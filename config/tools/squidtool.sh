#!/bin/bash
# maravento.com
#
################################################################################
#
# squidtool -- Squid log analysis for proxymon
#
# DESCRIPTION:
# Reads the Squid logs the panel does not cover, rotated and compressed
# ones included, and writes its reports as HTML. Requires root.
#
# USAGE:
# sudo bash squidtool.sh    Interactive menu
#
# LOG: /etc/proxymon/tools/squidtool.log
#      Written in this script's own directory, so it follows the script
#
################################################################################

set -uo pipefail

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# root check
if [ "$(id -u)" != "0" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: This script must be run as root -- abort" >&2
    exit 1
fi

# prevent overlapping runs
script_lock="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$script_lock")
exec 200>"$script_lock"
if ! flock -n 200; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: script $(basename "$0") is already running -- abort" >&2
    exit 1
fi

# logging
script_dir="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
log_file="$script_dir/squidtool.log"
{ > "$log_file"; } 2>/dev/null || true
log() {
    local log_msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
    echo "$log_msg" >> "$log_file" 2>/dev/null || true
    if [[ "$1" == ERROR:* ]]; then
        echo "$log_msg" >&2
    else
        echo "$log_msg"
    fi
}

# Function: Report whether a package is installed, not merely residual
package_installed() {
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = installed ]
}

# dependencies
for dep_pkg in perl gawk gzip grep coreutils util-linux; do
    if ! package_installed "$dep_pkg"; then
        log "ERROR: dependency '$dep_pkg' is not installed -- abort"
        exit 1
    fi
done

# dependencies (squid or squid-openssl)
if ! package_installed squid && ! package_installed squid-openssl; then
    log "ERROR: 'squid' or 'squid-openssl' is not installed -- abort"
    exit 1
fi

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

# validation -- one variable per thing validated; use directly with =~
UH_IPV4='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_UINT='^(0|[1-9][0-9]*)$'

proxymon_env="/etc/proxymon/proxymon.env"

# Rows below this many requests are dropped from the traffic report when no
# IP was given, so the table is not flooded by one-off entries. A report for
# a single IP shows everything.
min_hits=20
alert_threshold=300

# ------------------------------------------------------------------------------
# ENV
# ------------------------------------------------------------------------------

# PERMS
# Owner and mode of every .env this script reads
env_specs=("$proxymon_env root:www-data 640")
for env_spec in "${env_specs[@]}"; do
    read -r env_path env_owner_want env_perms_want <<< "$env_spec"
    if [ ! -f "$env_path" ]; then
        log "ERROR: $(basename "$env_path") not found -- abort"
        exit 1
    fi
    env_owner=$(stat -c '%U:%G' "$env_path" 2>/dev/null)
    env_perms=$(stat -c '%a' "$env_path" 2>/dev/null)
    if [[ "$env_owner" != "$env_owner_want" ]] \
       || [[ "$env_perms" != "$env_perms_want" ]]; then
        if chown "$env_owner_want" "$env_path" 2>/dev/null \
           && chmod "$env_perms_want" "$env_path" 2>/dev/null; then
            log "INFO: $(basename "$env_path") perms fixed -- fixed"
        else
            log "ERROR: cannot fix $(basename "$env_path") perms -- abort"
            exit 1
        fi
    fi
done
unset env_specs env_spec env_path env_owner_want env_perms_want
unset env_owner env_perms

# LOAD_CONF
# Read known key=value pairs from a config file, without sourcing it
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/proxymonenv.sh"

# LOAD
load_proxymon_env "$proxymon_env" || { log "ERROR: cannot load proxymon.env -- abort"; exit 1; }
report_dir="${TOOL_REPORT_DIR:-}"
traffic_html="$report_dir/squid_traffic.html"
search_html="$report_dir/squid_search.html"
panel_port="${PANEL_PORT:-}"

# KEY CHECK
# Collect every failure first, then decide -- a single abort reports them all
key_errors=()
for env_key in SQUID_LOG_DIR SQUID_LOG_FILE TOOL_REPORT_DIR PANEL_PORT; do
    if ! grep -q "^${env_key}=" "$proxymon_env"; then
        key_errors+=("$env_key missing line")
    elif [[ -z "${!env_key:-}" ]]; then
        key_errors+=("$env_key not set")
    elif [ "$env_key" = PANEL_PORT ] && { ! [[ "${!env_key}" =~ ^[1-9][0-9]{0,4}$ ]] || (( ${!env_key} > 65535 )); }; then
        key_errors+=("$env_key invalid port")
    fi
done
if (( ${#key_errors[@]} > 0 )); then
    for key_error in "${key_errors[@]}"; do
        log "ERROR: $key_error"
    done
    log "ERROR: ${#key_errors[@]} key(s) invalid in $(basename "$proxymon_env") -- abort"
    exit 1
fi
unset key_errors key_error env_key

# FALLBACK
# Second layer of protection, behind KEY CHECK -- by design never reached
if [ -z "${SQUID_LOG_DIR:-}" ]; then
    log "WARNING: no SQUID_LOG_DIR in proxymon.env -- fallback"
fi
squid_log_dir="$SQUID_LOG_DIR"
if [ -z "${SQUID_LOG_FILE:-}" ]; then
    log "WARNING: no SQUID_LOG_FILE in proxymon.env -- fallback"
fi
squid_log_file="${SQUID_LOG_FILE:-$squid_log_dir/access.log}"
cache_log_file="$squid_log_dir/cache.log"

# REPORT DIR
# Root owns the whole chain down to the reports, so nothing else can swap a
# path for a symlink while this script writes. Apache serves them through
# an Alias in proxymon.conf and only needs read access.
if ! mkdir -p "$report_dir"; then
    log "ERROR: cannot create $report_dir -- abort"
    exit 1
fi
if ! chown root:root "$report_dir" || ! chmod 755 "$report_dir"; then
    log "ERROR: cannot set permissions on $report_dir -- abort"
    exit 1
fi

# KEY GUARD
# Every report below reads this file, so a path that no longer matches the
# filesystem produces an empty report instead of an error.
if ! ls "$squid_log_file"* >/dev/null 2>&1; then
    log "ERROR: access log not found in $squid_log_dir -- abort"
    exit 1
fi

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

ask_ip() {
    local ip_answer
    read -r -p "IP address (enter for all): " ip_answer
    if [ -n "$ip_answer" ] && ! [[ "$ip_answer" =~ $UH_IPV4 ]]; then
        log "INFO: invalid IP '$ip_answer' -- skip" >&2
        return 1
    fi
    printf '%s' "$ip_answer"
}

# Prints the epoch before which entries are ignored, or 0 for no limit.
# $1 is the default shown to the user: a number of hours, or "all".
ask_cutoff() {
    local default_hours="$1" hours_answer now_epoch
    if [ "$default_hours" = "all" ]; then
        read -r -p "Hours to analyze, e.g. 24, 48, 72 (enter for all history): " hours_answer
        [ -z "$hours_answer" ] && { printf '0'; return 0; }
    else
        read -r -p "Hours to analyze, e.g. 24, 48, 72 (enter for $default_hours): " hours_answer
        hours_answer="${hours_answer:-$default_hours}"
    fi
    # The length test runs first so [ cannot overflow on a long digit string.
    # 876000 hours are one hundred years, far beyond any Squid log.
    if ! [[ "$hours_answer" =~ $UH_UINT ]] || [ "${#hours_answer}" -gt 7 ] \
        || [ "$hours_answer" -lt 1 ] || [ "$hours_answer" -gt 876000 ]; then
        # Callers read this function through $(...), so stdout must carry the
        # timestamp alone. The notice goes to stderr and still reaches the log.
        log "WARNING: invalid hours '$hours_answer' -- fallback" >&2
        hours_answer=72
    fi
    # The epoch is read in an assignment, because arithmetic would turn a
    # failing date into a zero and yield a negative cutoff with success.
    now_epoch=$(date +%s) || return 1
    printf '%s' "$(( now_epoch - hours_answer * 3600 ))"
}

cutoff_label() {
    local cutoff="$1" cutoff_date
    if [ "$cutoff" -eq 0 ]; then
        printf 'all history'
    else
        cutoff_date=$(date -d "@$cutoff" '+%Y-%m-%d %H:%M') || return 1
        printf 'since %s' "$cutoff_date"
    fi
}

# Counts the non-empty lines read from stdin. grep exits 1 when nothing
# matched, which is a count of zero, so only a higher status is an error.
count_lines() {
    local line_count grep_rc
    line_count=$(grep -c .)
    grep_rc=$?
    [ "$grep_rc" -le 1 ] || return 1
    printf '%s' "$line_count"
}

html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Marks the searched text inside already escaped lines. The term is escaped
# as HTML, so it matches what the line now holds. The \Q of Perl keeps the
# search literal. The term is tried first, so a term holding & or < still
# matches. The second branch leaves any remaining HTML entity untouched.
highlight_term() {
    local term_escaped
    term_escaped=$(printf '%s' "$1" | html_escape) || return 1
    [ -z "$term_escaped" ] && { cat; return 0; }
    perl -pe '
        BEGIN { $term = shift @ARGV; }
        s{(\Q$term\E)|(&(?:amp|lt|gt);)}{ defined($1) ? "<mark>$1</mark>" : $2 }gei;
    ' -- "$term_escaped"
}

html_open() {
    local page_title="$1"
    cat <<EOF
<!DOCTYPE html>
<html lang='en'>
<head>
<meta charset='UTF-8'>
<meta name='viewport' content='width=device-width, initial-scale=1.0'>
<title>$page_title</title>
<style>
body { font-family: 'Segoe UI', sans-serif; background: #f5f7fa; color: #333; margin: 0; padding: 20px; }
.container { max-width: 1200px; margin: 0 auto; background: white; border-radius: 10px; padding: 30px; box-shadow: 0 4px 20px rgba(0,0,0,0.1); }
h1 { text-align: center; color: #2c3e50; margin-bottom: 30px; font-size: 2.5em; }
.stat-card { background: #fff; padding: 20px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); border-left: 4px solid #3498db; margin-bottom: 20px; }
.metric { display: flex; justify-content: space-between; padding: 8px 0; border-bottom: 1px solid #f1f1f1; }
.metric:last-child { border-bottom: none; }
.metric-name { font-weight: 600; color: #555; }
.metric-value { color: #27ae60; font-weight: bold; }
.alert { color: #e74c3c; font-weight: bold; }
table { width: 100%; border-collapse: collapse; margin: 20px 0; background: white; border-radius: 8px; overflow: hidden; }
th, td { padding: 12px 15px; text-align: left; border-bottom: 1px solid #f1f1f1; }
th { background: #3498db; color: white; font-weight: 600; }
tr:nth-child(even) { background-color: #f8f9fa; }
tr:hover { background-color: #e3f2fd; }
pre { background: #f8f9fa; padding: 15px; border-radius: 8px; overflow-x: auto; font-size: 0.9em; line-height: 1.4; }
mark { background: #ffe08a; color: #333; padding: 0 2px; border-radius: 2px; }
.section-title { color: #2c3e50; font-size: 1.5em; margin: 30px 0 15px 0; padding-bottom: 10px; border-bottom: 2px solid #3498db; }
.timestamp { text-align: center; color: #777; margin-top: 30px; font-style: italic; }
</style>
</head>
<body>
<div class='container'>
<h1>$page_title</h1>
EOF
}

html_close() {
    local generated_at
    generated_at=$(date '+%Y-%m-%d %H:%M:%S') || return 1
    cat <<EOF
<p class='timestamp'>Generated on $generated_at</p>
</div>
</body>
</html>
EOF
}

# Leaves the report readable by the panel and prints where to open it
publish_report() {
    local report_file="$1" server_ip
    if ! chown root:root "$report_file" || ! chmod 644 "$report_file"; then
        log "ERROR: cannot set permissions on $(basename "$report_file") -- abort"
        exit 1
    fi
    server_ip=$(grep -oP "^Listen \K[0-9.]+(?=:${panel_port})" /etc/apache2/ports.conf 2>/dev/null | head -1)
    server_ip="${server_ip:-localhost}"
    echo "Report: http://${server_ip}:${panel_port}/proxymon/squidtool/$(basename "$report_file")"
    echo "File  : $report_file"
}

# TRAFFIC
# Requests per IP and domain over the period, most active first
report_traffic() {
    local target_ip cutoff rows row_count alert_count filter_rc block_rc
    target_ip=$(ask_ip) || return
    if ! cutoff=$(ask_cutoff 72); then
        log "ERROR: cannot resolve traffic period -- abort"
        exit 1
    fi

    log "INFO: traffic report -- ip=${target_ip:-all} cutoff=$cutoff"
    echo "Analyzing, please wait..."

    if ! rows=$(zcat -f "$squid_log_file"* | awk -v cutoff="$cutoff" -v ip="$target_ip" '
        $1 > cutoff {
            if (ip != "" && $3 != ip) next
            if (match($7, /https?:\/\/[^\/]+/)) {
                host = substr($7, RSTART, RLENGTH)
                sub(/^https?:\/\//, "", host)
                if (host != "") { print $3, host }
            }
            else if ($7 ~ /^[^\/]+:[0-9]+$/) { host = $7; sub(/:[0-9]+$/, "", host); print $3, host }
        }' | sort | uniq -c | sort -nr); then
        log "ERROR: cannot analyze access logs -- abort"
        exit 1
    fi

    if [ -n "$target_ip" ]; then
        rows=$(printf '%s\n' "$rows" | awk 'NF >= 3')
    else
        rows=$(printf '%s\n' "$rows" | awk -v min="$min_hits" 'NF >= 3 && $1 + 0 >= min')
    fi
    # fi carries the status of the branch that ran, so one test covers both.
    filter_rc=$?
    if [ "$filter_rc" -ne 0 ]; then
        log "ERROR: cannot filter traffic rows -- abort"
        exit 1
    fi

    if ! row_count=$(printf '%s' "$rows" | count_lines); then
        log "ERROR: cannot count traffic rows -- abort"
        exit 1
    fi
    if ! alert_count=$(printf '%s\n' "$rows" |
        awk -v th="$alert_threshold" 'NF >= 3 && $1 + 0 >= th' | count_lines); then
        log "ERROR: cannot count traffic alerts -- abort"
        exit 1
    fi

    # The subshell carries set -e, so any failing write or helper ends it. The
    # status is read on the next line, because bash would disable set -e if the
    # subshell hung from a || list. The period is resolved before the block,
    # since set -e ignores a failing substitution used as an argument.
    (
        set -e
        period_label=$(cutoff_label "$cutoff")
        html_open "Squid Traffic Report"
        echo "<div class='stat-card'>"
        echo "<div class='metric'><span class='metric-name'>IP address</span><span class='metric-value'>${target_ip:-all}</span></div>"
        echo "<div class='metric'><span class='metric-name'>Period</span><span class='metric-value'>${period_label}</span></div>"
        echo "<div class='metric'><span class='metric-name'>Rows</span><span class='metric-value'>${row_count}</span></div>"
        if [ "$alert_count" -gt 0 ]; then
            echo "<div class='metric'><span class='metric-name'>Above ${alert_threshold} requests</span><span class='metric-value alert'>${alert_count}</span></div>"
        fi
        echo "</div>"
        if [ "$row_count" -eq 0 ]; then
            echo "<p>No requests found for selected period.</p>"
        else
            echo "<table><tr><th>Requests</th><th>IP</th><th>Domain</th></tr>"
            printf '%s\n' "$rows" | html_escape | awk -v th="$alert_threshold" 'NF >= 3 {
                printf "<tr><td%s>%s</td><td>%s</td><td>%s</td></tr>\n", ($1 + 0 >= th ? " class=\"alert\"" : ""), $1, $2, $3
            }'
            echo "</table>"
        fi
        html_close
    ) > "$traffic_html"
    block_rc=$?
    if [ "$block_rc" -ne 0 ]; then
        log "ERROR: cannot write $(basename "$traffic_html") -- abort"
        exit 1
    fi

    log "INFO: traffic rows=$row_count alerts=$alert_count"
    publish_report "$traffic_html"
}

# SEARCH
# Occurrences of a term in access.log and cache.log, rotated files included
report_search() {
    local search_term target_ip cutoff access_hits cache_hits access_count
    local cache_count block_rc
    read -r -p "Enter the text to search (e.g. google): " search_term
    if [ -z "$search_term" ]; then
        log "INFO: no search term given -- skip"
        return
    fi
    target_ip=$(ask_ip) || return
    if ! cutoff=$(ask_cutoff all); then
        log "ERROR: cannot resolve search period -- abort"
        exit 1
    fi

    log "INFO: search '$search_term' -- ip=${target_ip:-all} cutoff=$cutoff"
    echo "Searching, please wait..."

    if ! access_hits=$(
        zcat -f "$squid_log_file"* \
            | awk -v cutoff="$cutoff" -v ip="$target_ip" '$1 > cutoff { if (ip == "" || $3 == ip) print }' \
            | grep -a -i -F -- "$search_term" \
            | perl -pe 's/^(\d+\.\d+)/localtime($1)/e'
        pipe_status=("${PIPESTATUS[@]}")
        (( pipe_status[0] == 0 && pipe_status[1] == 0 &&
           pipe_status[2] <= 1 && pipe_status[3] == 0 ))
    ); then
        log "ERROR: cannot search access logs -- abort"
        exit 1
    fi

    # cache.log carries no client IP, so the IP filter does not apply to it
    if ! cache_hits=$(
        zcat -f "$cache_log_file"* \
            | gawk -v cutoff="$cutoff" '{ ts = $1 " " $2; gsub(/[\/:]/, " ", ts); t = mktime(ts); if (t < 0 || t >= cutoff) print }' \
            | grep -a -i -F -- "$search_term" \
            | perl -pe 's/^(\d+\.\d+)/localtime($1)/e'
        pipe_status=("${PIPESTATUS[@]}")
        (( pipe_status[0] == 0 && pipe_status[1] == 0 &&
           pipe_status[2] <= 1 && pipe_status[3] == 0 ))
    ); then
        log "ERROR: cannot search cache log -- abort"
        exit 1
    fi

    if ! access_count=$(printf '%s' "$access_hits" | count_lines); then
        log "ERROR: cannot count access log matches -- abort"
        exit 1
    fi
    if ! cache_count=$(printf '%s' "$cache_hits" | count_lines); then
        log "ERROR: cannot count cache log matches -- abort"
        exit 1
    fi

    # The subshell carries set -e, so any failing write or helper ends it. The
    # status is read on the next line, because bash would disable set -e if the
    # subshell hung from a || list. The term and the period are resolved before
    # the block, since set -e ignores a failing substitution used as an argument.
    (
        set -e
        term_label=$(printf '%s' "$search_term" | html_escape)
        period_label=$(cutoff_label "$cutoff")
        html_open "Squid Search Report"
        echo "<div class='stat-card'>"
        echo "<div class='metric'><span class='metric-name'>Term</span><span class='metric-value'>${term_label}</span></div>"
        echo "<div class='metric'><span class='metric-name'>IP address</span><span class='metric-value'>${target_ip:-all}</span></div>"
        echo "<div class='metric'><span class='metric-name'>Period</span><span class='metric-value'>${period_label}</span></div>"
        echo "<div class='metric'><span class='metric-name'>access.log matches</span><span class='metric-value'>${access_count}</span></div>"
        echo "<div class='metric'><span class='metric-name'>cache.log matches</span><span class='metric-value'>${cache_count}</span></div>"
        echo "</div>"
        echo "<p class='section-title'>access.log</p>"
        if [ "$access_count" -eq 0 ]; then
            echo "<p>No matches found.</p>"
        else
            echo "<pre>"
            printf '%s\n' "$access_hits" | html_escape | highlight_term "$search_term"
            echo "</pre>"
        fi
        echo "<p class='section-title'>cache.log</p>"
        if [ "$cache_count" -eq 0 ]; then
            echo "<p>No matches found.</p>"
        else
            echo "<pre>"
            printf '%s\n' "$cache_hits" | html_escape | highlight_term "$search_term"
            echo "</pre>"
        fi
        html_close
    ) > "$search_html"
    block_rc=$?
    if [ "$block_rc" -ne 0 ]; then
        log "ERROR: cannot write $(basename "$search_html") -- abort"
        exit 1
    fi

    log "INFO: search access=$access_count cache=$cache_count"
    publish_report "$search_html"
}

# ------------------------------------------------------------------------------
# MENU
# ------------------------------------------------------------------------------

show_menu() {
    local option
    while true; do
        echo ""
        echo "Squid Analysis Tool"
        echo "-------------------"
        echo "1) Traffic report by IP and domain"
        echo "2) Log search in access.log and cache.log"
        echo "3) Exit"
        echo ""
        read -r -p "Select option (enter for 3): " option
        option="${option:-3}"
        case "$option" in
            1) report_traffic ;;
            2) report_search ;;
            3) return 0 ;;
            *) log "INFO: invalid option -- retry" ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# END
# ------------------------------------------------------------------------------

log "squidtool start..."
show_menu
log "squidtool done at: $(date '+%Y-%m-%d %H:%M:%S')"
