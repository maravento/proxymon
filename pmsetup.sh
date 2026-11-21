#!/bin/bash
# maravento.com
#
################################################################################
#
# pmsetup -- installer for proxymon
# FILE: pmsetup.sh
#
# USAGE:
# COMMAND                           ACTION
# sudo bash pmsetup.sh --install    Fresh install
# sudo bash pmsetup.sh --update     Refresh code, keep live data
# sudo bash pmsetup.sh --uninstall  Remove proxymon
# sudo bash pmsetup.sh              Interactive menu
# sudo bash pmsetup.sh -h           Show usage
# sudo bash pmsetup.sh --help       Show usage
#
# LOG: pmsetup.log, in this script's directory
#
################################################################################

set -Euo pipefail

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# root check
if [ "$(id -u)" != "0" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: This script must be run as root -abort" >&2
    exit 1
fi

# error handling
report_failure() {
    local failure_text="$failure_message"
    failure_text+=" -abort"
    if declare -F err >/dev/null; then
        err "$failure_text"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: $failure_text" >&2
    fi
}

failure_message="cannot initialize Proxymon"
trap 'report_failure; exit 1' ERR

check_requirements() {
    local network_command
    for network_command in ip awk python3; do
        command -v "$network_command" >/dev/null 2>&1 \
            || abort "network command '$network_command' missing -abort"
    done
    configure_locations
    case "$1" in
        install)
            run_initial_checks
            check_repo
            [ ! -d "$WEB_ROOT" ] || abort "proxymon installed; use --update | --uninstall -abort"
            check_port tcp "$PANEL_PORT" "web interface"
            check_port tcp "$WARNING_PORT" "warning page"
            require_static_lan_candidate
            check_conflicts "web server" nginx lighttpd caddy
            choose_lan_interface "${PROXYMON_LAN:-${LAN:-}}"
            lan_answer="$lan_iface_answer"
            read_lan_ipv4 "$lan_answer" "${PROXYMON_SERVER_IP:-${SERVER_IP:-}}"
            check_static_lan "$lan_answer" "${lan_cidr_answer%/*}"
            server_ip_answer="${lan_cidr_answer%/*}"
            ;;
        update)
            [ -d "$WEB_ROOT" ] || abort "proxymon is not installed -abort"
            local network_key
            for network_key in LAN SERVER_IP; do
                [ -n "${!network_key:-}" ] \
                    || abort "$network_key not set -abort"
            done
            choose_lan_interface "${LAN:-}"
            check_static_lan "${LAN:-}" "${SERVER_IP:-}"
            ;;
    esac
    check_ipv4_interfaces
    if [ "$1" = install ]; then
        check_internet
    else
        local package
        for package in "${apt_deps[@]}"; do
            if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null \
                | grep -q "ok installed"; then
                check_internet
                break
            fi
        done
    fi
}

# prevent overlapping runs
script_lock="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$script_lock") || {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: cannot open $(basename "$script_lock") -abort" >&2
    exit 1
}
failure_message="cannot open the installer lock"
exec 200>"$script_lock"

if ! flock -n 200; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: script $(basename "$0") is already running -abort" >&2
    exit 1
fi

failure_message="cannot find the installer directory"
script_dir="$(cd "$(dirname "$(realpath "$0")")" && pwd)"

# Every repository path below is relative to the script, not to wherever the
# administrator happened to be standing when running it
cd "$script_dir" || { echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: cannot enter $script_dir -abort" >&2; exit 1; }

log_file="${script_dir}/pmsetup.log"
{ > "$log_file"; } 2>/dev/null || true
log() {
    local msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
    echo "$msg" >> "$log_file" 2>/dev/null || true
    if [[ "$1" == ERROR:* ]]; then echo "$msg" >&2; else echo "$msg"; fi
}
info() { log "INFO: $*"; }
warn() { log "WARNING: $*"; }
err()  { log "ERROR: $*"; }
abort() { err "$*"; exit 1; }

configure_locations() {
    unset WEB_ROOT CONFIG_DIR PANEL_PORT WARNING_PORT
    unset TOOL_REPORT_DIR SQUIDMON_CONFIG LLM_ENV_FILE REPORT_STATS_PATH
    if [ -f "$proxymon_env" ]; then
        load_proxymon_env "$proxymon_env" || abort "cannot load proxymon.env -abort"
    fi
    local env_key
    local -A location_defaults=(
        [WEB_ROOT]="/var/www/proxymon"
        [CONFIG_DIR]="/etc/proxymon"
        [PANEL_PORT]="18770"
        [WARNING_PORT]="18771"
    )
    for env_key in WEB_ROOT CONFIG_DIR PANEL_PORT WARNING_PORT; do
        if [ -z "${!env_key+x}" ]; then
            printf -v "$env_key" '%s' "${location_defaults[$env_key]}"
        fi
    done
    location_defaults=(
        [TOOL_REPORT_DIR]="$CONFIG_DIR/tools/reports"
        [SQUIDMON_CONFIG]="$CONFIG_DIR/squidmon/config"
        [LLM_ENV_FILE]="$CONFIG_DIR/.env"
        [REPORT_STATS_PATH]="${REPORT_PATH:-$WEB_ROOT/squidreports/report}stats"
    )
    for env_key in TOOL_REPORT_DIR SQUIDMON_CONFIG LLM_ENV_FILE REPORT_STATS_PATH; do
        if [ -z "${!env_key+x}" ]; then
            printf -v "$env_key" '%s' "${location_defaults[$env_key]}"
        fi
    done
    for env_key in WEB_ROOT CONFIG_DIR TOOL_REPORT_DIR SQUIDMON_CONFIG LLM_ENV_FILE REPORT_STATS_PATH; do
        [[ "${!env_key}" =~ ^/[a-zA-Z0-9_./-]+$ ]] || abort "invalid $env_key -abort"
        [[ "${!env_key}" != /etc && "${!env_key}" != /var && "${!env_key}" != /var/www && "${!env_key}" != / && "${!env_key}" != *'/../'* && "${!env_key}" != */.. ]] || abort "unsafe $env_key -abort"
    done
    local checked_port
    for env_key in PANEL_PORT WARNING_PORT; do
        checked_port="${!env_key}"
        [[ "$checked_port" =~ $UH_UINT ]] && [ "${#checked_port}" -le 5 ] && [ "$checked_port" -ge 1 ] && [ "$checked_port" -le 65535 ] || abort "invalid $env_key -abort"
    done
    [ "$PANEL_PORT" != "$WARNING_PORT" ] || abort "panel and warning ports must differ -abort"
}

configure_apache_locations() {
    local failure_message="cannot update Apache site locations"
    local site old_root old_port old_config
    local -a old_ports=("$PANEL_PORT" "$WARNING_PORT")
    for site in proxymon warning; do
        local existing_site="/etc/apache2/sites-available/$site.conf"
        [ -f "$existing_site" ] || continue
        failure_message="cannot read the Apache site port"
        old_port=$(sed -nE 's/^<VirtualHost [^:]+:([0-9]+)>$/\1/p' "$existing_site" | head -n1) || { report_failure; exit 1; }
        [ -z "$old_port" ] || old_ports+=("$old_port")
    done
    for old_port in "${old_ports[@]}"; do
        failure_message="cannot edit Apache ports.conf"
        sed -i -E "/^Listen [^[:space:]]*:${old_port}\$/d; /^Listen ${old_port}\$/d" /etc/apache2/ports.conf
    done
    for site in proxymon warning; do
        local site_file="/etc/apache2/sites-available/$site.conf"
        [ -f "$site_file" ] || continue
        failure_message="cannot edit $(basename "$site_file")"
        sed -i -e "s|@WEB_ROOT@|$WEB_ROOT|g" -e "s|@TOOL_REPORT_DIR@|$TOOL_REPORT_DIR|g" -e "s|@PANEL_PORT@|$PANEL_PORT|g" -e "s|@WARNING_PORT@|$WARNING_PORT|g" "$site_file"
        failure_message="cannot read the Apache document root"
        old_root=$(sed -nE 's/^[[:space:]]*DocumentRoot[[:space:]]+([^[:space:]]+).*$/\1/p' "$site_file" | head -n1) || { report_failure; exit 1; }
        if [ "$site" = warning ]; then old_root=${old_root%/warning}; fi
        failure_message="cannot read the Apache site port"
        old_port=$(sed -nE 's/^<VirtualHost [^:]+:([0-9]+)>$/\1/p' "$site_file" | head -n1) || { report_failure; exit 1; }
        failure_message="cannot read the Squid Monitor alias"
        old_config=$(sed -nE 's@^[[:space:]]*Alias /proxymon/squidtool ([^[:space:]]+)$@\1@p' "$site_file" | head -n1) || { report_failure; exit 1; }
        if [ -n "$old_root" ]; then
            old_root=${old_root//./\\.}
            failure_message="cannot edit $(basename "$site_file")"
            sed -i "s|$old_root|$WEB_ROOT|g" "$site_file"
        fi
        if [ -n "$old_config" ]; then
            old_config=${old_config//./\\.}
            failure_message="cannot edit $(basename "$site_file")"
            sed -i "s|$old_config|$TOOL_REPORT_DIR|g" "$site_file"
        fi
        local site_port="$PANEL_PORT" site_host="127.0.0.1"
        if [ "$site" = warning ]; then site_port="$WARNING_PORT"; site_host="$SERVER_IP"; fi
        failure_message="cannot edit $(basename "$site_file")"
        sed -i -E "s/^<VirtualHost [^>]+>/<VirtualHost *:$site_port>/" "$site_file"
        failure_message="cannot write Apache ports.conf"
        printf 'Listen %s:%s\n' "$site_host" "$site_port" >> /etc/apache2/ports.conf
    done
}

# Function: Report whether a package is installed, not merely residual
package_installed() {
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = installed ]
}

# dependencies
# Every package the deployed components need. Installed by install_deps
# in --install and --update.
apt_deps=(python3-yaml wget curl git zip unzip ipset nbtscan libcgi-pm-perl libgd-perl libjson-xs-perl coreutils fonts-lato fonts-liberation fonts-dejavu perl python3 cron sudo util-linux iproute2 passwd findutils sed grep hostname ncurses-bin systemd libc-bin iptables gzip procps logrotate diffutils bzip2)

# Install the missing packages of apt_deps
install_deps() {
    local dep_pkg missing_pkgs=()
    for dep_pkg in "${apt_deps[@]}"; do
        package_installed "$dep_pkg" || missing_pkgs+=("$dep_pkg")
    done
    (( ${#missing_pkgs[@]} == 0 )) && return 0
    check_ipv4_interfaces
    check_internet
    retry_cmd "install packages" env DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "${missing_pkgs[@]}" \
        || { err "[1/2] cannot install ${missing_pkgs[*]}"; abort "[2/2] install them with apt, then re-run -abort"; }
    info "Installed: ${missing_pkgs[*]}"
}

# Installs Apache and PHP. Kept apart from apt_deps because they are
# proxymon's own serving layer, used by --install and --update.
install_apache2() {
    local dep_pkg apache_missing=no missing_pkgs=()

    for dep_pkg in apache2 apache2-bin apache2-data apache2-doc apache2-utils \
                   php libapache2-mod-php php-cli php-curl; do
        if ! package_installed "$dep_pkg"; then
            missing_pkgs+=("$dep_pkg")
            if [[ "$dep_pkg" == apache2* ]]; then
                apache_missing=yes
            fi
        fi
    done
    if (( ${#missing_pkgs[@]} == 0 )); then
        info "apache2 and php already present"
    else
        retry_cmd "install packages" env DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "${missing_pkgs[@]}" \
            || { err "[1/2] cannot install ${missing_pkgs[*]}"; abort "[2/2] install them with apt, then re-run -abort"; }
        systemctl enable apache2 &>/dev/null || true
        info "Installed: ${missing_pkgs[*]}"
    fi
    if [[ "${1:-install}" == update && "$apache_missing" == no ]]; then
        return 0
    fi
    # apache2-doc breaks after apache2 installs or upgrades.
    retry_cmd "install packages" env DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --reinstall apache2-doc \
        || abort "cannot reinstall apache2-doc -abort"
}

# Installs squid-openssl, the flavour that also supports SSL bump. An existing
# squid or squid-openssl is left untouched, including its squid.conf: the
# administrator's own proxy configuration is never replaced.
install_squid() {
    if package_installed squid || package_installed squid-openssl; then
        info "squid already present, its configuration is kept"
        squid_preexisting=1
        return 0
    fi

    retry_cmd "install packages" env DEBIAN_FRONTEND=noninteractive apt-get -qq install -y squid-openssl squid-langpack squid-common \
        || { err "[1/2] cannot install squid-openssl"; abort "[2/2] install it with apt, then re-run -abort"; }
    systemctl enable squid &>/dev/null || true
    squid_preexisting=0
    info "Installed: squid-openssl squid-langpack squid-common"
}

# Deploys proxymon's squid.conf and replaces its placeholders with the answers
# given during installation. Runs only when install_squid() installed squid: an
# existing squid.conf belongs to the administrator.
deploy_squid_template() {
    local failure_message="cannot deploy squid.conf"
    if (( squid_preexisting == 1 )); then
        info "squid.conf kept as is, template not deployed"
        return 0
    fi
    [ -f config/squid/squid.conf ] || abort "config/squid/squid.conf not found -abort"
    cp -f /etc/squid/squid.conf{,.bak} &>/dev/null || true
    cp -f config/squid/squid.conf /etc/squid/squid.conf \
        || abort "cannot write /etc/squid/squid.conf -abort"
    failure_message="cannot edit squid.conf"
    sed -i "s:192.168.0.0/24:$RANGE:g; s:192.168.0.10:$SERVER_IP:g" /etc/squid/squid.conf
    info "squid.conf deployed for $RANGE"
    failure_message="cannot create Squid cache directories"
    mkdir -p /var/spool/squid/rock
    failure_message="cannot set owner of Squid cache directories"
    chown -R proxy:proxy /var/spool/squid
    failure_message="cannot set permissions on Squid cache directories"
    chmod 700 /var/spool/squid /var/spool/squid/rock
    systemctl stop squid &>/dev/null || true
    failure_message="cannot initialize Squid cache directories"
    if ! squid -z &>/dev/null; then
        warn "cannot create Squid cache; Squid not started -alert"
        return 0
    fi
    if systemctl restart squid &>/dev/null; then
        info "squid running with the deployed squid.conf"
    else
        warn "Squid start failed; run journalctl -u squid -alert"
    fi
}

# The panels read access.log and access.log.1, never the .gz rotations.
# delaycompress keeps access.log.1 readable; weekly keeps a week in view.
set_squid_logrotate() {
    local failure_message="cannot update Squid logrotate settings"
    local rotate_file=/etc/logrotate.d/squid
    local hook="runuser -u www-data -- $WEB_ROOT/squidreports/squidreports.pl yesterday --wait-lock"

    # The file is replaced, not edited: edits pile up and depend on what the
    # package shipped. The previous file is kept as .bak in the same path.
    if [ -f "$rotate_file" ]; then
        failure_message="cannot back up Squid logrotate settings"
        cp -f "$rotate_file" "$rotate_file.bak"
    fi
    failure_message="cannot write Squid logrotate settings"
    cat > "$rotate_file" <<EOF
${SQUID_LOG_DIR:-/var/log/squid}/*.log {
    weekly
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 proxy proxy
    sharedscripts
    prerotate
        $hook
    endscript
    postrotate
        test ! -e /run/squid.pid || test ! -x /usr/sbin/squid || /usr/sbin/squid -k rotate
    endscript
}
EOF
    chown root:root "$rotate_file"
    chmod 644 "$rotate_file"
    info "${rotate_file#/etc/} replaced, previous kept as .bak -fixed"
}

squid_preexisting=1

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
            warn "conflicting $role: $dep_pkg -alert"
        done
        abort "remove them with apt purge -abort"
    fi
}

# port in use
check_port() {
    local proto="$1" port="$2" role="$3" port_listeners
    if ! port_listeners=$(python3 - "${proto,,}" "$port" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run(
        ["ss", "-lnH", f"--{sys.argv[1]}", f"sport = :{sys.argv[2]}"],
        capture_output=True,
        text=True,
    )
except OSError:
    sys.exit(1)
if result.returncode != 0 or result.stderr.strip():
    sys.exit(1)
sys.stdout.write(result.stdout)
PY
    ); then
        err "[1/2] cannot check ${proto^^} port $port"
        abort "[2/2] fix the ss query before installing -abort"
    fi
    if [ -n "$port_listeners" ]; then
        err "[1/2] ${proto^^} port $port in use by another $role"
        abort "[2/2] stop that service before installing -abort"
    fi
}

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

proxymon_env="/etc/proxymon/proxymon.env"

# validation - one variable per thing validated; use directly with =~
UH_CIDR='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])/(3[0-2]|[12][0-9]|[0-9])$'
UH_DNS='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])(,(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9]))*$'
UH_UINT='^(0|[1-9][0-9]*)$'
UH_SINT='^(0|-?[1-9][0-9]*)$'
UH_MAX=9223372036854775807
UH_MIN=-9223372036854775808

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

# check internet
check_internet() {
    local max_attempts=24 attempt=1

    while (( attempt <= max_attempts )); do
        if getent hosts www.google.com >/dev/null 2>&1; then
            return 0
        fi
        if (( attempt == 1 )); then
            log "INFO: waiting for internet..."
        fi
        attempt=$((attempt + 1))
        sleep 5
    done

    log "ERROR: no internet connection -abort"
    exit 1
}

# UPDATE CHECKS
update_error() {
    if declare -F err >/dev/null; then
        err "$* -abort"
    else
        log "ERROR: $* -abort"
    fi
    exit 1
}

update_reset() {
    update_cron_file="$1"
    update_files=()
    update_jobs=()
    update_services=()
    update_stopped_services=()
    update_copying=0
    update_cron_paused=0
    update_cron_existed=0
    update_cron_already_paused=0
}

update_file() {
    update_files+=("$1" "$2" "$3" "$4")
    case "$2" in *.sh|*.py|*.pl) update_jobs+=("$2") ;; esac
}

update_target() {
    update_files+=("" "$1" "${2:-644}" "${3:-root:root}")
}

update_preflight() {
    command -v python3 >/dev/null 2>&1 || update_error "python3 is required for update checks"
    local check_message
    if check_message=$(python3 - "${update_files[@]}" <<'UPDATE_PY'
import array, errno, fcntl, os, stat, sys, tempfile
items = [sys.argv[i:i + 4] for i in range(1, len(sys.argv), 4)]
space, probes = {}, set()
def fail(message):
    print(message)
    raise SystemExit(1)
def flags(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        try:
            value = array.array('L', [0])
            try:
                fcntl.ioctl(fd, 0x80086601, value, True)
            except OSError as exc:
                if exc.errno not in (errno.ENOTTY, errno.EOPNOTSUPP, errno.EINVAL):
                    raise
            else:
                if value[0] & 0x30:
                    protection = []
                    if value[0] & 0x10:
                        protection.append('immutable')
                    if value[0] & 0x20:
                        protection.append('append-only')
                    fail(os.path.basename(path) + ' is ' + ' and '.join(protection))
        finally:
            os.close(fd)
    except OSError as exc:
        fail(exc.strerror.lower() + ': ' + os.path.basename(path))
for source, target, mode, owner in items:
    if source:
        try:
            st = os.lstat(source)
            if not stat.S_ISREG(st.st_mode):
                fail('source is not a file: ' + os.path.basename(source))
            with open(source, 'rb') as stream:
                stream.read(1)
        except OSError as exc:
            fail('cannot read source: ' + os.path.basename(source))
for source, target, mode, owner in items:
    target = os.path.abspath(target)
    directory = mode.startswith('d')
    try:
        parent = target if directory else os.path.dirname(target)
        if os.path.lexists(target):
            st = os.lstat(target)
            if (directory and not stat.S_ISDIR(st.st_mode)) or (not directory and not stat.S_ISREG(st.st_mode)):
                fail(('dst is not a folder: ' if directory else 'dst is not a file: ') + os.path.basename(target))
            flags(target)
            if not directory:
                fd = os.open(target, os.O_WRONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                finally:
                    os.close(fd)
        while not os.path.exists(parent):
            if os.path.lexists(parent):
                fail('folder is a symbolic link: ' + parent)
            parent = os.path.dirname(parent)
        if not os.path.isdir(parent):
            fail('not a folder: ' + parent)
        current = parent
        while current != '/':
            if os.path.islink(current):
                fail('folder is a symbolic link: ' + current)
            flags(current)
            current = os.path.dirname(current)
        fs = os.statvfs(parent)
        if fs.f_flag & os.ST_RDONLY:
            fail('filesystem is read-only: ' + parent)
        if parent not in probes:
            fd, probe = tempfile.mkstemp(prefix='update-check-', dir=parent)
            try:
                os.write(fd, b'update check\n')
                os.fsync(fd)
            finally:
                os.close(fd)
                os.unlink(probe)
            probes.add(parent)
        device = os.stat(parent).st_dev
        required = os.stat(source).st_size if source else 4096
        needed, available, label = space.get(device, (0, fs.f_bavail * fs.f_frsize, parent))
        space[device] = (needed + required + 4096, available, label)
        if fs.f_favail == 0:
            fail('no free inodes for dst: ' + os.path.basename(target))
    except OSError as exc:
        fail('cannot write dst: ' + os.path.basename(target))
for needed, available, label in space.values():
    if available < needed:
        fail('not enough space to update: ' + label)
UPDATE_PY
    ); then
        :
    else
        update_error "$check_message"
    fi
}

update_backup() {
    [ -f "$1" ] && [ -r "$1" ] || update_error "backup script not readable: $(basename "$1")"
    bash "$1" || update_error "backup failed: $(basename "$1")"
}

update_begin() {
    export UPDATE_CRON_OWNER="$$"
    trap 'update_cleanup "$?"' EXIT
    local disabled="${update_cron_file}.update-disabled"
    [ ! -L "${update_cron_file}.lock" ] || update_error "invalid cron lock: $update_cron_file"
    (umask 077; : >> "${update_cron_file}.lock") || update_error "cannot open cron lock: $update_cron_file"
    exec 203>"${update_cron_file}.lock" || update_error "cannot open cron lock: $update_cron_file"
    flock -n 203 || update_error "cron file is being changed: $(basename "$update_cron_file")"
    if [ -e "$disabled" ] || [ -L "$disabled" ]; then
        [ -f "$disabled" ] && [ ! -L "$disabled" ] || update_error "invalid paused cron: $(basename "$disabled")"
        [ ! -e "$update_cron_file" ] || update_error "both active and paused cron exist: $(basename "$update_cron_file")"
        update_cron_already_paused=1
        update_cron_paused=1
    elif [ -e "$update_cron_file" ]; then
        mv -T -- "$update_cron_file" "$disabled" || update_error "cannot pause cron: $update_cron_file"
        update_cron_existed=1
        update_cron_paused=1
    else
        (umask 077; set -C; : > "$disabled") || update_error "cannot pause cron: $update_cron_file"
        update_cron_paused=1
    fi
    exec 203>&-
}

update_pids() {
    python3 - "$1" <<'UPDATE_PIDS'
import os, sys
wanted = os.path.realpath(sys.argv[1])
for entry in os.scandir('/proc'):
    if not entry.name.isdigit() or int(entry.name) == os.getpid():
        continue
    try:
        with open(entry.path + '/cmdline', 'rb') as stream:
            args = [os.fsdecode(value) for value in stream.read().split(b'\0') if value]
        if args and any(os.path.realpath(value) == wanted for value in args if value.startswith('/')):
            print(entry.name)
    except (OSError, ValueError):
        continue
UPDATE_PIDS
}

update_wait() {
    local script="$1" pids attempt
    for attempt in {1..30}; do
        pids=$(update_pids "$script") || update_error "cannot inspect processes: $(basename "$script")"
        [ -z "$pids" ] && return 0
        sleep 1
    done
    update_error "process still running: $(basename "$script")"
}

update_stop_service() {
    local unit="$1" state load_state
    load_state=$(systemctl show -p LoadState --value "$unit") || update_error "cannot inspect service: $unit"
    [ "$load_state" != not-found ] || return 0
    state=$(systemctl show -p ActiveState --value "$unit") || update_error "cannot inspect service: $unit"
    case "$state" in
        active|reloading|activating|deactivating) update_services+=("$unit") ;;
        inactive|failed) ;;
        *) update_error "unexpected service state: $unit ($state)" ;;
    esac
    update_stopped_services+=("$unit")
    systemctl stop "$unit" || update_error "cannot stop service: $unit"
    state=$(systemctl show -p ActiveState --value "$unit") || update_error "cannot inspect stopped: $unit"
    [ "$state" = inactive ] || {
        log "ERROR: [1/2] $unit state: $state"
        update_error "[2/2] $unit did not stop"
    }
}

update_wait_jobs() {
    local script unit state
    for script in "${update_jobs[@]}"; do
        update_wait "$script"
    done
    for unit in "${update_stopped_services[@]}"; do
        state=$(systemctl show -p ActiveState --value "$unit") || update_error "cannot inspect stopped: $unit"
        [ "$state" = inactive ] || update_error "service restarted in update: $unit"
    done
}

update_apply() {
    update_preflight
    update_copying=1
    local i source target mode owner
    for ((i=0; i<${#update_files[@]}; i+=4)); do
        source="${update_files[i]}"
        target="${update_files[i+1]}"
        mode="${update_files[i+2]}"
        owner="${update_files[i+3]}"
        if [[ "$mode" == d* ]]; then
            install -d -m "${mode#d}" -o "${owner%:*}" -g "${owner#*:}" -- "$target" \
                || update_error "cannot prepare directory: $target"
            continue
        fi
        if [ -z "$source" ]; then
            if [ ! -d "$(dirname "$target")" ]; then
                install -d -m 755 -o root -g root -- "$(dirname "$target")" \
                    || update_error "cannot prepare destination parent: $(basename "$target")"
            fi
            continue
        fi
        install -D -m "$mode" -o "${owner%:*}" -g "${owner#*:}" -- "$source" "$target" \
            || update_error "cannot replace file: $(basename "$target")"
        cmp -s -- "$source" "$target" || {
            local compared_file
            compared_file=$(basename "$target")
            if (( ${#compared_file} <= 19 )); then
                update_error "src and dst do not match: $compared_file"
            fi
            log "ERROR: [1/2] src and dst: $compared_file"
            update_error "[2/2] src and dst do not match"
        }
        info "updated $(basename "$target")"
    done
}

update_resume() {
    local unit state
    for unit in "${update_services[@]}"; do
        systemctl start "$unit" || update_error "cannot start service: $unit"
        state=$(systemctl show -p ActiveState --value "$unit") || update_error "cannot inspect started: $unit"
        [ "$state" = active ] || {
            log "ERROR: [1/2] $unit state: $state"
            update_error "[2/2] $unit did not start"
        }
    done
}

update_finish() {
    update_resume
    rm -f -- "${update_cron_file}.update-disabled" || update_error "cannot finish cron update: $(basename "$update_cron_file")"
    trap - EXIT
    unset UPDATE_CRON_OWNER
}

update_cleanup() {
    local status="$1" unit
    trap - EXIT
    if (( update_copying == 0 )); then
        for unit in "${update_services[@]}"; do
            systemctl start "$unit" || warn "cannot resume $unit -alert"
        done
        if (( update_cron_paused && ! update_cron_already_paused )); then
            if (( update_cron_existed )); then
                mv -T -- "${update_cron_file}.update-disabled" "$update_cron_file" \
                    || warn "cannot restore paused cron -alert"
            else
                rm -f -- "${update_cron_file}.update-disabled" || warn "cannot clear paused cron -alert"
            fi
        fi
    else
        if rm -f -- "$update_cron_file"; then
            warn "update failed; cron remains disabled -alert"
        else
            warn "cannot keep project cron paused -alert"
        fi
        for unit in "${update_services[@]}"; do
            systemctl stop "$unit" || warn "cannot keep $unit stopped -alert"
        done
    fi
    (( status != 0 )) || status=1
    exit "$status"
}

# validation - integer is representable as a signed 64-bit value
uh_fits() {
    local value="${1-}" limit
    [[ "$value" =~ $UH_SINT ]] || return 1
    if [[ "${value:0:1}" == - ]]; then
        limit="${UH_MIN#-}"
        value="${value#-}"
    else
        limit="$UH_MAX"
    fi
    (( ${#value} < ${#limit} )) && return 0
    (( ${#value} > ${#limit} )) && return 1
    [[ "$value" > "$limit" ]] && return 1
    return 0
}

# ACL PREPARATION
# Canonical block -- copied byte for byte into every script that creates a
# directory or a list under /etc/acl. Prepare /etc/acl first, then only the
# subdirectory and the lists this script needs. Never recursive.
# Usage: acl_prepare <dir> <dir_mode> <file_mode> [file ...]
acl_prepare() {
    local acl_dir="$1" dir_mode="$2" file_mode="$3" acl_file
    shift 3

    # mkdir without -p fails when the directory already exists, so a success
    # means this run created it and no concurrent run did.
    if mkdir -m "$dir_mode" -- "$acl_dir" 2>/dev/null; then
        if ! chown root:root -- "$acl_dir"; then
            log "ERROR: cannot set owner of $acl_dir -abort"
            exit 1
        fi
        log "WARNING: created ACL directory $acl_dir -alert"
    elif [ -d "$acl_dir" ] && [ ! -L "$acl_dir" ]; then
        acl_fix_perms "$acl_dir" "$dir_mode"
    else
        log "ERROR: $acl_dir is not a regular directory -abort"
        exit 1
    fi

    for acl_file in "$@"; do
        # Checked before the redirection: noclobber only protects regular
        # files, and opening a FIFO for writing blocks until a reader shows up.
        if [ -L "$acl_file" ] || { [ -e "$acl_file" ] && [ ! -f "$acl_file" ]; }; then
            log "ERROR: $(basename "$acl_file") is not a regular file -abort"
            exit 1
        fi
        # noclobber makes the redirection fail when the file already exists,
        # and umask 077 keeps the new file closed until chmod sets its mode.
        if (set -C; umask 077; : > "$acl_file") 2>/dev/null; then
            if ! { chmod "$file_mode" -- "$acl_file" \
                && chown root:root -- "$acl_file"; }; then
                log "ERROR: cannot set perms of $(basename "$acl_file") -abort"
                exit 1
            fi
            log "WARNING: created empty $(basename "$acl_file") -alert"
        elif [ -f "$acl_file" ] && [ ! -L "$acl_file" ]; then
            acl_fix_perms "$acl_file" "$file_mode"
        else
            log "ERROR: $(basename "$acl_file") is not a regular file -abort"
            exit 1
        fi
    done
}

# Repairs mode and owner of an existing ACL object, per Autorreparación
acl_fix_perms() {
    local acl_path="$1" want_mode="$2" cur_mode cur_owner
    cur_mode=$(stat -c '%a' -- "$acl_path" 2>/dev/null) || {
        log "ERROR: cannot stat $acl_path -abort"; exit 1; }
    cur_owner=$(stat -c '%U:%G' -- "$acl_path" 2>/dev/null) || {
        log "ERROR: cannot stat $acl_path -abort"; exit 1; }
    [[ "$cur_mode" == "$want_mode" && "$cur_owner" == "root:root" ]] && return 0
    if ! { chmod "$want_mode" -- "$acl_path" \
        && chown root:root -- "$acl_path"; }; then
        log "ERROR: cannot fix $(basename "$acl_path") perms -abort"
        exit 1
    fi
    log "INFO: $(basename "$acl_path") perms fixed -fixed"
}

# ACL download
get_acl() {
    local source_url="$1" target_file="$2" http_code
    http_code=$(curl -k -s -o /dev/null -w '%{http_code}' -I -L --connect-timeout 5 --max-time 15 --retry 1 "$source_url")
    case "$http_code" in
        2*|405) ;;
        000) log "TIMEOUT: $source_url"; return 1 ;;
        5*)  log "BUSY: $http_code $source_url"; return 1 ;;
        404|410)   log "BROKEN: $http_code $source_url"; return 1 ;;
        *)   log "HTTP_ERROR: $http_code $source_url"; return 1 ;;
    esac
    # wget has no timeout of its own -- if curl's HEAD check succeeds but
    # the actual transfer stalls (dead connection, slow/black-holed route),
    # wget would otherwise hang forever with nothing printed. --timeout
    # bounds each read/connect phase and --tries=1 stops it from silently
    # retrying on top of retry_cmd's own retry loop.
    local acl_tmp
    if ! acl_tmp=$(mktemp -- "${target_file}.XXXXXX"); then
        log "WARNING: cannot stage $(basename "$target_file") -alert"
        return 1
    fi
    if ! timeout 30 wget -q --timeout=15 --tries=1 "$source_url" -O "$acl_tmp"; then
        rm -f -- "$acl_tmp"
        log "PARTIAL: $source_url"
        return 1
    fi
    if ! chmod 644 "$acl_tmp" || ! mv -fT -- "$acl_tmp" "$target_file"; then
        rm -f -- "$acl_tmp"
        log "WARNING: cannot publish $(basename "$target_file") -alert"
        return 1
    fi
    local source_name target_name
    source_name=$(basename "$source_url")
    target_name=$(basename "$target_file")
    if [ "$source_name" = "$target_name" ]; then
        log "SAVED: $source_name"
    else
        log "SAVED: $source_name -> $target_name"
    fi
}

retry_cmd() {
    [ "$#" -ge 2 ] || return 2
    local retry_label="$1" retry_attempt retry_status
    shift
    for retry_attempt in 1 2 3; do
        if "$@"; then
            return 0
        else
            retry_status=$?
        fi
        [ "$retry_attempt" -lt 3 ] || return "$retry_status"
        if declare -F log >/dev/null; then
            log "INFO: $retry_label: retry $((retry_attempt + 1))/3" >&2
        else
            printf '%s INFO: %s: retry %s/3\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$retry_label" \
                "$((retry_attempt + 1))" >&2
        fi
        sleep 5
    done
}

check_apache_config() {
    local failure_message="cannot check Apache and PHP settings"
    if command -v php >/dev/null 2>&1; then
        failure_message="cannot read the PHP version"
        php_version=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;" 2>/dev/null) || { report_failure; exit 1; }
    else
        abort "php not installed -abort"
    fi

    if [[ ! "$php_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        abort "cannot read php version: '$php_version' -abort"
    fi

    config_errors=""

    if [ ! -f /etc/apache2/mods-available/mpm_prefork.conf ]; then
        config_errors+="/etc/apache2/mods-available/mpm_prefork.conf not found\n"
    fi

    if [ ! -f /etc/php/$php_version/apache2/php.ini ]; then
        if [ -f /etc/php/$php_version/cli/php.ini ]; then
            failure_message="cannot create the Apache PHP directory"
            mkdir -p /etc/php/$php_version/apache2
            failure_message="cannot copy Apache php.ini"
            cp /etc/php/$php_version/cli/php.ini /etc/php/$php_version/apache2/php.ini
            info "php.ini copied to /etc/php/$php_version/apache2/"
        else
            config_errors+="php.ini not found\n"
        fi
    fi

    # PHP and mpm_prefork are already installed (see install_apache2());
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
        systemctl restart apache2 || abort "cannot restart apache2 -abort"
    fi

    if [[ -n "$config_errors" ]]; then
        while IFS= read -r config_error; do
            [ -n "$config_error" ] && warn "$config_error -alert"
        done < <(echo -e "$config_errors")
        abort "invalid apache or php configuration -abort"
    else
        info "Apache and PHP configuration is valid"
    fi
}

run_initial_checks() {
    local failure_message
    info "running initial checks"
    failure_message="cannot check Apache and PHP settings"
    check_apache_config
}

check_repo() {
    local config_incomplete=0
    if [ ! -d "modules" ] || [ -z "$(ls -A "modules" 2>/dev/null)" ]; then
        config_incomplete=1
    fi
    if [ ! -d "config" ] || [ -z "$(ls -A "config" 2>/dev/null)" ]; then
        config_incomplete=1
    fi
    if [ "$config_incomplete" -eq 1 ]; then
        echo ""
        err "[1/2] repository files not found"
        err "[2/2] clone github.com/maravento/proxymon -abort"
        echo ""
        exit 1
    fi
}

# check ipv4 interfaces
list_ifaces() {
    ip -br link show 2>/dev/null | awk '$1 != "lo" {sub(/@.*/, "", $1); printf "%s %s\n", $1, ($2 == "UP") ? "UP" : "DOWN"}'
}

list_ipv4_ifaces() {
    local iface state
    while read -r iface state; do
        [ "$state" = UP ] || continue
        if ip -4 -o addr show dev "$iface" scope global 2>/dev/null \
            | awk '$4 != "" {found=1} END {exit !found}'; then
            printf '%s\n' "$iface"
        fi
    done < <(list_ifaces)
}

check_ipv4_interfaces() {
    local max_attempts=24 attempt=1

    while (( attempt <= max_attempts )); do
        if [ -n "$(list_ipv4_ifaces)" ]; then
            return 0
        fi
        if (( attempt == 1 )); then
            log "INFO: waiting for an interface with IPv4..."
        fi
        attempt=$((attempt + 1))
        sleep 5
    done

    log "ERROR: no interface with IPv4 -abort"
    exit 1
}

# LAN SELECTION
# Select an existing interface and one of its configured IPv4 addresses
choose_lan_interface() {
    local preset_iface="${1:-}"
    local iface_name iface_choice iface_index iface_state
    local -a lan_candidates=()
    while IFS= read -r iface_name; do
        lan_candidates+=("$iface_name")
    done < <(list_ipv4_ifaces)
    if [ -n "$preset_iface" ]; then
        for iface_name in "${lan_candidates[@]}"; do
            if [ "$preset_iface" = "$iface_name" ]; then
                lan_iface_answer="$preset_iface"
                return 0
            fi
        done
        log "ERROR: LAN must be an active interface with IPv4 -abort"
        exit 1
    fi
    (( ${#lan_candidates[@]} > 0 )) || {
        log "ERROR: no LAN interface available -abort"
        exit 1
    }
    if (( ${#lan_candidates[@]} == 1 )); then
        lan_iface_answer="${lan_candidates[0]}"
        return 0
    fi
    echo "Available LAN interfaces:"
    for iface_index in "${!lan_candidates[@]}"; do
        iface_name="${lan_candidates[$iface_index]}"
        iface_state=$(ip -br link show "$iface_name" | awk '{print $2}')
        printf ' [%d] %s (%s)\n' "$((iface_index + 1))" "$iface_name" "$iface_state"
        describe_lan_ipv4 "$iface_name"
    done
    while true; do
        read -r -p "Select LAN Interface [1-${#lan_candidates[@]}]: " iface_choice || {
            log "ERROR: cannot read LAN interface selection -abort"
            exit 1
        }
        if [[ "$iface_choice" =~ $UH_UINT ]] && [ "${#iface_choice}" -le 5 ] \
           && [ "$iface_choice" -ge 1 ] && [ "$iface_choice" -le "${#lan_candidates[@]}" ]; then
            lan_iface_answer="${lan_candidates[$((iface_choice - 1))]}"
            return 0
        fi
        log "INFO: invalid LAN interface selection -retry"
    done
}

check_static_lan() {
    local static_result
    static_result=$(python3 -I - "$1" "$2" <<'STATIC_LAN'
import configparser
import fnmatch
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

iface, address = sys.argv[1:]

def run(*args):
    return subprocess.check_output(
        args, text=True, stderr=subprocess.DEVNULL, timeout=10,
        env={**os.environ, 'LC_ALL': 'C', 'SYSTEMD_PAGER': 'cat'}).strip()

def has_address(values):
    return any(str(ipaddress.ip_interface(value.split(',')[0]).ip)
               == address for value in values)

def persistent_static():
    data = json.loads(run('ip', '-j', '-4', 'addr', 'show', 'dev', iface))
    selected = [entry for link in data for entry in link['addr_info']
                if entry.get('local') == address]
    if len(selected) != 1:
        return 'unknown'
    entry = selected[0]
    if entry.get('dynamic') or 'dynamic' in entry.get('flags', []):
        return 'dhcp'

    nm_active = False
    if shutil.which('nmcli'):
        try:
            uuid = run('nmcli', '-g', 'GENERAL.CON-UUID',
                       'device', 'show', iface)
            if uuid and uuid != '--':
                nm_active = True
                method = run('nmcli', '-g', 'ipv4.method',
                             'connection', 'show', uuid)
                addresses = run('nmcli', '-g', 'ipv4.addresses',
                                'connection', 'show', uuid)
                if method != 'manual' or not has_address(
                        addresses.split(', ')):
                    return 'unknown'
                rows = run('nmcli', '-t', '--escape', 'no',
                           '-f', 'UUID,FILENAME', 'connection', 'show')
                netplan_profile = False
                for row in rows.splitlines():
                    key, _, filename = row.partition(':')
                    if key != uuid:
                        continue
                    netplan_profile = (filename.startswith('/run/') and
                                       '/netplan-' in filename)
                    if not filename.startswith('/etc/'):
                        continue
                    config = configparser.ConfigParser(interpolation=None)
                    config.read(filename)
                    if config.get('ipv4', 'method') != 'manual':
                        return 'unknown'
                    values = [value for key, value in config['ipv4'].items()
                              if re.fullmatch(r'address\d+', key)]
                    if has_address(values):
                        return 'static'
                if not netplan_profile:
                    return 'unknown'
        except (OSError, ValueError, configparser.Error,
                subprocess.SubprocessError):
            if nm_active:
                return 'unknown'

    if not shutil.which('netplan'):
        return 'unknown'
    # Runtime Netplan overrides cannot prove persistent configuration.
    if list(Path('/run/netplan').glob('*.yaml')):
        return 'unknown'
    if not nm_active:
        status = run('networkctl', '--no-pager', 'status', iface)
        if not re.search(r'Network File: .*netplan.*\.network', status):
            return 'unknown'
    import yaml
    try:
        network = yaml.safe_load(run('netplan', 'get')).get('network', {})
    except yaml.YAMLError:
        return 'unknown'
    for kind in ('ethernets', 'wifis', 'bridges', 'bonds', 'vlans'):
        for name, config in network.get(kind, {}).items():
            match = config.get('match', {})
            if match:
                mac = data[0].get('permaddr', data[0].get('address', ''))
                matches = not (set(match) - {'name', 'macaddress'})
                if 'name' in match:
                    matches &= fnmatch.fnmatchcase(iface, match['name'])
                if 'macaddress' in match:
                    matches &= mac.lower() == match['macaddress'].lower()
                if config.get('set-name') == iface:
                    matches = True
            else:
                matches = name == iface
            if matches and has_address(config.get('addresses', [])):
                return 'static'
    return 'unknown'

try:
    print(persistent_static())
except (OSError, ValueError, KeyError, TypeError, AttributeError,
        ImportError, subprocess.SubprocessError):
    print('unknown')
STATIC_LAN
    ) || static_result=unknown
    if [ "${3:-}" = probe ]; then
        printf '%s\n' "$static_result"
        return 0
    fi
    case "$static_result" in
        static) return 0 ;;
        dhcp)
            log "ERROR: [1/2] LAN $1: $2 uses DHCP"
            log "ERROR: [2/2] configure a static LAN IPv4 -abort"
            ;;
        *)
            log "ERROR: [1/2] LAN $1: $2"
            log "ERROR: [2/2] cannot verify persistent static IPv4 -abort"
            ;;
    esac
    exit 1
}

lan_ipv4_condition() {
    case "$(check_static_lan "$1" "$2" probe)" in
        static) printf 'static' ;;
        dhcp) printf 'dynamic' ;;
        *) printf 'unverified' ;;
    esac
}

describe_lan_ipv4() {
    local cidr
    while read -r cidr; do
        printf '      %s (%s)\n' "$cidr" \
            "$(lan_ipv4_condition "$1" "${cidr%/*}")"
    done < <(ip -4 -o addr show dev "$1" scope global | awk '{print $4}')
}

require_static_lan_candidate() {
    local iface cidr
    local -a candidates=()
    mapfile -t candidates < <(list_ipv4_ifaces)
    (( ${#candidates[@]} > 1 )) || return 0
    for iface in "${candidates[@]}"; do
        while read -r cidr; do
            if [ "$(check_static_lan "$iface" "${cidr%/*}" probe)" = static ]; then
                return 0
            fi
        done < <(ip -4 -o addr show dev "$iface" scope global | awk '{print $4}')
    done
    log "ERROR: [1/2] no interface has a verified static IPv4"
    log "ERROR: [2/2] configure a static LAN IPv4 -abort"
    exit 1
}

read_lan_ipv4() {
    local selected_iface="$1" preset_ip="${2:-}" ipv4_choice ipv4_index candidate_cidr
    local -a lan_addresses=()
    mapfile -t lan_addresses < <(ip -4 -o addr show dev "$selected_iface" scope global | awk '{print $4}')
    (( ${#lan_addresses[@]} > 0 )) || {
        log "ERROR: LAN '$selected_iface' has no IPv4 address -abort"
        exit 1
    }
    for candidate_cidr in "${lan_addresses[@]}"; do
        [[ "$candidate_cidr" =~ $UH_CIDR ]] || {
            log "ERROR: LAN '$selected_iface' has invalid IPv4/prefix -abort"
            exit 1
        }
    done
    if [ -n "$preset_ip" ]; then
        for candidate_cidr in "${lan_addresses[@]}"; do
            if [ "${candidate_cidr%/*}" = "$preset_ip" ]; then
                lan_cidr_answer="$candidate_cidr"
                return 0
            fi
        done
        log "ERROR: requested IPv4 is not configured on LAN -abort"
        exit 1
    fi
    if (( ${#lan_addresses[@]} == 1 )); then
        lan_cidr_answer="${lan_addresses[0]}"
        return 0
    fi
    echo "IPv4 addresses on LAN '$selected_iface':"
    for ipv4_index in "${!lan_addresses[@]}"; do
        printf ' [%d] %s (%s)\n' "$((ipv4_index + 1))" \
            "${lan_addresses[$ipv4_index]}" \
            "$(lan_ipv4_condition "$selected_iface" \
                "${lan_addresses[$ipv4_index]%/*}")"
    done
    while true; do
        read -r -p "Select LAN IPv4 number: " ipv4_choice || {
            log "ERROR: cannot read LAN IPv4 selection -abort"
            exit 1
        }
        if [[ "$ipv4_choice" =~ $UH_UINT ]] && [ "${#ipv4_choice}" -le 5 ] \
           && [ "$ipv4_choice" -ge 1 ] && [ "$ipv4_choice" -le "${#lan_addresses[@]}" ]; then
            lan_cidr_answer="${lan_addresses[$((ipv4_choice - 1))]}"
            return 0
        fi
        log "INFO: invalid LAN IPv4 selection -retry"
    done
}

# ENV FILE
# Create the project configuration file
create_proxymon_env() {
    local failure_message="cannot create proxymon.env"
    local env_file="/etc/proxymon/proxymon.env"
    failure_message="cannot create proxymon"
    mkdir -p /etc/proxymon

    if [ -f "$env_file" ]; then
        info "$env_file already exists -skip"
        # Warn if a newer version of this script expects variables
        # not present in an existing env file (version drift).
        local expected_keys="WEB_ROOT CONFIG_DIR BACKUP_DIR TOOL_REPORT_DIR SQUIDMON_CONFIG LLM_ENV_FILE REPORT_STATS_PATH PANEL_PORT PANEL_DOMAINS WARNING_PORT LAN SERVER_IP RANGE REPORT_IP_GLOB SQUIDREPORTS_DIR REPORT_PATH REALNAME_CFG SKIPUSERS_CFG ACL_PATH ACL_SQUID_PATH ACL_BANDATA_PATH ALLOW_LIST BLOCK_LIST_DAY BLOCK_LIST_WEEK BLOCK_LIST_MONTH SQUID_LOG_DIR SQUID_LOG_FILE WARNING_HTML CACHE_PATH SQUID_MGR_HOST SQUID_MGR_PORT SQUID_INTERCEPT_PORT SQUID_MGR_PASSWD MAX_BANDWIDTH_DAY MAX_BANDWIDTH_WEEK MAX_BANDWIDTH_MONTH BANDATA_HOTSPOT BANDATA_DNS HOTSPOT_PATH UPDATE_REALNAME SQUIDTOOL_MIN_HITS SQUIDTOOL_ALERT_THRESHOLD"
        local absent_keys=""
        for env_key in $expected_keys; do
            grep -q "^${env_key}=" "$env_file" || absent_keys="$absent_keys $env_key"
        done
        if [ -n "$absent_keys" ]; then
            for env_key in $absent_keys; do
                warn "$(basename "$env_file"): missing variable $env_key -alert"
            done
            warn "$(basename "$env_file"): add missing variables -alert"
        fi

        local range_value
        failure_message="cannot read RANGE from proxymon.env"
        range_value=$(grep "^RANGE=" "$env_file" | head -n1 | cut -d'=' -f2-) || { report_failure; exit 1; }
        if [ -n "$range_value" ] && ! [[ "$range_value" =~ $UH_CIDR ]]; then
            warn "$(basename "$env_file"): RANGE must use IPv4/prefix -alert"
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

    local -a lan_network_values
    mapfile -t lan_network_values < <(python3 -c '
import ipaddress, sys
network = ipaddress.IPv4Interface(sys.argv[1]).network
octets = str(network.network_address).split(".")
fixed = network.prefixlen // 8
print(network)
print(".".join(octets[:fixed] + ["*"] * (4 - fixed)))
' "$lan_cidr_answer")
    [ "${#lan_network_values[@]}" -eq 2 ] || abort "cannot calculate LAN network -abort"
    lan_range="${lan_network_values[0]}"
    report_glob="${lan_network_values[1]}"
    info "LAN interface: $lan_answer ($lan_cidr_answer)"

    # Bandwidth limits: a number and an uppercase K, M, G or T (e.g. 500M, 1G, 1.5G)
    read_bandwidth() {
        local prompt_text="$1" default_value="$2" user_answer
        local check_bash_range="${3:-false}" quota_bytes
        if [ "$unattended" = true ]; then
            echo "$default_value"
            return
        fi
        while true; do
            failure_message="cannot read the bandwidth limit answer"
            read -rp "$prompt_text" user_answer || return 1
            user_answer=${user_answer:-$default_value}
            if [[ "$user_answer" =~ ^[0-9]+([.,][0-9]+)?[KMGT]$ ]] \
                && quota_bytes=$(LC_ALL=C numfmt --from=iec "${user_answer/,/.}" 2>/dev/null); then
                if [ "$check_bash_range" = true ] \
                    && ! uh_fits "$quota_bytes"; then
                    info "daily quota exceeds Bash integer range -retry" >&2
                    continue
                fi
                echo "$user_answer"
                return
            fi
            info "invalid size; use 500M, 1G or 1.5G -retry" >&2
        done
    }
    failure_message="cannot read the daily bandwidth limit"
    bw_day=$(read_bandwidth "Max bandwidth per day (default: 1G): " "1G" true) || { report_failure; exit 1; }
    failure_message="cannot read the weekly bandwidth limit"
    bw_week=$(read_bandwidth "Max bandwidth per week (default: 5G): " "5G") || { report_failure; exit 1; }
    failure_message="cannot read the monthly bandwidth limit"
    bw_month=$(read_bandwidth "Max bandwidth per month (default: 20G): " "20G") || { report_failure; exit 1; }
    if [ "$unattended" = true ]; then
        echo "Max bandwidth per day: $bw_day (default)"
        echo "Max bandwidth per week: $bw_week (default)"
        echo "Max bandwidth per month: $bw_month (default)"
    fi

    # DNS resolvers for blocked clients
    local bandata_dns=""
    if [ "$unattended" = true ]; then
        bandata_dns="${PROXYMON_BANDATA_DNS:-}"
        if ! [[ "$bandata_dns" =~ $UH_DNS ]] || [[ "$bandata_dns" == *,*,* ]]; then
            abort "PROXYMON_BANDATA_DNS: expected 1-2 IPv4 -abort"
        fi
        echo "DNS for blocked clients: $bandata_dns"
    else
        local dns_attempt
        for dns_attempt in 1 2 3; do
            failure_message="cannot read the DNS for blocked clients"
            read -rp "DNS for blocked clients (one or two IPv4, e.g. 192.168.0.1 or 8.8.8.8,1.1.1.1): " bandata_dns || { report_failure; exit 1; }
            if [[ "$bandata_dns" =~ $UH_DNS ]] && [[ "$bandata_dns" != *,*,* ]]; then
                break
            fi
            [ "$dns_attempt" -lt 3 ] || abort "no valid DNS for blocked clients -abort"
            info "invalid DNS for blocked clients -retry"
        done
    fi

    # Enable Bandata integration only for an installed UHM in Hotspot mode.
    hotspot_dir="/etc/uhm"
    if [ -f "$hotspot_dir/uhm.env" ] && [ -f "$hotspot_dir/acl/uhm-auth.txt" ] &&
        grep -qxF 'UNIFI_HOTSPOT_ENABLED=true' "$hotspot_dir/uhm.env"; then
        hotspot_enabled=true
    else
        hotspot_enabled=false
    fi
    echo "Unifi Hotspot in Bandata: $hotspot_enabled"

    # Auto-update Squidreports names and groups
    update_realname_flag=true
    echo "Update hostnames and groups in Squidreports: $update_realname_flag (default)"

    local squid_mgr_port="3128"
    local squid_intercept_port="3129"
    local squid_conf_port
    if [ -f /etc/squid/squid.conf ]; then
        squid_conf_port=$(awk '$1=="http_port" && $0 !~ /intercept/ {n=split($2,p,":"); print p[n]; exit}' /etc/squid/squid.conf)
        if [ -n "$squid_conf_port" ]; then
            squid_mgr_port="$squid_conf_port"
        fi
        squid_conf_port=$(awk '$1=="http_port" && $0 ~ /intercept/ {n=split($2,p,":"); print p[n]; exit}' /etc/squid/squid.conf)
        if [ -n "$squid_conf_port" ]; then
            squid_intercept_port="$squid_conf_port"
        fi
    fi
    local squid_port_value
    for squid_port_value in "$squid_mgr_port" "$squid_intercept_port"; do
        if ! [[ "$squid_port_value" =~ $UH_UINT ]] || [ "${#squid_port_value}" -gt 5 ] || [ "$squid_port_value" -lt 1 ] || [ "$squid_port_value" -gt 65535 ]; then
            abort "invalid Squid port: $squid_port_value -abort"
        fi
    done

    failure_message="cannot write $(basename "$env_file")"
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
# Public panel domains, comma-separated, when the panel is published behind a
# reverse proxy or tunnel. Empty means localhost only.
PANEL_DOMAINS=

# Network
LAN=${lan_answer}
SERVER_IP=${server_ip_answer}
RANGE=${lan_range}

# Squid
SQUID_LOG_DIR=/var/log/squid
SQUID_LOG_FILE=\$SQUID_LOG_DIR/access.log
SQUID_MGR_HOST=127.0.0.1
SQUID_MGR_PORT=${squid_mgr_port}
SQUID_INTERCEPT_PORT=${squid_intercept_port}
SQUID_MGR_PASSWD=

# ACL
ACL_PATH=/etc/acl
ACL_SQUID_PATH=/etc/squid/acl

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
# Changing these defaults is not recommended
SQUIDTOOL_MIN_HITS=20
SQUIDTOOL_ALERT_THRESHOLD=300

# Bandata
# Quotas: number + K, M, G or T (uppercase), e.g. 500M, 1G, 1.5G
REPORT_IP_GLOB=${report_glob}
ACL_BANDATA_PATH=${CONFIG_DIR}/bandata/acl
ALLOW_LIST=${CONFIG_DIR}/bandata/acl/allowdata.txt
BLOCK_LIST_DAY=${CONFIG_DIR}/bandata/acl/banday.txt
BLOCK_LIST_WEEK=${CONFIG_DIR}/bandata/acl/banweek.txt
BLOCK_LIST_MONTH=${CONFIG_DIR}/bandata/acl/banmonth.txt
MAX_BANDWIDTH_DAY=${bw_day}
MAX_BANDWIDTH_WEEK=${bw_week}
MAX_BANDWIDTH_MONTH=${bw_month}
WARNING_PORT=${WARNING_PORT}
WARNING_HTML=${WEB_ROOT}/warning/warning.html
BANDATA_HOTSPOT=${hotspot_enabled}
BANDATA_DNS=${bandata_dns}
HOTSPOT_PATH=${hotspot_dir}
UPDATE_REALNAME=${update_realname_flag}

# Backup
BACKUP_DIR=/etc/bak/proxymon
# =============================================================================
ENVEOF

    failure_message="cannot set permissions on $(basename "$env_file")"
    chmod 640 "$env_file"
    failure_message="cannot set owner of $(basename "$env_file")"
    chown root:www-data "$env_file"
    info "$(basename "$env_file") created"
    printf "\n"
}

# ------------------------------------------------------------------------------
# INSTALL
# ------------------------------------------------------------------------------

# CRON FILE
# Publish the complete project schedule after preparing it successfully.
cron_d_write() (
    local cron_file="/etc/cron.d/proxymon"
    local cron_tmp

    [ "$#" -gt 0 ] || return 1
    [ ! -L "${cron_file}.lock" ] || return 1
    (umask 077; : >> "${cron_file}.lock") || return 1
    exec 201>"${cron_file}.lock" || return 1
    flock -x 201 || return 1
    if [ -e "${cron_file}.update-disabled" ] && [ "${UPDATE_CRON_OWNER:-}" != "$$" ]; then
        return 1
    fi
    [ ! -L "$cron_file" ] || return 1
    [ ! -e "$cron_file" ] || [ -f "$cron_file" ] || return 1

    cron_tmp=$(mktemp "${cron_file}.XXXXXX") || return 1
    trap 'rm -f -- "$cron_tmp"' EXIT
    {
        printf '%s\n' '# Managed by the project installer; manual changes are replaced.'
        printf '%s\n' 'SHELL=/bin/bash' 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        printf '%s\n' "$@"
    } > "$cron_tmp" || return 1
    chmod 644 "$cron_tmp" && chown root:root "$cron_tmp" || return 1
    mv -fT -- "$cron_tmp" "$cron_file" || return 1
)

# PROJECT SCHEDULE
# Publish all tasks defined by this project
register_project_cron() {
    cron_d_write \
        "*/10 * * * * www-data $WEB_ROOT/squidreports/squidreports.pl today" \
        "5 0 * * * www-data $WEB_ROOT/squidreports/squidreports.pl yesterday --wait-lock" \
        "*/5 * * * * root $CONFIG_DIR/bandata/bandata.sh" \
        "@monthly root $CONFIG_DIR/tools/pmbk.sh"
}

# APACHE LOGROTATE
# Apache keeps 14 rotations by default; the projects keep 7
set_apache_logrotate() {
    local apache_rotate="/etc/logrotate.d/apache2"
    # Replaced, not edited; the package rotation and reload are kept.
    if [ -f "$apache_rotate" ]; then
        cp -f "$apache_rotate" "$apache_rotate.bak" \
            || { warn "cannot back up ${apache_rotate#/etc/} -alert"; return 0; }
    fi
    if ! cat > "$apache_rotate" <<'EOF'
/var/log/apache2/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
    sharedscripts
    prerotate
        if [ -d /etc/logrotate.d/httpd-prerotate ]; then
            run-parts /etc/logrotate.d/httpd-prerotate
        fi
    endscript
    postrotate
        if pgrep -f ^/usr/sbin/apache2 > /dev/null; then
            invoke-rc.d apache2 reload 2>&1 | logger -t apache2.logrotate
        fi
    endscript
}
EOF
    then
        warn "cannot write ${apache_rotate#/etc/} -alert"
        return 0
    fi
    chown root:root "$apache_rotate" && chmod 644 "$apache_rotate" \
        || { warn "cannot set ${apache_rotate#/etc/} permissions -alert"; return 0; }
    info "${apache_rotate#/etc/} replaced, previous kept as .bak -fixed"
}

install_project_logrotate() {
    local rotate_file="/etc/logrotate.d/proxymon"
    local project_log="/var/log/proxymon.log"
    if [ ! -f "$project_log" ]; then
        touch "$project_log" || return 1
    fi
    chown root:adm "$project_log" || return 1
    chmod 640 "$project_log" || return 1
    cat > "$rotate_file" <<EOF
$project_log {
    weekly
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
}
EOF
    [ "$?" -eq 0 ] || return 1
    chown root:root "$rotate_file" || return 1
    chmod 644 "$rotate_file" || return 1
    info "updated $rotate_file"
    cat > /etc/logrotate.d/bandata <<'EOF'
/var/log/bandata.log {
    weekly
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
}
EOF
    [ "$?" -eq 0 ] || return 1
    chown root:root /etc/logrotate.d/bandata || return 1
    chmod 644 /etc/logrotate.d/bandata || return 1
    info "updated /etc/logrotate.d/bandata"
    set_apache_logrotate
}

prepare_squidmon_config() {
    local template="$1" target="$2"
    if [ "$target" = "$CONFIG_DIR/squidmon/config" ]; then
        [ ! -L "$CONFIG_DIR/squidmon" ] && [ ! -L "$target" ] || return 1
        install -d -m 750 -o www-data -g www-data "$CONFIG_DIR/squidmon" || return 1
        if [ -e "$target" ]; then
            [ -f "$target" ] && chown www-data:www-data "$target" && chmod 600 "$target" || return 1
        else
            install -m 600 -o www-data -g www-data "$template" "$target" || return 1
        fi
    else
        mkdir -p "$(dirname "$target")" || return 1
        [ -f "$target" ] || cp "$template" "$target" || return 1
        chown -h www-data:www-data "$target" || return 1
    fi
}

migrate_squidmon_config() (
    local old_path="$SQUIDMON_CONFIG" new_path="$CONFIG_DIR/squidmon/config" env_tmp
    [ -f "$old_path" ] && [ ! -L "$old_path" ] || return 1
    [ ! -L "$new_path" ] || return 1
    if [ -e "$new_path" ] && ! cmp -s -- "$old_path" "$new_path"; then
        return 1
    fi
    prepare_squidmon_config "$old_path" "$new_path" || return 1
    env_tmp=$(mktemp "${proxymon_env}.XXXXXX") || return 1
    trap 'rm -f -- "$env_tmp"' EXIT
    sed "s|^SQUIDMON_CONFIG=.*|SQUIDMON_CONFIG=$new_path|" "$proxymon_env" > "$env_tmp" \
        && grep -qxF "SQUIDMON_CONFIG=$new_path" "$env_tmp" \
        && chmod --reference="$proxymon_env" "$env_tmp" \
        && chown --reference="$proxymon_env" "$env_tmp" \
        && mv -fT -- "$env_tmp" "$proxymon_env"
)

do_install() {
    check_requirements install
    local failure_message change_answer
    if [ "${PROXYMON_CONFIRM_CONFIG_CHANGES:-}" != yes ]; then
        echo "Install will add missing packages and change, with a .bak first:"
        echo "ports.conf, apache2.conf, security.conf, mpm_prefork.conf, php.ini, logrotate files"
        read -r -p "Continue? (y/N): " change_answer \
            || abort "cannot read install confirmation -abort"
        if [[ ! "$change_answer" =~ ^[Yy]$ ]]; then
            info "install cancelled -skip"
            exit 0
        fi
    fi
    failure_message="cannot install required packages"
    install_deps
    failure_message="cannot read locations from proxymon.env"
    configure_locations
    if [[ -d "$WEB_ROOT" ]]; then
        abort "proxymon installed; use --update | --uninstall -abort"
    fi
    failure_message="cannot install Apache and PHP packages"
    install_apache2
    failure_message="cannot install Squid packages"
    install_squid
    failure_message="cannot create proxymon.env"
    create_proxymon_env
    load_proxymon_env "$proxymon_env" || abort "cannot load proxymon.env -abort"
    # modules/ is served by Apache. config/ is only
    # read or executed by root, so it lives outside the web tree. web/ is
    # not project content: Apache reads it from its own directory.
    failure_message="cannot create $(basename "$WEB_ROOT")"
    mkdir -p "$WEB_ROOT"
    cp -rf modules/* "$WEB_ROOT"/ \
        || abort "failed to copy modules/ to $WEB_ROOT -abort"

    failure_message="cannot create $(basename "$CONFIG_DIR")"
    mkdir -p "$CONFIG_DIR"
    failure_message="bandata/ + tools/ copy to $(basename "$CONFIG_DIR") failed"
    cp -rf config/bandata config/tools "$CONFIG_DIR"/
    failure_message="cannot deploy the suffix updater"
    install -m 644 -o root -g root config/tools/proxymonenv.sh "$WEB_ROOT/squidreports/proxymonenv.sh"
    chmod 755 "$WEB_ROOT/squidreports/domain-suffixes-update.sh"
    info "updated squidreports/domain-suffixes-update.sh"
    info "updated squidreports/proxymonenv.sh"

    if [[ -f "config/web/proxymon.conf" ]]; then
        failure_message="cannot copy proxymon.conf"
        cp -f config/web/proxymon.conf /etc/apache2/sites-available/proxymon.conf
        info "Proxymon virtualhost configured"
    fi

    if [[ -f "config/web/warning.conf" ]]; then
        failure_message="cannot copy warning.conf"
        cp -f config/web/warning.conf /etc/apache2/sites-available/warning.conf
        info "Warning virtualhost configured"
    fi

    [ -f /etc/apache2/ports.conf.bak ] || cp -f /etc/apache2/ports.conf{,.bak} &>/dev/null || true

    if "$WEB_ROOT/squidreports/squidreports.pl" today; then
        info "initial squidreports report generated"
    else
        warn "cannot generate initial squidreports -alert"
    fi

    failure_message="cannot update Apache site locations"
    configure_apache_locations

    # Load env to get ACL paths defined by create_proxymon_env()
    # Verify ownership/permissions before sourcing -- this file is executed
    # as root, so it must not be writable by anyone other than root.
    env_file_path="$proxymon_env"
    failure_message="cannot read file owner or permissions"
    env_owner=$(stat -c '%U' "$env_file_path" 2>/dev/null) || { report_failure; exit 1; }
    failure_message="cannot read file owner or permissions"
    env_perms=$(stat -c '%a' "$env_file_path" 2>/dev/null) || { report_failure; exit 1; }
    env_group_digit="${env_perms: -2:1}"
    env_other_digit="${env_perms: -1}"
    if [ "$env_owner" != "root" ] || [[ "$env_group_digit" =~ [2367] ]] || [[ "$env_other_digit" =~ [2367] ]]; then
        if [ "$env_owner" != "root" ]; then
            warn "proxymon.env: owner is not root -alert"
        fi
        if [[ "$env_group_digit" =~ [2367] ]] || [[ "$env_other_digit" =~ [2367] ]]; then
            warn "proxymon.env: group or others can write -alert"
        fi
        abort "proxymon.env: unsafe owner or permissions -abort"
    fi
    load_proxymon_env "$env_file_path" || abort "cannot load proxymon.env -abort"

    # Create ACL directories
    # ACL_BANDATA_PATH ships inside config/bandata/acl/ with its 4 files
    # already present, copied to $CONFIG_DIR above. Only its permissions are
    # set here, through the same block, because only root reads those lists.
    acl_prepare "$ACL_PATH" 700 600
    acl_prepare "$ACL_SQUID_PATH" 755 644
    acl_prepare "$ACL_BANDATA_PATH" 700 600 "$ALLOW_LIST" \
        "$BLOCK_LIST_DAY" "$BLOCK_LIST_WEEK" "$BLOCK_LIST_MONTH"
    info "ACL directories created"

    # Create Squidreports report directory if it does not exist
    failure_message="cannot create $(basename "$REPORT_PATH")"
    mkdir -p "$REPORT_PATH"
    failure_message="cannot set permissions on $(basename "$REPORT_PATH")"
    chmod 755 "$REPORT_PATH"
    failure_message="cannot set owner of $(basename "$REPORT_PATH")"
    chown -hR www-data:www-data "$REPORT_PATH"
    failure_message="cannot create $(basename "$REPORT_STATS_PATH")"
    mkdir -p "$REPORT_STATS_PATH"
    failure_message="cannot set permissions on $(basename "$REPORT_STATS_PATH")"
    chmod 755 "$REPORT_STATS_PATH"
    failure_message="cannot set owner of $(basename "$REPORT_STATS_PATH")"
    chown -hR www-data:www-data "$REPORT_STATS_PATH"
    info "Squidreports report directory ready"

    # These blocklists are optional hardening, not required for Proxymon
    # to run -- a failed/slow download must not hang or abort the whole
    # install. Fewer, shorter retries here (with feedback on the way in
    # and out), and a soft failure just skips that one file with a warning.

    if retry_cmd "download blocktlds.txt" get_acl https://raw.githubusercontent.com/maravento/blackweb/refs/heads/master/bwupdate/lst/blocktlds.txt "$ACL_SQUID_PATH/blocktlds.txt"; then
        acl_prepare "$ACL_SQUID_PATH" 755 644 "$ACL_SQUID_PATH/blocktlds.txt"
    else
        warn "blocktlds.txt download failed -alert"
        [ -f "$ACL_SQUID_PATH/blocktlds.txt" ] \
            && acl_fix_perms "$ACL_SQUID_PATH/blocktlds.txt" 644
    fi

    if retry_cmd "download debugbl.txt" get_acl https://raw.githubusercontent.com/maravento/blackweb/refs/heads/master/bwupdate/lst/debugbl.txt "$ACL_SQUID_PATH/blockdomains.txt"; then
        acl_prepare "$ACL_SQUID_PATH" 755 644 "$ACL_SQUID_PATH/blockdomains.txt"
    else
        warn "blockdomains.txt download failed -alert"
        [ -f "$ACL_SQUID_PATH/blockdomains.txt" ] \
            && acl_fix_perms "$ACL_SQUID_PATH/blockdomains.txt" 644
    fi

    if retry_cmd "download blockpatterns.txt" get_acl https://raw.githubusercontent.com/maravento/vault/refs/heads/master/gateproxy/conf/squid/acl/blockpatterns.txt "$ACL_SQUID_PATH/blockpatterns.txt"; then
        acl_prepare "$ACL_SQUID_PATH" 755 644 "$ACL_SQUID_PATH/blockpatterns.txt"
    else
        warn "blockpatterns.txt download failed -alert"
        [ -f "$ACL_SQUID_PATH/blockpatterns.txt" ] \
            && acl_fix_perms "$ACL_SQUID_PATH/blockpatterns.txt" 644
    fi

    [ -f /etc/apache2/mods-available/mpm_prefork.conf.bak ] || cp -f /etc/apache2/mods-available/mpm_prefork.conf{,.bak} &>/dev/null || true
    failure_message="cannot edit mpm_prefork.conf"
    sed -i \
      -e 's/^\(StartServers[[:space:]]*\)5/\110/' \
      -e 's/^\(MinSpareServers[[:space:]]*\)5/\110/' \
      -e 's/^\(MaxSpareServers[[:space:]]*\)10/\115/' \
      -e 's/^\(MaxRequestWorkers[[:space:]]*\)150/\1200/' \
      -e 's/^\(MaxConnectionsPerChild[[:space:]]*\)0/\11000/' \
    /etc/apache2/mods-available/mpm_prefork.conf

    [ -f /etc/php/$php_version/apache2/php.ini.bak ] || cp -f /etc/php/$php_version/apache2/php.ini{,.bak} &>/dev/null || true
    failure_message="cannot edit Apache php.ini"
    sed -i \
      -e 's/^\s*;*\s*max_execution_time\s*=.*/max_execution_time = 120/' \
      -e 's/^\s*max_input_time\s*=.*/max_input_time = 120/' \
      -e 's/^;\s*max_input_time\s*=.*/max_input_time = 120/' \
      -e 's/^\s*;*\s*memory_limit\s*=.*/memory_limit = 1024M/' \
      -e 's/^\s*;*\s*post_max_size\s*=.*/post_max_size = 72M/' \
      -e 's/^\s*;*\s*upload_max_filesize\s*=.*/upload_max_filesize = 64M/' \
      -e 's/^\s*;*\s*opcache.memory_consumption\s*=.*/opcache.memory_consumption = 256/' \
      -e 's/^\s*;*\s*realpath_cache_size\s*=.*/realpath_cache_size = 16M/' \
      -e 's/^\s*;*\s*allow_url_fopen\s*=.*/allow_url_fopen = Off/' \
      -e 's/^\s*;*\s*expose_php\s*=.*/expose_php = Off/' \
      -e 's/^\s*;*\s*display_errors\s*=.*/display_errors = Off/' \
      -e 's/^\s*;*\s*display_startup_errors\s*=.*/display_startup_errors = Off/' \
      -e 's/^\s*;*\s*log_errors\s*=.*/log_errors = On/' \
      -e 's/^\s*;*\s*session\.upload_progress\.enabled\s*=.*/session.upload_progress.enabled = 0/' \
      -e 's/^\s*;*\s*session.use_strict_mode\s*=.*/session.use_strict_mode = 1/' \
      -e 's/^\s*;*\s*session.cookie_httponly\s*=.*/session.cookie_httponly = 1/' \
      -e 's/^\s*;*\s*session.cookie_samesite\s*=.*/session.cookie_samesite = Strict/' \
     /etc/php/$php_version/apache2/php.ini

    # Hardening
    if [ -f /etc/apache2/conf-available/security.conf ]; then
        [ -f /etc/apache2/conf-available/security.conf.bak ] || cp -f /etc/apache2/conf-available/security.conf{,.bak} &>/dev/null || true
    else
        failure_message="cannot create Apache security.conf"
        touch /etc/apache2/conf-available/security.conf
    fi
    failure_message="cannot edit Apache security.conf"
    sed -i "s/^#*\s*ServerSignature.*/ServerSignature Off/" /etc/apache2/conf-available/security.conf
    failure_message="cannot edit Apache security.conf"
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
            failure_message="cannot edit Apache security.conf"
            sed -i "s|^#*\s*Header set $header_name.*|Header set $header_name \"$header_value\"|" /etc/apache2/conf-available/security.conf
        else
            failure_message="cannot write Apache security.conf"
            echo "Header set $header_name \"$header_value\"" >> /etc/apache2/conf-available/security.conf
        fi
    done
    failure_message="cannot write Apache security.conf"
    grep -q "^FileETag None" /etc/apache2/conf-available/security.conf || \
        echo 'FileETag None' >> /etc/apache2/conf-available/security.conf

    failure_message="cannot write Apache security.conf"
    grep -q "^Header unset ETag" /etc/apache2/conf-available/security.conf || \
        echo 'Header unset ETag' >> /etc/apache2/conf-available/security.conf

    failure_message="cannot write Apache security.conf"
    grep -q "^Timeout" /etc/apache2/conf-available/security.conf || \
        echo 'Timeout 60' >> /etc/apache2/conf-available/security.conf
    [ -f /etc/apache2/apache2.conf.bak ] || cp -f /etc/apache2/apache2.conf{,.bak} &>/dev/null || true
    failure_message="cannot edit apache2.conf"
    sed -i -E '/^[[:space:]]*#/!s/^([[:space:]]*Options[[:space:]]+)(-?Indexes[[:space:]]+)?FollowSymLinks[[:space:]]*$/\1-Indexes +FollowSymLinks/' /etc/apache2/apache2.conf
    failure_message="cannot enable Apache headers module"
    a2enmod headers &>/dev/null
    failure_message="cannot enable Apache security configuration"
    a2enconf security &>/dev/null

    failure_message="cannot create $(basename "$CONFIG_DIR")"
    mkdir -p "$CONFIG_DIR" "$(dirname "$LLM_ENV_FILE")"
    if [ ! -f "$LLM_ENV_FILE" ]; then
        failure_message="cannot write $(basename "$LLM_ENV_FILE")"
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
    failure_message="cannot set permissions on $(basename "$LLM_ENV_FILE")"
    chmod 640 "$LLM_ENV_FILE"
    failure_message="cannot set owner of $(basename "$LLM_ENV_FILE")"
    chown root:www-data "$LLM_ENV_FILE"
    failure_message="cannot set permissions on $(basename "$CONFIG_DIR")"
    chmod 750 "$CONFIG_DIR"
    failure_message="cannot set owner of $(basename "$CONFIG_DIR")"
    chown root:www-data "$CONFIG_DIR"
    failure_message="cannot create $(basename "$CACHE_PATH")"
    mkdir -p "$CACHE_PATH"
    failure_message="cannot set permissions on $(basename "$CACHE_PATH")"
    chmod 750 "$CACHE_PATH"
    failure_message="cannot set owner of $(basename "$CACHE_PATH")"
    chown www-data:www-data "$CACHE_PATH"
    info "SquidAI config directory created: $CONFIG_DIR/"
    info "Edit $LLM_ENV_FILE and set your LLM credentials"

    find "$WEB_ROOT" -type d -exec chmod 755 {} +
    find "$WEB_ROOT" -type f -exec chmod 644 {} +
    find "$WEB_ROOT" -type f -name "*.cgi" -exec chmod +x {} +
    failure_message="cannot set permissions on squidreports.pl"
    chmod +x "$WEB_ROOT/squidreports/squidreports.pl"
    secure_web_code "$WEB_ROOT" 0 || abort "cannot secure web code -abort"
    if [ "$SQUIDMON_CONFIG" = "$WEB_ROOT/squidmon/etc/config" ]; then
        migrate_squidmon_config || abort "cannot migrate Squidmon settings -abort"
    else
        prepare_squidmon_config "$WEB_ROOT/squidmon/etc/config" "$SQUIDMON_CONFIG" \
            || abort "cannot prepare Squidmon settings -abort"
    fi

    # acl/ is pruned: its permissions belong to the ACL block, per rules.md 14
    find "$CONFIG_DIR/bandata" "$CONFIG_DIR/tools" -path "$ACL_BANDATA_PATH" \
        -prune -o -type d -exec chmod 755 {} +
    find "$CONFIG_DIR/bandata" "$CONFIG_DIR/tools" -path "$ACL_BANDATA_PATH" \
        -prune -o -type f -exec chmod 644 {} +
    failure_message="cannot set permissions on bandata.sh"
    chmod 750 "$CONFIG_DIR/bandata/bandata.sh"
    failure_message="cannot set permissions on pmbk.sh"
    chmod 750 "$CONFIG_DIR/tools/pmbk.sh"
    failure_message="cannot set permissions on squidtool.sh"
    chmod 750 "$CONFIG_DIR/tools/squidtool.sh"
    failure_message="cannot set owner of $(basename "$CONFIG_DIR")"
    chown -R root:root "$CONFIG_DIR/bandata" "$CONFIG_DIR/tools"
    if ! getent group proxy >/dev/null; then
        groupadd proxy || abort "cannot create group 'proxy' -abort"
        info "group 'proxy' created -fixed"
    fi
    failure_message="cannot add www-data to the proxy group"
    usermod -aG proxy www-data
    failure_message="cannot deploy squid.conf"
    deploy_squid_template
    failure_message="cannot update Squid logrotate settings"
    set_squid_logrotate
    install_project_logrotate || abort "cannot configure proxymon log rotation -abort"
    failure_message="cannot set owner of squid.conf"
    chown root:root /etc/squid/squid.conf
    failure_message="cannot set permissions on squid.conf"
    chmod 644 /etc/squid/squid.conf

    failure_message="cannot create Apache log files"
    touch /var/log/apache2/{warning_access,warning_error,proxymon_access,proxymon_error}.log
    failure_message="cannot set owner of Apache log files"
    chown root:adm /var/log/apache2/{warning_access,warning_error,proxymon_access,proxymon_error}.log
    failure_message="cannot set permissions on Apache log files"
    chmod 640 /var/log/apache2/{warning_access,warning_error,proxymon_access,proxymon_error}.log

    shopt -s nullglob
    squid_logs=("$SQUID_LOG_DIR"/*.log)
    if [ ${#squid_logs[@]} -gt 0 ]; then
        failure_message="cannot set owner of Squid log files"
        chown proxy:proxy "${squid_logs[@]}"
        failure_message="cannot set permissions on Squid log files"
        chmod 640 "${squid_logs[@]}"
    else
        info "No /var/log/squid/*.log files found yet -skip"
    fi
    shopt -u nullglob

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
        abort "cannot enable Apache module '$apache_mod' -abort"
    done

    a2ensite proxymon.conf || abort "cannot enable proxymon.conf -abort"
    a2ensite warning.conf || abort "cannot enable warning.conf -abort"

    systemctl restart cron || abort "cannot restart cron -abort"

    systemctl daemon-reload || abort "cannot reload systemd configuration -abort"
    if ! apachectl -t -D DUMP_INCLUDES -S &>/dev/null; then
        a2dissite proxymon.conf 2>/dev/null || true
        a2dissite warning.conf 2>/dev/null || true
        err "[1/2] tried disabling proxymon.conf, warning.conf"
        err "[2/2] Apache config test failed; fix and retry -abort"
        exit 1
    fi
    info "Apache configuration OK"
    systemctl restart apache2 || abort "cannot restart apache2 -abort"

    failure_message="cannot list enabled Apache sites"
    active_sites=$(a2query -s | awk '{print $1}' | paste -sd ' ')
    info "Active Apache sites: $active_sites"

    register_project_cron || abort "cannot write proxymon cron -abort"

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
    "squidreports/domain-suffixes.txt"
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
        err "web root must be a real directory: $target -abort"
        return 1
    fi
    cd -P -- "$target" || return 1
    if [ "$(pwd -P)" != "$target" ]; then
        err "web root has a symlink: $target -abort"
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
                err "code directory is a symbolic link: $dest_path -abort"
                return 1
            fi
            mkdir -p "$dest_path" || return 1
            chown root:root "$dest_path" || return 1
            chmod 755 "$dest_path" || return 1
        else
            if [ "$copy_code" = 1 ]; then
                cp -f -T --remove-destination -- "$src_path" "$dest_path" || return 1
            elif [ -L "$dest_path" ]; then
                err "code file is a symbolic link: $dest_path -abort"
                return 1
            fi
            chown root:root "$dest_path" || return 1
            case "$rel_path" in
                *.cgi|squidreports/squidreports.pl|squidreports/domain-suffixes-update.sh) chmod 755 "$dest_path" || return 1 ;;
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
    check_requirements update
    install_deps
    install_apache2 update
    configure_locations
    [ -d "$WEB_ROOT" ] || abort "proxymon is not installed -abort"
    [ -f /etc/apache2/ports.conf ] && [ ! -L /etc/apache2/ports.conf ] \
        || update_error "required destination missing or invalid: /etc/apache2/ports.conf"
    update_reset /etc/cron.d/proxymon
    local file rel mode
    [ -r "$script_dir/config/update-files.txt" ] || update_error "missing source: config/update-files.txt"
    while IFS= read -r rel || [ -n "$rel" ]; do
        [ -n "$rel" ] || continue
        [[ "$rel" != /* && "$rel" != *..* ]] || update_error "invalid module path in update-files.txt"
        mode=644
        case "$rel" in *.cgi|squidreports/squidreports.pl|squidreports/domain-suffixes-update.sh) mode=755 ;; esac
        update_file "$script_dir/modules/$rel" "$WEB_ROOT/$rel" "$mode" root:root
    done < "$script_dir/config/update-files.txt"
    for file in bandata/bandata.sh tools/pmbk.sh tools/proxymonenv.sh tools/squidtool.sh; do
        mode=750
        [ "$file" != tools/proxymonenv.sh ] || mode=644
        update_file "$script_dir/config/$file" "$CONFIG_DIR/$file" "$mode" root:root
    done
    update_file "$script_dir/config/tools/proxymonenv.sh" "$WEB_ROOT/squidreports/proxymonenv.sh" 644 root:root
    update_target /etc/apache2/ports.conf
    update_target /etc/apache2/sites-available/proxymon.conf
    update_target /etc/apache2/sites-available/warning.conf
    update_target /var/log/proxymon.log 640 root:adm
    update_target /etc/logrotate.d/squid.bak
    update_target /etc/logrotate.d/squid
    update_target /etc/logrotate.d/proxymon
    update_target /etc/logrotate.d/bandata
    update_target /etc/logrotate.d/apache2
    update_target /etc/logrotate.d/apache2.bak
    for file in squidreports/weekly.cgi squidreports/ip2name/ip2name.dhcp; do
        if [ -e "$WEB_ROOT/$file" ] || [ -L "$WEB_ROOT/$file" ]; then
            update_target "$WEB_ROOT/$file"
        fi
    done
    if [ "$SQUIDMON_CONFIG" = "$WEB_ROOT/squidmon/etc/config" ]; then
        [ -f "$SQUIDMON_CONFIG" ] || update_error "source is not a file: config"
        if [ -f "$CONFIG_DIR/squidmon/config" ] && [ ! -L "$CONFIG_DIR/squidmon/config" ]; then
            cmp -s -- "$SQUIDMON_CONFIG" "$CONFIG_DIR/squidmon/config" \
                || update_error "Squidmon settings differ at the migration destination"
        fi
        update_target "$SQUIDMON_CONFIG"
        update_target "$proxymon_env"
        update_target "$CONFIG_DIR/squidmon" d750 www-data:www-data
        update_target "$CONFIG_DIR/squidmon/config" 600 www-data:www-data
    fi
    update_target "$REPORT_PATH" d755 www-data:www-data
    update_target "$REPORT_STATS_PATH" d755 www-data:www-data
    update_target "$TOOL_REPORT_DIR" d755 root:root
    update_target "$update_cron_file"
    update_target "${update_cron_file}.lock" 600
    update_preflight
    update_backup "$script_dir/config/tools/pmbk.sh"
    update_begin
    update_stop_service apache2
    update_wait_jobs
    update_apply
    secure_web_code "$WEB_ROOT" 0 || update_error "cannot set web code permissions"
    if [ "$SQUIDMON_CONFIG" = "$WEB_ROOT/squidmon/etc/config" ]; then
        migrate_squidmon_config || update_error "cannot migrate Squidmon settings"
    fi
    # Repair the ACL directory modes set by --install; lists are never rewritten
    acl_prepare "$ACL_PATH" 700 600
    acl_prepare "$ACL_SQUID_PATH" 755 644
    for file in blocktlds.txt blockdomains.txt blockpatterns.txt; do
        if [ -f "$ACL_SQUID_PATH/$file" ]; then
            acl_fix_perms "$ACL_SQUID_PATH/$file" 644
        fi
    done
    acl_prepare "$ACL_BANDATA_PATH" 700 600 "$ALLOW_LIST" \
        "$BLOCK_LIST_DAY" "$BLOCK_LIST_WEEK" "$BLOCK_LIST_MONTH"
    rm -f -- "$WEB_ROOT/squidreports/weekly.cgi" "$WEB_ROOT/squidreports/ip2name/ip2name.dhcp" \
        || update_error "cannot remove obsolete web code"
    configure_apache_locations
    set_squid_logrotate
    install_project_logrotate || update_error "cannot configure proxymon log rotation"
    apache2ctl configtest || update_error "Apache configuration invalid"
    register_project_cron || update_error "cannot regenerate proxymon cron"
    update_finish
    info "Proxy Monitor updated successfully"
}

# ------------------------------------------------------------------------------
# UNINSTALL
# ------------------------------------------------------------------------------

do_uninstall() {
    local failure_message
    failure_message="cannot read the uninstall confirmation"
    read -p "Are you sure you want to uninstall? (y/n): " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "uninstall cancelled -skip"
        return 0
    fi
    failure_message="cannot read locations from proxymon.env"
    configure_locations

    if [[ ! -d "$WEB_ROOT" ]] && [[ ! -d "$CONFIG_DIR" ]]; then
        info "Proxy Monitor is not installed"
        return 0
    fi

    if bash "$CONFIG_DIR/tools/pmbk.sh"; then
        info "backup taken with pmbk.sh"
    else
        abort "pmbk.sh: backup failed -abort"
    fi

    local rotate_file=/etc/logrotate.d/squid
    local hook="runuser -u www-data -- $WEB_ROOT/squidreports/squidreports.pl yesterday --wait-lock"
    if [ -f "$rotate_file" ] && grep -qE "^[[:space:]]*${hook//./\\.}[[:space:]]*$" "$rotate_file"; then
        failure_message="cannot edit Squid logrotate settings"
        sed -i "\|^[[:space:]]*${hook//./\\.}[[:space:]]*$|d" "$rotate_file"
    fi

    failure_message="cannot remove proxymon"
    rm -f /etc/cron.d/proxymon /etc/cron.d/proxymon.update-disabled
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
                    warn "cannot query $base_chain; continuing uninstall -alert"
                    break
                fi
                [ -n "$rule_num" ] || break
                if ! iptables -D "$base_chain" "$rule_num" 2>/dev/null; then
                    warn "cannot remove $target_chain jump -alert"
                    break
                fi
            done
        done

        # Remove the NAT redirect to the warning portal
        while true; do
            if ! rule_num=$(iptables -t nat -L PREROUTING --line-numbers -n 2>/dev/null | awk '/match-set bandata/ && !found {print $1; found=1}'); then
                warn "cannot query NAT rules; continuing uninstall -alert"
                break
            fi
            [ -n "$rule_num" ] || break
            if ! iptables -t nat -D PREROUTING "$rule_num" 2>/dev/null; then
                warn "cannot remove Bandata redirect -alert"
                break
            fi
        done

        # Flush and remove the now-unreferenced Bandata chains
        for bandata_chain in BANDATA_FWD BANDATA_IN; do
            if iptables -L "$bandata_chain" -n &>/dev/null; then
                iptables -F "$bandata_chain" 2>/dev/null || warn "cannot flush $bandata_chain -alert"
                iptables -X "$bandata_chain" 2>/dev/null || warn "cannot remove $bandata_chain -alert"
            fi
        done
        info "Bandata iptables cleanup finished"
    fi

    if command -v ipset >/dev/null 2>&1 && ipset list bandata &>/dev/null; then
        ipset destroy bandata 2>/dev/null \
            || warn "cannot remove ipset bandata; remove manually -alert"
    fi

    # mpm_prefork.conf, security.conf and apache2.conf stay as they are:
    # they may hold user data. Their .bak copies remain.

    if [[ -f "/etc/apache2/sites-available/proxymon.conf" ]]; then
        a2dissite proxymon.conf 2>/dev/null || true
        failure_message="cannot remove proxymon.conf"
        rm -f /etc/apache2/sites-available/proxymon.conf
        info "Proxymon site disabled"
    fi

    if [[ -f "/etc/apache2/sites-available/warning.conf" ]]; then
        a2dissite warning.conf 2>/dev/null || true
        failure_message="cannot remove warning.conf"
        rm -f /etc/apache2/sites-available/warning.conf
        info "Warning site disabled"
    fi

    if [[ -d "$WEB_ROOT" ]]; then
        failure_message="cannot remove $(basename "$WEB_ROOT")"
        rm -rf "$WEB_ROOT"
        info "Installation directory removed"
    fi

    if [[ -d "$CACHE_PATH" ]]; then
        failure_message="cannot remove $(basename "$CACHE_PATH")"
        rm -rf "$CACHE_PATH"
        info "Cache directory removed"
    fi

    if [[ -d "$CONFIG_DIR" ]]; then
        failure_message="cannot read the config removal confirmation"
        read -p "Remove $CONFIG_DIR/ (contains LLM credentials, root scripts and Bandata lists)? (y/n): " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            failure_message="cannot remove $(basename "$CONFIG_DIR")"
            rm -rf "$CONFIG_DIR"
            info "Config directory removed"
        else
            info "$CONFIG_DIR kept -- remove manually if needed"
        fi
    fi

    failure_message="cannot edit Apache ports.conf"
    sed -i -E "/^Listen [^[:space:]]*:${PANEL_PORT}\$/d; /^Listen ${PANEL_PORT}\$/d" /etc/apache2/ports.conf
    info "Port $PANEL_PORT removed from Apache"

    failure_message="cannot edit Apache ports.conf"
    sed -i -E "/^Listen [^[:space:]]*:${WARNING_PORT}\$/d; /^Listen ${WARNING_PORT}\$/d" /etc/apache2/ports.conf
    info "Port $WARNING_PORT removed from Apache"

    failure_message="cannot remove Apache log files"
    rm -f /var/log/apache2/{warning_access,warning_error,proxymon_access,proxymon_error}.log*
    info "Proxymon log files removed"

    failure_message="cannot remove bandata.log*"
    rm -f /etc/logrotate.d/proxymon && info "Removed /etc/logrotate.d/proxymon"
    rm -f -- /var/log/proxymon.log /var/log/proxymon.log.* && info "Proxymon project log removed"
    rm -f /etc/logrotate.d/bandata /var/log/bandata.log* && {
        info "Removed /etc/logrotate.d/bandata"
        info "Bandata log files removed"
    }

    systemctl restart cron || abort "cannot restart cron -abort"
    systemctl daemon-reload || abort "cannot reload systemd configuration -abort"
    systemctl restart apache2 || abort "cannot restart apache2 -abort"

    failure_message="cannot list enabled Apache sites"
    remaining_sites=$(a2query -s | awk '{print $1}' | paste -sd ' ')
    info "Remaining Apache sites: $remaining_sites"

    info "Proxy Monitor uninstalled successfully"
    info "Restart to clear remaining temporary Bandata rules"
}

# ------------------------------------------------------------------------------
# MENU
# ------------------------------------------------------------------------------

# Interactive menu shown when the script runs without arguments
show_menu() {
    local failure_message="cannot read the installer menu choice"
    while true; do
        echo ""
        echo "proxymon installer"
        echo "------------------"
        echo "1) Install"
        echo "2) Update"
        echo "3) Uninstall"
        echo "4) Exit"
        echo ""
        failure_message="cannot read the installer menu choice"
        read -p "Select option [4]: " menu_option
        menu_option="${menu_option:-4}"
        case "$menu_option" in
            1) do_install; break ;;
            2) do_update; break ;;
            3) do_uninstall; break ;;
            4) break ;;
            *) info "invalid option -retry" ;;
        esac
    done
}

usage() {
    local failure_message
    failure_message="cannot display installer usage"
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
# ENV
# ------------------------------------------------------------------------------

# LOAD_CONF
# Load the shared configuration reader
source "$script_dir/config/tools/proxymonenv.sh"

# ------------------------------------------------------------------------------
# ACTIONS
# ------------------------------------------------------------------------------

# Run the action given on the command line, or fall back to the menu
log "INFO: pmsetup start..."

case "${1:-}" in
    --install) do_install ;;
    --update) do_update ;;
    --uninstall) do_uninstall ;;
    "") show_menu ;;
    -h|--help) usage ;;
    *)
        err "invalid option -abort"
        failure_message="cannot display installer usage"
        usage
        exit 1
        ;;
esac

log "INFO: pmsetup done"
