#!/usr/bin/env bash
# ============================================================
# PD-proxy — 多协议代理一键部署脚本 v3.8.0
# 协议: Snell v5 | Snell v4 (ShadowTLS) | Hysteria2 | VLESS Reality | AnyTLS
# 仓库: https://github.com/DDIPP1005/PD-proxy
# ============================================================
# 架构：数据驱动 — 所有协议定义为元数据表，安装引擎统一处理
# 原则：零静默错误 — 每步失败显式报错退出，不再吞噬错误
# ============================================================
set -euo pipefail
umask 077

# bash 4.0+ 必需（关联数组）
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { echo "需要 Bash 4.0+（Debian/Ubuntu 默认满足；macOS /bin/bash 3.2 不支持），当前: ${BASH_VERSION:-unknown}" >&2; exit 1; }

VERSION="3.8.0"
DEFAULT_SCRIPT_URL="https://raw.githubusercontent.com/DDIPP1005/PD-proxy/main/install.sh"
SCRIPT_URL="${PD_SCRIPT_URL:-$DEFAULT_SCRIPT_URL}"

cli_usage_error() {
    echo "参数错误: $*" >&2
    echo "使用 --help 查看支持的命令" >&2
    exit 2
}

# 纯查询命令，不需要锁和 root
case "${1:-}" in
    --help|-h)
        [ "$#" -eq 1 ] || cli_usage_error "$1 不接受额外参数"
        cat <<EOF
PD-proxy v${VERSION} — 多协议代理一键部署

用法:
  pd                      交互菜单
  pd --install    <协议>   安装  pd --uninstall <协议> 卸载
  pd --upgrade    <协议>   升级  pd --restart   <协议> 重启
  pd --stop/start <协议>   停止/启动
  pd --log        <协议>   日志  pd --config    <协议> 配置
  pd --config-all          全部配置  pd --export   导出
  pd --status              状态  pd --show      详情
  pd --doctor [--json]     只读诊断
  pd --bbr                 开启BBR  pd --bbrv3     BBRv3内核
  pd --update              更新    pd --remove-all [--yes]  卸载全部

协议: snell (Snell v5；PD_SNELL_MODE=shadowtls 可安装 Snell v4+ShadowTLS) | hy2 | vless | anytls

增强选项(环境变量):
  PD_SNELL_MODE=shadowtls  PD_SNELL_TLS_VERSION=v3  PD_HY2_HOP=5  PD_HY2_HOP_RANGE=30000-30100
  PD_SNELL_PORT=12345  PD_HY2_PORT=23456  PD_VLESS_PORT=34567  PD_ANYTLS_PORT=45678
  PD_VLESS_DEST=...:443
  PD_SNELL_MANUAL_TIMEOUT=6  PD_SNELL_PROBE_PARALLEL=12  PD_SNELL_VERSION=v5.x.x
  PD_BBR_BANDWIDTH=1000  PD_BBR_REGION=asia
  PD_LISTEN_FAMILY=auto  PD_PUBLIC_HOST=proxy.example.com
  PD_PUBLIC_IPV4=203.0.113.10  PD_PUBLIC_IPV6=2001:db8::10
  PD_STRICT_CHECKSUM=1  PD_SCRIPT_SHA256=<64位十六进制摘要>

示例:
  curl --proto '=https' --proto-redir '=https' -fsSLo /tmp/pd-install.sh ${DEFAULT_SCRIPT_URL}
  sudo bash /tmp/pd-install.sh
EOF
        exit 0 ;;
    --version|-v)
        [ "$#" -eq 1 ] || cli_usage_error "$1 不接受额外参数"
        echo "PD-proxy v${VERSION}"; exit 0 ;;
esac

# 无参数交互菜单不能用 `curl ... | bash`：stdin 会被脚本内容占用，菜单无法读取键盘。
# 带参数 CLI 允许非终端运行，便于自动化；持久化由 self_install 单独处理。
if [ "${PD_TEST_MODE:-0}" != "1" ] && [ "$#" -eq 0 ] && [ ! -t 0 ]; then
    echo "不能使用管道方式运行交互菜单，请改用：" >&2
    echo "  curl --proto '=https' --proto-redir '=https' -fsSLo /tmp/pd-install.sh ${DEFAULT_SCRIPT_URL}" >&2
    echo "  sudo bash /tmp/pd-install.sh" >&2
    exit 1
fi

# ============================================================
# 颜色 & 常量
# ============================================================
RED='\033[0;31m'; GREEN='\033[1;32m'; YELLOW='\033[0;33m'
CYAN='\033[1;36m'; MAGENTA='\033[1;35m'; BLUE='\033[1;34m'
BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

# 管道或重定向时自动去色
if [ ! -t 1 ]; then
    RED=''; GREEN=''; YELLOW=''; CYAN=''; MAGENTA=''; BLUE=''; BOLD=''; DIM=''; RESET=''
fi

BASE_DIR="${PD_BASE_DIR:-/opt/pd}"
STATE_FILE="${PD_STATE_FILE:-$BASE_DIR/state}"
INSTALLED_BIN="${PD_INSTALLED_BIN:-/usr/local/bin/pd}"
SYSTEMD_DIR="${PD_SYSTEMD_DIR:-/etc/systemd/system}"
LOCK_FILE="${PD_LOCK_FILE:-/run/lock/pd-proxy.lock}"
SPEEDTEST_BIN="${PD_SPEEDTEST_BIN:-/usr/local/bin/speedtest}"

# 日志函数必须在锁之前定义；锁失败路径也会使用 die。
info()  { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[!]${RESET} $*"; }
err()   { echo -e "${RED}[✗]${RESET} $*" >&2; }
step()  { echo -e "${CYAN}[>]${RESET} $*"; }
title() { echo -e "\n${BOLD}${CYAN}$*${RESET}"; }
die()   { err "$@"; exit 1; }

# ============================================================
# 协议安装选项（环境变量 → 全局变量，被 install_protocol 读取）
# ============================================================

# Snell 选项
PD_OPT_SNELL_MODE="${PD_SNELL_MODE:-standard}"          # standard | shadowtls
PD_OPT_SNELL_TLS_SNI="${PD_SNELL_TLS_SNI:-www.microsoft.com}"
PD_OPT_SNELL_TLS_PASS="${PD_SNELL_TLS_PASS:-}"          # 空=自动生成
PD_OPT_SNELL_TLS_VERSION="${PD_SNELL_TLS_VERSION:-v3}"  # v3 | v2

# HY2 选项
PD_OPT_HY2_HOP="${PD_HY2_HOP:-0}"                       # 0=单端口, 3 或 5
PD_OPT_HY2_HOP_RANGE="${PD_HY2_HOP_RANGE:-}"             # start-end，优先于 PD_HY2_HOP

# VLESS 选项
PD_OPT_VLESS_DEST="${PD_VLESS_DEST:-addons.mozilla.org:443}"
PD_OPT_VLESS_SNI="${PD_VLESS_SNI:-addons.mozilla.org}"
PD_OPT_VLESS_TRANSPORT="${PD_VLESS_TRANSPORT:-tcp}"     # tcp | grpc | ws
PD_OPT_VLESS_FP="${PD_VLESS_FP:-chrome}"                # chrome | firefox | safari | ios | randomized

# AnyTLS 选项
PD_OPT_ANYTLS_PADDING="${PD_ANYTLS_PADDING:-standard}"  # 兼容旧环境变量；当前服务端使用默认填充
PD_OPT_ANYTLS_SNI="${PD_ANYTLS_SNI:-}"                  # 空=不伪装

# 轻量化选项
PD_OPT_INSTALL_QR="${PD_INSTALL_QR:-0}"                  # 1=安装 qrencode 生成二维码

# 临时文件追踪（只清理自己创建的，不误删其他进程的文件）
declare -a _PD_TMPFILES=()
mktemp_pd() {
    local out_var="${1:-}" _pd_created_file
    [ -n "$out_var" ] || die "mktemp_pd 需要接收变量名"
    _pd_created_file=$(mktemp "${TMPDIR:-/tmp}/pd-XXXXXX") || die "创建临时文件失败"
    _PD_TMPFILES+=("$_pd_created_file")
    printf -v "$out_var" '%s' "$_pd_created_file"
}
mktemp_dir_pd() {
    local out_var="${1:-}" _pd_created_dir
    [ -n "$out_var" ] || die "mktemp_dir_pd 需要接收变量名"
    _pd_created_dir=$(mktemp -d "${TMPDIR:-/tmp}/pd-dir-XXXXXX") || die "创建临时目录失败"
    _PD_TMPFILES+=("$_pd_created_dir")
    printf -v "$out_var" '%s' "$_pd_created_dir"
}
cleanup_tmpfiles() {
    cleanup_tmpfiles_from 0
}
cleanup_tmpfiles_from() {
    local start="${1:-0}" i f
    for ((i=start; i<${#_PD_TMPFILES[@]}; i++)); do
        f="${_PD_TMPFILES[$i]:-}"
        if [ -n "$f" ]; then
            rm -rf -- "$f"
            _PD_TMPFILES[$i]=""
        fi
    done
    return 0
}
trap cleanup_tmpfiles EXIT

atomic_write_file() {
    local path="$1" mode="${2:-600}" dir base tmp
    dir=$(dirname "$path")
    base=$(basename "$path")
    [ -d "$dir" ] || { err "目标目录不存在: $dir"; return 1; }
    [ ! -L "$path" ] || { err "拒绝原子覆盖符号链接: $path"; return 1; }
    [ ! -e "$path" ] || [ -f "$path" ] || { err "目标不是普通文件: $path"; return 1; }
    tmp=$(mktemp "$dir/.${base}.XXXXXX") || return 1
    chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
    if ! cat > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if [ "$(id -u)" = 0 ]; then
        chown root:root "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print tolower($1)}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print tolower($1)}'
    else
        return 1
    fi
}

validate_https_url() {
    case "$1" in
        https://*) return 0 ;;
        *) err "拒绝非 HTTPS URL: $1"; return 1 ;;
    esac
}

curl_https() {
    command curl --proto '=https' --proto-redir '=https' "$@"
}

verify_expected_sha256() {
    local file="$1" expected="$2" label="$3" actual
    expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { err "$label 的 SHA-256 格式无效"; return 1; }
    actual=$(sha256_file "$file") || { err "缺少 SHA-256 工具，无法校验 $label"; return 1; }
    [ "$actual" = "$expected" ] || { err "$label SHA-256 不匹配"; return 1; }
}

github_release_digest() {
    local repo="$1" tag="$2" asset="$3"
    curl_https -fsS --retry 2 --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/${repo}/releases/tags/${tag}" 2>/dev/null \
        | awk -v asset="$asset" '
            /"name"[[:space:]]*:/ {
                line=$0; sub(/^.*"name"[[:space:]]*:[[:space:]]*"/, "", line); sub(/".*$/, "", line)
                wanted=(line == asset)
            }
            wanted && /"digest"[[:space:]]*:[[:space:]]*"sha256:/ {
                line=$0; sub(/^.*"digest"[[:space:]]*:[[:space:]]*"sha256:/, "", line); sub(/".*$/, "", line)
                print tolower(line); exit
            }
        '
}

verify_release_checksum() {
    local file="$1" label="$2" repo="${3:-}" tag="${4:-}" asset="${5:-}" digest=""
    if [ -n "$repo" ] && [ -n "$tag" ] && [ -n "$asset" ]; then
        digest=$(github_release_digest "$repo" "$tag" "$asset" || true)
    fi
    if [ -n "$digest" ]; then
        verify_expected_sha256 "$file" "$digest" "$label" || return 1
        info "$label 已按 GitHub release 官方 digest 校验"
        return 0
    fi
    if [ "${PD_STRICT_CHECKSUM:-0}" = 1 ]; then
        err "$label 未发布可读取的官方 SHA-256 digest；严格模式拒绝继续"
        return 1
    fi
    warn "$label 未提供可读取的官方 SHA-256 digest；仅完成 HTTPS、大小和格式校验"
}

download_https() {
    local url="$1" dest="$2" label="$3" repo="${4:-}" tag="${5:-}" asset
    validate_https_url "$url" || return 1
    curl_https -fSL# --retry 3 --connect-timeout 15 --max-time 300 -o "$dest" "$url" || return 1
    asset=${url##*/}
    verify_release_checksum "$dest" "$label" "$repo" "$tag" "$asset"
}

archive_paths_are_safe() {
    local path
    while IFS= read -r path; do
        case "$path" in
            /*|../*|*/../*|*/..) err "压缩包包含不安全路径: $path"; return 1 ;;
        esac
    done
}

extract_zip_binary() {
    local archive="$1" expected="$2" target="$3" label="$4" tmpdir source rc=0
    local tmp_start=${#_PD_TMPFILES[@]}
    unzip -Z1 "$archive" | archive_paths_are_safe || return 1
    mktemp_dir_pd tmpdir
    if ! unzip -q "$archive" -d "$tmpdir"; then
        rc=1
    elif find "$tmpdir" -type l -print -quit | grep -q .; then
        err "$label 压缩包包含符号链接，拒绝安装"
        rc=1
    else
        source=$(find "$tmpdir" -type f -name "$expected" -print -quit) || rc=1
        if [ "$rc" -eq 0 ] && [ -z "$source" ]; then
            err "$label 压缩包缺少 $expected"
            rc=1
        fi
        if [ "$rc" -eq 0 ]; then
            install -m 0755 "$source" "$target" || rc=1
        fi
    fi
    cleanup_tmpfiles_from "$tmp_start"
    return "$rc"
}

# 写锁只在变更动作执行期间持有。/run/lock 由 root 管理，且拒绝符号链接。
_PD_LOCK_DEPTH=0
write_lock_acquire() {
    if [ "$_PD_LOCK_DEPTH" -gt 0 ]; then
        _PD_LOCK_DEPTH=$((_PD_LOCK_DEPTH + 1))
        return 0
    fi
    local lock_dir
    command -v flock >/dev/null 2>&1 || die "缺少 flock，无法安全执行写操作"
    lock_dir=$(dirname "$LOCK_FILE")
    mkdir -p "$lock_dir" || die "无法创建锁目录: $lock_dir"
    [ ! -L "$lock_dir" ] || die "拒绝使用符号链接锁目录: $lock_dir"
    [ ! -L "$LOCK_FILE" ] || die "拒绝使用符号链接锁文件: $LOCK_FILE"
    [ ! -e "$LOCK_FILE" ] || [ -f "$LOCK_FILE" ] || die "锁路径不是普通文件: $LOCK_FILE"
    exec 200<>"$LOCK_FILE" || die "无法打开写锁: $LOCK_FILE"
    chmod 600 "$LOCK_FILE" || { exec 200>&-; die "无法保护写锁: $LOCK_FILE"; }
    flock -n 200 || { exec 200>&-; die "已有 PD-proxy 写操作在运行，请稍后再试"; }
    _PD_LOCK_DEPTH=1
}

write_lock_release() {
    local rc=0
    [ "$_PD_LOCK_DEPTH" -gt 0 ] || return 0
    _PD_LOCK_DEPTH=$((_PD_LOCK_DEPTH - 1))
    [ "$_PD_LOCK_DEPTH" -eq 0 ] || return 0
    flock -u 200 || rc=$?
    exec 200>&- || { [ "$rc" -ne 0 ] && return "$rc"; return 1; }
    return "$rc"
}

run_write_locked() {
    local rc release_rc=0 had_errexit=0 ignored cleanup_trap tmp_start=${#_PD_TMPFILES[@]}
    [[ $- == *e* ]] && had_errexit=1
    case "$tmp_start" in
        ''|*[!0-9]*) err "无效的临时文件清理起点"; return 1 ;;
    esac
    printf -v cleanup_trap 'cleanup_tmpfiles_from %q' "$tmp_start"

    # Keep the operation out of the caller's conditional/errexit context.
    # Bash disables errexit throughout a function called from if/||, and a
    # plain subshell inherits that suppression.  A command substitution is a
    # fresh execution context; fd 3 preserves the operation's normal stdout.
    set +e
    write_lock_acquire
    rc=$?
    if [ "$rc" -eq 0 ]; then
        {
            ignored=$(
                trap "$cleanup_trap" EXIT
                set -e
                "$@" >&3
            )
            rc=$?
        } 3>&1

        write_lock_release
        release_rc=$?
        if [ "$release_rc" -ne 0 ]; then
            err "释放写锁失败"
            [ "$rc" -ne 0 ] || rc=$release_rc
        fi
    fi
    [ "$had_errexit" -eq 0 ] || set -e
    return "$rc"
}

# ============================================================
# 公共工具
# ============================================================

check_root() {
    [ "$(id -u)" = "0" ] || die "请用 root 运行: sudo bash install.sh"
}

detect_os() {
    if [ -f /etc/os-release ]; then
        OS_ID=$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"' || echo "unknown")
        OS_PRETTY=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"' || echo "unknown")
    else
        OS_ID="unknown"
        OS_PRETTY="unknown"
    fi
    case "$OS_ID" in
        debian|ubuntu) OS_FAMILY="debian" ;;
        *) die "仅支持 Debian/Ubuntu，当前系统: $OS_ID" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
}

valid_ipv4() {
    local ip="$1" a b c d
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$ip"
    for o in "$a" "$b" "$c" "$d"; do
        [ "$o" -ge 0 ] 2>/dev/null && [ "$o" -le 255 ] || return 1
    done
    return 0
}

valid_ipv6() {
    local ip="$1" expanded part compressed=0 groups=0
    local -a _ipv6_parts=()
    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    [[ "$ip" != *:::* ]] || return 1
    if [[ "$ip" == *::* ]]; then
        [[ "${ip#*::}" != *::* ]] || return 1
        compressed=1
        expanded=${ip/::/:x:}
    else
        expanded="$ip"
    fi
    IFS=: read -r -a _ipv6_parts <<< "$expanded"
    for part in "${_ipv6_parts[@]}"; do
        [ -n "$part" ] || continue
        [ "$part" = x ] && continue
        [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        groups=$((groups + 1))
    done
    if [ "$compressed" = 1 ]; then
        [ "$groups" -lt 8 ]
    else
        [ "$groups" -eq 8 ]
    fi
}

fetch_public_ip() {
    local family="$1" validator="$2" url ip first="" replies=0
    for url in "https://ifconfig.me/ip" "https://api.ipify.org" "https://icanhazip.com"; do
        ip=$(curl_https "-${family}" -fsS --connect-timeout 2 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$ip" ] && "$validator" "$ip"; then
            replies=$((replies + 1))
            if [ -z "$first" ]; then
                first="$ip"
            elif [ "$ip" != "$first" ]; then
                warn "公网 IPv${family} 来源结果不一致，已拒绝使用自动探测地址" >&2
                return 2
            fi
        fi
    done
    [ "$replies" -gt 0 ] || return 1
    printf '%s\n' "$first"
}

get_ip() {
    IP=""; IP6=""; PUBLIC_HOST=""
    if [ -n "${PD_PUBLIC_HOST:-}" ]; then
        validate_hostname "$PD_PUBLIC_HOST" "PD_PUBLIC_HOST"
        PUBLIC_HOST="$PD_PUBLIC_HOST"
    fi
    if [ -n "${PD_PUBLIC_IPV4:-}" ]; then
        valid_ipv4 "$PD_PUBLIC_IPV4" || die "PD_PUBLIC_IPV4 不是有效 IPv4 地址"
        IP="$PD_PUBLIC_IPV4"
    elif [ -z "$PUBLIC_HOST" ]; then
        IP=$(fetch_public_ip 4 valid_ipv4 || true)
    fi
    if [ -n "${PD_PUBLIC_IPV6:-}" ]; then
        valid_ipv6 "$PD_PUBLIC_IPV6" || die "PD_PUBLIC_IPV6 不是有效 IPv6 地址"
        IP6="$PD_PUBLIC_IPV6"
    elif [ -z "$PUBLIC_HOST" ]; then
        IP6=$(fetch_public_ip 6 valid_ipv6 || true)
    fi
    return 0
}

get_mem() {
    MEM_TOTAL=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")
    MEM_AVAIL=$(free -m 2>/dev/null | awk '/^Mem:/{print $NF}' || echo "0")
}

has_ipv6() {
    ip -6 addr show scope global 2>/dev/null | grep -q inet6 && return 0 || return 1
}

bindv6only_value() {
    local value
    value=$(sysctl -n net.ipv6.bindv6only 2>/dev/null || cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || echo 1)
    case "$value" in 0|1) printf '%s\n' "$value" ;; *) printf '1\n' ;; esac
}

prepare_listen_family() {
    local requested="${PD_LISTEN_FAMILY:-auto}" bindonly
    case "$requested" in auto|ipv4|ipv6|dual) ;; *) die "PD_LISTEN_FAMILY 仅支持 auto|ipv4|ipv6|dual" ;; esac
    bindonly=$(bindv6only_value)
    case "$requested" in
        auto)
            if has_ipv6 && [ "$bindonly" = 0 ]; then
                PD_EFFECTIVE_LISTEN_FAMILY=dual
                PD_LISTEN_HOST="::"
            else
                PD_EFFECTIVE_LISTEN_FAMILY=ipv4
                PD_LISTEN_HOST="0.0.0.0"
            fi ;;
        ipv4) PD_EFFECTIVE_LISTEN_FAMILY=ipv4; PD_LISTEN_HOST="0.0.0.0" ;;
        ipv6)
            has_ipv6 || die "PD_LISTEN_FAMILY=ipv6，但系统没有全局 IPv6 地址"
            PD_EFFECTIVE_LISTEN_FAMILY=ipv6; PD_LISTEN_HOST="::" ;;
        dual)
            has_ipv6 || die "PD_LISTEN_FAMILY=dual，但系统没有全局 IPv6 地址"
            PD_EFFECTIVE_LISTEN_FAMILY=dual; PD_LISTEN_HOST="::"
            [ "$bindonly" = 0 ] || warn "net.ipv6.bindv6only=1；将启动后实测双栈，若程序未自行关闭 IPV6_V6ONLY 则回滚" ;;
    esac
}

listen_endpoint() {
    local port="$1"
    case "$PD_LISTEN_HOST" in *:*) printf '[%s]:%s' "$PD_LISTEN_HOST" "$port" ;; *) printf '%s:%s' "$PD_LISTEN_HOST" "$port" ;; esac
}

require_public_endpoint() {
    [ -n "${PUBLIC_HOST:-}" ] || [ -n "${IP:-}" ] || [ -n "${IP6:-}" ] || die "无法得到一致、有效的公网地址；请设置 PD_PUBLIC_HOST/PD_PUBLIC_IPV4/PD_PUBLIC_IPV6"
}

output_hosts() {
    local key="$1" allow4 allow6 port service transport
    OUTPUT_HOST4=""; OUTPUT_HOST6=""
    allow4=$(state_get "$key" listen_ipv4 2>/dev/null || true)
    allow6=$(state_get "$key" listen_ipv6 2>/dev/null || true)
    if [ -z "$allow4$allow6" ]; then
        port=$(state_get "$key" port 2>/dev/null || true)
        case "$key" in
            snell) service=snell; transport=tcp; [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ] && service=shadowtls-snell ;;
            hy2) service=hysteria2; transport=udp ;;
            vless) service=xray; transport=tcp ;;
            anytls) service=anytls; transport=tcp ;;
            *) return 1 ;;
        esac
        if [[ "$port" =~ ^[0-9]+$ ]] && systemctl is-active --quiet "$service" 2>/dev/null; then
            service_port_family_listening "$port" "$transport" "$service" ipv4 && allow4=1 || allow4=0
            service_port_family_listening "$port" "$transport" "$service" ipv6 && allow6=1 || allow6=0
        fi
    fi
    if [ -n "${PUBLIC_HOST:-}" ] && { [ "$allow4" = 1 ] || [ "$allow6" = 1 ]; }; then
        OUTPUT_HOST4=$(format_proxy_host "$PUBLIC_HOST")
        return 0
    fi
    [ "$allow4" = 1 ] && [ -n "${IP:-}" ] && OUTPUT_HOST4=$(format_proxy_host "$IP")
    [ "$allow6" = 1 ] && [ -n "${IP6:-}" ] && OUTPUT_HOST6=$(format_proxy_host "$IP6")
    [ -n "$OUTPUT_HOST4" ] || [ -n "$OUTPUT_HOST6" ] || {
        err "没有与实际监听地址族匹配的已验证公网地址，拒绝生成配置"
        return 1
    }
}

select_output_hosts() {
    local key="$1"
    output_hosts "$key" || return 1
    if [ -z "${OUTPUT_HOST4:-}" ]; then
        OUTPUT_HOST4="${OUTPUT_HOST6:-}"
        OUTPUT_HOST6=""
    elif [ "${OUTPUT_HOST6:-}" = "$OUTPUT_HOST4" ]; then
        OUTPUT_HOST6=""
    fi
    [ -n "${OUTPUT_HOST4:-}" ] || {
        err "没有可用的主输出地址，拒绝生成配置"
        return 1
    }
}

format_proxy_host() {
    local host="$1"
    case "$host" in
        *:*) printf '[%s]' "$host" ;;
        *) printf '%s' "$host" ;;
    esac
}

check_nftables() {
    # Hysteria2 端口跳跃需要 nftables (内核 4.18+, nf_tables 模块)
    # 先做轻量检测
    if ! command -v nft >/dev/null 2>&1; then
        return 1
    fi
    # 功能验证：尝试创建/删除临时 table，确认 nftables 真实可用
    local test_table="pd_nft_test_$$"
    if nft add table inet "$test_table" 2>/dev/null && nft delete table inet "$test_table" 2>/dev/null; then
        return 0
    fi
    return 1
}

detect_virt() {
    # 检测虚拟化环境：OpenVZ/Virtuozzo/LXC 无法加载内核模块，影响 BBR 和 nftables
    local virt=""
    if [ -f /proc/vz/veinfo ] || [ -d /proc/vz ]; then
        virt="openvz"
    elif grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
        virt="lxc"
    elif systemd-detect-virt -c 2>/dev/null | grep -q 'lxc'; then
        virt="lxc"
    fi
    [ -n "$virt" ] && echo "$virt" || echo "none"
}

check_disk() {
    local need_mb="$1"
    local avail_kb
    mkdir -p /opt
    avail_kb=$(df -k /opt 2>/dev/null | awk 'NR==2{print $4}' || echo "0")
    [ "$avail_kb" -gt $((need_mb * 1024)) ] || die "磁盘空间不足，需要 ${need_mb}MB，剩余 $((avail_kb / 1024))MB"
}

rand_port() {
    local attempts=0
    while [ $attempts -lt 100 ]; do
        local p=$(( $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 50001 + 10000 ))
        if ! get_all_ports | awk -v p="$p" '$1 == p { found=1 } END { exit found ? 0 : 1 }'; then
            # 额外检查：确保端口未被非 PD 服务占用
            if port_in_use "$p"; then
                attempts=$((attempts + 1))
                continue
            fi
            # 候选生成后再复检状态，避免并发或多行输出造成冲突。
            state_port_range_conflict "$p" "$p" "" && { attempts=$((attempts + 1)); continue; }
            echo "$p"
            return 0
        fi
        attempts=$((attempts + 1))
    done
    die "无法分配空闲端口（10000-60000），请手动指定"
}

rand_port_range() {
    local count="$1" attempts=0 max_base p end busy
    [[ "$count" =~ ^[0-9]+$ ]] || die "端口范围数量无效: $count"
    [ "$count" -ge 1 ] || die "端口范围数量无效: $count"
    max_base=$((60000 - count + 1))
    [ "$max_base" -ge 10000 ] || die "端口范围过大，无法在 10000-60000 内自动分配"
    while [ $attempts -lt 200 ]; do
        p=$(( $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % (max_base - 10000 + 1) + 10000 ))
        end=$((p + count - 1))
        if state_port_range_conflict "$p" "$end" ""; then
            attempts=$((attempts + 1))
            continue
        fi
        busy=$(system_port_range_conflict "$p" "$end" || true)
        if [ -n "$busy" ]; then
            attempts=$((attempts + 1))
            continue
        fi
        state_port_range_conflict "$p" "$end" "" && { attempts=$((attempts + 1)); continue; }
        echo "$p"
        return 0
    done
    die "无法分配连续空闲端口范围（${count} 个端口），请手动指定 PD_HY2_HOP_RANGE"
}

rand_pass() {
    openssl rand -hex 16 2>/dev/null || date +%s%N | sha256sum | cut -d' ' -f1
}

gen_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || {
        printf '%08x-%04x-%04x-%04x-%04x%08x\n' \
            $((RANDOM<<16|RANDOM)) $RANDOM $((RANDOM%0x10000)) \
            $((RANDOM%0x4000+0x4000)) $((RANDOM%0x4000+0x8000)) \
            $((RANDOM<<16|RANDOM))
    }
}

json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

url_escape() {
    local s="$1" i c out=""
    for ((i=0; i<${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v out '%s%%%02X' "$out" "'$c" ;;
        esac
    done
    printf '%s' "$out"
}

json_tag_name() {
    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

snell_manual_html() {
    local timeout
    timeout=$(snell_manual_timeout)
    curl_https -fsSL --connect-timeout 2 --max-time "$timeout" "https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell" 2>/dev/null \
        || curl_https -fsSL --connect-timeout 2 --max-time "$timeout" "https://manual.nssurge.com/others/snell.html" 2>/dev/null \
        || true
}

snell_arch() {
    case "$ARCH" in
        amd64) echo "amd64" ;;
        arm64) echo "aarch64" ;;
        *) echo "$ARCH" ;;
    esac
}

snell_manual_timeout() {
    local timeout="${PD_SNELL_MANUAL_TIMEOUT:-6}"
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=6
    [ "$timeout" -lt 2 ] && timeout=2
    [ "$timeout" -gt 15 ] && timeout=15
    echo "$timeout"
}

snell_probe_candidates() {
    local major="$1" minor patch
    local max_minor="${PD_SNELL_PROBE_MINOR_MAX:-9}"
    local max_patch="${PD_SNELL_PROBE_PATCH_MAX:-12}"
    [[ "$max_minor" =~ ^[0-9]+$ ]] || max_minor=9
    [[ "$max_patch" =~ ^[0-9]+$ ]] || max_patch=12
    [ "$max_minor" -gt 20 ] && max_minor=20
    [ "$max_patch" -gt 50 ] && max_patch=50
    for ((minor=max_minor; minor>=0; minor--)); do
        for ((patch=max_patch; patch>=0; patch--)); do
            printf 'v%s.%s.%s\n' "$major" "$minor" "$patch"
        done
    done
}

snell_probe_latest() {
    local major="$1" batch_size="${PD_SNELL_PROBE_PARALLEL:-12}"
    [[ "$batch_size" =~ ^[0-9]+$ ]] || batch_size=12
    [ "$batch_size" -lt 2 ] && batch_size=2
    [ "$batch_size" -gt 32 ] && batch_size=32

    local -a batch=()
    local probe found
    while IFS= read -r probe; do
        batch+=("$probe")
        if [ "${#batch[@]}" -ge "$batch_size" ]; then
            found=$(snell_probe_batch "${batch[@]}" || true)
            if [ -n "$found" ]; then
                echo "$found"
                return 0
            fi
            batch=()
        fi
    done < <(snell_probe_candidates "$major")
    if [ "${#batch[@]}" -gt 0 ]; then
        found=$(snell_probe_batch "${batch[@]}" || true)
        if [ -n "$found" ]; then
            echo "$found"
            return 0
        fi
    fi
    return 1
}

snell_cache_get() {
    local major="$1" cache_file="$2" cached=""
    [ -s "$cache_file" ] || return 1
    cached=$(sed -n '1p' "$cache_file" 2>/dev/null || true)
    if [[ "$cached" =~ ^v${major}\.[0-9]+\.[0-9]+[a-z0-9]*$ ]]; then
        echo "$cached"
        return 0
    fi
    warn "忽略无效 Snell 缓存版本: $cached" >&2
    return 1
}

snell_probe_batch() {
    local tmpdir probe probe_url pid result=""
    local -a pids=()
    tmpdir=$(mktemp -d /tmp/pd-snell-probe-XXXXXX)
    for probe in "$@"; do
        (
            trap - EXIT ERR
            probe_url="https://dl.nssurge.com/snell/snell-server-${probe}-linux-$(snell_arch).zip"
            curl_https -fsI --connect-timeout 1 --max-time 3 "$probe_url" >/dev/null 2>&1 && printf '%s\n' "$probe" > "$tmpdir/${probe}"
        ) &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    local -a result_files=("$tmpdir"/*)
    if [ -e "${result_files[0]}" ]; then
        result=$(snell_version_sort < <(printf '%s\n' "${result_files[@]}" | while IFS= read -r f; do sed -n '1p' "$f"; done) | head -1 || true)
        rm -rf "$tmpdir"
        [ -n "$result" ] && echo "$result" && return 0
        return 1
    fi
    rm -rf "$tmpdir"
    return 1
}

snell_strict_latest_msg() {
    local major="$1"
    echo "Snell ${major} 最新版检测失败：$(snell_manual_timeout) 秒内无法读取 Snell KB/手册。严格最新版模式下拒绝 fallback；可重试或设置 PD_SNELL_MANUAL_TIMEOUT=10"
}

snell_manual_fail_msg() {
    local major="$1"
    echo "Snell ${major} 可用版本检测失败，请检查网络或手动指定: PD_SNELL_VERSION=v${major}.x.x"
}

snell_version_sort() {
    sed 's/^v//' | sort -t. -k1,1nr -k2,2nr -k3,3nr | sed 's/^/v/'
}

require_version() {
    local ver="$1" label="$2"
    [ -n "$ver" ] || die "$label 版本为空，已停止安装，避免下载错误 URL"
}

version_to_num() {
    local v="${1#v}" a=0 b=0 c=0
    IFS=. read -r a b c <<< "$v"
    [[ "$a" =~ ^[0-9]+$ ]] || a=0
    [[ "$b" =~ ^[0-9]+$ ]] || b=0
    [[ "$c" =~ ^[0-9]+$ ]] || c=0
    printf '%d%03d%03d\n' "$a" "$b" "$c"
}

script_file_version() {
    local file="$1"
    sed -n 's/^VERSION="\([0-9][0-9.]*\)".*/\1/p' "$file" 2>/dev/null | head -1
}

downloaded_script_is_older() {
    local file="$1" remote_ver
    remote_ver=$(script_file_version "$file")
    [ -n "$remote_ver" ] || return 1
    [ "$(version_to_num "$remote_ver")" -lt "$(version_to_num "$VERSION")" ]
}

state_field_from_line() {
    local field="$1"
    tr ' ' '\n' | sed -n "s/^${field}=//p" | head -1
}

conf_value() {
    local key="$1" file="$2"
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$file" 2>/dev/null | head -1
}

yaml_value() {
    local key="$1" file="$2"
    sed -n "s/^[[:space:]]*${key}:[[:space:]]*//p" "$file" 2>/dev/null | head -1
}

json_value() {
    local key="$1" file="$2"
    sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" 2>/dev/null | head -1
}

unit_arg_value() {
    local arg="$1" file="$2"
    local value
    value=$(tr ' ' '\n' < "$file" 2>/dev/null | awk -v arg="$arg" '$0 == arg { getline; print; exit }') || return 1
    [ -n "$value" ] || return 1
    systemd_unescape_arg "$value"
}

unit_password_value() {
    unit_arg_value "--password" "$1"
}

systemd_escape_arg() {
    local s="$1"
    case "$s" in
        *[[:space:]\"\\%]* ) die "systemd 参数包含不支持的字符: $s" ;;
    esac
    s=${s//\$/\$\$}
    printf '%s' "$s"
}

systemd_unescape_arg() {
    local s="$1" out="" c next i
    for ((i=0; i<${#s}; i++)); do
        c=${s:i:1}
        if [ "$c" = '$' ]; then
            next=${s:i+1:1}
            [ "$next" = '$' ] || return 1
            out+='$'
            i=$((i + 1))
        else
            out+="$c"
        fi
    done
    printf '%s' "$out"
}

validate_hostname() {
    local value="$1" label="$2"
    [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]] || die "$label 格式无效: $value"
}

validate_hostport() {
    local value="$1" label="$2"
    [[ "$value" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || die "$label 格式无效，应为 host:port: $value"
    local port="${value##*:}"
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "$label 端口无效: $port"
}

validate_port() {
    local value="$1" label="$2"
    [[ "$value" =~ ^[0-9]{1,5}$ ]] || die "$label 必须是 1-65535 的端口号: $value"
    [ "$value" -ge 1 ] && [ "$value" -le 65535 ] || die "$label 端口超出范围: $value"
}

port_in_use() {
    local port="$1"
    ss_port_listening "$port" tcp && return 0
    ss_port_listening "$port" udp && return 0
    return 1
}

ss_port_listening() {
    local port="$1" transport="$2" flag
    case "$transport" in tcp) flag=-ltn ;; udp) flag=-lun ;; *) return 2 ;; esac
    ss -H "$flag" 2>/dev/null | awk -v port="$port" '
        {
            addr=$4
            sub(/%[^:]*:/, ":", addr)
            if (addr ~ (":" port "$")) found=1
        }
        END { exit found ? 0 : 1 }
    '
}

service_port_listening() {
    local port="$1" transport="$2" service="$3" flag pid
    case "$transport" in tcp) flag=-ltnp ;; udp) flag=-lunp ;; *) return 2 ;; esac
    pid=$(systemctl show -p MainPID --value "$service" 2>/dev/null) || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    ss -H "$flag" 2>/dev/null | awk -v port="$port" -v pid="$pid" '
        {
            addr=$4
            sub(/%[^:]*:/, ":", addr)
            if (addr ~ (":" port "$")) {
                marker="pid=" pid "([,)]|$)"
                if ($0 ~ marker) found=1
            }
        }
        END { exit found ? 0 : 1 }
    '
}

bindv6only_confirmed_value() {
    local value
    if value=$(sysctl -n net.ipv6.bindv6only 2>/dev/null); then
        :
    elif value=$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null); then
        :
    else
        return 1
    fi
    case "$value" in 0|1) printf '%s\n' "$value" ;; *) return 1 ;; esac
}

# Print 1/0 when the family can be confirmed as listening/not listening.
# In strict mode an IPv6 wildcard does not prove whether its socket accepts
# IPv4: IPV6_V6ONLY is per-socket and may override net.ipv6.bindv6only.
_service_port_family_probe() {
    local mode="$1" port="$2" transport="$3" service="$4" family="$5"
    local flag family_flag pid bindonly sockets
    case "$mode" in strict|compat) ;; *) return 2 ;; esac
    case "$transport" in tcp) flag=-ltnp ;; udp) flag=-lunp ;; *) return 2 ;; esac
    case "$family" in ipv4) family_flag=-4 ;; ipv6) family_flag=-6 ;; *) return 2 ;; esac
    pid=$(systemctl show -p MainPID --value "$service" 2>/dev/null) || return 2
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 2
    sockets=$(ss -H "$family_flag" "$flag" 2>/dev/null) || return 2
    if printf '%s\n' "$sockets" | awk -v port="$port" -v pid="$pid" '
        {
            addr=$4
            marker="pid=" pid "([,)]|$)"
            if ($0 !~ marker || addr !~ (":" port "$")) next
            found=1
        }
        END { exit found ? 0 : 1 }
    '; then
        printf '1\n'
        return 0
    fi
    if [ "$family" != ipv4 ]; then
        printf '0\n'
        return 0
    fi
    # The -6 filter makes ambiguous ss output such as *:443 unambiguously IPv6.
    sockets=$(ss -H -6 "$flag" 2>/dev/null) || return 2
    if printf '%s\n' "$sockets" | awk -v port="$port" -v pid="$pid" '
        {
            addr=$4
            marker="pid=" pid "([,)]|$)"
            if ($0 !~ marker || addr !~ (":" port "$")) next
            if (addr ~ /^\[::\]:/ || addr ~ /^:::/ || addr ~ /^\*:/) found=1
        }
        END { exit found ? 0 : 1 }
    '; then
        [ "$mode" = compat ] || return 2
        # Compatibility heuristic for post-install verification only.  The
        # global default cannot prove this socket's IPV6_V6ONLY setting.
        bindonly=$(bindv6only_confirmed_value) || return 2
        [ "$bindonly" = 0 ] && printf '1\n' || printf '0\n'
    else
        printf '0\n'
    fi
}

service_port_family_probe() {
    _service_port_family_probe strict "$@"
}

service_port_family_compat_probe() {
    _service_port_family_probe compat "$@"
}

service_port_family_listening() {
    local actual
    actual=$(service_port_family_compat_probe "$@") || return $?
    [ "$actual" = 1 ]
}

verify_and_record_listen_families() {
    local key="$1" port="$2" transport="$3" service="$4" got4=0 got6=0
    service_port_family_listening "$port" "$transport" "$service" ipv4 && got4=1
    service_port_family_listening "$port" "$transport" "$service" ipv6 && got6=1
    case "${PD_EFFECTIVE_LISTEN_FAMILY:-auto}" in
        ipv4) [ "$got4" = 1 ] && [ "$got6" = 0 ] || { err "服务未实现仅 IPv4 监听（IPv4=$got4 IPv6=$got6）"; return 1; } ;;
        ipv6) [ "$got6" = 1 ] && [ "$got4" = 0 ] || { err "服务未实现仅 IPv6 监听（IPv4=$got4 IPv6=$got6）"; return 1; } ;;
        dual) [ "$got4" = 1 ] && [ "$got6" = 1 ] || { err "服务未实际提供双栈监听（IPv4=$got4 IPv6=$got6）"; return 1; } ;;
        auto) [ "$got4" = 1 ] || [ "$got6" = 1 ] || return 1 ;;
    esac
    state_set "$key" listen_ipv4 "$got4" || return 1
    state_set "$key" listen_ipv6 "$got6" || return 1
    state_set "$key" listen_family "${PD_EFFECTIVE_LISTEN_FAMILY:-auto}"
}

protocol_transport() {
    case "$1" in
        hy2) echo udp ;;
        snell|vless|anytls) echo tcp ;;
        *) return 1 ;;
    esac
}

system_port_range_conflict() {
    local start="$1" end="$2" p
    for ((p=start; p<=end; p++)); do
        if port_in_use "$p"; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

port_var_name() {
    local proto="$1" key
    key=$(pkey "$proto")
    printf 'PD_%s_PORT' "$(echo "$key" | tr '[:lower:]' '[:upper:]')"
}

set_protocol_port() {
    local proto="$1" port="$2" port_var
    validate_port "$port" "端口"
    port_var=$(port_var_name "$proto")
    printf -v "$port_var" '%s' "$port"
}

prompt_protocol_port() {
    local proto="$1" name port_var port pc
    name=$(pname "$proto")
    port_var=$(port_var_name "$proto")
    while true; do
        echo ""
        echo -e "  ${MAGENTA}▸ ${name} — 监听端口${RESET}"
        echo -e "  ${CYAN}┌──────────────────────────────────────┐${RESET}"
        echo -e "  ${CYAN}│${RESET} [1] ${GREEN}自动分配${RESET}         推荐              ${CYAN}│${RESET}"
        echo -e "  ${CYAN}│${RESET} [2] 自定义端口                        ${CYAN}│${RESET}"
        echo -e "  ${CYAN}│${RESET} [B] ${DIM}返回${RESET}                            ${CYAN}│${RESET}"
        echo -e "  ${CYAN}└──────────────────────────────────────┘${RESET}"
        echo -ne "  ${MAGENTA}▸${RESET} 选择 [1]: "
        read -r pc
        case "$pc" in
            2)
                echo -ne "  输入端口 (1-65535): "
                read -r port
                validate_port "$port" "端口"
                if state_port_range_conflict "$port" "$port" "$(pkey "$proto")"; then
                    warn "端口 $port 已被其它 PD 协议使用，请换一个端口"
                    continue
                fi
                if port_in_use "$port"; then
                    warn "端口 $port 已被占用，请换一个端口"
                    continue
                fi
                printf -v "$port_var" '%s' "$port"
                return 0 ;;
            [Bb]) return 1 ;;
            [Qq]) info "再见 👋"; exit 0 ;;
            *) unset "$port_var"; return 0 ;;
        esac
    done
}

apply_hy2_hop_range() {
    local range="$1" start end count
    [[ "$range" =~ ^[0-9]{1,5}-[0-9]{1,5}$ ]] || die "HY2 跳跃范围格式应为 start-end，例如 30000-30100"
    start="${range%-*}"
    end="${range#*-}"
    validate_port "$start" "HY2 跳跃起始端口"
    validate_port "$end" "HY2 跳跃结束端口"
    [ "$end" -ge "$start" ] || die "HY2 跳跃范围结束端口必须大于等于起始端口"
    count=$((end - start + 1))
    [ "$count" -ge 3 ] || die "HY2 跳跃范围至少需要 3 个端口"
    [ "$count" -le 1000 ] || die "HY2 跳跃范围最多 1000 个端口，避免防火墙规则过重"
    if state_port_range_conflict "$start" "$end" "hy2"; then
        die "HY2 跳跃范围 $range 与其它已安装 PD 协议端口冲突"
    fi
    local busy_port
    busy_port=$(system_port_range_conflict "$start" "$end" || true)
    [ -z "$busy_port" ] || die "HY2 跳跃范围 $range 中的端口 $busy_port 已被系统占用"
    set_protocol_port hy2 "$start"
    PD_OPT_HY2_HOP="$count"
    PD_OPT_HY2_HOP_RANGE="$range"
}

validate_hy2_hop() {
    if [ -n "${PD_OPT_HY2_HOP_RANGE:-}" ]; then
        apply_hy2_hop_range "$PD_OPT_HY2_HOP_RANGE"
    fi
    [[ "$PD_OPT_HY2_HOP" =~ ^[0-9]+$ ]] || die "PD_HY2_HOP 必须是数字，当前: $PD_OPT_HY2_HOP"
    if [ "$PD_OPT_HY2_HOP" -ne 0 ] && [ "$PD_OPT_HY2_HOP" -lt 3 ]; then
        die "PD_HY2_HOP 只能为 0 或 >=3，当前: $PD_OPT_HY2_HOP"
    fi
    [ "$PD_OPT_HY2_HOP" -le 1000 ] || die "PD_HY2_HOP 最多 1000，避免防火墙规则过重"
}

setup_hy2_hop_rules() {
    local base_port="$1" hop_count="$2"
    [ "$hop_count" -ge 3 ] 2>/dev/null || return 0
    command -v nft >/dev/null 2>&1 || die "缺少 nft，无法配置 HY2 端口跳跃"
    local last_port=$((base_port + hop_count - 1))
    local nft_bin
    nft_bin=$(command -v nft)
    if nft list table inet pd_hy2_hop >/dev/null 2>&1; then
        if ! unit_is_pd_owned "$SYSTEMD_DIR/pd-hy2-hop.service"; then
            die "nft table inet pd_hy2_hop 已存在且所有权未知"
        fi
        nft delete table inet pd_hy2_hop || die "无法替换本脚本的旧 HY2 hop table"
    fi
    mkdir -p "$(pdir hy2)"
    atomic_write_file "$(pdir hy2)/hop.nft" 600 <<EOF || return 1
table inet pd_hy2_hop {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    udp dport ${base_port}-${last_port} redirect to :${base_port}
  }
}
EOF
    atomic_write_file "$SYSTEMD_DIR/pd-hy2-hop.service" 644 <<EOF || return 1
[Unit]
Description=PD-proxy: Hysteria2 port hopping nft rules
After=network.target
Before=hysteria2.service
PartOf=hysteria2.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${nft_bin} -f $(pdir hy2)/hop.nft
ExecStop=-${nft_bin} delete table inet pd_hy2_hop

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable pd-hy2-hop >/dev/null || die "启用 HY2 hop unit 失败"
    systemctl restart pd-hy2-hop || die "HY2 端口跳跃规则加载失败"
    state_set hy2 hop_owned 1 || die "记录 HY2 hop 所有权失败"
}

write_hy2_systemd() {
    local svc="$1" bin="$2" args="$3"
    atomic_write_file "$SYSTEMD_DIR/${svc}.service" 644 <<EOF
[Unit]
Description=PD-proxy: ${svc}
After=network.target pd-hy2-hop.service
Wants=pd-hy2-hop.service

[Service]
Type=simple
ExecStart=${bin} ${args}
Restart=always
RestartSec=5
LimitNOFILE=32768
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
RestrictAddressFamilies=AF_INET AF_INET6
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
}

clear_hy2_hop_rules() {
    local unit="$SYSTEMD_DIR/pd-hy2-hop.service" owned=false rc=0
    [ -f "$unit" ] && grep -q '^Description=PD-proxy:' "$unit" && owned=true
    if [ -e "$unit" ] || [ -L "$unit" ]; then
        [ ! -L "$unit" ] || { err "拒绝删除符号链接 unit: $unit"; return 1; }
        $owned || { err "拒绝删除非 PD-proxy 的 HY2 hop unit: $unit"; return 1; }
        systemctl disable --now pd-hy2-hop || rc=1
        rm -f "$unit" || rc=1
        systemctl daemon-reload || rc=1
    fi
    if command -v nft >/dev/null 2>&1 && nft list table inet pd_hy2_hop >/dev/null 2>&1; then
        if $owned || [ "$(state_get hy2 hop_owned 2>/dev/null || true)" = "1" ]; then
            nft delete table inet pd_hy2_hop || rc=1
        else
            err "拒绝删除所有权未知的 nft table inet pd_hy2_hop"
            rc=1
        fi
    fi
    [ "$rc" -eq 0 ] || { err "清理 HY2 端口跳跃资源失败"; return 1; }
}

verify_download() {
    local file="$1" label="$2" min_bytes="${3:-100000}"
    if [ ! -f "$file" ]; then
        die "$label 下载失败：文件不存在"
    fi
    local size
    size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo "0")
    if [ "$size" -lt "$min_bytes" ]; then
        die "$label 下载失败：文件大小异常（${size} bytes < ${min_bytes}）"
    fi
    # 验证可执行头（ELF magic = \x7fELF）
    if ! head -c 4 "$file" | grep -q $'\x7fELF'; then
        die "$label 损坏：不是有效的 ELF 二进制文件"
    fi
}

verify_port() {
    local port="$1" service="$2" transport="${3:-tcp}"
    sleep 2
    systemctl is-active --quiet "$service" 2>/dev/null || {
        err "服务 $service 未运行"
        return 1
    }
    if ! service_port_listening "$port" "$transport" "$service"; then
        err "端口 $port/$transport 未由服务 $service 的 MainPID 监听"
        warn "查看日志: journalctl -u $service -n 30 --no-pager"
        return 1
    fi
    info "端口 $port/${transport} 与服务 $service 验证通过 ✅"
}

verify_hy2_hop() {
    local port count end
    port="$1"; count="$2"; end=$((port + count - 1))
    verify_port "$port" hysteria2 udp || return 1
    systemctl is-active --quiet pd-hy2-hop 2>/dev/null || { err "HY2 hop unit 未运行"; return 1; }
    command -v nft >/dev/null 2>&1 || { err "HY2 hop 验证缺少 nft"; return 1; }
    nft list table inet pd_hy2_hop 2>/dev/null \
        | tr '\n' ' ' \
        | grep -Eq "udp dport ${port}-${end} redirect to :${port}([ ;]|$)" || {
            err "HY2 hop nft 规则与目标范围 ${port}-${end}/udp 不匹配"
            return 1
        }
}

verify_shadowtls_stack() {
    local ext_port="$1" int_port="$2"
    verify_port "$int_port" snell tcp || return 1
    verify_port "$ext_port" shadowtls-snell tcp || return 1
}

verify_running_protocol() {
    local proto="$1" key svc port transport public_svc stored_family inner_port hop
    key=$(pkey "$proto")
    svc=$(psvc "$proto")
    port=$(state_get "$key" port) || return 1
    [ -n "$port" ] || { err "$(pname "$proto") 端口状态缺失"; return 1; }

    if [ "$proto" = snell ] && [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ]; then
        inner_port=$(conf_value listen "$(pdir snell)/snell.conf" | sed 's/.*://')
        [ -n "$inner_port" ] || { err "Snell 内层监听端口缺失"; return 1; }
        verify_shadowtls_stack "$port" "$inner_port" || return 1
        public_svc=shadowtls-snell
    elif [ "$proto" = hy2 ]; then
        hop=$(state_get "$key" hop 2>/dev/null || true)
        if [ "${hop:-0}" -ge 3 ] 2>/dev/null; then
            verify_hy2_hop "$port" "$hop" || return 1
        else
            verify_port "$port" "$svc" udp || return 1
        fi
        public_svc="$svc"
    else
        transport=$(protocol_transport "$proto") || return 1
        verify_port "$port" "$svc" "$transport" || return 1
        public_svc="$svc"
    fi

    transport=$(protocol_transport "$proto") || return 1
    stored_family=$(state_get "$key" listen_family 2>/dev/null || true)
    [ -z "$stored_family" ] || PD_EFFECTIVE_LISTEN_FAMILY="$stored_family"
    [ -n "${PD_EFFECTIVE_LISTEN_FAMILY:-}" ] || PD_EFFECTIVE_LISTEN_FAMILY=auto
    verify_and_record_listen_families "$key" "$port" "$transport" "$public_svc"
}

save_iptables() {
    local tmp
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null || { err "持久化 iptables 规则失败"; return 1; }
    elif [ -d /etc/iptables ]; then
        tmp=$(mktemp /etc/iptables/.rules.v4.XXXXXX) || return 1
        if ! iptables-save > "$tmp" || ! mv -f "$tmp" /etc/iptables/rules.v4; then
            rm -f "$tmp"; err "写入 IPv4 防火墙持久化文件失败"; return 1
        fi
        if command -v ip6tables-save >/dev/null 2>&1; then
            tmp=$(mktemp /etc/iptables/.rules.v6.XXXXXX) || return 1
            if ! ip6tables-save > "$tmp" || ! mv -f "$tmp" /etc/iptables/rules.v6; then
                rm -f "$tmp"; err "写入 IPv6 防火墙持久化文件失败"; return 1
            fi
        fi
    fi
}

firewall_spec() {
    [ "$1" = "$2" ] && printf '%s' "$1" || printf '%s:%s' "$1" "$2"
}

ufw_rule_exists() {
    local rule="$1"
    ufw show added 2>/dev/null | grep -Fqx "ufw allow $rule"
}

firewall_add() {
    local key="$1" start="$2" end="$3" transport="$4" spec owned="" backend="none"
    validate_port "$start" "防火墙起始端口"
    validate_port "$end" "防火墙结束端口"
    [ "$end" -ge "$start" ] || { err "防火墙端口范围无效: $start-$end"; return 1; }
    case "$transport" in tcp|udp) ;; *) err "未知传输层: $transport"; return 1 ;; esac
    spec=$(firewall_spec "$start" "$end")
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        backend=ufw
        if ! ufw_rule_exists "${spec}/${transport}"; then
            ufw allow "${spec}/${transport}" >/dev/null || { err "添加 ufw 规则 ${spec}/${transport} 失败"; return 1; }
            owned=ufw
        fi
    elif command -v iptables >/dev/null 2>&1; then
        backend=iptables
        if ! iptables -C INPUT -p "$transport" --dport "$spec" -j ACCEPT >/dev/null 2>&1; then
            iptables -I INPUT -p "$transport" --dport "$spec" -j ACCEPT || { err "添加 iptables 规则失败"; return 1; }
            owned=iptables4
        fi
        if command -v ip6tables >/dev/null 2>&1 && ! ip6tables -C INPUT -p "$transport" --dport "$spec" -j ACCEPT >/dev/null 2>&1; then
            if ! ip6tables -I INPUT -p "$transport" --dport "$spec" -j ACCEPT; then
                [ "$owned" = iptables4 ] && iptables -D INPUT -p "$transport" --dport "$spec" -j ACCEPT >/dev/null 2>&1
                err "添加 ip6tables 规则失败"; return 1
            fi
            owned="${owned:+$owned,}iptables6"
        fi
        if [ -n "$owned" ] && ! save_iptables; then
            [[ ",$owned," == *,iptables6,* ]] && ip6tables -D INPUT -p "$transport" --dport "$spec" -j ACCEPT >/dev/null 2>&1
            [[ ",$owned," == *,iptables4,* ]] && iptables -D INPUT -p "$transport" --dport "$spec" -j ACCEPT >/dev/null 2>&1
            return 1
        fi
    else
        warn "未检测到活动的 ufw/iptables，请确认云防火墙已放行 ${spec}/${transport}"
    fi
    # 单字段先原子记录待提交所有权；后续任一状态字段失败时，事务仍能精确撤销规则。
    if ! state_set "$key" fw_pending "${backend},${spec},${transport},${owned}" \
        || ! state_set "$key" fw_backend "$backend" \
        || ! state_set "$key" fw_spec "$spec" \
        || ! state_set "$key" fw_proto "$transport" \
        || ! state_set "$key" fw_owned "$owned" \
        || ! state_set "$key" fw_pending ""; then
        local cleanup_rc=0
        [ "$owned" != ufw ] || ufw delete allow "${spec}/${transport}" >/dev/null || cleanup_rc=1
        if [[ ",$owned," == *,iptables6,* ]]; then ip6tables -D INPUT -p "$transport" --dport "$spec" -j ACCEPT >/dev/null || cleanup_rc=1; fi
        if [[ ",$owned," == *,iptables4,* ]]; then iptables -D INPUT -p "$transport" --dport "$spec" -j ACCEPT >/dev/null || cleanup_rc=1; fi
        if [[ "$owned" == *iptables* ]]; then save_iptables || cleanup_rc=1; fi
        [ "$cleanup_rc" -eq 0 ] || err "撤销新增防火墙规则失败，事务将再次清理"
        err "记录防火墙规则所有权失败"
        return 1
    fi
}

firewall_remove_owned() {
    local key="$1" backend spec transport owned pending rc=0
    backend=$(state_get "$key" fw_backend) || return 1
    spec=$(state_get "$key" fw_spec) || return 1
    transport=$(state_get "$key" fw_proto) || return 1
    owned=$(state_get "$key" fw_owned) || return 1
    pending=$(state_get "$key" fw_pending) || return 1
    if [ -n "$pending" ]; then
        IFS=, read -r backend spec transport owned <<< "$pending"
    fi
    if [ -z "$owned" ]; then
        [ -n "$backend" ] || {
            err "旧状态缺少防火墙所有权记录，拒绝猜测或静默遗留规则"
            return 1
        }
        return 0
    fi
    case "$backend" in
        ufw)
            [ "$owned" = ufw ] || { err "ufw 所有权记录无效"; return 1; }
            command -v ufw >/dev/null 2>&1 || { err "缺少 ufw，无法删除已记录规则"; return 1; }
            if ufw_rule_exists "${spec}/${transport}"; then
                ufw delete allow "${spec}/${transport}" >/dev/null || rc=1
            fi ;;
        iptables)
            command -v iptables >/dev/null 2>&1 || { err "缺少 iptables，无法删除已记录规则"; return 1; }
            if [[ ",$owned," == *,iptables6,* ]] && ! command -v ip6tables >/dev/null 2>&1; then
                err "缺少 ip6tables，无法删除已记录 IPv6 规则"; return 1
            fi
            if [[ ",$owned," == *,iptables4,* ]] && iptables -C INPUT -p "$transport" --dport "$spec" -j ACCEPT >/dev/null 2>&1; then
                iptables -D INPUT -p "$transport" --dport "$spec" -j ACCEPT || rc=1
            fi
            if [[ ",$owned," == *,iptables6,* ]] && command -v ip6tables >/dev/null 2>&1 \
                && ip6tables -C INPUT -p "$transport" --dport "$spec" -j ACCEPT >/dev/null 2>&1; then
                ip6tables -D INPUT -p "$transport" --dport "$spec" -j ACCEPT || rc=1
            fi
            [ "$rc" -ne 0 ] || save_iptables || rc=1 ;;
        *) err "未知防火墙后端所有权记录: $backend"; return 1 ;;
    esac
    [ "$rc" -eq 0 ] || { err "删除本脚本创建的防火墙规则 ${spec}/${transport} 失败"; return 1; }
    state_set "$key" fw_owned "" || return 1
    state_set "$key" fw_pending ""
}

firewall_restore_owned() {
    local key="$1" backend spec transport owned rc=0
    backend=$(state_get "$key" fw_backend) || return 1
    owned=$(state_get "$key" fw_owned) || return 1
    [ -n "$owned" ] || return 0
    spec=$(state_get "$key" fw_spec) || return 1
    transport=$(state_get "$key" fw_proto) || return 1
    case "$backend" in
        ufw)
            [ "$owned" = ufw ] || return 1
            command -v ufw >/dev/null 2>&1 || return 1
            if ! ufw_rule_exists "${spec}/${transport}"; then
                ufw allow "${spec}/${transport}" >/dev/null || rc=1
            fi ;;
        iptables)
            command -v iptables >/dev/null 2>&1 || return 1
            if [[ ",$owned," == *,iptables6,* ]] && ! command -v ip6tables >/dev/null 2>&1; then return 1; fi
            if [[ ",$owned," == *,iptables4,* ]] && ! iptables -C INPUT -p "$transport" --dport "$spec" -j ACCEPT >/dev/null 2>&1; then
                iptables -I INPUT -p "$transport" --dport "$spec" -j ACCEPT || rc=1
            fi
            if [[ ",$owned," == *,iptables6,* ]] && ! ip6tables -C INPUT -p "$transport" --dport "$spec" -j ACCEPT >/dev/null 2>&1; then
                ip6tables -I INPUT -p "$transport" --dport "$spec" -j ACCEPT || rc=1
            fi
            [ "$rc" -ne 0 ] || save_iptables || rc=1 ;;
        *) return 1 ;;
    esac
    [ "$rc" -eq 0 ] || { err "恢复防火墙规则 ${spec}/${transport} 失败"; return 1; }
}

# 兼容旧内部调用；没有所有权记录时绝不猜测并删除用户规则。
add_firewall() { firewall_add "${2:-legacy}" "$1" "$1" "${3:-tcp}"; }
add_firewall_range() { firewall_add "${3:-legacy}" "$1" "$2" "${4:-tcp}"; }
del_firewall() { firewall_remove_owned "${2:-legacy}"; }
del_firewall_range() { firewall_remove_owned "${3:-legacy}"; }

install_deps() {
    local proto="${1:-}"
    local missing=""
    if [ "$proto" = "hy2" ] && [ -n "${PD_OPT_HY2_HOP_RANGE:-}" ]; then
        validate_hy2_hop
    fi
    command -v curl >/dev/null 2>&1 || missing="$missing curl"
    [ -f /etc/ssl/certs/ca-certificates.crt ] || missing="$missing ca-certificates"
    command -v openssl >/dev/null 2>&1 || missing="$missing openssl"
    command -v ss >/dev/null 2>&1 || missing="$missing iproute2"
    case "$proto" in
        snell|vless|anytls) command -v unzip >/dev/null 2>&1 || missing="$missing unzip" ;;
    esac
    if [ "$proto" = "hy2" ] && [ "${PD_OPT_HY2_HOP:-0}" -ge 3 ] 2>/dev/null; then
        command -v nft >/dev/null 2>&1 || missing="$missing nftables"
    fi
    [ -z "$missing" ] && return 0
    info "安装依赖: $missing"
    apt-get update -qq || die "apt-get update 失败，请检查网络"
    apt-get install -y -qq $missing >/dev/null || die "依赖安装失败"
}

install_qrencode() {
    if command -v qrencode >/dev/null 2>&1; then
        return 0
    fi
    if [ "$PD_OPT_INSTALL_QR" != "1" ]; then
        return 0
    fi
    info "安装 qrencode..."
    apt-get update -qq 2>/dev/null || true
    apt-get install -y -qq qrencode >/dev/null 2>&1 || warn "qrencode 安装失败，跳过二维码生成"
    return 0
}

gen_qr() {
    command -v qrencode >/dev/null 2>&1 || return 0
    echo "$1" | qrencode -t ANSIUTF8 -m 1 -s 1 -r /dev/stdin 2>/dev/null || true
    return 0
}

# ============================================================
# 状态管理（纯 bash flat file，零外部依赖）
# 格式: <key> port=<port> status=<installed|uninstalled> version=<ver>
# ============================================================

state_get() {
    local key="$1" field="$2"
    [ ! -L "$STATE_FILE" ] || { err "拒绝读取符号链接状态文件: $STATE_FILE"; return 1; }
    [ -f "$STATE_FILE" ] || { echo ""; return; }
    local line
    line=$(awk -v key="$key" '$1 == key { print; exit }' "$STATE_FILE") || return 1
    [ -n "$line" ] || { echo ""; return; }
    echo "$line" | state_field_from_line "$field" || echo ""
}

state_get_from_file() {
    local file="$1" key="$2" field="$3" line
    [ -f "$file" ] || { echo ""; return 0; }
    line=$(awk -v key="$key" '$1 == key { print; exit }' "$file") || return 1
    [ -n "$line" ] || { echo ""; return 0; }
    printf '%s\n' "$line" | state_field_from_line "$field"
}

state_set() {
    local key="$1" field="$2" value="$3"
    state_path_prepare || return 1
    local line="" tmp
    [ -f "$STATE_FILE" ] && line=$(awk -v key="$key" '$1 == key { print; exit }' "$STATE_FILE")
    if echo "$line" | grep -q "${field}="; then
        line=$(echo "$line" | awk -v f="$field" -v v="$value" '{ for (i=1; i<=NF; i++) if ($i ~ "^" f "=") $i=f "=" v; print }')
    else
        if [ -n "$line" ]; then
            line="${line} ${field}=${value}"
        else
            line="${key} ${field}=${value}"
        fi
    fi
    line=$(echo "$line" | sed 's/^ *//;s/ *$//')
    tmp=$(mktemp "$BASE_DIR/.state.XXXXXX") || { err "创建状态临时文件失败"; return 1; }
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    if [ -f "$STATE_FILE" ]; then
        awk -v key="$key" '$1 != key { print }' "$STATE_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$STATE_FILE" || { rm -f "$tmp"; err "原子更新状态文件失败"; return 1; }
    chmod 600 "$STATE_FILE" || return 1
    [ "$(id -u)" != 0 ] || chown root:root "$STATE_FILE" || return 1
}

state_set_fields() {
    local key="$1" line="" tmp assignment field value
    shift
    [ "$#" -gt 0 ] || return 1
    state_path_prepare || return 1
    [ -f "$STATE_FILE" ] && line=$(awk -v key="$key" '$1 == key { print; exit }' "$STATE_FILE")
    for assignment in "$@"; do
        field=${assignment%%=*}
        value=${assignment#*=}
        [[ "$field" =~ ^[A-Za-z0-9_]+$ ]] && [[ "$value" != *[[:space:]]* ]] \
            || { err "状态字段格式无效: $assignment"; return 1; }
        if printf '%s\n' "$line" | tr ' ' '\n' | grep -q "^${field}="; then
            line=$(printf '%s\n' "$line" | awk -v f="$field" -v v="$value" \
                '{ for (i=1; i<=NF; i++) if ($i ~ "^" f "=") $i=f "=" v; print }') || return 1
        elif [ -n "$line" ]; then
            line="$line $field=$value"
        else
            line="$key $field=$value"
        fi
    done
    line=$(printf '%s\n' "$line" | sed 's/^ *//;s/ *$//')
    tmp=$(mktemp "$BASE_DIR/.state.XXXXXX") || { err "创建状态临时文件失败"; return 1; }
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    if [ "$(id -u)" = 0 ]; then
        chown root:root "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    if [ -f "$STATE_FILE" ]; then
        awk -v key="$key" '$1 != key { print }' "$STATE_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$STATE_FILE" || { rm -f "$tmp"; err "原子更新状态文件失败"; return 1; }
}

state_del() {
    local key="$1"
    state_path_prepare || return 1
    [ -f "$STATE_FILE" ] || return 0
    local tmp
    tmp=$(mktemp "$BASE_DIR/.state.XXXXXX") || { err "创建状态临时文件失败"; return 1; }
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    awk -v key="$key" '$1 != key { print }' "$STATE_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$STATE_FILE" || { rm -f "$tmp"; err "原子更新状态文件失败"; return 1; }
    chmod 600 "$STATE_FILE" || return 1
    [ "$(id -u)" != 0 ] || chown root:root "$STATE_FILE" || return 1
}

state_path_prepare() {
    assert_base_dir_safe || return 1
    [ ! -L "$BASE_DIR" ] || { err "拒绝使用符号链接状态目录: $BASE_DIR"; return 1; }
    mkdir -p "$BASE_DIR" || { err "无法创建状态目录: $BASE_DIR"; return 1; }
    chmod 755 "$BASE_DIR" || return 1
    [ "$(id -u)" != 0 ] || chown root:root "$BASE_DIR" || return 1
    if [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ]; then
        chmod 600 "$STATE_FILE" || return 1
        [ "$(id -u)" != 0 ] || chown root:root "$STATE_FILE" || return 1
    fi
    [ ! -L "$STATE_FILE" ] || { err "拒绝写入符号链接状态文件: $STATE_FILE"; return 1; }
    [ ! -e "$STATE_FILE" ] || [ -f "$STATE_FILE" ] || { err "状态路径不是普通文件: $STATE_FILE"; return 1; }
}

assert_base_dir_safe() {
    [ ! -L "$BASE_DIR" ] || { err "拒绝使用符号链接 PD 目录: $BASE_DIR"; return 1; }
    [ ! -L "$STATE_FILE" ] || { err "拒绝使用符号链接状态文件: $STATE_FILE"; return 1; }
    [ ! -e "$STATE_FILE" ] || [ -f "$STATE_FILE" ] || { err "状态路径不是普通文件: $STATE_FILE"; return 1; }
    [ -d "$BASE_DIR" ] || return 0
    [ -f "$STATE_FILE" ] || [ -f "$BASE_DIR/.pd-proxy-owned" ] \
        || { [ -f "$BASE_DIR/install.sh" ] && grep -q '^VERSION=' "$BASE_DIR/install.sh" 2>/dev/null; } \
        || ! find "$BASE_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q . \
        || { err "发现状态文件外的非空同名目录，拒绝覆盖: $BASE_DIR"; return 1; }
}

state_installed() {
    local key="$1"
    local s
    s=$(state_get "$key" "status")
    [ "$s" = "installed" ] && return 0 || return 1
}

get_all_ports() {
    [ -f "$STATE_FILE" ] || return 0
    awk '
        {
            port=""; hop=1; status=""
            for (i=2; i<=NF; i++) {
                split($i, kv, "=")
                if (kv[1] == "port") port=kv[2]
                else if (kv[1] == "hop") hop=kv[2]
                else if (kv[1] == "status") status=kv[2]
            }
            if (status != "installed" || port == "") next
            if (hop !~ /^[0-9]+$/ || hop < 1) hop=1
            for (p=port; p<port+hop; p++) print p
        }
    ' "$STATE_FILE"
}

state_port_range_conflict() {
    local start="$1" end="$2" exclude_key="${3:-}"
    [ -f "$STATE_FILE" ] || return 1
    awk -v start="$start" -v end="$end" -v exclude="$exclude_key" '
        {
            key=$1; port=""; hop=1; status=""
            for (i=2; i<=NF; i++) {
                split($i, kv, "=")
                if (kv[1] == "port") port=kv[2]
                else if (kv[1] == "hop") hop=kv[2]
                else if (kv[1] == "status") status=kv[2]
            }
            if (key == exclude || status != "installed" || port == "") next
            if (hop !~ /^[0-9]+$/ || hop < 1) hop=1
            other_start=port + 0
            other_end=other_start + hop - 1
            if (start <= other_end && end >= other_start) found=1
        }
        END { exit found ? 0 : 1 }
    ' "$STATE_FILE"
}

# ============================================================
# 协议注册表（数据驱动核心 — 新增协议只需加一块定义）
# ============================================================

# 协议元数据: key, name, dir, bin, service, disk_mb
declare -A PROTO=()

register_protocols() {
    # ---- Snell v5 ----
    PROTO[snell_key]="snell"
    PROTO[snell_name]="Snell v5"
    PROTO[snell_dir]="/opt/snell"
    PROTO[snell_bin]="/opt/snell/snell-server"
    PROTO[snell_service]="snell"
    PROTO[snell_disk]="20"

    # ---- Hysteria2 ----
    PROTO[hy2_key]="hy2"
    PROTO[hy2_name]="Hysteria2"
    PROTO[hy2_dir]="/opt/hysteria2"
    PROTO[hy2_bin]="/opt/hysteria2/hysteria"
    PROTO[hy2_service]="hysteria2"
    PROTO[hy2_disk]="30"

    # ---- VLESS Reality ----
    PROTO[vless_key]="vless"
    PROTO[vless_name]="VLESS Reality"
    PROTO[vless_dir]="/opt/xray"
    PROTO[vless_bin]="/opt/xray/xray"
    PROTO[vless_service]="xray"
    PROTO[vless_disk]="60"

    # ---- AnyTLS ----
    PROTO[anytls_key]="anytls"
    PROTO[anytls_name]="AnyTLS"
    PROTO[anytls_dir]="/opt/anytls"
    PROTO[anytls_bin]="/opt/anytls/anytls-server"
    PROTO[anytls_service]="anytls"
    PROTO[anytls_disk]="20"
}

# 获取协议元数据
pkey()   { echo "${PROTO[${1}_key]}"; }
pname()  { echo "${PROTO[${1}_name]}"; }
pdir()   { echo "${PROTO[${1}_dir]}"; }
pbin()   { echo "${PROTO[${1}_bin]}"; }
psvc()   { echo "${PROTO[${1}_service]}"; }
pdisk()  { echo "${PROTO[${1}_disk]}"; }

ALL_PROTOS="snell hy2 vless anytls"

# 协议名归一化（别名 → 标准名）
resolve_proto() {
    case "${1}" in
        hy2|hysteria2) echo "hy2" ;;
        vless|xray)     echo "vless" ;;
        snell|anytls)   echo "${1}" ;;
        *)              return 1 ;;
    esac
}

unit_is_pd_owned() {
    local unit="$1"
    [ -f "$unit" ] && [ ! -L "$unit" ] && grep -q '^Description=PD-proxy:' "$unit"
}

assert_unit_name_available() {
    local svc="$1" candidate
    for candidate in "$SYSTEMD_DIR/${svc}.service" "/lib/systemd/system/${svc}.service" "/usr/lib/systemd/system/${svc}.service"; do
        [ ! -e "$candidate" ] && [ ! -L "$candidate" ] || {
            err "发现状态文件外的同名 unit，拒绝覆盖: $candidate"
            return 1
        }
    done
}

assert_install_target_available() {
    local proto="$1" dir unit
    dir=$(pdir "$proto")
    unit="$SYSTEMD_DIR/$(psvc "$proto").service"
    [ ! -e "$dir" ] && [ ! -L "$dir" ] || { err "发现状态文件外的同名目录，拒绝覆盖: $dir"; return 1; }
    assert_unit_name_available "$(psvc "$proto")" || return 1
    if [ "$proto" = snell ]; then
        [ ! -e /opt/shadowtls ] && [ ! -L /opt/shadowtls ] || { err "发现状态文件外的 /opt/shadowtls，拒绝覆盖"; return 1; }
        assert_unit_name_available shadowtls-snell || return 1
    fi
    if [ "$proto" = hy2 ] && [ "${PD_OPT_HY2_HOP:-0}" -ge 3 ] 2>/dev/null; then
        assert_unit_name_available pd-hy2-hop || return 1
        if command -v nft >/dev/null 2>&1 && nft list table inet pd_hy2_hop >/dev/null 2>&1; then
            err "发现所有权未知的 nft table inet pd_hy2_hop，拒绝覆盖"
            return 1
        fi
    fi
}

assert_owned_resources_safe() {
    local proto="$1" dir unit candidate svc
    dir=$(pdir "$proto")
    svc=$(psvc "$proto")
    unit="$SYSTEMD_DIR/${svc}.service"
    [ ! -L "$dir" ] || { err "协议目录已变为符号链接，拒绝操作: $dir"; return 1; }
    if [ -e "$dir" ] && [ ! -f "$dir/.pd-proxy-owned" ]; then
        if state_installed "$(pkey "$proto")" && unit_is_pd_owned "$unit" && [ -x "$(pbin "$proto")" ]; then
            warn "迁移旧版 $(pname "$proto") 资源所有权标记"
            printf '%s\n' "PD-proxy owned resource" | atomic_write_file "$dir/.pd-proxy-owned" 600 || return 1
        else
            err "协议目录缺少 PD-proxy 所有权标记，拒绝操作: $dir"
            return 1
        fi
    fi
    [ ! -L "$unit" ] || { err "unit 已变为符号链接，拒绝操作: $unit"; return 1; }
    [ ! -e "$unit" ] || unit_is_pd_owned "$unit" || { err "unit 所有权不再属于 PD-proxy: $unit"; return 1; }
    for candidate in "/lib/systemd/system/${svc}.service" "/usr/lib/systemd/system/${svc}.service"; do
        [ ! -e "$candidate" ] && [ ! -L "$candidate" ] || {
            err "发现后来出现的同名系统 unit，拒绝继续以免覆盖: $candidate"
            return 1
        }
    done
    if [ "$proto" = snell ] && { [ -e /opt/shadowtls ] || [ -L /opt/shadowtls ] \
        || [ -e "$SYSTEMD_DIR/shadowtls-snell.service" ] || [ -L "$SYSTEMD_DIR/shadowtls-snell.service" ]; }; then
        [ ! -L /opt/shadowtls ] || { err "ShadowTLS 目录已变为符号链接"; return 1; }
        unit_is_pd_owned "$SYSTEMD_DIR/shadowtls-snell.service" \
            || { err "ShadowTLS unit 所有权无法确认"; return 1; }
        if [ -d /opt/shadowtls ] && [ ! -f /opt/shadowtls/.pd-proxy-owned ] \
            && state_installed snell && [ -x /opt/shadowtls/shadow-tls ]; then
            warn "迁移旧版 ShadowTLS 资源所有权标记"
            printf '%s\n' "PD-proxy owned resource" | atomic_write_file /opt/shadowtls/.pd-proxy-owned 600 || return 1
        fi
        [ -d /opt/shadowtls ] && [ -f /opt/shadowtls/.pd-proxy-owned ] \
            || { err "ShadowTLS 目录所有权无法确认"; return 1; }
    fi
}

_PD_TXN_DIR=""
_PD_TXN_PROTO=""
transaction_begin() {
    local proto="$1" dir svc path label active enabled
    local -a tx_services=()
    [ -z "$_PD_TXN_DIR" ] || { err "不支持嵌套事务"; return 1; }
    assert_owned_resources_safe "$proto" || return 1
    mktemp_dir_pd _PD_TXN_DIR
    _PD_TXN_PROTO="$proto"
    dir=$(pdir "$proto"); svc=$(psvc "$proto")
    mkdir -p "$_PD_TXN_DIR/items" || return 1
    for label in proto_dir shadow_dir proto_unit shadow_unit hop_unit; do
        path=""
        case "$label" in
            proto_dir) path="$dir" ;;
            shadow_dir) [ "$proto" = snell ] && path=/opt/shadowtls ;;
            proto_unit) path="$SYSTEMD_DIR/${svc}.service" ;;
            shadow_unit) [ "$proto" = snell ] && path="$SYSTEMD_DIR/shadowtls-snell.service" ;;
            hop_unit) [ "$proto" = hy2 ] && path="$SYSTEMD_DIR/pd-hy2-hop.service" ;;
        esac
        [ -n "$path" ] || continue
        if [ -e "$path" ] || [ -L "$path" ]; then
            [ ! -L "$path" ] || { err "事务拒绝备份符号链接: $path"; return 1; }
            cp -a "$path" "$_PD_TXN_DIR/items/$label" || { err "事务备份失败: $path"; return 1; }
            printf '%s\t%s\n' "$label" "$path" >> "$_PD_TXN_DIR/manifest" || return 1
        fi
    done
    if [ -f "$STATE_FILE" ]; then
        cp -p "$STATE_FILE" "$_PD_TXN_DIR/state" || { err "状态备份失败，已停止"; return 1; }
    else
        : > "$_PD_TXN_DIR/no-state" || return 1
    fi
    : > "$_PD_TXN_DIR/services" || return 1
    tx_services=("$(psvc "$proto")")
    [ "$proto" = snell ] && tx_services+=(shadowtls-snell)
    [ "$proto" = hy2 ] && tx_services+=(pd-hy2-hop)
    for svc in "${tx_services[@]}"; do
        active=0; enabled=0
        systemctl is-active --quiet "$svc" 2>/dev/null && active=1
        systemctl is-enabled --quiet "$svc" 2>/dev/null && enabled=1
        printf '%s %s %s\n' "$svc" "$active" "$enabled" >> "$_PD_TXN_DIR/services" || return 1
    done
}

transaction_restore_state() {
    local tmp
    state_path_prepare || return 1
    if [ -f "$_PD_TXN_DIR/state" ]; then
        tmp=$(mktemp "$BASE_DIR/.state.XXXXXX") || return 1
        cp -p "$_PD_TXN_DIR/state" "$tmp" || { rm -f "$tmp"; return 1; }
        mv -f "$tmp" "$STATE_FILE" || { rm -f "$tmp"; return 1; }
    else
        rm -f "$STATE_FILE" || return 1
    fi
}

transaction_rollback() {
    local rc=0 label path svc active enabled dir
    local key cur_fw old_fw cur_owned cur_pending
    local -a tx_services=() tx_paths=()
    [ -n "$_PD_TXN_DIR" ] || return 1
    err "操作失败，正在恢复事务前状态..."
    key=$(pkey "$_PD_TXN_PROTO")
    cur_owned=$(state_get "$key" fw_owned 2>/dev/null || true)
    cur_pending=$(state_get "$key" fw_pending 2>/dev/null || true)
    cur_fw="$(state_get "$key" fw_backend 2>/dev/null || true)|$(state_get "$key" fw_spec 2>/dev/null || true)|$(state_get "$key" fw_proto 2>/dev/null || true)|${cur_owned}|${cur_pending}"
    old_fw="$(state_get_from_file "$_PD_TXN_DIR/state" "$key" fw_backend)|$(state_get_from_file "$_PD_TXN_DIR/state" "$key" fw_spec)|$(state_get_from_file "$_PD_TXN_DIR/state" "$key" fw_proto)|$(state_get_from_file "$_PD_TXN_DIR/state" "$key" fw_owned)|$(state_get_from_file "$_PD_TXN_DIR/state" "$key" fw_pending)"
    if { [ -n "$cur_owned" ] || [ -n "$cur_pending" ]; } && [ "$cur_fw" != "$old_fw" ]; then
        firewall_remove_owned "$key" || rc=1
    fi
    tx_services=("$(psvc "$_PD_TXN_PROTO")")
    [ "$_PD_TXN_PROTO" = snell ] && tx_services+=(shadowtls-snell)
    [ "$_PD_TXN_PROTO" = hy2 ] && tx_services+=(pd-hy2-hop)
    for svc in "${tx_services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc" >/dev/null 2>&1 || rc=1
        fi
    done
    dir=$(pdir "$_PD_TXN_PROTO")
    tx_paths=("$dir" "$SYSTEMD_DIR/$(psvc "$_PD_TXN_PROTO").service")
    [ "$_PD_TXN_PROTO" = snell ] && tx_paths+=(/opt/shadowtls "$SYSTEMD_DIR/shadowtls-snell.service")
    [ "$_PD_TXN_PROTO" = hy2 ] && tx_paths+=("$SYSTEMD_DIR/pd-hy2-hop.service")
    for path in "${tx_paths[@]}"; do
        if [ -L "$path" ]; then
            err "回滚拒绝删除意外符号链接: $path"; rc=1
        elif [ -e "$path" ]; then
            rm -rf -- "$path" || rc=1
        fi
    done
    if [ -f "$_PD_TXN_DIR/manifest" ]; then
        while IFS=$'\t' read -r label path; do
            if [ -L "$path" ]; then
                err "回滚拒绝覆盖意外符号链接: $path"; rc=1; continue
            fi
            cp -a "$_PD_TXN_DIR/items/$label" "$path" || rc=1
        done < "$_PD_TXN_DIR/manifest"
    fi
    transaction_restore_state || rc=1
    systemctl daemon-reload >/dev/null 2>&1 || rc=1
    firewall_restore_owned "$key" || rc=1
    while read -r svc active enabled; do
        if [ "$enabled" = 1 ]; then
            systemctl enable "$svc" >/dev/null 2>&1 || rc=1
        elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            systemctl disable "$svc" >/dev/null 2>&1 || rc=1
        fi
        if [ "$active" = 1 ]; then
            systemctl start "$svc" >/dev/null 2>&1 || rc=1
        elif systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc" >/dev/null 2>&1 || rc=1
        fi
    done < "$_PD_TXN_DIR/services"
    _PD_TXN_DIR=""; _PD_TXN_PROTO=""
    [ "$rc" -eq 0 ] && info "已恢复事务前状态" || err "回滚不完整，请立即检查本机资源"
    return "$rc"
}

transaction_commit() {
    [ -n "$_PD_TXN_DIR" ] || return 1
    rm -rf -- "$_PD_TXN_DIR" || return 1
    _PD_TXN_DIR=""; _PD_TXN_PROTO=""
}

transaction_discard_unstarted() {
    [ -z "$_PD_TXN_DIR" ] || rm -rf -- "$_PD_TXN_DIR"
    _PD_TXN_DIR=""; _PD_TXN_PROTO=""
}

transaction_run() {
    local rc had_errexit=0 tmp_start=${#_PD_TMPFILES[@]}
    [[ $- == *e* ]] && had_errexit=1
    set +e
    (
        trap 'cleanup_tmpfiles_from "$tmp_start"' EXIT
        set -e
        "$@"
    )
    rc=$?
    if [ "$rc" -ne 0 ]; then
        transaction_rollback || true
        [ "$had_errexit" -eq 0 ] || set -e
        return "$rc"
    fi
    transaction_commit || rc=$?
    [ "$had_errexit" -eq 0 ] || set -e
    return "$rc"
}

# ============================================================
# systemd 辅助
# ============================================================

write_systemd() {
    local svc="$1" bin="$2" args="$3" mode=644 identity=""
    if [ "$svc" = anytls ]; then
        mode=600
        identity=$'DynamicUser=yes\nAmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE\nPrivateDevices=yes\nProtectKernelTunables=yes\nProtectKernelModules=yes\nProtectControlGroups=yes\nRestrictSUIDSGID=yes'
    fi
    atomic_write_file "$SYSTEMD_DIR/${svc}.service" "$mode" <<EOF
[Unit]
Description=PD-proxy: ${svc}
After=network.target

[Service]
Type=simple
${identity}
ExecStart=${bin} ${args}
Restart=always
RestartSec=5
LimitNOFILE=32768
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
RestrictAddressFamilies=AF_INET AF_INET6
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
}

register_and_start() {
    local svc="$1"
    systemctl daemon-reload
    systemctl enable "$svc" >/dev/null || die "systemctl enable $svc 失败"
    systemctl restart "$svc" || die "启动 $svc 失败: journalctl -u $svc -n 20"
}

# ============================================================
# 输出模板
# ============================================================

output_header() {
    echo ""
    echo -e "${BOLD}══════════════════════════════${RESET}"
    echo -e "${BOLD}  $1${RESET}"
    echo -e "${BOLD}══════════════════════════════${RESET}"
    echo -e "端口:   ${GREEN}$2${RESET}"
}

output_footer() { echo -e "${BOLD}══════════════════════════════${RESET}"; }

# ============================================================
# 协议实现
# ============================================================

# ---- Snell v5 ----
snell_get_version() {
    local v cache_file="$BASE_DIR/.snell-version-${ARCH}"
    mkdir -p "$BASE_DIR"
    if [ -n "${PD_SNELL_VERSION:-}" ]; then
        [[ "$PD_SNELL_VERSION" =~ ^v5\.[0-9]+\.[0-9]+[a-z0-9]*$ ]] || die "PD_SNELL_VERSION 格式无效，应类似 v5.0.1"
        echo "$PD_SNELL_VERSION"
        return 0
    fi
    # 1. 从 Snell KB/手册抓取最新版。Snell 没有官方 API，文档页是默认权威来源。
    # 默认 6 秒内完成：成功则保证最新版；失败则进入可用性 fallback。
    v=$(snell_manual_html \
        | sed -n 's/.*snell-server-v\(5\.[0-9][0-9]*\.[0-9][0-9]*[a-z0-9]*\)-linux-.*/\1/p; s/^### v\(5\.[0-9][0-9]*\.[0-9][0-9]*[a-z0-9]*\).*/\1/p' \
        | grep -v 'b' | head -1 || true)
    if [ -n "$v" ]; then
        printf '%s\n' "v${v}" | atomic_write_file "$cache_file" 600
        echo "v${v}"
        return 0
    fi

    # 2. 权威源不可达时，默认进入可用性 fallback：HEAD 探测当前 release 目录中可下载的最高版本。
    # 这能保证可用和尽量新；如必须严格权威最新版，设置 PD_STRICT_LATEST=1。
    if [ "${PD_STRICT_LATEST:-0}" = "1" ]; then
        err "$(snell_strict_latest_msg 5)"
        return 1
    fi
    warn "无法快速读取 Snell KB/手册，改用下载源探测可用版本；这会保证可用并尽量新，但不是严格权威最新版" >&2
    v=$(snell_probe_latest 5 || true)
    if [ -n "$v" ]; then
        printf '%s\n' "$v" | atomic_write_file "$cache_file" 600
        echo "$v"
        return 0
    fi

    if snell_cache_get 5 "$cache_file" >/dev/null 2>&1; then
        warn "下载源探测失败，使用上次成功缓存版本" >&2
        snell_cache_get 5 "$cache_file"
        return 0
    fi

    err "Snell 可用版本检测失败，请检查网络或手动指定: PD_SNELL_VERSION=v5.x.x"
    return 1
}

snell_v4_get_version() {
    local v cache_file="$BASE_DIR/.snell-v4-version-${ARCH}"
    mkdir -p "$BASE_DIR"
    # 1. 从 Snell KB/手册抓取最新版。Snell 没有官方 API，文档页是默认权威来源。
    # 默认 6 秒内完成：成功则保证最新版；失败则进入可用性 fallback。
    v=$(snell_manual_html \
        | sed -n 's/.*snell-server-v\(4\.[0-9][0-9]*\.[0-9][0-9]*[a-z0-9]*\)-linux-.*/\1/p; s/^### v\(4\.[0-9][0-9]*\.[0-9][0-9]*[a-z0-9]*\).*/\1/p' \
        | grep -v 'b' | head -1 || true)
    if [ -n "$v" ]; then
        printf '%s\n' "v${v}" | atomic_write_file "$cache_file" 600
        echo "v${v}"
        return 0
    fi

    if [ "${PD_STRICT_LATEST:-0}" = "1" ]; then
        err "$(snell_strict_latest_msg 4)"
        return 1
    fi
    warn "无法快速读取 Snell KB/手册，改用下载源探测 Snell v4 可用版本；这会保证可用并尽量新，但不是严格权威最新版" >&2
    v=$(snell_probe_latest 4 || true)
    if [ -n "$v" ]; then
        printf '%s\n' "$v" | atomic_write_file "$cache_file" 600
        echo "$v"
        return 0
    fi

    if snell_cache_get 4 "$cache_file" >/dev/null 2>&1; then
        warn "下载源探测失败，使用上次成功缓存版本" >&2
        snell_cache_get 4 "$cache_file"
        return 0
    fi

    err "Snell v4 可用版本检测失败，请检查网络"
    return 1
}

snell_v4_download() {
    local ver="$1"
    require_version "$ver" "Snell v4"
    local url="https://dl.nssurge.com/snell/snell-server-${ver}-linux-$(snell_arch).zip"
    step "下载 Snell v4 $ver ..."
    mkdir -p "$(pdir snell)"
    local tmpzip
    mktemp_pd tmpzip
    download_https "$url" "$tmpzip" "Snell v4 $ver" \
        || die "Snell v4 下载失败: $url"
    extract_zip_binary "$tmpzip" snell-server "$(pbin snell)" "Snell v4" \
        || die "Snell v4 安全解压失败"
    rm -f "$tmpzip"
    verify_download "$(pbin snell)" "Snell v4" 50000
    info "Snell v4 下载完成"
}

snell_download() {
    local ver="$1"
    require_version "$ver" "Snell"
    local url="https://dl.nssurge.com/snell/snell-server-${ver}-linux-$(snell_arch).zip"
    step "下载 Snell $ver ..."
    mkdir -p "$(pdir snell)"
    local tmpzip
    mktemp_pd tmpzip
    download_https "$url" "$tmpzip" "Snell $ver" \
        || die "Snell 下载失败: $url"
    extract_zip_binary "$tmpzip" snell-server "$(pbin snell)" "Snell" \
        || die "Snell 安全解压失败"
    rm -f "$tmpzip"
    verify_download "$(pbin snell)" "Snell" 50000
    info "Snell 下载完成"
}

snell_configure() {
    local port="$1" psk="$2" listen_addr="${3:-auto}"
    local ipv6_enabled="false"
    if [ "$listen_addr" = "auto" ]; then
        listen_addr="$PD_LISTEN_HOST"
    fi
    case "$listen_addr" in
        *:*) listen_addr="[$listen_addr]"; ipv6_enabled="true" ;;
    esac
    if has_ipv6; then
        ipv6_enabled="true"
    fi
    atomic_write_file "$(pdir snell)/snell.conf" 600 <<EOF
[snell-server]
listen = ${listen_addr}:${port}
psk = ${psk}
ipv6 = ${ipv6_enabled}
EOF
}

snell_service_args() {
    echo "-c $(pdir snell)/snell.conf"
}

snell_shadowtls_unit_values() {
    local svc_file="$SYSTEMD_DIR/shadowtls-snell.service"
    [ -f "$svc_file" ] || return 1
    local tls_pass tls_sni tls_proto
    tls_pass=$(unit_password_value "$svc_file" || echo "")
    tls_sni=$(unit_arg_value "--tls" "$svc_file" || echo "")
    [ -n "$tls_pass" ] && [ -n "$tls_sni" ] || return 1
    tls_proto="2"
    grep -q -- '--v3' "$svc_file" 2>/dev/null && tls_proto="3"
    printf '%s\n%s\n%s\n' "$tls_pass" "$tls_sni" "$tls_proto"
}

snell_output() {
    local port="$1" psk="$2"
    local tls_pass="" tls_sni="" tls_proto=""
    local tls_values=""
    tls_values=$(snell_shadowtls_unit_values 2>/dev/null || true)
    if [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ] && [ -z "$tls_values" ]; then
        err "ShadowTLS unit 存在但凭据无法安全读取，拒绝生成 Snell 配置"
        return 1
    fi
    if [ -n "$tls_values" ]; then
        tls_pass=$(printf '%s\n' "$tls_values" | sed -n '1p')
        tls_sni=$(printf '%s\n' "$tls_values" | sed -n '2p')
        tls_proto=$(printf '%s\n' "$tls_values" | sed -n '3p')
        [ -n "$tls_proto" ] || tls_proto="2"
    fi
    if [ -n "$tls_pass" ]; then
        local host4 host6
        select_output_hosts snell || return 1
        host4="$OUTPUT_HOST4"; host6="$OUTPUT_HOST6"
        output_header "Snell v4 + ShadowTLS" "$port"
        echo -e "PSK:     ${GREEN}${psk}${RESET}"
        echo -e "TLS密码: ${GREEN}${tls_pass}${RESET}"
        echo -e "TLS SNI: ${GREEN}${tls_sni}${RESET}"
        if [ "$tls_proto" = "3" ]; then
            echo -e "协议:    ${GREEN}ShadowTLS v3${RESET}"
        else
            echo -e "协议:    ${YELLOW}ShadowTLS v2${RESET}"
        fi
        echo ""
        echo -e "${CYAN}[Surge 配置]${RESET}"
        echo -e "${GREEN}Proxy = snell, ${host4}, ${port}, psk=${psk}, version=4, reuse=true, shadow-tls-password=${tls_pass}, shadow-tls-sni=${tls_sni%:*}, shadow-tls-version=${tls_proto}${RESET}"
        [ -n "$host6" ] && echo -e "${GREEN}Proxy-IPv6 = snell, ${host6}, ${port}, psk=${psk}, version=4, reuse=true, shadow-tls-password=${tls_pass}, shadow-tls-sni=${tls_sni%:*}, shadow-tls-version=${tls_proto}${RESET}"
        output_footer
    else
        local host4 host6
        select_output_hosts snell || return 1
        host4="$OUTPUT_HOST4"; host6="$OUTPUT_HOST6"
        output_header "Snell v5" "$port"
        echo -e "PSK:    ${GREEN}${psk}${RESET}"
        echo ""
        echo -e "${CYAN}[Surge 配置]${RESET}"
        echo -e "${GREEN}Proxy = snell, ${host4}, ${port}, psk=${psk}, version=5, reuse=true, tfo=true${RESET}"
        [ -n "$host6" ] && echo -e "${GREEN}Proxy-IPv6 = snell, ${host6}, ${port}, psk=${psk}, version=5, reuse=true, tfo=true${RESET}"
        output_footer
    fi
}

repair_snell_ipv6() {
    local port psk
    port=$(state_get snell "port")
    psk=$(conf_value "psk" "$(pdir snell)/snell.conf" || echo "")
    [ -n "$port" ] && [ -n "$psk" ] || return 0
    PD_LISTEN_FAMILY="${PD_LISTEN_FAMILY:-$(state_get snell listen_family 2>/dev/null || echo auto)}"
    [ -n "$PD_LISTEN_FAMILY" ] || PD_LISTEN_FAMILY=auto
    prepare_listen_family

    if [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ]; then
        local svc_file="$SYSTEMD_DIR/shadowtls-snell.service"
        local bin="/opt/shadowtls/shadow-tls" tls_pass tls_sni server_arg v3_arg="--v3"
        tls_pass=$(unit_password_value "$svc_file" || echo "")
        tls_sni=$(unit_arg_value "--tls" "$svc_file" || echo "")
        server_arg=$(unit_arg_value "--server" "$svc_file" || echo "")
        grep -q -- '--v3' "$svc_file" 2>/dev/null || v3_arg=""
        [ -n "$tls_pass" ] && [ -n "$tls_sni" ] && [ -n "$server_arg" ] || return 0
        snell_configure "${server_arg##*:}" "$psk" "127.0.0.1" || return 1
        write_shadowtls_unit "$port" "${server_arg##*:}" "$tls_sni" "$tls_pass" "$v3_arg" "$bin" || return 1
        systemctl daemon-reload || return 1
    else
        snell_configure "$port" "$psk" || return 1
        systemctl daemon-reload || return 1
    fi
}

repair_vless_ipv6() {
    local cfg="$(pdir vless)/config.json"
    [ -f "$cfg" ] || return 0

    PD_LISTEN_FAMILY="${PD_LISTEN_FAMILY:-$(state_get vless listen_family 2>/dev/null || echo auto)}"
    [ -n "$PD_LISTEN_FAMILY" ] || PD_LISTEN_FAMILY=auto
    prepare_listen_family
    if grep -q '"listen"' "$cfg" 2>/dev/null; then
        sed 's/"listen"[[:space:]]*:[[:space:]]*"[^"]*"/"listen": "'"$PD_LISTEN_HOST"'"/' "$cfg" \
            | atomic_write_file "$cfg" 600 || return 1
    else
        awk -v host="$PD_LISTEN_HOST" '{print} /"inbounds"[[:space:]]*:[[:space:]]*\[\{/ && !done {print "    \"listen\": \"" host "\","; done=1}' "$cfg" \
            | atomic_write_file "$cfg" 600 || return 1
    fi
}

repair_anytls_ipv6() {
    local port bin svc args
    port=$(state_get anytls "port")
    [ -n "$port" ] || return 0
    bin=$(pbin anytls)
    svc=$(psvc anytls)
    [ -x "$bin" ] || return 0
    PD_LISTEN_FAMILY="${PD_LISTEN_FAMILY:-$(state_get anytls listen_family 2>/dev/null || echo auto)}"
    [ -n "$PD_LISTEN_FAMILY" ] || PD_LISTEN_FAMILY=auto
    prepare_listen_family
    args=$(anytls_service_args "$port")
    write_systemd "$svc" "$bin" "$args" || return 1
    systemctl daemon-reload || return 1
}

# ============================================================
# ShadowTLS（Snell 增强模式）
# ============================================================

install_shadowtls() {
    local dir bin
    dir="/opt/shadowtls"
    bin="$dir/shadow-tls"

    local ver
    ver=$(curl_https -fs --retry 3 --max-time 15 "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" 2>/dev/null \
        | json_tag_name || true)
    [ -n "$ver" ] || die "ShadowTLS 版本检测失败"

    if [ -x "$bin" ]; then
        local current_ver
        current_ver=$("$bin" --version 2>/dev/null | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1 || echo "")
        if [ "v${current_ver}" = "$ver" ]; then
            info "ShadowTLS 已是最新版 $ver" >&2
            echo "$bin"
            return 0
        fi
        step "升级 ShadowTLS ${current_ver:-unknown} → $ver ..." >&2
    else
        step "下载 ShadowTLS $ver ..." >&2
    fi

    # shadow-tls release 用 x86_64 / aarch64 而非 amd64 / arm64
    local stls_arch="$ARCH"
    [ "$stls_arch" = "amd64" ] && stls_arch="x86_64"
    [ "$stls_arch" = "arm64" ] && stls_arch="aarch64"
    local url="https://github.com/ihciah/shadow-tls/releases/download/${ver}/shadow-tls-${stls_arch}-unknown-linux-musl"
    mkdir -p "$dir"
    chmod 755 "$dir"
    printf '%s\n' "PD-proxy owned resource" | atomic_write_file "$dir/.pd-proxy-owned" 600 \
        || die "写入 ShadowTLS 所有权标记失败"
    local tmpbin
    mktemp_pd tmpbin
    download_https "$url" "$tmpbin" "ShadowTLS $ver" "ihciah/shadow-tls" "$ver" \
        || { rm -f "$tmpbin"; die "ShadowTLS 下载失败"; }
    mv "$tmpbin" "$bin"
    chmod 755 "$bin"
    verify_download "$bin" "ShadowTLS" 1000000
    info "ShadowTLS 下载完成" >&2
    echo "$bin"
}

write_shadowtls_unit() {
    local ext_port="$1" int_port="$2" sni="$3" tls_pass="$4" v3_arg="$5" bin="$6" listen
    listen=$(listen_endpoint "$ext_port")
    tls_pass=$(systemd_escape_arg "$tls_pass")
    atomic_write_file "$SYSTEMD_DIR/shadowtls-snell.service" 600 <<EOF
[Unit]
Description=PD-proxy: ShadowTLS for Snell
After=network.target snell.service
Requires=snell.service

[Service]
Type=simple
DynamicUser=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
ExecStart=${bin} ${v3_arg} server --listen ${listen} --server 127.0.0.1:${int_port} --tls ${sni} --password ${tls_pass}
Restart=always
RestartSec=5
LimitNOFILE=32768
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes

[Install]
WantedBy=multi-user.target
EOF
}

snell_shadowtls_configure() {
    local ext_port="$1" int_port="$2"
    local sni="$PD_OPT_SNELL_TLS_SNI"
    local tls_pass="$PD_OPT_SNELL_TLS_PASS"
    local tls_version="$PD_OPT_SNELL_TLS_VERSION"
    validate_hostname "$sni" "PD_SNELL_TLS_SNI"
    case "$tls_version" in v3|3) tls_version="v3" ;; v2|2) tls_version="v2" ;; *) die "PD_SNELL_TLS_VERSION 仅支持 v3 或 v2，当前: $tls_version" ;; esac
    [ -n "$tls_pass" ] || tls_pass=$(rand_pass)
    PD_OPT_SNELL_TLS_PASS="$tls_pass"
    local v3_arg="--v3"
    [ "$tls_version" = "v2" ] && v3_arg=""
    step "配置 ShadowTLS ${tls_version} (SNI: $sni) ..."
    local svc="shadowtls-snell"
    local bin
    bin=$(install_shadowtls)
    write_shadowtls_unit "$ext_port" "$int_port" "${sni}:443" "$tls_pass" "$v3_arg" "$bin"
    systemctl daemon-reload
    systemctl enable "$svc" >/dev/null || { err "ShadowTLS enable 失败"; return 1; }
    systemctl restart "$svc" || { err "ShadowTLS 启动失败，查看 journalctl -u $svc -n 20"; return 1; }
    info "ShadowTLS ${tls_version} 已启动 (端口 $ext_port → Snell $int_port)"
}

# ---- Hysteria2 ----
hy2_get_version() {
    local v
    v=$(curl_https -fs --retry 3 --max-time 15 "https://api.github.com/repos/apernet/hysteria/releases/latest" 2>/dev/null \
        | json_tag_name | sed 's#^app/##' || true)
    [ -n "$v" ] && echo "$v" || die "Hysteria2 版本检测失败，请检查 GitHub 是否可达"
}

hy2_download() {
    local ver="$1"
    local url="https://github.com/apernet/hysteria/releases/download/app/${ver}/hysteria-linux-${ARCH}"
    step "下载 Hysteria2 $ver ..."
    mkdir -p "$(pdir hy2)"
    local tmpbin
    mktemp_pd tmpbin
    download_https "$url" "$tmpbin" "Hysteria2 $ver" "apernet/hysteria" "app/$ver" \
        || { rm -f "$tmpbin"; die "Hysteria2 下载失败: $url"; }
    mv "$tmpbin" "$(pbin hy2)"
    chmod 755 "$(pbin hy2)"
    verify_download "$(pbin hy2)" "Hysteria2" 5000000
    info "Hysteria2 下载完成"
}

hy2_configure() {
    local port="$1" pass="$2"
    local listen
    listen=$(listen_endpoint "$port")
    validate_hy2_hop
    if [ "$PD_OPT_HY2_HOP" -ge 3 ] 2>/dev/null; then
        if ! check_nftables; then
            local virt=$(detect_virt)
            if [ "$virt" != "none" ]; then
                warn "当前环境为 $virt 容器，不支持 nftables 端口跳跃"
            else
                warn "系统不支持 nftables，端口跳跃将不可用。需要内核 4.18+ 和 nf_tables 模块"
            fi
            warn "已降级为单端口模式，如需跳跃端口请使用支持 nftables 的 VPS"
            PD_OPT_HY2_HOP=0
        fi
    fi
    if [ "$PD_OPT_HY2_HOP" -ge 3 ] 2>/dev/null; then
        local last_port=$((port + PD_OPT_HY2_HOP - 1))
        local i
        for i in $(seq 1 $((PD_OPT_HY2_HOP - 1))); do
            local hp=$((port + i))
            if ss -tlnp 2>/dev/null | grep -q ":${hp} " || ss -ulnp 2>/dev/null | grep -q ":${hp} "; then
                warn "跳跃端口 $hp 已被占用，端口跳跃可能不可用"
            fi
        done
        # Hysteria2 只监听主端口，额外端口通过 nft redirect 转发到主端口。
        listen=$(listen_endpoint "$port")
        info "端口跳跃: ${port}-${last_port} (${PD_OPT_HY2_HOP} 个端口)"
    fi
    atomic_write_file "$(pdir hy2)/config.yaml" 600 <<EOF
listen: "${listen}"

tls:
  cert: $(pdir hy2)/cert.crt
  key: $(pdir hy2)/cert.key

auth:
  type: password
  password: ${pass}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
EOF
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$(pdir hy2)/cert.key" -out "$(pdir hy2)/cert.crt" \
        -days 3650 -nodes -subj "/CN=bing.com" >/dev/null 2>&1 \
        || die "Hysteria2 证书生成失败"
    chmod 600 "$(pdir hy2)/config.yaml" "$(pdir hy2)/cert.key" "$(pdir hy2)/cert.crt"
    [ "$(id -u)" != 0 ] || chown root:root "$(pdir hy2)/config.yaml" "$(pdir hy2)/cert.key" "$(pdir hy2)/cert.crt"
}

hy2_service_args() {
    echo "server -c $(pdir hy2)/config.yaml"
}

hy2_output() {
    local port="$1" pass="$2"
    local host4 host6
    select_output_hosts hy2 || return 1
    host4="$OUTPUT_HOST4"; host6="$OUTPUT_HOST6"
    output_header "Hysteria2" "$port"
    echo -e "密码:   ${GREEN}${pass}${RESET}"
    echo ""
    echo -e "${CYAN}[Surge 配置]${RESET}"
    local hop_count
    hop_count=$(state_get hy2 hop)
    if [ "${hop_count:-0}" -ge 3 ] 2>/dev/null; then
        local last_port=$((port + hop_count - 1))
        echo -e "${GREEN}Proxy = hysteria2, ${host4}, ${port}-${last_port}, password=${pass}, sni=www.bing.com, skip-cert-verify=true, ports=${port}-${last_port}${RESET}"
        [ -n "$host6" ] && echo -e "${GREEN}Proxy-IPv6 = hysteria2, ${host6}, ${port}-${last_port}, password=${pass}, sni=www.bing.com, skip-cert-verify=true, ports=${port}-${last_port}${RESET}"
    else
        echo -e "${GREEN}Proxy = hysteria2, ${host4}, ${port}, password=${pass}, sni=www.bing.com, skip-cert-verify=true${RESET}"
        [ -n "$host6" ] && echo -e "${GREEN}Proxy-IPv6 = hysteria2, ${host6}, ${port}, password=${pass}, sni=www.bing.com, skip-cert-verify=true${RESET}"
    fi
    echo ""
    echo -e "${CYAN}[Shadowrocket]${RESET}"
    gen_qr "hysteria2://${pass}@${host4}:${port}?sni=www.bing.com&insecure=1#PD-HY2"
    [ -n "$host6" ] && echo -e "${GREEN}hysteria2://${pass}@${host6}:${port}?sni=www.bing.com&insecure=1#PD-HY2-IPv6${RESET}"
    output_footer
}

# ---- VLESS Reality ----
vless_get_version() {
    local v
    v=$(curl_https -fs --retry 3 --max-time 15 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
        | json_tag_name || true)
    [ -n "$v" ] && echo "$v" || die "Xray 版本检测失败，请检查 GitHub 是否可达"
}

vless_download() {
    local ver="$1"
    local arch_suffix="64"
    [ "$ARCH" = "arm64" ] && arch_suffix="arm64-v8a"
    require_version "$ver" "Xray"
    local url="https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-${arch_suffix}.zip"
    step "下载 Xray-core $ver ..."
    mkdir -p "$(pdir vless)"
    local tmpzip
    mktemp_pd tmpzip
    download_https "$url" "$tmpzip" "Xray $ver" "XTLS/Xray-core" "$ver" \
        || die "Xray 下载失败: $url"
    extract_zip_binary "$tmpzip" xray "$(pbin vless)" "Xray" \
        || die "Xray 安全解压失败"
    rm -f "$tmpzip"
    verify_download "$(pbin vless)" "Xray" 5000000
    info "Xray-core 下载完成"
}

vless_configure() {
    local port="$1" uuid="$2"
    local dest="${PD_OPT_VLESS_DEST}"
    local dest_host="${dest%:*}"
    local sni_list="${PD_OPT_VLESS_SNI}"
    local transport="${PD_OPT_VLESS_TRANSPORT}"
    local fp="${PD_OPT_VLESS_FP}"

    validate_hostport "$dest" "PD_VLESS_DEST"
    validate_hostname "$dest_host" "PD_VLESS_DEST host"
    case "$transport" in
        tcp) ;;
        grpc|ws) warn "VLESS Reality 仅启用 TCP Vision；已忽略 PD_VLESS_TRANSPORT=$transport"; transport="tcp" ;;
        *) die "PD_VLESS_TRANSPORT 仅支持 tcp，当前: $transport" ;;
    esac
    case "$fp" in chrome|firefox|safari|ios|randomized) ;; *) die "PD_VLESS_FP 无效: $fp" ;; esac

    step "生成 Reality 密钥..."
    local keys
    keys=$("$(pbin vless)" x25519 2>/dev/null) || die "Xray x25519 密钥生成失败"
    local privkey
    privkey=$(echo "$keys" | awk '/Private/{print $NF; exit}')
    local pubkey
    pubkey=$(echo "$keys" | awk '/Public/{print $NF; exit}')
    local shortid
    shortid=$(openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
    [ -n "$privkey" ] || die "Reality 私钥生成失败"
    [ -n "$pubkey" ] || die "Reality 公钥生成失败"
    local listen_host="$PD_LISTEN_HOST"

    # 保存配置信息供输出使用
    printf '%s\n' "$pubkey" | atomic_write_file "$(pdir vless)/.pubkey" 600
    printf '%s\n' "$shortid" | atomic_write_file "$(pdir vless)/.shortid" 600
    printf '%s\n' "$dest" | atomic_write_file "$(pdir vless)/.dest" 600
    printf '%s\n' "$transport" | atomic_write_file "$(pdir vless)/.transport" 600
    printf '%s\n' "$fp" | atomic_write_file "$(pdir vless)/.fp" 600

    # 构建 serverNames JSON 数组（去重）
    local snames_json="[\"$(json_escape "$dest_host")\""
    local seen=" ${dest_host} "
    for sn in $(echo "$sni_list" | tr ',' ' ' | sort -u); do
        validate_hostname "$sn" "PD_VLESS_SNI"
        [ "$sn" = "$dest_host" ] && continue
        echo "$seen" | grep -q " $sn " 2>/dev/null && continue
        snames_json="${snames_json}, \"$(json_escape "$sn")\""
        seen="${seen}${sn} "
    done
    snames_json="${snames_json}]"

    atomic_write_file "$(pdir vless)/config.json" 600 <<EOF
{
  "inbounds": [{
    "listen": "$(json_escape "$listen_host")",
    "port": ${port},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${uuid}", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "$(json_escape "$dest")",
        "serverNames": ${snames_json},
        "privateKey": "$(json_escape "$privkey")",
        "shortIds": ["$(json_escape "$shortid")"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
}

vless_service_args() {
    echo "run -c $(pdir vless)/config.json"
}

vless_output() {
    local port="$1" uuid="$2"
    local pubkey shortid dest transport fp
    pubkey=$(cat "$(pdir vless)/.pubkey" 2>/dev/null || true)
    shortid=$(cat "$(pdir vless)/.shortid" 2>/dev/null || true)
    [ -n "$uuid" ] && [ -n "$pubkey" ] && [ -n "$shortid" ] || { err "VLESS 凭据不完整，拒绝生成配置"; return 1; }
    dest=$(cat "$(pdir vless)/.dest" 2>/dev/null || echo "addons.mozilla.org:443")
    transport=$(cat "$(pdir vless)/.transport" 2>/dev/null || echo "tcp")
    fp=$(cat "$(pdir vless)/.fp" 2>/dev/null || echo "chrome")
    local dest_host="${dest%:*}"
    local host4 host6 link link6
    select_output_hosts vless || return 1
    host4="$OUTPUT_HOST4"; host6="$OUTPUT_HOST6"
    link="vless://${uuid}@${host4}:${port}?encryption=none&security=reality&sni=${dest_host}&fp=${fp}&pbk=${pubkey}&sid=${shortid}&type=${transport}&flow=xtls-rprx-vision#PD-VLESS"
    [ -n "$host6" ] && link6="vless://${uuid}@${host6}:${port}?encryption=none&security=reality&sni=${dest_host}&fp=${fp}&pbk=${pubkey}&sid=${shortid}&type=${transport}&flow=xtls-rprx-vision#PD-VLESS-IPv6"

    output_header "VLESS Reality" "$port"
    echo -e "UUID:   ${GREEN}${uuid}${RESET}"
    echo -e "目标:   ${DIM}${dest}${RESET}"
    echo -e "传输:   ${DIM}${transport}${RESET}"
    echo -e "指纹:   ${DIM}${fp}${RESET}"
    echo ""
    echo -e "${YELLOW}⚠ Surge 不支持 VLESS Reality，请用 Shadowrocket${RESET}"
    echo ""
    echo -e "${CYAN}[Shadowrocket]${RESET}"
    gen_qr "$link"
    echo ""
    echo -e "${CYAN}[通用链接]${RESET}"
    echo -e "${GREEN}${link}${RESET}"
    [ -n "${link6:-}" ] && echo -e "${GREEN}${link6}${RESET}"
    output_footer
}

# ---- AnyTLS ----
anytls_get_version() {
    local v
    v=$(curl_https -fs --retry 3 --max-time 15 "https://api.github.com/repos/anytls/anytls-go/releases/latest" 2>/dev/null \
        | json_tag_name || true)
    [ -n "$v" ] && echo "$v" || die "AnyTLS 版本检测失败，请检查 GitHub 是否可达"
}

anytls_download() {
    local ver="$1"
    local ver_num="${ver#v}"
    local url="https://github.com/anytls/anytls-go/releases/download/${ver}/anytls_${ver_num}_linux_${ARCH}.zip"
    step "下载 AnyTLS $ver ..."
    mkdir -p "$(pdir anytls)"
    chmod 755 "$(pdir anytls)"
    local tmpzip
    mktemp_pd tmpzip
    download_https "$url" "$tmpzip" "AnyTLS $ver" "anytls/anytls-go" "$ver" \
        || die "AnyTLS 下载失败: $url"
    extract_zip_binary "$tmpzip" anytls-server "$(pbin anytls)" "AnyTLS" \
        || die "AnyTLS 安全解压失败"
    rm -f "$tmpzip"
    verify_download "$(pbin anytls)" "AnyTLS" 1000000
    info "AnyTLS 下载完成"
}

anytls_configure() {
    local port="$1" pass="$2"
    local padding="${PD_OPT_ANYTLS_PADDING}"
    local sni="${PD_OPT_ANYTLS_SNI}"
    case "$padding" in standard|deep|fixed|none) ;; *) die "PD_ANYTLS_PADDING 无效: $padding" ;; esac
    [ "$padding" = "standard" ] || warn "当前 anytls-server 未启用预设填充参数，PD_ANYTLS_PADDING=$padding 已忽略"
    [ -z "$sni" ] || validate_hostname "$sni" "PD_ANYTLS_SNI"

    printf '%s\n' "$pass" | atomic_write_file "$(pdir anytls)/.password" 600
    printf '%s\n' "server-default" | atomic_write_file "$(pdir anytls)/.padding" 600
    if [ -n "$sni" ]; then
        printf '%s\n' "$sni" | atomic_write_file "$(pdir anytls)/.sni" 600
    else
        rm -f "$(pdir anytls)/.sni"
    fi
}

anytls_service_args() {
    local port="$1"
    local pass
    pass=$(cat "$(pdir anytls)/.password" 2>/dev/null || echo "")
    pass=$(systemd_escape_arg "$pass")

    local listen_host
    listen_host=$(listen_endpoint "$port")
    local args="-l ${listen_host} -p ${pass}"
    # anytls-server v0.0.12 无 -sni 参数，SNI 由客户端侧处理
    echo "$args"
}

anytls_output() {
    local port="$1" pass="$2"
    local padding sni
    padding=$(cat "$(pdir anytls)/.padding" 2>/dev/null || echo "standard")
    sni=$(cat "$(pdir anytls)/.sni" 2>/dev/null || echo "")

    local host4 host6 query="" link link6
    select_output_hosts anytls || return 1
    host4="$OUTPUT_HOST4"; host6="$OUTPUT_HOST6"
    [ -n "$sni" ] && query="?sni=$(url_escape "$sni")&insecure=1"
    link="anytls://${pass}@${host4}:${port}${query}#PD-AnyTLS"
    [ -n "$host6" ] && link6="anytls://${pass}@${host6}:${port}${query}#PD-AnyTLS-IPv6"
    output_header "AnyTLS" "$port"
    echo -e "密码:   ${GREEN}${pass}${RESET}"
    echo -e "填充:   ${DIM}${padding}（服务端默认）${RESET}"
    [ -n "$sni" ] && echo -e "SNI:    ${DIM}${sni}（客户端侧使用）${RESET}"
    echo ""
    echo -e "${CYAN}[Surge 配置]${RESET}"
    echo -e "${GREEN}Proxy = anytls, ${host4}, ${port}, password=${pass}${RESET}"
    [ -n "$host6" ] && echo -e "${GREEN}Proxy-IPv6 = anytls, ${host6}, ${port}, password=${pass}${RESET}"
    echo ""
    echo -e "${CYAN}[Shadowrocket]${RESET}"
    gen_qr "$link"
    echo ""
    echo -e "${CYAN}[通用链接]${RESET}"
    echo -e "${GREEN}${link}${RESET}"
    [ -n "${link6:-}" ] && echo -e "${GREEN}${link6}${RESET}"
    output_footer
}

# ============================================================
# 统一安装流水线（核心 — 所有协议走同一套流程）
# ============================================================

switch_snell_mode_impl() {
    uninstall_protocol_impl snell
    assert_install_target_available snell
    install_protocol_impl snell
}

install_protocol() {
    local proto="$1" key cur_sts=false want_sts=false
    assert_base_dir_safe || return 1
    key=$(pkey "$proto")
    if state_installed "$key"; then
        if [ "$proto" = snell ]; then
            [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ] && cur_sts=true
            [ "$PD_OPT_SNELL_MODE" = shadowtls ] && want_sts=true
            if [ "$cur_sts" != "$want_sts" ]; then
                warn "检测到 Snell 模式不同，将以事务方式切换..."
                transaction_begin snell || { transaction_discard_unstarted; return 1; }
                transaction_run switch_snell_mode_impl
                return $?
            fi
        fi
        warn "$(pname "$proto") 已安装，执行最新版检查..."
        upgrade_protocol "$proto"
        return $?
    fi
    assert_install_target_available "$proto" || return 1
    transaction_begin "$proto" || { transaction_discard_unstarted; return 1; }
    transaction_run install_protocol_impl "$proto"
}

install_protocol_impl() {
    local proto="$1"
    local name key dir bin svc
    name=$(pname "$proto")
    key=$(pkey "$proto")
    dir=$(pdir "$proto")
    bin=$(pbin "$proto")
    svc=$(psvc "$proto")

    # ShadowTLS 模式适配显示名
    local display_name="$name"
    if [ "$proto" = "snell" ] && [ "$PD_OPT_SNELL_MODE" = "shadowtls" ]; then
        display_name="Snell v4 + ShadowTLS"
    fi
    title "安装 $display_name"

    prepare_listen_family
    require_public_endpoint
    install_deps "$proto"; install_qrencode
    check_disk "$(pdisk "$proto")"
    if [ "$proto" = "hy2" ] && [ -n "${PD_OPT_HY2_HOP_RANGE:-}" ]; then
        validate_hy2_hop
    fi

    local port port_var
    port_var=$(port_var_name "$proto")
    if [ -n "${!port_var:-}" ]; then
        port="${!port_var}"
        validate_port "$port" "$port_var"
        if state_port_range_conflict "$port" "$port" "$key"; then
            die "端口 $port 已被其它已安装 PD 协议使用，请更换 $port_var"
        fi
        if port_in_use "$port"; then
            die "端口 $port 已被系统占用，请更换 $port_var"
        fi
        info "端口(手动): $port"
    else
        if [ "$proto" = "hy2" ]; then
            validate_hy2_hop
            if [ "$PD_OPT_HY2_HOP" -ge 3 ] 2>/dev/null; then
                port=$(rand_port_range "$PD_OPT_HY2_HOP")
            else
                port=$(rand_port)
            fi
        else
            port=$(rand_port)
        fi
        info "端口(自动): $port"
    fi
    if [ "$proto" = "hy2" ]; then
        validate_hy2_hop
        [ $((port + PD_OPT_HY2_HOP - 1)) -le 65535 ] || die "HY2 跳跃端口超过 65535，请降低 ${port_var} 或 PD_HY2_HOP"
        if [ "$PD_OPT_HY2_HOP" -ge 3 ] 2>/dev/null && state_port_range_conflict "$port" "$((port + PD_OPT_HY2_HOP - 1))" "$key"; then
            die "HY2 跳跃端口范围 ${port}-$((port + PD_OPT_HY2_HOP - 1)) 与其它已安装 PD 协议端口冲突"
        fi
        if [ "$PD_OPT_HY2_HOP" -ge 3 ] 2>/dev/null; then
            local busy_port
            busy_port=$(system_port_range_conflict "$port" "$((port + PD_OPT_HY2_HOP - 1))" || true)
            [ -z "$busy_port" ] || die "HY2 跳跃端口范围 ${port}-$((port + PD_OPT_HY2_HOP - 1)) 中的端口 $busy_port 已被系统占用"
        fi
    fi

    local pass
    pass=$(rand_pass)
    # VLESS 需要标准 UUID 格式，不能是 base64
    [ "$proto" = "vless" ] && pass=$(gen_uuid)

    local ver=""
    if [ "$proto" = "snell" ] && [ "$PD_OPT_SNELL_MODE" = "shadowtls" ]; then
        step "获取 Snell v4 版本..."
        if ! ver=$(snell_v4_get_version); then
            die "Snell v4 版本检测失败，已停止安装"
        fi
        require_version "$ver" "Snell v4"
        info "版本: $ver"
        snell_v4_download "$ver"
    elif declare -f "${proto}_get_version" >/dev/null 2>&1; then
        step "获取版本..."
        if ! ver=$("${proto}_get_version"); then
            die "$(pname "$proto") 版本检测失败，已停止安装"
        fi
        require_version "$ver" "$(pname "$proto")"
        info "版本: $ver"
        "${proto}_download" "$ver"
    fi

    step "写入配置..."
    if [ "$proto" = "snell" ] && [ "$PD_OPT_SNELL_MODE" = "shadowtls" ]; then
        # ShadowTLS 模式：Snell 监听内部端口（50000+），先配 Snell，ShadowTLS 稍后部署
        local snell_int=$(( (RANDOM % 15000) + 50000 ))
        local _sni_attempts=0
        while port_in_use "$snell_int"; do
            snell_int=$(( (RANDOM % 15000) + 50000 ))
            _sni_attempts=$((_sni_attempts + 1))
            [ $_sni_attempts -lt 100 ] || die "无法分配 Snell 内部端口（50000-65000）"
        done
        snell_configure "$snell_int" "$pass" "127.0.0.1"
    else
        "${proto}_configure" "$port" "$pass"
    fi
    printf '%s\n' "PD-proxy owned resource" | atomic_write_file "$dir/.pd-proxy-owned" 600 \
        || die "写入资源所有权标记失败"

    # 在最终写 unit 前再次检查状态和系统监听，关闭选端口后的竞争窗口。
    local final_end="$port"
    [ "$proto" = hy2 ] && [ "$PD_OPT_HY2_HOP" -ge 3 ] 2>/dev/null && final_end=$((port + PD_OPT_HY2_HOP - 1))
    state_port_range_conflict "$port" "$final_end" "$key" && die "最终端口复检发现状态冲突: ${port}-${final_end}"
    local final_busy
    final_busy=$(system_port_range_conflict "$port" "$final_end" || true)
    [ -z "$final_busy" ] || die "最终端口复检发现端口 $final_busy 已被占用"

    step "注册服务..."
    if [ "$proto" = "hy2" ] && [ "$PD_OPT_HY2_HOP" -ge 3 ] 2>/dev/null; then
        setup_hy2_hop_rules "$port" "$PD_OPT_HY2_HOP"
        write_hy2_systemd "$svc" "$bin" "$("${proto}_service_args" "$port")"
    else
        write_systemd "$svc" "$bin" "$("${proto}_service_args" "$port")"
    fi
    register_and_start "$svc"

    # 6.5 Snell + ShadowTLS: snell.service 已运行，现在部署 ShadowTLS
    if [ "$proto" = "snell" ] && [ "$PD_OPT_SNELL_MODE" = "shadowtls" ]; then
        snell_shadowtls_configure "$port" "$snell_int"
    fi

    if [ "$proto" = "hy2" ] && [ "$PD_OPT_HY2_HOP" -ge 3 ] 2>/dev/null; then
        firewall_add "$key" "$port" "$((port + PD_OPT_HY2_HOP - 1))" udp
        state_set "$key" "hop" "$PD_OPT_HY2_HOP"
        [ -n "${PD_OPT_HY2_HOP_RANGE:-}" ] && state_set "$key" "hop_range" "$PD_OPT_HY2_HOP_RANGE"
    else
        firewall_add "$key" "$port" "$port" "$(protocol_transport "$proto")"
        if [ "$proto" = "hy2" ]; then
            state_set "$key" "hop" "0"
            state_set "$key" "hop_range" ""
        fi
    fi
    if [ "$proto" = "snell" ] && [ "$PD_OPT_SNELL_MODE" = "shadowtls" ]; then
        verify_shadowtls_stack "$port" "$snell_int" || die "ShadowTLS 两层传输验证失败"
    elif [ "$proto" = hy2 ] && [ "$PD_OPT_HY2_HOP" -ge 3 ] 2>/dev/null; then
        verify_hy2_hop "$port" "$PD_OPT_HY2_HOP" || die "HY2 hop 传输验证失败"
    else
        verify_port "$port" "$svc" "$(protocol_transport "$proto")" || die "目标服务传输验证失败"
    fi

    local public_service="$svc"
    [ "$proto" = snell ] && [ "$PD_OPT_SNELL_MODE" = shadowtls ] && public_service=shadowtls-snell
    verify_and_record_listen_families "$key" "$port" "$(protocol_transport "$proto")" "$public_service" \
        || die "监听地址族验证失败"

    state_set "$key" "port" "$port"
    state_set "$key" "version" "$ver"
    state_set "$key" "status" "installed"

    "${proto}_output" "$port" "$pass"

}

uninstall_protocol() {
    local proto="$1" key
    key=$(pkey "$proto")
    if ! state_installed "$key"; then
        warn "$(pname "$proto") 未安装"
        return 0
    fi
    transaction_begin "$proto" || { transaction_discard_unstarted; return 1; }
    transaction_run uninstall_protocol_impl "$proto"
}

uninstall_protocol_impl() {
    local proto="$1"
    local key=$(pkey "$proto")
    local svc=$(psvc "$proto")

    info "卸载 $(pname "$proto") ..."
    assert_owned_resources_safe "$proto" || return 1

    local port
    port=$(state_get "$key" "port")

    systemctl is-active --quiet "$svc" 2>/dev/null && systemctl stop "$svc"
    systemctl is-enabled --quiet "$svc" 2>/dev/null && systemctl disable "$svc" >/dev/null
    local unit="$SYSTEMD_DIR/${svc}.service"
    [ ! -e "$unit" ] || { unit_is_pd_owned "$unit" || die "拒绝删除所有权未知的 unit: $unit"; rm -f "$unit"; }

    # Snell ShadowTLS 额外清理
    if [ "$proto" = "snell" ]; then
        local tls_svc="shadowtls-snell"
        local tls_unit="$SYSTEMD_DIR/${tls_svc}.service"
        systemctl is-active --quiet "$tls_svc" 2>/dev/null && systemctl stop "$tls_svc"
        systemctl is-enabled --quiet "$tls_svc" 2>/dev/null && systemctl disable "$tls_svc" >/dev/null
        [ ! -e "$tls_unit" ] || { unit_is_pd_owned "$tls_unit" || die "拒绝删除所有权未知的 unit: $tls_unit"; rm -f "$tls_unit"; }
        [ ! -L /opt/shadowtls ] || die "拒绝递归删除符号链接 /opt/shadowtls"
        [ ! -e /opt/shadowtls ] || [ -f /opt/shadowtls/.pd-proxy-owned ] \
            || die "ShadowTLS 目录缺少所有权标记，拒绝删除"
        [ ! -e /opt/shadowtls ] || rm -rf /opt/shadowtls
    fi

    systemctl daemon-reload
    systemctl reset-failed "${svc}.service" 2>/dev/null || true

    if [ "$proto" = "hy2" ]; then
        local listen_line
        listen_line=$(grep 'listen:' "$(pdir hy2)/config.yaml" 2>/dev/null || echo "")
        local hop_count
        hop_count=$(state_get "$key" "hop")
        [ -n "$hop_count" ] || hop_count=$(echo "$listen_line" | tr ',' '\n' | wc -l | tr -d ' \n')
        if [ "$hop_count" -ge 2 ] 2>/dev/null || [ -e "$SYSTEMD_DIR/pd-hy2-hop.service" ] || [ -L "$SYSTEMD_DIR/pd-hy2-hop.service" ]; then
            firewall_remove_owned "$key"
            clear_hy2_hop_rules
        else
            firewall_remove_owned "$key"
        fi
    else
        firewall_remove_owned "$key"
    fi
    [ ! -L "$(pdir "$proto")" ] || die "拒绝递归删除符号链接: $(pdir "$proto")"
    [ ! -e "$(pdir "$proto")" ] || rm -rf "$(pdir "$proto")"
    state_del "$key"
    info "$(pname "$proto") 已卸载"
}

# ============================================================
# 协议升级 / 重启 / 纯配置
# ============================================================

upgrade_protocol() {
    local proto="$1" key name
    key=$(pkey "$proto"); name=$(pname "$proto")
    state_installed "$key" || { err "$name 未安装，无法升级"; return 1; }
    transaction_begin "$proto" || { transaction_discard_unstarted; return 1; }
    transaction_run upgrade_protocol_impl "$proto"
}

upgrade_protocol_impl() {
    local proto="$1" key name svc bin bin_bak ver="" old_ver port hop transport
    local was_active=false shadow_active=false shadow_enabled=false hop_active=false hop_enabled=false download_main=true
    key=$(pkey "$proto"); name=$(pname "$proto"); svc=$(psvc "$proto"); bin=$(pbin "$proto")
    bin_bak="${bin}.bak"
    title "升级 $name"
    check_disk "$(pdisk "$proto")"
    systemctl is-active --quiet "$svc" 2>/dev/null && was_active=true
    systemctl is-active --quiet shadowtls-snell 2>/dev/null && shadow_active=true
    systemctl is-enabled --quiet shadowtls-snell 2>/dev/null && shadow_enabled=true
    systemctl is-active --quiet pd-hy2-hop 2>/dev/null && hop_active=true
    systemctl is-enabled --quiet pd-hy2-hop 2>/dev/null && hop_enabled=true
    old_ver=$(state_get "$key" version)

    if [ "$proto" = snell ] && [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ]; then
        step "获取 Snell v4 最新版本..."
        ver=$(snell_v4_get_version) || die "Snell v4 版本检测失败，已停止升级"
    else
        step "获取最新版本..."
        ver=$("${proto}_get_version") || die "$name 版本检测失败，已停止升级"
    fi
    require_version "$ver" "$name"
    [ "$ver" = "$old_ver" ] && download_main=false
    if ! $download_main && ! { [ "$proto" = snell ] && [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ]; }; then
        info "$name 已是最新版 ($ver)，跳过"
        return 0
    fi
    info "版本: $old_ver → $ver"

    [ -f "$bin" ] && [ ! -L "$bin" ] || die "旧二进制缺失或不是普通文件: $bin"
    [ ! -e "$bin_bak" ] && [ ! -L "$bin_bak" ] || die "发现陈旧备份，拒绝升级: $bin_bak"
    cp -p "$bin" "$bin_bak" || die "创建升级备份失败，已停止"

    $shadow_active && systemctl stop shadowtls-snell
    $was_active && systemctl stop "$svc"
    if $download_main; then
        step "下载候选版本..."
        if [ "$proto" = snell ] && [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ]; then
            snell_v4_download "$ver"
        else
            "${proto}_download" "$ver"
        fi
    fi

    systemctl start "$svc" || die "候选版本启动失败: journalctl -u $svc -n 20"
    port=$(state_get "$key" port)
    hop=$(state_get "$key" hop)
    if [ "$proto" = snell ] && [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ]; then
        install_shadowtls >/dev/null
        systemctl restart shadowtls-snell || die "ShadowTLS 候选启动失败"
        local inner_port
        inner_port=$(conf_value listen "$(pdir snell)/snell.conf" | sed 's/.*://')
        verify_shadowtls_stack "$port" "$inner_port" || die "ShadowTLS 两层候选验证失败"
    elif [ "$proto" = hy2 ] && [ "${hop:-0}" -ge 3 ] 2>/dev/null; then
        setup_hy2_hop_rules "$port" "$hop"
        verify_hy2_hop "$port" "$hop" || die "HY2 hop 候选验证失败"
    else
        transport=$(protocol_transport "$proto")
        verify_port "$port" "$svc" "$transport" || die "候选版本传输验证失败"
    fi
    local public_svc="$svc"
    [ "$proto" = snell ] && [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ] && public_svc=shadowtls-snell
    local stored_family
    stored_family=$(state_get "$key" listen_family 2>/dev/null || true)
    [ -z "$stored_family" ] || PD_EFFECTIVE_LISTEN_FAMILY="$stored_family"
    [ -n "${PD_EFFECTIVE_LISTEN_FAMILY:-}" ] || PD_EFFECTIVE_LISTEN_FAMILY=auto
    verify_and_record_listen_families "$key" "$port" "$(protocol_transport "$proto")" "$public_svc" \
        || die "候选版本监听地址族验证失败"

    state_set "$key" version "$ver"
    rm -f "$bin_bak" || die "清理升级备份失败"
    if ! $was_active; then systemctl stop "$svc" || die "恢复原停止状态失败"; fi
    if [ "$proto" = snell ] && [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ] && ! $shadow_active; then
        systemctl stop shadowtls-snell || die "恢复 ShadowTLS 原停止状态失败"
    fi
    if [ "$proto" = snell ] && [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ] && ! $shadow_enabled; then
        systemctl disable shadowtls-snell >/dev/null || die "恢复 ShadowTLS 原禁用状态失败"
    fi
    if [ "$proto" = hy2 ] && [ "${hop:-0}" -ge 3 ] 2>/dev/null; then
        if ! $hop_active; then systemctl stop pd-hy2-hop || die "恢复 HY2 hop 原停止状态失败"; fi
        if ! $hop_enabled; then systemctl disable pd-hy2-hop >/dev/null || die "恢复 HY2 hop 原禁用状态失败"; fi
    fi
    info "$name 升级完成"
}

restart_service() {
    local proto="$1"
    local key=$(pkey "$proto")
    local svc=$(psvc "$proto")

    if ! state_installed "$key"; then
        die "$(pname "$proto") 未安装"
    fi
    info "重启 $(pname "$proto") ..."
    systemctl restart "$svc" || die "重启失败: journalctl -u $svc -n 20"
    # Snell + ShadowTLS: Requires= 只传播 stop 不传播 start
    if [ "$proto" = "snell" ] && [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ]; then
        systemctl restart shadowtls-snell || die "ShadowTLS 重启失败: journalctl -u shadowtls-snell -n 20"
    fi
    if [ "$proto" = "hy2" ]; then
        local port hop
        port=$(state_get "$key" "port")
        hop=$(state_get "$key" "hop")
        if [ "${hop:-0}" -ge 3 ] 2>/dev/null; then
            setup_hy2_hop_rules "$port" "$hop" || die "HY2 跳跃规则恢复失败"
        fi
    fi
    verify_running_protocol "$proto" || die "重启后服务验证失败"
    info "$(pname "$proto") 已重启"
}

stop_service() {
    local proto="$1"
    local key=$(pkey "$proto")
    local svc=$(psvc "$proto")
    local failed=0 shadowtls=false

    if ! state_installed "$key"; then
        die "$(pname "$proto") 未安装"
    fi
    info "停止 $(pname "$proto") ..."
    if [ "$proto" = "snell" ] && [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ]; then
        shadowtls=true
        systemctl stop shadowtls-snell || { err "ShadowTLS 停止失败"; failed=1; }
    fi
    if [ "$proto" = "hy2" ]; then
        clear_hy2_hop_rules || failed=1
    fi
    systemctl stop "$svc" || { err "$(pname "$proto") 停止失败"; failed=1; }
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        err "服务 $svc 停止后仍处于 active 状态"
        failed=1
    fi
    if $shadowtls && systemctl is-active --quiet shadowtls-snell 2>/dev/null; then
        err "服务 shadowtls-snell 停止后仍处于 active 状态"
        failed=1
    fi
    if [ "$proto" = hy2 ] && systemctl is-active --quiet pd-hy2-hop 2>/dev/null; then
        err "服务 pd-hy2-hop 停止后仍处于 active 状态"
        failed=1
    fi
    [ "$failed" -eq 0 ] || return 1
    info "$(pname "$proto") 已停止"
}

start_service() {
    local proto="$1"
    local key=$(pkey "$proto")
    local svc=$(psvc "$proto")

    if ! state_installed "$key"; then
        die "$(pname "$proto") 未安装"
    fi
    info "启动 $(pname "$proto") ..."
    systemctl start "$svc" || die "启动失败: journalctl -u $svc -n 20"
    # Snell + ShadowTLS: Requires= 只传播 stop 不传播 start
    if [ "$proto" = "snell" ] && [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ]; then
        systemctl start shadowtls-snell || die "ShadowTLS 启动失败: journalctl -u shadowtls-snell -n 20"
    fi
    if [ "$proto" = "hy2" ]; then
        local port hop
        port=$(state_get "$key" "port")
        hop=$(state_get "$key" "hop")
        if [ "${hop:-0}" -ge 3 ] 2>/dev/null; then
            setup_hy2_hop_rules "$port" "$hop" || die "HY2 跳跃规则恢复失败"
        fi
    fi
    verify_running_protocol "$proto" || die "启动后服务验证失败"
    info "$(pname "$proto") 已启动"
}

show_log() {
    local proto="$1"
    local key=$(pkey "$proto")
    local svc=$(psvc "$proto")

    if ! state_installed "$key"; then
        die "$(pname "$proto") 未安装"
    fi
    if [ "$proto" = snell ] && [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ]; then
        journalctl -u snell -u shadowtls-snell -n 100 --no-pager 2>/dev/null || warn "无法读取 Snell/ShadowTLS 日志"
    else
        journalctl -u "$svc" -n 50 --no-pager 2>/dev/null || warn "无法读取日志"
    fi
}

show_config_only() {
    local proto="$1"
    local key=$(pkey "$proto")
    if ! state_installed "$key"; then
        die "$(pname "$proto") 未安装"
    fi

    local port=$(state_get "$key" "port")
    [[ "$port" =~ ^[0-9]+$ ]] || { err "协议端口状态无效，拒绝生成配置"; return 1; }
    case $proto in
        snell)
            local psk tls_pass tls_sni tls_proto
            psk=$(conf_value "psk" "$(pdir snell)/snell.conf" || echo "")
            [ -n "$psk" ] || { err "Snell PSK 缺失，拒绝生成配置"; return 1; }
            local host4 host6
            select_output_hosts snell || return 1
            host4="$OUTPUT_HOST4"; host6="$OUTPUT_HOST6"
            local tls_values=""
            tls_values=$(snell_shadowtls_unit_values 2>/dev/null || true)
            if [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ] && [ -z "$tls_values" ]; then
                err "ShadowTLS 凭据缺失，拒绝生成配置"
                return 1
            fi
            if [ -n "$tls_values" ]; then
                tls_pass=$(printf '%s\n' "$tls_values" | sed -n '1p')
                tls_sni=$(printf '%s\n' "$tls_values" | sed -n '2p')
                tls_proto=$(printf '%s\n' "$tls_values" | sed -n '3p')
                [ -n "$tls_proto" ] || tls_proto="2"
                echo "Proxy = snell, ${host4}, ${port}, psk=${psk}, version=4, reuse=true, shadow-tls-password=${tls_pass}, shadow-tls-sni=${tls_sni%:*}, shadow-tls-version=${tls_proto}"
                [ -n "$host6" ] && echo "Proxy-IPv6 = snell, ${host6}, ${port}, psk=${psk}, version=4, reuse=true, shadow-tls-password=${tls_pass}, shadow-tls-sni=${tls_sni%:*}, shadow-tls-version=${tls_proto}"
            else
                echo "Proxy = snell, ${host4}, ${port}, psk=${psk}, version=5, reuse=true, tfo=true"
                [ -n "$host6" ] && echo "Proxy-IPv6 = snell, ${host6}, ${port}, psk=${psk}, version=5, reuse=true, tfo=true"
            fi ;;
        hy2)
            local pass hop host4 host6
            pass=$(yaml_value "password" "$(pdir hy2)/config.yaml" || echo "")
            [ -n "$pass" ] || { err "Hysteria2 密码缺失，拒绝生成配置"; return 1; }
            hop=$(state_get "$key" "hop")
            select_output_hosts hy2 || return 1
            host4="$OUTPUT_HOST4"; host6="$OUTPUT_HOST6"
            if [ "$hop" -ge 3 ] 2>/dev/null; then
                local last_port=$((port + hop - 1))
                echo "Proxy = hysteria2, ${host4}, ${port}-${last_port}, password=${pass}, sni=www.bing.com, skip-cert-verify=true, ports=${port}-${last_port}"
                [ -n "$host6" ] && echo "Proxy-IPv6 = hysteria2, ${host6}, ${port}-${last_port}, password=${pass}, sni=www.bing.com, skip-cert-verify=true, ports=${port}-${last_port}"
            else
                echo "Proxy = hysteria2, ${host4}, ${port}, password=${pass}, sni=www.bing.com, skip-cert-verify=true"
                [ -n "$host6" ] && echo "Proxy-IPv6 = hysteria2, ${host6}, ${port}, password=${pass}, sni=www.bing.com, skip-cert-verify=true"
            fi
            echo ""
            echo "# Shadowrocket: hysteria2://${pass}@${host4}:${port}?sni=www.bing.com&insecure=1#PD-HY2"
            [ -n "$host6" ] && echo "# Shadowrocket-IPv6: hysteria2://${pass}@${host6}:${port}?sni=www.bing.com&insecure=1#PD-HY2-IPv6" ;;
        vless)
            local uuid pubkey shortid dest transport fp dest_host host4 host6
            uuid=$(json_value "id" "$(pdir vless)/config.json" || echo "")
            pubkey=$(cat "$(pdir vless)/.pubkey" 2>/dev/null || echo "")
            shortid=$(cat "$(pdir vless)/.shortid" 2>/dev/null || echo "")
            dest=$(cat "$(pdir vless)/.dest" 2>/dev/null || echo "addons.mozilla.org:443")
            transport=$(cat "$(pdir vless)/.transport" 2>/dev/null || echo "tcp")
            fp=$(cat "$(pdir vless)/.fp" 2>/dev/null || echo "chrome")
            [ -n "$uuid" ] && [ -n "$pubkey" ] && [ -n "$shortid" ] \
                || { err "VLESS 凭据不完整，拒绝生成配置"; return 1; }
            dest_host="${dest%:*}"
            select_output_hosts vless || return 1
            host4="$OUTPUT_HOST4"; host6="$OUTPUT_HOST6"
            echo "# Surge 不支持 VLESS"
            echo "vless://${uuid}@${host4}:${port}?encryption=none&security=reality&sni=${dest_host}&fp=${fp}&pbk=${pubkey}&sid=${shortid}&type=${transport}&flow=xtls-rprx-vision#PD-VLESS"
            [ -n "$host6" ] && echo "vless://${uuid}@${host6}:${port}?encryption=none&security=reality&sni=${dest_host}&fp=${fp}&pbk=${pubkey}&sid=${shortid}&type=${transport}&flow=xtls-rprx-vision#PD-VLESS-IPv6" ;;
        anytls)
            local pass padding sni host4 host6
            pass=$(cat "$(pdir anytls)/.password" 2>/dev/null || echo "")
            [ -n "$pass" ] || { err "AnyTLS 密码缺失，拒绝生成配置"; return 1; }
            padding=$(cat "$(pdir anytls)/.padding" 2>/dev/null || echo "standard")
            sni=$(cat "$(pdir anytls)/.sni" 2>/dev/null || echo "")
            select_output_hosts anytls || return 1
            host4="$OUTPUT_HOST4"; host6="$OUTPUT_HOST6"
            echo "Proxy = anytls, ${host4}, ${port}, password=${pass}"
            [ -n "$host6" ] && echo "Proxy-IPv6 = anytls, ${host6}, ${port}, password=${pass}"
            echo ""
            local query=""
            [ -n "$sni" ] && query="?sni=$(url_escape "$sni")&insecure=1"
            echo "# Shadowrocket: anytls://${pass}@${host4}:${port}${query}#PD-AnyTLS"
            [ -n "$host6" ] && echo "# Shadowrocket-IPv6: anytls://${pass}@${host6}:${port}${query}#PD-AnyTLS-IPv6" ;;
    esac
}

# ============================================================
# 状态 & 配置查看
# ============================================================

show_status() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║${RESET}     ${MAGENTA}◆  P D - P R O X Y${RESET}  ${DIM}v${VERSION}${RESET}    ${CYAN}║${RESET}"
    echo -e "${CYAN}╠══════════════════════════════════════╣${RESET}"
    for proto in $ALL_PROTOS; do
        local key=$(pkey "$proto")
        local name=$(pname "$proto")
        # ShadowTLS 模式适配显示名
        if [ "$proto" = "snell" ] && [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ] && systemctl is-active --quiet shadowtls-snell 2>/dev/null; then
            name="Snell v4+STS"
        fi
        if state_installed "$key"; then
            local port=$(state_get "$key" "port")
            local ver=$(state_get "$key" "version")
            local svc=$(psvc "$proto")
            local st icon
            if [ "$proto" = "snell" ] && [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ]; then
                if systemctl is-active --quiet "$svc" 2>/dev/null && systemctl is-active --quiet shadowtls-snell 2>/dev/null; then
                    st="${GREEN}ONLINE ${RESET}"
                    icon="${GREEN}◆${RESET}"
                else
                    st="${RED}OFFLINE${RESET}"
                    icon="${RED}◇${RESET}"
                fi
            elif [ "$proto" = "hy2" ] && [ "$(state_get "$key" "hop")" -ge 3 ] 2>/dev/null; then
                if systemctl is-active --quiet "$svc" 2>/dev/null && nft list table inet pd_hy2_hop >/dev/null 2>&1; then
                    st="${GREEN}ONLINE ${RESET}"
                    icon="${GREEN}◆${RESET}"
                else
                    st="${RED}OFFLINE${RESET}"
                    icon="${RED}◇${RESET}"
                fi
            elif systemctl is-active --quiet "$svc" 2>/dev/null; then
                st="${GREEN}ONLINE ${RESET}"
                icon="${GREEN}◆${RESET}"
            else
                st="${RED}OFFLINE${RESET}"
                icon="${RED}◇${RESET}"
            fi
            printf "${CYAN}║${RESET} ${icon} %-12s ${st}  ${BLUE}:%-5s${RESET} ${DIM}%s${RESET} ${CYAN}║${RESET}\n" "$name" "$port" "$ver"
        else
            printf "${CYAN}║${RESET} ${DIM}◇ %-12s 未安装              ${RESET} ${CYAN}║${RESET}\n" "$name"
        fi
    done
    echo -e "${CYAN}╠══════════════════════════════════════╣${RESET}"
    printf "${CYAN}║${RESET} ${DIM}%-10s │ ${BLUE}%-15s${RESET}${DIM} │ %sMB${RESET}  ${CYAN}║${RESET}\n" "$OS_PRETTY" "$IP" "$MEM_AVAIL"
    echo -e "${CYAN}╚══════════════════════════════════════╝${RESET}"
    echo ""
}

show_config() {
    title "协议配置"
    echo -e "${CYAN}══════════════════════════════════════════${RESET}"
    local has_any=false
    for proto in $ALL_PROTOS; do
        local key=$(pkey "$proto")
        if ! state_installed "$key"; then continue; fi
        has_any=true
        local port=$(state_get "$key" "port")
        case $proto in
            snell)
                local psk
                psk=$(conf_value "psk" "$(pdir snell)/snell.conf" || true)
                [ -n "$psk" ] && snell_output "$port" "$psk" || warn "Snell 凭据缺失，已跳过配置输出" ;;
            hy2)
                local pass
                pass=$(yaml_value "password" "$(pdir hy2)/config.yaml" || true)
                [ -n "$pass" ] && hy2_output "$port" "$pass" || warn "Hysteria2 凭据缺失，已跳过配置输出" ;;
            vless)
                local uuid
                uuid=$(json_value "id" "$(pdir vless)/config.json" || true)
                [ -n "$uuid" ] && vless_output "$port" "$uuid" || warn "VLESS 凭据缺失，已跳过配置输出" ;;
            anytls)
                local pass
                pass=$(cat "$(pdir anytls)/.password" 2>/dev/null || true)
                [ -n "$pass" ] && anytls_output "$port" "$pass" || warn "AnyTLS 凭据缺失，已跳过配置输出" ;;
        esac
        echo ""
    done
    if ! $has_any; then
        echo -e "  ${YELLOW}暂无已安装的协议${RESET}"
        echo ""
    fi
    echo -e "${CYAN}══════════════════════════════════════════${RESET}"
}

# ============================================================
# BBR
# ============================================================

calculate_bbr_buf() {
    local mbps=${1:-1000} region=${2:-asia}
    [[ "$mbps" =~ ^[0-9]+$ ]] || mbps=1000
    local buf=""
    if [ "$region" = "overseas" ]; then
        [ "$mbps" -le 100 ] && buf=8
        [ "$mbps" -le 200 ] && [ -z "$buf" ] && buf=16
        [ "$mbps" -le 300 ] && [ -z "$buf" ] && buf=20
        [ "$mbps" -le 500 ] && [ -z "$buf" ] && buf=32
        [ "$mbps" -le 700 ] && [ -z "$buf" ] && buf=48
        [ -z "$buf" ] && buf=64
    else
        [ "$mbps" -le 100 ] && buf=6
        [ "$mbps" -le 200 ] && [ -z "$buf" ] && buf=8
        [ "$mbps" -le 300 ] && [ -z "$buf" ] && buf=10
        [ "$mbps" -le 500 ] && [ -z "$buf" ] && buf=12
        [ "$mbps" -le 700 ] && [ -z "$buf" ] && buf=14
        [ "$mbps" -le 1000 ] && [ -z "$buf" ] && buf=16
        [ "$mbps" -le 1500 ] && [ -z "$buf" ] && buf=20
        [ "$mbps" -le 2000 ] && [ -z "$buf" ] && buf=24
        [ "$mbps" -le 2500 ] && [ -z "$buf" ] && buf=28
        [ -z "$buf" ] && buf=32
    fi
    echo "$buf"
}

install_speedtest_cli() {
    local cpu_arch url tmpdir target="$SPEEDTEST_BIN" target_dir tmp_install="" backup=""
    local old_exists=0 expected actual digest tmp_start=${#_PD_TMPFILES[@]}
    target_dir=$(dirname "$target")
    [ -d "$target_dir" ] && [ ! -L "$target_dir" ] \
        || { err "speedtest 目标目录不安全: $target_dir"; return 1; }
    if [ -L "$target" ]; then
        err "拒绝覆盖 speedtest 符号链接: $target"
        return 1
    fi
    if [ -e "$target" ]; then
        [ -f "$target" ] || { err "speedtest 目标不是普通文件: $target"; return 1; }
        [ "$(state_get system speedtest_owned 2>/dev/null || true)" = 1 ] \
            || { err "发现不属于本脚本的 speedtest，拒绝覆盖: $target"; return 1; }
        expected=$(state_get system speedtest_sha256 2>/dev/null || true)
        expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
        actual=$(sha256_file "$target" 2>/dev/null || true)
        [[ "$expected" =~ ^[0-9a-f]{64}$ ]] && [ "$actual" = "$expected" ] \
            || { err "speedtest 所有权摘要不匹配，拒绝覆盖: $target"; return 1; }
        old_exists=1
    elif command -v speedtest >/dev/null 2>&1; then
        return 0
    fi
    cpu_arch=$(uname -m)
    case "$cpu_arch" in
        x86_64|amd64) url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz" ;;
        aarch64|arm64) url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz" ;;
        *) warn "speedtest 不支持当前架构: $cpu_arch" >&2; return 1 ;;
    esac
    mktemp_dir_pd tmpdir
    download_https "$url" "$tmpdir/speedtest.tgz" "Ookla speedtest CLI 1.2.0" \
        || { cleanup_tmpfiles_from "$tmp_start"; return 1; }
    tar -tzf "$tmpdir/speedtest.tgz" | archive_paths_are_safe \
        || { cleanup_tmpfiles_from "$tmp_start"; return 1; }
    tar -xzf "$tmpdir/speedtest.tgz" -C "$tmpdir" >/dev/null 2>&1 \
        || { cleanup_tmpfiles_from "$tmp_start"; return 1; }
    [ -f "$tmpdir/speedtest" ] && [ ! -L "$tmpdir/speedtest" ] \
        || { cleanup_tmpfiles_from "$tmp_start"; return 1; }
    tmp_install=$(mktemp "$target_dir/.speedtest.XXXXXX") \
        || { cleanup_tmpfiles_from "$tmp_start"; return 1; }
    if ! install -m 0755 "$tmpdir/speedtest" "$tmp_install"; then
        rm -f "$tmp_install"; cleanup_tmpfiles_from "$tmp_start"; return 1
    fi
    if [ "$(id -u)" = 0 ] && ! chown root:root "$tmp_install"; then
        rm -f "$tmp_install"; cleanup_tmpfiles_from "$tmp_start"; return 1
    fi
    digest=$(sha256_file "$tmp_install") \
        || { rm -f "$tmp_install"; cleanup_tmpfiles_from "$tmp_start"; return 1; }
    if [ "$old_exists" = 1 ]; then
        backup=$(mktemp "$target_dir/.speedtest-backup.XXXXXX") \
            || { rm -f "$tmp_install"; cleanup_tmpfiles_from "$tmp_start"; return 1; }
        cp -p "$target" "$backup" \
            || { rm -f "$tmp_install" "$backup"; cleanup_tmpfiles_from "$tmp_start"; return 1; }
    fi
    # Recheck immediately before the rename so a resource created or changed
    # while the archive was prepared is never treated as ours.
    if [ "$old_exists" = 1 ]; then
        actual=$(sha256_file "$target" 2>/dev/null || true)
        if [ -L "$target" ] || [ ! -f "$target" ] || [ "$actual" != "$expected" ]; then
            err "speedtest 目标在安装期间发生变化，拒绝覆盖: $target"
            rm -f "$tmp_install" "$backup"
            cleanup_tmpfiles_from "$tmp_start"
            return 1
        fi
    elif [ -e "$target" ] || [ -L "$target" ]; then
        err "speedtest 目标在安装期间出现，拒绝覆盖: $target"
        rm -f "$tmp_install"
        cleanup_tmpfiles_from "$tmp_start"
        return 1
    fi
    if ! mv -f "$tmp_install" "$target"; then
        rm -f "$tmp_install" "$backup"; cleanup_tmpfiles_from "$tmp_start"; return 1
    fi
    if ! state_set_fields system "speedtest_owned=1" "speedtest_sha256=$digest"; then
        if [ "$old_exists" = 1 ]; then
            mv -f "$backup" "$target" || err "speedtest 状态写入失败且旧文件回滚失败: $target"
        else
            rm -f "$target"
        fi
        rm -f "$backup"
        cleanup_tmpfiles_from "$tmp_start"
        return 1
    fi
    rm -f "$backup"
    cleanup_tmpfiles_from "$tmp_start"
    return 0
}

parse_speedtest_upload() {
    sed -nE 's/.*[Uu]pload:[[:space:]]*([0-9]+)(\.[0-9]+)?.*/\1/p' | head -1
}

detect_bbr_bandwidth() {
    local choice="" server_id="" output="" upload="" servers="" attempt=0
    echo "" >&2
    echo -e "  ${MAGENTA}▸ 服务器带宽检测${RESET}" >&2
    echo "  [1] 自动检测（推荐）" >&2
    echo "  [2] 手动指定测速服务器 ID" >&2
    echo "  [3] 手动选择预设档位" >&2
    echo -ne "  ${MAGENTA}▸${RESET} 选择 [1]: " >&2
    read -r choice || choice=""
    choice=${choice:-1}
    case "$choice" in
        1)
            if ! install_speedtest_cli; then
                warn "speedtest 安装失败，使用默认 1000 Mbps" >&2
                echo 1000
                return 0
            fi
            step "正在搜索附近测速服务器..." >&2
            servers=$(speedtest --accept-license --accept-gdpr --servers 2>/dev/null | sed -nE 's/^[[:space:]]*([0-9]+).*/\1/p' | head -n 10 || true)
            [ -n "$servers" ] || servers="auto"
            for server_id in $servers; do
                attempt=$((attempt + 1))
                [ "$attempt" -gt 5 ] && break
                if [ "$server_id" = "auto" ]; then
                    output=$(speedtest --accept-license --accept-gdpr 2>&1 || true)
                else
                    output=$(speedtest --accept-license --accept-gdpr --server-id="$server_id" 2>&1 || true)
                fi
                upload=$(printf '%s\n' "$output" | parse_speedtest_upload || true)
                if [ -n "$upload" ] && ! printf '%s\n' "$output" | grep -qi 'FAILED\|error'; then
                    info "检测到上传带宽: ${upload} Mbps" >&2
                    echo "$upload"
                    return 0
                fi
            done
            warn "自动测速失败，使用默认 1000 Mbps" >&2
            echo 1000 ;;
        2)
            if ! install_speedtest_cli; then
                warn "speedtest 安装失败，使用默认 1000 Mbps" >&2
                echo 1000
                return 0
            fi
            echo -ne "  输入测速服务器 ID: " >&2
            read -r server_id || server_id=""
            if [[ "$server_id" =~ ^[0-9]+$ ]]; then
                output=$(speedtest --accept-license --accept-gdpr --server-id="$server_id" 2>&1 || true)
                upload=$(printf '%s\n' "$output" | parse_speedtest_upload || true)
                if [ -n "$upload" ] && ! printf '%s\n' "$output" | grep -qi 'FAILED\|error'; then
                    info "检测到上传带宽: ${upload} Mbps" >&2
                    echo "$upload"
                    return 0
                fi
            fi
            warn "指定服务器测速失败，使用默认 1000 Mbps" >&2
            echo 1000 ;;
        3)
            prompt_bbr_bandwidth_preset ;;
        *)
            echo 1000 ;;
    esac
}

prompt_bbr_bandwidth_preset() {
    local c custom
    echo "" >&2
    echo -e "  ${MAGENTA}▸ 手动选择带宽档位${RESET}" >&2
    echo "  [1] 100 Mbps   [2] 200 Mbps   [3] 300 Mbps" >&2
    echo "  [4] 500 Mbps   [5] 700 Mbps   [6] 1000 Mbps" >&2
    echo "  [7] 1500 Mbps  [8] 2000 Mbps  [9] 2500 Mbps" >&2
    echo "  [10] 自定义输入" >&2
    echo -ne "  ${MAGENTA}▸${RESET} 选择 [6]: " >&2
    read -r c || c=""
    case "${c:-6}" in
        1) echo 100 ;; 2) echo 200 ;; 3) echo 300 ;; 4) echo 500 ;; 5) echo 700 ;;
        6) echo 1000 ;; 7) echo 1500 ;; 8) echo 2000 ;; 9) echo 2500 ;;
        10)
            while true; do
                echo -ne "  输入带宽 Mbps: " >&2
                read -r custom || custom=""
                [[ "$custom" =~ ^[0-9]+$ ]] && [ "$custom" -gt 0 ] && { echo "$custom"; return 0; }
                warn "请输入有效数字" >&2
            done ;;
        *) echo 1000 ;;
    esac
}

prompt_bbr_region() {
    local c
    echo "" >&2
    echo -e "  ${MAGENTA}▸ 服务地区${RESET}" >&2
    echo "  [1] 亚太地区（港/日/新/韩等，RTT < 100ms）" >&2
    echo "  [2] 美国/欧洲（跨洋，RTT 150-300ms）" >&2
    echo -ne "  ${MAGENTA}▸${RESET} 选择 [1]: " >&2
    read -r c || c=""
    case "$c" in 2) echo overseas ;; *) echo asia ;; esac
}

apply_mss_clamp() {
    command -v iptables >/dev/null 2>&1 || return 0
    if iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -m comment --comment PD-proxy:mss -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1; then
        [ "$(state_get system mss_owned 2>/dev/null || true)" = 1 ] \
            || { err "发现带 PD-proxy 标记但所有权状态缺失的 MSS rule，拒绝接管"; return 1; }
        return 0
    fi
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -m comment --comment PD-proxy:mss -j TCPMSS --clamp-mss-to-pmtu \
        || { err "添加 MSS clamp 规则失败"; return 1; }
    state_set system mss_owned 1 || {
        iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -m comment --comment PD-proxy:mss -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || true
        return 1
    }
}

write_bbr_persist_service() {
    if [ -e /usr/local/bin/pd-bbr-apply.sh ] \
        && { [ "$(state_get system bbr_persist_owned 2>/dev/null || true)" != 1 ] \
            || ! grep -q '^# PD-proxy owned resource$' /usr/local/bin/pd-bbr-apply.sh 2>/dev/null; }; then
        err "发现非本脚本所有的 /usr/local/bin/pd-bbr-apply.sh，拒绝覆盖"
        return 1
    fi
    if [ -e "$SYSTEMD_DIR/pd-bbr-apply.service" ] \
        && { [ "$(state_get system bbr_persist_owned 2>/dev/null || true)" != 1 ] \
            || ! unit_is_pd_owned "$SYSTEMD_DIR/pd-bbr-apply.service"; }; then
        err "发现非本脚本所有的 pd-bbr-apply.service，拒绝覆盖"
        return 1
    fi
    atomic_write_file /usr/local/bin/pd-bbr-apply.sh 755 <<'EOF' || return 1
#!/usr/bin/env bash
# PD-proxy owned resource
for d in /sys/class/net/*; do
    [ -e "$d" ] || continue
    dev=$(basename "$d")
    case "$dev" in lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue ;; esac
    tc qdisc replace dev "$dev" root fq 2>/dev/null || true
done
EOF
    atomic_write_file "$SYSTEMD_DIR/pd-bbr-apply.service" 644 <<'EOF' || return 1
[Unit]
Description=PD-proxy: BBR network runtime tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/pd-bbr-apply.sh

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || return 1
    systemctl enable pd-bbr-apply.service >/dev/null || return 1
    state_set system bbr_persist_owned 1 || {
        systemctl disable --now pd-bbr-apply.service >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_DIR/pd-bbr-apply.service" /usr/local/bin/pd-bbr-apply.sh
        systemctl daemon-reload >/dev/null 2>&1 || true
        return 1
    }
}

apply_tc_fq() {
    if ! command -v tc >/dev/null 2>&1; then return 0; fi
    local applied=0 dev
    for dev in $(ls /sys/class/net/ 2>/dev/null); do
        case "$dev" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue ;;
        esac
        tc qdisc replace dev "$dev" root fq 2>/dev/null && applied=$((applied+1))
    done
    if [ "$applied" -gt 0 ]; then
        state_set system tc_fq_applied 1 || { err "记录 tc fq 运行时变更失败"; return 1; }
        info "已对 ${applied} 个网卡应用 fq 队列算法（即时生效）"
    fi
    return 0
}

select_xanmod_package() {
    if [ -n "${PD_XANMOD_PACKAGE:-}" ]; then
        echo "$PD_XANMOD_PACKAGE"
        return 0
    fi
    local flags=""
    flags=$(sed -n 's/^flags[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | head -1 || true)
    local has_v2=true has_v3=true f
    for f in cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3; do
        echo " $flags " | grep -q " $f " || has_v2=false
    done
    for f in avx avx2 bmi1 bmi2 f16c fma movbe xsave; do
        echo " $flags " | grep -q " $f " || has_v3=false
    done
    if ! echo " $flags " | grep -Eq ' (lzcnt|abm) '; then
        has_v3=false
    fi
    if $has_v2 && $has_v3; then
        echo "linux-xanmod-x64v3"
    elif $has_v2; then
        echo "linux-xanmod-x64v2"
    else
        echo "linux-xanmod-x64v1"
    fi
}

select_xanmod_package_candidates() {
    local base_pkg
    base_pkg=$(select_xanmod_package)
    case "$base_pkg" in
        linux-xanmod-x64v1)
            printf '%s\n' linux-xanmod-x64v1 linux-xanmod-lts-x64v1 ;;
        linux-xanmod-x64v2)
            printf '%s\n' linux-xanmod-x64v2 linux-xanmod-lts-x64v2 ;;
        linux-xanmod-x64v3)
            printf '%s\n' linux-xanmod-x64v3 linux-xanmod-lts-x64v3 ;;
        *)
            printf '%s\n' "$base_pkg" ;;
    esac
}

xanmod_supported_codename() {
    case "$1" in
        bookworm|trixie|forky|sid|noble|plucky|questing|resolute|faye|gigi|wilma|xia|zara|zena) return 0 ;;
        *) return 1 ;;
    esac
}

check_xanmod_disk_space() {
    local root_avail boot_avail var_avail
    root_avail=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
    [[ "$root_avail" =~ ^[0-9]+$ ]] || root_avail=0
    if [ "$root_avail" -lt 1200 ]; then
        warn "根分区可用空间不足：${root_avail}MB，安装 XanMod 内核建议至少 1200MB"
        warn "请先清理空间：apt-get clean && apt-get autoremove --purge"
        return 1
    fi
    if mountpoint -q /boot 2>/dev/null; then
        boot_avail=$(df -Pm /boot 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
        [[ "$boot_avail" =~ ^[0-9]+$ ]] || boot_avail=0
        if [ "$boot_avail" -lt 300 ]; then
            warn "/boot 可用空间不足：${boot_avail}MB，安装新内核建议至少 300MB"
            warn "请先清理旧内核或扩大 /boot 分区"
            return 1
        fi
    fi
    if mountpoint -q /var 2>/dev/null; then
        var_avail=$(df -Pm /var 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
        [[ "$var_avail" =~ ^[0-9]+$ ]] || var_avail=0
        if [ "$var_avail" -lt 600 ]; then
            warn "/var 可用空间不足：${var_avail}MB，APT 下载内核包建议至少 600MB"
            warn "请先清理 /var/cache/apt 或扩大 /var 分区"
            return 1
        fi
    fi
    return 0
}

ensure_xanmod_swap() {
    PD_XANMOD_SWAP_CREATED=0
    PD_XANMOD_SWAP_FSTAB_BAK=""
    local mem_total swap_total root_avail swap_mb=0 need_mb ans fstab_bak
    mem_total=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo 0)
    swap_total=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}' || echo 0)
    [[ "$mem_total" =~ ^[0-9]+$ ]] || mem_total=0
    [[ "$swap_total" =~ ^[0-9]+$ ]] || swap_total=0
    [ "$mem_total" -gt 0 ] || return 0
    [ "$mem_total" -ge 1024 ] || swap_mb=1024
    [ "$mem_total" -lt 512 ] && swap_mb=1536
    [ "$swap_total" -ge 512 ] && return 0
    [ "$swap_mb" -gt 0 ] || return 0
    if [ -e /swapfile ] || [ -L /swapfile ]; then
        warn "检测到 /swapfile 已存在，避免覆盖现有路径，已停止 BBRv3 安装"
        return 1
    fi
    root_avail=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
    [[ "$root_avail" =~ ^[0-9]+$ ]] || root_avail=0
    need_mb=$((swap_mb + 1500))
    if [ "$root_avail" -lt "$need_mb" ]; then
        warn "内存 ${mem_total}MB 且 swap 不足，但根分区可用 ${root_avail}MB，不足以安全创建 ${swap_mb}MB swap 并安装内核"
        warn "请扩容磁盘或手动清理后重试；已停止 BBRv3 安装"
        return 1
    fi
    warn "检测到内存较小：${mem_total}MB，当前 swap：${swap_total}MB"
    warn "建议创建 ${swap_mb}MB swap，降低内核安装时内存不足风险"
    echo -ne "  是否创建 swap？(y/N): "
    read -r ans || ans=""
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { info "已跳过 swap 创建"; return 0; }
    step "创建 ${swap_mb}MB swap..."
    fstab_bak="/etc/fstab.pdproxy.$(date +%Y%m%d%H%M%S).bak"
    cp /etc/fstab "$fstab_bak" 2>/dev/null || true
    if command -v fallocate >/dev/null 2>&1 && fallocate -l "${swap_mb}M" /swapfile 2>/dev/null; then
        :
    elif ! dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=none 2>/dev/null; then
        rm -f /swapfile
        [ -f "$fstab_bak" ] && cp "$fstab_bak" /etc/fstab 2>/dev/null || true
        warn "swap 文件创建失败，已停止 BBRv3 安装"
        return 1
    fi
    chmod 600 /swapfile
    if ! mkswap /swapfile >/dev/null 2>&1 || ! swapon /swapfile >/dev/null 2>&1; then
        swapoff /swapfile >/dev/null 2>&1 || true
        rm -f /swapfile
        [ -f "$fstab_bak" ] && cp "$fstab_bak" /etc/fstab 2>/dev/null || true
        warn "swap 创建失败，已回滚，已停止 BBRv3 安装"
        return 1
    fi
    if ! grep -q '^/swapfile ' /etc/fstab 2>/dev/null; then
        local fstab_tmp
        fstab_tmp=$(mktemp /etc/.fstab.pd.XXXXXX) || return 1
        if ! awk '{ print } END { print "/swapfile none swap sw 0 0" }' /etc/fstab > "$fstab_tmp" \
            || ! atomic_write_file /etc/fstab 644 < "$fstab_tmp"; then
            rm -f "$fstab_tmp"
            swapoff /swapfile >/dev/null 2>&1 || true
            rm -f /swapfile
            [ -f "$fstab_bak" ] && cp "$fstab_bak" /etc/fstab 2>/dev/null || true
            warn "写入 /etc/fstab 失败，swap 已回滚，已停止 BBRv3 安装"
            return 1
        fi
        rm -f "$fstab_tmp"
    fi
    PD_XANMOD_SWAP_CREATED=1
    PD_XANMOD_SWAP_FSTAB_BAK="$fstab_bak"
    state_set system swap_owned 1 || { rollback_xanmod_swap_if_created; return 1; }
    state_set system swap_bytes "$(stat -c%s /swapfile 2>/dev/null || echo 0)" || { rollback_xanmod_swap_if_created; return 1; }
    state_set system swap_fstab_owned 1 || { rollback_xanmod_swap_if_created; return 1; }
    info "swap 已创建并启用：${swap_mb}MB"
}

rollback_xanmod_swap_if_created() {
    [ "${PD_XANMOD_SWAP_CREATED:-0}" = "1" ] || return 0
    swapoff /swapfile >/dev/null 2>&1 || true
    rm -f /swapfile
    if [ -n "${PD_XANMOD_SWAP_FSTAB_BAK:-}" ] && [ -f "$PD_XANMOD_SWAP_FSTAB_BAK" ]; then
        cp "$PD_XANMOD_SWAP_FSTAB_BAK" /etc/fstab 2>/dev/null || true
    else
        sed -i '\#^/swapfile #d' /etc/fstab 2>/dev/null || true
    fi
    PD_XANMOD_SWAP_CREATED=0
    state_set system swap_owned 0 2>/dev/null || true
    state_set system swap_fstab_owned 0 2>/dev/null || true
    warn "已回滚本次为 BBRv3 创建的 swap"
}

recover_xanmod_apt_failure() {
    rm -f /etc/apt/sources.list.d/xanmod-release.list
    apt-get -f install -y >/dev/null 2>&1 || true
    apt-get clean >/dev/null 2>&1 || true
}

enable_bbr() {
    local running_cc buf_mb buf_bytes band region
    running_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")

    # ① 已运行：输出摘要，但仍继续刷新调优参数
    if [ "$running_cc" = "bbr" ]; then
        local qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
        local rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "?")
        echo -e "  BBR 已运行：${GREEN}${running_cc}${RESET} / qdisc: ${CYAN}${qdisc}${RESET}"
        echo -e "  缓冲上限: rmem_max=$(numfmt --to=iec "$rmem_max" 2>/dev/null || echo "$rmem_max")"
    fi

    # ② 未运行 BBR 时才检查内核/虚拟化；已运行 BBR 则允许刷新调优参数。
    if [ "$running_cc" != "bbr" ]; then
        local kernel_major kernel_minor
        kernel_major=$(uname -r | cut -d. -f1)
        kernel_minor=$(uname -r | cut -d. -f2 | sed 's/[^0-9].*//')
        [[ "$kernel_major" =~ ^[0-9]+$ ]] || kernel_major=0
        [[ "$kernel_minor" =~ ^[0-9]+$ ]] || kernel_minor=0
        if [ "$kernel_major" -lt 4 ] || { [ "$kernel_major" -eq 4 ] && [ "$kernel_minor" -lt 9 ]; }; then
            warn "内核版本过低 ($(uname -r))，BBR 需要 ≥ 4.9"
            return 1
        fi

        if detect_virt 2>/dev/null | grep -qiE 'openvz|virtuozzo|lxc'; then
            warn "当前虚拟化环境不支持加载内核模块，无法开启 BBR"
            return 1
        fi
    fi

    # 不改写 /etc/sysctl.conf 或用户的其他 sysctl 文件，只管理自己的独立文件。

    # ⑤ 按 vps-tcp-tune 逻辑：自动/手动带宽 + 地区决定缓冲区
    if [ -n "${PD_BBR_BANDWIDTH:-}" ]; then
        band="$PD_BBR_BANDWIDTH"
    elif [ -t 0 ]; then
        band=$(detect_bbr_bandwidth)
    else
        band=1000
    fi
    if [ -n "${PD_BBR_REGION:-}" ]; then
        region="$PD_BBR_REGION"
    elif [ -t 0 ]; then
        region=$(prompt_bbr_region)
    else
        region=asia
    fi
    [[ "$band" =~ ^[0-9]+$ ]] || band=1000
    case "$region" in asia|overseas) ;; *) region=asia ;; esac
    buf_mb=$(calculate_bbr_buf "$band" "$region")
    buf_bytes=$((buf_mb * 1024 * 1024))

    local region_label="亚太"
    [ "$region" = "overseas" ] && region_label="欧美"

    step "开启 BBR (带宽: ${band} Mbps / 地区: ${region_label} / 缓冲: ${buf_mb} MB)"

    # ⑥ 写入独立配置文件
    mkdir -p /etc/sysctl.d
    local sysctl_conf=/etc/sysctl.d/99-pdproxy.conf
    if [ -e "$sysctl_conf" ] \
        && { [ "$(state_get system bbr_sysctl_owned 2>/dev/null || true)" != 1 ] \
            || ! grep -q '^# PD-proxy owned resource$' "$sysctl_conf" 2>/dev/null; }; then
        err "$sysctl_conf 已存在且所有权未知，拒绝覆盖"
        return 1
    fi
    atomic_write_file "$sysctl_conf" 644 << SYSCTL_EOF || return 1
# PD-proxy owned resource
# BBR 优化 ($(date '+%F %T'))
# 带宽: ${band} Mbps | 地区: ${region_label} | 缓冲: ${buf_mb} MB

# 拥塞控制
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# TCP 缓冲 (${buf_mb}MB)
net.core.rmem_max=${buf_bytes}
net.core.wmem_max=${buf_bytes}
net.ipv4.tcp_rmem=4096 87380 ${buf_bytes}
net.ipv4.tcp_wmem=4096 65536 ${buf_bytes}

# 连接优化
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=1024 65535
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=8192
net.core.netdev_max_backlog=5000

# TCP 高级
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_fastopen=3

# 连接回收
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_max_tw_buckets=5000

# 保活
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5

# UDP (Hysteria2 / QUIC)
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

# 安全
net.ipv4.tcp_syncookies=1

# 虚拟内存与调度优化
vm.swappiness=5
vm.dirty_ratio=15
vm.dirty_background_ratio=5
vm.overcommit_memory=1
vm.vfs_cache_pressure=50
kernel.sched_autogroup_enabled=0
SYSCTL_EOF
    state_set system bbr_sysctl_owned 1 || { rm -f "$sysctl_conf"; return 1; }

    # ⑦ 应用：先尝试加载模块，再应用 sysctl，避免 congestion_control=bbr 失败提前退出。
    modprobe tcp_bbr 2>/dev/null || true
    sysctl -p "$sysctl_conf" >/dev/null 2>&1 || { err "部分 BBR 内核参数应用失败"; return 1; }

    # ⑧ tc fq 即时生效
    apply_tc_fq || return 1
    apply_mss_clamp || return 1
    write_bbr_persist_service || return 1

    # ⑨ 验证
    running_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [ "$running_cc" = "bbr" ]; then
        info "BBR 已开启 (${running_cc})"
    else
        warn "BBR 未生效 (当前: ${running_cc})，可能需要重启系统"
        return 1
    fi
    return 0
}

# ---- BBRv3 内核（XanMod）----
enable_bbrv3_kernel() {
    info "正在检查内核..."

    # ① 已安装
    if grep -qi 'xanmod' /proc/version 2>/dev/null; then
        info "XanMod 内核已运行，将检查仓库中是否有可更新内核"
    fi

    # ② 虚拟化限制
    if detect_virt 2>/dev/null | grep -qiE 'openvz|virtuozzo|lxc'; then
        warn "当前虚拟化环境不支持更换内核（$(detect_virt 2>/dev/null)），跳过"
        return 1
    fi

    # ③ 架构限制：XanMod x64 系列仅适用于 x86_64/amd64
    case "$(uname -m)" in
        x86_64|amd64) ;;
        *) warn "XanMod x64 内核仅支持 x86_64/amd64，当前架构: $(uname -m)"; return 1 ;;
    esac

    # ④ 确认
    echo ""
    warn "安装 XanMod 内核后需要重启系统才能生效"
    echo -ne "  是否继续？(y/N): "
    read -r ans || ans=""
    [ "$ans" != "y" ] && [ "$ans" != "Y" ] && { info "已取消"; return 0; }

    # ⑤ 安装依赖
    step "安装 XanMod BBRv3 内核..."
    check_xanmod_disk_space || return 1
    ensure_xanmod_swap || return 1
    apt-get update -qq || { rollback_xanmod_swap_if_created; warn "apt-get update 失败，无法安装 XanMod"; return 1; }
    apt-get install -y -qq gnupg lsb-release curl ca-certificates >/dev/null || { rollback_xanmod_swap_if_created; warn "安装 XanMod 依赖失败"; return 1; }
    mkdir -p /etc/apt/keyrings || return 1

    local key_tmp
    mktemp_pd key_tmp
    curl_https -fsSL https://dl.xanmod.org/archive.key -o "$key_tmp" || { rollback_xanmod_swap_if_created; warn "下载 XanMod GPG key 失败"; return 1; }
    if [ -n "${PD_XANMOD_KEY_SHA256:-}" ]; then
        verify_expected_sha256 "$key_tmp" "$PD_XANMOD_KEY_SHA256" "XanMod archive.key" \
            || { rollback_xanmod_swap_if_created; return 1; }
    elif [ "${PD_STRICT_CHECKSUM:-0}" = 1 ]; then
        rollback_xanmod_swap_if_created
        err "XanMod archive.key 未设置 PD_XANMOD_KEY_SHA256；严格模式拒绝导入"
        return 1
    else
        warn "XanMod archive.key 仅由 HTTPS 获取，未固定独立摘要；可设置 PD_XANMOD_KEY_SHA256"
    fi
    if [ -e /etc/apt/keyrings/xanmod-archive-keyring.gpg ]; then
        local old_key_sha current_key_sha
        old_key_sha=$(state_get system xanmod_key_sha256 2>/dev/null || true)
        current_key_sha=$(sha256_file /etc/apt/keyrings/xanmod-archive-keyring.gpg 2>/dev/null || true)
        if [ "$(state_get system xanmod_key_owned 2>/dev/null || true)" != 1 ] \
            || [ -z "$old_key_sha" ] || [ "$old_key_sha" != "$current_key_sha" ]; then
            warn "XanMod keyring 已存在但所有权/摘要无法确认，拒绝覆盖"
            rollback_xanmod_swap_if_created
            return 1
        fi
    fi
    rm -f /etc/apt/keyrings/xanmod-archive-keyring.gpg || return 1
    gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg "$key_tmp" 2>/dev/null || { rollback_xanmod_swap_if_created; warn "导入 XanMod GPG key 失败"; return 1; }
    state_set system xanmod_key_owned 1 || { rm -f /etc/apt/keyrings/xanmod-archive-keyring.gpg; return 1; }
    state_set system xanmod_key_sha256 "$(sha256_file /etc/apt/keyrings/xanmod-archive-keyring.gpg)" \
        || { rm -f /etc/apt/keyrings/xanmod-archive-keyring.gpg; return 1; }
    local codename
    codename=$(lsb_release -sc 2>/dev/null || sed -n 's/^VERSION_CODENAME=//p' /etc/os-release 2>/dev/null | head -1 || true)
    [ -n "$codename" ] || { rollback_xanmod_swap_if_created; warn "无法识别系统代号，无法添加 XanMod 源"; return 1; }
    if ! xanmod_supported_codename "$codename"; then
        warn "XanMod 官方源暂不支持当前系统代号: $codename"
        warn "支持: bookworm/trixie/forky/sid/noble/plucky/questing/resolute 以及 Linux Mint faye/gigi/wilma/xia/zara/zena"
        warn "已取消 BBRv3 内核安装；可继续使用 pd --bbr 开启普通 BBR"
        rollback_xanmod_swap_if_created
        return 1
    fi
    if [ -e /etc/apt/sources.list.d/xanmod-release.list ] \
        && { [ "$(state_get system xanmod_repo_owned 2>/dev/null || true)" != 1 ] \
            || ! grep -q '^# PD-proxy owned resource$' /etc/apt/sources.list.d/xanmod-release.list 2>/dev/null; }; then
            warn "XanMod 源已存在且所有权未知，拒绝覆盖"
            rollback_xanmod_swap_if_created
            return 1
    fi
    printf '%s\n' "# PD-proxy owned resource" "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] https://deb.xanmod.org ${codename} main" \
        | atomic_write_file /etc/apt/sources.list.d/xanmod-release.list 644 || return 1
    state_set system xanmod_repo_owned 1 || { rm -f /etc/apt/sources.list.d/xanmod-release.list; return 1; }
    state_set system xanmod_key_owned 1 || return 1

    apt-get update -qq || { rm -f /etc/apt/sources.list.d/xanmod-release.list; rollback_xanmod_swap_if_created; warn "刷新 XanMod APT 源失败，已移除 XanMod 源"; return 1; }
    local xanmod_pkg="" candidate
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        if apt-cache show "$candidate" >/dev/null 2>&1; then
            xanmod_pkg="$candidate"
            break
        fi
        warn "当前系统源中没有 $candidate 包，尝试下一个兼容包..."
    done < <(select_xanmod_package_candidates)
    if [ -z "$xanmod_pkg" ]; then
        rm -f /etc/apt/sources.list.d/xanmod-release.list
        warn "当前 XanMod 源没有适合此 CPU/系统的内核包，已移除 XanMod 源"
        rollback_xanmod_swap_if_created
        return 1
    fi
    info "选择内核包: $xanmod_pkg"
    if ! apt-get install -y -qq "$xanmod_pkg" 2>/dev/null; then
        recover_xanmod_apt_failure
        rollback_xanmod_swap_if_created
        warn "XanMod 内核安装失败，已移除 XanMod 源并尝试修复 APT 状态"
        warn "如果日志出现 No space left on device，请清理磁盘后重试：apt-get clean && apt-get autoremove --purge"
        return 1
    fi
    update-grub 2>/dev/null || true

    info "XanMod BBRv3 内核已安装"
    echo ""
    warn "需要重启才能生效，重启后执行 pd --bbr 即可开启 BBRv3"
    echo -ne "  是否现在重启？(y/N): "
    read -r ans || ans=""
    [ "$ans" != "y" ] && [ "$ans" != "Y" ] && { info "请稍后手动重启"; return 0; }
    reboot
}

# ============================================================
# 自安装（pd 命令）
# ============================================================

fetch_self_update() {
    local dest="$1"
    validate_https_url "$SCRIPT_URL" || return 1
    if [ "$SCRIPT_URL" != "$DEFAULT_SCRIPT_URL" ] && [ -z "${PD_SCRIPT_SHA256:-}" ]; then
        err "自定义 PD_SCRIPT_URL 必须同时设置 PD_SCRIPT_SHA256，拒绝静默信任"
        return 1
    fi
    curl_https -fsSL --retry 3 --connect-timeout 15 --max-time 120 "$SCRIPT_URL" -o "$dest" || return 1
    if [ -n "${PD_SCRIPT_SHA256:-}" ]; then
        verify_expected_sha256 "$dest" "$PD_SCRIPT_SHA256" "PD-proxy 自更新脚本" || return 1
    elif [ "${PD_STRICT_CHECKSUM:-0}" = 1 ]; then
        err "自更新脚本没有 PD_SCRIPT_SHA256；严格模式拒绝继续"
        return 1
    else
        warn "官方 raw 自更新脚本没有独立摘要；已完成 HTTPS 与 bash -n 校验。可设置 PD_SCRIPT_SHA256 固定内容"
    fi
}

atomic_install_script() {
    local source="$1" target="$BASE_DIR/install.sh" tmp
    [ ! -L "$target" ] || { err "拒绝覆盖符号链接脚本: $target"; return 1; }
    tmp=$(mktemp "$BASE_DIR/.install.sh.XXXXXX") || return 1
    cp "$source" "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 755 "$tmp" || { rm -f "$tmp"; return 1; }
    [ "$(id -u)" != 0 ] || chown root:root "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
}

self_install() {
    assert_base_dir_safe || return 1
    mkdir -p "$BASE_DIR" || return 1
    chmod 755 "$BASE_DIR" || return 1
    [ "$(id -u)" != 0 ] || chown root:root "$BASE_DIR" || return 1
    printf '%s\n' "PD-proxy owned resource" | atomic_write_file "$BASE_DIR/.pd-proxy-owned" 600 || return 1
    if [ -L "$INSTALLED_BIN" ]; then
        [ "$(readlink "$INSTALLED_BIN")" = "$BASE_DIR/install.sh" ] \
            || { err "pd 入口指向未知目标，拒绝覆盖: $INSTALLED_BIN"; return 1; }
    elif [ -e "$INSTALLED_BIN" ]; then
        err "pd 入口已存在且非本脚本符号链接，拒绝覆盖: $INSTALLED_BIN"
        return 1
    fi
    # 直接运行修复版时，优先安装当前脚本，避免后续 pd 命令回退到 GitHub 原版。
    local source_path="${BASH_SOURCE[0]}"
    local source_is_file=false
    case "$source_path" in
        ""|bash|-|pd) ;;
        /dev/fd/*|/proc/*/fd/*) ;;
        *) [ -r "$source_path" ] && source_is_file=true ;;
    esac
    local install_from_url=false
    [ -n "${SCRIPT_URL:-}" ] && install_from_url=true
    if [ "${PD_UPDATE:-}" = "1" ]; then
        if $install_from_url; then
            local tmp_pd
            mktemp_pd tmp_pd
            fetch_self_update "$tmp_pd" || {
                rm -f "$tmp_pd"
                warn "无法从 SCRIPT_URL 同步脚本: $SCRIPT_URL"
                return 1
            }
            bash -n "$tmp_pd" 2>/dev/null || {
                rm -f "$tmp_pd"
                warn "下载到的脚本语法校验失败，已保留当前版本"
                return 1
            }
            if downloaded_script_is_older "$tmp_pd"; then
                local remote_ver
                remote_ver=$(script_file_version "$tmp_pd")
                rm -f "$tmp_pd"
                warn "远端脚本版本 $remote_ver 低于当前 $VERSION，已拒绝降级"
                return 1
            fi
            atomic_install_script "$tmp_pd" || return 1
        elif $source_is_file; then
            local src_path dst_path
            src_path=$(readlink -f "$source_path" 2>/dev/null || echo "$source_path")
            dst_path=$(readlink -f "$BASE_DIR/install.sh" 2>/dev/null || echo "")
            if [ "$src_path" != "$dst_path" ]; then
                atomic_install_script "$source_path" || return 1
            fi
        elif [ ! -f "$BASE_DIR/install.sh" ]; then
            warn "找不到当前脚本文件，无法刷新 /opt/pd/install.sh"
            return 1
        fi
    elif $source_is_file; then
        local src_path dst_path
        src_path=$(readlink -f "$source_path" 2>/dev/null || echo "$source_path")
        dst_path=$(readlink -f "$BASE_DIR/install.sh" 2>/dev/null || echo "")
        if [ "$src_path" != "$dst_path" ]; then
            atomic_install_script "$source_path" || return 1
        fi
    elif $install_from_url; then
        local tmp_pd
        mktemp_pd tmp_pd
        fetch_self_update "$tmp_pd" || {
            rm -f "$tmp_pd"
            warn "无法从 SCRIPT_URL 同步脚本: $SCRIPT_URL"
            return 1
        }
        bash -n "$tmp_pd" 2>/dev/null || {
            rm -f "$tmp_pd"
            warn "下载到的脚本语法校验失败，无法持久化 pd 命令"
            return 1
        }
        if downloaded_script_is_older "$tmp_pd"; then
            local remote_ver
            remote_ver=$(script_file_version "$tmp_pd")
            rm -f "$tmp_pd"
            warn "远端脚本版本 $remote_ver 低于当前 $VERSION，已拒绝降级"
            return 1
        fi
        atomic_install_script "$tmp_pd" || return 1
    elif [ ! -f "$BASE_DIR/install.sh" ]; then
            warn "当前脚本不是文件，无法持久化 pd 命令；请设置 PD_SCRIPT_URL 或下载后运行"
            return 1
    fi
    chmod 755 "$BASE_DIR/install.sh" || return 1
    [ "$(id -u)" != 0 ] || chown root:root "$BASE_DIR/install.sh" || return 1
    [ -L "$INSTALLED_BIN" ] || ln -s "$BASE_DIR/install.sh" "$INSTALLED_BIN" || return 1
}

# ============================================================
# 卸载全部
# ============================================================

cleanup_managed_system_resources() {
    local rc=0 owned expected actual bytes tmp unit script
    if [ "$(state_get system bbr_sysctl_owned 2>/dev/null || true)" = 1 ]; then
        if [ -f /etc/sysctl.d/99-pdproxy.conf ] && grep -q '^# PD-proxy owned resource$' /etc/sysctl.d/99-pdproxy.conf; then
            rm -f /etc/sysctl.d/99-pdproxy.conf || rc=1
            warn "已删除本脚本的 BBR sysctl 文件；当前运行时参数保持到重启或管理员重新加载 sysctl"
        else
            warn "BBR sysctl 文件已变化或缺失，无法安全自动恢复，已保留"
        fi
    elif [ -e /etc/sysctl.d/99-pdproxy.conf ]; then
        warn "未记录 /etc/sysctl.d/99-pdproxy.conf 所有权，已保留"
    fi
    if [ "$(state_get system tc_fq_applied 2>/dev/null || true)" = 1 ]; then
        warn "tc fq 属于运行时变更且安装前 qdisc 未知，无法安全自动恢复；当前设置保留到重启或管理员调整"
    fi

    unit="$SYSTEMD_DIR/pd-bbr-apply.service"; script=/usr/local/bin/pd-bbr-apply.sh
    if [ "$(state_get system bbr_persist_owned 2>/dev/null || true)" = 1 ]; then
        if unit_is_pd_owned "$unit" && grep -q '^# PD-proxy owned resource$' "$script" 2>/dev/null; then
            systemctl disable --now pd-bbr-apply.service >/dev/null 2>&1 || true
            rm -f "$unit" "$script" || rc=1
            systemctl daemon-reload >/dev/null 2>&1 || rc=1
        else
            warn "BBR 持久化 unit/脚本已变化，无法确认所有权，已保留"
        fi
    elif [ -e "$unit" ] || [ -e "$script" ]; then
        warn "未记录 BBR 持久化资源所有权，已保留"
    fi

    if [ "$(state_get system mss_owned 2>/dev/null || true)" = 1 ]; then
        if command -v iptables >/dev/null 2>&1; then
            if iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -m comment --comment PD-proxy:mss -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1; then
                iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -m comment --comment PD-proxy:mss -j TCPMSS --clamp-mss-to-pmtu || rc=1
            else
                warn "未找到带 PD-proxy 标记的 MSS rule；未标记规则所有权不可证明，已保留"
            fi
        else
            warn "缺少 iptables，无法安全清理本脚本的 MSS rule；已保留"
        fi
    fi

    if [ "$(state_get system speedtest_owned 2>/dev/null || true)" = 1 ]; then
        expected=$(state_get system speedtest_sha256 2>/dev/null || true)
        actual=$(sha256_file "$SPEEDTEST_BIN" 2>/dev/null || true)
        if [ -n "$expected" ] && [ "$actual" = "$expected" ]; then
            if [ ! -L "$SPEEDTEST_BIN" ] && [ -f "$SPEEDTEST_BIN" ]; then
                rm -f "$SPEEDTEST_BIN" || rc=1
            else
                rc=1
            fi
        else
            warn "speedtest 二进制已变化，无法确认仍是本脚本安装的版本，已保留"
        fi
    fi

    if [ "$(state_get system swap_owned 2>/dev/null || true)" = 1 ]; then
        expected=$(state_get system swap_bytes 2>/dev/null || true)
        bytes=$(stat -c%s /swapfile 2>/dev/null || echo "")
        if [ -f /swapfile ] && [ -n "$expected" ] && [ "$bytes" = "$expected" ] \
            && [ "$(grep -c '^/swapfile none swap sw 0 0$' /etc/fstab 2>/dev/null || true)" = 1 ]; then
            swapoff /swapfile >/dev/null 2>&1 || rc=1
            if [ "$rc" = 0 ]; then
                tmp=$(mktemp /etc/.fstab.pd.XXXXXX) || return 1
                awk '$0 != "/swapfile none swap sw 0 0" { print }' /etc/fstab > "$tmp" || { rm -f "$tmp"; return 1; }
                atomic_write_file /etc/fstab 644 < "$tmp" || rc=1
                rm -f "$tmp"
                [ "$rc" != 0 ] || rm -f /swapfile || rc=1
            fi
        else
            warn "swapfile 大小或 fstab 记录已变化，无法安全自动恢复，已保留"
        fi
    elif [ -e /swapfile ]; then
        warn "/swapfile 并非状态中记录的本脚本资源，已保留"
    fi

    if [ "$(state_get system xanmod_repo_owned 2>/dev/null || true)" = 1 ]; then
        if grep -q '^# PD-proxy owned resource$' /etc/apt/sources.list.d/xanmod-release.list 2>/dev/null; then
            rm -f /etc/apt/sources.list.d/xanmod-release.list || rc=1
        else
            warn "XanMod 源文件已变化，已保留"
        fi
    fi
    if [ "$(state_get system xanmod_key_owned 2>/dev/null || true)" = 1 ]; then
        expected=$(state_get system xanmod_key_sha256 2>/dev/null || true)
        actual=$(sha256_file /etc/apt/keyrings/xanmod-archive-keyring.gpg 2>/dev/null || true)
        if [ -n "$expected" ] && [ "$actual" = "$expected" ]; then
            rm -f /etc/apt/keyrings/xanmod-archive-keyring.gpg || rc=1
        else
            warn "XanMod keyring 已变化，已保留"
        fi
    fi
    if dpkg-query -W 'linux-xanmod*' >/dev/null 2>&1; then
        warn "XanMod 内核包不会由 remove-all 自动删除；自动删除当前/启动内核不安全"
    fi
    [ ! -e /etc/sysctl.conf.pdproxy.bak ] || warn "历史 /etc/sysctl.conf.pdproxy.bak 所有权不可证明，已保留"
    return "$rc"
}

remove_all() {
    echo -e "${RED}⚠ 即将卸载本脚本记录的代理协议、入口和可确认所有权的系统资源${RESET}"
    if [ "${PD_YES:-}" = "1" ] || [ "${1:-}" = "--yes" ]; then
        info "自动确认 (--yes)"
    else
        echo -n "确认？输入 yes: "
        read -r confirm || confirm=""
        [ "$confirm" = "yes" ] || { info "已取消"; return 0; }
    fi

    local proto failed=0 target entry
    for proto in $ALL_PROTOS; do
        if state_installed "$(pkey "$proto")"; then
            if ! uninstall_protocol "$proto"; then
                err "$(pname "$proto") 卸载失败；保留 PD-proxy 状态和入口以便重试"
                failed=1
            fi
        elif [ -e "$(pdir "$proto")" ] || [ -L "$(pdir "$proto")" ] \
            || [ -e "$SYSTEMD_DIR/$(psvc "$proto").service" ] || [ -L "$SYSTEMD_DIR/$(psvc "$proto").service" ]; then
            err "发现状态外的 $(pname "$proto") 资源，拒绝猜测所有权或删除"
            failed=1
        fi
    done
    if ! state_installed snell && { [ -e /opt/shadowtls ] || [ -L /opt/shadowtls ] \
        || [ -e "$SYSTEMD_DIR/shadowtls-snell.service" ] || [ -L "$SYSTEMD_DIR/shadowtls-snell.service" ]; }; then
        err "发现状态外的 ShadowTLS 资源，拒绝删除"
        failed=1
    fi
    if ! state_installed hy2 && { [ -e "$SYSTEMD_DIR/pd-hy2-hop.service" ] || [ -L "$SYSTEMD_DIR/pd-hy2-hop.service" ]; }; then
        err "发现状态外的 HY2 hop unit，拒绝删除"
        failed=1
    fi
    [ "$failed" -eq 0 ] || return 1
    cleanup_managed_system_resources || return 1

    if [ -L "$INSTALLED_BIN" ]; then
        target=$(readlink "$INSTALLED_BIN")
        [ "$target" = "$BASE_DIR/install.sh" ] || { err "拒绝删除目标未知的 pd 符号链接: $INSTALLED_BIN -> $target"; return 1; }
        rm -f "$INSTALLED_BIN" || return 1
    elif [ -e "$INSTALLED_BIN" ]; then
        err "拒绝删除非本脚本所有的入口: $INSTALLED_BIN"
        return 1
    fi

    [ ! -L "$BASE_DIR" ] || { err "拒绝删除符号链接状态目录: $BASE_DIR"; return 1; }
    if [ -d "$BASE_DIR" ]; then
        for entry in "$BASE_DIR"/* "$BASE_DIR"/.[!.]* "$BASE_DIR"/..?*; do
            [ -e "$entry" ] || continue
            case "$(basename "$entry")" in
                state|install.sh|export.conf|.pd-proxy-owned|.snell-version-*|.snell-v4-version-*) rm -f "$entry" || return 1 ;;
                *) err "状态目录含未知资源，拒绝递归删除: $entry"; return 1 ;;
            esac
        done
        rmdir "$BASE_DIR" || { err "状态目录非空，已保留: $BASE_DIR"; return 1; }
    fi
    info "PD-proxy 管理且所有权可确认的资源已卸载；上述保留项需管理员复核"
    return 0
}

# ============================================================
# 入口
# ============================================================

# 交互式协议选择
pick_proto() {
    local action="$1" func="$2" mode="${3:-read}"
    echo ""
    echo "选择要${action}的协议:"
    local -a _picks=()
    for p in $ALL_PROTOS; do
        if state_installed "$(pkey "$p")"; then
            _picks+=("$p")
            echo "  ${#_picks[@]}) $(pname "$p")"
        fi
    done
    [ ${#_picks[@]} -eq 0 ] && { warn "没有已安装的协议"; return; }
    echo -n "选择: "
    read -r pick
    [ "$pick" -ge 1 ] 2>/dev/null || { warn "无效选择"; return; }
    local target="${_picks[$((pick - 1))]:-}"
    [ -n "$target" ] || { warn "无效选择"; return; }
    if [ "$mode" = write ]; then
        run_write_locked "$func" "$target"
    else
        "$func" "$target"
    fi
}

run_export() {
    detect_os; detect_arch; get_ip
    mkdir -p "$BASE_DIR"
    local tmp
    tmp=$(mktemp "$BASE_DIR/.export.XXXXXX") || return 1
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    {
        echo "# PD-proxy 导出 — $(date)"
        for p in $ALL_PROTOS; do
            if state_installed "$(pkey "$p")"; then
                echo ""
                echo "# $(pname "$p")"
                show_config_only "$p"
            fi
        done
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    atomic_write_file "$BASE_DIR/export.conf" 600 < "$tmp" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    info "配置已导出到 $BASE_DIR/export.conf"
}

declare -a _DOCTOR_IDS=() _DOCTOR_STATUS=() _DOCTOR_MESSAGES=()
_DOCTOR_FAILED=0

doctor_add() {
    local id="$1" status="$2" message="$3"
    _DOCTOR_IDS+=("$id")
    _DOCTOR_STATUS+=("$status")
    _DOCTOR_MESSAGES+=("$message")
    [ "$status" != fail ] || _DOCTOR_FAILED=1
}

doctor_firewall() {
    local key="$1" backend spec transport owned check4=0 check6=0 failed=0
    backend=$(state_get "$key" fw_backend 2>/dev/null || true)
    spec=$(state_get "$key" fw_spec 2>/dev/null || true)
    transport=$(state_get "$key" fw_proto 2>/dev/null || true)
    owned=$(state_get "$key" fw_owned 2>/dev/null || true)
    case "$backend" in
        none) doctor_add "${key}.firewall" warn "未检测到本机防火墙后端，请检查云防火墙 ${spec}/${transport}" ;;
        ufw)
            if command -v ufw >/dev/null 2>&1 && ufw_rule_exists "${spec}/${transport}"; then
                doctor_add "${key}.firewall" ok "ufw 规则存在（owned=${owned:-no}）"
            else
                doctor_add "${key}.firewall" fail "状态记录的 ufw 规则不存在"
            fi ;;
        iptables)
            # Empty ownership is the legacy IPv4-only state.  Otherwise verify
            # every family explicitly recorded as owned, and no unrecorded one.
            [ -n "$owned" ] || check4=1
            [[ ",$owned," == *,iptables4,* ]] && check4=1
            [[ ",$owned," == *,iptables6,* ]] && check6=1
            if [ "$check4" = 0 ] && [ "$check6" = 0 ]; then
                doctor_add "${key}.firewall" fail "iptables 所有权记录无效: $owned"
                return
            fi
            if [ "$check4" = 1 ]; then
                command -v iptables >/dev/null 2>&1 \
                    && iptables -C INPUT -p "$transport" --dport "$spec" -j ACCEPT >/dev/null 2>&1 \
                    || failed=1
            fi
            if [ "$check6" = 1 ]; then
                command -v ip6tables >/dev/null 2>&1 \
                    && ip6tables -C INPUT -p "$transport" --dport "$spec" -j ACCEPT >/dev/null 2>&1 \
                    || failed=1
            fi
            if [ "$failed" = 0 ]; then
                doctor_add "${key}.firewall" ok "iptables 规则存在（owned=${owned:-legacy-ipv4}）"
            else
                doctor_add "${key}.firewall" fail "状态记录的 iptables 规则不存在（owned=${owned:-legacy-ipv4}）"
            fi ;;
        *) doctor_add "${key}.firewall" warn "缺少可核验的防火墙状态" ;;
    esac
}

doctor_protocol() {
    local proto="$1" key svc public_svc dir bin port transport active=0 port_valid=0 listening=0
    local recorded4 recorded6 actual4=0 actual6=0 probe4 probe6 family_confirmed=0
    key=$(pkey "$proto"); svc=$(psvc "$proto"); dir=$(pdir "$proto"); bin=$(pbin "$proto")
    public_svc="$svc"
    state_installed "$key" || return 0
    if [ -d "$dir" ] && [ -x "$bin" ] && unit_is_pd_owned "$SYSTEMD_DIR/${svc}.service"; then
        doctor_add "${key}.state" ok "状态、目录、二进制和 unit 一致"
    else
        doctor_add "${key}.state" fail "installed 状态与目录/二进制/unit 不一致"
    fi
    systemctl is-active --quiet "$svc" 2>/dev/null && active=1
    [ "$active" = 1 ] && doctor_add "${key}.service" ok "$svc 正在运行" \
        || doctor_add "${key}.service" fail "$svc 未运行"
    port=$(state_get "$key" port 2>/dev/null || true)
    transport=$(protocol_transport "$proto")
    [ "$proto" = snell ] && [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ] && public_svc=shadowtls-snell
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        port_valid=1
    fi
    if [ "$port_valid" = 1 ] && [ "$active" = 1 ] && service_port_listening "$port" "$transport" "$public_svc"; then
        listening=1
        doctor_add "${key}.listen" ok "$port/$transport 由 $public_svc 监听"
    else
        doctor_add "${key}.listen" fail "端口状态无效或未由 $public_svc 监听"
    fi
    recorded4=$(state_get "$key" listen_ipv4 2>/dev/null || true)
    recorded6=$(state_get "$key" listen_ipv6 2>/dev/null || true)
    if [ "$(id -u)" = 0 ] && [ "$active" = 1 ] && [ "$port_valid" = 1 ] && [ "$listening" = 1 ]; then
        if probe4=$(service_port_family_probe "$port" "$transport" "$public_svc" ipv4) \
            && probe6=$(service_port_family_probe "$port" "$transport" "$public_svc" ipv6); then
            actual4=$probe4
            actual6=$probe6
            family_confirmed=1
        fi
    fi
    if [[ "$recorded4" =~ ^[01]$ ]] && [[ "$recorded6" =~ ^[01]$ ]]; then
        if [ "$family_confirmed" = 0 ]; then
            doctor_add "${key}.family" warn "无法可靠确认监听族（记录 IPv4=${recorded4} IPv6=${recorded6}）"
        elif [ "$recorded4" = "$actual4" ] && [ "$recorded6" = "$actual6" ]; then
            doctor_add "${key}.family" ok "监听族与状态一致（IPv4=${actual4} IPv6=${actual6}）"
        else
            doctor_add "${key}.family" fail "监听族与状态不一致（记录 IPv4=${recorded4} IPv6=${recorded6}；实际 IPv4=${actual4} IPv6=${actual6}）"
        fi
    else
        doctor_add "${key}.family" warn "监听族状态缺失或无效（记录 IPv4=${recorded4:-?} IPv6=${recorded6:-?}）"
    fi
    doctor_firewall "$key"
    if [ "$proto" = snell ] && [ -f "$SYSTEMD_DIR/shadowtls-snell.service" ]; then
        local inner_addr inner_port
        inner_addr=$(unit_arg_value --server "$SYSTEMD_DIR/shadowtls-snell.service" 2>/dev/null || true)
        inner_port=${inner_addr##*:}
        if systemctl is-active --quiet shadowtls-snell 2>/dev/null \
            && service_port_listening "$port" tcp shadowtls-snell \
            && [[ "$inner_port" =~ ^[0-9]+$ ]] && service_port_listening "$inner_port" tcp snell; then
            doctor_add shadowtls.layer ok "Snell 与 ShadowTLS 外层均运行"
        else
            doctor_add shadowtls.layer fail "Snell 内层或 ShadowTLS 外层未运行/监听"
        fi
    fi
    if [ "$proto" = hy2 ]; then
        local hop end
        hop=$(state_get hy2 hop 2>/dev/null || true)
        if [ "${hop:-0}" -ge 3 ] 2>/dev/null; then
            end=$((port + hop - 1))
            if systemctl is-active --quiet pd-hy2-hop 2>/dev/null && command -v nft >/dev/null 2>&1 \
                && nft list table inet pd_hy2_hop 2>/dev/null | tr '\n' ' ' | grep -Eq "udp dport ${port}-${end} redirect to :${port}([ ;]|$)"; then
                doctor_add hy2.hop ok "HY2 hop unit 与 nft 范围一致"
            else
                doctor_add hy2.hop fail "HY2 hop unit/nft 与状态不一致"
            fi
        fi
    fi
}

doctor_run() {
    local json="${1:-0}" os_id="unknown" arch_raw systemd_state="" i comma
    _DOCTOR_IDS=(); _DOCTOR_STATUS=(); _DOCTOR_MESSAGES=(); _DOCTOR_FAILED=0
    if [ "$(id -u)" = 0 ]; then
        doctor_add privileges ok "root 可读取受限状态、unit 和 socket 进程信息"
    else
        doctor_add privileges warn "非 root 运行；受限状态、journal 和 socket 进程信息可能不可见"
    fi
    [ -r /etc/os-release ] && os_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"' | head -1)
    case "$os_id" in debian|ubuntu) doctor_add os ok "支持的系统: $os_id" ;; *) doctor_add os fail "不支持的系统: $os_id" ;; esac
    arch_raw=$(uname -m 2>/dev/null || echo unknown)
    case "$arch_raw" in x86_64|amd64|aarch64|arm64) doctor_add arch ok "支持的架构: $arch_raw" ;; *) doctor_add arch fail "不支持的架构: $arch_raw" ;; esac
    if command -v systemctl >/dev/null 2>&1; then
        systemd_state=$(systemctl is-system-running 2>/dev/null || true)
        case "$systemd_state" in running|degraded) doctor_add systemd ok "systemd: $systemd_state" ;; *) doctor_add systemd fail "systemd 不可用: ${systemd_state:-unknown}" ;; esac
    else
        doctor_add systemd fail "缺少 systemctl"
    fi
    get_ip
    if [ -n "${PUBLIC_HOST:-}" ] || [ -n "${IP:-}" ] || [ -n "${IP6:-}" ]; then
        doctor_add public_ip ok "公网端点可用（host=${PUBLIC_HOST:-none} IPv4=${IP:-none} IPv6=${IP6:-none}）"
    else
        doctor_add public_ip warn "未得到一致的公网地址；配置输出将被拒绝"
    fi
    for i in $ALL_PROTOS; do doctor_protocol "$i"; done
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" = bbr ]; then
        doctor_add bbr ok "BBR 正在运行"
    else
        doctor_add bbr warn "BBR 未运行"
    fi
    if [ "$json" = 1 ]; then
        printf '{"version":"%s","ok":%s,"checks":[' "$VERSION" "$([ "$_DOCTOR_FAILED" = 0 ] && echo true || echo false)"
        comma=""
        for ((i=0; i<${#_DOCTOR_IDS[@]}; i++)); do
            printf '%s{"id":"%s","status":"%s","message":"%s"}' "$comma" \
                "$(json_escape "${_DOCTOR_IDS[$i]}")" "${_DOCTOR_STATUS[$i]}" "$(json_escape "${_DOCTOR_MESSAGES[$i]}")"
            comma=,
        done
        printf ']}\n'
    else
        echo "PD-proxy doctor v$VERSION（只读）"
        for ((i=0; i<${#_DOCTOR_IDS[@]}; i++)); do
            printf '%-5s %-20s %s\n' "${_DOCTOR_STATUS[$i]}" "${_DOCTOR_IDS[$i]}" "${_DOCTOR_MESSAGES[$i]}"
        done
    fi
    [ "$_DOCTOR_FAILED" = 0 ]
}

# 注册协议表
register_protocols

# 回归测试只加载定义，不执行 CLI、root 检查或菜单。
if [ "${PD_TEST_MODE:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# ============================================================
# CLI 派发（统一入口 — 协议名归一化一处完成）
# ============================================================

# 写操作需要 root，读操作不需要

validate_cli_arity() {
    local action="${1:-}"
    case "$action" in
        --install|-i|--uninstall|-r|--upgrade|-u|--restart|--stop|--start|--log|-l|--config|-c)
            [ "$#" -eq 2 ] || cli_usage_error "$action 需要且只接受一个协议参数" ;;
        --config-all|--show|--status|-s|--export|--bbr|--bbrv3|--update)
            [ "$#" -eq 1 ] || cli_usage_error "$action 不接受额外参数" ;;
        --doctor)
            [ "$#" -eq 1 ] || { [ "$#" -eq 2 ] && [ "${2:-}" = --json ]; } \
                || cli_usage_error "--doctor 仅接受可选的 --json" ;;
        --remove-all)
            [ "$#" -eq 1 ] || { [ "$#" -eq 2 ] && [ "${2:-}" = --yes ]; } \
                || cli_usage_error "--remove-all 仅接受可选的 --yes" ;;
        "") [ "$#" -eq 0 ] || cli_usage_error "意外参数" ;;
        *) cli_usage_error "未知参数: $action" ;;
    esac
}

validate_cli_arity "$@"

# 一行式协议派发：resolve_proto 归一化 → 调用目标函数
cli_dispatch() {
    local action="$1" proto="${2:-}"
    case "$action" in
        install)
            [ -z "$proto" ] && die "用法: pd --install <snell|hy2|vless|anytls>"
            check_root; detect_os; detect_arch; get_ip; get_mem
            run_write_locked self_install || warn "pd 更新失败，使用缓存版本"
            proto=$(resolve_proto "$proto") || die "未知协议: $proto，可选: snell hy2 vless anytls"
            # CLI 路径：无环境变量时重置为默认值，防止交互菜单污染
            [ -z "${PD_SNELL_MODE:-}" ] && PD_OPT_SNELL_MODE="standard"
            [ -z "${PD_HY2_HOP:-}" ] && PD_OPT_HY2_HOP=0
            [ -z "${PD_HY2_HOP_RANGE:-}" ] && PD_OPT_HY2_HOP_RANGE=""
            [ -z "${PD_VLESS_DEST:-}" ] && PD_OPT_VLESS_DEST="addons.mozilla.org:443"
            [ -z "${PD_VLESS_SNI:-}" ] && PD_OPT_VLESS_SNI="addons.mozilla.org"
            [ -z "${PD_VLESS_TRANSPORT:-}" ] && PD_OPT_VLESS_TRANSPORT="tcp"
            [ -z "${PD_VLESS_FP:-}" ] && PD_OPT_VLESS_FP="chrome"
            [ -z "${PD_ANYTLS_PADDING:-}" ] && PD_OPT_ANYTLS_PADDING="standard"
            [ -z "${PD_ANYTLS_SNI:-}" ] && PD_OPT_ANYTLS_SNI=""
            run_write_locked install_protocol "$proto" ;;
        uninstall)
            [ -z "$proto" ] && die "用法: pd --uninstall <snell|hy2|vless|anytls>"
            check_root; detect_os
            proto=$(resolve_proto "$proto") || die "未知协议: $proto"
            run_write_locked uninstall_protocol "$proto" ;;
        upgrade)
            [ -z "$proto" ] && die "用法: pd --upgrade <snell|hy2|vless|anytls>"
            check_root; detect_os; detect_arch; get_ip
            proto=$(resolve_proto "$proto") || die "未知协议: $proto"
            run_write_locked upgrade_protocol "$proto" ;;
        restart)
            [ -z "$proto" ] && die "用法: pd --restart <snell|hy2|vless|anytls>"
            check_root
            proto=$(resolve_proto "$proto") || die "未知协议: $proto"
            run_write_locked restart_service "$proto" ;;
        stop)
            [ -z "$proto" ] && die "用法: pd --stop <snell|hy2|vless|anytls>"
            check_root
            proto=$(resolve_proto "$proto") || die "未知协议: $proto"
            run_write_locked stop_service "$proto" ;;
        start)
            [ -z "$proto" ] && die "用法: pd --start <snell|hy2|vless|anytls>"
            check_root
            proto=$(resolve_proto "$proto") || die "未知协议: $proto"
            run_write_locked start_service "$proto" ;;
        log)
            [ -z "$proto" ] && die "用法: pd --log <snell|hy2|vless|anytls>"
            proto=$(resolve_proto "$proto") || die "未知协议: $proto"
            show_log "$proto" ;;
        config)
            [ -z "$proto" ] && die "用法: pd --config <snell|hy2|vless|anytls>"
            check_root; detect_os; detect_arch; get_ip
            proto=$(resolve_proto "$proto") || die "未知协议: $proto"
            show_config_only "$proto" ;;
    esac
}

case "${1:-}" in
    --install|-i)  cli_dispatch install  "${2:-}" ; exit $? ;;
    --uninstall|-r)
        case "${2:-}" in
            all|--all) check_root; run_write_locked remove_all; exit $? ;;
        esac
        cli_dispatch uninstall "${2:-}" ; exit $? ;;
    --upgrade|-u)  cli_dispatch upgrade  "${2:-}" ; exit $? ;;
    --restart)     cli_dispatch restart  "${2:-}" ; exit $? ;;
    --stop)        cli_dispatch stop     "${2:-}" ; exit $? ;;
    --start)       cli_dispatch start    "${2:-}" ; exit $? ;;
    --log|-l)      cli_dispatch log      "${2:-}" ; exit $? ;;
    --config|-c)   cli_dispatch config   "${2:-}" ; exit $? ;;
    --config-all)
        check_root; detect_os; detect_arch; get_ip
        for p in $ALL_PROTOS; do
            state_installed "$(pkey "$p")" || continue
            echo "=== $(pname "$p") ==="
            show_config_only "$p"
            echo ""
        done
        exit 0 ;;
    --show)
        check_root; detect_os; detect_arch; get_ip; get_mem; show_config; exit 0 ;;
    --status|-s)
        detect_os; detect_arch; get_ip; get_mem; show_status; exit 0 ;;
    --doctor)
        if [ "${2:-}" = --json ]; then doctor_run 1; else doctor_run 0; fi
        exit $? ;;
    --export)
        check_root; run_write_locked run_export; exit $? ;;
    --bbr)
        check_root; detect_os; run_write_locked enable_bbr; exit $? ;;
    --bbrv3)
        check_root; detect_os; detect_arch; run_write_locked enable_bbrv3_kernel; exit $? ;;
    --update)
        check_root; PD_UPDATE=1 run_write_locked self_install
        info "PD-proxy 修复版已更新"; exit 0 ;;
    --remove-all)
        check_root; [ "${2:-}" = "--yes" ] && PD_YES=1; run_write_locked remove_all; exit $? ;;
esac

# ============================================================
# 交互菜单系统（二级菜单 + 协议配置子菜单）
# ============================================================

# ---- Snell 配置子菜单 ----
menu_snell_config() {
    while true; do
        echo ""
        echo -e "  ${MAGENTA}▸ Snell v5 — 安装模式${RESET}"
        echo -e "  ${CYAN}┌──────────────────────────────────────┐${RESET}"
        echo -e "  ${CYAN}│${RESET} [1] ${GREEN}标准模式${RESET}         直接 Snell 监听    ${CYAN}│${RESET}"
        echo -e "  ${CYAN}│${RESET} [2] ${MAGENTA}+ ShadowTLS${RESET}      伪装 TLS (推荐)    ${CYAN}│${RESET}"
        echo -e "  ${CYAN}│${RESET} [B] ${DIM}返回${RESET}                            ${CYAN}│${RESET}"
        echo -e "  ${CYAN}└──────────────────────────────────────┘${RESET}"
        echo -ne "  ${MAGENTA}▸${RESET} 选择: "
        read -r cc
        case "$cc" in
            1) PD_OPT_SNELL_MODE="standard"; break ;;
            2)
                PD_OPT_SNELL_MODE="shadowtls"
                echo ""
                echo -e "  ${MAGENTA}▸ 伪装 SNI 站点${RESET}"
                echo -e "  ${CYAN}┌──────────────────────────────────────┐${RESET}"
                echo -e "  ${CYAN}│${RESET} [1] microsoft.com                  ${CYAN}│${RESET}"
                echo -e "  ${CYAN}│${RESET} [2] apple.com                      ${CYAN}│${RESET}"
                echo -e "  ${CYAN}│${RESET} [3] cloudflare.com                 ${CYAN}│${RESET}"
                echo -e "  ${CYAN}│${RESET} [4] 自定义输入                      ${CYAN}│${RESET}"
                echo -e "  ${CYAN}└──────────────────────────────────────┘${RESET}"
                echo -ne "  ${MAGENTA}▸${RESET} 选择 [1]: "
                read -r sni_c
                case "$sni_c" in
                    2) PD_OPT_SNELL_TLS_SNI="www.apple.com" ;;
                    3) PD_OPT_SNELL_TLS_SNI="cloudflare.com" ;;
                    4) echo -ne "  SNI: "; read -r sni_custom; PD_OPT_SNELL_TLS_SNI="${sni_custom:-www.microsoft.com}" ;;
                    *) PD_OPT_SNELL_TLS_SNI="www.microsoft.com" ;;
                esac
                echo ""
                echo -e "  ${MAGENTA}▸ ShadowTLS 协议版本${RESET}"
                echo -e "  ${CYAN}┌──────────────────────────────────────┐${RESET}"
                echo -e "  ${CYAN}│${RESET} [1] ${GREEN}V3${RESET} 推荐，抗劫持更强             ${CYAN}│${RESET}"
                echo -e "  ${CYAN}│${RESET} [2] V2 兼容旧客户端                 ${CYAN}│${RESET}"
                echo -e "  ${CYAN}└──────────────────────────────────────┘${RESET}"
                echo -ne "  ${MAGENTA}▸${RESET} 选择 [1]: "
                read -r tls_v
                case "$tls_v" in
                    2) PD_OPT_SNELL_TLS_VERSION="v2" ;;
                    *) PD_OPT_SNELL_TLS_VERSION="v3" ;;
                esac
                break ;;
            [Bb]) return 1 ;;
            [Qq]) info "再见 👋"; exit 0 ;;
            *) warn "无效选择" ;;
        esac
    done
    prompt_protocol_port snell || return 1
    run_write_locked install_protocol snell
    return 0
}

# ---- HY2 配置子菜单 ----
menu_hy2_config() {
    local hy2_range
    while true; do
        echo ""
        echo -e "  ${MAGENTA}▸ Hysteria2 — 端口模式${RESET}"
        echo -e "  ${CYAN}┌──────────────────────────────────────┐${RESET}"
        echo -e "  ${CYAN}│${RESET} [1] ${GREEN}单端口${RESET}           标准              ${CYAN}│${RESET}"
        echo -e "  ${CYAN}│${RESET} [2] ${MAGENTA}3 端口跳跃${RESET}       轻量混淆          ${CYAN}│${RESET}"
        echo -e "  ${CYAN}│${RESET} [3] ${MAGENTA}5 端口跳跃${RESET}       深度混淆 (推荐)   ${CYAN}│${RESET}"
        echo -e "  ${CYAN}│${RESET} [4] ${MAGENTA}范围端口跳跃${RESET}     自定义 start-end ${CYAN}│${RESET}"
        echo -e "  ${CYAN}│${RESET} [B] ${DIM}返回${RESET}                            ${CYAN}│${RESET}"
        echo -e "  ${CYAN}└──────────────────────────────────────┘${RESET}"
        echo -ne "  ${MAGENTA}▸${RESET} 选择: "
        read -r cc
        case "$cc" in
            1) PD_OPT_HY2_HOP=0; PD_OPT_HY2_HOP_RANGE=""; prompt_protocol_port hy2 || return 1; break ;;
            2) PD_OPT_HY2_HOP=3; PD_OPT_HY2_HOP_RANGE=""; prompt_protocol_port hy2 || return 1; break ;;
            3) PD_OPT_HY2_HOP=5; PD_OPT_HY2_HOP_RANGE=""; prompt_protocol_port hy2 || return 1; break ;;
            4)
                echo -ne "  输入跳跃范围 (例如 30000-30100): "
                read -r hy2_range
                apply_hy2_hop_range "$hy2_range"
                break ;;
            [Bb]) return 1 ;;
            [Qq]) info "再见 👋"; exit 0 ;;
            *) warn "无效选择" ;;
        esac
    done
    run_write_locked install_protocol hy2
    return 0
}

# ---- VLESS 配置子菜单 ----
menu_vless_config() {
    while true; do
        echo ""
        echo -e "  ${MAGENTA}▸ VLESS Reality — 伪装目标${RESET}"
        echo -e "  ${CYAN}┌──────────────────────────────────────┐${RESET}"
        echo -e "  ${CYAN}│${RESET} [1] addons.mozilla.org  Mozilla CDN   ${CYAN}│${RESET}"
        echo -e "  ${CYAN}│${RESET} [2] www.microsoft.com   微软 CDN      ${CYAN}│${RESET}"
        echo -e "  ${CYAN}│${RESET} [3] swdist.apple.com    Apple 分发    ${CYAN}│${RESET}"
        echo -e "  ${CYAN}│${RESET} [4] dl.google.com       Google 下载   ${CYAN}│${RESET}"
        echo -e "  ${CYAN}│${RESET} [B] ${DIM}返回${RESET}                            ${CYAN}│${RESET}"
        echo -e "  ${CYAN}└──────────────────────────────────────┘${RESET}"
        echo -ne "  ${MAGENTA}▸${RESET} 选择 [1]: "
        read -r cc
        case "$cc" in
            2) PD_OPT_VLESS_DEST="www.microsoft.com:443"; PD_OPT_VLESS_SNI="www.microsoft.com" ;;
            3) PD_OPT_VLESS_DEST="swdist.apple.com:443"; PD_OPT_VLESS_SNI="swdist.apple.com" ;;
            4) PD_OPT_VLESS_DEST="dl.google.com:443"; PD_OPT_VLESS_SNI="dl.google.com" ;;
            [Bb]) return 1 ;;
            [Qq]) info "再见 👋"; exit 0 ;;
            *) PD_OPT_VLESS_DEST="addons.mozilla.org:443"; PD_OPT_VLESS_SNI="addons.mozilla.org" ;;
        esac

        PD_OPT_VLESS_TRANSPORT="tcp"

        echo ""
        echo -e "  ${MAGENTA}▸ 浏览器指纹${RESET}"
        echo -e "  [1] chrome  [2] firefox  [3] safari  [4] ios  [5] 随机"
        echo -ne "  ${MAGENTA}▸${RESET} 选择 [1]: "
        read -r fp_c
        case "$fp_c" in
            2) PD_OPT_VLESS_FP="firefox" ;;
            3) PD_OPT_VLESS_FP="safari" ;;
            4) PD_OPT_VLESS_FP="ios" ;;
            5) PD_OPT_VLESS_FP="randomized" ;;
            *) PD_OPT_VLESS_FP="chrome" ;;
        esac
        prompt_protocol_port vless || return 1
        break
    done
    run_write_locked install_protocol vless
    return 0
}

# ---- AnyTLS 配置子菜单 ----
menu_anytls_config() {
    while true; do
        echo ""
        echo -e "  ${MAGENTA}▸ SNI 伪装${RESET}"
        echo -e "  ${DIM}  AnyTLS 服务端使用默认填充；SNI 仅写入客户端链接${RESET}"
        echo -e "  [1] 不伪装  [2] microsoft.com  [3] apple.com  [4] cloudflare.com"
        echo -e "  [B] 返回"
        echo -ne "  ${MAGENTA}▸${RESET} 选择 [1]: "
        read -r sni_c
        case "$sni_c" in
            2) PD_OPT_ANYTLS_SNI="www.microsoft.com" ;;
            3) PD_OPT_ANYTLS_SNI="www.apple.com" ;;
            4) PD_OPT_ANYTLS_SNI="cloudflare.com" ;;
            [Bb]) return 1 ;;
            [Qq]) info "再见 👋"; exit 0 ;;
            *) PD_OPT_ANYTLS_SNI="" ;;
        esac
        prompt_protocol_port anytls || return 1
        break
    done
    run_write_locked install_protocol anytls
    return 0
}

menu_install() {
    echo -e "  ${MAGENTA}▸ 安装协议${RESET}"
    echo -e "  ${CYAN}┌──────────────────────────────────────┐${RESET}"
    echo -e "  ${CYAN}│${RESET} [1] ${GREEN}Snell v5${RESET}        ${DIM}Surge 主力${RESET}        ${CYAN}│${RESET}"
    echo -e "  ${CYAN}│${RESET} [2] ${GREEN}Hysteria2${RESET}       ${DIM}Surge + SR${RESET}        ${CYAN}│${RESET}"
    echo -e "  ${CYAN}│${RESET} [3] ${GREEN}VLESS Reality${RESET}   ${DIM}Shadowrocket${RESET}      ${CYAN}│${RESET}"
    echo -e "  ${CYAN}│${RESET} [4] ${GREEN}AnyTLS${RESET}          ${DIM}Surge + SR${RESET}        ${CYAN}│${RESET}"
    echo -e "  ${CYAN}│${RESET} [B] ${DIM}返回主菜单${RESET}                    ${CYAN}│${RESET}"
    echo -e "  ${CYAN}└──────────────────────────────────────┘${RESET}"
    echo ""
    echo -ne "  ${MAGENTA}▸${RESET} 选择: "
    read -r cc
    case "$cc" in
        1) menu_snell_config || return 1 ;;
        2) menu_hy2_config || return 1 ;;
        3) menu_vless_config || return 1 ;;
        4) menu_anytls_config || return 1 ;;
        [Bb]) return 1 ;;
        [Qq]) info "再见 👋"; exit 0 ;;
        *) warn "无效选择" ;;
    esac
    return 0
}

menu_manage() {
    echo -e "  ${MAGENTA}▸ 管理协议${RESET}"
    echo -e "  ${CYAN}┌──────────────────────────────────────┐${RESET}"
    echo -e "  ${CYAN}│${RESET} [1] 升级       [4] 启动              ${CYAN}│${RESET}"
    echo -e "  ${CYAN}│${RESET} [2] 重启       [5] 日志              ${CYAN}│${RESET}"
    echo -e "  ${CYAN}│${RESET} [3] 停止       [6] 卸载              ${CYAN}│${RESET}"
    echo -e "  ${CYAN}│${RESET} [B] ${DIM}返回主菜单${RESET}                      ${CYAN}│${RESET}"
    echo -e "  ${CYAN}└──────────────────────────────────────┘${RESET}"
    echo ""
    echo -ne "  ${MAGENTA}▸${RESET} 选择: "
    read -r cc
    case "$cc" in
        1) pick_proto "升级" upgrade_protocol write ;;
        2) pick_proto "重启" restart_service write ;;
        3) pick_proto "停止" stop_service write ;;
        4) pick_proto "启动" start_service write ;;
        5) pick_proto "日志" show_log ;;
        6) pick_proto "卸载" uninstall_protocol write ;;
        [Bb]) return 1 ;;
        [Qq]) info "再见 👋"; exit 0 ;;
        *) warn "无效选择" ;;
    esac
    return 0
}

menu_view() {
    echo -e "  ${MAGENTA}▸ 查看配置${RESET}"
    echo -e "  ${CYAN}┌──────────────────────────────────────┐${RESET}"
    echo -e "  ${CYAN}│${RESET} [1] 单协议配置行                     ${CYAN}│${RESET}"
    echo -e "  ${CYAN}│${RESET} [2] 全部协议配置                     ${CYAN}│${RESET}"
    echo -e "  ${CYAN}│${RESET} [3] 导出配置文件                     ${CYAN}│${RESET}"
    echo -e "  ${CYAN}│${RESET} [B] ${DIM}返回主菜单${RESET}                      ${CYAN}│${RESET}"
    echo -e "  ${CYAN}└──────────────────────────────────────┘${RESET}"
    echo ""
    echo -ne "  ${MAGENTA}▸${RESET} 选择: "
    read -r cc
    case "$cc" in
        1) pick_proto "配置" show_config_only ;;
        2) show_config ;;
        3) run_write_locked run_export ;;
        [Bb]) return 1 ;;
        [Qq]) info "再见 👋"; exit 0 ;;
        *) warn "无效选择" ;;
    esac
    return 0
}

menu_system() {
    echo -e "  ${MAGENTA}▸ 系统工具${RESET}"
    echo -e "  ${CYAN}┌──────────────────────────────────────┐${RESET}"
    echo -e "  ${CYAN}│${RESET} [1] 安装/更新 XanMod 内核 + BBR v3     ${CYAN}│${RESET}"
    echo -e "  ${CYAN}│${RESET} [2] 卸载 XanMod 内核 ${DIM}(预留)${RESET}              ${CYAN}│${RESET}"
    echo -e "  ${CYAN}│${RESET} [3] BBR 直连/落地优化（智能带宽）      ${CYAN}│${RESET}"
    echo -e "  ${CYAN}│${RESET} [4] 卸载全部协议                       ${CYAN}│${RESET}"
    echo -e "  ${CYAN}│${RESET} [B] ${DIM}返回主菜单${RESET}                      ${CYAN}│${RESET}"
    echo -e "  ${CYAN}└──────────────────────────────────────┘${RESET}"
    echo ""
    echo -ne "  ${MAGENTA}▸${RESET} 选择: "
    read -r cc
    case "$cc" in
        1) run_write_locked enable_bbrv3_kernel ;;
        2) warn "XanMod 内核卸载功能暂未集成；如需回退，请先保留云厂商默认内核并手动 apt purge 对应 linux-xanmod 包" ;;
        3) run_write_locked enable_bbr ;;
        4) run_write_locked remove_all ;;
        [Bb]) return 1 ;;
        [Qq]) info "再见 👋"; exit 0 ;;
        *) warn "无效选择" ;;
    esac
    return 0
}

# ============================================================
# 主菜单循环
# ============================================================

check_root
detect_os; detect_arch; get_ip; get_mem
run_write_locked self_install || warn "pd 更新失败，使用缓存版本"

while true; do
    show_status
    echo -e "  ${CYAN}[1]${RESET} 安装协议    ${CYAN}[2]${RESET} 管理协议"
    echo -e "  ${CYAN}[3]${RESET} 查看配置    ${CYAN}[4]${RESET} 系统工具"
    echo -e "  ${CYAN}[Q]${RESET} 退出"
    echo ""
    echo -ne "  ${MAGENTA}▸${RESET} 选择: "
    read -r cc
    case "$cc" in
        1) while menu_install; do :; done ;;
        2) while menu_manage; do :; done ;;
        3) while menu_view; do :; done ;;
        4) while menu_system; do :; done ;;
        [Qq]) info "再见 👋"; exit 0 ;;
        *) ;;
    esac
done
