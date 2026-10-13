#!/bin/bash
# maravento.com
#
################################################################################
#
# bandata -- data usage limits for proxymon
#
# DESCRIPTION:
# Applies the data quotas to the LAN addresses Squid reports, and blocks
# the ones over quota. Updates Squidreports names and ACL groups. Requires root.
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

# logging
log_file="/var/log/bandata.log"
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
for dep_pkg in ipset findutils coreutils iptables util-linux sed grep procps logrotate; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        log "ERROR: dependency '$dep_pkg' is not installed -- abort"
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
    chmod 644 "$logrotate_conf"
    chown root:root "$logrotate_conf"
    log "INFO: logrotate config created for $(basename "$log_file") -- fixed"
fi

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

# validation -- one variable per thing validated; use directly with =~
UH_IPV4='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_UINT='^(0|[1-9][0-9]*)$'

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
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../tools/proxymonenv.sh"

# LOAD
load_proxymon_env "$proxymon_env" || { log "ERROR: cannot load proxymon.env -- abort"; exit 1; }

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
    elif [ "$env_key" = WARNING_PORT ] && { ! [[ "${!env_key}" =~ ^[1-9][0-9]{0,4}$ ]] || (( ${!env_key} > 65535 )); }; then
        key_errors+=("$env_key invalid port")
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
    elif [[ -z "$(LC_ALL=C numfmt --from=iec "${!env_key/,/.}" 2>/dev/null)" ]]; then
        key_errors+=("$env_key invalid size, expected 500M, 1G or 1.5G")
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

# KEY GUARD
# Each key above is valid on its own. These two relations are not.
if [ ! -e "/sys/class/net/$LAN" ]; then
    log "ERROR: interface '$LAN' does not exist -- abort"
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
        log "WARNING: removing orphaned $(basename "$stale_file") -- alert"
        rm -f "$stale_file"
    fi
done

# today
today_dow=$(date +"%u")
# reorganize IP
sort_ips="sort -t . -k 1,1n -k 2,2n -k 3,3n -k 4,4n"
# FILESYSTEM LAYOUT
# Create folders if they don't exist
[ -d "$ACL_PATH" ] || mkdir -p "$ACL_PATH"
[ -d "$ACL_MAC_PATH" ] || mkdir -p "$ACL_MAC_PATH"
[ -d "$ACL_BANDATA_PATH" ] || mkdir -p "$ACL_BANDATA_PATH"
# Create ACL files if they don't exist
touch "$ALLOW_LIST" "$BLOCK_LIST_DAY" "$BLOCK_LIST_WEEK" "$BLOCK_LIST_MONTH"

if [ "$BANDATA_HOTSPOT" = true ] && [ ! -d "$HOTSPOT_PATH" ]; then
    log "ERROR: BANDATA_HOTSPOT=true but $HOTSPOT_PATH does not exist"
    log "ERROR: install uhm or set BANDATA_HOTSPOT=false -- abort"
    exit 1
fi

# ------------------------------------------------------------------------------
# BANDAY
# ------------------------------------------------------------------------------

log "INFO: Running Bandata Day..."

# path to day report
day_logs_dir=$REPORT_PATH/$(date +"%Y%m%d")
# bandata day rule
if [[ "$today_dow" -eq 6 || "$today_dow" -eq 7 ]]; then
    log "INFO: Weekend Excluded"
    : > "$BLOCK_LIST_DAY"
else
    if [ ! -d "$day_logs_dir" ]; then
        log "INFO: day report folder $(basename "$day_logs_dir") not found -- skip"
        : > "$BLOCK_LIST_DAY"
    else
        tmp_day=$(mktemp)
        subshell_ok=0
        (
            cd "$day_logs_dir" || { log "WARNING: cannot cd into $day_logs_dir -- alert" >&2; exit 1; }
            shopt -s nullglob
            for report_file in $REPORT_IP_GLOB; do
                user_bytes=$(awk '$1=="total:" {print $2}' "$report_file")
                if [[ "$user_bytes" =~ $UH_UINT ]] && (( user_bytes > max_bw_day )); then
                    echo "$report_file"
                elif [ -n "$user_bytes" ] && ! [[ "$user_bytes" =~ $UH_UINT ]]; then
                    log "WARNING: non-numeric total '$user_bytes' in $report_file -- alert" >&2
                fi
            done
            exit 0
        ) > "$tmp_day" && subshell_ok=1

        if [ "$subshell_ok" -eq 1 ]; then
            grep -wvFf <(grep -v '^[[:space:]]*$' "$ALLOW_LIST") "$tmp_day" | $sort_ips | uniq > "${BLOCK_LIST_DAY}.tmp"
            pipe_status=("${PIPESTATUS[@]}")
            if [ "${pipe_status[0]}" -le 1 ] && [ "${pipe_status[1]}" -eq 0 ] && [ "${pipe_status[2]}" -eq 0 ]; then
                mv -f "${BLOCK_LIST_DAY}.tmp" "$BLOCK_LIST_DAY"
            else
                log "WARNING: cannot build daily block list -- fallback"
                rm -f "${BLOCK_LIST_DAY}.tmp"
            fi
        else
            log "WARNING: subshell failed for $day_logs_dir -- fallback"
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

log "INFO: Running Bandata Week..."

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
        report_files=$(find "${week_dirs[@]}" -maxdepth 1 -type f -name "$REPORT_IP_GLOB")
        user_totals=$(echo "$report_files" | xargs -r -I {} awk '/^total:/{sub(".*/", "", FILENAME); print FILENAME" "$NF}' {})
        over_limit_ips=$(echo "$user_totals" | awk '{ arr[$1]+=$2 } END { for (key in arr) printf("%s\t%s\n", arr[key], key) }' | sort -k1,1)
        echo "$over_limit_ips" | awk -v max="$max_bw_week" '$1 > max {print $2}' | grep -wvFf <(grep -v '^[[:space:]]*$' "$ALLOW_LIST") | $sort_ips | uniq > "${BLOCK_LIST_WEEK}.tmp"
        pipe_status=("${PIPESTATUS[@]}")
        if [ "${pipe_status[0]}" -eq 0 ] && [ "${pipe_status[1]}" -eq 0 ] \
           && [ "${pipe_status[2]}" -le 1 ] && [ "${pipe_status[3]}" -eq 0 ] \
           && [ "${pipe_status[4]}" -eq 0 ]; then
            mv -f "${BLOCK_LIST_WEEK}.tmp" "$BLOCK_LIST_WEEK"
        else
            log "WARNING: cannot build weekly block list -- fallback"
            rm -f "${BLOCK_LIST_WEEK}.tmp"
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

log "INFO: Running Bandata Month..."

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
    report_files=$(find "${month_dirs[@]}" -maxdepth 1 -type f -name "$REPORT_IP_GLOB")
    user_totals=$(echo "$report_files" | xargs -r -I {} awk '/^total:/{sub(".*/", "", FILENAME); print FILENAME" "$NF}' {})
    over_limit_ips=$(echo "$user_totals" | awk '{ arr[$1]+=$2 } END { for (key in arr) printf("%s\t%s\n", arr[key], key) }' | sort -k1,1)
    echo "$over_limit_ips" | awk -v max="$max_bw_month" '$1 > max {print $2}' | grep -wvFf <(grep -v '^[[:space:]]*$' "$ALLOW_LIST") | $sort_ips | uniq > "${BLOCK_LIST_MONTH}.tmp"
    pipe_status=("${PIPESTATUS[@]}")
    if [ "${pipe_status[0]}" -eq 0 ] && [ "${pipe_status[1]}" -eq 0 ] \
       && [ "${pipe_status[2]}" -le 1 ] && [ "${pipe_status[3]}" -eq 0 ] \
       && [ "${pipe_status[4]}" -eq 0 ]; then
        mv -f "${BLOCK_LIST_MONTH}.tmp" "$BLOCK_LIST_MONTH"
    else
        log "WARNING: cannot build monthly block list -- fallback"
        rm -f "${BLOCK_LIST_MONTH}.tmp"
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
# IPSET/IPTABLES FOR BANDATA
# ------------------------------------------------------------------------------

log "INFO: Running Ipset/Iptables Rules..."
# Every preparation step decides whether the new set may be published. A
# failed create or flush leaves bandata_new holding the previous contents,
# and swapping that in would reinstate blocks that are no longer current.
load_failed=0
ipset -! create bandata hash:net family inet hashsize 1024 maxelem 65536 || {
    load_failed=1
    log "WARNING: cannot create ipset 'bandata' -- alert"
}
ipset -! create bandata_new hash:net family inet hashsize 1024 maxelem 65536 || {
    load_failed=1
    log "WARNING: cannot create ipset 'bandata_new' -- alert"
}
ipset -! flush bandata_new || {
    load_failed=1
    log "WARNING: cannot flush ipset 'bandata_new' -- alert"
}

# NAT
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

# Load IPs to bandata_new
all_bans=$(cat "$BLOCK_LIST_DAY" "$BLOCK_LIST_WEEK" "$BLOCK_LIST_MONTH" | $sort_ips | uniq)

if [ -n "$all_bans" ]; then
    for banned_ip in $all_bans; do
        [[ "$banned_ip" =~ $UH_IPV4 ]] || { log "WARNING: not an IPv4 '$banned_ip' -- alert"; continue; }
        ipset -exist add bandata_new "$banned_ip" || {
            load_failed=1
            log "WARNING: cannot add '$banned_ip' to bandata_new -- alert"
        }
    done
fi

# Atomic swap: bandata_new replaces bandata with no window of empty set.
# A half-loaded set must never be published: swapping it in would silently
# unblock every address that failed to load, so the active set is kept.
if [ "$load_failed" -ne 0 ]; then
    log "WARNING: bandata_new not trustworthy, active blocks left untouched -- alert"
    ipset destroy bandata_new 2>/dev/null || true
elif ipset swap bandata_new bandata; then
    ipset destroy bandata_new
else
    log "WARNING: ipset swap failed, bandata not updated -- alert"
fi

if [ -n "$all_bans" ]; then
    log "INFO: FINAL BAN SUMMARY:"
    ipset list bandata 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | $sort_ips | while IFS= read -r banned_ip; do
        # Check which category this IP belongs to
        if grep -qxF "$banned_ip" "$BLOCK_LIST_DAY" 2>/dev/null; then
            ban_period="DAILY"
        elif grep -qxF "$banned_ip" "$BLOCK_LIST_WEEK" 2>/dev/null; then
            ban_period="WEEKLY"
        elif grep -qxF "$banned_ip" "$BLOCK_LIST_MONTH" 2>/dev/null; then
            ban_period="MONTHLY"
        else
            ban_period="UNKNOWN"
        fi
        log "INFO: $banned_ip [$ban_period]"
    done
else
    log "INFO: There are no IPs in bandata"
fi

log "INFO: Applying Iptables Rules..."

# Add a rule only when it is not there yet, and remember any failure. Without
# this the script reported "bandata done" and exit zero even when no rule
# could be applied, which reads exactly like a successful run.
rules_failed=0
iptables_rule() {
    iptables -C "$@" 2>/dev/null && return 0
    if ! iptables -A "$@"; then
        rules_failed=1
        log "WARNING: cannot apply rule: iptables -A $* -- alert"
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
        log "WARNING: cannot apply rule: iptables $table -I $chain 1 $* -- alert"
    fi
}

# Create dedicated chains if they don't exist. A second run finds them
# already there, so only a real creation failure is worth reporting.
for bandata_chain in BANDATA_FWD BANDATA_IN; do
    iptables -L "$bandata_chain" -n >/dev/null 2>&1 ||         iptables -N "$bandata_chain" || {
            rules_failed=1
            log "WARNING: cannot create chain $bandata_chain -- alert"
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
# WARNING PAGE UPDATE
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
            log "WARNING: $(basename "$hotspot_acl") not found -- alert" >&2
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
        if echo "$final_output" > "$cfg_tmp"; then
            chmod 644 "$cfg_tmp"
            mv -f "$cfg_tmp" "$REALNAME_CFG"
        else
            rm -f "$cfg_tmp"
            log "WARNING: cannot update realname.cfg -- alert"
        fi
    fi

    if [ -z "$skip_output" ]; then
        log "INFO: No excluded data for skipuser.cfg"
    else
        cfg_tmp=$(mktemp)
        if echo "$skip_output" > "$cfg_tmp"; then
            chmod 644 "$cfg_tmp"
            mv -f "$cfg_tmp" "$SKIPUSERS_CFG"
        else
            rm -f "$cfg_tmp"
            log "WARNING: cannot update skipuser.cfg -- alert"
        fi
    fi
}

update_squidreports_groups() {
    local limited_acl="$ACL_MAC_PATH/mac-limited.txt"
    local hotspot_acl="$HOTSPOT_PATH/acl/uhm-auth.txt"
    local group_cfg="$SQUIDREPORTS_DIR/group.cfg"
    local cfg_tmp acl_file group_id group_name

    cfg_tmp=$(mktemp) || {
        log "WARNING: cannot stage group.cfg -- alert"
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
            log "WARNING: $(basename "$acl_file") not found -- alert"
            continue
        fi
        if ! awk -F';' -v re="${UH_IPV4//\\./\\\\.}" \
            -v id="$group_id" -v name="$group_name" \
            '$1 == "a" && NF >= 4 && $3 ~ re {print $3, id, name}' \
            "$acl_file" >> "$cfg_tmp"; then
            rm -f -- "$cfg_tmp"
            log "WARNING: cannot read groups from $(basename "$acl_file") -- alert"
            return 1
        fi
    done
    if sort -u -o "$cfg_tmp" "$cfg_tmp" && chmod 644 "$cfg_tmp" \
        && mv -f -- "$cfg_tmp" "$group_cfg"; then
        log "INFO: group.cfg updated"
    else
        rm -f -- "$cfg_tmp"
        log "WARNING: cannot update group.cfg -- alert"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# UPDATE
# ------------------------------------------------------------------------------

if [[ "${UPDATE_REALNAME:-false}" == "true" ]]; then
    update_squidreports_realname
    update_squidreports_groups
fi

# ------------------------------------------------------------------------------
# END
# ------------------------------------------------------------------------------

# A run that could not publish the set or apply its rules did not do its
# job, and must not look like one that did.
if [ "${load_failed:-0}" -ne 0 ] || [ "${rules_failed:-0}" -ne 0 ]; then
    log "ERROR: cannot apply data quotas -- abort"
    exit 1
fi

log "bandata done at: $(date '+%Y-%m-%d %H:%M:%S')"
