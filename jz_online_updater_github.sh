#!/bin/bash
# JZZN Sniff GitHub transactional online updater.
# Stable compatibility entry:
#   curl -fsSL https://raw.githubusercontent.com/JzCharizard/jz_online_update/main/jz_online_updater_github.sh | sudo bash

set -Eeuo pipefail

RELEASE_TAG="v1.2.12"
PRODUCT_VERSION="v1.2.12"
PACKAGE_NAME="jzzn-v1.2.12-update-linux-x86_64.7z"
SHA_NAME="$PACKAGE_NAME.sha256"
SIG_NAME="$PACKAGE_NAME.sig"
RELEASE_BASE="https://github.com/JzCharizard/jz_online_update/releases/download/$RELEASE_TAG"
DOWNLOAD_HOST="github.com"
PACKAGE_SHA256="d48bb0717612533231cc070fed45e8969820275a088f8f8e48dae3d315a933e1"
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

JZ_PASS remains a v1.2.12 compatibility variable and will be removed later.
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

install_runtime_dependencies() {
    local package missing=""
    command -v apt-get >/dev/null 2>&1 || fail "apt-get is unavailable"
    command -v dpkg-query >/dev/null 2>&1 || fail "dpkg-query is unavailable"
    for package in $REQUIRED_PACKAGES; do
        dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q '^install ok installed$' \
            || missing="$missing $package"
    done
    if [ -n "$missing" ]; then
        log "installing missing minimum runtime dependencies:${missing}"
        DEBIAN_FRONTEND=noninteractive apt-get update || fail "apt-get update failed"
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive apt-get install -y $missing \
            || fail "runtime dependency installation failed"
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
    if [ -n "${JZ_PASS:-}" ]; then
        PASSWORD=$JZ_PASS
        log "WARNING: compatibility variable JZ_PASS is in use; migrate to protected credentials"
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
        [ -z "${JZZN_UPDATE_ARCHIVE_PASSWORD:-}${JZ_PASS:-}" ] || break
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
