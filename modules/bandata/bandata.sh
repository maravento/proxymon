#!/bin/bash
# maravento.com
#
################################################################################
#
# Bandata for Squid Reports
# Data Plan for LAN
#
# Instructions:
# Configuration is read from /etc/proxymon/proxymon.env (generated during installation)
# Log output: /var/log/bandata.log
# Default limits: max 1G day / 5G week / 20G month
# Limits can use M, G or B suffix (e.g. 500M, 1G, 1.5G)
# bandata excludes weekends
#
# NOTE on skipuser.cfg:
# - Rebuilt on every run from mac-transparent.txt/mac-unlimited.txt plus every
# IPv4 entry found in /etc/hosts, so the proxy host's own traffic (loopback
# and the server itself) is never listed as a LightSquid user.
# - The server IP MUST have an entry in /etc/hosts with its hostname. Without
# it, the server's own proxy traffic is reported and counted against the
# bandwidth limits like any LAN client.
# - Manual edits to skipuser.cfg do not survive: the file is regenerated here.
#
# NOTE on logging:
# - Writes to /var/log/bandata.log (log + screen via tee). Rotation is
# handled by this script itself: it self-installs /etc/logrotate.d/bandata
# on first run (see below), so no manual truncate is needed.
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
for dep_pkg in ipset findutils coreutils iptables util-linux mawk sed grep procps logrotate; do
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
    log "Created logrotate config: $logrotate_conf"
fi

# ------------------------------------------------------------------------------
# ENV
# ------------------------------------------------------------------------------

proxymon_env="/etc/proxymon/proxymon.env"
if [ ! -f "$proxymon_env" ]; then
    log "ERROR: $proxymon_env not found. Run install to generate it."
    exit 1
fi
env_owner=$(stat -c '%U' "$proxymon_env" 2>/dev/null)
env_perms=$(stat -c '%a' "$proxymon_env" 2>/dev/null)
env_group_digit="${env_perms: -2:1}"
env_other_digit="${env_perms: -1}"
if [ "$env_owner" != "root" ] || [[ "$env_group_digit" =~ [2367] ]] || [[ "$env_other_digit" =~ [2367] ]]; then
    log "ERROR: $proxymon_env has unsafe owner/permissions (owner=$env_owner perms=$env_perms)."
    log "Expected owner root, no group/other write -- abort"
    exit 1
fi
# shellcheck source=/etc/proxymon/proxymon.env
source "$proxymon_env"

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

# validation -- one variable per thing validated; use directly with =~
UH_OCT='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_IPV4='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_CIDR='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])/(3[0-2]|[12][0-9]|[0-9])$'
UH_NETMASK='^(0\.0\.0\.0|128\.0\.0\.0|192\.0\.0\.0|224\.0\.0\.0|240\.0\.0\.0|248\.0\.0\.0|252\.0\.0\.0|254\.0\.0\.0|255\.0\.0\.0|255\.128\.0\.0|255\.192\.0\.0|255\.224\.0\.0|255\.240\.0\.0|255\.248\.0\.0|255\.252\.0\.0|255\.254\.0\.0|255\.255\.0\.0|255\.255\.128\.0|255\.255\.192\.0|255\.255\.224\.0|255\.255\.240\.0|255\.255\.248\.0|255\.255\.252\.0|255\.255\.254\.0|255\.255\.255\.0|255\.255\.255\.128|255\.255\.255\.192|255\.255\.255\.224|255\.255\.255\.240|255\.255\.255\.248|255\.255\.255\.252|255\.255\.255\.254|255\.255\.255\.255)$'
UH_DNS='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])(,(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9]))*$'
UH_UINT='^(0|[1-9][0-9]*)$'
UH_FQDN='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
UH_MAC_RE='([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'
UH_MAC="^${UH_MAC_RE}$"
UH_PREFIX='0.0.0.0:0 128.0.0.0:1 192.0.0.0:2 224.0.0.0:3 240.0.0.0:4 248.0.0.0:5 252.0.0.0:6 254.0.0.0:7 255.0.0.0:8 255.128.0.0:9 255.192.0.0:10 255.224.0.0:11 255.240.0.0:12 255.248.0.0:13 255.252.0.0:14 255.254.0.0:15 255.255.0.0:16 255.255.128.0:17 255.255.192.0:18 255.255.224.0:19 255.255.240.0:20 255.255.248.0:21 255.255.252.0:22 255.255.254.0:23 255.255.255.0:24 255.255.255.128:25 255.255.255.192:26 255.255.255.224:27 255.255.255.240:28 255.255.255.248:29 255.255.255.252:30 255.255.255.254:31 255.255.255.255:32'

log "bandata start..."

# ------------------------------------------------------------------------------
# FUNTIONS
# ------------------------------------------------------------------------------

# Self-heal: remove orphaned .tmp files left by a previous run that failed
# between the write and the mv (no -e/trap in this script to catch that).
for stale_file in "$BLOCK_LIST_DAY.tmp" "$BLOCK_LIST_WEEK.tmp" "$BLOCK_LIST_MONTH.tmp" "$REALNAME_CFG.tmp" "$SKIPUSERS_CFG.tmp"; do
    if [ -f "$stale_file" ]; then
        log "WARNING: removing orphaned $(basename "$stale_file") -- alert"
        rm -f "$stale_file"
    fi
done

# Validate LAN interface -- required for all iptables rules below
if [ -z "$LAN" ]; then
    log "ERROR: LAN is empty in $proxymon_env"
    exit 1
fi
if [ ! -e "/sys/class/net/$LAN" ]; then
    log "ERROR: interface '$LAN' does not exist -- abort"
    log "Available interfaces: $(ls /sys/class/net 2>/dev/null | tr '\n' ' ')"
    exit 1
fi

# today
today_dow=$(date +"%u")
# reorganize IP
sort_ips="sort -t . -k 1,1n -k 2,2n -k 3,3n -k 4,4n"
# BANDWIDTH LIMITS VALIDATION
# Convert and validate MAX_BANDWIDTH_* before any comparison is made.
# If numfmt fails (empty/invalid value), abort instead of silently
# treating the limit as 0, which would block the entire network.
max_bw_day=$(LC_ALL=C numfmt --from=iec "${MAX_BANDWIDTH_DAY/,/.}" 2>/dev/null)
if [ -z "$max_bw_day" ]; then
    log "ERROR: invalid MAX_BANDWIDTH_DAY value in $proxymon_env: '${MAX_BANDWIDTH_DAY}'"
    log "Expected format: 500M, 1G, 1.5G"
    exit 1
fi

max_bw_week=$(LC_ALL=C numfmt --from=iec "${MAX_BANDWIDTH_WEEK/,/.}" 2>/dev/null)
if [ -z "$max_bw_week" ]; then
    log "ERROR: invalid MAX_BANDWIDTH_WEEK value in $proxymon_env: '${MAX_BANDWIDTH_WEEK}'"
    log "Expected format: 500M, 1G, 1.5G"
    exit 1
fi

max_bw_month=$(LC_ALL=C numfmt --from=iec "${MAX_BANDWIDTH_MONTH/,/.}" 2>/dev/null)
if [ -z "$max_bw_month" ]; then
    log "ERROR: invalid MAX_BANDWIDTH_MONTH value in $proxymon_env: '${MAX_BANDWIDTH_MONTH}'"
    log "Expected format: 500M, 1G, 1.5G"
    exit 1
fi

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

log "Running Bandata Day..."

# path to day report
day_logs_dir=$REPORT_PATH/$(date +"%Y%m%d")
# bandata day rule
if [[ "$today_dow" -eq 6 || "$today_dow" -eq 7 ]]; then
    log "Weekend Excluded"
    : > "$BLOCK_LIST_DAY"
else
    if [ ! -d "$day_logs_dir" ]; then
        log "Day report folder not found: $day_logs_dir"
        : > "$BLOCK_LIST_DAY"
    else
        tmp_day=$(mktemp)
        subshell_ok=0
        (
            cd "$day_logs_dir" || { log "ERROR: cannot cd into $day_logs_dir" >&2; exit 1; }
            shopt -s nullglob
            for report_file in $REPORT_IP_GLOB; do
                user_bytes=$(awk '$1=="total:" {print $2}' "$report_file")
                if [[ "$user_bytes" =~ $UH_UINT ]] && (( user_bytes > max_bw_day )); then
                    echo "$report_file"
                elif [ -n "$user_bytes" ] && ! [[ "$user_bytes" =~ $UH_UINT ]]; then
                    log "WARNING: non-numeric total '$user_bytes' in $day_logs_dir/$report_file -- skipping" >&2
                fi
            done
            exit 0
        ) > "$tmp_day" && subshell_ok=1

        if [ "$subshell_ok" -eq 1 ]; then
            grep -wvFf <(grep -v '^[[:space:]]*$' "$ALLOW_LIST") "$tmp_day" | $sort_ips | uniq > "${BLOCK_LIST_DAY}.tmp"
            if [ "${PIPESTATUS[0]}" -le 1 ]; then
                mv -f "${BLOCK_LIST_DAY}.tmp" "$BLOCK_LIST_DAY"
            else
                log "ERROR: cannot build daily block list -- keeping existing"
                rm -f "${BLOCK_LIST_DAY}.tmp"
            fi
        else
            log "ERROR: subshell failed for $day_logs_dir -- keeping existing block list"
        fi
        rm -f "$tmp_day"
    fi

    day_count=$(wc -l < "$BLOCK_LIST_DAY" 2>/dev/null || echo 0)
    if [ "$day_count" -gt 0 ]; then
        log "Daily Blocked:"
        sed 's/^/ /' "$BLOCK_LIST_DAY" | tee -a "$log_file"
    else
        log "No daily blocks"
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
        day_dir="$REPORT_PATH/$(date -d "last monday +$weekday_offset days" +'%Y%m%d')"
        [ -d "$day_dir" ] && week_dirs+=("$day_dir")
    done

    if [ ${#week_dirs[@]} -eq 0 ]; then
        log "No weekday report folders found for last week"
        : > "$BLOCK_LIST_WEEK"
    else
        report_files=$(find "${week_dirs[@]}" -maxdepth 1 -type f -name "$REPORT_IP_GLOB")
        user_totals=$(echo "$report_files" | xargs -r -I {} awk '/^total:/{sub(".*/", "", FILENAME); print FILENAME" "$NF}' {})
        over_limit_ips=$(echo "$user_totals" | awk '{ arr[$1]+=$2 } END { for (key in arr) printf("%s\t%s\n", arr[key], key) }' | sort -k1,1)
        echo "$over_limit_ips" | awk -v max="$max_bw_week" '$1 > max {print $2}' | grep -wvFf <(grep -v '^[[:space:]]*$' "$ALLOW_LIST") | $sort_ips | uniq > "${BLOCK_LIST_WEEK}.tmp"
        if [ "${PIPESTATUS[2]}" -le 1 ]; then
            mv -f "${BLOCK_LIST_WEEK}.tmp" "$BLOCK_LIST_WEEK"
        else
            log "ERROR: cannot build weekly block list -- keeping existing"
            rm -f "${BLOCK_LIST_WEEK}.tmp"
        fi
    fi

    week_count=$(wc -l < "$BLOCK_LIST_WEEK" 2>/dev/null || echo 0)
    if [ "$week_count" -gt 0 ]; then
        log "Weekly Blocked:"
        sed 's/^/ /' "$BLOCK_LIST_WEEK" | tee -a "$log_file"
    else
        log "No weekly blocks"
    fi
else
    log "Weekly check runs on Monday only"
fi

# ------------------------------------------------------------------------------
# BANDAY
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
    log "No weekday report folders found for current month"
    : > "$BLOCK_LIST_MONTH"
else
    report_files=$(find "${month_dirs[@]}" -maxdepth 1 -type f -name "$REPORT_IP_GLOB")
    user_totals=$(echo "$report_files" | xargs -r -I {} awk '/^total:/{sub(".*/", "", FILENAME); print FILENAME" "$NF}' {})
    over_limit_ips=$(echo "$user_totals" | awk '{ arr[$1]+=$2 } END { for (key in arr) printf("%s\t%s\n", arr[key], key) }' | sort -k1,1)
    echo "$over_limit_ips" | awk -v max="$max_bw_month" '$1 > max {print $2}' | grep -wvFf <(grep -v '^[[:space:]]*$' "$ALLOW_LIST") | $sort_ips | uniq > "${BLOCK_LIST_MONTH}.tmp"
    if [ "${PIPESTATUS[2]}" -le 1 ]; then
        mv -f "${BLOCK_LIST_MONTH}.tmp" "$BLOCK_LIST_MONTH"
    else
        log "ERROR: cannot build monthly block list -- keeping existing"
        rm -f "${BLOCK_LIST_MONTH}.tmp"
    fi
fi

month_count=$(wc -l < "$BLOCK_LIST_MONTH" 2>/dev/null || echo 0)
if [ "$month_count" -gt 0 ]; then
    log "Monthly Blocked:"
    sed 's/^/ /' "$BLOCK_LIST_MONTH" | tee -a "$log_file"
else
    log "No monthly blocks"
fi

# ------------------------------------------------------------------------------
# IPSET/IPTABLES FOR BANDATA
# ------------------------------------------------------------------------------

log "Running Ipset/Iptables Rules..."
ipset -! create bandata hash:net family inet hashsize 1024 maxelem 65536
ipset -! create bandata_new hash:net family inet hashsize 1024 maxelem 65536
ipset -! flush bandata_new

# NAT
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

# Load IPs to bandata_new
all_bans=$(cat "$BLOCK_LIST_DAY" "$BLOCK_LIST_WEEK" "$BLOCK_LIST_MONTH" | $sort_ips | uniq)

if [ -n "$all_bans" ]; then
    for banned_ip in $all_bans; do
        ipset -exist add bandata_new "$banned_ip"
    done
fi

# Atomic swap: bandata_new replaces bandata with no window of empty set
if ipset swap bandata_new bandata; then
    ipset destroy bandata_new
else
    log "ERROR: ipset swap failed, bandata not updated -- alert"
fi

if [ -n "$all_bans" ]; then
    log "FINAL BAN SUMMARY:"
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
        log "$banned_ip [$ban_period]"
    done
else
    log "There are no IPs in bandata"
fi

log "Applying Iptables Rules..."

# Create dedicated chains if they don't exist
iptables -N BANDATA_FWD 2>/dev/null
iptables -N BANDATA_IN 2>/dev/null

# Jump into dedicated chains from FORWARD/INPUT position 1
iptables -C FORWARD -i "$LAN" -j BANDATA_FWD 2>/dev/null || \
iptables -I FORWARD 1 -i "$LAN" -j BANDATA_FWD

iptables -C INPUT -i "$LAN" -j BANDATA_IN 2>/dev/null || \
iptables -I INPUT 1 -i "$LAN" -j BANDATA_IN

# Populate BANDATA_FWD (order matters within this chain only)
iptables -C BANDATA_FWD -m set --match-set bandata src -p udp --dport 53 -j ACCEPT 2>/dev/null || \
iptables -A BANDATA_FWD -m set --match-set bandata src -p udp --dport 53 -j ACCEPT

iptables -C BANDATA_FWD -m set --match-set bandata src -p tcp --dport 80 -j ACCEPT 2>/dev/null || \
iptables -A BANDATA_FWD -m set --match-set bandata src -p tcp --dport 80 -j ACCEPT

iptables -C BANDATA_FWD -m set --match-set bandata src -j DROP 2>/dev/null || \
iptables -A BANDATA_FWD -m set --match-set bandata src -j DROP

# Populate BANDATA_IN
iptables -C BANDATA_IN -m set --match-set bandata src -p tcp --dport 18081 -j ACCEPT 2>/dev/null || \
iptables -A BANDATA_IN -m set --match-set bandata src -p tcp --dport 18081 -j ACCEPT

iptables -C BANDATA_IN -m set --match-set bandata src -j DROP 2>/dev/null || \
iptables -A BANDATA_IN -m set --match-set bandata src -j DROP

# NAT redirect (PREROUTING is unaffected by the chain restructure)
iptables -t nat -C PREROUTING -i "$LAN" -m set --match-set bandata src -p tcp --dport 80 -j REDIRECT --to-port 18081 2>/dev/null || \
iptables -t nat -I PREROUTING 1 -i "$LAN" -m set --match-set bandata src -p tcp --dport 80 -j REDIRECT --to-port 18081

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

# Generates realname.cfg and skipuser.cfg for Lightsquid reports.
# ACL format expected: a;MAC;IP;HOSTNAME;
# Output format: "IP HOSTNAME"
update_lightsquid_realname() {
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
            log "WARNING: $(basename "$hotspot_acl") not found -- skip"
            return
        fi
        awk -F';' '$1 == "a" && NF >= 4 {print $3, $4}' "$hotspot_acl"
    }

    # /etc/hosts entries (loopback and the server's own IP) generate proxy
    # traffic and would otherwise be reported as LightSquid users.
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

    local final_output skip_output
    final_output=$(printf "%s\n%s\n" "$hotspot_out" "$acl_out" | sed '/^$/d' | $sort_uniq)
    skip_output=$(printf "%s\n%s\n" "$skip_out" "$(process_hosts)" | sed '/^$/d' | $sort_uniq)

    if [ -z "$final_output" ]; then
        log "No MAC data processed for realname.cfg"
    else
        echo "$final_output" > "${REALNAME_CFG}.tmp" && mv -f "${REALNAME_CFG}.tmp" "$REALNAME_CFG"
    fi

    if [ -z "$skip_output" ]; then
        log "No excluded data for skipuser.cfg"
    else
        echo "$skip_output" > "${SKIPUSERS_CFG}.tmp" && mv -f "${SKIPUSERS_CFG}.tmp" "$SKIPUSERS_CFG"
    fi
}

# ------------------------------------------------------------------------------
# UPDATE
# ------------------------------------------------------------------------------

if [[ "${UPDATE_REALNAME:-false}" == "true" ]]; then
    update_lightsquid_realname
fi

# ------------------------------------------------------------------------------
# END
# ------------------------------------------------------------------------------

log "bandata done at: $(date)"
