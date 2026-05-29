#!/usr/bin/env bash
# ============================================================
# PD-proxy — 多协议代理一键部署脚本 v2.7.0
# 协议: Snell v5 | Hysteria2 | VLESS Reality | AnyTLS
# 仓库: https://github.com/DDIPP1005/PD-proxy
# ============================================================
# 架构：数据驱动 — 所有协议定义为元数据表，安装引擎统一处理
# 原则：零静默错误 — 每步失败显式报错退出，不再吞噬错误
# ============================================================
set -euo pipefail

# bash 4.0+ 必需（关联数组）
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { echo "需要 bash 4.0+，当前: ${BASH_VERSION:-unknown}" >&2; exit 1; }

VERSION="2.7.3"
SCRIPT_URL="https://raw.githubusercontent.com/DDIPP1005/PD-proxy/main/install.sh"

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
  curl -fsSL https://raw.githubusercontent.com/DDIPP1005/PD-proxy/main/install.sh | bash -s -- --install snell
  PD_HY2_HOP=5 pd --install hy2
EOF
        exit 0 ;;
    --version|-v)
        echo "PD-proxy v${VERSION}"; exit 0 ;;
esac

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

# ============================================================
# 协议安装选项（环境变量 → 全局变量，被 install_protocol 读取）
# ============================================================

# Snell 选项
PD_OPT_SNELL_MODE="${PD_SNELL_MODE:-standard}"          # standard | shadowtls
PD_OPT_SNELL_TLS_SNI="${PD_SNELL_TLS_SNI:-www.microsoft.com}"
PD_OPT_SNELL_TLS_PASS="${PD_SNELL_TLS_PASS:-}"          # 空=自动生成

# HY2 选项
PD_OPT_HY2_HOP="${PD_HY2_HOP:-0}"                       # 0=单端口, 3, 5, 或自定义

# VLESS 选项
PD_OPT_VLESS_DEST="${PD_VLESS_DEST:-addons.mozilla.org:443}"
PD_OPT_VLESS_SNI="${PD_VLESS_SNI:-addons.mozilla.org}"
PD_OPT_VLESS_TRANSPORT="${PD_VLESS_TRANSPORT:-tcp}"     # tcp | grpc | ws
PD_OPT_VLESS_FP="${PD_VLESS_FP:-chrome}"                # chrome | firefox | safari | ios | randomized

# AnyTLS 选项
PD_OPT_ANYTLS_PADDING="${PD_ANYTLS_PADDING:-standard}"  # standard | deep | fixed | none
PD_OPT_ANYTLS_SNI="${PD_ANYTLS_SNI:-}"                  # 空=不伪装

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
# 日志（永不静默）
# ============================================================
info()  { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[!]${RESET} $*"; }
err()   { echo -e "${RED}[✗]${RESET} $*" >&2; }
step()  { echo -e "${CYAN}[>]${RESET} $*"; }
title() { echo -e "\n${BOLD}${CYAN}$*${RESET}"; }
die()   { err "$@"; exit 1; }

# ============================================================
# 公共工具
# ============================================================

check_root() {
    [ "$(id -u)" = "0" ] || die "请用 root 运行: sudo bash install.sh"
}

detect_os() {
    if [ -f /etc/os-release ]; then
        OS_ID=$(grep -oP '^ID=\K.+' /etc/os-release 2>/dev/null | tr -d '"' || echo "unknown")
        OS_PRETTY=$(grep -oP '^PRETTY_NAME=\K.+' /etc/os-release 2>/dev/null | tr -d '"' || echo "unknown")
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

check_disk() {
    local need_mb="$1"
    local avail_kb
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
            if ss -tlnp 2>/dev/null | grep -q ":${p} "; then
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
    openssl rand -base64 32 2>/dev/null || {
        local raw
        raw=$(head -c 32 /dev/urandom | base64 2>/dev/null | tr -d '=\n') 
        [ -n "$raw" ] || raw=$(date +%s%N | sha256sum | cut -d' ' -f1)
        echo "$raw"
    }
}

gen_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || {
        printf '%08x-%04x-%04x-%04x-%04x%08x\n' \
            $((RANDOM<<16|RANDOM)) $RANDOM $((RANDOM%0x10000)) \
            $((RANDOM%0x4000+0x4000)) $((RANDOM%0x4000+0x8000)) \
            $((RANDOM<<16|RANDOM))
    }
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
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
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
    local missing=""
    command -v curl >/dev/null 2>&1 || missing="$missing curl"
    command -v unzip >/dev/null 2>&1 || missing="$missing unzip"
    [ -z "$missing" ] && return 0
    info "安装依赖: $missing"
    apt-get update -qq || die "apt-get update 失败，请检查网络"
    apt-get install -y -qq $missing >/dev/null || die "依赖安装失败"
}

install_qrencode() {
    command -v qrencode >/dev/null 2>&1 && return 0
    info "安装 qrencode..."
    apt-get update -qq 2>/dev/null || true
    apt-get install -y -qq qrencode >/dev/null 2>&1 || warn "qrencode 安装失败，跳过二维码生成"
}

gen_qr() {
    command -v qrencode >/dev/null 2>&1 || return
    echo "$1" | qrencode -t ANSIUTF8 -m 1 -s 1 -r /dev/stdin 2>/dev/null || true
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
    echo "$line" | grep -oP "${field}=\\K\\S+" 2>/dev/null || echo ""
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
        line=$(echo "$line" | sed "s/${field}=\\S*/${field}=${value}/")
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
    [ -f "$STATE_FILE" ] || return
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
    [ -f "$STATE_FILE" ] || return
    grep -oP 'port=\K\S+' "$STATE_FILE" 2>/dev/null
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
    local v cache_file="$BASE_DIR/.snell-version"
    # 1. 尝试缓存
    if [ -f "$cache_file" ] && [ "$(($(date +%s) - $(stat -c%Y "$cache_file" 2>/dev/null || stat -f%m "$cache_file" 2>/dev/null || echo 0)))" -lt 86400 ]; then
        v=$(cat "$cache_file")
        # 验证版本是否仍可下载
        local test_url="https://dl.nssurge.com/snell/snell-server-${v}-linux-${ARCH}.zip"
        if curl -fsI --max-time 10 "$test_url" >/dev/null 2>&1; then
            echo "$v"; return 0
        fi
    fi
    # 2. 从 Surge 手册抓取
    v=$(curl -fs --max-time 15 "https://manual.nssurge.com/others/snell.html" 2>/dev/null \
        | grep -oP 'snell-server-v\K5\.[0-9]+\.[0-9]+[a-z0-9]*' \
        | grep -v 'b' | head -1)
    if [ -n "$v" ]; then
        echo "v${v}" | tee "$cache_file"; return 0
    fi
    # 3. 级联探测（5.1探3次，5.0全探到底 — v5.0.1是amd64唯一可用版本）
    for ver_prefix in "5.1" "5.0"; do
        local minor=10
        local group_limit=3
        [ "$ver_prefix" = "5.0" ] && group_limit=10
        local group_count=0
        while [ $minor -ge 1 ] && [ $group_count -lt $group_limit ]; do
            local probe="v${ver_prefix}.${minor}"
            local probe_url="https://dl.nssurge.com/snell/snell-server-${probe}-linux-${ARCH}.zip"
            if curl -fsI --max-time 10 "$probe_url" >/dev/null 2>&1; then
                echo "$probe" | tee "$cache_file"; return 0
            fi
            minor=$((minor - 1))
            group_count=$((group_count + 1))
        done
    done
    die "Snell 版本检测失败，请检查网络或手动指定: PD_SNELL_VERSION=v5.0.x"
}

snell_download() {
    local ver="$1"
    local url="https://dl.nssurge.com/snell/snell-server-${ver}-linux-${ARCH}.zip"
    step "下载 Snell $ver ..."
    mkdir -p "$(pdir snell)"
    local tmpzip=$(mktemp_pd)
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
    if [ -f "/etc/systemd/system/shadowtls-snell.service" ]; then
        tls_pass=$(grep -oP 'password \\K\\S+' /etc/systemd/system/shadowtls-snell.service 2>/dev/null || echo "")
        tls_sni=$(grep -oP -- '--tls \\K\\S+' /etc/systemd/system/shadowtls-snell.service 2>/dev/null || echo "")
    fi
    if [ -n "$tls_pass" ]; then
        output_header "Snell v5 + ShadowTLS" "$port"
        echo -e "PSK:     ${GREEN}${psk}${RESET}"
        echo -e "TLS密码: ${GREEN}${tls_pass}${RESET}"
        echo -e "TLS SNI: ${GREEN}${tls_sni}${RESET}"
        echo ""
        echo -e "${CYAN}[Surge 配置]${RESET}"
        echo -e "${GREEN}Proxy = snell, ${IP}, ${port}, psk=${psk}, version=5, reuse=true, tfo=true, shadow-tls-password=${tls_pass}, shadow-tls-sni=${tls_sni}${RESET}"
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
    local dir="/opt/shadowtls" bin="$dir/shadow-tls"
    [ -x "$bin" ] && { info "ShadowTLS 已安装" >&2; echo "$bin"; return 0; }

    step "下载 ShadowTLS ..." >&2
    local ver
    ver=$(curl -fs --retry 3 --max-time 15 "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" 2>/dev/null \
        | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)
    [ -n "$ver" ] || die "ShadowTLS 版本检测失败"

    # shadow-tls release 用 x86_64 / aarch64 而非 amd64 / arm64
    local stls_arch="$ARCH"
    [ "$stls_arch" = "amd64" ] && stls_arch="x86_64"
    [ "$stls_arch" = "arm64" ] && stls_arch="aarch64"
    local url="https://github.com/ihciah/shadow-tls/releases/download/${ver}/shadow-tls-${stls_arch}-unknown-linux-musl"
    mkdir -p "$dir"
    local tmpbin=$(mktemp_pd)
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
    [ -n "$tls_pass" ] || tls_pass=$(rand_pass)
    PD_OPT_SNELL_TLS_PASS="$tls_pass"

    step "配置 ShadowTLS (SNI: $sni) ..."
    local svc="shadowtls-snell"
    local bin=$(install_shadowtls)
    cat > "/etc/systemd/system/${svc}.service" <<EOF
[Unit]
Description=PD-proxy: ShadowTLS for Snell
After=network.target snell.service
Requires=snell.service

[Service]
Type=simple
ExecStart=${bin} server --listen 0.0.0.0:${ext_port} --server 127.0.0.1:${int_port} --tls ${sni} --password ${tls_pass}
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
        | grep -oP '"tag_name":\s*"app/\K[^"]+' | head -1)
    [ -n "$v" ] && echo "$v" || die "Hysteria2 版本检测失败，请检查 GitHub 是否可达"
}

hy2_download() {
    local ver="$1"
    local url="https://github.com/apernet/hysteria/releases/download/app/${ver}/hysteria-linux-${ARCH}"
    step "下载 Hysteria2 $ver ..."
    mkdir -p "$(pdir hy2)"
    local tmpbin=$(mktemp_pd)
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
    if [ "$PD_OPT_HY2_HOP" -ge 3 ] 2>/dev/null; then
        local hop_ports="$port"
        local i
        for i in $(seq 1 $((PD_OPT_HY2_HOP - 1))); do
            local hp=$((port + i))
            hop_ports="$hop_ports,$hp"
            if ss -tlnp 2>/dev/null | grep -q ":${hp} "; then
                warn "跳跃端口 $hp 已被占用，Hysteria2 可能无法监听该端口"
            fi
        done
        listen=":${hop_ports}"
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
    local listen_line hop_count
    listen_line=$(grep 'listen:' "$(pdir hy2)/config.yaml" 2>/dev/null || echo "")
    hop_count=$(echo "$listen_line" | tr ',' '\n' | wc -l | tr -d ' \n')
    if [ "${hop_count:-0}" -ge 3 ] 2>/dev/null; then
        local last_port=$((port + hop_count - 1))
        local hop_list
        hop_list=$(echo "$listen_line" | grep -oP ':(\K.*)')
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
vless_download() {
    local arch_suffix="64"
    [ "$ARCH" = "arm64" ] && arch_suffix="arm64-v8a"
    local url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch_suffix}.zip"
    step "下载 Xray-core ..."
    mkdir -p "$(pdir vless)"
    local tmpzip=$(mktemp_pd)
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

    # 构建 serverNames JSON 数组
    local snames_json="[\"${dest_host}\""
    for sn in $(echo "$sni_list" | tr ',' ' '); do
        [ "$sn" = "$dest_host" ] && continue
        snames_json="${snames_json}, \"${sn}\""
    done
    snames_json="${snames_json}]"

    # 根据传输方式生成 streamSettings
    local stream_settings network_settings
    case "$transport" in
        grpc)
            network_settings="\"network\": \"grpc\", \"security\": \"reality\", \"grpcSettings\": {\"serviceName\": \"\"}"
            ;;
        ws)
            network_settings="\"network\": \"ws\", \"security\": \"reality\", \"wsSettings\": {\"path\": \"/\"}"
            ;;
        *)  # tcp
            network_settings="\"network\": \"tcp\", \"security\": \"reality\""
            ;;
    esac

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
      ${network_settings},
      "realitySettings": {
        "dest": "${dest}",
        "serverNames": ${snames_json},
        "privateKey": "${privkey}",
        "shortIds": ["${shortid}"]
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
        | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)
    [ -n "$v" ] && echo "$v" || die "AnyTLS 版本检测失败，请检查 GitHub 是否可达"
}

anytls_download() {
    local ver="$1"
    local ver_num="${ver#v}"
    local url="https://github.com/anytls/anytls-go/releases/download/${ver}/anytls_${ver_num}_linux_${ARCH}.zip"
    step "下载 AnyTLS $ver ..."
    mkdir -p "$(pdir anytls)"
    local tmpzip=$(mktemp_pd)
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

    echo "$pass" > "$(pdir anytls)/.password"
    echo "$padding" > "$(pdir anytls)/.padding"
    echo "$sni" > "$(pdir anytls)/.sni"
    chmod 600 "$(pdir anytls)/.password"
}

anytls_service_args() {
    local port="$1"
    local pass padding sni
    pass=$(cat "$(pdir anytls)/.password" 2>/dev/null || echo "")
    padding=$(cat "$(pdir anytls)/.padding" 2>/dev/null || echo "standard")
    sni=$(cat "$(pdir anytls)/.sni" 2>/dev/null || echo "")

    local args="-l 0.0.0.0:${port} -p ${pass}"
    case "$padding" in
        deep)  args="$args --padding-scheme deep" ;;
        fixed) args="$args --padding-scheme fixed" ;;
        none)  args="$args --padding-scheme none" ;;
        *)     ;;  # standard: 默认
    esac
    [ -n "$sni" ] && args="$args --sni $sni"
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
    echo -e "填充:   ${DIM}${padding}${RESET}"
    [ -n "$sni" ] && echo -e "SNI:    ${DIM}${sni}${RESET}"
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

    title "安装 $name"

    install_deps; install_qrencode
    check_disk "$(pdisk "$proto")"
    if state_installed "$key"; then
        warn "$name 已安装，跳过"
        return 0
    fi

    local port port_var="PD_$(echo "$key" | tr '[:lower:]' '[:upper:]')_PORT"
    if [ -n "${!port_var:-}" ]; then
        port="${!port_var}"
        info "端口(手动): $port"
    else
        port=$(rand_port)
        info "端口(自动): $port"
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
        rm -rf '$dir'
        state_del '$key'
        die '安装失败，已回滚，检查上述错误信息'
    " ERR

    local pass=$(rand_pass)
    # VLESS 需要标准 UUID 格式，不能是 base64
    [ "$proto" = "vless" ] && pass=$(gen_uuid)

    local ver=""
    if declare -f "${proto}_get_version" >/dev/null 2>&1; then
        step "获取版本..."
        ver=$("${proto}_get_version")
        info "版本: $ver"
    fi

    "${proto}_download" "$ver"

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
    write_systemd "$svc" "$bin" "$("${proto}_service_args" "$port")"
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
        hop_count=$(echo "$listen_line" | tr ',' '\n' | wc -l | tr -d ' \n')
        if [ "$hop_count" -ge 2 ] 2>/dev/null; then
            local i
            for i in $(seq 1 $((hop_count - 1))); do
                del_firewall $((port + i)) 2>/dev/null || true
            done
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

    local ver=""
    if declare -f "${proto}_get_version" >/dev/null 2>&1; then
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

    step "下载新版本..."
    "${proto}_download" "$ver"

    step "启动服务..."
    systemctl start "$svc" || die "启动 $svc 失败: journalctl -u $svc -n 20"
    # Snell + ShadowTLS: Requires= 只传播 stop 不传播 start，需手动拉起
    if [ "$proto" = "snell" ] && [ -f /etc/systemd/system/shadowtls-snell.service ]; then
        systemctl start shadowtls-snell 2>/dev/null || warn "ShadowTLS 启动失败"
    fi

    state_set "$key" "version" "$ver"
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
        systemctl start shadowtls-snell 2>/dev/null || true
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
        systemctl start shadowtls-snell 2>/dev/null || true
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
            psk=$(grep -oP 'psk\s*=\s*\K.+' "$(pdir snell)/snell.conf" 2>/dev/null || echo "")
            if [ -f "/etc/systemd/system/shadowtls-snell.service" ]; then
                tls_pass=$(grep -oP 'password \\K\\S+' /etc/systemd/system/shadowtls-snell.service 2>/dev/null || echo "")
                tls_sni=$(grep -oP -- '--tls \\K\\S+' /etc/systemd/system/shadowtls-snell.service 2>/dev/null || echo "")
                echo "Proxy = snell, ${IP}, ${port}, psk=${psk}, version=5, reuse=true, tfo=true, shadow-tls-password=${tls_pass}, shadow-tls-sni=${tls_sni}"
            else
                echo "Proxy = snell, ${IP}, ${port}, psk=${psk}, version=5, reuse=true, tfo=true"
            fi ;;
        hy2)
            local pass hop
            pass=$(grep -oP 'password:\s*\K.+' "$(pdir hy2)/config.yaml" 2>/dev/null || echo "")
            local listen_line=$(grep 'listen:' "$(pdir hy2)/config.yaml" 2>/dev/null || echo "")
            hop=$(echo "$listen_line" | tr ',' '\n' | wc -l | tr -d ' \n')
            if [ "$hop" -ge 3 ] 2>/dev/null; then
                local last_port=$((port + hop - 1))
                echo "Proxy = hysteria2, ${IP}, ${port}-${last_port}, password=${pass}, sni=www.bing.com, skip-cert-verify=true, ports=$(echo "$listen_line" | grep -oP ':(\K.*)')"
            else
                echo "Proxy = hysteria2, ${IP}, ${port}, password=${pass}, sni=www.bing.com, skip-cert-verify=true"
            fi
            echo ""
            echo "# Shadowrocket: hysteria2://${pass}@${IP}:${port}?sni=www.bing.com&insecure=1#PD-HY2" ;;
        vless)
            local uuid pubkey shortid dest transport fp dest_host
            uuid=$(grep -oP '"id":\s*"\K[^"]+' "$(pdir vless)/config.json" 2>/dev/null | head -1 || echo "")
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
        if state_installed "$key"; then
            local port=$(state_get "$key" "port")
            local ver=$(state_get "$key" "version")
            local svc=$(psvc "$proto")
            local st icon
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
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
                psk=$(grep -oP 'psk\s*=\s*\K.+' "$(pdir snell)/snell.conf" 2>/dev/null || echo "未知")
                snell_output "$port" "$psk" ;;
            hy2)
                local pass
                pass=$(grep -oP 'password:\s*\K.+' "$(pdir hy2)/config.yaml" 2>/dev/null || echo "未知")
                hy2_output "$port" "$pass" ;;
            vless)
                local uuid
                uuid=$(grep -oP '"id":\s*"\K[^"]+' "$(pdir vless)/config.json" 2>/dev/null | head -1 || echo "未知")
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
    local kernel_ver=$(uname -r | cut -d. -f1)
    if [ "$kernel_ver" -lt 4 ]; then
        warn "内核版本过低 ($(uname -r))，不支持 BBR"
        return
    fi
    if lsmod 2>/dev/null | grep -q tcp_bbr; then
        info "BBR 已开启，跳过"
        return
    fi
    if grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null; then
        info "BBR 已配置，跳过"
        return
    fi
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    info "BBR 已开启"
}

# ============================================================
# 自安装（pd 命令）
# ============================================================

self_install() {
    mkdir -p "$BASE_DIR"
    # 仅在首次安装或显式更新时下载
    if [ ! -f "$BASE_DIR/install.sh" ] || [ "${PD_UPDATE:-}" = "1" ]; then
        local tmp_pd=$(mktemp_pd)
        curl -fsSL "$SCRIPT_URL" -o "$tmp_pd" || {
            rm -f "$tmp_pd"
            warn "无法从 GitHub 同步最新脚本，使用当前版本"
            return 1
        }
        mv "$tmp_pd" "$BASE_DIR/install.sh"
        chmod +x "$BASE_DIR/install.sh"
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
        [ "${2:-}" = "all" ] || [ "${2:-}" = "--all" ] && { check_root; remove_all; exit 0; }
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
        info "PD-proxy 已更新到最新版"; exit 0 ;;
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

        echo ""
        echo -e "  ${MAGENTA}▸ 传输方式${RESET}"
        echo -e "  [1] TCP (默认)  [2] gRPC  [3] WebSocket"
        echo -ne "  ${MAGENTA}▸${RESET} 选择 [1]: "
        read -r trans
        case "$trans" in
            2) PD_OPT_VLESS_TRANSPORT="grpc" ;;
            3) PD_OPT_VLESS_TRANSPORT="ws" ;;
            *) PD_OPT_VLESS_TRANSPORT="tcp" ;;
        esac

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
