#!/bin/bash
# maravento.com
#
################################################################################
#
# pmsetup -- installer for proxymon
#
# DESCRIPTION:
# Installs, updates or uninstalls proxymon. Requires root, and a populated
# modules/ and config/ tree next to this script.
#
# USAGE:
# sudo bash pmsetup.sh --install      Fresh install
# sudo bash pmsetup.sh --update       Refresh code, keep live data
# sudo bash pmsetup.sh --uninstall    Remove proxymon
# sudo bash pmsetup.sh                Interactive menu
# sudo bash pmsetup.sh -h             Show usage
#
# LOG: pmsetup.log, in this script's directory
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

# Every repository path below is relative to the script, not to wherever the
# administrator happened to be standing when running it
cd "$script_dir" || { echo "ERROR: cannot enter $script_dir -- abort"; exit 1; }

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

source "$script_dir/config/tools/proxymonenv.sh"
proxymon_env="/etc/proxymon/proxymon.env"

configure_locations() {
    unset WEB_ROOT CONFIG_DIR BACKUP_DIR PANEL_PORT WARNING_PORT
    unset TOOL_REPORT_DIR SQUIDMON_CONFIG LLM_ENV_FILE REPORT_STATS_PATH
    if [ -f "$proxymon_env" ]; then
        load_proxymon_env "$proxymon_env" || abort "cannot load proxymon.env -- abort"
    fi
    local env_key
    local -A location_defaults=(
        [WEB_ROOT]="/var/www/proxymon"
        [CONFIG_DIR]="/etc/proxymon"
        [BACKUP_DIR]="/etc/bak/proxymon"
        [PANEL_PORT]="18080"
        [WARNING_PORT]="18081"
    )
    for env_key in WEB_ROOT CONFIG_DIR BACKUP_DIR PANEL_PORT WARNING_PORT; do
        if [ -z "${!env_key+x}" ]; then
            printf -v "$env_key" '%s' "${location_defaults[$env_key]}"
        fi
    done
    location_defaults=(
        [TOOL_REPORT_DIR]="$CONFIG_DIR/tools/reports"
        [SQUIDMON_CONFIG]="$WEB_ROOT/squidmon/etc/config"
        [LLM_ENV_FILE]="$CONFIG_DIR/.env"
        [REPORT_STATS_PATH]="${REPORT_PATH:-$WEB_ROOT/squidreports/report}stats"
    )
    for env_key in TOOL_REPORT_DIR SQUIDMON_CONFIG LLM_ENV_FILE REPORT_STATS_PATH; do
        if [ -z "${!env_key+x}" ]; then
            printf -v "$env_key" '%s' "${location_defaults[$env_key]}"
        fi
    done
    for env_key in WEB_ROOT CONFIG_DIR BACKUP_DIR TOOL_REPORT_DIR SQUIDMON_CONFIG LLM_ENV_FILE REPORT_STATS_PATH; do
        [[ "${!env_key}" =~ ^/[a-zA-Z0-9_./-]+$ ]] || abort "invalid $env_key -- abort"
        [[ "${!env_key}" != /etc && "${!env_key}" != /var && "${!env_key}" != /var/www && "${!env_key}" != / && "${!env_key}" != *'/../'* && "${!env_key}" != */.. ]] || abort "unsafe $env_key -- abort"
    done
    for env_key in PANEL_PORT WARNING_PORT; do
        [[ "${!env_key}" =~ ^[1-9][0-9]{0,4}$ ]] && (( ${!env_key} <= 65535 )) || abort "invalid $env_key -- abort"
    done
    [ "$PANEL_PORT" != "$WARNING_PORT" ] || abort "panel and warning ports must differ -- abort"
}

configure_apache_locations() {
    local site old_root old_port old_config
    local -a old_ports=("$PANEL_PORT" "$WARNING_PORT")
    for site in proxymon warning; do
        local existing_site="/etc/apache2/sites-available/$site.conf"
        [ -f "$existing_site" ] || continue
        old_port=$(sed -nE 's/^<VirtualHost [^:]+:([0-9]+)>$/\1/p' "$existing_site" | head -n1)
        [ -z "$old_port" ] || old_ports+=("$old_port")
    done
    for old_port in "${old_ports[@]}"; do
        sed -i -E "/^Listen [^[:space:]]*:${old_port}\$/d; /^Listen ${old_port}\$/d" /etc/apache2/ports.conf
    done
    for site in proxymon warning; do
        local site_file="/etc/apache2/sites-available/$site.conf"
        [ -f "$site_file" ] || continue
        sed -i -e "s|@WEB_ROOT@|$WEB_ROOT|g" -e "s|@TOOL_REPORT_DIR@|$TOOL_REPORT_DIR|g" -e "s|@PANEL_PORT@|$PANEL_PORT|g" -e "s|@WARNING_PORT@|$WARNING_PORT|g" "$site_file"
        old_root=$(sed -nE 's/^[[:space:]]*DocumentRoot[[:space:]]+([^[:space:]]+).*$/\1/p' "$site_file" | head -n1)
        if [ "$site" = warning ]; then old_root=${old_root%/warning}; fi
        old_port=$(sed -nE 's/^<VirtualHost [^:]+:([0-9]+)>$/\1/p' "$site_file" | head -n1)
        old_config=$(sed -nE 's@^[[:space:]]*Alias /proxymon/squidtool ([^[:space:]]+)$@\1@p' "$site_file" | head -n1)
        if [ -n "$old_root" ]; then
            old_root=${old_root//./\\.}
            sed -i "s|$old_root|$WEB_ROOT|g" "$site_file"
        fi
        if [ -n "$old_config" ]; then
            old_config=${old_config//./\\.}
            sed -i "s|$old_config|$TOOL_REPORT_DIR|g" "$site_file"
        fi
        local site_port="$PANEL_PORT" site_host="127.0.0.1"
        if [ "$site" = warning ]; then site_port="$WARNING_PORT"; site_host="$SERVER_IP"; fi
        sed -i -E "s/^<VirtualHost [^>]+>/<VirtualHost *:$site_port>/" "$site_file"
        printf 'Listen %s:%s\n' "$site_host" "$site_port" >> /etc/apache2/ports.conf
    done
}

# dependencies
check_dependencies() {
    for dep_pkg in wget curl git zip unzip ipset nbtscan libcgi-session-perl libgd-perl libjson-xs-perl coreutils fonts-lato fonts-liberation fonts-dejavu perl cron sudo util-linux iproute2 passwd findutils sed grep hostname ncurses-bin systemd libc-bin iptables gawk gzip procps logrotate; do
        if ! dpkg -s "$dep_pkg" &>/dev/null; then
            if [ "$dep_pkg" = libjson-xs-perl ]; then
                info "Installing missing dependency: $dep_pkg"
                apt-get install -y "$dep_pkg" || abort "cannot install '$dep_pkg' -- abort"
            else
                abort "dependency '$dep_pkg' is not installed -- abort"
            fi
        fi
    done

}

# Installs Apache and PHP. Unlike check_dependencies, these are installed
# instead of merely verified: they are proxymon's own serving layer, not a
# tool it calls.
install_apache2() {
    local dep_pkg missing_pkgs=()

    for dep_pkg in apache2 apache2-bin apache2-data apache2-doc apache2-utils \
                   php libapache2-mod-php php-cli php-curl; do
        dpkg -s "$dep_pkg" &>/dev/null || missing_pkgs+=("$dep_pkg")
    done
    if (( ${#missing_pkgs[@]} == 0 )); then
        info "apache2 and php already present"
        return 0
    fi

    DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "${missing_pkgs[@]}" \
        || { err "cannot install ${missing_pkgs[*]}"; abort "install them with apt, then re-run -- abort"; }
    systemctl enable apache2 &>/dev/null || true
    info "Installed: ${missing_pkgs[*]}"
}

# Installs squid-openssl, the flavour that also supports SSL bump. An existing
# squid or squid-openssl is left untouched, including its squid.conf: the
# administrator's own proxy configuration is never replaced.
install_squid() {
    if dpkg -s squid &>/dev/null || dpkg -s squid-openssl &>/dev/null; then
        info "squid already present, its configuration is kept"
        squid_preexisting=1
        return 0
    fi

    DEBIAN_FRONTEND=noninteractive apt-get -qq install -y squid-openssl squid-langpack squid-common \
        || { err "cannot install squid-openssl"; abort "install it with apt, then re-run -- abort"; }
    systemctl enable squid &>/dev/null || true
    squid_preexisting=0
    info "Installed: squid-openssl squid-langpack squid-common"
}

# Deploys proxymon's squid.conf and replaces its placeholders with the answers
# given during installation. Runs only when install_squid() installed squid: an
# existing squid.conf belongs to the administrator.
deploy_squid_template() {
    if (( squid_preexisting == 1 )); then
        info "squid.conf kept as is, template not deployed"
        return 0
    fi
    [ -f config/squid/squid.conf ] || abort "config/squid/squid.conf not found -- abort"
    cp -f /etc/squid/squid.conf{,.bak} &>/dev/null || true
    cp -f config/squid/squid.conf /etc/squid/squid.conf \
        || abort "cannot write /etc/squid/squid.conf -- abort"
    sed -i "s:192.168.0.0/24:$RANGE:g; s:192.168.0.10:$SERVER_IP:g" /etc/squid/squid.conf
    info "squid.conf deployed with RANGE=$RANGE and SERVER_IP=$SERVER_IP"
}

# Squidmon, Logview and SquidAI read only the current access.log. A rotation
# leaves it empty, so they lose the hours moved to the rotated file. Weekly
# limits that gap to one day out of seven.
set_squid_logrotate() {
    local rotate_file=/etc/logrotate.d/squid
    local hook="runuser -u www-data -- $WEB_ROOT/squidreports/squidreports.pl yesterday --wait-lock"

    if [ ! -f "$rotate_file" ]; then
        warn "$rotate_file not found, rotation left unchanged -- alert"
        return 0
    fi
    cp -f "$rotate_file"{,.bak} &>/dev/null || true
    sed -i -E 's/^([[:space:]]*)(daily|monthly)$/\1weekly/' "$rotate_file"
    if grep -qE '^[[:space:]]*weekly$' "$rotate_file"; then
        info "squid log rotation set to weekly"
    else
        warn "cannot set weekly rotation in $rotate_file -- alert"
    fi
    if grep -qE '^[[:space:]]*(size|maxsize)[[:space:]]' "$rotate_file"; then
        warn "$rotate_file sets size or maxsize, which splits the current day -- alert"
    fi
    if grep -qE "^[[:space:]]*$hook$" "$rotate_file"; then
        info "squid rotation already closes the previous day"
    elif grep -qE '^[[:space:]]*prerotate' "$rotate_file"; then
        warn "$rotate_file already defines prerotate, closing not added -- alert"
    elif ! grep -qE '^[[:space:]]*sharedscripts' "$rotate_file"; then
        warn "$rotate_file has no sharedscripts, closing not added -- alert"
    else
        sed -i "/^[[:space:]]*sharedscripts/a \\    prerotate\n        $hook\n    endscript" "$rotate_file"
        info "squid rotation now closes the previous day first"
    fi
}

squid_preexisting=1
check_dependencies

# conflicting packages
check_conflicts() {
    local role="$1"; shift
    local found=()
    for dep_pkg in "$@"; do
        if dpkg-query -W -f='${Status}' "$dep_pkg" 2>/dev/null | grep -q "ok installed"; then
            found+=("$dep_pkg")
        fi
    done
    if [ "${#found[@]}" -gt 0 ]; then
        for dep_pkg in "${found[@]}"; do
            err "conflicting $role package: $dep_pkg"
        done
        abort "remove them with apt purge -- abort"
    fi
}

# port in use
check_port() {
    local proto="$1" port="$2" role="$3"
    if [ -n "$(ss -lnH "-${proto,,}" "sport = :$port" 2>/dev/null)" ]; then
        err "${proto^^} port $port in use by another $role"
        abort "stop that service before installing -- abort"
    fi
}

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

# ACL download
get_acl() {
    local source_url="$1" target_file="$2" http_code
    http_code=$(curl -k -s -o /dev/null -w '%{http_code}' -I -L --connect-timeout 5 --max-time 15 --retry 1 "$source_url")
    case "$http_code" in
        2*|405) ;;
        000) log "INFO: $(basename "$source_url") timeout -- retry"; return 1 ;;
        5*)  log "INFO: $(basename "$source_url") server busy -- retry"; return 1 ;;
        *)   log "INFO: $(basename "$source_url") http $http_code -- retry"; return 1 ;;
    esac
    # wget has no timeout of its own -- if curl's HEAD check succeeds but
    # the actual transfer stalls (dead connection, slow/black-holed route),
    # wget would otherwise hang forever with nothing printed. --timeout
    # bounds each read/connect phase and --tries=1 stops it from silently
    # retrying on top of retry_cmd's own retry loop.
    if ! timeout 30 wget -q -c -N --timeout=15 --tries=1 "$source_url" -O "$target_file"; then
        log "INFO: $(basename "$source_url") download incomplete -- retry"
        return 1
    fi
    log "INFO: $(basename "$source_url") saved"
}

retry_cmd() {
    local max_retries="${RETRY_CMD_MAX:-10}"
    local retry_delay="${RETRY_CMD_DELAY:-10}"
    local retry_attempt=1
    until "$@"; do
        if [ "$retry_attempt" -ge "$max_retries" ]; then
            if [ "${RETRY_CMD_SOFT_FAIL:-0}" -eq 1 ]; then
                warn "command failed after $max_retries attempts, giving up: $* -- alert"
                return 1
            fi
            abort "command failed after $max_retries attempts: $* -- abort"
        fi
        info "attempt $retry_attempt/$max_retries: $* -- retry"
        retry_attempt=$((retry_attempt + 1))
        sleep "$retry_delay"
    done
}

check_apache_config() {
    if command -v php >/dev/null 2>&1; then
        php_version=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;" 2>/dev/null)
    else
        abort "php not installed -- abort"
    fi

    if [[ ! "$php_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        abort "cannot read php version: '$php_version' -- abort"
    fi

    config_errors=""

    if [ ! -f /etc/apache2/mods-available/mpm_prefork.conf ]; then
        config_errors+="/etc/apache2/mods-available/mpm_prefork.conf not found\n"
    fi

    if [ ! -f /etc/php/$php_version/apache2/php.ini ]; then
        if [ -f /etc/php/$php_version/cli/php.ini ]; then
            mkdir -p /etc/php/$php_version/apache2
            cp /etc/php/$php_version/cli/php.ini /etc/php/$php_version/apache2/php.ini
            info "php.ini copied to /etc/php/$php_version/apache2/"
        else
            config_errors+="php.ini not found\n"
        fi
    fi

    # PHP and mpm_prefork are already installed (see check_dependencies());
    # if their Apache modules just aren't enabled yet, enable them instead
    # of aborting.
    apache_needs_restart=0

    if ! apache2ctl -M 2>/dev/null | grep -q "mpm_prefork"; then
        if a2enmod mpm_prefork >/dev/null 2>&1; then
            info "mpm_prefork module enabled"
            apache_needs_restart=1
        else
            config_errors+="mpm_prefork module is not enabled and could not be enabled automatically\n"
        fi
    fi

    if ! apache2ctl -M 2>/dev/null | grep -qE "php[0-9.]*_module"; then
        if a2enmod "php${php_version}" >/dev/null 2>&1 || a2enmod php >/dev/null 2>&1; then
            info "php module enabled"
            apache_needs_restart=1
        else
            config_errors+="php module is not enabled and could not be enabled automatically\n"
        fi
    fi

    if [[ "$apache_needs_restart" -eq 1 ]]; then
        systemctl restart apache2
    fi

    if [[ -n "$config_errors" ]]; then
        while IFS= read -r config_error; do
            [ -n "$config_error" ] && warn "$config_error -- alert"
        done < <(echo -e "$config_errors")
        abort "invalid apache or php configuration -- abort"
    else
        info "Apache and PHP configuration is valid"
    fi
}

check_squid_traffic() {
    if [ -f "$proxymon_env" ]; then
        load_proxymon_env "$proxymon_env" || abort "cannot load proxymon.env -- abort"
    fi
    local squid_log_file="${SQUID_LOG_FILE:-/var/log/squid/access.log}"
    if [ ! -f "$squid_log_file" ]; then
        abort "$(basename "$squid_log_file") not found -- abort"
    fi

    log_lines=$(wc -l < "$squid_log_file" 2>/dev/null || echo 0)

    if [ "$log_lines" -eq 0 ]; then
        info "access.log empty, no traffic yet"
        echo "Continuing anyway; reports will be empty until traffic starts flowing."
        return 0
    fi

    log_entries=$(grep -cE "TCP_(HIT|MISS|TUNNEL|DENIED|ERROR)" "$squid_log_file" 2>/dev/null || true)
    log_entries=${log_entries:-0}

    if [ "$log_entries" -eq 0 ]; then
        info "no valid traffic found ($log_lines lines, 0 valid)"
        echo "Check Squid ACLs, port, and that clients point at this proxy. Continuing anyway."
    else
        echo "Squid traffic: $log_lines lines, $log_entries valid entries"
    fi
}

run_initial_checks() {
    echo -e "Running initial checks...\n"
    check_conflicts "web server" nginx lighttpd caddy
    check_apache_config
    check_squid_traffic
    echo -e "All checks passed!\n"
}

check_repo() {
    local missing_flag=0
    if [ ! -d "modules" ] || [ -z "$(ls -A "modules" 2>/dev/null)" ]; then
        missing_flag=1
    fi
    if [ ! -d "config" ] || [ -z "$(ls -A "config" 2>/dev/null)" ]; then
        missing_flag=1
    fi
    if [ "$missing_flag" -eq 1 ]; then
        echo ""
        err "repository files not found"
        err "clone it from github.com/maravento/proxymon -- abort"
        echo ""
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

# validation -- one variable per thing validated; use directly with =~
UH_IPV4='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_CIDR='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])/(3[0-2]|[12][0-9]|[0-9])$'

# ------------------------------------------------------------------------------
# ENV
# ------------------------------------------------------------------------------

create_proxymon_env() {
    local env_file="/etc/proxymon/proxymon.env"
    mkdir -p /etc/proxymon

    if [ -f "$env_file" ]; then
        info "$env_file already exists -- skip"
        # Warn if a newer version of this script expects variables
        # not present in an existing env file (version drift).
        local required_keys="WEB_ROOT CONFIG_DIR BACKUP_DIR TOOL_REPORT_DIR SQUIDMON_CONFIG LLM_ENV_FILE REPORT_STATS_PATH PANEL_PORT WARNING_PORT LAN SERVER_IP RANGE REPORT_IP_GLOB SQUIDREPORTS_DIR REPORT_PATH REALNAME_CFG SKIPUSERS_CFG ACL_PATH ACL_MAC_PATH ACL_SQUID_PATH ACL_BANDATA_PATH ALLOW_LIST BLOCK_LIST_DAY BLOCK_LIST_WEEK BLOCK_LIST_MONTH SQUID_LOG_DIR SQUID_LOG_FILE WARNING_HTML CACHE_PATH SQUID_MGR_HOST SQUID_MGR_PORT SQUID_MGR_PASSWD MAX_BANDWIDTH_DAY MAX_BANDWIDTH_WEEK MAX_BANDWIDTH_MONTH BANDATA_HOTSPOT HOTSPOT_PATH UPDATE_REALNAME"
        local missing_flag=""
        for env_key in $required_keys; do
            grep -q "^${env_key}=" "$env_file" || missing_flag="$missing_flag $env_key"
        done
        if [ -n "$missing_flag" ]; then
            warn "$env_file is missing variables expected by this version: $missing_flag -- alert"
            echo " Add them manually, or remove $env_file and re-run install to regenerate."
        fi

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

    # Unattended mode -- a caller (e.g. another installer) sets PROXYMON_LAN
    # with the interface it already knows. Nothing is asked: every remaining
    # value takes its default and is printed as it is taken.
    local unattended=false
    [ -n "${PROXYMON_LAN:-}" ] && unattended=true

    # LAN interface
    if [ "$unattended" = true ]; then
        [ -e "/sys/class/net/$PROXYMON_LAN" ] || abort "PROXYMON_LAN='$PROXYMON_LAN' not found on this system -- abort"
        lan_answer="$PROXYMON_LAN"
        echo "LAN interface: $lan_answer (preset)"
    else
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
    fi

    # Server IP -- PROXYMON_SERVER_IP takes precedence when the caller
    # supplies it. Otherwise it comes from the interface chosen above.
    mapfile -t iface_ips < <(ip -o -4 addr show dev "$lan_answer" scope global | awk '{print $4}' | cut -d/ -f1)
    if [ -n "${PROXYMON_SERVER_IP:-}" ]; then
        [[ "$PROXYMON_SERVER_IP" =~ $UH_IPV4 ]] || abort "PROXYMON_SERVER_IP='$PROXYMON_SERVER_IP' is not a valid IPv4 address -- abort"
        server_ip_answer="$PROXYMON_SERVER_IP"
        echo "Server IP for LAN: $server_ip_answer (preset)"
    else
        case "${#iface_ips[@]}" in
            0)
                abort "interface '$lan_answer' has no IPv4 address configured -- abort"
                ;;
            1)
                server_ip_answer="${iface_ips[0]}"
                echo "Server IP for LAN: $server_ip_answer (from $lan_answer)"
                ;;
            *)
                if [ "$unattended" = true ]; then
                    server_ip_answer="${iface_ips[0]}"
                    echo "Server IP for LAN: $server_ip_answer (first of ${#iface_ips[@]} on $lan_answer)"
                else
                    echo "Interface '$lan_answer' has multiple IPv4 addresses:"
                    PS3="Select IP number: "
                    select server_ip_answer in "${iface_ips[@]}"; do
                        [ -n "$server_ip_answer" ] && break
                    done
                    unset PS3
                fi
                ;;
        esac
    fi

    # Glob pattern used to match per-IP report filenames under REPORT_PATH
    # (e.g. bandata.sh's "for file in $REPORT_IP_GLOB"). This is NOT a
    # network range -- it's a filename-matching pattern derived from the
    # server's own /24, since report files are named after client IPs.
    report_glob="$(echo "$server_ip_answer" | cut -d'.' -f1-3).*"

    # Real network range (CIDR) for the LAN this server serves -- used to
    # restrict the web panel to LAN clients. Derived from the same /24
    # assumption as above. For a non-standard subnet, edit RANGE manually
    # in /etc/proxymon/proxymon.env after installation.
    lan_range="$(echo "$server_ip_answer" | cut -d'.' -f1-3).0/24"

    # Bandwidth limits -- validate with numfmt (accepts e.g. 500M, 1G, 1.5G)
    read_bandwidth() {
        local prompt_text="$1" default_value="$2" user_answer
        if [ "$unattended" = true ]; then
            echo "$default_value"
            return
        fi
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
    if [ "$unattended" = true ]; then
        echo "Max bandwidth per day: $bw_day (default)"
        echo "Max bandwidth per week: $bw_week (default)"
        echo "Max bandwidth per month: $bw_month (default)"
    fi

    # Unifi Hotspot Manager -- enabled when uhm is installed and its ACL exists
    hotspot_dir="/etc/uhm"
    if [ -f "$hotspot_dir/uhm.env" ] && [ -f "$hotspot_dir/acl/uhm-auth.txt" ]; then
        hotspot_enabled=true
    else
        hotspot_enabled=false
    fi
    echo "Unifi Hotspot in Bandata: $hotspot_enabled"

    # Auto-update Squidreports names and groups
    update_realname_flag=true
    echo "Update hostnames and groups in Squidreports: $update_realname_flag (default)"

    cat > "$env_file" << ENVEOF
# =============================================================================
# Proxymon
# /etc/proxymon/proxymon.env
# =============================================================================
# Generated by pmsetup.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Edit manually if needed. Re-run pmsetup.sh --install to regenerate.

# General
WEB_ROOT=${WEB_ROOT}
CONFIG_DIR=${CONFIG_DIR}
PANEL_PORT=${PANEL_PORT}

# Network
LAN=${lan_answer}
SERVER_IP=${server_ip_answer}
RANGE=${lan_range}

# Squid
SQUID_LOG_DIR=/var/log/squid
SQUID_LOG_FILE=\$SQUID_LOG_DIR/access.log
SQUID_MGR_HOST=127.0.0.1
SQUID_MGR_PORT=3128
SQUID_MGR_PASSWD=

# ACL
ACL_PATH=/etc/acl
ACL_MAC_PATH=\$ACL_PATH/mac
ACL_SQUID_PATH=\$ACL_PATH/squid

# Squidreports
SQUIDREPORTS_DIR=${WEB_ROOT}/squidreports
REPORT_PATH=\$SQUIDREPORTS_DIR/report
REPORT_STATS_PATH=${REPORT_STATS_PATH}
REALNAME_CFG=\$SQUIDREPORTS_DIR/realname.cfg
SKIPUSERS_CFG=\$SQUIDREPORTS_DIR/skipuser.cfg

# Squidmon
SQUIDMON_CONFIG=${SQUIDMON_CONFIG}

# SquidAI
LLM_ENV_FILE=${LLM_ENV_FILE}
CACHE_PATH=/var/cache/proxymon

# Squidtool
TOOL_REPORT_DIR=${TOOL_REPORT_DIR}

# Bandata
REPORT_IP_GLOB=${report_glob}
ACL_BANDATA_PATH=${CONFIG_DIR}/bandata/acl
ALLOW_LIST=\$ACL_BANDATA_PATH/allowdata.txt
BLOCK_LIST_DAY=\$ACL_BANDATA_PATH/banday.txt
BLOCK_LIST_WEEK=\$ACL_BANDATA_PATH/banweek.txt
BLOCK_LIST_MONTH=\$ACL_BANDATA_PATH/banmonth.txt
MAX_BANDWIDTH_DAY=${bw_day}
MAX_BANDWIDTH_WEEK=${bw_week}
MAX_BANDWIDTH_MONTH=${bw_month}
WARNING_PORT=${WARNING_PORT}
WARNING_HTML=${WEB_ROOT}/warning/warning.html
BANDATA_HOTSPOT=${hotspot_enabled}
HOTSPOT_PATH=${hotspot_dir}
UPDATE_REALNAME=${update_realname_flag}

# Backup
BACKUP_DIR=${BACKUP_DIR}
# =============================================================================
ENVEOF

    chmod 640 "$env_file"
    chown root:www-data "$env_file"
    echo "$env_file created"
    printf "\n"
}

# ------------------------------------------------------------------------------
# INSTALL
# ------------------------------------------------------------------------------

# CRON_D
# Add or replace one line in the project's single cron.d file
cron_d_set() {
    local match="$1" line="$2"
    local cron_file="/etc/cron.d/proxymon"
    local cron_tmp

    cron_tmp=$(mktemp)
    [ -f "$cron_file" ] && { grep -vF "$match" "$cron_file" > "$cron_tmp" || true; }
    [ -n "$line" ] && printf '%s\n' "$line" >> "$cron_tmp"
    if [ -s "$cron_tmp" ]; then
        install -m 644 -o root -g root "$cron_tmp" "$cron_file"
    else
        rm -f "$cron_file"
    fi
    rm -f "$cron_tmp"
}

do_install() {
    install_apache2
    install_squid
    run_initial_checks
    configure_locations
    if [[ -d "$WEB_ROOT" ]]; then
        abort "proxymon already installed -- abort"
    fi

    check_port tcp "$PANEL_PORT" "web interface"
    check_port tcp "$WARNING_PORT" "warning page"

    check_repo
    create_proxymon_env
    load_proxymon_env "$proxymon_env" || abort "cannot load proxymon.env -- abort"
    # modules/ is served by Apache. config/ is only
    # read or executed by root, so it lives outside the web tree. vhost/ is
    # not project content: Apache reads it from its own directory.
    mkdir -p "$WEB_ROOT"
    cp -rf modules/* "$WEB_ROOT"/

    mkdir -p "$CONFIG_DIR"
    cp -rf config/bandata config/tools "$CONFIG_DIR"/

    info "Configuring Apache..."

    if [[ -f "config/vhost/proxymon.conf" ]]; then
        cp -f config/vhost/proxymon.conf /etc/apache2/sites-available/proxymon.conf
        info "Proxymon virtualhost configured"
    fi

    if [[ -f "config/vhost/warning.conf" ]]; then
        cp -f config/vhost/warning.conf /etc/apache2/sites-available/warning.conf
        info "Warning virtualhost configured"
    fi

    [ -f /etc/apache2/ports.conf.bak ] || cp -f /etc/apache2/ports.conf{,.bak} &>/dev/null || true

    info "Configuring Squid Monitor..."

    info "Configuring Squidreports..."
    if "$WEB_ROOT/squidreports/squidreports.pl" today; then
        info "initial squidreports report generated"
    else
        warn "cannot generate initial squidreports -- alert"
    fi

    configure_apache_locations

    info "Configuring ACL directories and files..."
    # Load env to get ACL paths defined by create_proxymon_env()
    # Verify ownership/permissions before sourcing -- this file is executed
    # as root, so it must not be writable by anyone other than root.
    env_file_path="$proxymon_env"
    env_owner=$(stat -c '%U' "$env_file_path" 2>/dev/null)
    env_perms=$(stat -c '%a' "$env_file_path" 2>/dev/null)
    env_group_digit="${env_perms: -2:1}"
    env_other_digit="${env_perms: -1}"
    if [ "$env_owner" != "root" ] || [[ "$env_group_digit" =~ [2367] ]] || [[ "$env_other_digit" =~ [2367] ]]; then
        err "$env_file_path owner=$env_owner perms=$env_perms"
        err "expected root owner, no group/other write access -- abort"
        exit 1
    fi
    load_proxymon_env "$env_file_path" || abort "cannot load proxymon.env -- abort"

    # Create ACL directories
    # ACL_BANDATA_PATH is not created here: it ships inside config/bandata/acl/
    # with its 4 files already present, copied to $CONFIG_DIR above and
    # given root ownership by the "Setting Permissions" step below.
    mkdir -p "$ACL_PATH" "$ACL_MAC_PATH" "$ACL_SQUID_PATH"
    chmod 755 "$ACL_PATH" "$ACL_MAC_PATH" "$ACL_SQUID_PATH"
    chown root:root "$ACL_PATH" "$ACL_MAC_PATH" "$ACL_SQUID_PATH"
    info "ACL directories created"

    # Create Squidreports report directory if it does not exist
    mkdir -p "$REPORT_PATH"
    chmod 755 "$REPORT_PATH"
    chown -hR www-data:www-data "$REPORT_PATH"
    mkdir -p "$REPORT_STATS_PATH"
    chmod 755 "$REPORT_STATS_PATH"
    chown -hR www-data:www-data "$REPORT_STATS_PATH"
    info "Squidreports report directory ready"

    info "downloading ACL lists"

    # These blocklists are optional hardening, not required for Proxymon
    # to run -- a failed/slow download must not hang or abort the whole
    # install. Fewer, shorter retries here (with feedback on the way in
    # and out), and a soft failure just skips that one file with a warning.

    echo "  - blocktlds.txt ..."
    if RETRY_CMD_MAX=3 RETRY_CMD_DELAY=5 RETRY_CMD_SOFT_FAIL=1 retry_cmd get_acl https://raw.githubusercontent.com/maravento/blackweb/refs/heads/master/bwupdate/lst/blocktlds.txt "$ACL_SQUID_PATH/blocktlds.txt"; then
        chmod 644 "$ACL_SQUID_PATH/blocktlds.txt"
        chown root:root "$ACL_SQUID_PATH/blocktlds.txt"
        echo "    done: $ACL_SQUID_PATH/blocktlds.txt"
    else
        warn "blocktlds.txt not downloaded -- alert"
    fi

    echo "  - blockdomains.txt ..."
    if RETRY_CMD_MAX=3 RETRY_CMD_DELAY=5 RETRY_CMD_SOFT_FAIL=1 retry_cmd get_acl https://raw.githubusercontent.com/maravento/blackweb/refs/heads/master/bwupdate/lst/debugbl.txt "$ACL_SQUID_PATH/blockdomains.txt"; then
        chmod 644 "$ACL_SQUID_PATH/blockdomains.txt"
        chown root:root "$ACL_SQUID_PATH/blockdomains.txt"
        echo "    done: $ACL_SQUID_PATH/blockdomains.txt"
    else
        warn "blockdomains.txt not downloaded -- alert"
    fi

    echo "  - blockpatterns.txt ..."
    if RETRY_CMD_MAX=3 RETRY_CMD_DELAY=5 RETRY_CMD_SOFT_FAIL=1 retry_cmd get_acl https://raw.githubusercontent.com/maravento/vault/refs/heads/master/gateproxy/acl/squid/blockpatterns.txt "$ACL_SQUID_PATH/blockpatterns.txt"; then
        chmod 644 "$ACL_SQUID_PATH/blockpatterns.txt"
        chown root:root "$ACL_SQUID_PATH/blockpatterns.txt"
        echo "    done: $ACL_SQUID_PATH/blockpatterns.txt"
    else
        warn "blockpatterns.txt not downloaded -- alert"
    fi

    info "ACL lists step finished"

    cron_d_set "$CONFIG_DIR/bandata/bandata.sh" "*/5 * * * * root $CONFIG_DIR/bandata/bandata.sh"
    info "Squid Monitor cron entry added"

    # Squidreports runs as www-data. In /etc/cron.d the user is a field of
    # the line, so it lives in the project's own file.
    cron_d_set "squidreports.pl today" "*/10 * * * * www-data $WEB_ROOT/squidreports/squidreports.pl today"
    cron_d_set "squidreports.pl yesterday" "5 0 * * * www-data $WEB_ROOT/squidreports/squidreports.pl yesterday --wait-lock"

    info "proxymon cron entry updated (Squidreports)"

    info " Updating Prefork MPM..."
    [ -f /etc/apache2/mods-available/mpm_prefork.conf.bak ] || cp -f /etc/apache2/mods-available/mpm_prefork.conf{,.bak} &>/dev/null || true
    sed -i \
      -e 's/^\(StartServers[[:space:]]*\)5/\110/' \
      -e 's/^\(MinSpareServers[[:space:]]*\)5/\110/' \
      -e 's/^\(MaxSpareServers[[:space:]]*\)10/\115/' \
      -e 's/^\(MaxRequestWorkers[[:space:]]*\)150/\1200/' \
      -e 's/^\(MaxConnectionsPerChild[[:space:]]*\)0/\11000/' \
    /etc/apache2/mods-available/mpm_prefork.conf

    info " Updating PHP..."
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
    info " Updating Apache2 Security..."
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

    info "Configuring SquidAI..."
    mkdir -p "$CONFIG_DIR" "$(dirname "$LLM_ENV_FILE")"
    if [ ! -f "$LLM_ENV_FILE" ]; then
        cat > "$LLM_ENV_FILE" << 'EOF'
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
    chmod 640 "$LLM_ENV_FILE"
    chown root:www-data "$LLM_ENV_FILE"
    chmod 750 "$CONFIG_DIR"
    chown root:www-data "$CONFIG_DIR"
    mkdir -p "$CACHE_PATH"
    chmod 750 "$CACHE_PATH"
    chown www-data:www-data "$CACHE_PATH"
    info "SquidAI config directory created: $CONFIG_DIR/"
    info "Edit $LLM_ENV_FILE and set your LLM credentials"

    info " Setting Permissions..."
    find "$WEB_ROOT" -type d -exec chmod 755 {} +
    find "$WEB_ROOT" -type f -exec chmod 644 {} +
    find "$WEB_ROOT" -type f -name "*.cgi" -exec chmod +x {} +
    chmod +x "$WEB_ROOT/squidreports/squidreports.pl"
    secure_web_code "$WEB_ROOT" 0 || abort "cannot secure web code -- abort"
    if [ "$SQUIDMON_CONFIG" != "$WEB_ROOT/squidmon/etc/config" ]; then
        mkdir -p "$(dirname "$SQUIDMON_CONFIG")"
        [ -f "$SQUIDMON_CONFIG" ] || cp "$WEB_ROOT/squidmon/etc/config" "$SQUIDMON_CONFIG"
    fi
    chown -h www-data:www-data "$SQUIDMON_CONFIG"

    find "$CONFIG_DIR/bandata" "$CONFIG_DIR/tools" -type d -exec chmod 755 {} +
    find "$CONFIG_DIR/bandata" "$CONFIG_DIR/tools" -type f -exec chmod 644 {} +
    chmod 755 "$CONFIG_DIR/bandata/bandata.sh"
    chmod 755 "$CONFIG_DIR/tools/pmbk.sh"
    chmod 755 "$CONFIG_DIR/tools/squidtool.sh"
    chown -R root:root "$CONFIG_DIR/bandata" "$CONFIG_DIR/tools"
    if ! getent group proxy >/dev/null; then
        groupadd proxy || abort "cannot create group 'proxy' -- abort"
        info "group 'proxy' created -- fixed"
    fi
    usermod -aG proxy www-data
    deploy_squid_template
    set_squid_logrotate
    chown root:root /etc/squid/squid.conf
    chmod 644 /etc/squid/squid.conf

    info " Setting Logs..."
    touch /var/log/apache2/{warning_access,warning_error,proxymon_access,proxymon_error}.log
    chown root:adm /var/log/apache2/{warning_access,warning_error,proxymon_access,proxymon_error}.log
    chmod 640 /var/log/apache2/{warning_access,warning_error,proxymon_access,proxymon_error}.log

    shopt -s nullglob
    squid_logs=("$SQUID_LOG_DIR"/*.log)
    if [ ${#squid_logs[@]} -gt 0 ]; then
        chown proxy:proxy "${squid_logs[@]}"
        chmod 640 "${squid_logs[@]}"
    else
        info "No /var/log/squid/*.log files found yet -- skip"
    fi
    shopt -u nullglob

    info " Enabling Apache Modules..."
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

    info " Enabling Apache Sites..."
    a2ensite proxymon.conf || abort "cannot enable proxymon.conf -- abort"
    a2ensite warning.conf || abort "cannot enable warning.conf -- abort"

    info " Restarting Cron..."
    systemctl restart cron

    info " Restarting Apache2..."
    systemctl daemon-reload
    if ! apachectl -t -D DUMP_INCLUDES -S &>/dev/null; then
        a2dissite proxymon.conf 2>/dev/null || true
        a2dissite warning.conf 2>/dev/null || true
        err "Apache configuration test failed, sites just enabled disabled"
        err "fix the configuration, then re-run install -- abort"
        exit 1
    fi
    info "Apache configuration OK"
    systemctl restart apache2

    info " Check Active Apache sites:"
    a2query -s

    if [ -x "$CONFIG_DIR/tools/pmbk.sh" ]; then
        info "Registering pmbk.sh monthly cron entry ..."
        "$CONFIG_DIR/tools/pmbk.sh" install || warn "cron entry not registered -- alert"
    fi

    info "Proxy Monitor installed successfully"
    # The panel is bound to loopback above and proxymon.conf allows 127.0.0.1
    # only, so announcing the server IP would send the administrator to an
    # address that refuses the connection. The warning portal is the one bound
    # to the LAN, and it is announced with the server IP.
    info "Access Proxy Monitor: http://127.0.0.1:${PANEL_PORT}"
    info "Access Warning Portal: http://${SERVER_IP}:${WARNING_PORT}"
}

web_preserved_paths=(
    "squidreports/report"
    "squidreports/reportstats"
    "squidreports/realname.cfg"
    "squidreports/skipuser.cfg"
    "squidreports/squidreports.cfg"
    "squidreports/group.cfg"
    "squidmon/etc/config"
    "warning/warning.html"
)

secure_web_code() (
    local target="$1" copy_code="$2" src_path rel_path dest_path preserved
    local source_root="$PWD/modules"
    local -a prune_args=()

    if [ -L "$target" ] || [ ! -d "$target" ]; then
        err "web root must be a real directory: $target -- abort"
        return 1
    fi
    cd -P -- "$target" || return 1
    if [ "$(pwd -P)" != "$target" ]; then
        err "web root has a symbolic link in its path: $target -- abort"
        return 1
    fi
    chown root:root . || return 1
    chmod 755 . || return 1
    for preserved in "${web_preserved_paths[@]}"; do
        prune_args+=(-path "$source_root/$preserved" -o)
    done
    prune_args+=(-false)

    while IFS= read -r -d '' src_path; do
        rel_path="${src_path#"$source_root/"}"
        dest_path="./$rel_path"
        if [ -d "$src_path" ]; then
            if [ -L "$dest_path" ]; then
                err "code directory is a symbolic link: $dest_path -- abort"
                return 1
            fi
            mkdir -p "$dest_path" || return 1
            chown root:root "$dest_path" || return 1
            chmod 755 "$dest_path" || return 1
        else
            if [ "$copy_code" = 1 ]; then
                cp -f -T --remove-destination -- "$src_path" "$dest_path" || return 1
            elif [ -L "$dest_path" ]; then
                err "code file is a symbolic link: $dest_path -- abort"
                return 1
            fi
            chown root:root "$dest_path" || return 1
            case "$rel_path" in
                *.cgi|squidreports/squidreports.pl) chmod 755 "$dest_path" || return 1 ;;
                *) chmod 644 "$dest_path" || return 1 ;;
            esac
        fi
    done < <(find "$source_root" -mindepth 1 \( "${prune_args[@]}" \) -prune -o -print0)
    return 0
)

# ------------------------------------------------------------------------------
# UPDATE
# ------------------------------------------------------------------------------

# Refreshes code under $WEB_ROOT and the root scripts under
# $CONFIG_DIR. Keeps data and configuration files. Reads existing
# location/port keys, applies Apache paths/ports and refreshes module cron
# entries. Copies every file under modules/ except web_preserved_paths.

do_update() {
    configure_locations
    if [[ ! -d "$WEB_ROOT" ]]; then
        abort "proxymon not installed -- abort"
    fi

    local configured_port old_ports
    old_ports=$(sed -nE 's/^<VirtualHost [^:]+:([0-9]+)>$/\1/p' /etc/apache2/sites-available/proxymon.conf /etc/apache2/sites-available/warning.conf 2>/dev/null || true)
    for configured_port in "$PANEL_PORT" "$WARNING_PORT"; do
        if ! grep -qx "$configured_port" <<< "$old_ports"; then
            if grep -qE "^Listen ([^[:space:]]*:)?${configured_port}([[:space:]]|$)" /etc/apache2/ports.conf; then
                abort "port $configured_port already belongs to Apache -- abort"
            fi
            check_port tcp "$configured_port" "configured application port"
        fi
    done

    check_repo

    systemctl stop apache2
    info "apache2 stopped for update"
    trap 'systemctl start apache2 >/dev/null 2>&1 || true' EXIT

    if bash "$script_dir/config/tools/pmbk.sh"; then
        info "backup taken with pmbk.sh"
    else
        warn "backup failed, continuing -- alert"
    fi

    secure_web_code "$WEB_ROOT" 1 || abort "cannot update web code -- abort"
    rm -f -- "$WEB_ROOT/squidreports/weekly.cgi"
    rm -f -- "$WEB_ROOT/squidreports/ip2name/ip2name.dhcp"
    info "updated web code in $WEB_ROOT"

    # The root scripts, copied one by one. config/bandata/acl/ is live data
    # and config/vhost/ is Apache configuration, so neither is touched.
    mkdir -p "$CONFIG_DIR/bandata" "$CONFIG_DIR/tools"
    cp -f config/bandata/bandata.sh "$CONFIG_DIR/bandata/bandata.sh"
    info "updated bandata/bandata.sh"
    cp -f config/tools/pmbk.sh "$CONFIG_DIR/tools/pmbk.sh"
    info "updated tools/pmbk.sh"
    install -m 644 -o root -g root config/tools/proxymonenv.sh "$CONFIG_DIR/tools/proxymonenv.sh"
    info "updated tools/proxymonenv.sh"
    rm -f -- "$CONFIG_DIR/tools/proxymon-env.sh"
    cp -f config/tools/squidtool.sh "$CONFIG_DIR/tools/squidtool.sh"
    info "updated tools/squidtool.sh"

    for data_dir in "$REPORT_PATH" "$REPORT_STATS_PATH"; do
        [ -d "$data_dir" ] || install -d -m 755 -o www-data -g www-data "$data_dir"
    done

    [ -d "$TOOL_REPORT_DIR" ] || install -d -m 755 -o root -g root "$TOOL_REPORT_DIR"

    info "Live data left untouched"

    chmod 755 "$CONFIG_DIR/bandata/bandata.sh"
    chmod 755 "$CONFIG_DIR/tools/pmbk.sh"
    chmod 755 "$CONFIG_DIR/tools/squidtool.sh"
    chown root:root "$CONFIG_DIR/bandata/bandata.sh"
    chown root:root "$CONFIG_DIR/tools/pmbk.sh"
    chown root:root "$CONFIG_DIR/tools/squidtool.sh"
    info "Permissions set"

    configure_apache_locations
    set_squid_logrotate
    cron_d_set "squidreports.pl today" "*/10 * * * * www-data $WEB_ROOT/squidreports/squidreports.pl today"
    cron_d_set "squidreports.pl yesterday" "5 0 * * * www-data $WEB_ROOT/squidreports/squidreports.pl yesterday --wait-lock"
    cron_d_set "bandata.sh" "*/5 * * * * root $CONFIG_DIR/bandata/bandata.sh"
    cron_d_set "pmbk.sh" "@monthly root $CONFIG_DIR/tools/pmbk.sh"
    apache2ctl configtest || abort "Apache configuration invalid -- abort"

    trap - EXIT
    if systemctl start apache2; then
        info "apache2 started"
    else
        err "Apache failed to start -- abort"
        exit 1
    fi

    info "Proxy Monitor updated successfully"
}

# ------------------------------------------------------------------------------
# UNINSTALL
# ------------------------------------------------------------------------------

do_uninstall() {
    read -p "Are you sure you want to uninstall? (y/n): " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "uninstall cancelled -- skip"
        return 0
    fi
    configure_locations
    info "for a backup, run $CONFIG_DIR/tools/pmbk.sh first"
    info " Uninstalling Proxy Monitor..."

    if [[ ! -d "$WEB_ROOT" ]] && [[ ! -d "$CONFIG_DIR" ]]; then
        info " Proxy Monitor is not installed"
        return 0
    fi

    rm -f /etc/cron.d/proxymon
    info "proxymon cron entries removed"

    if command -v iptables >/dev/null 2>&1; then
        # Remove FORWARD/INPUT jumps into the Bandata chains by rule number
        # (matched by target name, so this works regardless of which LAN
        # interface bandata.sh was configured with).
        for chain_pair in "FORWARD:BANDATA_FWD" "INPUT:BANDATA_IN"; do
            base_chain="${chain_pair%%:*}"
            target_chain="${chain_pair##*:}"
            while true; do
                if ! rule_num=$(iptables -L "$base_chain" --line-numbers -n 2>/dev/null | awk -v t="$target_chain" '$2==t && !found {print $1; found=1}'); then
                    warn "cannot query $base_chain; continuing uninstall -- alert"
                    break
                fi
                [ -n "$rule_num" ] || break
                if ! iptables -D "$base_chain" "$rule_num" 2>/dev/null; then
                    warn "cannot remove $target_chain jump; continuing uninstall -- alert"
                    break
                fi
            done
        done

        # Remove the NAT redirect to the warning portal
        while true; do
            if ! rule_num=$(iptables -t nat -L PREROUTING --line-numbers -n 2>/dev/null | awk '/match-set bandata/ && !found {print $1; found=1}'); then
                warn "cannot query NAT rules; continuing uninstall -- alert"
                break
            fi
            [ -n "$rule_num" ] || break
            if ! iptables -t nat -D PREROUTING "$rule_num" 2>/dev/null; then
                warn "cannot remove Bandata redirect; continuing uninstall -- alert"
                break
            fi
        done

        # Flush and remove the now-unreferenced Bandata chains
        for bandata_chain in BANDATA_FWD BANDATA_IN; do
            if iptables -L "$bandata_chain" -n &>/dev/null; then
                iptables -F "$bandata_chain" 2>/dev/null || warn "cannot flush $bandata_chain -- alert"
                iptables -X "$bandata_chain" 2>/dev/null || warn "cannot remove $bandata_chain -- alert"
            fi
        done
        info "Bandata iptables cleanup finished"
    fi

    if command -v ipset >/dev/null 2>&1 && ipset list bandata &>/dev/null; then
        ipset destroy bandata 2>/dev/null && echo "Bandata ipset destroyed" \
            || warn "cannot destroy ipset 'bandata', remove it manually -- alert"
    fi

    if [[ -f "/etc/apache2/mods-available/mpm_prefork.conf.bak" ]]; then
        mv -f /etc/apache2/mods-available/mpm_prefork.conf.bak /etc/apache2/mods-available/mpm_prefork.conf
        info "mpm_prefork configuration restored"
    fi

    php_version=""
    if command -v php >/dev/null 2>&1; then
        php_version=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;" 2>/dev/null || true)
    fi
    if [[ -n "$php_version" && -f "/etc/php/$php_version/apache2/php.ini.bak" ]]; then
        mv -f "/etc/php/$php_version/apache2/php.ini.bak" "/etc/php/$php_version/apache2/php.ini"
        info "php.ini restored"
    fi

    if [[ -f "/etc/apache2/conf-available/security.conf.bak" ]]; then
        mv -f /etc/apache2/conf-available/security.conf.bak /etc/apache2/conf-available/security.conf
        info "security.conf restored"
    fi

    if [[ -f "/etc/apache2/apache2.conf.bak" ]]; then
        mv -f /etc/apache2/apache2.conf.bak /etc/apache2/apache2.conf
        info "apache2.conf restored"
    fi

    if [[ -f "/etc/apache2/sites-available/proxymon.conf" ]]; then
        a2dissite proxymon.conf 2>/dev/null || true
        rm -f /etc/apache2/sites-available/proxymon.conf
        info "Proxymon site disabled"
    fi

    if [[ -f "/etc/apache2/sites-available/warning.conf" ]]; then
        a2dissite warning.conf 2>/dev/null || true
        rm -f /etc/apache2/sites-available/warning.conf
        info "Warning site disabled"
    fi

    if [[ -x "$CONFIG_DIR/tools/pmbk.sh" ]]; then
        "$CONFIG_DIR/tools/pmbk.sh" uninstall || true
    fi

    if [[ -d "$WEB_ROOT" ]]; then
        rm -rf "$WEB_ROOT"
        info "Installation directory removed"
    fi

    if [[ -d "$CACHE_PATH" ]]; then
        rm -rf "$CACHE_PATH"
        info "Cache directory removed"
    fi

    if [[ -d "$CONFIG_DIR" ]]; then
        read -p "Remove $CONFIG_DIR/ (contains LLM credentials, root scripts and Bandata lists)? (y/n): " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$CONFIG_DIR"
            info "Config directory removed"
        else
            info " $CONFIG_DIR kept -- remove manually if needed"
        fi
    fi

    sed -i -E "/^Listen [^[:space:]]*:${PANEL_PORT}\$/d; /^Listen ${PANEL_PORT}\$/d" /etc/apache2/ports.conf
    info "Port $PANEL_PORT removed from Apache"

    sed -i -E "/^Listen [^[:space:]]*:${WARNING_PORT}\$/d; /^Listen ${WARNING_PORT}\$/d" /etc/apache2/ports.conf
    info "Port $WARNING_PORT removed from Apache"

    rm -f /var/log/apache2/{warning_access,warning_error,proxymon_access,proxymon_error}.log*
    info "Proxymon log files removed"

    rm -f /etc/logrotate.d/bandata /var/log/bandata.log*
    info "Bandata logrotate config and log files removed"

    systemctl restart cron
    systemctl daemon-reload
    systemctl restart apache2

    info " Remaining Apache sites:"
    a2query -s

    info "Proxy Monitor uninstalled successfully"
    info "Restart the computer to clear any remaining temporary Bandata rules."
}

# ------------------------------------------------------------------------------
# MENU
# ------------------------------------------------------------------------------

# Interactive menu shown when the script runs without arguments
show_menu() {
    while true; do
        echo ""
        echo "proxymon installer"
        echo "------------------"
        echo "1) Install"
        echo "2) Update"
        echo "3) Uninstall"
        echo "4) Exit"
        echo ""
        read -p "Select option [4]: " menu_option
        menu_option="${menu_option:-4}"
        case "$menu_option" in
            1) do_install; break ;;
            2) do_update; break ;;
            3) do_uninstall; break ;;
            4) exit 0 ;;
            *) info "invalid option -- retry" ;;
        esac
    done
}

usage() {
    cat <<USAGE_END
Usage: $(basename "$0") [--install|--update|--uninstall]

  --install      Fresh install
  --update       Refresh code, keep live data
  --uninstall    Remove proxymon, after confirmation
  -h, --help     Show this message

Without arguments it opens the interactive menu.
USAGE_END
}

# ------------------------------------------------------------------------------
# ACTIONS
# ------------------------------------------------------------------------------

# Run the action given on the command line, or fall back to the menu
case "${1:-}" in
    --install) do_install ;;
    --update) do_update ;;
    --uninstall) do_uninstall ;;
    "") show_menu ;;
    -h|--help) usage ;;
    *)
        err "unknown option $1 -- abort"
        usage
        exit 1
        ;;
esac
