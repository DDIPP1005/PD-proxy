#!/usr/bin/env bash
# ============================================================
# PD-proxy — 多协议代理一键部署脚本 v3.0.0
# 协议: Snell v5 | Snell v4 (ShadowTLS) | Hysteria2 | VLESS Reality | AnyTLS
# 仓库: https://github.com/DDIPP1005/PD-proxy
# ============================================================
# 架构：数据驱动 — 所有协议定义为元数据表，安装引擎统一处理
# 原则：零静默错误 — 每步失败显式报错退出，不再吞噬错误
# ============================================================
set -euo pipefail

# bash 4.0+ 必需（关联数组）
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { echo "需要 Bash 4.0+（Debian/Ubuntu 默认满足；macOS /bin/bash 3.2 不支持），当前: ${BASH_VERSION:-unknown}" >&2; exit 1; }

VERSION="3.0.0"
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
  pd --bbr                 开启BBR  pd --update   更新
  pd --remove-all [--yes]  卸载全部

协议: snell (Snell v5) | hy2 (Hysteria2) | vless (VLESS Reality) | anytls

增强选项(环境变量):
  PD_SNELL_MODE=shadowtls  PD_HY2_HOP=5  PD_VLESS_DEST=...:443  PD_ANYTLS_PADDING=deep

示例:
  bash install-fixed.sh --install snell
  bash -c "\$(curl -fsSL ${SCRIPT_URL})"
  bash -c "\$(curl -fsSL ${SCRIPT_URL})" pd --install snell
  PD_HY2_HOP=5 pd --install hy2
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
    echo "  bash <(curl -fsSL ${SCRIPT_URL})" >&2
    echo "非交互安装也建议：" >&2
    echo "  bash -c \"\$(curl -fsSL ${SCRIPT_URL})\" pd --install snell" >&2
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

# HY2 选项
PD_OPT_HY2_HOP="${PD_HY2_HOP:-0}"                       # 0=单端口, 3 或 5

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

json_tag_name() {
    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
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

validate_hy2_hop() {
    case "$PD_OPT_HY2_HOP" in
        0|3|5) ;;
        *) die "PD_HY2_HOP 仅支持 0、3、5，当前: $PD_OPT_HY2_HOP" ;;
    esac
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

del_firewall() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "$port"/tcp >/dev/null 2>&1 || true
        ufw delete allow "$port"/udp >/dev/null 2>&1 || true
    elif command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
        save_iptables
    fi
}

install_deps() {
    local proto="${1:-}"
    local missing=""
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
    tr ' ' '\n' < "$STATE_FILE" | sed -n 's/^port=//p'
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
    # 1. 从 Surge 手册抓取
    v=$(curl -fs --max-time 15 "https://manual.nssurge.com/others/snell.html" 2>/dev/null \
        | sed -n 's/.*snell-server-v\(5\.[0-9][0-9]*\.[0-9][0-9]*[a-z0-9]*\).*/\1/p' \
        | grep -v 'b' | head -1 || true)
    if [ -n "$v" ]; then
        echo "v${v}" | tee "$cache_file"; return 0
    fi
    # 2. 级联 HEAD 探测：Surge 手册临时不可用时仍尽量找到最新版。
    local max_minor="${PD_SNELL_PROBE_MAX:-30}"
    [[ "$max_minor" =~ ^[0-9]+$ ]] || max_minor=30
    [ "$max_minor" -gt 100 ] && max_minor=100
    for ver_prefix in "5.9" "5.8" "5.7" "5.6" "5.5" "5.4" "5.3" "5.2" "5.1" "5.0"; do
        local minor=$max_minor
        while [ $minor -ge 0 ]; do
            local probe="v${ver_prefix}.${minor}"
            local probe_url="https://dl.nssurge.com/snell/snell-server-${probe}-linux-${ARCH}.zip"
            if curl -fsI --max-time 10 "$probe_url" >/dev/null 2>&1; then
                echo "$probe" | tee "$cache_file"; return 0
            fi
            minor=$((minor - 1))
        done
    done
    die "Snell 版本检测失败，请检查网络或手动指定: PD_SNELL_VERSION=v5.0.x"
}

snell_v4_get_version() {
    local v cache_file="$BASE_DIR/.snell-v4-version-${ARCH}"
    mkdir -p "$BASE_DIR"
    # 1. 从 Surge 手册抓取
    v=$(curl -fs --max-time 15 "https://manual.nssurge.com/others/snell.html" 2>/dev/null \
        | sed -n 's/.*snell-server-v\(4\.[0-9][0-9]*\.[0-9][0-9]*[a-z0-9]*\).*/\1/p' \
        | grep -v 'b' | head -1 || true)
    if [ -n "$v" ]; then
        echo "v${v}" | tee "$cache_file"; return 0
    fi
    # 2. 级联 HEAD 探测 v4.x（Surge 手册可能临时不可用）
    local ver_prefix minor
    local max_minor="${PD_SNELL_V4_PROBE_MAX:-30}"
    [[ "$max_minor" =~ ^[0-9]+$ ]] || max_minor=30
    [ "$max_minor" -gt 100 ] && max_minor=100
    for ver_prefix in "4.9" "4.8" "4.7" "4.6" "4.5" "4.4" "4.3" "4.2" "4.1" "4.0"; do
        minor=$max_minor
        while [ $minor -ge 0 ]; do
            local probe="v${ver_prefix}.${minor}"
            local probe_url="https://dl.nssurge.com/snell/snell-server-${probe}-linux-${ARCH}.zip"
            if curl -fsI --max-time 10 "$probe_url" >/dev/null 2>&1; then
                echo "$probe" | tee "$cache_file"; return 0
            fi
            minor=$((minor - 1))
        done
    done
    die "Snell v4 版本检测失败，请检查网络"
}

snell_v4_download() {
    local ver="$1"
    local url="https://dl.nssurge.com/snell/snell-server-${ver}-linux-${ARCH}.zip"
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
    local url="https://dl.nssurge.com/snell/snell-server-${ver}-linux-${ARCH}.zip"
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

snell_output() {
    local port="$1" psk="$2"
    local tls_pass="" tls_sni=""
    local svc_file="/etc/systemd/system/shadowtls-snell.service"
    if [ -f "$svc_file" ] && systemctl is-active --quiet shadowtls-snell 2>/dev/null; then
        # 主提取（脚本生成的标准单行 ExecStart）
        tls_pass=$(unit_password_value "$svc_file" || echo "")
        tls_sni=$(unit_arg_value "--tls" "$svc_file" || echo "")
    fi
    if [ -n "$tls_pass" ]; then
        output_header "Snell v4 + ShadowTLS" "$port"
        echo -e "PSK:     ${GREEN}${psk}${RESET}"
        echo -e "TLS密码: ${GREEN}${tls_pass}${RESET}"
        echo -e "TLS SNI: ${GREEN}${tls_sni}${RESET}"
        echo ""
        echo -e "${CYAN}[Surge 配置]${RESET}"
        echo -e "${GREEN}Proxy = snell, ${IP}, ${port}, psk=${psk}, version=4, reuse=true, shadow-tls-password=${tls_pass}, shadow-tls-sni=${tls_sni%:*}${RESET}"
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
    validate_hostname "$sni" "PD_SNELL_TLS_SNI"
    [ -n "$tls_pass" ] || tls_pass=$(rand_pass)
    tls_pass=$(systemd_escape_arg "$tls_pass")
    PD_OPT_SNELL_TLS_PASS="$tls_pass"

    step "配置 ShadowTLS (SNI: $sni) ..."
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
ExecStart=${bin} server --listen 0.0.0.0:${ext_port} --server 127.0.0.1:${int_port} --tls ${sni}:443 --password ${tls_pass} --wildcard-sni authed
Restart=always
RestartSec=5
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$svc" >/dev/null 2>&1 || true
    systemctl restart "$svc" || { err "ShadowTLS 启动失败，查看 journalctl -u $svc -n 20"; return 1; }
    info "ShadowTLS 已启动 (端口 $ext_port → Snell $int_port)"
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
        local hop_ports="$port"
        local i
        for i in $(seq 1 $((PD_OPT_HY2_HOP - 1))); do
            local hp=$((port + i))
            hop_ports="$hop_ports,$hp"
            if ss -tlnp 2>/dev/null | grep -q ":${hp} " || ss -ulnp 2>/dev/null | grep -q ":${hp} "; then
                warn "跳跃端口 $hp 已被占用，端口跳跃可能不可用"
            fi
        done
        # Hysteria2 只监听主端口，额外端口通过 nft redirect 转发到主端口。
        listen=":${port}"
        info "端口跳跃: $hop_ports"
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
        local hop_list="$port"
        local i
        for i in $(seq 1 $((hop_count - 1))); do
            hop_list="${hop_list},$((port + i))"
        done
        echo -e "${GREEN}Proxy = hysteria2, ${IP}, ${port}-${last_port}, password=${pass}, sni=www.bing.com, skip-cert-verify=true, ports=${hop_list}${RESET}"
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
    local arch_suffix="64"
    [ "$ARCH" = "arm64" ] && arch_suffix="arm64-v8a"
    local url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch_suffix}.zip"
    step "下载 Xray-core ..."
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
    privkey=$(echo "$keys" | grep "Private" | awk '{print $NF}')
    local pubkey
    pubkey=$(echo "$keys" | grep "Public" | awk '{print $NF}')
    local shortid
    shortid=$(openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
    [ -n "$privkey" ] || die "Reality 私钥生成失败"

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

    local link="anytls://${pass}@${IP}:${port}#PD-AnyTLS"
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

    local port port_var="PD_$(echo "$key" | tr '[:lower:]' '[:upper:]')_PORT"
    if [ -n "${!port_var:-}" ]; then
        port="${!port_var}"
        validate_port "$port" "$port_var"
        info "端口(手动): $port"
    else
        port=$(rand_port)
        info "端口(自动): $port"
    fi
    if [ "$proto" = "hy2" ]; then
        validate_hy2_hop
        [ $((port + PD_OPT_HY2_HOP - 1)) -le 65535 ] || die "HY2 跳跃端口超过 65535，请降低 ${port_var} 或 PD_HY2_HOP"
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
        del_firewall '$_rollback_port'
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
        ver=$(snell_v4_get_version)
        info "版本: $ver"
        snell_v4_download "$ver"
    elif declare -f "${proto}_get_version" >/dev/null 2>&1; then
        step "获取版本..."
        ver=$("${proto}_get_version")
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

    add_firewall "$port"
    # 端口跳跃：额外开放跳跃端口
    if [ "$proto" = "hy2" ] && [ "$PD_OPT_HY2_HOP" -ge 3 ] 2>/dev/null; then
        local i
        for i in $(seq 1 $((PD_OPT_HY2_HOP - 1))); do
            add_firewall $((port + i))
        done
        state_set "$key" "hop" "$PD_OPT_HY2_HOP"
    elif [ "$proto" = "hy2" ]; then
        state_set "$key" "hop" "0"
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

    [ -n "$port" ] && del_firewall "$port"
    # HY2 端口跳跃防火墙清理
    if [ "$proto" = "hy2" ]; then
        local listen_line
        listen_line=$(grep 'listen:' "$(pdir hy2)/config.yaml" 2>/dev/null || echo "")
        local hop_count
        hop_count=$(state_get "$key" "hop")
        [ -n "$hop_count" ] || hop_count=$(echo "$listen_line" | tr ',' '\n' | wc -l | tr -d ' \n')
        if [ "$hop_count" -ge 2 ] 2>/dev/null; then
            local i
            for i in $(seq 1 $((hop_count - 1))); do
                del_firewall $((port + i)) 2>/dev/null || true
            done
            clear_hy2_hop_rules
        fi
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
        ver=$(snell_v4_get_version)
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
        ver=$("${proto}_get_version")
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
            local psk tls_pass tls_sni
            psk=$(conf_value "psk" "$(pdir snell)/snell.conf" || echo "")
            local svc_file="/etc/systemd/system/shadowtls-snell.service"
            if [ -f "$svc_file" ] && systemctl is-active --quiet shadowtls-snell 2>/dev/null; then
                tls_pass=$(unit_password_value "$svc_file" || echo "")
                tls_sni=$(unit_arg_value "--tls" "$svc_file" || echo "")
                echo "Proxy = snell, ${IP}, ${port}, psk=${psk}, version=4, reuse=true, shadow-tls-password=${tls_pass}, shadow-tls-sni=${tls_sni%:*}"
            else
                echo "Proxy = snell, ${IP}, ${port}, psk=${psk}, version=5, reuse=true, tfo=true"
            fi ;;
        hy2)
            local pass hop
            pass=$(yaml_value "password" "$(pdir hy2)/config.yaml" || echo "")
            hop=$(state_get "$key" "hop")
            if [ "$hop" -ge 3 ] 2>/dev/null; then
                local last_port=$((port + hop - 1))
                local hop_list="$port"
                local i
                for i in $(seq 1 $((hop - 1))); do
                    hop_list="${hop_list},$((port + i))"
                done
                echo "Proxy = hysteria2, ${IP}, ${port}-${last_port}, password=${pass}, sni=www.bing.com, skip-cert-verify=true, ports=${hop_list}"
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
            echo "# Shadowrocket: anytls://${pass}@${IP}:${port}#PD-AnyTLS" ;;
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

enable_bbr() {
    # 优先检查运行时（比模块检测可靠：BBR 可能编译进内核而非模块）
    local running_cc
    running_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [ "$running_cc" = "bbr" ]; then
        info "BBR 已运行，跳过"
        return
    fi

    local kernel_ver=$(uname -r | cut -d. -f1)
    if [ "$kernel_ver" -lt 4 ]; then
        warn "内核版本过低 ($(uname -r))，不支持 BBR"
        return
    fi

    # 检查持久化配置（避免重复写入 sysctl.conf）
    if grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
        info "BBR 已配置（sysctl.conf），加载中..."
        sysctl -p >/dev/null 2>&1 || true
        running_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
        if [ "$running_cc" = "bbr" ]; then
            info "BBR 已开启"
        else
            warn "BBR 配置存在但未生效，可能需要重启或加载 tcp_bbr 模块"
        fi
        return
    fi

    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
    running_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [ "$running_cc" = "bbr" ]; then
        info "BBR 已开启"
    else
        warn "BBR 写入 sysctl.conf 但未生效，尝试加载模块..."
        modprobe tcp_bbr 2>/dev/null && sysctl -p >/dev/null 2>&1 && info "BBR 已开启" || warn "BBR 开启失败，可能需要重启系统"
    fi
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
        if $source_is_file; then
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
            mv "$tmp_pd" "$BASE_DIR/install.sh"
            chmod +x "$BASE_DIR/install.sh"
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
    elif [ ! -f "$BASE_DIR/install.sh" ]; then
        if $install_from_url; then
            local tmp_pd
            tmp_pd=$(mktemp_pd)
            curl -fsSL "$SCRIPT_URL" -o "$tmp_pd" || {
                rm -f "$tmp_pd"
                warn "无法从 SCRIPT_URL 同步脚本: $SCRIPT_URL"
                return 1
            }
            mv "$tmp_pd" "$BASE_DIR/install.sh"
            chmod +x "$BASE_DIR/install.sh"
        else
            warn "当前脚本不是文件，无法持久化 pd 命令；请设置 PD_SCRIPT_URL 或下载后运行"
            return 1
        fi
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
        read -r confirm
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
        check_root; enable_bbr; exit 0 ;;
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
                break ;;
            [Bb]) return 1 ;;
            [Qq]) info "再见 👋"; exit 0 ;;
            *) warn "无效选择" ;;
        esac
    done
    install_protocol snell
    return 0
}

# ---- HY2 配置子菜单 ----
menu_hy2_config() {
    while true; do
        echo ""
        echo -e "  ${MAGENTA}▸ Hysteria2 — 端口模式${RESET}"
        echo -e "  ${CYAN}┌──────────────────────────────────────┐${RESET}"
        echo -e "  ${CYAN}│${RESET} [1] ${GREEN}单端口${RESET}           标准              ${CYAN}│${RESET}"
        echo -e "  ${CYAN}│${RESET} [2] ${MAGENTA}3 端口跳跃${RESET}       轻量混淆          ${CYAN}│${RESET}"
        echo -e "  ${CYAN}│${RESET} [3] ${MAGENTA}5 端口跳跃${RESET}       深度混淆 (推荐)   ${CYAN}│${RESET}"
        echo -e "  ${CYAN}│${RESET} [B] ${DIM}返回${RESET}                            ${CYAN}│${RESET}"
        echo -e "  ${CYAN}└──────────────────────────────────────┘${RESET}"
        echo -ne "  ${MAGENTA}▸${RESET} 选择: "
        read -r cc
        case "$cc" in
            1) PD_OPT_HY2_HOP=0; break ;;
            2) PD_OPT_HY2_HOP=3; break ;;
            3) PD_OPT_HY2_HOP=5; break ;;
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
    echo -e "  ${CYAN}│${RESET} [1] BBR 优化                          ${CYAN}│${RESET}"
    echo -e "  ${CYAN}│${RESET} [2] 卸载全部协议                       ${CYAN}│${RESET}"
    echo -e "  ${CYAN}│${RESET} [B] ${DIM}返回主菜单${RESET}                      ${CYAN}│${RESET}"
    echo -e "  ${CYAN}└──────────────────────────────────────┘${RESET}"
    echo ""
    echo -ne "  ${MAGENTA}▸${RESET} 选择: "
    read -r cc
    case "$cc" in
        1) enable_bbr ;;
        2) remove_all ;;
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
