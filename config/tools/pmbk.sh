#!/bin/bash
# maravento.com
#
################################################################################
#
# pmbk -- configuration backup for proxymon
#
# USAGE:
# sudo bash pmbk.sh            Create a backup now
# sudo bash pmbk.sh --install    Register the @monthly cron entry
# sudo bash pmbk.sh --uninstall  Remove the cron entry (keeps archives)
#
# LOG: /var/log/proxymon.log
#
################################################################################

set -euo pipefail

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
log_file="/var/log/proxymon.log"
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
for dep_pkg in zip coreutils util-linux cron; do
    if ! package_installed "$dep_pkg"; then
        log "ERROR: dependency '$dep_pkg' is not installed -abort"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

proxymon_env="/etc/proxymon/proxymon.env"

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

# Monthly is the floor, not a recommendation: it exists so an untouched
# system still has a recent copy. Run it by hand before any change.
# CRON_D
# Add or replace one line in the project's single cron.d file
cron_d_set() {
    local match="$1" line="$2"
    local cron_file="/etc/cron.d/proxymon"
    local cron_tmp

    cron_tmp=$(mktemp) || return 1
    if [ -f "$cron_file" ]; then
        grep -vF "$match" "$cron_file" > "$cron_tmp" || {
            [ "$?" -eq 1 ] || { rm -f "$cron_tmp"; return 1; }
        }
    fi
    if [ -n "$line" ]; then
        printf '%s\n' "$line" >> "$cron_tmp" || {
            rm -f "$cron_tmp"
            return 1
        }
    fi
    if [ -s "$cron_tmp" ]; then
        if ! install -m 644 -o root -g root "$cron_tmp" "$cron_file"; then
            rm -f "$cron_tmp"
            return 1
        fi
    else
        rm -f "$cron_file"
    fi
    rm -f "$cron_tmp"
}

register_cron() {
    # Deploy self first: the cron entry must point at a path that exists,
    # whether this ran from the repo or from its final location.
    local script_path
    script_path="$(readlink -f "$0")"
    if [ "$script_path" != "$installed_path" ]; then
        if ! mkdir -p "$(dirname "$installed_path")"; then
            log "ERROR: cannot create $(dirname "$installed_path") -abort"
            exit 1
        fi
        install -m 755 -o root -g root "$script_path" "$installed_path"
        log "INFO: deployed to $installed_path"
    fi

    cron_d_set "$installed_path" "@monthly root $installed_path"
    log "INFO: pmbk backup cron registered, runs @monthly"
}

deregister_cron() {
    cron_d_set "$installed_path" ""
    log "INFO: pmbk backup cron removed, archives kept"
}

# ------------------------------------------------------------------------------
# ENV
# ------------------------------------------------------------------------------

# PERMS
# Owner and mode of every .env this script reads
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
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/proxymonenv.sh"
# LOAD
load_proxymon_env "$proxymon_env" || { log "ERROR: cannot load proxymon.env -abort"; exit 1; }

# KEY CHECK
key_errors=()
for env_key in BACKUP_DIR CONFIG_DIR WEB_ROOT REPORT_PATH REPORT_STATS_PATH SQUIDMON_CONFIG TOOL_REPORT_DIR LLM_ENV_FILE ACL_MAC_PATH ACL_SQUID_PATH ACL_BANDATA_PATH ALLOW_LIST BLOCK_LIST_DAY BLOCK_LIST_WEEK BLOCK_LIST_MONTH; do
    if ! grep -q "^${env_key}=" "$proxymon_env"; then
        key_errors+=("$env_key missing line")
    elif [[ -z "${!env_key:-}" ]]; then
        key_errors+=("$env_key not set")
    elif [ "$env_key" = BACKUP_DIR ] && [[ "$BACKUP_DIR" != /* ]]; then
        key_errors+=("$env_key invalid absolute path")
    fi
done
if (( ${#key_errors[@]} > 0 )); then
    for key_error in "${key_errors[@]}"; do
        log "WARNING: $key_error -alert"
    done
    log "ERROR: ${#key_errors[@]} key(s) invalid in $(basename "$proxymon_env") -abort"
    exit 1
fi
unset key_errors key_error env_key

backup_dir="$BACKUP_DIR"
backup_zip="${backup_dir}/pmbk_$(date +%Y%m%d_%H%M%S).zip"
installed_path="$CONFIG_DIR/tools/$(basename "$0")"

# Start
case "${1:-}" in
    --install)
        log "pmbk start..."
        register_cron
        log "pmbk done at: $(date '+%Y-%m-%d %H:%M:%S')"
        exit 0
        ;;
    --uninstall)
        log "pmbk start..."
        deregister_cron
        log "pmbk done at: $(date '+%Y-%m-%d %H:%M:%S')"
        exit 0
        ;;
    "")
        log "pmbk start..."
        ;;
    *)
        log "ERROR: '$1' invalid; --install/--uninstall or none -abort"
        exit 1
        ;;
esac

# ------------------------------------------------------------------------------
# BACKUP
# ------------------------------------------------------------------------------

if ! mkdir -p "$backup_dir"; then
    log "ERROR: cannot create $backup_dir -abort"
    exit 1
fi

# Project files and relevant system configuration are listed explicitly
# so the project state can be restored.
php_version=""
if command -v php >/dev/null 2>&1; then
    php_version=$(php -r \
        'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
fi

backup_list=()
for backup_item in \
    /etc/proxymon/proxymon.env \
    "$WEB_ROOT" \
    "$CONFIG_DIR" \
    "$REPORT_PATH" \
    "$REPORT_STATS_PATH" \
    "$SQUIDMON_CONFIG" \
    "$TOOL_REPORT_DIR" \
    "$LLM_ENV_FILE" \
    "$ACL_MAC_PATH" \
    "$ACL_SQUID_PATH" \
    "$ACL_BANDATA_PATH" \
    "$ALLOW_LIST" \
    "$BLOCK_LIST_DAY" \
    "$BLOCK_LIST_WEEK" \
    "$BLOCK_LIST_MONTH" \
    /etc/apache2/sites-available/proxymon.conf \
    /etc/apache2/sites-available/warning.conf \
    /etc/apache2/ports.conf \
    /etc/apache2/apache2.conf \
    /etc/apache2/conf-available/security.conf \
    /etc/apache2/mods-available/mpm_prefork.conf \
    /etc/logrotate.d/bandata \
    /etc/logrotate.d/proxymon \
    /etc/cron.d/proxymon \
    ${php_version:+"/etc/php/$php_version/apache2/php.ini"}
do
    if [ -e "$backup_item" ]; then
        backup_list+=("$backup_item")
    else
        log "INFO: $backup_item not present -skip"
    fi
done

if (( ${#backup_list[@]} == 0 )); then
    log "ERROR: cannot find Proxymon installation paths -abort"
    exit 1
fi

# Build under a .part name so zip always starts from nothing, and so a failed
# run can only ever delete its own work. The archive takes its final name once
# zip has succeeded, which also keeps the retention glob from seeing a partial.
backup_part="${backup_zip}.part"
rm -f "$backup_part"
if (umask 077; zip -r -q -y "$backup_part" "${backup_list[@]}"); then
    chmod 600 "$backup_part"
    if ! mv -f "$backup_part" "$backup_zip"; then
        rm -f "$backup_part"
        log "ERROR: rename $(basename "$backup_zip"). check chmod -abort"
        exit 1
    fi
    log "INFO: backup written to $(basename "$backup_zip")"

    # keep only the last 3
    old_backups=("$backup_dir"/pmbk_*.zip)
    if (( ${#old_backups[@]} > 3 )); then
        printf '%s\n' "${old_backups[@]}" | sort | head -n -3 | xargs -r rm -f
    fi
else
    rm -f "$backup_part"
    log "ERROR: $(basename "$backup_zip"). check space/chmod -abort"
    exit 1
fi

# ------------------------------------------------------------------------------
# END
# ------------------------------------------------------------------------------

log "pmbk done at: $(date '+%Y-%m-%d %H:%M:%S')"
