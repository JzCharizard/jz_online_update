#!/bin/bash
# JZZN Sniff GitHub online updater
# Stable entry point:
#   curl -fsSL https://raw.githubusercontent.com/JzCharizard/jz_online_update/main/jz_online_updater_github.sh | sudo bash

set -uo pipefail

RELEASE_TAG="v1.2.9"
PRODUCT_VERSION="v1.2.9"
PACKAGE_NAME="jzzn-v1.2.9-update-linux-x86_64.7z"
PACKAGE_URL="https://github.com/JzCharizard/jz_online_update/releases/download/${RELEASE_TAG}/${PACKAGE_NAME}"
PACKAGE_SHA256="2c73c35c78ee17e5ce6b9ad5b6119de2a7d1696ad51760ad2714cc6c78f3d44e"
DOWNLOAD_HOST="github.com"
REQUIRED_PACKAGES="vim nano curl wget git htop bash-completion unzip iputils-ping net-tools traceroute dnsutils tcpdump build-essential"

KEEP=0
WORK_DIR=""
PASSWORD=""
SEVENZIP=""

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

fail() {
    log "Error: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
JZZN Sniff GitHub Online Updater

Usage:
  curl -fsSL https://raw.githubusercontent.com/JzCharizard/jz_online_update/main/jz_online_updater_github.sh | sudo bash
  curl -fsSL .../jz_online_updater_github.sh | sudo env JZ_PASS='update-package-password' bash

Options:
  --keep       Keep the temporary directory after a successful update
  -h, --help   Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --keep|--no-clean) KEEP=1 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
    shift
done

[ "$(id -u)" = "0" ] || fail "run as root (curl ... | sudo bash)"

cleanup() {
    local rc=$?
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        if [ "$KEEP" -eq 1 ] || [ "$rc" -ne 0 ]; then
            log "Temporary directory retained: $WORK_DIR"
        else
            rm -rf "$WORK_DIR"
        fi
    fi
}
trap cleanup EXIT

install_runtime_dependencies() {
    local package missing=""

    command -v dpkg-query >/dev/null 2>&1 \
        || fail "dpkg-query is unavailable; this updater supports Debian/Ubuntu only"
    command -v apt-get >/dev/null 2>&1 \
        || fail "apt-get is unavailable; runtime dependencies cannot be installed automatically"

    for package in $REQUIRED_PACKAGES; do
        if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q '^install ok installed$'; then
            missing="$missing $package"
        fi
    done

    for candidate in 7z 7za 7zr; do
        if command -v "$candidate" >/dev/null 2>&1; then
            SEVENZIP="$candidate"
            break
        fi
    done
    if [ -z "$SEVENZIP" ]; then
        missing="$missing p7zip-full"
    fi

    if [ -n "$missing" ]; then
        log "Missing packages detected:${missing}"
        log "Running apt-get update"
        DEBIAN_FRONTEND=noninteractive apt-get update \
            || fail "apt-get update failed"
        log "Installing online-update dependencies"
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive apt-get install -y $REQUIRED_PACKAGES p7zip-full \
            || fail "dependency installation failed"
    else
        log "Runtime dependency check passed"
    fi

    for candidate in 7z 7za 7zr; do
        if command -v "$candidate" >/dev/null 2>&1; then
            SEVENZIP="$candidate"
            break
        fi
    done
    [ -n "$SEVENZIP" ] || fail "7z command is still unavailable after dependency installation"
}

wait_for_download_host() {
    local attempt
    if ! command -v getent >/dev/null 2>&1; then
        log "getent is unavailable; skipping the download-host precheck"
        return 0
    fi
    for attempt in 1 2 3 4 5 6; do
        if getent ahosts "$DOWNLOAD_HOST" >/dev/null 2>&1 \
            || getent hosts "$DOWNLOAD_HOST" >/dev/null 2>&1; then
            return 0
        fi
        log "Unable to resolve ${DOWNLOAD_HOST}; waiting before retry (${attempt}/6)"
        if [ "$attempt" -eq 2 ] && command -v resolvectl >/dev/null 2>&1; then
            resolvectl flush-caches >/dev/null 2>&1 || true
        fi
        if [ "$attempt" -eq 3 ] \
            && command -v systemctl >/dev/null 2>&1 \
            && systemctl is-active --quiet systemd-resolved; then
            log "Restarting systemd-resolved to recover name resolution"
            systemctl restart systemd-resolved >/dev/null 2>&1 || true
        fi
        sleep 5
    done
    fail "cannot resolve ${DOWNLOAD_HOST}; check DNS/network connectivity and retry"
}

download_package() {
    local destination=$1 attempt
    log "Downloading the ${PRODUCT_VERSION} update package: $PACKAGE_URL"
    for attempt in 1 2 3 4 5; do
        wait_for_download_host
        rm -f "$destination"
        if command -v curl >/dev/null 2>&1; then
            curl -fL --progress-bar --connect-timeout 30 --max-time 3600 \
                -o "$destination" "$PACKAGE_URL" && [ -s "$destination" ] && return 0
        elif command -v wget >/dev/null 2>&1; then
            wget --progress=bar:force --timeout=30 --tries=1 \
                -O "$destination" "$PACKAGE_URL" && [ -s "$destination" ] && return 0
        else
            fail "neither curl nor wget is available"
        fi
        log "Package download failed; retrying in 5 seconds (${attempt}/5)" >&2
        sleep 5
    done
    fail "package download failed after all retries"
}

verify_package() {
    local archive=$1 actual
    actual=$(sha256sum "$archive" | awk '{print $1}') \
        || fail "cannot calculate the package SHA256"
    [ "$actual" = "$PACKAGE_SHA256" ] \
        || fail "package SHA256 mismatch (expected $PACKAGE_SHA256, actual $actual)"
    log "Package SHA256 verification passed"
}

read_password() {
    local empty_attempt
    if [ -n "${JZ_PASS:-}" ]; then
        PASSWORD=$JZ_PASS
        return 0
    fi
    [ -r /dev/tty ] \
        || fail "cannot read a password; provide one through the JZ_PASS environment variable"
    for empty_attempt in 1 2 3; do
        printf 'Enter update package password: ' > /dev/tty
        IFS= read -rs PASSWORD < /dev/tty
        printf '\n' > /dev/tty
        [ -n "$PASSWORD" ] && return 0
        log "Password cannot be empty (${empty_attempt}/3)" >&2
    done
    fail "no password was entered after three attempts"
}

extract_package() {
    local archive=$1 destination=$2 attempt
    for attempt in 1 2 3; do
        read_password
        rm -rf "$destination"
        mkdir -p "$destination" || fail "cannot create the extraction directory"
        if "$SEVENZIP" x -p"$PASSWORD" -o"$destination" -y "$archive" >/dev/null 2>&1; then
            log "Update package decrypted successfully"
            return 0
        fi
        log "Incorrect password or damaged archive (${attempt}/3)" >&2
        if [ -n "${JZ_PASS:-}" ]; then
            break
        fi
        PASSWORD=""
    done
    fail "decryption failed after all attempts; the update has stopped"
}

install_runtime_dependencies
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is unavailable"

WORK_DIR=$(mktemp -d /tmp/jzzn-online-update.XXXXXX) \
    || fail "cannot create the temporary directory"
ARCHIVE="$WORK_DIR/$PACKAGE_NAME"
EXTRACT_DIR="$WORK_DIR/package"

download_package "$ARCHIVE"
verify_package "$ARCHIVE"
extract_package "$ARCHIVE" "$EXTRACT_DIR"

INSTALL_SCRIPT=$(find "$EXTRACT_DIR" -type f -name install.sh 2>/dev/null \
    | awk -F/ '{print NF "\t" $0}' | sort -n | head -1 | cut -f2-)
[ -n "$INSTALL_SCRIPT" ] || fail "install.sh was not found in the update package"
PACKAGE_ROOT=$(dirname "$INSTALL_SCRIPT")

log "Starting the ${PRODUCT_VERSION} in-place upgrade"
( cd "$PACKAGE_ROOT" && bash ./install.sh ) \
    || fail "${PRODUCT_VERSION} upgrade failed; inspect /var/log/jzzn-install.log"

log "GitHub online update completed: ${PRODUCT_VERSION} (release ${RELEASE_TAG})"
exit 0
