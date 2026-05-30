#!/usr/bin/env bash
# ============================================================
# PD-proxy — 多协议代理一键部署脚本 v3.6.7
# 协议: Snell v5 | Snell v4 (ShadowTLS) | Hysteria2 | VLESS Reality | AnyTLS
# 仓库: https://github.com/DDIPP1005/PD-proxy
# ============================================================
# 架构：数据驱动 — 所有协议定义为元数据表，安装引擎统一处理
# 原则：零静默错误 — 每步失败显式报错退出，不再吞噬错误
# ============================================================
set -euo pipefail

# bash 4.0+ 必需（关联数组）
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { echo "需要 Bash 4.0+（Debian/Ubuntu 默认满足；macOS /bin/bash 3.2 不支持），当前: ${BASH_VERSION:-unknown}" >&2; exit 1; }

VERSION="3.6.7"
SCRIPT_URL="${PD_SCRIPT_URL:-https://raw.githubusercontent.com/DDIPP1005/PD-proxy/main/install.sh}"

# 纯查询命令，不需要锁和 root
case "${1:-}" in
    --help|-h)
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
  pd --bbr                 开启BBR  pd --bbrv3     BBRv3内核
  pd --update              更新    pd --remove-all [--yes]  卸载全部

协议: snell (Snell v5；PD_SNELL_MODE=shadowtls 可安装 Snell v4+ShadowTLS) | hy2 | vless | anytls

增强选项(环境变量):
  PD_SNELL_MODE=shadowtls  PD_SNELL_TLS_VERSION=v3  PD_HY2_HOP=5  PD_HY2_HOP_RANGE=30000-30100
  PD_SNELL_PORT=12345  PD_HY2_PORT=23456  PD_VLESS_PORT=34567  PD_ANYTLS_PORT=45678
  PD_VLESS_DEST=...:443
  PD_SNELL_MANUAL_TIMEOUT=6  PD_SNELL_PROBE_PARALLEL=12  PD_SNELL_VERSION=v5.x.x
  PD_BBR_BANDWIDTH=1000  PD_BBR_REGION=asia

示例:
  bash -c "\$(curl -fsSL ${SCRIPT_URL})"
EOF
        exit 0 ;;
    --version|-v)
        echo "PD-proxy v${VERSION}"; exit 0 ;;
esac

# 无参数交互菜单不能用 `curl ... | bash`：stdin 会被脚本内容占用，菜单无法读取键盘。
# 带参数 CLI 允许非终端运行，便于自动化；持久化由 self_install 单独处理。
if [ "$#" -eq 0 ] && [ ! -t 0 ]; then
    echo "不能使用管道方式运行交互菜单，请改用：" >&2
    echo "  bash -c \"\$(curl -fsSL ${SCRIPT_URL})\"" >&2
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

BASE_DIR="/opt/pd"
STATE_FILE="$BASE_DIR/state"
INSTALLED_BIN="/usr/local/bin/pd"
LOCK_FILE="/tmp/pd-proxy.lock"

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
PD_OPT_ANYTLS_PADDING="${PD_ANYTLS_PADDING:-standard}"  # standard | deep | fixed | none
PD_OPT_ANYTLS_SNI="${PD_ANYTLS_SNI:-}"                  # 空=不伪装

# 轻量化选项
PD_OPT_INSTALL_QR="${PD_INSTALL_QR:-0}"                  # 1=安装 qrencode 生成二维码

# 并发锁
exec 200>"$LOCK_FILE"
flock -n 200 || die "已有 PD-proxy 进程在运行，请稍后再试"

# 临时文件追踪（只清理自己创建的，不误删其他进程的文件）
declare -a _PD_TMPFILES=()
mktemp_pd() {
    local f; f=$(mktemp /tmp/pd-XXXXXX)
    _PD_TMPFILES+=("$f"); echo "$f"
}
trap 'rm -f "${_PD_TMPFILES[@]}" 2>/dev/null' EXIT

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

get_ip() {
    IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null \
      || curl -s4 --max-time 5 ip.sb 2>/dev/null \
      || curl -s4 --max-time 5 icanhazip.com 2>/dev/null \
      || echo "未知")
}

get_mem() {
    MEM_TOTAL=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")
    MEM_AVAIL=$(free -m 2>/dev/null | awk '/^Mem:/{print $NF}' || echo "0")
}

has_ipv6() {
    ip -6 addr show scope global 2>/dev/null | grep -q inet6 && return 0 || return 1
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
    local used_ports=" $(get_all_ports) "
    local attempts=0
    while [ $attempts -lt 100 ]; do
        local p=$(( $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 50001 + 10000 ))
        if ! echo "$used_ports" | grep -q " $p "; then
            # 额外检查：确保端口未被非 PD 服务占用
            if ss -tlnp 2>/dev/null | grep -q ":${p} " || ss -ulnp 2>/dev/null | grep -q ":${p} "; then
                attempts=$((attempts + 1))
                continue
            fi
            echo "$p"
            return 0
        fi
        attempts=$((attempts + 1))
    done
    die "无法分配空闲端口（10000-60000），请手动指定"
}

rand_port_range() {
    local count="$1" used_ports=" $(get_all_ports) " attempts=0 max_base p end busy
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
        if echo "$used_ports" | grep -q " $p "; then
            attempts=$((attempts + 1))
            continue
        fi
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
    curl -fsSL --connect-timeout 2 --max-time "$timeout" "https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell" 2>/dev/null \
        || curl -fsSL --connect-timeout 2 --max-time "$timeout" "https://manual.nssurge.com/others/snell.html" 2>/dev/null \
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
            curl -fsI --connect-timeout 1 --max-time 3 "$probe_url" >/dev/null 2>&1 && printf '%s\n' "$probe" > "$tmpdir/${probe}"
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
    tr ' ' '\n' < "$file" 2>/dev/null | awk -v arg="$arg" '$0 == arg { getline; print; exit }'
}

unit_password_value() {
    unit_arg_value "--password" "$1"
}

systemd_escape_arg() {
    local s="$1"
    case "$s" in
        *[[:space:]\"\\%]* ) die "systemd 参数包含不支持的字符: $s" ;;
    esac
    printf '%s' "$s"
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
    ss -tlnp 2>/dev/null | grep -q ":${port} " && return 0
    ss -ulnp 2>/dev/null | grep -q ":${port} " && return 0
    return 1
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
    mkdir -p "$(pdir hy2)"
    cat > "$(pdir hy2)/hop.nft" <<EOF
table inet pd_hy2_hop {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    udp dport ${base_port}-${last_port} redirect to :${base_port}
  }
}
EOF
    nft delete table inet pd_hy2_hop 2>/dev/null || true
    nft -f "$(pdir hy2)/hop.nft"
    cat > /etc/systemd/system/pd-hy2-hop.service <<EOF
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
    systemctl enable pd-hy2-hop >/dev/null 2>&1 || true
}

write_hy2_systemd() {
    local svc="$1" bin="$2" args="$3"
    cat > "/etc/systemd/system/${svc}.service" <<EOF
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
    command -v nft >/dev/null 2>&1 || return 0
    systemctl disable --now pd-hy2-hop 2>/dev/null || true
    rm -f /etc/systemd/system/pd-hy2-hop.service
    systemctl daemon-reload 2>/dev/null || true
    nft delete table inet pd_hy2_hop 2>/dev/null || true
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
    local port="$1" service="$2"
    sleep 2
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || ss -ulnp 2>/dev/null | grep -q ":${port} "; then
        info "端口 $port 监听确认 ✅"
        return 0
    fi
    err "端口 $port 未监听，服务可能启动失败"
    warn "查看日志: journalctl -u $service -n 30 --no-pager"
    return 1
}

save_iptables() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
    elif [ -d /etc/iptables ]; then
        cp /etc/iptables/rules.v4 /etc/iptables/rules.v4.bak 2>/dev/null || true
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
}

add_firewall() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port"/tcp >/dev/null 2>&1 || true
        ufw allow "$port"/udp >/dev/null 2>&1 || true
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
        save_iptables
    else
        warn "未检测到 ufw/iptables，请确认云防火墙已放行端口 $port"
    fi
}

add_firewall_range() {
    local start="$1" end="$2"
    validate_port "$start" "防火墙起始端口"
    validate_port "$end" "防火墙结束端口"
    [ "$end" -ge "$start" ] || die "防火墙端口范围无效: $start-$end"
    if [ "$start" = "$end" ]; then
        add_firewall "$start"
        return 0
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${start}:${end}"/tcp >/dev/null 2>&1 || true
        ufw allow "${start}:${end}"/udp >/dev/null 2>&1 || true
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport "${start}:${end}" -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport "${start}:${end}" -j ACCEPT 2>/dev/null || true
        save_iptables
    else
        warn "未检测到 ufw/iptables，请确认云防火墙已放行端口范围 ${start}-${end}"
    fi
}

del_firewall() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow "$port"/tcp >/dev/null 2>&1 || true
        ufw delete allow "$port"/udp >/dev/null 2>&1 || true
    elif command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
        save_iptables
    fi
}

del_firewall_range() {
    local start="$1" end="$2"
    validate_port "$start" "防火墙起始端口"
    validate_port "$end" "防火墙结束端口"
    [ "$end" -ge "$start" ] || return 0
    if [ "$start" = "$end" ]; then
        del_firewall "$start"
        return 0
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow "${start}:${end}"/tcp >/dev/null 2>&1 || true
        ufw delete allow "${start}:${end}"/udp >/dev/null 2>&1 || true
    elif command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p tcp --dport "${start}:${end}" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport "${start}:${end}" -j ACCEPT 2>/dev/null || true
        save_iptables
    fi
}

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
    [ -f "$STATE_FILE" ] || { echo ""; return; }
    local line
    line=$(grep "^${key} " "$STATE_FILE" 2>/dev/null) || { echo ""; return; }
    echo "$line" | state_field_from_line "$field" || echo ""
}

state_set() {
    local key="$1" field="$2" value="$3"
    mkdir -p "$BASE_DIR"
    local line=""
    if [ -f "$STATE_FILE" ]; then
        line=$(grep "^${key} " "$STATE_FILE" 2>/dev/null || echo "")
        grep -v "^${key} " "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
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
    echo "$line" >> "$STATE_FILE"
}

state_del() {
    local key="$1"
    [ -f "$STATE_FILE" ] || return 0
    grep -v "^${key} " "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
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

# ============================================================
# systemd 辅助
# ============================================================

write_systemd() {
    local svc="$1" bin="$2" args="$3"
    cat > "/etc/systemd/system/${svc}.service" <<EOF
[Unit]
Description=PD-proxy: ${svc}
After=network.target

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

register_and_start() {
    local svc="$1"
    systemctl daemon-reload
    systemctl enable "$svc" >/dev/null 2>&1 || warn "systemctl enable $svc 失败"
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
        echo "v${v}" > "$cache_file"
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
        echo "$v" > "$cache_file"
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
        echo "v${v}" > "$cache_file"
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
        echo "$v" > "$cache_file"
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
    tmpzip=$(mktemp_pd)
    curl -fSL# --retry 3 --connect-timeout 15 --max-time 300 -o "$tmpzip" "$url" \
        || die "Snell v4 下载失败: $url"
    unzip -o "$tmpzip" -d "$(pdir snell)" >/dev/null \
        || die "Snell v4 解压失败"
    rm -f "$tmpzip"
    chmod +x "$(pbin snell)"
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
    tmpzip=$(mktemp_pd)
    curl -fSL# --retry 3 --connect-timeout 15 --max-time 300 -o "$tmpzip" "$url" \
        || die "Snell 下载失败: $url"
    unzip -o "$tmpzip" -d "$(pdir snell)" >/dev/null \
        || die "Snell 解压失败"
    rm -f "$tmpzip"
    chmod +x "$(pbin snell)"
    verify_download "$(pbin snell)" "Snell" 50000
    info "Snell 下载完成"
}

snell_configure() {
    local port="$1" psk="$2" listen_addr="${3:-0.0.0.0}"
    local ipv6_enabled="false"
    has_ipv6 && ipv6_enabled="true"
    cat > "$(pdir snell)/snell.conf" <<EOF
[snell-server]
listen = ${listen_addr}:${port}
psk = ${psk}
ipv6 = ${ipv6_enabled}
EOF
    chmod 600 "$(pdir snell)/snell.conf"
}

snell_service_args() {
    echo "-c $(pdir snell)/snell.conf"
}

snell_shadowtls_unit_values() {
    local svc_file="/etc/systemd/system/shadowtls-snell.service"
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
    if [ -n "$tls_values" ]; then
        tls_pass=$(printf '%s\n' "$tls_values" | sed -n '1p')
        tls_sni=$(printf '%s\n' "$tls_values" | sed -n '2p')
        tls_proto=$(printf '%s\n' "$tls_values" | sed -n '3p')
        [ -n "$tls_proto" ] || tls_proto="2"
    fi
    if [ -n "$tls_pass" ]; then
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
        echo -e "${GREEN}Proxy = snell, ${IP}, ${port}, psk=${psk}, version=4, reuse=true, shadow-tls-password=${tls_pass}, shadow-tls-sni=${tls_sni%:*}, shadow-tls-version=${tls_proto}${RESET}"
        output_footer
    else
        output_header "Snell v5" "$port"
        echo -e "PSK:    ${GREEN}${psk}${RESET}"
        echo ""
        echo -e "${CYAN}[Surge 配置]${RESET}"
        echo -e "${GREEN}Proxy = snell, ${IP}, ${port}, psk=${psk}, version=5, reuse=true, tfo=true${RESET}"
        output_footer
    fi
}

# ============================================================
# ShadowTLS（Snell 增强模式）
# ============================================================

install_shadowtls() {
    local dir bin
    dir="/opt/shadowtls"
    bin="$dir/shadow-tls"

    local ver
    ver=$(curl -fs --retry 3 --max-time 15 "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" 2>/dev/null \
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
    local tmpbin
    tmpbin=$(mktemp_pd)
    curl -fSL# --retry 3 --connect-timeout 15 --max-time 120 -o "$tmpbin" "$url" \
        || { rm -f "$tmpbin"; die "ShadowTLS 下载失败"; }
    mv "$tmpbin" "$bin"
    chmod +x "$bin"
    verify_download "$bin" "ShadowTLS" 1000000
    info "ShadowTLS 下载完成" >&2
    echo "$bin"
}

snell_shadowtls_configure() {
    local ext_port="$1" int_port="$2"
    local sni="$PD_OPT_SNELL_TLS_SNI"
    local tls_pass="$PD_OPT_SNELL_TLS_PASS"
    local tls_version="$PD_OPT_SNELL_TLS_VERSION"
    validate_hostname "$sni" "PD_SNELL_TLS_SNI"
    case "$tls_version" in v3|3) tls_version="v3" ;; v2|2) tls_version="v2" ;; *) die "PD_SNELL_TLS_VERSION 仅支持 v3 或 v2，当前: $tls_version" ;; esac
    [ -n "$tls_pass" ] || tls_pass=$(rand_pass)
    tls_pass=$(systemd_escape_arg "$tls_pass")
    PD_OPT_SNELL_TLS_PASS="$tls_pass"
    local v3_arg="--v3"
    [ "$tls_version" = "v2" ] && v3_arg=""

    step "配置 ShadowTLS ${tls_version} (SNI: $sni) ..."
    local svc="shadowtls-snell"
    local bin
    bin=$(install_shadowtls)
    cat > "/etc/systemd/system/${svc}.service" <<EOF
[Unit]
Description=PD-proxy: ShadowTLS for Snell
After=network.target snell.service
Requires=snell.service

[Service]
Type=simple
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
ExecStart=${bin} ${v3_arg} server --listen 0.0.0.0:${ext_port} --server 127.0.0.1:${int_port} --tls ${sni}:443 --password ${tls_pass}
Restart=always
RestartSec=5
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$svc" >/dev/null 2>&1 || true
    systemctl restart "$svc" || { err "ShadowTLS 启动失败，查看 journalctl -u $svc -n 20"; return 1; }
    info "ShadowTLS ${tls_version} 已启动 (端口 $ext_port → Snell $int_port)"
}

# ---- Hysteria2 ----
hy2_get_version() {
    local v
    v=$(curl -fs --retry 3 --max-time 15 "https://api.github.com/repos/apernet/hysteria/releases/latest" 2>/dev/null \
        | json_tag_name | sed 's#^app/##' || true)
    [ -n "$v" ] && echo "$v" || die "Hysteria2 版本检测失败，请检查 GitHub 是否可达"
}

hy2_download() {
    local ver="$1"
    local url="https://github.com/apernet/hysteria/releases/download/app/${ver}/hysteria-linux-${ARCH}"
    step "下载 Hysteria2 $ver ..."
    mkdir -p "$(pdir hy2)"
    local tmpbin
    tmpbin=$(mktemp_pd)
    curl -fSL# --retry 3 --connect-timeout 15 --max-time 300 -o "$tmpbin" "$url" \
        || { rm -f "$tmpbin"; die "Hysteria2 下载失败: $url"; }
    mv "$tmpbin" "$(pbin hy2)"
    chmod +x "$(pbin hy2)"
    verify_download "$(pbin hy2)" "Hysteria2" 5000000
    info "Hysteria2 下载完成"
}

hy2_configure() {
    local port="$1" pass="$2"
    local listen=":${port}"
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
        listen=":${port}"
        info "端口跳跃: ${port}-${last_port} (${PD_OPT_HY2_HOP} 个端口)"
    fi
    cat > "$(pdir hy2)/config.yaml" <<EOF
listen: ${listen}

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
    chmod 600 "$(pdir hy2)/config.yaml" "$(pdir hy2)/cert.key"
}

hy2_service_args() {
    echo "server -c $(pdir hy2)/config.yaml"
}

hy2_output() {
    local port="$1" pass="$2"
    output_header "Hysteria2" "$port"
    echo -e "密码:   ${GREEN}${pass}${RESET}"
    echo ""
    echo -e "${CYAN}[Surge 配置]${RESET}"
    local hop_count
    hop_count=$(state_get hy2 hop)
    if [ "${hop_count:-0}" -ge 3 ] 2>/dev/null; then
        local last_port=$((port + hop_count - 1))
        echo -e "${GREEN}Proxy = hysteria2, ${IP}, ${port}-${last_port}, password=${pass}, sni=www.bing.com, skip-cert-verify=true, ports=${port}-${last_port}${RESET}"
    else
        echo -e "${GREEN}Proxy = hysteria2, ${IP}, ${port}, password=${pass}, sni=www.bing.com, skip-cert-verify=true${RESET}"
    fi
    echo ""
    echo -e "${CYAN}[Shadowrocket]${RESET}"
    gen_qr "hysteria2://${pass}@${IP}:${port}?sni=www.bing.com&insecure=1#PD-HY2"
    output_footer
}

# ---- VLESS Reality ----
vless_get_version() {
    local v
    v=$(curl -fs --retry 3 --max-time 15 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
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
    tmpzip=$(mktemp_pd)
    curl -fSL# --retry 3 --connect-timeout 15 --max-time 300 -o "$tmpzip" "$url" \
        || die "Xray 下载失败: $url"
    unzip -o "$tmpzip" -d "$(pdir vless)" >/dev/null \
        || die "Xray 解压失败"
    rm -f "$tmpzip"
    chmod +x "$(pbin vless)"
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

    # 保存配置信息供输出使用
    echo "$pubkey" > "$(pdir vless)/.pubkey"
    echo "$shortid" > "$(pdir vless)/.shortid"
    echo "$dest" > "$(pdir vless)/.dest"
    echo "$transport" > "$(pdir vless)/.transport"
    echo "$fp" > "$(pdir vless)/.fp"

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

    cat > "$(pdir vless)/config.json" <<EOF
{
  "inbounds": [{
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
    chmod 600 "$(pdir vless)/config.json"
}

vless_service_args() {
    echo "run -c $(pdir vless)/config.json"
}

vless_output() {
    local port="$1" uuid="$2"
    local pubkey shortid dest transport fp
    pubkey=$(cat "$(pdir vless)/.pubkey" 2>/dev/null || echo "未知")
    shortid=$(cat "$(pdir vless)/.shortid" 2>/dev/null || echo "未知")
    dest=$(cat "$(pdir vless)/.dest" 2>/dev/null || echo "addons.mozilla.org:443")
    transport=$(cat "$(pdir vless)/.transport" 2>/dev/null || echo "tcp")
    fp=$(cat "$(pdir vless)/.fp" 2>/dev/null || echo "chrome")
    local dest_host="${dest%:*}"
    local link="vless://${uuid}@${IP}:${port}?encryption=none&security=reality&sni=${dest_host}&fp=${fp}&pbk=${pubkey}&sid=${shortid}&type=${transport}&flow=xtls-rprx-vision#PD-VLESS"

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
    output_footer
}

# ---- AnyTLS ----
anytls_get_version() {
    local v
    v=$(curl -fs --retry 3 --max-time 15 "https://api.github.com/repos/anytls/anytls-go/releases/latest" 2>/dev/null \
        | json_tag_name || true)
    [ -n "$v" ] && echo "$v" || die "AnyTLS 版本检测失败，请检查 GitHub 是否可达"
}

anytls_download() {
    local ver="$1"
    local ver_num="${ver#v}"
    local url="https://github.com/anytls/anytls-go/releases/download/${ver}/anytls_${ver_num}_linux_${ARCH}.zip"
    step "下载 AnyTLS $ver ..."
    mkdir -p "$(pdir anytls)"
    local tmpzip
    tmpzip=$(mktemp_pd)
    curl -fSL# --retry 3 --connect-timeout 15 --max-time 300 -o "$tmpzip" "$url" \
        || die "AnyTLS 下载失败: $url"
    unzip -o "$tmpzip" -d "$(pdir anytls)" >/dev/null \
        || die "AnyTLS 解压失败"
    rm -f "$tmpzip"
    chmod +x "$(pbin anytls)"
    verify_download "$(pbin anytls)" "AnyTLS" 1000000
    info "AnyTLS 下载完成"
}

anytls_configure() {
    local port="$1" pass="$2"
    local padding="${PD_OPT_ANYTLS_PADDING}"
    local sni="${PD_OPT_ANYTLS_SNI}"
    case "$padding" in standard|deep|fixed|none) ;; *) die "PD_ANYTLS_PADDING 无效: $padding" ;; esac
    [ -z "$sni" ] || validate_hostname "$sni" "PD_ANYTLS_SNI"

    echo "$pass" > "$(pdir anytls)/.password"
    echo "$padding" > "$(pdir anytls)/.padding"
    [ -n "$sni" ] && echo "$sni" > "$(pdir anytls)/.sni" || rm -f "$(pdir anytls)/.sni"
    chmod 600 "$(pdir anytls)/.password"
}

anytls_service_args() {
    local port="$1"
    local pass padding sni
    pass=$(cat "$(pdir anytls)/.password" 2>/dev/null || echo "")
    pass=$(systemd_escape_arg "$pass")
    padding=$(cat "$(pdir anytls)/.padding" 2>/dev/null || echo "standard")
    sni=$(cat "$(pdir anytls)/.sni" 2>/dev/null || echo "")

    local args="-l 0.0.0.0:${port} -p ${pass}"
    case "$padding" in
        # anytls-server v0.0.12: --padding-scheme 接受文件路径非预设名
        # 仅当用户指定了文件路径时才传递，预设名不兼容
        *)     ;;  # 使用 anytls 默认，不传 --padding-scheme
    esac
    # anytls-server v0.0.12 无 -sni 参数，SNI 由客户端侧处理
    echo "$args"
}

anytls_output() {
    local port="$1" pass="$2"
    local padding sni
    padding=$(cat "$(pdir anytls)/.padding" 2>/dev/null || echo "standard")
    sni=$(cat "$(pdir anytls)/.sni" 2>/dev/null || echo "")

    local query=""
    [ -n "$sni" ] && query="?sni=$(url_escape "$sni")&insecure=1"
    local link="anytls://${pass}@${IP}:${port}${query}#PD-AnyTLS"
    output_header "AnyTLS" "$port"
    echo -e "密码:   ${GREEN}${pass}${RESET}"
    echo -e "填充:   ${DIM}${padding}（当前服务端使用 anytls 默认）${RESET}"
    [ -n "$sni" ] && echo -e "SNI:    ${DIM}${sni}（客户端侧使用）${RESET}"
    echo ""
    echo -e "${CYAN}[Surge 配置]${RESET}"
    echo -e "${GREEN}anytls, ${IP}, ${port}, password=${pass}${RESET}"
    echo ""
    echo -e "${CYAN}[Shadowrocket]${RESET}"
    gen_qr "$link"
    echo ""
    echo -e "${CYAN}[通用链接]${RESET}"
    echo -e "${GREEN}${link}${RESET}"
    output_footer
}

# ============================================================
# 统一安装流水线（核心 — 所有协议走同一套流程）
# ============================================================

install_protocol() {
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

    install_deps "$proto"; install_qrencode
    check_disk "$(pdisk "$proto")"
    if state_installed "$key"; then
        # 模式切换提示
        if [ "$proto" = "snell" ]; then
            local cur_sts=false want_sts=false
            [ -f /etc/systemd/system/shadowtls-snell.service ] && cur_sts=true
            [ "$PD_OPT_SNELL_MODE" = "shadowtls" ] && want_sts=true
            if [ "$cur_sts" != "$want_sts" ]; then
                warn "检测到 Snell 模式不同，自动切换到目标模式..."
                uninstall_protocol snell
                install_protocol snell
                return 0
            fi
        fi
        warn "$name 已安装，执行最新版检查..."
        upgrade_protocol "$proto"
        return 0
    fi

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

    # 回滚陷阱（端口已确定后才设置，确保 _rollback_port 被正确展开）
    local _rollback_port="$port"
    trap "
        err '安装失败，正在回滚...'
        systemctl stop '$svc' 2>/dev/null || true
        rm -f '/etc/systemd/system/${svc}.service'
        if [ '$proto' = 'snell' ]; then
            systemctl stop 'shadowtls-snell' 2>/dev/null || true
            rm -f '/etc/systemd/system/shadowtls-snell.service'
            rm -rf '/opt/shadowtls'
        fi
        systemctl daemon-reload
        if [ '$proto' = 'hy2' ] && [ "\${PD_OPT_HY2_HOP:-0}" -ge 3 ] 2>/dev/null; then
            _pd_rb_end=$((_rollback_port + PD_OPT_HY2_HOP - 1))
            del_firewall_range '$_rollback_port' "\$_pd_rb_end"
        else
            del_firewall '$_rollback_port'
        fi
        if [ '$proto' = 'hy2' ]; then
            clear_hy2_hop_rules
        fi
        rm -rf '$dir'
        state_del '$key'
        die '安装失败，已回滚，检查上述错误信息'
    " ERR

    local pass=$(rand_pass)
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
        while ss -tlnp 2>/dev/null | grep -q ":${snell_int} " 2>/dev/null; do
            snell_int=$(( (RANDOM % 15000) + 50000 ))
            _sni_attempts=$((_sni_attempts + 1))
            [ $_sni_attempts -lt 100 ] || die "无法分配 Snell 内部端口（50000-65000）"
        done
        snell_configure "$snell_int" "$pass" "127.0.0.1"
    else
        "${proto}_configure" "$port" "$pass"
    fi

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
        add_firewall_range "$port" "$((port + PD_OPT_HY2_HOP - 1))"
        state_set "$key" "hop" "$PD_OPT_HY2_HOP"
        [ -n "${PD_OPT_HY2_HOP_RANGE:-}" ] && state_set "$key" "hop_range" "$PD_OPT_HY2_HOP_RANGE"
    else
        add_firewall "$port"
        if [ "$proto" = "hy2" ]; then
            state_set "$key" "hop" "0"
            state_set "$key" "hop_range" ""
        fi
    fi
    verify_port "$port" "$svc" || warn "请检查服务状态"
    # Snell + ShadowTLS: 外部端口由 shadowtls-snell 监听
    if [ "$proto" = "snell" ] && [ "$PD_OPT_SNELL_MODE" = "shadowtls" ]; then
        if ! systemctl is-active --quiet shadowtls-snell 2>/dev/null; then
            warn "ShadowTLS 服务未运行，查看 journalctl -u shadowtls-snell -n 20"
        fi
    fi

    state_set "$key" "port" "$port"
    state_set "$key" "status" "installed"
    state_set "$key" "version" "$ver"

    "${proto}_output" "$port" "$pass"

    # 清除回滚陷阱
    trap - ERR
}

uninstall_protocol() {
    local proto="$1"
    local key=$(pkey "$proto")
    local svc=$(psvc "$proto")

    info "卸载 $(pname "$proto") ..."
    if ! state_installed "$key"; then
        warn "$(pname "$proto") 未安装"
        return 0
    fi

    local port
    port=$(state_get "$key" "port")

    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"

    # Snell ShadowTLS 额外清理
    if [ "$proto" = "snell" ]; then
        local tls_svc="shadowtls-snell"
        systemctl stop "$tls_svc" 2>/dev/null || true
        systemctl disable "$tls_svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/${tls_svc}.service"
        rm -rf /opt/shadowtls
    fi

    systemctl daemon-reload
    systemctl reset-failed "${svc}.service" 2>/dev/null || true

    if [ "$proto" = "hy2" ]; then
        local listen_line
        listen_line=$(grep 'listen:' "$(pdir hy2)/config.yaml" 2>/dev/null || echo "")
        local hop_count
        hop_count=$(state_get "$key" "hop")
        [ -n "$hop_count" ] || hop_count=$(echo "$listen_line" | tr ',' '\n' | wc -l | tr -d ' \n')
        if [ "$hop_count" -ge 2 ] 2>/dev/null; then
            del_firewall_range "$port" "$((port + hop_count - 1))" 2>/dev/null || true
            clear_hy2_hop_rules
        else
            [ -n "$port" ] && del_firewall "$port"
        fi
    else
        [ -n "$port" ] && del_firewall "$port"
    fi
    rm -rf "$(pdir "$proto")"
    state_del "$key"
    info "$(pname "$proto") 已卸载"
}

# ============================================================
# 协议升级 / 重启 / 纯配置
# ============================================================

upgrade_protocol() {
    local proto="$1"
    local key=$(pkey "$proto")
    local name=$(pname "$proto")
    local svc=$(psvc "$proto")

    if ! state_installed "$key"; then
        die "$name 未安装，无法升级"
    fi

    title "升级 $name"

    # 检查磁盘空间
    check_disk "$(pdisk "$proto")"
    local was_active=false
    systemctl is-active --quiet "$svc" 2>/dev/null && was_active=true

    local ver=""
    if [ "$proto" = "snell" ] && [ -f /etc/systemd/system/shadowtls-snell.service ]; then
        step "获取 Snell v4 最新版本..."
        if ! ver=$(snell_v4_get_version); then
            die "Snell v4 版本检测失败，已停止升级"
        fi
        require_version "$ver" "Snell v4"
        local old_ver=$(state_get "$key" "version")
        if [ "$ver" = "$old_ver" ] && [ -n "$ver" ]; then
            info "Snell v4 已是最新版 ($ver)"
            install_shadowtls >/dev/null
            if $was_active; then
                systemctl restart shadowtls-snell 2>/dev/null || warn "ShadowTLS 启动失败"
            fi
            return 0
        fi
        info "版本: $old_ver → $ver"
    elif declare -f "${proto}_get_version" >/dev/null 2>&1; then
        step "获取最新版本..."
        if ! ver=$("${proto}_get_version"); then
            die "$name 版本检测失败，已停止升级"
        fi
        require_version "$ver" "$name"
        local old_ver=$(state_get "$key" "version")
        if [ "$ver" = "$old_ver" ] && [ -n "$ver" ]; then
            info "$name 已是最新版 ($ver)，跳过"
            return 0
        fi
        info "版本: $old_ver → $ver"
    fi

    step "停止服务..."
    systemctl stop "$svc" 2>/dev/null || true

    # 备份旧二进制，启动失败时可回滚
    local bin=$(pbin "$proto")
    local bin_bak="${bin}.bak"
    if [ -f "$bin" ]; then
        cp "$bin" "$bin_bak" 2>/dev/null || true
    fi

    trap "
        err '升级失败，正在恢复旧服务...'
        if [ -f '$bin_bak' ]; then
            mv '$bin_bak' '$bin' 2>/dev/null || true
            chmod +x '$bin' 2>/dev/null || true
        fi
        if $was_active; then
            systemctl start '$svc' 2>/dev/null || true
            if [ '$proto' = 'snell' ] && [ -f /etc/systemd/system/shadowtls-snell.service ]; then
                systemctl start shadowtls-snell 2>/dev/null || true
            fi
        else
            systemctl stop '$svc' 2>/dev/null || true
            if [ '$proto' = 'snell' ] && [ -f /etc/systemd/system/shadowtls-snell.service ]; then
                systemctl stop shadowtls-snell 2>/dev/null || true
            fi
        fi
        if [ '$proto' = 'hy2' ]; then
            _pd_hop=\$(state_get '$key' 'hop')
            _pd_port=\$(state_get '$key' 'port')
            if $was_active && [ "\${_pd_hop:-0}" -ge 3 ] 2>/dev/null; then
                setup_hy2_hop_rules "\$_pd_port" "\$_pd_hop" 2>/dev/null || true
            elif [ "\${_pd_hop:-0}" -ge 3 ] 2>/dev/null; then
                clear_hy2_hop_rules 2>/dev/null || true
            fi
        fi
        die '升级失败，已尝试恢复旧服务'
    " ERR

    step "下载新版本..."
    if [ "$proto" = "snell" ] && [ -f /etc/systemd/system/shadowtls-snell.service ]; then
        snell_v4_download "$ver"
    else
        "${proto}_download" "$ver"
    fi

    step "验证新版本..."
    if systemctl start "$svc" 2>/dev/null; then
        rm -f "$bin_bak"
    else
        err "新版本启动失败，正在回滚..."
        if [ -f "$bin_bak" ]; then
            mv "$bin_bak" "$bin" 2>/dev/null || true
            chmod +x "$bin" 2>/dev/null || true
            systemctl start "$svc" 2>/dev/null && info "已回滚到旧版本" || die "回滚失败: journalctl -u $svc -n 20"
        else
            die "启动 $svc 失败且无备份可回滚: journalctl -u $svc -n 20"
        fi
    fi
    # Snell + ShadowTLS: Requires= 只传播 stop 不传播 start，需手动拉起
    if [ "$proto" = "snell" ] && [ -f /etc/systemd/system/shadowtls-snell.service ]; then
        install_shadowtls >/dev/null
        if $was_active; then
            systemctl restart shadowtls-snell 2>/dev/null || warn "ShadowTLS 启动失败"
        fi
    fi
    if [ "$proto" = "hy2" ]; then
        local port hop
        port=$(state_get "$key" "port")
        hop=$(state_get "$key" "hop")
        if [ "${hop:-0}" -ge 3 ] 2>/dev/null; then
            setup_hy2_hop_rules "$port" "$hop" || warn "HY2 跳跃规则恢复失败"
        fi
    fi

    state_set "$key" "version" "$ver"
    if ! $was_active; then
        systemctl stop "$svc" 2>/dev/null || true
        if [ "$proto" = "snell" ] && [ -f /etc/systemd/system/shadowtls-snell.service ]; then
            systemctl stop shadowtls-snell 2>/dev/null || true
        fi
        if [ "$proto" = "hy2" ]; then
            clear_hy2_hop_rules
        fi
    fi
    trap - ERR
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
    if [ "$proto" = "snell" ] && [ -f /etc/systemd/system/shadowtls-snell.service ]; then
        systemctl restart shadowtls-snell || die "ShadowTLS 重启失败: journalctl -u shadowtls-snell -n 20"
    fi
    if [ "$proto" = "hy2" ]; then
        local port hop
        port=$(state_get "$key" "port")
        hop=$(state_get "$key" "hop")
        if [ "${hop:-0}" -ge 3 ] 2>/dev/null; then
            setup_hy2_hop_rules "$port" "$hop" || warn "HY2 跳跃规则恢复失败"
        fi
    fi
    info "$(pname "$proto") 已重启"
}

stop_service() {
    local proto="$1"
    local key=$(pkey "$proto")
    local svc=$(psvc "$proto")

    if ! state_installed "$key"; then
        die "$(pname "$proto") 未安装"
    fi
    info "停止 $(pname "$proto") ..."
    if [ "$proto" = "snell" ] && [ -f /etc/systemd/system/shadowtls-snell.service ]; then
        systemctl stop shadowtls-snell 2>/dev/null || true
    fi
    if [ "$proto" = "hy2" ]; then
        clear_hy2_hop_rules
    fi
    systemctl stop "$svc" || warn "停止失败"
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
    if [ "$proto" = "snell" ] && [ -f /etc/systemd/system/shadowtls-snell.service ]; then
        systemctl start shadowtls-snell || die "ShadowTLS 启动失败: journalctl -u shadowtls-snell -n 20"
    fi
    if [ "$proto" = "hy2" ]; then
        local port hop
        port=$(state_get "$key" "port")
        hop=$(state_get "$key" "hop")
        if [ "${hop:-0}" -ge 3 ] 2>/dev/null; then
            setup_hy2_hop_rules "$port" "$hop" || warn "HY2 跳跃规则恢复失败"
        fi
    fi
    info "$(pname "$proto") 已启动"
}

show_log() {
    local proto="$1"
    local key=$(pkey "$proto")
    local svc=$(psvc "$proto")

    if ! state_installed "$key"; then
        die "$(pname "$proto") 未安装"
    fi
    journalctl -u "$svc" -n 50 --no-pager 2>/dev/null || warn "无法读取日志"
}

show_config_only() {
    local proto="$1"
    local key=$(pkey "$proto")
    if ! state_installed "$key"; then
        die "$(pname "$proto") 未安装"
    fi

    local port=$(state_get "$key" "port")
    case $proto in
        snell)
            local psk tls_pass tls_sni tls_proto
            psk=$(conf_value "psk" "$(pdir snell)/snell.conf" || echo "")
            local tls_values=""
            tls_values=$(snell_shadowtls_unit_values 2>/dev/null || true)
            if [ -n "$tls_values" ]; then
                tls_pass=$(printf '%s\n' "$tls_values" | sed -n '1p')
                tls_sni=$(printf '%s\n' "$tls_values" | sed -n '2p')
                tls_proto=$(printf '%s\n' "$tls_values" | sed -n '3p')
                [ -n "$tls_proto" ] || tls_proto="2"
                echo "Proxy = snell, ${IP}, ${port}, psk=${psk}, version=4, reuse=true, shadow-tls-password=${tls_pass}, shadow-tls-sni=${tls_sni%:*}, shadow-tls-version=${tls_proto}"
            else
                echo "Proxy = snell, ${IP}, ${port}, psk=${psk}, version=5, reuse=true, tfo=true"
            fi ;;
        hy2)
            local pass hop
            pass=$(yaml_value "password" "$(pdir hy2)/config.yaml" || echo "")
            hop=$(state_get "$key" "hop")
            if [ "$hop" -ge 3 ] 2>/dev/null; then
                local last_port=$((port + hop - 1))
                echo "Proxy = hysteria2, ${IP}, ${port}-${last_port}, password=${pass}, sni=www.bing.com, skip-cert-verify=true, ports=${port}-${last_port}"
            else
                echo "Proxy = hysteria2, ${IP}, ${port}, password=${pass}, sni=www.bing.com, skip-cert-verify=true"
            fi
            echo ""
            echo "# Shadowrocket: hysteria2://${pass}@${IP}:${port}?sni=www.bing.com&insecure=1#PD-HY2" ;;
        vless)
            local uuid pubkey shortid dest transport fp dest_host
            uuid=$(json_value "id" "$(pdir vless)/config.json" || echo "")
            pubkey=$(cat "$(pdir vless)/.pubkey" 2>/dev/null || echo "")
            shortid=$(cat "$(pdir vless)/.shortid" 2>/dev/null || echo "")
            dest=$(cat "$(pdir vless)/.dest" 2>/dev/null || echo "addons.mozilla.org:443")
            transport=$(cat "$(pdir vless)/.transport" 2>/dev/null || echo "tcp")
            fp=$(cat "$(pdir vless)/.fp" 2>/dev/null || echo "chrome")
            dest_host="${dest%:*}"
            echo "# Surge 不支持 VLESS"
            echo "vless://${uuid}@${IP}:${port}?encryption=none&security=reality&sni=${dest_host}&fp=${fp}&pbk=${pubkey}&sid=${shortid}&type=${transport}&flow=xtls-rprx-vision#PD-VLESS" ;;
        anytls)
            local pass padding sni
            pass=$(cat "$(pdir anytls)/.password" 2>/dev/null || echo "")
            padding=$(cat "$(pdir anytls)/.padding" 2>/dev/null || echo "standard")
            sni=$(cat "$(pdir anytls)/.sni" 2>/dev/null || echo "")
            echo "anytls, ${IP}, ${port}, password=${pass}"
            echo ""
            local query=""
            [ -n "$sni" ] && query="?sni=$(url_escape "$sni")&insecure=1"
            echo "# Shadowrocket: anytls://${pass}@${IP}:${port}${query}#PD-AnyTLS" ;;
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
        if [ "$proto" = "snell" ] && [ -f /etc/systemd/system/shadowtls-snell.service ] && systemctl is-active --quiet shadowtls-snell 2>/dev/null; then
            name="Snell v4+STS"
        fi
        if state_installed "$key"; then
            local port=$(state_get "$key" "port")
            local ver=$(state_get "$key" "version")
            local svc=$(psvc "$proto")
            local st icon
            if [ "$proto" = "snell" ] && [ -f /etc/systemd/system/shadowtls-snell.service ]; then
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
                psk=$(conf_value "psk" "$(pdir snell)/snell.conf" || echo "未知")
                snell_output "$port" "$psk" ;;
            hy2)
                local pass
                pass=$(yaml_value "password" "$(pdir hy2)/config.yaml" || echo "未知")
                hy2_output "$port" "$pass" ;;
            vless)
                local uuid
                uuid=$(json_value "id" "$(pdir vless)/config.json" || echo "未知")
                vless_output "$port" "$uuid" ;;
            anytls)
                local pass
                pass=$(cat "$(pdir anytls)/.password" 2>/dev/null || echo "未知")
                anytls_output "$port" "$pass" ;;
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
    command -v speedtest >/dev/null 2>&1 && return 0
    local cpu_arch url tmpdir
    cpu_arch=$(uname -m)
    case "$cpu_arch" in
        x86_64|amd64) url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz" ;;
        aarch64|arm64) url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz" ;;
        *) warn "speedtest 不支持当前架构: $cpu_arch" >&2; return 1 ;;
    esac
    tmpdir=$(mktemp -d /tmp/pd-speedtest-XXXXXX)
    curl -fsSL --connect-timeout 15 --max-time 120 "$url" -o "$tmpdir/speedtest.tgz" || { rm -rf "$tmpdir"; return 1; }
    tar -xzf "$tmpdir/speedtest.tgz" -C "$tmpdir" >/dev/null 2>&1 || { rm -rf "$tmpdir"; return 1; }
    install -m 0755 "$tmpdir/speedtest" /usr/local/bin/speedtest || { rm -rf "$tmpdir"; return 1; }
    rm -rf "$tmpdir"
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
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 \
        || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
}

write_bbr_persist_service() {
    cat > /usr/local/bin/pd-bbr-apply.sh <<'EOF'
#!/usr/bin/env bash
for d in /sys/class/net/*; do
    [ -e "$d" ] || continue
    dev=$(basename "$d")
    case "$dev" in lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue ;; esac
    tc qdisc replace dev "$dev" root fq 2>/dev/null || true
done
if command -v iptables >/dev/null 2>&1; then
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 \
        || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
fi
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
fi
EOF
    chmod +x /usr/local/bin/pd-bbr-apply.sh
    cat > /etc/systemd/system/pd-bbr-apply.service <<'EOF'
[Unit]
Description=PD-proxy BBR network runtime tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/pd-bbr-apply.sh

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable pd-bbr-apply.service >/dev/null 2>&1 || true
}

clean_sysctl_conflicts() {
    local conf=/etc/sysctl.conf changed=0
    [ -f "$conf" ] || return
    [ -f /etc/sysctl.conf.pdproxy.bak ] || cp "$conf" /etc/sysctl.conf.pdproxy.bak 2>/dev/null || true
    local -a keys=(
        "net\\.ipv4\\.tcp_congestion_control"
        "net\\.core\\.default_qdisc"
        "net\\.core\\.rmem_max"
        "net\\.core\\.wmem_max"
        "net\\.ipv4\\.tcp_rmem"
        "net\\.ipv4\\.tcp_wmem"
    )
    local k
    for k in "${keys[@]}"; do
        if grep -q "^${k}" "$conf" 2>/dev/null; then
            sed -i -E "s/^(${k}.*)/#&  # 已迁移到 \/etc\/sysctl.d\/99-pdproxy.conf/" "$conf"
            changed=1
        fi
    done
    [ "$changed" -eq 1 ] && info "已迁移 sysctl.conf 中的旧 BBR 配置"
}

apply_tc_fq() {
    if ! command -v tc >/dev/null 2>&1; then return; fi
    local applied=0 dev
    for dev in $(ls /sys/class/net/ 2>/dev/null); do
        case "$dev" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue ;;
        esac
        tc qdisc replace dev "$dev" root fq 2>/dev/null && applied=$((applied+1))
    done
    [ $applied -gt 0 ] && info "已对 ${applied} 个网卡应用 fq 队列算法（即时生效）"
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
            return
        fi

        if detect_virt 2>/dev/null | grep -qiE 'openvz|virtuozzo|lxc'; then
            warn "当前虚拟化环境不支持加载内核模块，无法开启 BBR"
            return
        fi
    fi

    # ④ 清理旧配置
    clean_sysctl_conflicts

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
    cat > "$sysctl_conf" << SYSCTL_EOF
# PD-proxy BBR 优化 ($(date '+%F %T'))
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

    # ⑦ 应用：先尝试加载模块，再应用 sysctl，避免 congestion_control=bbr 失败提前退出。
    modprobe tcp_bbr 2>/dev/null || true
    sysctl -p "$sysctl_conf" >/dev/null 2>&1 || warn "部分内核参数未能立即应用，可能需要重启或内核不支持"

    # ⑧ tc fq 即时生效
    apply_tc_fq
    apply_mss_clamp
    write_bbr_persist_service

    # ⑨ 验证
    running_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [ "$running_cc" = "bbr" ]; then
        info "BBR 已开启 (${running_cc})"
    else
        warn "BBR 未生效 (当前: ${running_cc})，可能需要重启系统"
    fi
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
        return
    fi

    # ③ 架构限制：XanMod x64 系列仅适用于 x86_64/amd64
    case "$(uname -m)" in
        x86_64|amd64) ;;
        *) warn "XanMod x64 内核仅支持 x86_64/amd64，当前架构: $(uname -m)"; return ;;
    esac

    # ④ 确认
    echo ""
    warn "安装 XanMod 内核后需要重启系统才能生效"
    echo -ne "  是否继续？(y/N): "
    read -r ans || ans=""
    [ "$ans" != "y" ] && [ "$ans" != "Y" ] && { info "已取消"; return; }

    # ⑤ 安装依赖
    step "安装 XanMod BBRv3 内核..."
    apt-get update -qq || { warn "apt-get update 失败，无法安装 XanMod"; return; }
    apt-get install -y -qq gnupg lsb-release curl ca-certificates >/dev/null || { warn "安装 XanMod 依赖失败"; return; }
    mkdir -p /etc/apt/keyrings

    local key_tmp
    key_tmp=$(mktemp_pd)
    curl -fsSL https://dl.xanmod.org/archive.key -o "$key_tmp" || { warn "下载 XanMod GPG key 失败"; return; }
    rm -f /etc/apt/keyrings/xanmod-archive-keyring.gpg
    gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg "$key_tmp" 2>/dev/null || { warn "导入 XanMod GPG key 失败"; return; }
    local codename
    codename=$(lsb_release -sc 2>/dev/null || sed -n 's/^VERSION_CODENAME=//p' /etc/os-release 2>/dev/null | head -1 || true)
    [ -n "$codename" ] || { warn "无法识别系统代号，无法添加 XanMod 源"; return; }
    if ! xanmod_supported_codename "$codename"; then
        warn "XanMod 官方源暂不支持当前系统代号: $codename"
        warn "支持: bookworm/trixie/forky/sid/noble/plucky/questing/resolute 以及 Linux Mint faye/gigi/wilma/xia/zara/zena"
        warn "已取消 BBRv3 内核安装；可继续使用 pd --bbr 开启普通 BBR"
        return
    fi
    echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${codename} main" \
        > /etc/apt/sources.list.d/xanmod-release.list

    apt-get update -qq || { rm -f /etc/apt/sources.list.d/xanmod-release.list; warn "刷新 XanMod APT 源失败，已移除 XanMod 源"; return; }
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
        return
    fi
    info "选择内核包: $xanmod_pkg"
    if ! apt-get install -y -qq "$xanmod_pkg" 2>/dev/null; then
        rm -f /etc/apt/sources.list.d/xanmod-release.list
        warn "XanMod 内核安装失败，已移除 XanMod 源，请检查 APT 源或系统兼容性"
        return
    fi
    update-grub 2>/dev/null || true

    info "XanMod BBRv3 内核已安装"
    echo ""
    warn "需要重启才能生效，重启后执行 pd --bbr 即可开启 BBRv3"
    echo -ne "  是否现在重启？(y/N): "
    read -r ans || ans=""
    [ "$ans" != "y" ] && [ "$ans" != "Y" ] && { info "请稍后手动重启"; return; }
    reboot
}

# ============================================================
# 自安装（pd 命令）
# ============================================================

self_install() {
    mkdir -p "$BASE_DIR"
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
            tmp_pd=$(mktemp_pd)
            curl -fsSL "$SCRIPT_URL" -o "$tmp_pd" || {
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
            mv "$tmp_pd" "$BASE_DIR/install.sh"
            chmod +x "$BASE_DIR/install.sh"
        elif $source_is_file; then
            local src_path dst_path
            src_path=$(readlink -f "$source_path" 2>/dev/null || echo "$source_path")
            dst_path=$(readlink -f "$BASE_DIR/install.sh" 2>/dev/null || echo "")
            if [ "$src_path" != "$dst_path" ]; then
                cp "$source_path" "$BASE_DIR/install.sh"
                chmod +x "$BASE_DIR/install.sh"
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
            cp "$source_path" "$BASE_DIR/install.sh"
            chmod +x "$BASE_DIR/install.sh"
        fi
    elif $install_from_url; then
        local tmp_pd
        tmp_pd=$(mktemp_pd)
        curl -fsSL "$SCRIPT_URL" -o "$tmp_pd" || {
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
        mv "$tmp_pd" "$BASE_DIR/install.sh"
        chmod +x "$BASE_DIR/install.sh"
    elif [ ! -f "$BASE_DIR/install.sh" ]; then
            warn "当前脚本不是文件，无法持久化 pd 命令；请设置 PD_SCRIPT_URL 或下载后运行"
            return 1
    fi
    ln -sf "$BASE_DIR/install.sh" "$INSTALLED_BIN" 2>/dev/null || true
}

# ============================================================
# 卸载全部
# ============================================================

remove_all() {
    echo -e "${RED}⚠ 即将卸载所有代理协议和 PD-proxy${RESET}"
    if [ "${PD_YES:-}" = "1" ] || [ "${1:-}" = "--yes" ]; then
        info "自动确认 (--yes)"
    else
        echo -n "确认？输入 yes: "
        read -r confirm || confirm=""
        [ "$confirm" = "yes" ] || { info "已取消"; return; }
    fi

    for proto in $ALL_PROTOS; do
        uninstall_protocol "$proto" 2>/dev/null || true
    done
    rm -f "$INSTALLED_BIN"
    rm -f /usr/local/bin/pd-update
    rm -rf "$BASE_DIR"
    info "全部已卸载。再见 👋"
    exit 0
}

# ============================================================
# 入口
# ============================================================

# 交互式协议选择
pick_proto() {
    local action="$1" func="$2"
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
    "$func" "$target"
}

run_export() {
    detect_os; detect_arch; get_ip
    mkdir -p "$BASE_DIR"
    {
        echo "# PD-proxy 导出 — $(date)"
        for p in $ALL_PROTOS; do
            if state_installed "$(pkey "$p")"; then
                echo ""
                echo "# $(pname "$p")"
                show_config_only "$p"
            fi
        done
    } > /opt/pd/export.conf
    chmod 600 /opt/pd/export.conf
    info "配置已导出到 /opt/pd/export.conf"
}

# 注册协议表
register_protocols

# ============================================================
# CLI 派发（统一入口 — 协议名归一化一处完成）
# ============================================================

# 写操作需要 root，读操作不需要

# 一行式协议派发：resolve_proto 归一化 → 调用目标函数
cli_dispatch() {
    local action="$1" proto="${2:-}"
    case "$action" in
        install)
            [ -z "$proto" ] && die "用法: pd --install <snell|hy2|vless|anytls>"
            check_root; detect_os; detect_arch; get_ip; get_mem
            self_install || warn "pd 更新失败，使用缓存版本"
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
            install_protocol "$proto" ;;
        uninstall)
            [ -z "$proto" ] && die "用法: pd --uninstall <snell|hy2|vless|anytls>"
            check_root; detect_os
            proto=$(resolve_proto "$proto") || die "未知协议: $proto"
            uninstall_protocol "$proto" ;;
        upgrade)
            [ -z "$proto" ] && die "用法: pd --upgrade <snell|hy2|vless|anytls>"
            check_root; detect_os; detect_arch; get_ip
            proto=$(resolve_proto "$proto") || die "未知协议: $proto"
            upgrade_protocol "$proto" ;;
        restart)
            [ -z "$proto" ] && die "用法: pd --restart <snell|hy2|vless|anytls>"
            check_root
            proto=$(resolve_proto "$proto") || die "未知协议: $proto"
            restart_service "$proto" ;;
        stop)
            [ -z "$proto" ] && die "用法: pd --stop <snell|hy2|vless|anytls>"
            check_root
            proto=$(resolve_proto "$proto") || die "未知协议: $proto"
            stop_service "$proto" ;;
        start)
            [ -z "$proto" ] && die "用法: pd --start <snell|hy2|vless|anytls>"
            check_root
            proto=$(resolve_proto "$proto") || die "未知协议: $proto"
            start_service "$proto" ;;
        log)
            [ -z "$proto" ] && die "用法: pd --log <snell|hy2|vless|anytls>"
            proto=$(resolve_proto "$proto") || die "未知协议: $proto"
            show_log "$proto" ;;
        config)
            [ -z "$proto" ] && die "用法: pd --config <snell|hy2|vless|anytls>"
            detect_os; detect_arch; get_ip
            proto=$(resolve_proto "$proto") || die "未知协议: $proto"
            show_config_only "$proto" ;;
    esac
}

case "${1:-}" in
    --install|-i)  cli_dispatch install  "${2:-}" ; exit 0 ;;
    --uninstall|-r)
        case "${2:-}" in
            all|--all) check_root; remove_all; exit 0 ;;
        esac
        cli_dispatch uninstall "${2:-}" ; exit 0 ;;
    --upgrade|-u)  cli_dispatch upgrade  "${2:-}" ; exit 0 ;;
    --restart)     cli_dispatch restart  "${2:-}" ; exit 0 ;;
    --stop)        cli_dispatch stop     "${2:-}" ; exit 0 ;;
    --start)       cli_dispatch start    "${2:-}" ; exit 0 ;;
    --log|-l)      cli_dispatch log      "${2:-}" ; exit 0 ;;
    --config|-c)   cli_dispatch config   "${2:-}" ; exit 0 ;;
    --config-all)
        detect_os; detect_arch; get_ip
        for p in $ALL_PROTOS; do
            state_installed "$(pkey "$p")" || continue
            echo "=== $(pname "$p") ==="
            show_config_only "$p"
            echo ""
        done
        exit 0 ;;
    --show)
        detect_os; detect_arch; get_ip; get_mem; show_config; exit 0 ;;
    --status|-s)
        detect_os; detect_arch; get_ip; get_mem; show_status; exit 0 ;;
    --export)
        check_root; run_export; exit 0 ;;
    --bbr)
        check_root; detect_os; enable_bbr; exit 0 ;;
    --bbrv3)
        check_root; detect_os; detect_arch; enable_bbrv3_kernel; exit 0 ;;
    --update)
        check_root; PD_UPDATE=1 self_install
        info "PD-proxy 修复版已更新"; exit 0 ;;
    --remove-all)
        check_root; [ "${2:-}" = "--yes" ] && PD_YES=1; remove_all; exit 0 ;;
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
    install_protocol snell
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
    install_protocol hy2
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
    install_protocol vless
    return 0
}

# ---- AnyTLS 配置子菜单 ----
menu_anytls_config() {
    while true; do
        echo ""
        echo -e "  ${MAGENTA}▸ AnyTLS — 填充模式${RESET}"
        echo -e "  ${CYAN}┌──────────────────────────────────────┐${RESET}"
        echo -e "  ${CYAN}│${RESET} [1] ${GREEN}标准填充${RESET}         随机 64-512B     ${CYAN}│${RESET}"
        echo -e "  ${CYAN}│${RESET} [2] ${MAGENTA}深度填充${RESET}         随机 64-1024B    ${CYAN}│${RESET}"
        echo -e "  ${CYAN}│${RESET} [3] 固定填充           固定 512B        ${CYAN}│${RESET}"
        echo -e "  ${CYAN}│${RESET} [4] 无填充             纯转发           ${CYAN}│${RESET}"
        echo -e "  ${CYAN}│${RESET} [B] ${DIM}返回${RESET}                            ${CYAN}│${RESET}"
        echo -e "  ${CYAN}└──────────────────────────────────────┘${RESET}"
        echo -ne "  ${MAGENTA}▸${RESET} 选择 [1]: "
        read -r cc
        case "$cc" in
            2) PD_OPT_ANYTLS_PADDING="deep" ;;
            3) PD_OPT_ANYTLS_PADDING="fixed" ;;
            4) PD_OPT_ANYTLS_PADDING="none" ;;
            [Bb]) return 1 ;;
            [Qq]) info "再见 👋"; exit 0 ;;
            *) PD_OPT_ANYTLS_PADDING="standard" ;;
        esac

        echo ""
        echo -e "  ${MAGENTA}▸ SNI 伪装${RESET}"
        echo -e "  [1] 不伪装  [2] microsoft.com  [3] apple.com  [4] cloudflare.com"
        echo -ne "  ${MAGENTA}▸${RESET} 选择 [1]: "
        read -r sni_c
        case "$sni_c" in
            2) PD_OPT_ANYTLS_SNI="www.microsoft.com" ;;
            3) PD_OPT_ANYTLS_SNI="www.apple.com" ;;
            4) PD_OPT_ANYTLS_SNI="cloudflare.com" ;;
            *) PD_OPT_ANYTLS_SNI="" ;;
        esac
        prompt_protocol_port anytls || return 1
        break
    done
    install_protocol anytls
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
        1) pick_proto "升级" upgrade_protocol ;;
        2) pick_proto "重启" restart_service ;;
        3) pick_proto "停止" stop_service ;;
        4) pick_proto "启动" start_service ;;
        5) pick_proto "日志" show_log ;;
        6) pick_proto "卸载" uninstall_protocol ;;
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
        3) run_export ;;
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
        1) enable_bbrv3_kernel ;;
        2) warn "XanMod 内核卸载功能暂未集成；如需回退，请先保留云厂商默认内核并手动 apt purge 对应 linux-xanmod 包" ;;
        3) enable_bbr ;;
        4) remove_all ;;
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
self_install || warn "pd 更新失败，使用缓存版本"

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
