#!/bin/bash
# JZZN Sniff GitHub online updater
# Stable entry point:
#   curl -fsSL https://raw.githubusercontent.com/JzCharizard/jz_online_update/main/jz_online_updater_github.sh | sudo bash

set -uo pipefail

RELEASE_TAG="v1.0.3"
PRODUCT_VERSION="v1.2.9"
PACKAGE_NAME="jzzn-v1.2.9-update-linux-x86_64.7z"
PACKAGE_URL="https://github.com/JzCharizard/jz_online_update/releases/download/${RELEASE_TAG}/${PACKAGE_NAME}"
PACKAGE_SHA256="75b9b0f4154c7b2e0d4bd0468a1eabc0637a2a3d71030b2e460f225b32a55a14"
REQUIRED_PACKAGES="vim nano curl wget git htop bash-completion unzip iputils-ping net-tools traceroute dnsutils tcpdump build-essential"

KEEP=0
WORK_DIR=""
PASSWORD=""
SEVENZIP=""

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

fail() {
    log "错误: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
JZZN Sniff GitHub 在线更新

用法：
  curl -fsSL https://raw.githubusercontent.com/JzCharizard/jz_online_update/main/jz_online_updater_github.sh | sudo bash
  curl -fsSL .../jz_online_updater_github.sh | sudo env JZ_PASS='更新包密码' bash

选项：
  --keep       更新完成后保留临时目录，便于排查
  -h, --help   显示帮助
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --keep|--no-clean) KEEP=1 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "未知参数: $1" ;;
    esac
    shift
done

[ "$(id -u)" = "0" ] || fail "请使用 root 权限执行（curl ... | sudo bash）"

cleanup() {
    local rc=$?
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        if [ "$KEEP" -eq 1 ] || [ "$rc" -ne 0 ]; then
            log "临时目录已保留: $WORK_DIR"
        else
            rm -rf "$WORK_DIR"
        fi
    fi
}
trap cleanup EXIT

install_runtime_dependencies() {
    local package missing=""

    command -v dpkg-query >/dev/null 2>&1 \
        || fail "当前系统不支持 dpkg-query；此在线更新包仅支持 Debian/Ubuntu 系统"
    command -v apt-get >/dev/null 2>&1 \
        || fail "当前系统未找到 apt-get；无法自动安装运行依赖"

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
        log "检测到缺少的软件包:${missing}"
        log "执行 apt-get update"
        DEBIAN_FRONTEND=noninteractive apt-get update \
            || fail "apt-get update 失败"
        log "安装在线更新所需依赖"
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive apt-get install -y $REQUIRED_PACKAGES p7zip-full \
            || fail "依赖安装失败"
    else
        log "运行依赖检查通过"
    fi

    for candidate in 7z 7za 7zr; do
        if command -v "$candidate" >/dev/null 2>&1; then
            SEVENZIP="$candidate"
            break
        fi
    done
    [ -n "$SEVENZIP" ] || fail "安装后仍未找到 7z 命令"
}

download_package() {
    local destination=$1
    log "下载 ${PRODUCT_VERSION} 更新包: $PACKAGE_URL"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --progress-bar --connect-timeout 30 --max-time 3600 \
            -o "$destination" "$PACKAGE_URL" || fail "更新包下载失败"
    elif command -v wget >/dev/null 2>&1; then
        wget --progress=bar:force --timeout=30 -O "$destination" "$PACKAGE_URL" \
            || fail "更新包下载失败"
    else
        fail "未找到 curl 或 wget"
    fi
    [ -s "$destination" ] || fail "下载到的更新包为空"
}

verify_package() {
    local archive=$1 actual
    actual=$(sha256sum "$archive" | awk '{print $1}') \
        || fail "无法计算更新包 SHA256"
    [ "$actual" = "$PACKAGE_SHA256" ] \
        || fail "更新包 SHA256 不匹配（期望 $PACKAGE_SHA256，实际 $actual）"
    log "更新包 SHA256 校验通过"
}

read_password() {
    if [ -n "${JZ_PASS:-}" ]; then
        PASSWORD=$JZ_PASS
        return 0
    fi
    [ -r /dev/tty ] \
        || fail "无法读取密码；请使用 JZ_PASS 环境变量传入"
    printf '请输入更新包密码: ' > /dev/tty
    IFS= read -rs PASSWORD < /dev/tty
    printf '\n' > /dev/tty
    [ -n "$PASSWORD" ] || fail "密码不能为空"
}

extract_package() {
    local archive=$1 destination=$2 attempt
    for attempt in 1 2 3; do
        read_password
        rm -rf "$destination"
        mkdir -p "$destination" || fail "无法创建解压目录"
        if "$SEVENZIP" x -p"$PASSWORD" -o"$destination" -y "$archive" >/dev/null 2>&1; then
            log "更新包解密成功"
            return 0
        fi
        log "密码错误或压缩包损坏（第 ${attempt}/3 次）" >&2
        if [ -n "${JZ_PASS:-}" ]; then
            break
        fi
        PASSWORD=""
    done
    fail "连续解密失败，更新已停止"
}

install_runtime_dependencies
command -v sha256sum >/dev/null 2>&1 || fail "未找到 sha256sum"

WORK_DIR=$(mktemp -d /tmp/jzzn-online-update.XXXXXX) \
    || fail "无法创建临时目录"
ARCHIVE="$WORK_DIR/$PACKAGE_NAME"
EXTRACT_DIR="$WORK_DIR/package"

download_package "$ARCHIVE"
verify_package "$ARCHIVE"
extract_package "$ARCHIVE" "$EXTRACT_DIR"

INSTALL_SCRIPT=$(find "$EXTRACT_DIR" -type f -name install.sh 2>/dev/null \
    | awk -F/ '{print NF "\t" $0}' | sort -n | head -1 | cut -f2-)
[ -n "$INSTALL_SCRIPT" ] || fail "更新包内未找到 install.sh"
PACKAGE_ROOT=$(dirname "$INSTALL_SCRIPT")

log "开始执行 ${PRODUCT_VERSION} 原地升级"
( cd "$PACKAGE_ROOT" && bash ./install.sh ) \
    || fail "${PRODUCT_VERSION} 升级失败；请检查 /var/log/jzzn-install.log"

log "GitHub 在线更新完成：${PRODUCT_VERSION}（发布 ${RELEASE_TAG}）"
exit 0
