#!/bin/bash
# maravento.com
#
################################################################################
#
# domain-suffixes-update -- manual Public Suffix List update for proxymon
#
# USAGE:
# sudo bash domain-suffixes-update.sh    Update domain-suffixes.txt
#
# LOG: /var/log/proxymon.log
#
################################################################################

set -uo pipefail

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [ "$(id -u)" != "0" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: This script must be run as root -abort" >&2
    exit 1
fi

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

script_lock="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$script_lock") || {
    log "ERROR: cannot open $(basename "$script_lock") -abort"
    exit 1
}
exec 200>"$script_lock"
if ! flock -n 200; then
    log "ERROR: suffix update is already running -abort"
    exit 1
fi

for dep_pkg in curl python3 coreutils util-linux; do
    if [ "$(dpkg-query -W -f='${db:Status-Status}' "$dep_pkg" 2>/dev/null)" != installed ]; then
        log "ERROR: dependency '$dep_pkg' is not installed -abort"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
proxymon_env="/etc/proxymon/proxymon.env"
env_reader="$script_dir/proxymonenv.sh"
if [ ! -f "$env_reader" ]; then
    env_reader="$script_dir/../../config/tools/proxymonenv.sh"
fi
temporary_dir=""

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

cleanup() {
    if [ -n "$temporary_dir" ]; then
        rm -rf -- "$temporary_dir"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ------------------------------------------------------------------------------
# ENV
# ------------------------------------------------------------------------------

# PERMS
env_specs=("$proxymon_env root:www-data 640")
for env_spec in "${env_specs[@]}"; do
    read -r env_path env_owner_want env_perms_want <<< "$env_spec"
    if [ ! -f "$env_path" ]; then
        log "ERROR: $(basename "$env_path") not found -abort"
        exit 1
    fi
    env_owner=$(stat -c '%U:%G' "$env_path" 2>/dev/null)
    env_perms=$(stat -c '%a' "$env_path" 2>/dev/null)
    if [[ "$env_owner" != "$env_owner_want" ]] || [[ "$env_perms" != "$env_perms_want" ]]; then
        if chown "$env_owner_want" "$env_path" 2>/dev/null \
            && chmod "$env_perms_want" "$env_path" 2>/dev/null; then
            log "INFO: $(basename "$env_path") perms fixed -fixed"
        else
            log "ERROR: cannot fix $(basename "$env_path") perms -abort"
            exit 1
        fi
    fi
done
unset env_specs env_spec env_path env_owner_want env_perms_want env_owner env_perms

# LOAD_CONF
if [ ! -f "$env_reader" ]; then
    log "ERROR: proxymonenv.sh not found -abort"
    exit 1
fi
source "$env_reader"

# LOAD
load_proxymon_env "$proxymon_env" || {
    log "ERROR: cannot load proxymon.env -abort"
    exit 1
}

# KEY CHECK
key_errors=()
for env_key in SQUIDREPORTS_DIR; do
    if ! grep -q "^${env_key}=" "$proxymon_env"; then
        key_errors+=("$env_key missing line")
    elif [[ -z "${!env_key:-}" ]]; then
        key_errors+=("$env_key not set")
    elif [[ "${!env_key}" != /* ]]; then
        key_errors+=("$env_key invalid absolute path")
    fi
done
if (( ${#key_errors[@]} > 0 )); then
    for key_error in "${key_errors[@]}"; do
        log "WARNING: $key_error -alert"
    done
    log "ERROR: ${#key_errors[@]} key(s) invalid in proxymon.env -abort"
    exit 1
fi
unset key_errors key_error env_key

# ------------------------------------------------------------------------------
# UPDATE
# ------------------------------------------------------------------------------

log "domain-suffixes-update start..."

if [ "$#" -ne 0 ]; then
    log "ERROR: no arguments are accepted -abort"
    exit 1
fi
if [ ! -d "$SQUIDREPORTS_DIR" ]; then
    log "ERROR: SQUIDREPORTS_DIR does not exist -abort"
    exit 1
fi
if ! directory_specs=$(stat -Lc '%u %a' "$SQUIDREPORTS_DIR"); then
    log "ERROR: cannot check SQUIDREPORTS_DIR permissions -abort"
    exit 1
fi
read -r directory_owner directory_mode <<< "$directory_specs"
if [ "$directory_owner" != 0 ]; then
    log "ERROR: SQUIDREPORTS_DIR is not root-owned -abort"
    exit 1
elif (( (8#$directory_mode & 022) != 0 )); then
    log "ERROR: SQUIDREPORTS_DIR allows non-root writes -abort"
    exit 1
fi
suffix_file="$SQUIDREPORTS_DIR/domain-suffixes.txt"
if [ -L "$suffix_file" ] || { [ -e "$suffix_file" ] && [ ! -f "$suffix_file" ]; }; then
    log "ERROR: domain-suffixes.txt is not a regular file -abort"
    exit 1
fi
temporary_dir=$(mktemp -d "$SQUIDREPORTS_DIR/domain-suffixes-update.XXXXXX") || {
    log "ERROR: cannot create suffix update directory -abort"
    exit 1
}
download_file="$temporary_dir/public_suffix_list.dat"
candidate_file="$temporary_dir/domain-suffixes.txt"

log "INFO: downloading Public Suffix List"
if ! curl --fail --silent --show-error --location --proto '=https' \
    --proto-redir '=https' --connect-timeout 15 --max-time 90 --retry 2 \
    https://publicsuffix.org/list/public_suffix_list.dat --output "$download_file"; then
    log "ERROR: Public Suffix List download failed -abort"
    exit 1
fi

if ! rule_count=$(python3 - "$download_file" "$candidate_file" 2>"$temporary_dir/validation.error" <<'PY'
import re
import sys
from pathlib import Path

try:
    text = Path(sys.argv[1]).read_text(encoding="utf-8")
    markers = [
        "// ===BEGIN ICANN DOMAINS===",
        "// ===END ICANN DOMAINS===",
        "// ===BEGIN PRIVATE DOMAINS===",
        "// ===END PRIVATE DOMAINS===",
    ]
    positions = [text.find(marker) for marker in markers]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        sys.exit("PSL download lacks complete section markers")
    version = re.search(r"^// VERSION: ([0-9_-]+UTC)$", text, re.MULTILINE)
    commit = re.search(r"^// COMMIT: ([0-9a-f]{40})$", text, re.MULTILINE)
    if not version or not commit:
        sys.exit("PSL download lacks valid version metadata")
    rules = set()
    section_rules = {"ICANN": 0, "PRIVATE": 0}
    section = None
    for number, line in enumerate(text.splitlines(), 1):
        if line == markers[0]:
            section = "ICANN"
        elif line == markers[2]:
            section = "PRIVATE"
        elif line in (markers[1], markers[3]):
            section = None
        if not line.strip() or line.startswith("//"):
            continue
        if section is None:
            sys.exit("PSL rule appears outside its section")
        rule = line.split()[0]
        prefix = "!" if rule.startswith("!") else "*." if rule.startswith("*.") else ""
        domain = rule[len(prefix):]
        try:
            domain = domain.encode("idna").decode("ascii").lower()
        except UnicodeError:
            sys.exit(f"PSL rule has invalid IDN at line {number}")
        labels = domain.split(".")
        if len(domain) > 253 or any(
            not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
            for label in labels
        ):
            sys.exit(f"PSL rule is invalid at line {number}")
        rules.add(prefix + domain)
        section_rules[section] += 1
    if not all(section_rules.values()):
        sys.exit("PSL download contains an empty section")
    header = [
        "# Public Suffix List for Squidreports domain grouping.",
        "# Source: https://publicsuffix.org/list/public_suffix_list.dat",
        "# VERSION: " + version.group(1),
        "# COMMIT: " + commit.group(1),
        "# This Source Code Form is subject to the terms of the Mozilla Public",
        "# License, v. 2.0. If a copy of the MPL was not distributed with this",
        "# file, You can obtain one at https://mozilla.org/MPL/2.0/.",
        "# ICANN and PRIVATE rules; IDNs stored as ASCII/Punycode.",
        "# Wildcard (*) and exception (!) rules are preserved.",
    ]
    Path(sys.argv[2]).write_text("\n".join(header + sorted(rules)) + "\n", encoding="ascii")
    print(len(rules))
except (OSError, UnicodeError) as error:
    sys.exit(f"PSL input/output error: {type(error).__name__}")
PY
); then
    validation_error=$(head -n 1 "$temporary_dir/validation.error")
    log "ERROR: ${validation_error:-cannot validate PSL download} -abort"
    exit 1
fi

if [ -f "$suffix_file" ]; then
    cmp -s "$suffix_file" "$candidate_file"
    compare_status=$?
    if [ "$compare_status" -eq 0 ]; then
        log "INFO: domain-suffixes.txt is current -skip"
        log "domain-suffixes-update done at: $(date '+%Y-%m-%d %H:%M:%S')"
        exit 0
    elif [ "$compare_status" -gt 1 ]; then
        log "ERROR: cannot compare domain-suffixes.txt -abort"
        exit 1
    fi
    if ! chmod --reference="$suffix_file" "$candidate_file" \
        || ! chown --reference="$suffix_file" "$candidate_file"; then
        log "ERROR: cannot preserve suffix file permissions -abort"
        exit 1
    fi
else
    if ! chmod 644 "$candidate_file" || ! chown root:root "$candidate_file"; then
        log "ERROR: cannot set suffix file permissions -abort"
        exit 1
    fi
fi
if ! mv -fT -- "$candidate_file" "$suffix_file"; then
    log "ERROR: cannot publish domain-suffixes.txt -abort"
    exit 1
fi
log "INFO: public suffix rules: $rule_count"
log "INFO: updated domain-suffixes.txt"

# ------------------------------------------------------------------------------
# END
# ------------------------------------------------------------------------------

log "domain-suffixes-update done at: $(date '+%Y-%m-%d %H:%M:%S')"
