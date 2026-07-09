#!/bin/bash
#
# jz_online_updater_github.sh
#
# 在线更新脚本 (GitHub 版), 托管于 GitHub:
#   https://raw.githubusercontent.com/JzCharizard/jz_online_update/master/jz_online_updater_github.sh
#
# 目标机一键执行:
#   curl -fsSL https://raw.githubusercontent.com/JzCharizard/jz_online_update/master/jz_online_updater_github.sh | sudo bash
#   curl -fsSL .../jz_online_updater_github.sh | sudo bash -s -- --dry-run
#
# 流程:
#   1. 从 GitHub 下载最新 file_manifest.json;
#   2. 下载固定 Release 的安装包(始终为同一个版本, 每次发版覆盖上传);
#   3. 与当前系统比对; 不一致则从安装包刷新 dst(逻辑同 jz_offline_updater.sh);
#   4. 成功后更新 /etc/init.d/file_manifest.json;
#   5. 成功后自动删除临时下载目录(管道执行无本地脚本文件, 仅清临时文件)。
#
# 依赖: bash(4+)、curl 或 wget、coreutils、tar、grep、sed、awk、find、sort、paste。
# 需要 root 权限(--dry-run 除外)。

set -o pipefail

GITHUB_RAW_BASE="https://raw.githubusercontent.com/JzCharizard/jz_online_update/master"
MANIFEST_NAME="file_manifest.json"
# 安装包固定 URL: 始终同一个 Release, 每次发版覆盖上传该文件
PACKAGE_URL="https://github.com/JzCharizard/jz_online_update/releases/download/v1.0.0/jz_offline_installer.sh.tar.gz"

SYSTEM_MANIFEST="/etc/init.d/file_manifest.json"
ALGO="sha256"
DRY_RUN=0
CLEAN=1

WORK_DIR=""
TMP=""

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S.%3N')" "$*"
}

usage() {
    cat <<'EOF'
jz_online_updater_github.sh - GitHub 在线更新

用法:
  curl -fsSL https://raw.githubusercontent.com/JzCharizard/jz_online_update/master/jz_online_updater_github.sh | sudo bash
  curl -fsSL .../jz_online_updater_github.sh | sudo bash -s -- --dry-run
  curl -fsSL .../jz_online_updater_github.sh | sudo bash -s -- --no-clean

选项:
  --dry-run       仅比对, 不下载安装包、不修改系统
  --no-clean      成功后保留临时下载目录
  --clean         成功后删除临时目录(默认)
  -h, --help      显示帮助
EOF
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --no-clean) CLEAN=0; shift ;;
        --clean)    CLEAN=1; shift ;;
        -h|--help)  usage 0 ;;
        *) log "未知参数: $1" >&2; usage 1 ;;
    esac
done

HASH_CMD="${ALGO}sum"
for c in "$HASH_CMD" tar find sort awk sed grep paste; do
    command -v "$c" >/dev/null 2>&1 || { log "错误: 缺少命令: $c" >&2; exit 1; }
done
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
    || { log "错误: 需要 curl 或 wget" >&2; exit 1; }

download_file() {
    local url=$1 dest=$2
    log "==> 下载: $url"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 30 --max-time 1800 -o "$dest" "$url" \
            || { log "错误: 下载失败: $url" >&2; return 1; }
    else
        wget -q -O "$dest" "$url" \
            || { log "错误: 下载失败: $url" >&2; return 1; }
    fi
    [ -s "$dest" ] || { log "错误: 下载结果为空: $url" >&2; return 1; }
}

install_system_manifest() {
    local src=$1
    if cp -f "$src" "$SYSTEM_MANIFEST"; then
        chmod 644 "$SYSTEM_MANIFEST" 2>/dev/null
        log "==> 已更新系统记录表: $SYSTEM_MANIFEST"
    else
        log "! 更新系统记录表失败(需 root?): $SYSTEM_MANIFEST" >&2
    fi
}

cleanup_workdir() {
    [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] || return 0
    log "==> 清理临时下载目录"
    rm -rf "$WORK_DIR" && log "  - 已删除: $WORK_DIR"
    log "==> 清理完成"
}

finish_success() {
    install_system_manifest "$MANIFEST"
    [ "$CLEAN" -eq 1 ] && cleanup_workdir
}

on_exit() {
    local code=$?
    rm -rf "$TMP"
    if [ "$code" -ne 0 ] && [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        log "临时目录保留(便于排查): $WORK_DIR" >&2
    fi
}
trap on_exit EXIT

# ----------------------------------------------------------------------------
# 哈希与 manifest 解析 (与 jz_offline_updater.sh 一致)
# ----------------------------------------------------------------------------
hash_file() { "$HASH_CMD" "$1" | awk '{print $1}'; }

hash_folder() {
    local folder=$1
    {
        cd "$folder" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r rel; do
            printf '%s\0' "$rel"
            cat "./$rel"
            printf '\0'
        done
        true
    } | "$HASH_CMD" | awk '{print $1}'
}

json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

read_manifest_tsv() {
    local f=$1
    paste -d'\t' \
        <(grep '"src":'   "$f" | sed 's/.*"src": *"\([^"]*\)".*/\1/') \
        <(grep '"dst":'   "$f" | sed 's/.*"dst": *"\([^"]*\)".*/\1/') \
        <(grep '"type":'  "$f" | sed 's/.*"type": *"\([^"]*\)".*/\1/') \
        <(grep '"mode":'  "$f" | sed 's/.*"mode": *"\([^"]*\)".*/\1/') \
        <(grep '"owner":' "$f" | sed 's/.*"owner": *"\([^"]*\)".*/\1/') \
        <(grep '"hash":'  "$f" | sed 's/.*"hash": *"\([^"]*\)".*/\1/')
}

# ----------------------------------------------------------------------------
# 1) 下载最新记录表
# ----------------------------------------------------------------------------
WORK_DIR=$(mktemp -d)
MANIFEST="${WORK_DIR}/${MANIFEST_NAME}"
CURRENT_OUT="${WORK_DIR}/file_manifest_current.json"
MANIFEST_URL="${GITHUB_RAW_BASE}/${MANIFEST_NAME}"

log "==> 在线更新开始 (工作目录: $WORK_DIR)"
download_file "$MANIFEST_URL" "$MANIFEST" || exit 1

# version 仅作展示/记录用途(不影响下载, 安装包 URL 固定)
VERSION=$(grep '"version":' "$MANIFEST" | head -1 | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')
PACKAGE="${WORK_DIR}/${PACKAGE_URL##*/}"

# ----------------------------------------------------------------------------
# 2) 载入记录表, 生成当前系统 manifest
# ----------------------------------------------------------------------------
declare -A LAT_DST LAT_TYPE LAT_MODE LAT_OWNER LAT_HASH
declare -A CUR_HASH
LAT_ORDER=()

while IFS=$'\t' read -r s d t m o h; do
    [ -z "$s" ] && continue
    LAT_DST["$s"]="$d"; LAT_TYPE["$s"]="$t"; LAT_MODE["$s"]="$m"
    LAT_OWNER["$s"]="$o"; LAT_HASH["$s"]="$h"
    LAT_ORDER+=("$s")
done < <(read_manifest_tsv "$MANIFEST")

generate_current_manifest() {
    local out=$1 files_body="" count=0
    local s dst type mode owner digest esrc edst etype emode eowner obj now

    for s in "${LAT_ORDER[@]}"; do
        dst="${LAT_DST[$s]}"; type="${LAT_TYPE[$s]}"
        mode="${LAT_MODE[$s]}"; owner="${LAT_OWNER[$s]}"
        case "$type" in
            file)
                [ -f "$dst" ] || { log "当前系统缺失(type=file): $dst" >&2; continue; }
                digest=$(hash_file "$dst") ;;
            folder)
                [ -d "$dst" ] || { log "当前系统缺失(type=folder): $dst" >&2; continue; }
                digest=$(hash_folder "$dst") ;;
            *) log "跳过(未知 type=${type}): $s" >&2; continue ;;
        esac
        CUR_HASH["$s"]="$digest"
        esrc=$(json_escape "$s"); edst=$(json_escape "$dst"); etype=$(json_escape "$type")
        emode=$(json_escape "$mode"); eowner=$(json_escape "$owner")
        obj="    {
      \"src\": \"${esrc}\",
      \"dst\": \"${edst}\",
      \"type\": \"${etype}\",
      \"mode\": \"${emode}\",
      \"owner\": \"${eowner}\",
      \"hash\": \"${digest}\"
    }"
        if [ -z "$files_body" ]; then files_body="$obj"; else files_body="${files_body},
${obj}"; fi
        count=$((count + 1))
    done

    now=$(date +"%Y-%m-%dT%H:%M:%S%:z")
    {
        printf '{\n  "version": "%s",\n' "${VERSION:-null}"
        printf '  "algorithm": "%s",\n' "$ALGO"
        printf '  "generated_at": "%s",\n' "$now"
        printf '  "count": %d,\n' "$count"
        if [ "$count" -eq 0 ]; then printf '  "files": []\n'
        else printf '  "files": [\n%s\n  ]\n' "$files_body"; fi
        printf '}\n'
    } > "$out"
}

log "==> 生成当前系统 manifest: $CURRENT_OUT"
generate_current_manifest "$CURRENT_OUT"

# ----------------------------------------------------------------------------
# 3) 比对
# ----------------------------------------------------------------------------
lat_count=${#LAT_ORDER[@]}
cur_count=${#CUR_HASH[@]}

log "==> 比对 (最新版 ${VERSION:-未标注})"
log "    数量: 最新版 ${lat_count} 条, 当前系统 ${cur_count} 条"
[ "$lat_count" -ne "$cur_count" ] && log "    ! 数量不一致"

NEEDS=()
for s in "${LAT_ORDER[@]}"; do
    if [ -z "${CUR_HASH[$s]+x}" ]; then
        log "    [缺失] $s  (dst: ${LAT_DST[$s]})"
        NEEDS+=("$s")
    elif [ "${CUR_HASH[$s]}" != "${LAT_HASH[$s]}" ]; then
        log "    [不同] $s  (dst: ${LAT_DST[$s]})"
        NEEDS+=("$s")
    fi
done

if [ ${#NEEDS[@]} -eq 0 ]; then
    log "==> 当前系统与最新版一致, 无需刷新。"
    [ "$DRY_RUN" -eq 0 ] && finish_success
    exit 0
fi

log "==> 需要刷新 ${#NEEDS[@]} 条"
if [ "$DRY_RUN" -eq 1 ]; then
    log "==> --dry-run: 仅比对, 不下载安装包、不修改系统。"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    log "错误: 在线更新需要 root 权限, 请使用: curl ... | sudo bash" >&2
    exit 1
fi

# ----------------------------------------------------------------------------
# 4) 下载安装包并刷新
# ----------------------------------------------------------------------------
download_file "$PACKAGE_URL" "$PACKAGE" || exit 1

TMP=$(mktemp -d)

log "==> 读取安装包内容清单"
LISTING=$(tar tf "$PACKAGE") || { log "错误: 无法读取安装包" >&2; exit 1; }
TOPDIR=$(printf '%s\n' "$LISTING" | head -1 | cut -d/ -f1)

resolve_member() {
    local s=$1 cand
    for cand in "$s" "./$s" "${TOPDIR}/$s" "./${TOPDIR}/$s"; do
        if printf '%s\n' "$LISTING" | awk -v c="$cand" 'BEGIN{f=1} $0==c || index($0,c"/")==1 {f=0} END{exit f}'; then
            printf '%s' "$cand"; return 0
        fi
    done
    return 1
}

declare -A MEMBER
members=()
for s in "${NEEDS[@]}"; do
    m=$(resolve_member "$s") || { log "错误: 安装包内找不到 src: $s" >&2; exit 1; }
    MEMBER["$s"]="$m"
    members+=("$m")
done

log "==> 从安装包解压 ${#members[@]} 个成员"
tar xf "$PACKAGE" -C "$TMP" "${members[@]}" || { log "错误: 解压失败" >&2; exit 1; }

patch_one_file() {
    local sp=$1 dp=$2 mode=$3 owner=$4
    mkdir -p "$(dirname "$dp")"
    cp -f "$sp" "$dp" || { log "    ! 复制失败: $sp -> $dp" >&2; return 1; }
    chmod "$mode"  "$dp" || log "    ! chmod 失败: $dp" >&2
    chown "$owner" "$dp" || log "    ! chown 失败: $dp" >&2
}

patch_folder_sync() {
    local sd=$1 dd=$2 mode=$3 owner=$4 rel dmode fmode
    dmode="${mode%%:*}"; fmode="${mode##*:}"
    mkdir -p "$dd"
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        mkdir -p "$(dirname "$dd/$rel")"
        cp -f "$sd/$rel" "$dd/$rel" || log "    ! 复制失败: $sd/$rel -> $dd/$rel" >&2
    done < <(cd "$sd" && find . -type f | sed 's|^\./||')
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        [ -f "$sd/$rel" ] || { rm -f "$dd/$rel" && log "    - 删除多余文件: $dd/$rel"; }
    done < <(cd "$dd" && find . -type f | sed 's|^\./||')
    find "$dd" -type d -exec chmod "$dmode" {} + || log "    ! chmod 目录失败: $dd" >&2
    find "$dd" -type f -exec chmod "$fmode" {} + || log "    ! chmod 文件失败: $dd" >&2
    chown -R "$owner" "$dd" || log "    ! chown -R 失败: $dd" >&2
}

log "==> 开始刷新"
for s in "${NEEDS[@]}"; do
    sp="${TMP}/${MEMBER[$s]}"
    dp="${LAT_DST[$s]}"
    t="${LAT_TYPE[$s]}"
    md="${LAT_MODE[$s]}"
    ow="${LAT_OWNER[$s]}"
    log "  * ${s}  ->  ${dp}  (${t}, mode=${md}, owner=${ow})"
    if [ "$t" = "folder" ]; then
        [ -d "$sp" ] || { log "    ! 解压后不是目录: $sp" >&2; continue; }
        patch_folder_sync "$sp" "$dp" "$md" "$ow"
    else
        [ -f "$sp" ] || { log "    ! 解压后不是文件: $sp" >&2; continue; }
        patch_one_file "$sp" "$dp" "$md" "$ow"
    fi
done

# ----------------------------------------------------------------------------
# 5) 回验
# ----------------------------------------------------------------------------
log "==> 回验刷新结果"
fail=0
for s in "${NEEDS[@]}"; do
    dp="${LAT_DST[$s]}"; t="${LAT_TYPE[$s]}"
    if [ "$t" = "folder" ]; then
        [ -d "$dp" ] && now_hash=$(hash_folder "$dp") || now_hash=""
    else
        [ -f "$dp" ] && now_hash=$(hash_file "$dp") || now_hash=""
    fi
    if [ "$now_hash" = "${LAT_HASH[$s]}" ]; then
        log "    [OK]   $s"
    else
        log "    [FAIL] $s  (期望 ${LAT_HASH[$s]:0:12}..., 实得 ${now_hash:0:12}...)"
        fail=$((fail + 1))
    fi
done

if [ "$fail" -eq 0 ]; then
    log "==> 全部刷新成功, 当前系统已与最新版一致。"
    finish_success
    exit 0
else
    log "==> 有 ${fail} 条回验失败, 未更新系统记录表, 请检查。" >&2
    exit 2
fi
