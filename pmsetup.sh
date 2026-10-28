#!/bin/bash
# maravento.com
#
################################################################################
#
# pmsetup -- installer for proxymon
# FILE: pmsetup.sh
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
    unset WEB_ROOT CONFIG_DIR BACKUP_DIR PANEL_PORT WARNING_PORT
    unset TOOL_REPORT_DIR SQUIDMON_CONFIG LLM_ENV_FILE REPORT_STATS_PATH
    if [ -f "$proxymon_env" ]; then
        load_proxymon_env "$proxymon_env" || abort "cannot load proxymon.env -abort"
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
check_dependencies() {
    for dep_pkg in wget curl git zip unzip ipset nbtscan libcgi-session-perl libgd-perl libjson-xs-perl coreutils fonts-lato fonts-liberation fonts-dejavu perl python3 cron sudo util-linux iproute2 passwd findutils sed grep hostname ncurses-bin systemd libc-bin iptables gawk gzip procps logrotate; do
        if ! package_installed "$dep_pkg"; then
            if [ "$dep_pkg" = libjson-xs-perl ]; then
                info "Installing missing dependency: $dep_pkg"
                apt-get install -y "$dep_pkg" || abort "cannot install '$dep_pkg' -abort"
            else
                abort "'$dep_pkg' is not installed -abort"
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
        package_installed "$dep_pkg" || missing_pkgs+=("$dep_pkg")
    done
    if (( ${#missing_pkgs[@]} == 0 )); then
        info "apache2 and php already present"
        return 0
    fi

    DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "${missing_pkgs[@]}" \
        || { err "cannot install ${missing_pkgs[*]}"; abort "install them with apt, then re-run -abort"; }
    systemctl enable apache2 &>/dev/null || true
    info "Installed: ${missing_pkgs[*]}"
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

    DEBIAN_FRONTEND=noninteractive apt-get -qq install -y squid-openssl squid-langpack squid-common \
        || { err "cannot install squid-openssl"; abort "install it with apt, then re-run -abort"; }
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
    info "squid.conf deployed with RANGE=$RANGE and SERVER_IP=$SERVER_IP"
    failure_message="cannot create Squid cache directories"
    mkdir -p /var/spool/squid/rock
    failure_message="cannot set owner of Squid cache directories"
    chown -R proxy:proxy /var/spool/squid
    failure_message="cannot set permissions on Squid cache directories"
    chmod -R 700 /var/spool/squid
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

# Squidmon and Logview read only the current access.log, so a rotation leaves
# them without the activity moved to the rotated file. SquidAI also reads the
# first rotated file, which keeps its answers by date correct across that
# boundary. Weekly rotation keeps the gap of the first two modules bounded.
set_squid_logrotate() {
    local failure_message="cannot update Squid logrotate settings"
    local rotate_file=/etc/logrotate.d/squid
    local hook="runuser -u www-data -- $WEB_ROOT/squidreports/squidreports.pl yesterday --wait-lock"

    if [ ! -f "$rotate_file" ]; then
        warn "Squid logrotate missing; rotation unchanged -alert"
        return 0
    fi
    cp -f "$rotate_file"{,.bak} &>/dev/null || true
    if grep -qE '^[[:space:]]*weekly$' "$rotate_file"; then
        info "$rotate_file already weekly -skip"
    else
        failure_message="cannot edit Squid logrotate settings"
        sed -i -E 's/^([[:space:]]*)(hourly|daily|monthly|yearly)$/\1weekly/' \
            "$rotate_file"
        if ! grep -qE '^[[:space:]]*weekly$' "$rotate_file"; then
            failure_message="cannot edit Squid logrotate settings"
            sed -i '0,/{[[:space:]]*$/s//&\n    weekly/' "$rotate_file"
        fi
        if grep -qE '^[[:space:]]*weekly$' "$rotate_file"; then
            info "$rotate_file set to weekly -fixed"
        else
            warn "cannot set weekly in ${rotate_file#/etc/} -alert"
        fi
    fi
    failure_message="cannot edit Squid logrotate settings"
    sed -i '/^[[:space:]]*nocreate$/d' "$rotate_file"
    if grep -qE '^[[:space:]]*create[[:space:]]+0640[[:space:]]+proxy[[:space:]]+proxy$' "$rotate_file"; then
        info "${rotate_file#/etc/} creates the log as 0640 proxy -skip"
    elif ! grep -qE '^[[:space:]]*sharedscripts' "$rotate_file"; then
        warn "squid has no sharedscripts, create not added -alert"
    else
        failure_message="cannot edit Squid logrotate settings"
        sed -i '/^[[:space:]]*sharedscripts/a \    create 0640 proxy proxy' "$rotate_file"
        info "${rotate_file#/etc/} set to create 0640 proxy -fixed"
    fi
    if grep -qE '^[[:space:]]*rotate[[:space:]]+7$' "$rotate_file"; then
        info "$rotate_file already rotate 7 -skip"
    else
        failure_message="cannot edit Squid logrotate settings"
        sed -i -E 's/^([[:space:]]*)rotate[[:space:]]+[0-9]+$/\1rotate 7/' "$rotate_file"
        if grep -qE '^[[:space:]]*rotate[[:space:]]+7$' "$rotate_file"; then
            info "$rotate_file set to rotate 7 -fixed"
        else
            warn "cannot set rotate 7 in ${rotate_file#/etc/} -alert"
        fi
    fi
    local size_directive size_directives=""
    for size_directive in size maxsize; do
        if grep -qE "^[[:space:]]*$size_directive[[:space:]]" "$rotate_file"; then
            size_directives="${size_directives:+$size_directives|}$size_directive"
        fi
    done
    if [ -n "$size_directives" ]; then
        warn "$(basename "$rotate_file") allows log rotation by $size_directives -alert"
    fi
    if grep -qE "^[[:space:]]*$hook$" "$rotate_file"; then
        info "squidreports.pl yesterday already in rotation -skip"
    elif grep -qE '^[[:space:]]*prerotate' "$rotate_file"; then
        info "$rotate_file has prerotate defined -skip"
    elif ! grep -qE '^[[:space:]]*sharedscripts' "$rotate_file"; then
        warn "Squidreports: squid has no sharedscripts"
        warn "Squidreports not added before log rotation -alert"
    else
        failure_message="cannot edit Squid logrotate settings"
        sed -i "/^[[:space:]]*sharedscripts/a \\    prerotate\n        $hook\n    endscript" "$rotate_file"
        info "squidreports.pl yesterday added to rotation -fixed"
    fi
}

squid_preexisting=1
failure_message="cannot check required packages"
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
            warn "conflicting $role: $dep_pkg -alert"
        done
        abort "remove them with apt purge -abort"
    fi
}

# port in use
check_port() {
    local proto="$1" port="$2" role="$3"
    if [ -n "$(ss -lnH "-${proto,,}" "sport = :$port" 2>/dev/null)" ]; then
        err "${proto^^} port $port in use by another $role"
        abort "stop that service before installing -abort"
    fi
}

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

proxymon_env="/etc/proxymon/proxymon.env"

# validation -- one variable per thing validated; use directly with =~
UH_IPV4='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_CIDR='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])/(3[0-2]|[12][0-9]|[0-9])$'
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
    update_daemons=()
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

update_stop_daemon() {
    local script="$1" pids
    pids=$(update_pids "$script") || update_error "cannot inspect processes: $script"
    if [ -n "$pids" ]; then
        update_daemons+=("$script")
        bash "$script" --stop || update_error "cannot stop daemon: $script"
        update_wait "$script"
    fi
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
        log "ERROR: $unit state: $state"
        update_error "$unit did not stop"
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
            log "ERROR: src and dst: $compared_file"
            update_error "src and dst do not match"
        }
        info "updated $(basename "$target")"
    done
}

update_resume() {
    local unit script state
    for unit in "${update_services[@]}"; do
        systemctl start "$unit" || update_error "cannot start service: $unit"
        state=$(systemctl show -p ActiveState --value "$unit") || update_error "cannot inspect started: $unit"
        [ "$state" = active ] || {
            log "ERROR: $unit state: $state"
            update_error "$unit did not start"
        }
    done
    for script in "${update_daemons[@]}"; do
        bash "$script" --start || update_error "cannot start daemon: $script"
        [ -n "$(update_pids "$script")" ] || update_error "daemon did not start: $script"
    done
}

update_finish() {
    update_resume
    rm -f -- "${update_cron_file}.update-disabled" || update_error "cannot finish cron update: $(basename "$update_cron_file")"
    trap - EXIT
    unset UPDATE_CRON_OWNER
}

update_cleanup() {
    local status="$1" unit script
    trap - EXIT
    if (( update_copying == 0 )); then
        for unit in "${update_services[@]}"; do
            systemctl start "$unit" || warn "cannot resume $unit -alert"
        done
        for script in "${update_daemons[@]}"; do
            bash "$script" --start || warn "cannot resume $(basename "$script") -alert"
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
        for script in "${update_daemons[@]}"; do
            bash "$script" --stop || warn "cannot keep $(basename "$script") stopped -alert"
        done
    fi
    (( status != 0 )) || status=1
    exit "$status"
}

# INTEGER RANGE
# Check signed Bash integer limits
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
    log "INFO: $acl_path perms fixed -fixed"
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
    if ! timeout 30 wget -q -c -N --timeout=15 --tries=1 "$source_url" -O "$target_file"; then
        log "PARTIAL: $source_url"
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
    local max_retries="${RETRY_CMD_MAX:-10}"
    local retry_delay="${RETRY_CMD_DELAY:-10}"
    local retry_attempt=1
    local retry_file
    retry_file=$(basename "${@: -1}")
    until "$@"; do
        if [ "$retry_attempt" -ge "$max_retries" ]; then
            if [ "${RETRY_CMD_SOFT_FAIL:-0}" -eq 1 ]; then
                return 1
            fi
            abort "$retry_file: download failed -abort"
        fi
        info "$retry_file: download failed; retry $((retry_attempt + 1))/$max_retries"
        retry_attempt=$((retry_attempt + 1))
        sleep "$retry_delay"
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
    local failure_message="cannot check Proxymon requirements"
    info "running initial checks"
    failure_message="cannot check Apache and PHP settings"
    check_apache_config
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
        err "clone it from github.com/maravento/proxymon -abort"
        echo ""
        exit 1
    fi
}

# LAN SELECTION
# Select an existing interface and one of its configured IPv4 addresses
choose_lan_interface() {
    local preset_iface="${1:-}" excluded_iface="${2:-}"
    local iface_name iface_choice iface_index iface_addrs
    local -a lan_candidates=()
    if [ -n "$preset_iface" ]; then
        ip link show dev "$preset_iface" >/dev/null 2>&1 || {
            log "ERROR: LAN interface '$preset_iface' not found -abort"
            exit 1
        }
        [ "$preset_iface" != "$excluded_iface" ] || {
            log "ERROR: LAN and WAN must differ -abort"
            exit 1
        }
        lan_iface_answer="$preset_iface"
        return 0
    fi
    while IFS= read -r iface_name; do
        [ "$iface_name" = "$excluded_iface" ] && continue
        lan_candidates+=("$iface_name")
    done < <(ip -br link show | awk '$1 != "lo" {sub(/@.*/, "", $1); print $1}')
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
        iface_addrs=$(ip -4 -o addr show dev "$iface_name" scope global | awk '{print $4}' | paste -sd' ')
        printf ' [%d] %s (%s)\n' "$((iface_index + 1))" "$iface_name" "${iface_addrs:-no IPv4}"
    done
    while true; do
        read -r -p "Select LAN interface number: " iface_choice || {
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
        printf ' [%d] %s\n' "$((ipv4_index + 1))" "${lan_addresses[$ipv4_index]}"
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
        local required_keys="WEB_ROOT CONFIG_DIR BACKUP_DIR TOOL_REPORT_DIR SQUIDMON_CONFIG LLM_ENV_FILE REPORT_STATS_PATH PANEL_PORT PANEL_DOMAINS WARNING_PORT LAN SERVER_IP RANGE REPORT_IP_GLOB SQUIDREPORTS_DIR REPORT_PATH REALNAME_CFG SKIPUSERS_CFG ACL_PATH ACL_MAC_PATH ACL_SQUID_PATH ACL_BANDATA_PATH ALLOW_LIST BLOCK_LIST_DAY BLOCK_LIST_WEEK BLOCK_LIST_MONTH SQUID_LOG_DIR SQUID_LOG_FILE WARNING_HTML CACHE_PATH SQUID_MGR_HOST SQUID_MGR_PORT SQUID_INTERCEPT_PORT SQUID_MGR_PASSWD MAX_BANDWIDTH_DAY MAX_BANDWIDTH_WEEK MAX_BANDWIDTH_MONTH BANDATA_HOTSPOT HOTSPOT_PATH UPDATE_REALNAME SQUIDTOOL_MIN_HITS SQUIDTOOL_ALERT_THRESHOLD"
        local missing_flag=""
        for env_key in $required_keys; do
            grep -q "^${env_key}=" "$env_file" || missing_flag="$missing_flag $env_key"
        done
        if [ -n "$missing_flag" ]; then
            for env_key in $missing_flag; do
                warn "$(basename "$env_file"): missing variable $env_key"
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

    choose_lan_interface "${PROXYMON_LAN:-}"
    lan_answer="$lan_iface_answer"
    read_lan_ipv4 "$lan_answer" "${PROXYMON_SERVER_IP:-}"
    server_ip_answer="${lan_cidr_answer%/*}"
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

    # Bandwidth limits -- validate with numfmt (accepts e.g. 500M, 1G, 1.5G)
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
            if quota_bytes=$(LC_ALL=C numfmt --from=iec "${user_answer/,/.}" 2>/dev/null); then
                if [ "$check_bash_range" = true ] \
                    && ! uh_fits "$quota_bytes"; then
                    info "daily quota exceeds Bash integer range -retry" >&2
                    continue
                fi
                echo "$user_answer"
                return
            fi
            echo "'$user_answer' is not a valid size (e.g. 500M, 1G, 1.5G). Try again." >&2
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
# Changing these defaults is not recommended
SQUIDTOOL_MIN_HITS=20
SQUIDTOOL_ALERT_THRESHOLD=300

# Bandata
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
HOTSPOT_PATH=${hotspot_dir}
UPDATE_REALNAME=${update_realname_flag}

# Backup
# Changing these defaults is not recommended
BACKUP_DIR=${BACKUP_DIR}
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
    [ -f "$apache_rotate" ] || { warn "apache2 has no logrotate file -alert"; return 0; }
    if grep -qE '^[[:space:]]*rotate[[:space:]]+7$' "$apache_rotate"; then
        info "${apache_rotate#/etc/} already rotate 7 -skip"
        return 0
    fi
    cp -f "$apache_rotate"{,.bak} &>/dev/null || true
    sed -i -E 's/^([[:space:]]*)rotate[[:space:]]+[0-9]+$/\1rotate 7/' "$apache_rotate"
    if grep -qE '^[[:space:]]*rotate[[:space:]]+7$' "$apache_rotate"; then
        info "${apache_rotate#/etc/} set to rotate 7 -fixed"
    else
        warn "cannot set rotate 7 in ${apache_rotate#/etc/} -alert"
    fi
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
    daily
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
    set_apache_logrotate
}

do_install() {
    local failure_message="cannot finish the Proxymon installation"
    failure_message="cannot check conflicting packages"
    check_conflicts "web server" nginx lighttpd caddy
    failure_message="cannot read locations from proxymon.env"
    configure_locations
    if [[ -d "$WEB_ROOT" ]]; then
        abort "proxymon already installed -abort"
    fi
    failure_message="cannot check the internet connection"
    check_internet
    failure_message="cannot install Apache and PHP packages"
    install_apache2
    failure_message="cannot install Squid packages"
    install_squid
    failure_message="cannot check Proxymon requirements"
    run_initial_checks

    failure_message="cannot check the required network port"
    check_port tcp "$PANEL_PORT" "web interface"
    failure_message="cannot check the required network port"
    check_port tcp "$WARNING_PORT" "warning page"

    failure_message="cannot check required repository files"
    check_repo
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

    log "EVENT: Configuring Apache..."

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

    log "EVENT: Configuring Squid Monitor..."

    log "EVENT: Configuring Squidreports..."
    if "$WEB_ROOT/squidreports/squidreports.pl" today; then
        info "initial squidreports report generated"
    else
        warn "cannot generate initial squidreports -alert"
    fi

    failure_message="cannot update Apache site locations"
    configure_apache_locations

    log "EVENT: Configuring ACL directories and files..."
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
            err "proxymon.env: owner is not root -abort"
        fi
        if [[ "$env_group_digit" =~ [2367] ]] || [[ "$env_other_digit" =~ [2367] ]]; then
            err "proxymon.env: group or others can write -abort"
        fi
        exit 1
    fi
    load_proxymon_env "$env_file_path" || abort "cannot load proxymon.env -abort"

    # Create ACL directories
    # ACL_BANDATA_PATH ships inside config/bandata/acl/ with its 4 files
    # already present, copied to $CONFIG_DIR above. Only its permissions are
    # set here, through the same block, because only root reads those lists.
    acl_prepare "$ACL_PATH" 755 644
    acl_prepare "$ACL_MAC_PATH" 700 600
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

    if RETRY_CMD_MAX=3 RETRY_CMD_DELAY=5 RETRY_CMD_SOFT_FAIL=1 retry_cmd get_acl https://raw.githubusercontent.com/maravento/blackweb/refs/heads/master/bwupdate/lst/blocktlds.txt "$ACL_SQUID_PATH/blocktlds.txt"; then
        acl_prepare "$ACL_SQUID_PATH" 755 644 "$ACL_SQUID_PATH/blocktlds.txt"
    else
        warn "blocktlds.txt download failed -alert"
        [ -f "$ACL_SQUID_PATH/blocktlds.txt" ] \
            && acl_fix_perms "$ACL_SQUID_PATH/blocktlds.txt" 644
    fi

    if RETRY_CMD_MAX=3 RETRY_CMD_DELAY=5 RETRY_CMD_SOFT_FAIL=1 retry_cmd get_acl https://raw.githubusercontent.com/maravento/blackweb/refs/heads/master/bwupdate/lst/debugbl.txt "$ACL_SQUID_PATH/blockdomains.txt"; then
        acl_prepare "$ACL_SQUID_PATH" 755 644 "$ACL_SQUID_PATH/blockdomains.txt"
    else
        warn "blockdomains.txt download failed -alert"
        [ -f "$ACL_SQUID_PATH/blockdomains.txt" ] \
            && acl_fix_perms "$ACL_SQUID_PATH/blockdomains.txt" 644
    fi

    if RETRY_CMD_MAX=3 RETRY_CMD_DELAY=5 RETRY_CMD_SOFT_FAIL=1 retry_cmd get_acl https://raw.githubusercontent.com/maravento/vault/refs/heads/master/gateproxy/acl/squid/blockpatterns.txt "$ACL_SQUID_PATH/blockpatterns.txt"; then
        acl_prepare "$ACL_SQUID_PATH" 755 644 "$ACL_SQUID_PATH/blockpatterns.txt"
    else
        warn "blockpatterns.txt download failed -alert"
        [ -f "$ACL_SQUID_PATH/blockpatterns.txt" ] \
            && acl_fix_perms "$ACL_SQUID_PATH/blockpatterns.txt" 644
    fi

    log "EVENT: Updating Prefork MPM..."
    [ -f /etc/apache2/mods-available/mpm_prefork.conf.bak ] || cp -f /etc/apache2/mods-available/mpm_prefork.conf{,.bak} &>/dev/null || true
    failure_message="cannot edit mpm_prefork.conf"
    sed -i \
      -e 's/^\(StartServers[[:space:]]*\)5/\110/' \
      -e 's/^\(MinSpareServers[[:space:]]*\)5/\110/' \
      -e 's/^\(MaxSpareServers[[:space:]]*\)10/\115/' \
      -e 's/^\(MaxRequestWorkers[[:space:]]*\)150/\1200/' \
      -e 's/^\(MaxConnectionsPerChild[[:space:]]*\)0/\11000/' \
    /etc/apache2/mods-available/mpm_prefork.conf

    log "EVENT: Updating PHP..."
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
      -e 's/^\s*;*\s*session.use_strict_mode\s*=.*/session.use_strict_mode = 1/' \
      -e 's/^\s*;*\s*session.cookie_httponly\s*=.*/session.cookie_httponly = 1/' \
      -e 's/^\s*;*\s*session.cookie_samesite\s*=.*/session.cookie_samesite = Strict/' \
     /etc/php/$php_version/apache2/php.ini

    # Hardening
    log "EVENT: Updating Apache2 Security..."
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

    log "EVENT: Configuring SquidAI..."
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

    log "EVENT: Setting Permissions..."
    find "$WEB_ROOT" -type d -exec chmod 755 {} +
    find "$WEB_ROOT" -type f -exec chmod 644 {} +
    find "$WEB_ROOT" -type f -name "*.cgi" -exec chmod +x {} +
    failure_message="cannot set permissions on squidreports.pl"
    chmod +x "$WEB_ROOT/squidreports/squidreports.pl"
    secure_web_code "$WEB_ROOT" 0 || abort "cannot secure web code -abort"
    if [ "$SQUIDMON_CONFIG" != "$WEB_ROOT/squidmon/etc/config" ]; then
        failure_message="cannot create the Squid Monitor config directory"
        mkdir -p "$(dirname "$SQUIDMON_CONFIG")"
        failure_message="cannot copy $(basename "$WEB_ROOT")"
        [ -f "$SQUIDMON_CONFIG" ] || cp "$WEB_ROOT/squidmon/etc/config" "$SQUIDMON_CONFIG"
    fi
    failure_message="cannot set owner of Squid Monitor config"
    chown -h www-data:www-data "$SQUIDMON_CONFIG"

    # acl/ is pruned: its permissions belong to the ACL block, per rules.md 14
    find "$CONFIG_DIR/bandata" "$CONFIG_DIR/tools" -path "$ACL_BANDATA_PATH" \
        -prune -o -type d -exec chmod 755 {} +
    find "$CONFIG_DIR/bandata" "$CONFIG_DIR/tools" -path "$ACL_BANDATA_PATH" \
        -prune -o -type f -exec chmod 644 {} +
    failure_message="cannot set permissions on bandata.sh"
    chmod 755 "$CONFIG_DIR/bandata/bandata.sh"
    failure_message="cannot set permissions on pmbk.sh"
    chmod 755 "$CONFIG_DIR/tools/pmbk.sh"
    failure_message="cannot set permissions on squidtool.sh"
    chmod 755 "$CONFIG_DIR/tools/squidtool.sh"
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

    log "EVENT: Setting Logs..."
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

    log "EVENT: Enabling Apache Modules..."
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
        abort "cannot enable Apache module '$apache_mod', check it is installed -abort"
    done

    log "EVENT: Enabling Apache Sites..."
    a2ensite proxymon.conf || abort "cannot enable proxymon.conf -abort"
    a2ensite warning.conf || abort "cannot enable warning.conf -abort"

    log "EVENT: Restarting Cron..."
    systemctl restart cron || abort "cannot restart cron -abort"

    log "EVENT: Restarting Apache2..."
    systemctl daemon-reload || abort "cannot reload systemd configuration -abort"
    if ! apachectl -t -D DUMP_INCLUDES -S &>/dev/null; then
        a2dissite proxymon.conf 2>/dev/null || true
        a2dissite warning.conf 2>/dev/null || true
        err "Apache tried disabling proxymon.conf and warning.conf"
        err "Apache config test failed; fix it and retry -abort"
        exit 1
    fi
    info "Apache configuration OK"
    systemctl restart apache2 || abort "cannot restart apache2 -abort"

    info "Check Active Apache sites:"
    failure_message="cannot list enabled Apache sites"
    a2query -s

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
        err "web root has a symbolic link in its path: $target -abort"
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
        mode=755
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
    local failure_message="cannot finish the Proxymon removal"
    failure_message="cannot read the uninstall confirmation"
    read -p "Are you sure you want to uninstall? (y/n): " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "uninstall cancelled -skip"
        return 0
    fi
    failure_message="cannot read locations from proxymon.env"
    configure_locations
    log "EVENT: Uninstalling Proxy Monitor..."

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
                    warn "cannot remove $target_chain jump; continuing uninstall -alert"
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

    if [[ -f "/etc/apache2/mods-available/mpm_prefork.conf.bak" ]]; then
        failure_message="cannot restore mpm_prefork.conf"
        mv -f /etc/apache2/mods-available/mpm_prefork.conf.bak /etc/apache2/mods-available/mpm_prefork.conf
        info "mpm_prefork configuration restored"
    fi

    php_version=""
    if command -v php >/dev/null 2>&1; then
        php_version=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;" 2>/dev/null || true)
    fi
    if [[ -n "$php_version" && -f "/etc/php/$php_version/apache2/php.ini.bak" ]]; then
        failure_message="cannot restore Apache php.ini"
        mv -f "/etc/php/$php_version/apache2/php.ini.bak" "/etc/php/$php_version/apache2/php.ini"
        info "php.ini restored"
    fi

    if [[ -f "/etc/apache2/conf-available/security.conf.bak" ]]; then
        failure_message="cannot restore Apache security.conf"
        mv -f /etc/apache2/conf-available/security.conf.bak /etc/apache2/conf-available/security.conf
        info "security.conf restored"
    fi

    if [[ -f "/etc/apache2/apache2.conf.bak" ]]; then
        failure_message="cannot restore apache2.conf"
        mv -f /etc/apache2/apache2.conf.bak /etc/apache2/apache2.conf
        info "apache2.conf restored"
    fi

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

    if [[ -x "$CONFIG_DIR/tools/pmbk.sh" ]]; then
        "$CONFIG_DIR/tools/pmbk.sh" --uninstall || true
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
    rm -f /etc/logrotate.d/bandata /var/log/bandata.log* && {
        info "Removed /etc/logrotate.d/bandata"
        info "Bandata log files removed"
    }

    systemctl restart cron || abort "cannot restart cron -abort"
    systemctl daemon-reload || abort "cannot reload systemd configuration -abort"
    systemctl restart apache2 || abort "cannot restart apache2 -abort"

    info "Remaining Apache sites:"
    failure_message="cannot list enabled Apache sites"
    a2query -s

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
    local failure_message="cannot display installer usage"
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
log "EVENT: pmsetup start..."

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

log "EVENT: pmsetup done"
