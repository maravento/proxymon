#!/bin/bash
# maravento.com
#
################################################################################
#
# Squid Analysis Tool
#
# Advanced companion to the proxymon panel: looks into the Squid logs the
# panel does not cover, including rotated and compressed files.
#
# 1) Traffic report -- requests per IP and domain, with alerts
# 2) Log search     -- literal text, no regex, in access.log and cache.log
#
# Both reports are written as HTML next to this script and served by the
# proxymon vhost. Log paths come from /etc/proxymon/proxymon.env.
#
# log: squidtool.log, in this script's directory (rewritten on each run)
#
################################################################################

set -uo pipefail

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# logging
script_dir="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
log_file="$script_dir/squidtool.log"
{ > "$log_file"; } 2>/dev/null || true
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$log_file" 2>/dev/null || true
}

# root check
if [ "$(id -u)" != "0" ]; then
    log "ERROR: This script must be run as root -- abort"
    exit 1
fi

# prevent overlapping runs
script_lock="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$script_lock")
exec 200>"$script_lock"
if ! flock -n 200; then
    log "ERROR: script $(basename "$0") is already running -- abort"
    exit 1
fi

# dependencies
for dep_pkg in perl gawk gzip grep coreutils util-linux; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        log "ERROR: dependency '$dep_pkg' is not installed -- abort"
        exit 1
    fi
done

# dependencies (squid or squid-openssl)
if ! dpkg -s squid &>/dev/null && ! dpkg -s squid-openssl &>/dev/null; then
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
traffic_html="$script_dir/squid_traffic.html"
search_html="$script_dir/squid_search.html"
panel_port="18080"
# Rows below this many requests are dropped from the traffic report when no
# IP was given, so the table is not flooded by one-off entries. A report for
# a single IP shows everything.
min_hits=20
alert_threshold=300

# Squid log paths come from proxymon.env, never sourced: the file is read
# key by key and SQUID_LOG_FILE may reference SQUID_LOG_DIR, which is
# expanded here instead of by the shell.
load_conf() {
    local conf_file="$1" env_line env_key env_value
    [ -f "$conf_file" ] || return 1
    while IFS= read -r env_line || [ -n "$env_line" ]; do
        [[ "$env_line" =~ ^[[:space:]]*# ]] && continue
        [[ "$env_line" =~ ^[[:space:]]*$ ]] && continue
        env_key="${env_line%%=*}"
        env_value="${env_line#*=}"
        if [[ ! "$env_line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] \
           || [[ "$env_value" == [[:space:]\"\']* ]] \
           || [[ "$env_value" == *[[:space:]\"\'] ]]; then
            log "ERROR: malformed line in $conf_file: '$env_line' -- abort"
            exit 1
        fi
        case "$env_key" in
            SQUID_LOG_DIR)  squid_log_dir="$env_value" ;;
            SQUID_LOG_FILE) squid_log_file="$env_value" ;;
        esac
    done < "$conf_file"
    return 0
}

squid_log_dir=""
squid_log_file=""
if ! load_conf "$proxymon_env"; then
    log "WARNING: $(basename "$proxymon_env") not found -- fallback"
fi
squid_log_dir="${squid_log_dir:-/var/log/squid}"
squid_log_file="${squid_log_file:-$squid_log_dir/access.log}"
squid_log_file="${squid_log_file//\$SQUID_LOG_DIR/$squid_log_dir}"
squid_log_file="${squid_log_file//\$\{SQUID_LOG_DIR\}/$squid_log_dir}"
cache_log_file="$squid_log_dir/cache.log"

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
        log "ERROR: invalid IP '$ip_answer' -- abort"
        return 1
    fi
    printf '%s' "$ip_answer"
}

# Prints the epoch before which entries are ignored, or 0 for no limit.
# $1 is the default shown to the user: a number of hours, or "all".
ask_cutoff() {
    local default_hours="$1" hours_answer
    if [ "$default_hours" = "all" ]; then
        read -r -p "Hours to analyze, e.g. 24, 48, 72 (enter for all history): " hours_answer
        [ -z "$hours_answer" ] && { printf '0'; return 0; }
    else
        read -r -p "Hours to analyze, e.g. 24, 48, 72 (enter for $default_hours): " hours_answer
        hours_answer="${hours_answer:-$default_hours}"
    fi
    if ! [[ "$hours_answer" =~ $UH_UINT ]] || [ "$hours_answer" -lt 1 ]; then
        log "WARNING: invalid hours '$hours_answer' -- fallback"
        hours_answer=72
    fi
    printf '%s' "$(( $(date +%s) - hours_answer * 3600 ))"
}

cutoff_label() {
    local cutoff="$1"
    if [ "$cutoff" -eq 0 ]; then
        printf 'all history'
    else
        printf 'since %s' "$(date -d "@$cutoff" '+%Y-%m-%d %H:%M')"
    fi
}

html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Marks the searched text inside already escaped lines. The term is escaped
# twice: as HTML, so it matches what the line now holds, and as a regular
# expression, so a literal search stays literal.
highlight_term() {
    local term_escaped
    term_escaped=$(printf '%s' "$1" | html_escape | sed -e 's/[][\.*^$/\\?+(){}|]/\\&/g')
    [ -z "$term_escaped" ] && { cat; return 0; }
    sed -E "s/($term_escaped)/<mark>\1<\/mark>/Ig"
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
    cat <<EOF
<p class='timestamp'>Generated on $(date '+%Y-%m-%d %H:%M:%S')</p>
</div>
</body>
</html>
EOF
}

# Leaves the report readable by the panel and prints where to open it
publish_report() {
    local report_file="$1" server_ip
    chown www-data:www-data "$report_file" 2>/dev/null || true
    chmod 644 "$report_file"
    server_ip=$(grep -oP "^Listen \K[0-9.]+(?=:${panel_port})" /etc/apache2/ports.conf 2>/dev/null | head -1)
    server_ip="${server_ip:-localhost}"
    echo "Report: http://${server_ip}:${panel_port}/proxymon/tools/$(basename "$report_file")"
    echo "File  : $report_file"
}

# TRAFFIC
# Requests per IP and domain over the period, most active first
report_traffic() {
    local target_ip cutoff rows row_count alert_count
    target_ip=$(ask_ip) || return
    cutoff=$(ask_cutoff 72)

    log "INFO: traffic report -- ip=${target_ip:-all} cutoff=$cutoff"
    echo "Analyzing, please wait..."

    rows=$(zcat -f "$squid_log_file"* 2>/dev/null | gawk -v cutoff="$cutoff" -v ip="$target_ip" '
        $1 > cutoff {
            if (ip != "" && $3 != ip) next
            if (match($7, /https?:\/\/([^\/]+)/, url_parts) && url_parts[1] != "") { print $3, url_parts[1] }
            else if ($7 ~ /^[^\/]+:[0-9]+$/) { host = $7; sub(/:[0-9]+$/, "", host); print $3, host }
        }' | sort | uniq -c | sort -nr)

    if [ -n "$target_ip" ]; then
        rows=$(printf '%s\n' "$rows" | gawk 'NF >= 3')
    else
        rows=$(printf '%s\n' "$rows" | gawk -v min="$min_hits" 'NF >= 3 && $1 + 0 >= min')
    fi

    row_count=$(printf '%s' "$rows" | grep -c . || true)
    alert_count=$(printf '%s\n' "$rows" | gawk -v th="$alert_threshold" 'NF >= 3 && $1 + 0 >= th' | grep -c . || true)

    {
        html_open "Squid Traffic Report"
        echo "<div class='stat-card'>"
        echo "<div class='metric'><span class='metric-name'>IP address</span><span class='metric-value'>${target_ip:-all}</span></div>"
        echo "<div class='metric'><span class='metric-name'>Period</span><span class='metric-value'>$(cutoff_label "$cutoff")</span></div>"
        echo "<div class='metric'><span class='metric-name'>Rows</span><span class='metric-value'>${row_count}</span></div>"
        if [ "$alert_count" -gt 0 ]; then
            echo "<div class='metric'><span class='metric-name'>Above ${alert_threshold} requests</span><span class='metric-value alert'>${alert_count}</span></div>"
        fi
        echo "</div>"
        if [ "$row_count" -eq 0 ]; then
            echo "<p>No requests found for the selected period.</p>"
        else
            echo "<table><tr><th>Requests</th><th>IP</th><th>Domain</th></tr>"
            printf '%s\n' "$rows" | html_escape | gawk -v th="$alert_threshold" 'NF >= 3 {
                printf "<tr><td%s>%s</td><td>%s</td><td>%s</td></tr>\n", ($1 + 0 >= th ? " class=\"alert\"" : ""), $1, $2, $3
            }'
            echo "</table>"
        fi
        html_close
    } > "$traffic_html"

    log "INFO: traffic rows=$row_count alerts=$alert_count"
    publish_report "$traffic_html"
}

# SEARCH
# Occurrences of a term in access.log and cache.log, rotated files included
report_search() {
    local search_term target_ip cutoff access_hits cache_hits access_count cache_count
    read -r -p "Enter the text to search (e.g. google): " search_term
    if [ -z "$search_term" ]; then
        log "ERROR: no search term given -- abort"
        return
    fi
    target_ip=$(ask_ip) || return
    cutoff=$(ask_cutoff all)

    log "INFO: search '$search_term' -- ip=${target_ip:-all} cutoff=$cutoff"
    echo "Searching, please wait..."

    access_hits=$(zcat -f "$squid_log_file"* 2>/dev/null \
        | gawk -v cutoff="$cutoff" -v ip="$target_ip" '$1 > cutoff { if (ip == "" || $3 == ip) print }' \
        | grep -a -i -F -- "$search_term" \
        | perl -pe 's/^(\d+\.\d+)/localtime($1)/e')

    # cache.log carries no client IP, so the IP filter does not apply to it
    cache_hits=$(zcat -f "$cache_log_file"* 2>/dev/null \
        | gawk -v cutoff="$cutoff" '{ ts = $1 " " $2; gsub(/[\/:]/, " ", ts); t = mktime(ts); if (t < 0 || t >= cutoff) print }' \
        | grep -a -i -F -- "$search_term" \
        | perl -pe 's/^(\d+\.\d+)/localtime($1)/e')

    access_count=$(printf '%s' "$access_hits" | grep -c . || true)
    cache_count=$(printf '%s' "$cache_hits" | grep -c . || true)

    {
        html_open "Squid Search Report"
        echo "<div class='stat-card'>"
        echo "<div class='metric'><span class='metric-name'>Term</span><span class='metric-value'>$(printf '%s' "$search_term" | html_escape)</span></div>"
        echo "<div class='metric'><span class='metric-name'>IP address</span><span class='metric-value'>${target_ip:-all}</span></div>"
        echo "<div class='metric'><span class='metric-name'>Period</span><span class='metric-value'>$(cutoff_label "$cutoff")</span></div>"
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
    } > "$search_html"

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
            *) echo "ERROR: invalid option" ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# END
# ------------------------------------------------------------------------------

log "squidtool start..."
show_menu
log "squidtool done at: $(date)"
