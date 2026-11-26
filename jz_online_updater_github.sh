#!/bin/bash
# JZZN Sniff GitHub transactional online updater.
# Stable compatibility entry:
#   curl -fsSL https://raw.githubusercontent.com/JzCharizard/jz_online_update/main/jz_online_updater_github.sh | sudo bash

set -Eeuo pipefail

RELEASE_TAG="v1.2.15"
PRODUCT_VERSION="v1.2.15"
PACKAGE_NAME="jzzn-v1.2.15-update-linux-x86_64.7z"
SHA_NAME="$PACKAGE_NAME.sha256"
SIG_NAME="$PACKAGE_NAME.sig"
RELEASE_BASE="https://github.com/JzCharizard/jz_online_update/releases/download/$RELEASE_TAG"
DOWNLOAD_HOST="github.com"
PACKAGE_SHA256="ec15884be7aedebded1a167ccd3538fd292824cd84c58fb18863ec44d5eedb80"
SIGNING_KEY_FINGERPRINT="eda973d767d633f54fc31d892bdd7dacc8fdb64de160f0e349e953f93fb7376e"
REQUIRED_PACKAGES="ca-certificates curl wget bash coreutils tar openssl p7zip-full postgresql-client iproute2 iputils-ping rsyslog logrotate util-linux procps"

KEEP=0
WORK_DIR=""
PASSWORD=""
SEVENZIP=""
TXID="$(date '+%Y%m%d-%H%M%S')-$$"
STATE_DIR="/var/lib/jzzn-updater/state"
STATE_FILE="$STATE_DIR/$TXID.json"
LOG_DIR="/var/log/jzzn-updater"
TX_LOG="$LOG_DIR/$TXID.log"
INSTALL_STARTED=0
FINAL_STATUS="initializing"
FAIL_REASON=""
SIGNATURE_STATUS="false"
APT_GET_IP_OPTIONS=()

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/[[:cntrl:]]/ /g'
}

write_state() {
    local tmp="$STATE_FILE.tmp.$$"
    mkdir -p "$STATE_DIR"
    cat > "$tmp" <<EOF
{
  "transaction_id": "$(json_escape "$TXID")",
  "operation": "github-online-update",
  "target_version": "$PRODUCT_VERSION",
  "status": "$(json_escape "$FINAL_STATUS")",
  "operator": "$(json_escape "${SUDO_USER:-root}")",
  "source_ip": "$(json_escape "${SSH_CLIENT:-}")",
  "package_name": "$PACKAGE_NAME",
  "package_sha256": "$PACKAGE_SHA256",
  "signature_verified": "$SIGNATURE_STATUS",
  "failure_reason": "$(json_escape "$FAIL_REASON")",
  "updated_at": "$(date -Iseconds)"
}
EOF
    chmod 600 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

fail() {
    local message=$1
    FAIL_REASON=$message
    if [ "$INSTALL_STARTED" -eq 0 ]; then
        FINAL_STATUS="failed_precheck"
        write_state
    fi
    log "ERROR: $message" >&2
    exit 1
}

usage() {
    cat <<'EOF'
JZZN Sniff GitHub online updater

Options:
  --keep, --no-clean   Keep downloads and extracted files after success
  -h, --help           Show this help

Credential lookup order:
  JZZN_UPDATE_ARCHIVE_PASSWORD environment variable
  /root/.config/jzzn/update-archive-password (mode 0600 required)
  Interactive prompt (up to three attempts)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --keep|--no-clean) KEEP=1 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
    shift
done

[ "$(id -u)" = "0" ] || { echo "run this updater as root" >&2; exit 1; }
mkdir -p "$STATE_DIR" "$LOG_DIR" /run/lock
touch "$TX_LOG"
chmod 600 "$TX_LOG"
exec > >(tee -a "$TX_LOG") 2>&1
exec 9>/run/lock/jzzn-updater.lock
flock -n 9 || fail "another install or update transaction is already running"
write_state

cleanup() {
    local rc=$?
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        if [ "$KEEP" -eq 1 ] || [ "$rc" -ne 0 ]; then
            log "temporary directory retained: $WORK_DIR"
        else
            rm -rf -- "$WORK_DIR"
            log "download workspace removed after the packaged install.sh completed"
        fi
    fi
}
trap cleanup EXIT

# BEGIN embedded apt-network-guard.sh
#!/bin/bash
# Canonical copy: embedded in curl entry scripts; shipped with install payloads.
# Do not mask live units: a masked restart can stop a unit and fail to start it.

snapshot_network_before_apt() {
    local snapshot="/var/lib/jzzn-updater/network-before-apt/$TXID" path target
    if [ ! -f "$snapshot/complete" ]; then
        install -d -m 700 "$snapshot" || return 1
        for path in /etc/netplan /lib/netplan /etc/systemd/network \
            /etc/NetworkManager/system-connections /run/systemd/network /run/netplan; do
            [ -e "$path" ] || continue
            target="$snapshot${path%/*}"
            mkdir -p "$target" || return 1
            cp -a "$path" "$target/" || return 1
        done
        if command -v ip >/dev/null 2>&1; then
            ip -details addr show > "$snapshot/addresses.txt" || return 1
            ip -4 route show table all > "$snapshot/routes-v4.txt" || return 1
            ip -6 route show table all > "$snapshot/routes-v6.txt" || return 1
        fi
        touch "$snapshot/complete" || return 1
        log "Network configuration and live addresses backed up before APT: $snapshot"
    fi
    # Do not let package generators discard the only, volatile network config.
    for path in /etc/netplan /lib/netplan; do
        [ -d "$path" ] || continue
        [ -z "$(find "$path" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -print -quit)" ] || return 0
    done
    for path in /etc/systemd/network; do
        [ -d "$path" ] || continue
        [ -z "$(find "$path" -maxdepth 1 -type f -name '*.network' -print -quit)" ] || return 0
    done
    path=/etc/NetworkManager/system-connections
    if [ -d "$path" ] && [ -n "$(find "$path" -maxdepth 1 -type f -name '*.nmconnection' -print -quit)" ]; then
        return 0
    fi
    if declare -F generate_transition_netplan >/dev/null; then
        generate_transition_netplan "$snapshot"
        return $?
    fi
    log "BLOCK: no persistent Netplan/networkd/NetworkManager configuration found; restore a valid network configuration before retrying. Snapshot: $snapshot" >&2
    return 1
}

run_package_command() (
    # A subshell owns the traps; an APT error must not bypass guard restoration.
    set -Eeuo pipefail
    local guard_dir policy=/usr/sbin/policy-rc.d unit file state rc=0
    local policy_installed=0 reload_needed=0 restore_failed=0
    local -a dropins=() active_units=() original_invocations=()
    local -a units=(
        ssh.service ssh.socket sshd.service sshd.socket
        systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service
        NetworkManager.service network-manager.service networking.service networkd-dispatcher.service
        systemd-resolved.service systemd-udevd.service systemd-logind.service dbus.service dbus-broker.service
    )
    snapshot_network_before_apt || return 1
    guard_dir=$(mktemp -d /var/lib/jzzn-updater/apt-guard.XXXXXX) || return 1
    chmod 700 "$guard_dir" || return 1

    restore_package_guard() {
        local result=$? dropin
        trap - EXIT HUP INT TERM
        if [ "$policy_installed" -eq 1 ]; then
            if cmp -s "$policy" "$guard_dir/policy"; then
                if [ -e "$guard_dir/original-policy" ] || [ -L "$guard_dir/original-policy" ]; then
                    cp -a "$guard_dir/original-policy" "$policy.jzzn-${guard_dir##*/}" \
                        && mv -Tf "$policy.jzzn-${guard_dir##*/}" "$policy" || restore_failed=1
                else
                    rm -f -- "$policy" || restore_failed=1
                fi
            else
                echo "ERROR: policy-rc.d changed during APT; original retained at $guard_dir" >&2
                restore_failed=1
            fi
        fi
        for dropin in "${dropins[@]}"; do
            rm -f -- "$dropin" || restore_failed=1
            rmdir -- "${dropin%/*}" 2>/dev/null || true
        done
        if [ "$reload_needed" -eq 1 ]; then
            systemctl daemon-reload || restore_failed=1
        fi
        if [ "$restore_failed" -eq 0 ]; then
            rm -f -- "$guard_dir/original-policy" "$guard_dir/delegate" "$guard_dir/policy" "$guard_dir/restore-policy"
            rmdir -- "$guard_dir" || restore_failed=1
        fi
        if [ "$restore_failed" -ne 0 ]; then
            echo "ERROR: APT guard restoration needs manual attention: $guard_dir" >&2
            [ "$result" -ne 0 ] || result=1
        fi
        exit "$result"
    }
    trap restore_package_guard EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if [ -e "$policy" ] || [ -L "$policy" ]; then
        [ -x "$policy" ] || { echo "ERROR: existing policy-rc.d is not executable" >&2; return 1; }
        if grep -q '^# JZZN temporary APT guard:' "$policy"; then
            echo "ERROR: unfinished APT guard detected; restore its saved original policy before retrying" >&2
            return 1
        fi
        cp -a "$policy" "$guard_dir/original-policy" || return 1
        cp -pL "$policy" "$guard_dir/delegate" || return 1
    fi
    cat > "$guard_dir/policy" <<EOF || return 1
#!/bin/sh
# JZZN temporary APT guard: $guard_dir
for arg in "\$@"; do
    case "\${arg##*/}" in
        ssh|sshd|ssh.*|sshd.*|ssh@*|sshd@*|systemd-networkd*|NetworkManager*|network-manager*|networking*|networkd-dispatcher*|systemd-resolved*|systemd-udevd*|systemd-logind*|dbus|dbus.*|dbus-broker*)
            echo "JZZN: package service action deferred to preserve networking/SSH: \$*" >&2
            exit 101 ;;
    esac
done
if [ -x '$guard_dir/delegate' ]; then exec '$guard_dir/delegate' "\$@"; fi
exit 0
EOF
    [ -s "$guard_dir/policy" ] || return 1
    chmod 755 "$guard_dir/policy" || return 1
    # Mark ownership before the atomic replacement so signal cleanup is safe.
    policy_installed=1
    cp "$guard_dir/policy" "$policy.jzzn-${guard_dir##*/}" || return 1
    mv -Tf "$policy.jzzn-${guard_dir##*/}" "$policy" || return 1
    for unit in "${units[@]}"; do
        if [ "$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)" = "not-found" ]; then
            continue
        fi
        state=$(systemctl show -p ActiveState --value "$unit") || return 1
        if [ "$state" = "active" ]; then
            active_units+=("$unit")
            original_invocations+=("$(systemctl show -p InvocationID --value "$unit")")
        fi
        file="/run/systemd/system/$unit.d/90-jzzn-${guard_dir##*/}.conf"
        mkdir -p "${file%/*}" || return 1
        dropins+=("$file")
        printf '[Unit]\nRefuseManualStop=yes\n' > "$file" || return 1
    done
    reload_needed=1
    systemctl daemon-reload || return 1
    for unit in "${units[@]}"; do
        if [ "$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)" = "not-found" ]; then continue; fi
        [ "$(systemctl show -p RefuseManualStop --value "$unit")" = "yes" ] \
            || { echo "ERROR: cannot protect $unit from package restarts" >&2; return 1; }
    done
    log "APT guard active: automatic service restarts suspended; networking and SSH protected"
    # SUSPEND disables Ubuntu's APT hook even when it specifies -m u.
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1 "$@" || rc=$?
    for file in "${!active_units[@]}"; do
        unit=${active_units[$file]}
        if [ "$(systemctl show -p ActiveState --value "$unit")" != "active" ] \
            || [ "$(systemctl show -p InvocationID --value "$unit")" != "${original_invocations[$file]}" ]; then
            echo "ERROR: protected service changed during APT: $unit" >&2
            rc=1
        fi
    done
    return "$rc"
)

#!/bin/bash
# Ordinary fresh-install only. Static snapshot for the dependency-install phase;
# the existing product NIC selection later replaces this temporary YAML.
generate_transition_netplan() (
    set -Eeuo pipefail
    local snapshot=$1 staging target=/etc/netplan/00-jzzn-install-transition.yaml
    command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 is required to snapshot an unconfigured network" >&2; return 1; }
    staging=$(mktemp -d /tmp/jzzn-netplan-transition.XXXXXX) || return 1
    trap 'rm -rf -- "$staging"' EXIT
    mkdir -p "$staging/etc/netplan" || return 1
    python3 - "$staging/etc/netplan/transition.yaml" "$snapshot" <<'PY' || return 1
import ipaddress
import json
import pathlib
import subprocess
import sys

def command(args):
    return subprocess.check_output(args, text=True)

def ip(*args):
    return json.loads(command(['ip', '-j', *args]))

def dns_for(name):
    try:
        value = command(['resolvectl', 'dns', name]).split(':', 1)[1].split()
        return [v for v in value if valid_ip(v)]
    except (OSError, subprocess.CalledProcessError, IndexError):
        return []

def valid_ip(value):
    try:
        ipaddress.ip_address(value.split('%')[0]); return True
    except ValueError:
        return False

try:
    links = ip('-details', 'link', 'show')
    addresses = ip('address', 'show')
    routes = ip('-4', 'route', 'show', 'table', 'all') + ip('-6', 'route', 'show', 'table', 'all')
    rules = ip('-4', 'rule', 'show') + ip('-6', 'rule', 'show')
    if any(r.get('table') not in ('local', 'main', 'default', 254, 255, 253)
           or r.get('src', 'all') != 'all' or r.get('dst', 'all') != 'all'
           or any(k in r for k in ('fwmark', 'fwmask', 'iif', 'oif', 'uidrange')) for r in rules):
        raise ValueError('custom policy routing requires manual network configuration')
    result = {}
    for link in links:
        name = link['ifname']
        if name == 'lo':
            continue
        if link.get('link_type') != 'ether' or link.get('master') or link.get('linkinfo', {}).get('info_kind'):
            raise ValueError('bridge/bond/VLAN/tunnel topology requires manual configuration: ' + name)
        mac = link.get('address', '')
        if not mac or len(mac.split(':')) != 6:
            raise ValueError('missing Ethernet MAC: ' + name)
        config = {'match': {'macaddress': mac}, 'dhcp4': False, 'dhcp6': False,
                  'accept-ra': False, 'optional': True, 'mtu': link['mtu']}
        current = next(a for a in addresses if a['ifname'] == name)
        addrs = sorted({str(ipaddress.ip_interface(str(a['local']) + '/' + str(a['prefixlen'])))
                        for a in current.get('addr_info', []) if a.get('scope') == 'global'})
        if addrs:
            config['addresses'] = addrs
        servers = dns_for(name)
        if servers:
            config['nameservers'] = {'addresses': servers}
            try:
                domains = command(['resolvectl', 'domain', name]).split(':', 1)[1].split()
                if domains and domains != ['n/a']:
                    config['nameservers']['search'] = domains
            except (OSError, subprocess.CalledProcessError, IndexError):
                pass
        result[name] = config
    for route in routes:
        table = route.get('table', 'main')
        if table in ('local', 255) or route.get('type', 'unicast') != 'unicast':
            continue
        if table not in ('main', 254):
            raise ValueError('custom route table requires manual configuration')
        if route.get('protocol') == 'kernel':
            continue  # connected routes follow the exact address prefixes
        name = route.get('dev')
        if name not in result or route.get('nexthops') or route.get('nhid'):
            raise ValueError('unsupported route/device: ' + json.dumps(route))
        item = {'to': route['dst']}
        if route.get('gateway'):
            item['via'] = route['gateway']
        else:
            item['scope'] = route.get('scope', 'link')
        if 'metric' in route:
            item['metric'] = route['metric']
        if 'onlink' in route.get('flags', []):
            item['on-link'] = True
        if route.get('prefsrc'):
            item['from'] = route['prefsrc']
        bucket = result[name].setdefault('routes', [])
        if item not in bucket:
            bucket.append(item)
    if not any(c.get('addresses') for c in result.values()):
        raise ValueError('no current global IP addresses to preserve')
    if not any(c.get('nameservers') for c in result.values()):
        servers = []
        for file in ['/run/systemd/resolve/resolv.conf', '/etc/resolv.conf']:
            path = pathlib.Path(file)
            if not path.exists():
                continue
            for line in path.read_text().splitlines():
                parts = line.split()
                if len(parts) >= 2 and parts[0] == 'nameserver' and valid_ip(parts[1]) and parts[1] != '127.0.0.53':
                    if parts[1] not in servers:
                        servers.append(parts[1])
            if servers:
                break
        if not servers:
            raise ValueError('cannot identify current upstream DNS servers')
        name = next((n for n, c in result.items() if any(r['to'] == 'default' for r in c.get('routes', []))), None)
        if name is None:
            name = next(n for n, c in result.items() if c.get('addresses'))
        result[name]['nameservers'] = {'addresses': servers}
    data = {'network': {'version': 2, 'renderer': 'networkd', 'ethernets': result}}
    # JSON is valid YAML and avoids quoting mistakes without PyYAML dependencies.
    pathlib.Path(sys.argv[1]).write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
    pathlib.Path(sys.argv[2], 'transition-network-source.json').write_text(
        json.dumps({'links': links, 'addresses': addresses, 'routes': routes, 'rules': rules}, indent=2) + '\n', encoding='utf-8')
except (ValueError, KeyError, StopIteration, OSError, subprocess.CalledProcessError) as error:
    print('ERROR: cannot safely create transition Netplan: ' + str(error), file=sys.stderr)
    sys.exit(1)
PY
    # Validate in a separate root only: never generate/apply live network state.
    if command -v netplan >/dev/null 2>&1; then
        netplan generate --root-dir "$staging" || return 1
    fi
    mkdir -p /etc/netplan || return 1
    [ ! -e "$target" ] && [ ! -L "$target" ] || { log "ERROR: transition file unexpectedly exists" >&2; return 1; }
    install -m 600 "$staging/etc/netplan/transition.yaml" "$target.pending" || return 1
    mv -Tf "$target.pending" "$target" || return 1
    cp -a "$target" "$snapshot/transition-netplan.yaml" || return 1
    log "Transition Netplan created from current IP/prefix/routes/DNS: $target (no rename, apply or service restart)"
)
# END embedded apt-network-guard.sh

check_platform() {
    [ -r /etc/os-release ] || fail "cannot identify the operating system"
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = "ubuntu" ] || fail "Ubuntu Server is required; found ${PRETTY_NAME:-unknown}"
    [ "$(uname -m)" = "x86_64" ] || fail "x86_64 is required; found $(uname -m)"
    log "platform check passed: ${PRETTY_NAME:-Ubuntu} x86_64"
}

find_7z() {
    local candidate
    for candidate in 7z 7za 7zr; do
        if command -v "$candidate" >/dev/null 2>&1; then
            SEVENZIP=$candidate
            return 0
        fi
    done
    return 1
}

configure_apt_ip_family() {
    APT_GET_IP_OPTIONS=()
    if ! command -v ip >/dev/null 2>&1 \
       || ! ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 ' \
       || ! ip -6 route show default 2>/dev/null | grep -q '^default'; then
        APT_GET_IP_OPTIONS=(-o Acquire::ForceIPv4=true)
        log "no usable global IPv6 address and default route were detected; APT will automatically use IPv4"
    else
        log "usable IPv6 configuration detected; APT will keep the system IP-family preference"
    fi
}

install_runtime_dependencies() {
    local package missing=""
    command -v apt-get >/dev/null 2>&1 || fail "apt-get is unavailable"
    command -v dpkg-query >/dev/null 2>&1 || fail "dpkg-query is unavailable"
    configure_apt_ip_family
    for package in $REQUIRED_PACKAGES; do
        dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q '^install ok installed$' \
            || missing="$missing $package"
    done
    if [ -n "$missing" ]; then
        log "installing missing minimum runtime dependencies:${missing}"
        run_package_command apt-get "${APT_GET_IP_OPTIONS[@]}" update || fail "apt-get update failed"
        # shellcheck disable=SC2086
        run_package_command apt-get "${APT_GET_IP_OPTIONS[@]}" install -y $missing \
            || fail "runtime dependency installation failed"
    fi
    if ! command -v ntpdate >/dev/null 2>&1; then
        log "ntpdate not detected; installing ntpdate"
        [ -n "$missing" ] || run_package_command apt-get "${APT_GET_IP_OPTIONS[@]}" update || fail "apt-get update failed"
        run_package_command apt-get "${APT_GET_IP_OPTIONS[@]}" install -y ntpdate \
            || run_package_command apt-get "${APT_GET_IP_OPTIONS[@]}" install -y ntpsec-ntpdate \
            || fail "failed to install ntpdate"
    fi
    find_7z || fail "7z/7za/7zr was not found"
    for command_name in sha256sum openssl curl tar flock; do
        command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: $command_name"
    done
    log "minimum runtime dependency check passed"
}

wait_for_download_host() {
    local attempt
    command -v getent >/dev/null 2>&1 || return 0
    for attempt in 1 2 3 4 5 6; do
        getent ahosts "$DOWNLOAD_HOST" >/dev/null 2>&1 \
            || getent hosts "$DOWNLOAD_HOST" >/dev/null 2>&1 || {
                log "cannot resolve $DOWNLOAD_HOST; retrying in 5 seconds ($attempt/6)"
                [ "$attempt" -ne 2 ] || { command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches >/dev/null 2>&1 || true; }
                sleep 5
                continue
            }
        return 0
    done
    fail "cannot resolve download host $DOWNLOAD_HOST"
}

download_file() {
    local name url destination attempt
    name=$1
    destination=$2
    url="$RELEASE_BASE/$name"
    for attempt in 1 2 3 4 5; do
        wait_for_download_host
        rm -f "$destination"
        if curl -fL --retry 2 --retry-all-errors --connect-timeout 30 --max-time 3600 \
            --progress-bar -o "$destination" "$url" && [ -s "$destination" ]; then
            return 0
        fi
        log "download failed; retrying in 5 seconds: $name ($attempt/5)"
        sleep 5
    done
    fail "download failed after all retries: $name"
}

write_public_key() {
    cat > "$1" <<'PUBLIC_KEY'
-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAjQWaJAENq5xb06tIw6eC
jDGA72iJZJ9zQMNmd9CxW3Xna885L8MQd8GqG+DjBiIoX4MZEQVW9QnzOs4pDUUy
/I9PRNtylSJk6FUBwaMAJli96/IkZ7P6RnmIanct/yXpAyvL8owMifGPQqlYeBK9
nT2jMycitxVG70jodee+iFqCG+8rMe9ONt+nH1mCXK/V8CcZ4JOkZCxOetCY5taJ
PigUIjrwQM2rU9cfLpSppY09nnUNjw7Uk26yFjzHZeJJUuC05AKQ9OAeyLMCh7du
v084QkJ6HWibXIe3Mf6/8h5yKHP22PtO+rIf6vCxKncNekPKdLftaUGV0JQnPTkt
c6Hjw0dUdaRktwoDAvn3jDTGehLjW0RvGK9/Fr1d+jCUkuL3sjcOhDQfe8/sqhXK
o8LoiQKSeyMR1wSA7gfxBkTEBSiuWWpUEDSI8cLbzmKQJ4lOLRT1tqHx9Gfp7Hsh
MMl8tBUeNxI3Y/buOByPPwUIv2YJjELoPZhi6M2FNlrNAgMBAAE=
-----END PUBLIC KEY-----
PUBLIC_KEY
}

verify_release_files() {
    local archive=$1 sha_file=$2 sig_file=$3 public_key=$4 recorded actual
    recorded=$(awk 'NF {print tolower($1); exit}' "$sha_file")
    [ "$recorded" = "$PACKAGE_SHA256" ] \
        || fail "the SHA256 sidecar does not match the hash pinned by this entry script"
    actual=$(sha256sum "$archive" | awk '{print tolower($1)}')
    [ "$actual" = "$PACKAGE_SHA256" ] \
        || fail "package SHA256 mismatch (expected $PACKAGE_SHA256, got $actual)"
    openssl dgst -sha256 -verify "$public_key" -signature "$sig_file" "$archive" \
        >/dev/null 2>&1 || fail "invalid package signature; update rejected before service shutdown"
    export JZZN_SIGNATURE_VERIFIED=true
    SIGNATURE_STATUS="true"
    log "outer SHA256 and RSA-SHA256 signature verified (public-key fingerprint $SIGNING_KEY_FINGERPRINT)"
}

read_password() {
    local credential_file=/root/.config/jzzn/update-archive-password mode attempt
    if [ -n "${JZZN_UPDATE_ARCHIVE_PASSWORD:-}" ]; then
        PASSWORD=$JZZN_UPDATE_ARCHIVE_PASSWORD
        return 0
    fi
    if [ -r "$credential_file" ]; then
        mode=$(stat -c '%a' "$credential_file" 2>/dev/null || true)
        [ "$mode" = "600" ] || fail "credential file must have mode 0600: $credential_file"
        IFS= read -r PASSWORD < "$credential_file"
        [ -n "$PASSWORD" ] || fail "credential file is empty: $credential_file"
        return 0
    fi
    [ -r /dev/tty ] || fail "cannot read a password interactively; supply protected credentials"
    for attempt in 1 2 3; do
        printf 'Enter update archive password: ' > /dev/tty
        IFS= read -rs PASSWORD < /dev/tty
        printf '\n' > /dev/tty
        [ -n "$PASSWORD" ] && return 0
        log "password cannot be empty ($attempt/3)"
    done
    fail "no password was entered after three attempts"
}

validate_and_extract_archive() {
    local archive=$1 destination=$2 list_file=$3 attempt
    for attempt in 1 2 3; do
        read_password
        if "$SEVENZIP" t -p"$PASSWORD" "$archive" >/dev/null 2>&1 \
           && "$SEVENZIP" l -slt -p"$PASSWORD" "$archive" > "$list_file" 2>/dev/null; then
            if ! awk '
                /^----------$/ {inside=1; next}
                inside && /^Path = / {
                    p=substr($0,8)
                    gsub(/\\/, "/", p)
                    if (p ~ /^\// || p ~ /^[A-Za-z]:/ || p ~ /(^|\/)\.\.(\/|$)/) bad=1
                }
                inside && /^(Symbolic Link|Hard Link) = / {bad=1}
                END {exit bad ? 1 : 0}
            ' "$list_file"; then
                fail "archive contains an absolute path, traversal, backslash, or link entry"
            fi
            rm -rf -- "$destination"
            mkdir -p "$destination"
            "$SEVENZIP" x -p"$PASSWORD" -o"$destination" -y "$archive" >/dev/null \
                || fail "package extraction failed"
            [ -z "$(find "$destination" -type l -print -quit)" ] \
                || fail "extracted content contains a symbolic link"
            log "password, archive integrity, and path-safety checks passed"
            return 0
        fi
        log "incorrect password or damaged archive ($attempt/3)"
        [ -z "${JZZN_UPDATE_ARCHIVE_PASSWORD:-}" ] || break
        PASSWORD=""
    done
    fail "package could not be opened after three attempts"
}

confirm_precheck_warning() {
    [ "${JZZN_ALLOW_PRECHECK_WARN:-0}" = "1" ] && return 0
    [ -r /dev/tty ] || fail "precheck returned warnings and interactive confirmation is unavailable; set JZZN_ALLOW_PRECHECK_WARN=1 to proceed"
    printf 'Upgrade precheck has warnings. Confirm review and continue? [y/N] ' > /dev/tty
    IFS= read -r answer < /dev/tty
    case "$answer" in y|Y|yes|YES) return 0 ;; esac
    fail "operator did not approve the precheck warnings"
}

remove_legacy_installation_if_present() {
    local tmp
    if [ ! -e /etc/init.d/sniff ] && [ ! -L /etc/init.d/sniff ]; then
        log "legacy /etc/init.d/sniff was not found; running the packaged install.sh directly"
        return 0
    fi

    log "legacy /etc/init.d/sniff detected; removing legacy core files and startup paths"
    systemctl stop sniff-watchdog.timer sniff-watchdog.service controller.service sniff.service \
        >/dev/null 2>&1 || true
    if [ -x /root/controller-1.0.0/bin/kill ]; then
        ( cd /root/controller-1.0.0 && ./bin/kill ) >/dev/null 2>&1 || true
    fi
    pkill -TERM -x sniff_daemon 2>/dev/null || true
    pkill -TERM -x sniff 2>/dev/null || true
    sleep 2
    pkill -KILL -x sniff_daemon 2>/dev/null || true
    pkill -KILL -x sniff 2>/dev/null || true

    if [ -f /etc/rc.local ]; then
        tmp=$(mktemp)
        awk '!/controller-1\.0\.0\/bin\/start/ && \
             !/\/etc\/init\.d\/(sniff|sniff_daemon|check_net\.sh)/ && \
             !/sniff_daemon/ && !/tmux.*sniff/' \
            /etc/rc.local > "$tmp"
        cat "$tmp" > /etc/rc.local
        rm -f "$tmp"
    fi

    rm -f /etc/init.d/sniff /etc/init.d/sniff_daemon \
        /etc/init.d/check_net.sh /etc/init.d/file_manifest.json \
        /usr/local/bin/sniff /usr/local/bin/sniff.xdp \
        /usr/local/bin/sniff_daemon /usr/local/bin/sniff_daemon.xdp \
        /usr/local/bin/sniff-watchdog
    rm -f /etc/rc?.d/[SK][0-9][0-9]sniff \
        /etc/rc?.d/[SK][0-9][0-9]sniff_daemon \
        /etc/rc?.d/[SK][0-9][0-9]check_net.sh 2>/dev/null || true
    rm -f /etc/systemd/system/sniff.service \
        /etc/systemd/system/controller.service \
        /etc/systemd/system/sniff-watchdog.service \
        /etc/systemd/system/sniff-watchdog.timer \
        /etc/systemd/system/multi-user.target.wants/sniff.service \
        /etc/systemd/system/multi-user.target.wants/controller.service \
        /etc/systemd/system/timers.target.wants/sniff-watchdog.timer
    systemctl daemon-reload

    [ ! -e /etc/init.d/sniff ] && [ ! -L /etc/init.d/sniff ] \
        || fail "failed to remove legacy core file /etc/init.d/sniff"
    log "legacy core files and startup paths removed; running the packaged install.sh"
}

check_platform
install_runtime_dependencies
WORK_DIR=$(mktemp -d /tmp/jzzn-online-update.XXXXXX) || fail "cannot create a temporary directory"
ARCHIVE="$WORK_DIR/$PACKAGE_NAME"
SHA_FILE="$WORK_DIR/$SHA_NAME"
SIG_FILE="$WORK_DIR/$SIG_NAME"
PUBLIC_KEY="$WORK_DIR/release-public.pem"
EXTRACT_DIR="$WORK_DIR/package"
LIST_FILE="$WORK_DIR/archive-list.txt"

log "downloading $PRODUCT_VERSION update release files"
download_file "$PACKAGE_NAME" "$ARCHIVE"
download_file "$SHA_NAME" "$SHA_FILE"
download_file "$SIG_NAME" "$SIG_FILE"
write_public_key "$PUBLIC_KEY"
verify_release_files "$ARCHIVE" "$SHA_FILE" "$SIG_FILE" "$PUBLIC_KEY"
validate_and_extract_archive "$ARCHIVE" "$EXTRACT_DIR" "$LIST_FILE"
[ -f "$EXTRACT_DIR/install.sh" ] || fail "install.sh is missing from the archive root"
[ -f "$EXTRACT_DIR/precheck.sh" ] || fail "precheck.sh is missing from the archive root"
( cd "$EXTRACT_DIR" && bash ./install.sh --verify-package-only ) \
    || fail "inner SHA256, manifest, or Bash syntax verification failed"

set +e
( cd "$EXTRACT_DIR" && bash ./precheck.sh )
PRECHECK_RC=$?
set -e
case "$PRECHECK_RC" in
    0) ;;
    1) confirm_precheck_warning ;;
    *) fail "upgrade precheck blocked execution; resolve every BLOCK finding first" ;;
esac

FINAL_STATUS="installing"
write_state
INSTALL_STARTED=1
export JZZN_TRANSACTION_ID="$TXID"
export JZZN_PACKAGE_NAME="$PACKAGE_NAME"
export JZZN_PACKAGE_SHA256="$PACKAGE_SHA256"
export JZZN_SIGNATURE_VERIFIED=true
export JZZN_PRECHECK_DONE=1
export JZZN_LOCK_HELD=1
remove_legacy_installation_if_present
log "starting the packaged $PRODUCT_VERSION install.sh"
( cd "$EXTRACT_DIR" && bash ./install.sh ) \
    || fail "$PRODUCT_VERSION update did not complete; inspect $TX_LOG, /var/log/jzzn-install.log, and $STATE_FILE"

FINAL_STATUS="success"
log "GitHub online update completed: $PRODUCT_VERSION (transaction $TXID)"
exit 0
