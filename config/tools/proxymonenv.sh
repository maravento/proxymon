#!/bin/bash
# maravento.com
#
################################################################################
#
# proxymonenv -- shared Bash configuration reader
# FILE: tools/proxymonenv.sh
#
# USAGE:
# Loaded by callers with source. Not a standalone command or cron job.
#
################################################################################

load_proxymon_env() {
    local env_file="${1:-/etc/proxymon/proxymon.env}"
    local env_line env_key env_value env_ref
    [ -f "$env_file" ] || return 1
    [ "$(stat -c %u "$env_file")" = 0 ] || return 1
    local env_mode
    env_mode=$(stat -c %a "$env_file")
    (( (8#$env_mode & 022) == 0 )) || return 1
    while IFS= read -r env_line || [ -n "$env_line" ]; do
        [[ "$env_line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$env_line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || return 1
        env_key=${BASH_REMATCH[1]}
        env_value=${BASH_REMATCH[2]}
        if [[ "$env_value" == [[:space:]\"\']* ]] \
           || [[ "$env_value" == *[[:space:]\"\'] ]]; then
            return 1
        fi
        case "$env_key" in
            WEB_ROOT|CONFIG_DIR|BACKUP_DIR|TOOL_REPORT_DIR|SQUIDMON_CONFIG|LLM_ENV_FILE|REPORT_STATS_PATH|PANEL_PORT|WARNING_PORT|LAN|SERVER_IP|RANGE|REPORT_IP_GLOB|SQUIDREPORTS_DIR|REPORT_PATH|REALNAME_CFG|SKIPUSERS_CFG|ACL_PATH|ACL_MAC_PATH|ACL_SQUID_PATH|ACL_BANDATA_PATH|ALLOW_LIST|BLOCK_LIST_DAY|BLOCK_LIST_WEEK|BLOCK_LIST_MONTH|SQUID_LOG_DIR|SQUID_LOG_FILE|WARNING_HTML|CACHE_PATH|SQUID_MGR_HOST|SQUID_MGR_PORT|SQUID_INTERCEPT_PORT|MAX_BANDWIDTH_DAY|MAX_BANDWIDTH_WEEK|MAX_BANDWIDTH_MONTH|BANDATA_HOTSPOT|HOTSPOT_PATH|UPDATE_REALNAME|SQUIDTOOL_MIN_HITS|SQUIDTOOL_ALERT_THRESHOLD)
                while [[ "$env_value" =~ \$\{?([A-Z][A-Z0-9_]*)\}? ]]; do
                    env_ref=${BASH_REMATCH[1]}
                    [ -n "${!env_ref:-}" ] || return 1
                    env_value=${env_value//${BASH_REMATCH[0]}/${!env_ref}}
                done
                [[ "$env_value" != *'$'* && "$env_value" != *'`'* ]] || return 1
                printf -v "$env_key" '%s' "$env_value"
                ;;
        esac
    done < "$env_file"
}
