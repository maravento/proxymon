#!/bin/bash
# maravento.com
#
################################################################################
#
# Proxy Monitor (Proxymon) -- install / update / uninstall script
#
# Proxymon bundles Squid bandwidth monitoring (Bandata), LightSquid,
# SARG, SquidAnalyzer and SquidMon behind an Apache web panel, with
# optional Unifi Hotspot integration.
#
# USAGE
# ./pmsetup.sh install Fresh install. Aborts if /var/www/proxymon
# already exists (use update or uninstall
# first -- see below).
# ./pmsetup.sh update Refresh code and permissions under
# /var/www/proxymon. Stops Apache, backs up
# live data, replaces code, restores live
# data, resets permissions, restarts Apache.
# Does not touch Apache/PHP/SARG system
# config, cron, ACL lists, or
# /etc/proxymon/proxymon.env.
# ./pmsetup.sh uninstall Remove Proxymon: Apache sites, cron entries,
# iptables/ipset rules, restore .bak configs.
# Prompts before deleting /etc/proxymon and
# /etc/acl (allowlists, MAC registrations, LLM
# credentials). Bandata's own ACLs live under
# /var/www/proxymon/bandata/acl and are removed
# with the rest of /var/www/proxymon. The SquidAI
# response cache in /var/cache/proxymon is also
# removed.
# ./pmsetup.sh Interactive menu with the same 3 options.
# ./pmsetup.sh -h|--help Show usage.
#
# REQUIREMENTS
# - Run as root.
# - Must be run from a directory containing a populated modules/
# folder -- obtained by cloning the full repository (see check_repo()).
# install and update both read from this local modules/ tree; the
# script itself does not fetch or pull anything from git.
# - System packages from check_dependencies() (squid, apache2, sarg,
# php, zip, etc.) must already be installed.
#
# INSTALL vs UPDATE -- WHAT EACH TOUCHES
# install_proxymon() writes everything from scratch: Apache vhosts and
# Listen directives, /etc/proxymon/proxymon.env (interactive prompts),
# ACL directories/lists (with a fresh download), SARG config and
# usertab, SquidAnalyzer, PHP/Apache hardening (php.ini, security.conf,
# apache2.conf, mpm_prefork.conf), cron entries, the SquidAI response
# cache directory /var/cache/proxymon, and enables the sites.
# Because it prompts for configuration and can overwrite an existing
# setup, it refuses to run if /var/www/proxymon already exists.
#
# update_proxymon() only refreshes code and permissions under
# /var/www/proxymon. It never touches Apache/PHP/SARG system config,
# cron, ACL lists, or proxymon.env, and it never prompts. Sequence:
# 1. Stop Apache (avoid serving a half-swapped tree).
# 2. Archive the live data that isn't part of the modules/ repo tree
# into /etc/bak/proxymon/proxymonbak_<YYYYMMDD_HHMM>.zip.
# 3. cp -rf modules/* into /var/www/proxymon (same method install
# uses).
# 4. Unzip the archive over / , restoring the live data over the
# freshly-copied placeholders.
# 5. Reset permissions/ownership on /var/www/proxymon.
# 6. Restart Apache.
# A maximum of 3 archives is kept in /etc/bak/proxymon. Live data
# preserved:
# - lightsquid/report (daily LightSquid reports)
# - lightsquid/realname.cfg (hostname mappings)
# - lightsquid/skipuser.cfg (excluded users)
# - sarg/squid-reports (SARG rendered reports)
# - squidmon/etc/config (SquidMon config file)
# - squidanalyzer/output (SquidAnalyzer rendered reports)
# - sqstat/config.inc.php (SQStat custom config, e.g. cachemgr credentials)
# - bandata/acl/allowdata.txt (Bandata quota-exempt IP list)
#
################################################################################

set -Euo pipefail
trap 'echo "Error on line $LINENO"; exit 1' ERR

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# root check
if [ "$(id -u)" != "0" ]; then
    echo "ERROR: This script must be run as root -- abort"
    exit 1
fi

# prevent overlapping runs
script_lock="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$script_lock")
exec 200>"$script_lock"

if ! flock -n 200; then
    echo "ERROR: script $(basename "$0") is already running -- abort"
    exit 1
fi

script_dir="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
log_file="${script_dir}/pmsetup.log"
{ > "$log_file"; } 2>/dev/null || true
log() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" | tee -a "$log_file" 2>/dev/null || true
}
info() { printf ' \e[32m \e[0m %s\n' "$*"; log "INFO: $*"; }
warn() { printf ' \e[33m!\e[0m %s\n' "$*"; log "WARNING: $*"; }
err()  { printf ' \e[31m \e[0m %s\n' "$*" >&2; log "ERROR: $*"; }
abort() { err "$*"; exit 1; }

# local_user detection
detect_local_user() {
    local uid_min uid_max
    local user uid best_user="" best_uid=999999

    uid_min=$(awk '/^UID_MIN/{print $2}' /etc/login.defs 2>/dev/null)
    uid_max=$(awk '/^UID_MAX/{print $2}' /etc/login.defs 2>/dev/null)
    uid_min=${uid_min:-1000}
    uid_max=${uid_max:-60000}

    while IFS=: read -r user _ uid _ _ _ shell; do
        [ "$user" = "root" ] && continue
        [ -z "$uid" ] && continue
        [ "$uid" -lt "$uid_min" ] && continue
        [ "$uid" -gt "$uid_max" ] && continue

        case "$shell" in
            */false|*/nologin) continue ;;
        esac

        id -nG "$user" 2>/dev/null | grep -qw sudo || continue

        if [ "$uid" -lt "$best_uid" ]; then
            best_uid="$uid"
            best_user="$user"
        fi
    done </etc/passwd

    [ -n "$best_user" ] || return 1
    echo "$best_user"
}

if ! local_user=$(detect_local_user); then
    abort "no valid local user found, create one with sudo access -- abort"
fi
echo "Using local user: $local_user"

# dependencies
check_dependencies() {
    for dep_pkg in wget git zip unzip ipset nbtscan mawk libcgi-session-perl libgd-perl coreutils sarg php libapache2-mod-php php-cli php-curl fonts-lato fonts-liberation fonts-dejavu apache2 apache2-bin apache2-data apache2-doc apache2-utils perl cron sudo util-linux iproute2 passwd findutils sed grep hostname ncurses-bin systemd libc-bin iptables; do
        if ! dpkg -s "$dep_pkg" &>/dev/null; then
            abort "dependency '$dep_pkg' is not installed -- abort"
        fi
    done

    # dependencies (squid or squid-openssl)
    if ! dpkg -s squid &>/dev/null && ! dpkg -s squid-openssl &>/dev/null; then
        abort "'squid' or 'squid-openssl' is not installed -- abort"
    fi
}
check_dependencies

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

retry_cmd() {
    local max_retries=10
    local retry_attempt=1
    until "$@"; do
        if [ "$retry_attempt" -ge "$max_retries" ]; then
            abort "command failed after $max_retries attempts: $* -- abort"
        fi
        warn "command failed (attempt $retry_attempt/$max_retries), retrying in 10s: $* -- retry"
        retry_attempt=$((retry_attempt + 1))
        sleep 10
    done
}

check_apache_config() {
    if command -v php >/dev/null 2>&1; then
        php_version=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;" 2>/dev/null)
    else
        echo "PHP is not installed"
        exit 1
    fi

    if [[ ! "$php_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        echo "Could not determine PHP version (got '$php_version'). Is PHP working correctly?"
        exit 1
    fi

    config_errors=""

    if [ ! -f /etc/apache2/mods-available/mpm_prefork.conf ]; then
        config_errors+="/etc/apache2/mods-available/mpm_prefork.conf not found\n"
    fi

    if [ ! -f /etc/php/$php_version/apache2/php.ini ]; then
        if [ -f /etc/php/$php_version/cli/php.ini ]; then
            mkdir -p /etc/php/$php_version/apache2
            cp /etc/php/$php_version/cli/php.ini /etc/php/$php_version/apache2/php.ini
            echo "php.ini copied to /etc/php/$php_version/apache2/"
        else
            config_errors+="php.ini not found\n"
        fi
    fi

    if ! apache2ctl -M 2>/dev/null | grep -q "mpm_prefork"; then
        config_errors+="mpm_prefork module is not enabled\n"
    fi

    if ! apache2ctl -M 2>/dev/null | grep -qE "php[0-9.]*_module"; then
        config_errors+="php module is not enabled\n"
    fi

    if [[ -n "$config_errors" ]]; then
        echo "$config_errors"
        exit 1
    else
        echo "Apache and PHP configuration is valid"
    fi
}

check_squid_traffic() {
    if [ ! -f /var/log/squid/access.log ]; then
        echo "/var/log/squid/access.log not found"
        exit 1
    fi

    log_lines=$(wc -l < /var/log/squid/access.log 2>/dev/null || echo 0)

    if [ "$log_lines" -eq 0 ]; then
        warn "access.log is empty, Squid served no traffic yet -- degraded"
        echo "Continuing anyway; reports will be empty until traffic starts flowing."
        return 0
    fi

    log_entries=$(grep -cE "TCP_(HIT|MISS|TUNNEL|DENIED|ERROR)" /var/log/squid/access.log 2>/dev/null || true)
    log_entries=${log_entries:-0}

    if [ "$log_entries" -eq 0 ]; then
        warn "no valid traffic found ($log_lines lines, 0 valid) -- degraded"
        echo "Check Squid ACLs, port, and that clients point at this proxy. Continuing anyway."
    else
        echo "Squid traffic: $log_lines lines, $log_entries valid entries"
    fi
}

run_initial_checks() {
    echo -e "Running initial checks...\n"
    check_apache_config
    check_squid_traffic
    echo -e "All checks passed!\n"
}

check_repo() {
    local missing_flag=0
    if [ ! -d "modules" ] || [ -z "$(ls -A "modules" 2>/dev/null)" ]; then
        missing_flag=1
    fi
    if [ "$missing_flag" -eq 1 ]; then
        echo ""
        err "repository files not found, run: git clone https://github.com/maravento/proxymon -- abort"
        echo ""
        exit 1
    fi
}

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

# ------------------------------------------------------------------------------
# ENV
# ------------------------------------------------------------------------------

create_proxymon_env() {
    local env_file="/etc/proxymon/proxymon.env"
    mkdir -p /etc/proxymon

    if [ -f "$env_file" ]; then
        echo "$env_file already exists -- skipping configuration"
        # Warn if a newer version of this script expects variables
        # not present in an existing env file (version drift).
        local required_keys="LAN SERVER_IP RANGE REPORT_IP_GLOB LIGHTSQUID_DIR REPORT_PATH REALNAME_CFG SKIPUSERS_CFG ACL_PATH ACL_MAC_PATH ACL_SQUID_PATH ACL_BANDATA_PATH ALLOW_LIST BLOCK_LIST_DAY BLOCK_LIST_WEEK BLOCK_LIST_MONTH SQUID_LOG_DIR SQUID_LOG_FILE WARNING_HTML CACHE_PATH MAX_BANDWIDTH_DAY MAX_BANDWIDTH_WEEK MAX_BANDWIDTH_MONTH BANDATA_HOTSPOT HOTSPOT_PATH UPDATE_REALNAME"
        local missing_flag=""
        for env_key in $required_keys; do
            grep -q "^${env_key}=" "$env_file" || missing_flag="$missing_flag $env_key"
        done
        if [ -n "$missing_flag" ]; then
            warn "$env_file is missing variables expected by this version: $missing_flag -- alert"
            echo " Add them manually, or remove $env_file and re-run install to regenerate."
        fi

        # RANGE used to hold a filename-matching glob (e.g. "192.168.0*"),
        # not a network CIDR. An env file from before this change will fail
        # this check and needs RANGE corrected manually (and REPORT_IP_GLOB
        # added, per the check above) before Require ip will work correctly.
        local range_value
        range_value=$(grep "^RANGE=" "$env_file" | head -n1 | cut -d'=' -f2-)
        if [ -n "$range_value" ] && ! [[ "$range_value" =~ $UH_CIDR ]]; then
            warn "RANGE='$range_value' in $env_file is not a network CIDR -- alert"
            echo " This looks like the old filename-glob value. Add REPORT_IP_GLOB=$range_value,"
            echo " then set RANGE to your actual LAN subnet (e.g. RANGE=192.168.0.0/24)."
        fi
        return 0
    fi

    echo "----------------------------------------"
    echo " Bandata Configuration"
    echo "----------------------------------------"
    printf "\n"

    # LAN interface
    echo "Available network interfaces:"
    ip -o -4 addr show scope global | awk '{printf "  %-12s %s\n", $2, $4}'
    lan_default=$(ip -o link | awk -F': ' '$2 != "lo" {print $2; exit}')
    lan_default=${lan_default:-eth0}
    while true; do
        read -rp "LAN interface (default: $lan_default): " lan_answer
        lan_answer=${lan_answer:-$lan_default}
        if [ -e "/sys/class/net/$lan_answer" ]; then
            break
        fi
        echo "Interface '$lan_answer' not found on this system. Try again."
    done

    # Server IP
    while true; do
        read -rp "Server IP for LAN (default: 192.168.0.10): " server_ip_answer
        server_ip_answer=${server_ip_answer:-192.168.0.10}
        if ! [[ "$server_ip_answer" =~ $UH_IPV4 ]]; then
            echo "'$server_ip_answer' is not a valid IPv4 address. Try again."
            continue
        fi
        if ! ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$server_ip_answer"; then
            echo "'$server_ip_answer' is not configured on this system. Try again."
            continue
        fi
        break
    done

    # Glob pattern used to match per-IP report filenames under REPORT_PATH
    # (e.g. bandata.sh's "for file in $REPORT_IP_GLOB"). This is NOT a
    # network range -- it's a filename-matching pattern derived from the
    # server's own /24, since report files are named after client IPs.
    report_glob="$(echo "$server_ip_answer" | cut -d'.' -f1-3)*"

    # Real network range (CIDR) for the LAN this server serves -- used to
    # restrict the web panel to LAN clients. Derived from the same /24
    # assumption as above. For a non-standard subnet, edit RANGE manually
    # in /etc/proxymon/proxymon.env after installation.
    lan_range="$(echo "$server_ip_answer" | cut -d'.' -f1-3).0/24"

    # Bandwidth limits -- validate with numfmt (accepts e.g. 500M, 1G, 1.5G)
    read_bandwidth() {
        local prompt_text="$1" default_value="$2" user_answer
        while true; do
            read -rp "$prompt_text" user_answer
            user_answer=${user_answer:-$default_value}
            if LC_ALL=C numfmt --from=iec "${user_answer/,/.}" >/dev/null 2>&1; then
                echo "$user_answer"
                return
            fi
            echo "'$user_answer' is not a valid size (e.g. 500M, 1G, 1.5G). Try again." >&2
        done
    }
    bw_day=$(read_bandwidth "Max bandwidth per day (default: 1G): " "1G")
    bw_week=$(read_bandwidth "Max bandwidth per week (default: 5G): " "5G")
    bw_month=$(read_bandwidth "Max bandwidth per month (default: 20G): " "20G")

    # Unifi Hotspot Manager -- only ask if /etc/uhm exists
    hotspot_enabled=false
    hotspot_dir="/etc/uhm"
    if [ -d "/etc/uhm" ]; then
        read -rp "Unifi Hotspot Manager detected. Enable it in Bandata? (y/n, default: n): " hotspot_answer
        if [[ "$hotspot_answer" =~ ^[Yy]$ ]]; then
            hotspot_enabled=true
        fi
    fi

    # Auto-update Lightsquid realname
    read -rp "Automatically update hostnames in Lightsquid? (y/n, default: n): " realname_answer
    if [[ "$realname_answer" =~ ^[Yy]$ ]]; then
        update_realname_flag=true
    else
        update_realname_flag=false
    fi

    cat > "$env_file" << ENVEOF
# proxymon.env -- Bandata configuration
# Generated by pmsetup.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Edit manually if needed. Re-run pmsetup.sh install to regenerate.

# Network
LAN=${lan_answer}
SERVER_IP=${server_ip_answer}
RANGE=${lan_range}
REPORT_IP_GLOB=${report_glob}

# Paths (defaults -- edit only if your setup differs)
LIGHTSQUID_DIR=/var/www/proxymon/lightsquid
REPORT_PATH=\$LIGHTSQUID_DIR/report
REALNAME_CFG=\$LIGHTSQUID_DIR/realname.cfg
SKIPUSERS_CFG=\$LIGHTSQUID_DIR/skipuser.cfg
ACL_PATH=/etc/acl
ACL_MAC_PATH=\$ACL_PATH/mac
ACL_SQUID_PATH=\$ACL_PATH/squid
ACL_BANDATA_PATH=/var/www/proxymon/bandata/acl
ALLOW_LIST=\$ACL_BANDATA_PATH/allowdata.txt
BLOCK_LIST_DAY=\$ACL_BANDATA_PATH/banday.txt
BLOCK_LIST_WEEK=\$ACL_BANDATA_PATH/banweek.txt
BLOCK_LIST_MONTH=\$ACL_BANDATA_PATH/banmonth.txt
SQUID_LOG_DIR=/var/log/squid
SQUID_LOG_FILE=\$SQUID_LOG_DIR/access.log
WARNING_HTML=/var/www/proxymon/bandata/warning/warning.html
CACHE_PATH=/var/cache/proxymon

# Bandwidth limits
MAX_BANDWIDTH_DAY=${bw_day}
MAX_BANDWIDTH_WEEK=${bw_week}
MAX_BANDWIDTH_MONTH=${bw_month}

# Unifi Hotspot
BANDATA_HOTSPOT=${hotspot_enabled}
HOTSPOT_PATH=${hotspot_dir}

# Lightsquid realname auto-update
UPDATE_REALNAME=${update_realname_flag}
ENVEOF

    chmod 640 "$env_file"
    chown root:www-data "$env_file"
    echo "$env_file created"
    printf "\n"
}

# ------------------------------------------------------------------------------
# INSTALL
# ------------------------------------------------------------------------------

install_proxymon() {
    if [[ -d "/var/www/proxymon" ]]; then
        echo "Proxy Monitor is already installed (/var/www/proxymon exists)."
        echo "Use '$0 update' to update it, or '$0 uninstall' to remove it first."
        exit 1
    fi

    check_repo
    mkdir -p /var/www/proxymon
    cp -rf modules/* /var/www/proxymon/

    if [ -n "$local_user" ] && [ -f "/var/www/proxymon/sqstat/config.inc.php" ]; then
        local_user_esc=$(printf '%s' "$local_user" | sed -e 's/[\/&]/\\&/g')
        sed -i "s/\$cachemgr_passwd\[0\]=\"\";/\$cachemgr_passwd[0]=\"$local_user_esc\";/" /var/www/proxymon/sqstat/config.inc.php
    fi

    echo "Configuring Apache..."

    if [[ -f "/var/www/proxymon/proxymon.conf" ]]; then
        cp -f /var/www/proxymon/proxymon.conf /etc/apache2/sites-available/proxymon.conf
        echo "Proxymon virtualhost configured"
    fi

    if [[ -f "/var/www/proxymon/bandata/warning/warning.conf" ]]; then
        cp -f /var/www/proxymon/bandata/warning/warning.conf /etc/apache2/sites-available/warning.conf
        echo "Warning virtualhost configured"
    fi

    [ -f /etc/apache2/ports.conf.bak ] || cp -f /etc/apache2/ports.conf{,.bak} &>/dev/null || true

    echo "Configuring Squid Monitor..."
    create_proxymon_env

    echo "Configuring LightSquid..."
    /var/www/proxymon/lightsquid/lightparser.pl today || true
    echo "Initial LightSquid report generated"

    echo "Configuring ACL directories and files..."
    # Load env to get ACL paths defined by create_proxymon_env()
    # Verify ownership/permissions before sourcing -- this file is executed
    # as root, so it must not be writable by anyone other than root.
    env_file_path="/etc/proxymon/proxymon.env"
    env_owner=$(stat -c '%U' "$env_file_path" 2>/dev/null)
    env_perms=$(stat -c '%a' "$env_file_path" 2>/dev/null)
    env_group_digit="${env_perms: -2:1}"
    env_other_digit="${env_perms: -1}"
    if [ "$env_owner" != "root" ] || [[ "$env_group_digit" =~ [2367] ]] || [[ "$env_other_digit" =~ [2367] ]]; then
        err "$env_file_path has unsafe owner/permissions (owner=$env_owner perms=$env_perms) -- abort"
        echo "Expected owner root with no group/other write access. Refusing to source it."
        exit 1
    fi
    source "$env_file_path"

    echo "Configuring Apache Listen directives..."
    if [ -n "$SERVER_IP" ]; then
        # Drop any prior Listen line for these ports (0.0.0.0, a stale IP,
        # or a bare "Listen <port>") before adding the current ones.
        for probe_port in 18080 18081; do
            sed -i -E "/^Listen [^[:space:]]*:${probe_port}\$/d; /^Listen ${probe_port}\$/d" /etc/apache2/ports.conf
        done
        # 18080 is the app -- reachable from the LAN and from loopback
        # (e.g. a local Cloudflare Tunnel connecting to the origin).
        echo "Listen ${SERVER_IP}:18080" >> /etc/apache2/ports.conf
        echo "Listen 127.0.0.1:18080" >> /etc/apache2/ports.conf
        # 18081 is Bandata's warning page -- LAN-only, no loopback needed.
        echo "Listen ${SERVER_IP}:18081" >> /etc/apache2/ports.conf
        echo "Port 18080 bound to ${SERVER_IP} and 127.0.0.1"
        echo "Port 18081 bound to ${SERVER_IP}"
    else
        abort "SERVER_IP not set, cannot configure Listen -- abort"
    fi

    echo "Restricting Proxymon panel to LAN..."
    if [[ -f /etc/apache2/sites-available/proxymon.conf ]]; then
        read -rp "Restrict Proxymon panel to $RANGE (plus 127.0.0.1)? Otherwise it keeps the default 192.168.0.0/24 (y/n, default: y): " lan_restrict_answer
        lan_restrict_answer=${lan_restrict_answer:-y}
        if [[ "$lan_restrict_answer" =~ ^[Yy]$ ]]; then
            if [[ "$RANGE" =~ $UH_CIDR ]]; then
                # 127.0.0.1 allowed alongside the LAN so a local tunnel/trusted
                # proxy connecting over loopback to port 18080 still works.
                sed -i "s|192.168.0.0/24 127.0.0.1|$RANGE 127.0.0.1|g" /etc/apache2/sites-available/proxymon.conf
                echo "Proxymon panel restricted to $RANGE and 127.0.0.1"
            else
                warn "RANGE='$RANGE' in $env_file_path is not a valid CIDR, keeping the default range -- fallback"
            fi
        else
            info "keeping the default range, edit proxymon.conf by hand if needed -- skip"
        fi
    fi

    # Create ACL directories
    # ACL_BANDATA_PATH is not created here: it ships inside modules/bandata/acl/
    # with its 4 files already present, copied by cp -rf modules/* above and
    # given the same permissions/ownership as the rest of /var/www/proxymon
    # by the "Setting Permissions" step below.
    mkdir -p "$ACL_PATH" "$ACL_MAC_PATH" "$ACL_SQUID_PATH"
    chmod 755 "$ACL_PATH" "$ACL_MAC_PATH" "$ACL_SQUID_PATH"
    chown root:root "$ACL_PATH" "$ACL_MAC_PATH" "$ACL_SQUID_PATH"
    echo "ACL directories created"

    # Create LightSquid report directory if it does not exist
    mkdir -p "$REPORT_PATH"
    chmod 755 "$REPORT_PATH"
    chown www-data:www-data "$REPORT_PATH"
    echo "LightSquid report directory ready"

    echo "Downloading ACL lists..."
    retry_cmd wget -q --show-progress https://raw.githubusercontent.com/maravento/blackweb/refs/heads/master/bwupdate/lst/blocktlds.txt -O "$ACL_SQUID_PATH/blocktlds.txt"
    chmod 644 "$ACL_SQUID_PATH/blocktlds.txt"
    chown root:root "$ACL_SQUID_PATH/blocktlds.txt"
    echo "blocktlds.txt downloaded"

    retry_cmd wget -q --show-progress https://raw.githubusercontent.com/maravento/blackweb/refs/heads/master/bwupdate/lst/debugbl.txt -O "$ACL_SQUID_PATH/blockdomains.txt"
    chmod 644 "$ACL_SQUID_PATH/blockdomains.txt"
    chown root:root "$ACL_SQUID_PATH/blockdomains.txt"
    echo "blockdomains.txt downloaded"

    retry_cmd wget -q --show-progress https://raw.githubusercontent.com/maravento/vault/refs/heads/master/gateproxy/acl/squid/blockpatterns.txt -O "$ACL_SQUID_PATH/blockpatterns.txt"
    chmod 644 "$ACL_SQUID_PATH/blockpatterns.txt"
    chown root:root "$ACL_SQUID_PATH/blockpatterns.txt"
    echo "blockpatterns.txt downloaded"

    (crontab -l 2>/dev/null || true) | {
        grep -v "/var/www/proxymon/bandata/bandata.sh"
        echo "*/5 * * * * /var/www/proxymon/bandata/bandata.sh >> /var/log/bandata.log 2>&1"
    } | crontab -
    echo "Squid Monitor crontab added"

    echo "Configuring SARG..."
    mkdir -p /var/www/proxymon/sarg/squid-reports

    [ -f /etc/sarg/sarg.conf.bak ] || cp -f /etc/sarg/sarg.conf{,.bak} &>/dev/null || true
    sed -i 's|output_dir /var/lib/sarg|output_dir /var/www/proxymon/sarg/squid-reports|g' /etc/sarg/sarg.conf
    sed -i 's|^resolve_ip .*|resolve_ip no|g' /etc/sarg/sarg.conf
    sed -i 's|lastlog 0|lastlog 7|g' /etc/sarg/sarg.conf

    server_hostname=$(hostname)
    [ -f /etc/sarg/usertab.bak ] || cp -f /etc/sarg/usertab{,.bak} &>/dev/null || true

    if [ -n "$SERVER_IP" ]; then
        if ! grep -q "^${SERVER_IP//./\\.}[[:space:]]" /etc/sarg/usertab; then
            echo "$SERVER_IP $server_hostname" >> /etc/sarg/usertab
            echo "Added $SERVER_IP $server_hostname to usertab"
        fi
    else
        echo "SERVER_IP not set in proxymon.env -- skipping usertab entry"
    fi

    echo " Generating Initial SARG Report..."
    timeout 30 /usr/bin/sarg -f /etc/sarg/sarg.conf -l /var/log/squid/access.log > /dev/null 2>&1 || true
    echo "Initial SARG report generated"

    echo "Configuring SquidAnalyzer..."
    chmod -R 755 /var/www/proxymon/squidanalyzer
    mkdir -p /var/www/proxymon/squidanalyzer/output
    rm -rf /var/www/proxymon/squidanalyzer/output/* 2>/dev/null
    chown -R www-data:www-data /var/www/proxymon/squidanalyzer

    cd /var/www/proxymon/squidanalyzer || exit 1
    sudo -u www-data perl -I. ./squid-analyzer -c etc/squidanalyzer.conf -d &> /dev/null || true
    cd - > /dev/null

    # -- Consolidated www-data crontab update (single atomic write) --
    # All www-data cron entries (LightSquid, SARG daily/weekly, SquidAnalyzer)
    # are rewritten together to avoid leaving the crontab in a partial
    # state if the installer is interrupted between operations.
    (sudo -u www-data crontab -l 2>/dev/null || true) | {
        grep -v "lightparser.pl" \
            | grep -v "sarg.*sarg.conf.*access.log" \
            | grep -v "find.*sarg.*squid-reports" \
            | grep -v "squid-analyzer"
        echo "*/10 * * * * /var/www/proxymon/lightsquid/lightparser.pl today"
        echo "@daily /usr/bin/sarg -f /etc/sarg/sarg.conf -l /var/log/squid/access.log"
        echo '@weekly find /var/www/proxymon/sarg/squid-reports -name "2*" -mtime +30 -type d -exec rm -rf {} +'
        echo '0 2 * * * cd /var/www/proxymon/squidanalyzer && perl -I. ./squid-analyzer -c etc/squidanalyzer.conf'
    } | sudo -u www-data crontab -
    echo "www-data crontab entries updated (LightSquid, SARG, SquidAnalyzer)"

    echo " Updating Prefork MPM..."
    [ -f /etc/apache2/mods-available/mpm_prefork.conf.bak ] || cp -f /etc/apache2/mods-available/mpm_prefork.conf{,.bak} &>/dev/null || true
    sed -i \
      -e 's/^\(StartServers[[:space:]]*\)5/\110/' \
      -e 's/^\(MinSpareServers[[:space:]]*\)5/\110/' \
      -e 's/^\(MaxSpareServers[[:space:]]*\)10/\115/' \
      -e 's/^\(MaxRequestWorkers[[:space:]]*\)150/\1200/' \
      -e 's/^\(MaxConnectionsPerChild[[:space:]]*\)0/\11000/' \
    /etc/apache2/mods-available/mpm_prefork.conf

    echo " Updating PHP..."
    [ -f /etc/php/$php_version/apache2/php.ini.bak ] || cp -f /etc/php/$php_version/apache2/php.ini{,.bak} &>/dev/null || true
    sed -i \
      -e 's/^\s*;*\s*max_execution_time\s*=.*/max_execution_time = 120/' \
      -e 's/^\s*max_input_time\s*=.*/max_input_time = 120/' \
      -e 's/^;\s*max_input_time\s*=.*/max_input_time = 120/' \
      -e 's/^\s*;*\s*memory_limit\s*=.*/memory_limit = 1024M/' \
      -e 's/^\s*;*\s*post_max_size\s*=.*/post_max_size = 64M/' \
      -e 's/^\s*;*\s*upload_max_filesize\s*=.*/upload_max_filesize = 64M/' \
      -e 's/^\s*;*\s*opcache.memory_consumption\s*=.*/opcache.memory_consumption = 256/' \
      -e 's/^\s*;*\s*realpath_cache_size\s*=.*/realpath_cache_size = 16M/' \
      -e 's/^\s*;*\s*allow_url_fopen\s*=.*/allow_url_fopen = On/' \
     /etc/php/$php_version/apache2/php.ini

    # Hardening
    echo " Updating Apache2 Security..."
    if [ -f /etc/apache2/conf-available/security.conf ]; then
        [ -f /etc/apache2/conf-available/security.conf.bak ] || cp -f /etc/apache2/conf-available/security.conf{,.bak} &>/dev/null || true
    else
        touch /etc/apache2/conf-available/security.conf
    fi
    sed -i "s/^#*\s*ServerSignature.*/ServerSignature Off/" /etc/apache2/conf-available/security.conf
    sed -i "s/^#*\s*ServerTokens.*/ServerTokens Prod/" /etc/apache2/conf-available/security.conf
    declare -A apache_headers=(
        ["X-Content-Type-Options"]="nosniff"
        ["X-Frame-Options"]="sameorigin"
        ["X-XSS-Protection"]="1; mode=block"
        ["Referrer-Policy"]="strict-origin-when-cross-origin"
    )
    for header_name in "${!apache_headers[@]}"; do
        header_value="${apache_headers[$header_name]}"
        if grep -q "Header set $header_name" /etc/apache2/conf-available/security.conf; then
            sed -i "s|^#*\s*Header set $header_name.*|Header set $header_name \"$header_value\"|" /etc/apache2/conf-available/security.conf
        else
            echo "Header set $header_name \"$header_value\"" >> /etc/apache2/conf-available/security.conf
        fi
    done
    grep -q "^FileETag None" /etc/apache2/conf-available/security.conf || \
        echo 'FileETag None' >> /etc/apache2/conf-available/security.conf

    grep -q "^Header unset ETag" /etc/apache2/conf-available/security.conf || \
        echo 'Header unset ETag' >> /etc/apache2/conf-available/security.conf

    grep -q "^Timeout" /etc/apache2/conf-available/security.conf || \
        echo 'Timeout 60' >> /etc/apache2/conf-available/security.conf
    [ -f /etc/apache2/apache2.conf.bak ] || cp -f /etc/apache2/apache2.conf{,.bak} &>/dev/null || true
    sed -i -E '/^[[:space:]]*#/!s/^([[:space:]]*Options[[:space:]]+)(-?Indexes[[:space:]]+)?FollowSymLinks[[:space:]]*$/\1-Indexes +FollowSymLinks/' /etc/apache2/apache2.conf
    a2enmod headers &>/dev/null
    a2enconf security &>/dev/null

    echo "Configuring SquidAI..."
    mkdir -p /etc/proxymon
    if [ ! -f /etc/proxymon/.env ]; then
        cat > /etc/proxymon/.env << 'EOF'
# SquidAI -- LLM Provider Configuration
# Uncomment ONE provider block and fill in your credentials.
# Leave LLM_MODEL empty if the model is already part of the URL.
# LLM_API_KEY can be left empty for local providers (Ollama, LM Studio).
#
# LLM_RESPONSE_FORMAT tells the worker how to read the response:
# openai -> choices[0].message.content (most cloud providers)
# ollama -> message.content (Ollama)
# gemini -> passthrough, no transform (Google Gemini)

# Active provider (uncomment one block below)
LLM_URL=
LLM_API_KEY=
LLM_MODEL=
LLM_RESPONSE_FORMAT=openai

# PROVIDER EXAMPLES -- copy the values above and replace

# Cloudflare Workers AI (model goes in the URL, no LLM_MODEL needed)
# LLM_URL=https://api.cloudflare.com/client/v4/accounts/ACCOUNT_ID/ai/run/@cf/meta/llama-3.1-8b-instruct-fast
# LLM_API_KEY=your_token
# LLM_RESPONSE_FORMAT=openai

# OpenAI
# LLM_URL=https://api.openai.com/v1/chat/completions
# LLM_API_KEY=sk-...
# LLM_MODEL=gpt-4o-mini
# LLM_RESPONSE_FORMAT=openai

# Groq (fast inference, free tier available)
# LLM_URL=https://api.groq.com/openai/v1/chat/completions
# LLM_API_KEY=gsk_...
# LLM_MODEL=llama-3.1-8b-instant
# LLM_RESPONSE_FORMAT=openai

# OpenRouter (access to many models, free tier available)
# LLM_URL=https://openrouter.ai/api/v1/chat/completions
# LLM_API_KEY=sk-or-...
# LLM_MODEL=mistralai/mistral-7b-instruct
# LLM_RESPONSE_FORMAT=openai

# Together AI
# LLM_URL=https://api.together.xyz/v1/chat/completions
# LLM_API_KEY=your_key
# LLM_MODEL=meta-llama/Llama-3-8b-chat-hf
# LLM_RESPONSE_FORMAT=openai

# Ollama (local, no API key required)
# LLM_URL=http://localhost:11434/api/chat
# LLM_API_KEY=
# LLM_MODEL=llama3.1
# LLM_RESPONSE_FORMAT=ollama

# LM Studio (local, OpenAI-compatible)
# LLM_URL=http://localhost:1234/v1/chat/completions
# LLM_API_KEY=lm-studio
# LLM_MODEL=
# LLM_RESPONSE_FORMAT=openai

# Google Gemini
# LLM_URL=https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent?key=YOUR_KEY
# LLM_API_KEY=
# LLM_MODEL=
# LLM_RESPONSE_FORMAT=gemini
EOF
    fi
    chmod 640 /etc/proxymon/.env
    chown root:www-data /etc/proxymon/.env
    chmod 750 /etc/proxymon
    chown root:www-data /etc/proxymon
    mkdir -p "$CACHE_PATH"
    chmod 750 "$CACHE_PATH"
    chown www-data:www-data "$CACHE_PATH"
    echo "SquidAI config directory created: /etc/proxymon/"
    echo "Edit /etc/proxymon/.env and set your LLM credentials"

    echo " Setting Permissions..."
    find /var/www/proxymon -type d -exec chmod 755 {} +
    find /var/www/proxymon -type f -exec chmod 644 {} +
    find /var/www/proxymon -type f -name "*.cgi" -exec chmod +x {} +
    chmod +x /var/www/proxymon/bandata/bandata.sh
    chmod +x /var/www/proxymon/lightsquid/lightparser.pl
    chown -R www-data:www-data /var/www/proxymon
    # bandata.sh runs entirely as root (its own root check, invoked from
    # root's crontab) and is the only thing that ever touches these 4 files
    # -- no PHP/CGI under /var/www/proxymon reads or writes them. Same
    # reasoning as realname.cfg/skipuser.cfg, which bandata.sh also owns
    # exclusively and are root:root for the same reason.
    chown root:root "$ACL_BANDATA_PATH"/*.txt
    if getent group proxy >/dev/null; then
        usermod -aG proxy www-data
    else
        err "group 'proxy' not found, expected from the squid package -- abort"
        echo "Ensure squid is installed before running this step."
        exit 1
    fi
    chown root:root /etc/squid/squid.conf
    chmod 644 /etc/squid/squid.conf

    echo " Setting Logs..."
    touch /var/log/apache2/{warning_access,warning_error,proxymon_access,proxymon_error}.log
    chown root:adm /var/log/apache2/{warning_access,warning_error,proxymon_access,proxymon_error}.log
    chmod 640 /var/log/apache2/{warning_access,warning_error,proxymon_access,proxymon_error}.log

    shopt -s nullglob
    squid_logs=(/var/log/squid/*.log)
    if [ ${#squid_logs[@]} -gt 0 ]; then
        chown proxy:proxy "${squid_logs[@]}"
        chmod 640 "${squid_logs[@]}"
    else
        echo "No /var/log/squid/*.log files found yet -- skipping permissions"
    fi
    shopt -u nullglob

    echo " Enabling Apache Modules..."
    a2dismod mpm_event 2>/dev/null || true
    # mod_cgid requires a threaded MPM (worker/event) and is incompatible
    # with mpm_prefork enabled below. Use mod_cgi instead.
    a2dismod cgid 2>/dev/null || true

    for apache_mod in mpm_prefork "php$php_version" cgi rewrite; do
        if a2enmod "$apache_mod" 2>/dev/null; then
            continue
        fi
        # Fallback for systems where the module is registered as plain "php"
        if [[ "$apache_mod" == "php$php_version" ]] && a2enmod php 2>/dev/null; then
            continue
        fi
        abort "cannot enable Apache module '$apache_mod', check it is installed -- abort"
    done

    echo " Enabling Apache Sites..."
    a2ensite proxymon.conf || { echo "Failed to enable proxymon.conf"; exit 1; }
    a2ensite warning.conf || { echo "Failed to enable warning.conf"; exit 1; }

    echo " Restarting Cron..."
    systemctl restart cron

    echo " Restarting Apache2..."
    systemctl daemon-reload
    if ! apachectl -t -D DUMP_INCLUDES -S &>/dev/null; then
        echo "Apache configuration test failed. Disabling the sites just enabled so a future"
        echo "an unrelated Apache restart does not undo it."
        a2dissite proxymon.conf 2>/dev/null || true
        a2dissite warning.conf 2>/dev/null || true
        echo "Run 'apachectl -t' to see the error, fix the configuration, then re-run install."
        exit 1
    fi
    echo "Apache configuration OK"
    systemctl restart apache2

    echo " Check Active Apache sites:"
    a2query -s

    echo "Proxy Monitor installed successfully"
    echo "Access Proxy Monitor: http://${SERVER_IP}:18080"
    echo "Access Warning Portal: http://${SERVER_IP}:18081"
}

# ------------------------------------------------------------------------------
# UPDATE
# ------------------------------------------------------------------------------

# Refreshes code under /var/www/proxymon only. Does NOT touch anything
# outside that path: no Apache/PHP/SARG/cron config, no ACL lists, no
# proxymon.env, no service restarts. Preserves live data that lives
# inside /var/www/proxymon but isn't part of the repo tree.

update_proxymon() {
    if [[ ! -d "/var/www/proxymon" ]]; then
        echo "Proxy Monitor is not installed. Run '$0 install' first."
        exit 1
    fi

    backup_dir="/etc/bak/proxymon"
    backup_zip="${backup_dir}/proxymonbak_$(date +%Y%m%d_%H%M).zip"

    # Live data that isn't part of the modules/ repo tree -- backed up before
    # the file swap and restored after. Never modified in place.
    protected_paths=(
        "lightsquid/report"
        "lightsquid/realname.cfg"
        "lightsquid/skipuser.cfg"
        "sarg/squid-reports"
        "squidmon/etc/config"
        "squidanalyzer/output"
        "sqstat/config.inc.php"
        "bandata/acl/allowdata.txt"
    )

    check_repo

    echo "Stopping Apache..."
    systemctl stop apache2

    if ! mkdir -p "$backup_dir"; then
        abort "cannot create $backup_dir -- abort"
    fi

    backup_list=()
    for rel_path in "${protected_paths[@]}"; do
        if [ -e "/var/www/proxymon/$rel_path" ]; then
            backup_list+=("/var/www/proxymon/$rel_path")
        else
            info "$rel_path not present -- skip"
        fi
    done

    if (( ${#backup_list[@]} == 0 )); then
        echo "Nothing to back up yet (first update on this install)"
    elif zip -r -q "$backup_zip" "${backup_list[@]}"; then
        chmod 600 "$backup_zip"
        echo "Backup written to $backup_zip"

        # keep only the last 3
        old_backups=("$backup_dir"/proxymonbak_*.zip)
        if (( ${#old_backups[@]} > 3 )); then
            printf '%s\n' "${old_backups[@]}" | sort | head -n -3 | xargs -r rm -f
        fi
    else
        rm -f "$backup_zip"
        abort "cannot write $backup_zip, check free space and permissions -- abort"
    fi

    echo "Replacing Proxy Monitor code..."
    cp -rf modules/* /var/www/proxymon/

    if [ -f "$backup_zip" ]; then
        echo "Restoring live data from backup..."
        unzip -o -q "$backup_zip" -d /
        echo "Live data restored"
    fi

    echo "Setting permissions..."
    find /var/www/proxymon -type d -exec chmod 755 {} +
    find /var/www/proxymon -type f -exec chmod 644 {} +
    find /var/www/proxymon -type f -name "*.cgi" -exec chmod +x {} +
    [ -f /var/www/proxymon/bandata/bandata.sh ] && chmod +x /var/www/proxymon/bandata/bandata.sh
    [ -f /var/www/proxymon/lightsquid/lightparser.pl ] && chmod +x /var/www/proxymon/lightsquid/lightparser.pl
    chown -R www-data:www-data /var/www/proxymon
    # bandata.sh runs entirely as root and is the only thing that touches
    # these 4 files -- see install_proxymon() for the full reasoning.
    # Hardcoded (not $ACL_BANDATA_PATH): update_proxymon() does not source
    # proxymon.env by design (see header: never touches proxymon.env).
    [ -d /var/www/proxymon/bandata/acl ] && chown root:root /var/www/proxymon/bandata/acl/*.txt 2>/dev/null
    echo "Permissions set"

    echo "Starting Apache..."
    if systemctl start apache2; then
        echo "Apache started"
    else
        echo "Apache failed to start -- check: systemctl status apache2"
        exit 1
    fi

    echo "Backup kept in $backup_dir (last 3 kept)."
    echo "Proxy Monitor updated successfully"
}

# ------------------------------------------------------------------------------
# UNINSTALL
# ------------------------------------------------------------------------------

uninstall_proxymon() {
    echo " Uninstalling Proxy Monitor..."

    if [[ ! -d "/var/www/proxymon" ]]; then
        if ! ((sudo crontab -l 2>/dev/null || true) | grep -q "/var/www/proxymon/bandata/bandata.sh") && \
           ! ((sudo -u www-data crontab -l 2>/dev/null || true) | grep -q "lightparser.pl\|sarg\|squid-analyzer") && \
           [[ ! -d "/etc/proxymon" ]]; then
            echo " Proxy Monitor is not installed"
            return 0
        fi
    fi

    # -- Consolidated www-data crontab cleanup (single atomic write) --
    if (sudo -u www-data crontab -l 2>/dev/null || true) \
        | { grep -v "lightparser.pl" || true; } \
        | { grep -v "sarg.*sarg.conf.*access.log" || true; } \
        | { grep -v "find.*sarg.*squid-reports" || true; } \
        | { grep -v "squid-analyzer" || true; } \
        | sudo -u www-data crontab - 2>/dev/null; then
        echo "LightSquid, SARG and SquidAnalyzer crontab entries removed"
    else
        warn "cannot update www-data crontab, entries may remain -- alert"
    fi

    if (crontab -l 2>/dev/null || true) | { grep -v "/var/www/proxymon/bandata/bandata.sh" || true; } | crontab - 2>/dev/null; then
        echo "Squid Monitor crontab removed"
    else
        warn "cannot update root crontab, bandata.sh entry may remain -- alert"
    fi

    if command -v iptables >/dev/null 2>&1; then
        # Remove FORWARD/INPUT jumps into the Bandata chains by rule number
        # (matched by target name, so this works regardless of which LAN
        # interface bandata.sh was configured with).
        for chain_pair in "FORWARD:BANDATA_FWD" "INPUT:BANDATA_IN"; do
            base_chain="${chain_pair%%:*}"
            target_chain="${chain_pair##*:}"
            while true; do
                rule_num=$(iptables -L "$base_chain" --line-numbers -n 2>/dev/null | awk -v t="$target_chain" '$2==t{print $1; exit}')
                [ -n "$rule_num" ] || break
                iptables -D "$base_chain" "$rule_num" 2>/dev/null || break
            done
        done

        # Remove the NAT redirect to the warning portal
        while true; do
            rule_num=$(iptables -t nat -L PREROUTING --line-numbers -n 2>/dev/null | awk '/match-set bandata/{print $1; exit}')
            [ -n "$rule_num" ] || break
            iptables -t nat -D PREROUTING "$rule_num" 2>/dev/null || break
        done

        # Flush and remove the now-unreferenced Bandata chains
        for bandata_chain in BANDATA_FWD BANDATA_IN; do
            if iptables -L "$bandata_chain" -n &>/dev/null; then
                iptables -F "$bandata_chain" 2>/dev/null || true
                iptables -X "$bandata_chain" 2>/dev/null || true
            fi
        done
        echo "Bandata iptables rules removed"
    fi

    if command -v ipset >/dev/null 2>&1 && ipset list bandata &>/dev/null; then
        ipset destroy bandata 2>/dev/null && echo "Bandata ipset destroyed" \
            || warn "cannot destroy ipset 'bandata', remove it manually -- alert"
    fi

    if [[ -f "/etc/sarg/sarg.conf.bak" ]]; then
        mv -f /etc/sarg/sarg.conf.bak /etc/sarg/sarg.conf
        echo "SARG configuration restored"
    fi

    if [[ -f "/etc/sarg/usertab.bak" ]]; then
        mv -f /etc/sarg/usertab.bak /etc/sarg/usertab
        echo "SARG usertab restored"
    fi

    if [[ -f "/etc/apache2/mods-available/mpm_prefork.conf.bak" ]]; then
        mv -f /etc/apache2/mods-available/mpm_prefork.conf.bak /etc/apache2/mods-available/mpm_prefork.conf
        echo "mpm_prefork configuration restored"
    fi

    php_version=""
    if command -v php >/dev/null 2>&1; then
        php_version=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;" 2>/dev/null || true)
    fi
    if [[ -n "$php_version" && -f "/etc/php/$php_version/apache2/php.ini.bak" ]]; then
        mv -f "/etc/php/$php_version/apache2/php.ini.bak" "/etc/php/$php_version/apache2/php.ini"
        echo "php.ini restored"
    fi

    if [[ -f "/etc/apache2/conf-available/security.conf.bak" ]]; then
        mv -f /etc/apache2/conf-available/security.conf.bak /etc/apache2/conf-available/security.conf
        echo "security.conf restored"
    fi

    if [[ -f "/etc/apache2/apache2.conf.bak" ]]; then
        mv -f /etc/apache2/apache2.conf.bak /etc/apache2/apache2.conf
        echo "apache2.conf restored"
    fi

    if [[ -f "/etc/apache2/sites-available/proxymon.conf" ]]; then
        a2dissite proxymon.conf 2>/dev/null || true
        rm -f /etc/apache2/sites-available/proxymon.conf
        echo "Proxymon site disabled"
    fi

    if [[ -f "/etc/apache2/sites-available/warning.conf" ]]; then
        a2dissite warning.conf 2>/dev/null || true
        rm -f /etc/apache2/sites-available/warning.conf
        echo "Warning site disabled"
    fi

    if [[ -d "/var/www/proxymon" ]]; then
        rm -rf /var/www/proxymon
        echo "Installation directory removed"
    fi

    if [[ -d "/var/cache/proxymon" ]]; then
        rm -rf /var/cache/proxymon
        echo "Cache directory removed"
    fi

    if [[ -d "/etc/proxymon" ]]; then
        read -p "Remove /etc/proxymon/ (contains LLM credentials)? (y/n): " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf /etc/proxymon
            echo "SquidAI config directory removed"
        else
            echo " /etc/proxymon kept -- remove manually if needed"
        fi
    fi

    if [[ -d "/etc/acl" ]]; then
        read -p "Remove /etc/acl/ (contains allowlists and MAC registrations, shared with other projects)? (y/n): " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf /etc/acl
            echo "/etc/acl removed"
        else
            echo " /etc/acl kept -- remove manually if needed"
        fi
    fi

    sed -i -E '/^Listen [^[:space:]]*:18080$/d; /^Listen 18080$/d' /etc/apache2/ports.conf
    echo "Port 18080 removed from Apache"

    sed -i -E '/^Listen [^[:space:]]*:18081$/d; /^Listen 18081$/d' /etc/apache2/ports.conf
    echo "Port 18081 removed from Apache"

    rm -f /var/log/apache2/{warning_access,warning_error,proxymon_access,proxymon_error}.log*
    echo "Proxymon log files removed"

    rm -f /etc/logrotate.d/bandata /var/log/bandata.log*
    echo "Bandata logrotate config and log files removed"

    systemctl restart cron
    systemctl daemon-reload
    systemctl restart apache2

    echo " Remaining Apache sites:"
    a2query -s

    echo "Proxy Monitor uninstalled successfully"
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

case "${1:-}" in
    install)
        run_initial_checks
        install_proxymon
        exit 0
        ;;
    update)
        update_proxymon
        exit 0
        ;;
    uninstall)
        read -p "Are you sure you want to uninstall? (y/n): " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            uninstall_proxymon
        else
            echo "Uninstall cancelled"
            exit 0
        fi
        exit 0
        ;;
    -h|--help)
        echo "Proxy Monitor Installation/Uninstallation Script"
        echo ""
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "install Install Proxy Monitor"
        echo "update Update Proxy Monitor code (/var/www/proxymon only)"
        echo "uninstall Uninstall Proxy Monitor"
        echo "-h, --help Show this help message"
        exit 0
        ;;
    "")
        show_menu() {
            clear
            echo "----------------------------------------"
            echo " Proxy Monitor Installer"
            echo "----------------------------------------"
            echo ""
            echo "1 - Install Proxy Monitor"
            echo "2 - Update Proxy Monitor"
            echo "3 - Uninstall Proxy Monitor"
            echo "4 - Exit"
            echo ""
            echo "----------------------------------------"
            echo -n "Select an option: "
        }

        while true; do
            show_menu
            read -r menu_option

            case "$menu_option" in
                1)
                    echo ""
                    run_initial_checks
                    install_proxymon
                    echo ""
                    echo -n "Press Enter to continue..."
                    read -r
                    ;;
                2)
                    echo ""
                    update_proxymon
                    echo ""
                    echo -n "Press Enter to continue..."
                    read -r
                    ;;
                3)
                    echo ""
                    read -p "Are you sure you want to uninstall? (y/n): " -r
                    echo ""
                    if [[ $REPLY =~ ^[Yy]$ ]]; then
                        uninstall_proxymon
                    else
                        echo "Uninstall cancelled"
                    fi
                    echo ""
                    echo -n "Press Enter to continue..."
                    read -r
                    ;;
                4)
                    echo "Goodbye!"
                    exit 0
                    ;;
                *)
                    echo "Invalid option. Please select 1, 2, 3 or 4"
                    sleep 2
                    ;;
            esac
        done
        ;;
    *)
        echo "Unknown option: $1"
        echo "Use: $0 -h for help"
        exit 1
        ;;
esac
