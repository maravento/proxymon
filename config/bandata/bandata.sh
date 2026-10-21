#!/bin/bash
# maravento.com
#
################################################################################
#
# bandata -- data usage limits for proxymon
#
# USAGE:
# sudo bash bandata.sh    Apply the quotas now
#
# LOG: /var/log/bandata.log
#
################################################################################

set -uo pipefail

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# path for cron
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# root check
if [ "$(id -u)" != "0" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: This script must be run as root -abort" >&2
    exit 1
fi

# logging
log_file="/var/log/bandata.log"
log() {
    local log_msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
    echo "$log_msg" >> "$log_file" 2>/dev/null || true
    if [[ "$1" == ERROR:* ]]; then
        echo "$log_msg" >&2
    else
        echo "$log_msg"
    fi
}

# prevent overlapping runs
script_lock="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$script_lock") || {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: cannot open $(basename "$script_lock") -abort" >&2
    exit 1
}
exec 200>"$script_lock"

if ! flock -n 200; then
    log "ERROR: script $(basename "$0") is already running -abort"
    exit 1
fi

# Function: Report whether a package is installed, not merely residual
package_installed() {
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = installed ]
}

# dependencies
for dep_pkg in ipset findutils coreutils iptables util-linux sed grep procps logrotate; do
    if ! package_installed "$dep_pkg"; then
        log "ERROR: dependency '$dep_pkg' is not installed -abort"
        exit 1
    fi
done

# Verify logrotate config exists for this log; create it if missing (self-contained)
logrotate_conf="/etc/logrotate.d/bandata"
if [ ! -f "$logrotate_conf" ]; then
    cat > "$logrotate_conf" <<'EOF'
/var/log/bandata.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
}
EOF
    logrotate_ok=$?
    chmod 644 "$logrotate_conf" || logrotate_ok=1
    chown root:root "$logrotate_conf" || logrotate_ok=1
    if [ "$logrotate_ok" -eq 0 ]; then
        log "INFO: logrotate config created for $(basename "$log_file") -fixed"
    else
        log "WARNING: cannot create logrotate config -alert"
        rm -f "$logrotate_conf" \
            || log "WARNING: cannot remove the partial logrotate config -alert"
    fi
fi

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

# validation -- one variable per thing validated; use directly with =~
UH_IPV4='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_UINT='^(0|[1-9][0-9]*)$'
UH_BOOL='^(true|false)$'

# ------------------------------------------------------------------------------
# ENV
# ------------------------------------------------------------------------------

# PERMS
# Owner and mode of every .env this script reads
proxymon_env="/etc/proxymon/proxymon.env"
env_specs=("$proxymon_env root:www-data 640")
for env_spec in "${env_specs[@]}"; do
    read -r env_path env_owner_want env_perms_want <<< "$env_spec"
    if [ ! -f "$env_path" ]; then
        log "ERROR: $(basename "$env_path") not found -abort"
        exit 1
    fi
    env_owner=$(stat -c '%U:%G' "$env_path" 2>/dev/null)
    env_perms=$(stat -c '%a' "$env_path" 2>/dev/null)
    if [[ "$env_owner" != "$env_owner_want" ]] \
       || [[ "$env_perms" != "$env_perms_want" ]]; then
        if chown "$env_owner_want" "$env_path" 2>/dev/null \
           && chmod "$env_perms_want" "$env_path" 2>/dev/null; then
            log "INFO: $(basename "$env_path") perms fixed -fixed"
        else
            log "ERROR: cannot fix $(basename "$env_path") perms -abort"
            exit 1
        fi
    fi
done
unset env_specs env_spec env_path env_owner_want env_perms_want
unset env_owner env_perms

# LOAD_CONF
# Read known key=value pairs from a config file, without sourcing it
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../tools/proxymonenv.sh"

# LOAD
# Reads proxymon.env; a file that cannot be read aborts the run here
load_proxymon_env "$proxymon_env" || { log "ERROR: cannot load proxymon.env -abort"; exit 1; }

# KEY CHECK
# Collect every failure first, then decide -- a single abort reports them all
key_errors=()
for env_key in WARNING_PORT LAN REPORT_IP_GLOB SQUIDREPORTS_DIR REPORT_PATH REALNAME_CFG \
               SKIPUSERS_CFG ACL_PATH ACL_MAC_PATH ACL_BANDATA_PATH \
               ALLOW_LIST BLOCK_LIST_DAY BLOCK_LIST_WEEK BLOCK_LIST_MONTH \
               WARNING_HTML BANDATA_HOTSPOT HOTSPOT_PATH UPDATE_REALNAME; do
    if ! grep -q "^${env_key}=" "$proxymon_env"; then
        key_errors+=("$env_key missing line")
    elif [[ -z "${!env_key:-}" ]]; then
        key_errors+=("$env_key not set")
    elif [ "$env_key" = WARNING_PORT ] && { checked_port="${!env_key}"; ! [[ "$checked_port" =~ $UH_UINT ]] || [ "${#checked_port}" -gt 5 ] || [ "$checked_port" -lt 1 ] || [ "$checked_port" -gt 65535 ]; }; then
        key_errors+=("$env_key invalid port")
    elif { [ "$env_key" = BANDATA_HOTSPOT ] || [ "$env_key" = UPDATE_REALNAME ]; } \
        && ! [[ "${!env_key}" =~ $UH_BOOL ]]; then
        key_errors+=("$env_key invalid boolean")
    fi
done
# numfmt is the only parser that accepts the IEC forms the administrator
# writes (500M, 1G, 1.5G), so it is also what validates them. An empty result
# would otherwise be treated as a 0 limit, blocking the entire network.
for env_key in MAX_BANDWIDTH_DAY MAX_BANDWIDTH_WEEK MAX_BANDWIDTH_MONTH; do
    if ! grep -q "^${env_key}=" "$proxymon_env"; then
        key_errors+=("$env_key missing line")
    elif [[ -z "${!env_key:-}" ]]; then
        key_errors+=("$env_key not set")
    elif ! quota_bytes=$(LC_ALL=C numfmt --from=iec "${!env_key/,/.}" 2>/dev/null) \
        || [[ -z "$quota_bytes" ]]; then
        key_errors+=("$env_key invalid size, expected 500M, 1G or 1.5G")
    elif [ "$env_key" = MAX_BANDWIDTH_DAY ] && ! {
        [[ "$quota_bytes" =~ $UH_UINT ]] && {
            [ "${#quota_bytes}" -lt 19 ] || {
                [ "${#quota_bytes}" -eq 19 ] \
                    && [[ "$quota_bytes" < 9223372036854775808 ]]
            }
        }
    }; then
        key_errors+=("$env_key exceeds Bash integer range")
    fi
done
if (( ${#key_errors[@]} > 0 )); then
    for key_error in "${key_errors[@]}"; do
        log "WARNING: $key_error -alert"
    done
    log "ERROR: ${#key_errors[@]} key(s) invalid in $(basename "$proxymon_env") -abort"
    exit 1
fi
unset key_errors key_error env_key checked_port quota_bytes

# KEY GUARD
# Each key above is valid on its own. These two relations are not.
if [ ! -e "/sys/class/net/$LAN" ]; then
    log "ERROR: interface '$LAN' does not exist -abort"
    exit 1
fi
# Byte forms of the three limits, derived from keys KEY CHECK already validated
max_bw_day=$(LC_ALL=C numfmt --from=iec "${MAX_BANDWIDTH_DAY/,/.}")
max_bw_week=$(LC_ALL=C numfmt --from=iec "${MAX_BANDWIDTH_WEEK/,/.}")
max_bw_month=$(LC_ALL=C numfmt --from=iec "${MAX_BANDWIDTH_MONTH/,/.}")

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

log "bandata start..."

# PREFLIGHT CHECKS
# Self-heal: remove orphaned .tmp files left by a previous run that failed
# between the write and the mv (no -e/trap in this script to catch that).
for stale_file in "$BLOCK_LIST_DAY.tmp" "$BLOCK_LIST_WEEK.tmp" "$BLOCK_LIST_MONTH.tmp"; do
    if [ -f "$stale_file" ]; then
        log "WARNING: removing orphaned $(basename "$stale_file") -alert"
        rm -f "$stale_file"
    fi
done

# today
today_dow=$(date +"%u")
# reorganize IP
sort_ips="sort -t . -k 1,1n -k 2,2n -k 3,3n -k 4,4n"
# A list that cannot be cleared keeps the previous blocks, so that failure must
# reach the set. The mark is read where load_failed starts, further below.
list_failed=0
clear_list() {
    : > "$1" || {
        list_failed=1
        log "WARNING: cannot clear $(basename "$1") -alert"
    }
}
# FILESYSTEM LAYOUT
# Create folders if they don't exist
[ -d "$ACL_PATH" ] || mkdir -p "$ACL_PATH"
[ -d "$ACL_MAC_PATH" ] || mkdir -p "$ACL_MAC_PATH"
[ -d "$ACL_BANDATA_PATH" ] || mkdir -p "$ACL_BANDATA_PATH"
# Create ACL files if they don't exist
touch "$ALLOW_LIST" "$BLOCK_LIST_DAY" "$BLOCK_LIST_WEEK" "$BLOCK_LIST_MONTH"

if [ "$BANDATA_HOTSPOT" = true ] && [ ! -d "$HOTSPOT_PATH" ]; then
    log "ERROR: BANDATA_HOTSPOT=true but $HOTSPOT_PATH missing -abort"
    exit 1
fi

# ------------------------------------------------------------------------------
# BANDAY
# ------------------------------------------------------------------------------

log "Running Bandata Day..."

# path to day report
day_logs_dir=$REPORT_PATH/$(date +"%Y%m%d")
# bandata day rule
if [[ "$today_dow" -eq 6 || "$today_dow" -eq 7 ]]; then
    log "INFO: Weekend Excluded"
    : > "$BLOCK_LIST_DAY"
else
    if [ ! -d "$day_logs_dir" ]; then
        log "INFO: day report folder $(basename "$day_logs_dir") not found -skip"
        : > "$BLOCK_LIST_DAY"
    else
        tmp_day=$(mktemp)
        subshell_ok=0
        (
            cd "$day_logs_dir" || { log "WARNING: cannot cd into $day_logs_dir -alert" >&2; exit 1; }
            shopt -s nullglob
            for report_file in $REPORT_IP_GLOB; do
                # A failing awk can still print a partial total, so its status
                # decides. Ending the subshell clears the day, as the flow asks.
                user_bytes=$(awk '$1=="total:" {print $2}' "$report_file") || {
                    log "WARNING: cannot read $report_file -alert" >&2
                    exit 1
                }
                if [[ "$user_bytes" =~ $UH_UINT ]] && (( user_bytes > max_bw_day )); then
                    echo "$report_file"
                elif [ -n "$user_bytes" ] && ! [[ "$user_bytes" =~ $UH_UINT ]]; then
                    log "WARNING: non-numeric total '$user_bytes' in $report_file -alert" >&2
                fi
            done
            exit 0
        ) > "$tmp_day" && subshell_ok=1

        if [ "$subshell_ok" -eq 1 ]; then
            # The exclusions are read in an assignment, because a process
            # substitution hides its own failure. A partial read would turn an
            # exempt address into a block. grep 1 means no blank line removed.
            allow_ips=$(grep -v '^[[:space:]]*$' "$ALLOW_LIST")
            allow_rc=$?
            if [ "$allow_rc" -gt 1 ]; then
                log "WARNING: cannot read allow list, day cleared -alert"
                : > "$BLOCK_LIST_DAY"
            else
                grep -wvFf <(printf '%s\n' "$allow_ips") "$tmp_day" | $sort_ips | uniq > "${BLOCK_LIST_DAY}.tmp"
                pipe_status=("${PIPESTATUS[@]}")
                if [ "${pipe_status[0]}" -le 1 ] && [ "${pipe_status[1]}" -eq 0 ] && [ "${pipe_status[2]}" -eq 0 ]; then
                    if ! mv -f "${BLOCK_LIST_DAY}.tmp" "$BLOCK_LIST_DAY"; then
                        log "WARNING: cannot publish daily list, day cleared -alert"
                        rm -f "${BLOCK_LIST_DAY}.tmp"
                        clear_list "$BLOCK_LIST_DAY"
                    fi
                else
                    log "WARNING: cannot build daily list, day cleared -alert"
                    rm -f "${BLOCK_LIST_DAY}.tmp"
                    : > "$BLOCK_LIST_DAY"
                fi
            fi
        else
            log "WARNING: cannot read day reports, day cleared -alert"
            : > "$BLOCK_LIST_DAY"
        fi
        rm -f "$tmp_day"
    fi

    day_count=$(wc -l < "$BLOCK_LIST_DAY" 2>/dev/null || echo 0)
    if [ "$day_count" -gt 0 ]; then
        log "INFO: Daily Blocked:"
        sed 's/^/ /' "$BLOCK_LIST_DAY" | tee -a "$log_file"
    else
        log "INFO: No daily blocks"
    fi
fi

# ------------------------------------------------------------------------------
# BANWEEK
# ------------------------------------------------------------------------------

# weekly MON-FRI
# note: uses GNU date (coreutils) relative-date syntax ("last monday",
# "+1 month -1 day"). Not portable to BSD/macOS date. This project
# targets Linux only (already requires ipset/iptables).

log "Running Bandata Week..."

if [ "$today_dow" -eq 1 ]; then
    week_dirs=()
    for weekday_offset in {0..4}; do
        day_dir="$REPORT_PATH/$(date -d "last week monday +$weekday_offset days" +'%Y%m%d')"
        [ -d "$day_dir" ] && week_dirs+=("$day_dir")
    done

    if [ ${#week_dirs[@]} -eq 0 ]; then
        log "INFO: No weekday report folders found for last week"
        : > "$BLOCK_LIST_WEEK"
    else
        # Each reading decides, because a partial list would total only part of
        # the week. Any failure clears the week, as the flow asks.
        if ! report_files=$(find "${week_dirs[@]}" -maxdepth 1 -type f \
            -name "$REPORT_IP_GLOB"); then
            log "WARNING: cannot read weekly reports, week cleared -alert"
            : > "$BLOCK_LIST_WEEK"
        elif ! user_totals=$(echo "$report_files" | xargs -r -I {} \
            awk '/^total:/{sub(".*/", "", FILENAME); print FILENAME" "$NF}' {}); then
            log "WARNING: cannot total weekly reports, week cleared -alert"
            : > "$BLOCK_LIST_WEEK"
        elif ! over_limit_ips=$(echo "$user_totals" | awk '{ arr[$1]+=$2 } END { for (key in arr) printf("%s\t%s\n", arr[key], key) }' | sort -k1,1); then
            log "WARNING: cannot add up weekly totals, week cleared -alert"
            : > "$BLOCK_LIST_WEEK"
        else
            # Same reading as the day: the exclusions cannot come from a process
            # substitution, whose failure the pipeline never sees.
            allow_ips=$(grep -v '^[[:space:]]*$' "$ALLOW_LIST")
            allow_rc=$?
            if [ "$allow_rc" -gt 1 ]; then
                log "WARNING: cannot read allow list, week cleared -alert"
                : > "$BLOCK_LIST_WEEK"
            else
                echo "$over_limit_ips" | awk -v max="$max_bw_week" '$1 > max {print $2}' | grep -wvFf <(printf '%s\n' "$allow_ips") | $sort_ips | uniq > "${BLOCK_LIST_WEEK}.tmp"
                pipe_status=("${PIPESTATUS[@]}")
                if [ "${pipe_status[0]}" -eq 0 ] && [ "${pipe_status[1]}" -eq 0 ] \
                   && [ "${pipe_status[2]}" -le 1 ] && [ "${pipe_status[3]}" -eq 0 ] \
                   && [ "${pipe_status[4]}" -eq 0 ]; then
                    if ! mv -f "${BLOCK_LIST_WEEK}.tmp" "$BLOCK_LIST_WEEK"; then
                        log "WARNING: cannot publish weekly list, week cleared -alert"
                        rm -f "${BLOCK_LIST_WEEK}.tmp"
                        clear_list "$BLOCK_LIST_WEEK"
                    fi
                else
                    log "WARNING: cannot build weekly list, week cleared -alert"
                    rm -f "${BLOCK_LIST_WEEK}.tmp"
                    : > "$BLOCK_LIST_WEEK"
                fi
            fi
        fi
    fi

    week_count=$(wc -l < "$BLOCK_LIST_WEEK" 2>/dev/null || echo 0)
    if [ "$week_count" -gt 0 ]; then
        log "INFO: Weekly Blocked:"
        sed 's/^/ /' "$BLOCK_LIST_WEEK" | tee -a "$log_file"
    else
        log "INFO: No weekly blocks"
    fi
else
    log "INFO: Weekly check runs on Monday only"
fi

# ------------------------------------------------------------------------------
# BANMONTH
# ------------------------------------------------------------------------------

log "Running Bandata Month..."

# Build weekday directories for current month (excluding weekends)
month_prefix=$(date +"%Y%m")
days_in_month=$(date -d "$(date +%Y-%m-01) +1 month -1 day" +%d)
month_dirs=()
for day_num in $(seq -w 1 "$days_in_month"); do
    day_path="$REPORT_PATH/${month_prefix}${day_num}"
    [ -d "$day_path" ] || continue
    day_of_week=$(date -d "${month_prefix:0:4}-${month_prefix:4:2}-${day_num}" +%u)
    [ "$day_of_week" -ge 6 ] && continue
    month_dirs+=("$day_path")
done

if [ ${#month_dirs[@]} -eq 0 ]; then
    log "INFO: No weekday report folders found for current month"
    : > "$BLOCK_LIST_MONTH"
else
    # Each reading decides, as in the week: a partial list would total only
    # part of the month. Any failure clears the month, as the flow asks.
    if ! report_files=$(find "${month_dirs[@]}" -maxdepth 1 -type f \
        -name "$REPORT_IP_GLOB"); then
        log "WARNING: cannot read monthly reports, month cleared -alert"
        : > "$BLOCK_LIST_MONTH"
    elif ! user_totals=$(echo "$report_files" | xargs -r -I {} \
        awk '/^total:/{sub(".*/", "", FILENAME); print FILENAME" "$NF}' {}); then
        log "WARNING: cannot total monthly reports, month cleared -alert"
        : > "$BLOCK_LIST_MONTH"
    elif ! over_limit_ips=$(echo "$user_totals" | awk '{ arr[$1]+=$2 } END { for (key in arr) printf("%s\t%s\n", arr[key], key) }' | sort -k1,1); then
        log "WARNING: cannot add up monthly totals, month cleared -alert"
        : > "$BLOCK_LIST_MONTH"
    else
        # Same reading as the day and the week, for the same reason.
        allow_ips=$(grep -v '^[[:space:]]*$' "$ALLOW_LIST")
        allow_rc=$?
        if [ "$allow_rc" -gt 1 ]; then
            log "WARNING: cannot read allow list, month cleared -alert"
            : > "$BLOCK_LIST_MONTH"
        else
            echo "$over_limit_ips" | awk -v max="$max_bw_month" '$1 > max {print $2}' | grep -wvFf <(printf '%s\n' "$allow_ips") | $sort_ips | uniq > "${BLOCK_LIST_MONTH}.tmp"
            pipe_status=("${PIPESTATUS[@]}")
            if [ "${pipe_status[0]}" -eq 0 ] && [ "${pipe_status[1]}" -eq 0 ] \
               && [ "${pipe_status[2]}" -le 1 ] && [ "${pipe_status[3]}" -eq 0 ] \
               && [ "${pipe_status[4]}" -eq 0 ]; then
                if ! mv -f "${BLOCK_LIST_MONTH}.tmp" "$BLOCK_LIST_MONTH"; then
                    log "WARNING: cannot publish monthly list, month cleared -alert"
                    rm -f "${BLOCK_LIST_MONTH}.tmp"
                    clear_list "$BLOCK_LIST_MONTH"
                fi
            else
                log "WARNING: cannot build monthly list, month cleared -alert"
                rm -f "${BLOCK_LIST_MONTH}.tmp"
                : > "$BLOCK_LIST_MONTH"
            fi
        fi
    fi
fi

month_count=$(wc -l < "$BLOCK_LIST_MONTH" 2>/dev/null || echo 0)
if [ "$month_count" -gt 0 ]; then
    log "INFO: Monthly Blocked:"
    sed 's/^/ /' "$BLOCK_LIST_MONTH" | tee -a "$log_file"
else
    log "INFO: No monthly blocks"
fi

# ------------------------------------------------------------------------------
# IPSET RULES
# ------------------------------------------------------------------------------

log "Running Ipset/Iptables Rules..."
# Every preparation step decides whether the new set may be published. A
# failed create or flush leaves bandata_new holding the previous contents,
# and swapping that in would reinstate blocks that are no longer current.
load_failed=$list_failed
ipset -! create bandata hash:net family inet hashsize 1024 maxelem 65536 || {
    load_failed=1
    log "WARNING: cannot create ipset 'bandata' -alert"
}
ipset -! create bandata_new hash:net family inet hashsize 1024 maxelem 65536 || {
    load_failed=1
    log "WARNING: cannot create ipset 'bandata_new' -alert"
}
ipset -! flush bandata_new || {
    load_failed=1
    log "WARNING: cannot flush ipset 'bandata_new' -alert"
}

# FORWARDING
# Enable IPv4 packet forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

# Load IPs to bandata_new
if ! all_bans=$(
    {
        for block_list in "$BLOCK_LIST_DAY" "$BLOCK_LIST_WEEK" "$BLOCK_LIST_MONTH"; do
            if [ ! -e "$block_list" ]; then
                log "WARNING: $(basename "$block_list") is missing" >&2
                exit 1
            elif [ ! -f "$block_list" ]; then
                log "WARNING: $(basename "$block_list") is not a regular file" >&2
                exit 1
            elif [ ! -r "$block_list" ]; then
                log "WARNING: $(basename "$block_list") is not readable" >&2
                exit 1
            fi
            cat -- "$block_list"
            read_status=$?
            if [ "$read_status" -ne 0 ]; then
                log "WARNING: cannot read $(basename "$block_list"); cat exit $read_status" >&2
                exit 1
            fi
        done
    } | $sort_ips | uniq
    read_status=("${PIPESTATUS[@]}")
    if [ "${read_status[1]}" -ne 0 ]; then
        log "WARNING: quota IP sort failed; sort exit ${read_status[1]}" >&2
    fi
    if [ "${read_status[2]}" -ne 0 ]; then
        log "WARNING: quota IP deduplication failed; uniq exit ${read_status[2]}" >&2
    fi
    (( read_status[0] == 0 && read_status[1] == 0 && read_status[2] == 0 ))
); then
    all_bans=""
    load_failed=1
fi

if [ -n "$all_bans" ]; then
    for banned_ip in $all_bans; do
        [[ "$banned_ip" =~ $UH_IPV4 ]] || { log "WARNING: not an IPv4 '$banned_ip' -alert"; continue; }
        ipset -exist add bandata_new "$banned_ip" || {
            load_failed=1
            log "WARNING: cannot add '$banned_ip' to bandata_new -alert"
        }
    done
fi

# Atomic swap: bandata_new replaces bandata with no window of empty set.
# A client must not stay blocked because of a script or kernel failure.
# When the new set cannot be published, every block is cleared instead.
if [ "$load_failed" -ne 0 ]; then
    log "WARNING: clearing all Bandata quota blocks -alert"
    ipset flush bandata 2>/dev/null || true
    ipset destroy bandata_new 2>/dev/null || true
elif ipset swap bandata_new bandata; then
    ipset destroy bandata_new
else
    log "WARNING: cannot activate new set, all blocks cleared -alert"
    ipset flush bandata 2>/dev/null || true
    ipset destroy bandata_new 2>/dev/null || true
fi

log "Applying Iptables Rules..."

# Add a rule only when it is not there yet, and remember any failure. Without
# this the script reported "bandata done" and exit zero even when no rule
# could be applied, which reads exactly like a successful run.
rules_failed=0
iptables_rule() {
    iptables -C "$@" 2>/dev/null && return 0
    if ! iptables -A "$@"; then
        rules_failed=1
        log "WARNING: cannot apply rule: iptables -A $* -alert"
    fi
}

# -C takes no position number but -I does, so the chain and the rule are
# passed apart and each form is built here.
iptables_insert() {
    local table=""
    if [ "$1" = "-t" ]; then table="$1 $2"; shift 2; fi
    local chain="$1"; shift
    # shellcheck disable=SC2086
    iptables $table -C "$chain" "$@" 2>/dev/null && return 0
    # shellcheck disable=SC2086
    if ! iptables $table -I "$chain" 1 "$@"; then
        rules_failed=1
        log "WARNING: cannot apply rule: iptables $table -I $chain 1 $* -alert"
    fi
}

# Create dedicated chains if they don't exist. A second run finds them
# already there, so only a real creation failure is worth reporting.
for bandata_chain in BANDATA_FWD BANDATA_IN; do
    iptables -L "$bandata_chain" -n >/dev/null 2>&1 ||         iptables -N "$bandata_chain" || {
            rules_failed=1
            log "WARNING: cannot create chain $bandata_chain -alert"
        }
done

# Jump into dedicated chains from FORWARD/INPUT position 1
iptables_insert FORWARD -i "$LAN" -j BANDATA_FWD

iptables_insert INPUT -i "$LAN" -j BANDATA_IN

# Populate BANDATA_FWD (order matters within this chain only)
iptables_rule BANDATA_FWD -m set --match-set bandata src -p udp --dport 53 -j ACCEPT

iptables_rule BANDATA_FWD -m set --match-set bandata src -p tcp --dport 80 -j ACCEPT

iptables_rule BANDATA_FWD -m set --match-set bandata src -j DROP

# Populate BANDATA_IN
iptables_rule BANDATA_IN -m set --match-set bandata src -p tcp --dport "$WARNING_PORT" -j ACCEPT

iptables_rule BANDATA_IN -m set --match-set bandata src -j DROP

# NAT redirect (PREROUTING is unaffected by the chain restructure)
iptables_insert -t nat PREROUTING -i "$LAN" -m set --match-set bandata src -p tcp --dport 80 -j REDIRECT --to-port "$WARNING_PORT"

# ------------------------------------------------------------------------------
# WARNING PAGE
# ------------------------------------------------------------------------------

# Sync quota values from proxymon.env into warning.html
# Values are delimited by HTML comments: <!-- bw-day --> ... <!-- /bw-day -->
if [ -f "$WARNING_HTML" ]; then
    sed -i \
        -e "s#<!-- bw-day -->[^<]*<!-- /bw-day -->#<!-- bw-day -->${MAX_BANDWIDTH_DAY}<!-- /bw-day -->#" \
        -e "s#<!-- bw-week -->[^<]*<!-- /bw-week -->#<!-- bw-week -->${MAX_BANDWIDTH_WEEK}<!-- /bw-week -->#" \
        -e "s#<!-- bw-month -->[^<]*<!-- /bw-month -->#<!-- bw-month -->${MAX_BANDWIDTH_MONTH}<!-- /bw-month -->#" \
        "$WARNING_HTML"
fi

# Generates realname.cfg and skipuser.cfg for Squidreports reports.
# ACL format expected: a;MAC;IP;HOSTNAME;
# Output format: "IP HOSTNAME"
update_squidreports_realname() {
    # Files to exclude from realname.cfg (sent to skipuser.cfg instead).
    # Use filenames only, space-separated. Empty string disables exclusion.
    local excluded_acls="mac-unlimited.txt"

    # Extract "IP HOSTNAME" from ACL line "a;MAC;IP;HOSTNAME;"
    extract_ip_hostname() {
        awk -F';' -v re="${UH_IPV4//\\./\\\\.}" 'NF >= 4 && $3 ~ re {print $3, $4}'
    }

    # Check if a basename matches the exclude list (exact match, no regex)
    is_excluded() {
        local candidate_name="$1"
        local excluded_name
        for excluded_name in $excluded_acls; do
            [ "$candidate_name" = "$excluded_name" ] && return 0
        done
        return 1
    }

    process_hotspot() {
        local hotspot_acl="$HOTSPOT_PATH/acl/uhm-auth.txt"
        if [ ! -f "$hotspot_acl" ]; then
            # stdout of this function is captured and ends up in realname.cfg,
            # so the diagnostic goes to stderr and never reaches that file
            log "WARNING: $(basename "$hotspot_acl") not found -alert" >&2
            return
        fi
        awk -F';' -v re="${UH_IPV4//\\./\\\\.}" \
            '$1 == "a" && NF >= 4 && $3 ~ re {print $3, $4}' "$hotspot_acl"
    }

    # /etc/hosts entries (loopback and the server's own IP) generate proxy
    # traffic and would otherwise be reported as Squidreports users.
    process_hosts() {
        local host_ip host_name rest_of_line
        while read -r host_ip host_name rest_of_line; do
            case "$host_ip" in ""|\#*) continue ;; esac
            [[ "$host_ip" =~ $UH_IPV4 ]] || continue
            [ -n "$host_name" ] && printf '%s %s\n' "$host_ip" "$host_name"
        done < /etc/hosts
    }

    process_acls() {
        local filter_mode="$1" # "include" or "exclude"
        local mac_file
        find "$ACL_MAC_PATH" -maxdepth 1 -type f -iname 'mac-*' | while read -r mac_file; do
            local base_name
            base_name=$(basename "$mac_file")
            if [ "$filter_mode" = "include" ]; then
                is_excluded "$base_name" && continue
            else
                is_excluded "$base_name" || continue
            fi
            extract_ip_hostname < "$mac_file"
        done
    }

    local sort_uniq="sort -u -t . -k 1,1n -k 2,2n -k 3,3n -k 4,4n"
    local hotspot_out="" acl_out skip_out

    if [ "$BANDATA_HOTSPOT" = true ]; then
        hotspot_out=$(process_hotspot)
    fi
    acl_out=$(process_acls include)
    skip_out=$(process_acls exclude)

    local final_output skip_output cfg_tmp
    final_output=$(printf "%s\n%s\n" "$hotspot_out" "$acl_out" | sed '/^$/d' | $sort_uniq)
    skip_output=$(printf "%s\n%s\n" "$skip_out" "$(process_hosts)" | sed '/^$/d' | $sort_uniq)

    # Squidreports reads both files from its own directory, which belongs to
    # www-data. Staging through mktemp keeps this root write on a name no
    # other user can reach, and the mv replaces the target name as a whole.
    if [ -z "$final_output" ]; then
        log "INFO: No MAC data processed for realname.cfg"
    else
        cfg_tmp=$(mktemp)
        if ! { echo "$final_output" > "$cfg_tmp" && chmod 644 "$cfg_tmp" \
            && mv -f "$cfg_tmp" "$REALNAME_CFG"; }; then
            rm -f "$cfg_tmp"
            log "WARNING: cannot update realname.cfg -alert"
        fi
    fi

    if [ -z "$skip_output" ]; then
        log "INFO: No excluded data for skipuser.cfg"
    else
        cfg_tmp=$(mktemp)
        if ! { echo "$skip_output" > "$cfg_tmp" && chmod 644 "$cfg_tmp" \
            && mv -f "$cfg_tmp" "$SKIPUSERS_CFG"; }; then
            rm -f "$cfg_tmp"
            log "WARNING: cannot update skipuser.cfg -alert"
        fi
    fi
}

update_squidreports_groups() {
    local limited_acl="$ACL_MAC_PATH/mac-limited.txt"
    local hotspot_acl="$HOTSPOT_PATH/acl/uhm-auth.txt"
    local group_cfg="$SQUIDREPORTS_DIR/group.cfg"
    local cfg_tmp acl_file group_id group_name

    cfg_tmp=$(mktemp) || {
        log "WARNING: cannot stage group.cfg -alert"
        return 1
    }
    for group_id in 01 02; do
        if [ "$group_id" = 01 ]; then
            acl_file="$limited_acl"
            group_name=limited
        else
            [ "$BANDATA_HOTSPOT" = true ] || continue
            acl_file="$hotspot_acl"
            group_name=hotspot
        fi
        if [ ! -f "$acl_file" ]; then
            log "WARNING: $(basename "$acl_file") not found -alert"
            continue
        fi
        if ! awk -F';' -v re="${UH_IPV4//\\./\\\\.}" \
            -v id="$group_id" -v name="$group_name" \
            '$1 == "a" && NF >= 4 && $3 ~ re {print $3, id, name}' \
            "$acl_file" >> "$cfg_tmp"; then
            rm -f -- "$cfg_tmp"
            log "WARNING: cannot read groups from $(basename "$acl_file") -alert"
            return 1
        fi
    done
    if sort -u -o "$cfg_tmp" "$cfg_tmp" && chmod 644 "$cfg_tmp" \
        && mv -f -- "$cfg_tmp" "$group_cfg"; then
        log "INFO: group.cfg updated"
    else
        rm -f -- "$cfg_tmp"
        log "WARNING: cannot update group.cfg -alert"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# UPDATE
# ------------------------------------------------------------------------------

if [ "$UPDATE_REALNAME" = true ]; then
    update_squidreports_realname
    update_squidreports_groups
fi

# ------------------------------------------------------------------------------
# END
# ------------------------------------------------------------------------------

# A run that could not publish the set or apply its rules did not do its
# job, and must not look like one that did.
if [ "${load_failed:-0}" -ne 0 ] || [ "${rules_failed:-0}" -ne 0 ]; then
    # A rule failure leaves the set loaded, and rules from an earlier run may
    # still read it. The set is emptied, as the load failure already does.
    if [ "${rules_failed:-0}" -ne 0 ]; then
        ipset flush bandata 2>/dev/null \
            || log "WARNING: cannot clear ipset 'bandata' -alert"
    fi
    log "ERROR: cannot apply data quotas -abort"
    exit 1
fi

if active_bans=$(ipset list bandata 2>/dev/null); then
    active_ban_count=$(printf '%s\n' "$active_bans" | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {count++} END {print count+0}')
    log "INFO: Quota rules applied; blocked IPs: $active_ban_count"
else
    log "WARNING: cannot read bandata; block count unavailable -alert"
fi

log "bandata done at: $(date '+%Y-%m-%d %H:%M:%S')"
