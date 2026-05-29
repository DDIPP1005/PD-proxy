#!/usr/bin/env bash
# ============================================================
# PD-proxy — 多协议代理一键部署脚本 v2.3.0
# 协议: Snell v5 | Hysteria2 | VLESS Reality | AnyTLS
# 仓库: https://github.com/DDIPP1005/PD-proxy
# ============================================================
# 架构：数据驱动 — 所有协议定义为元数据表，安装引擎统一处理
# 原则：零静默错误 — 每步失败显式报错退出，不再吞噬错误
# ============================================================
set -euo pipefail

VERSION="2.3.0"
SCRIPT_URL="https://raw.githubusercontent.com/DDIPP1005/PD-proxy/main/install.sh"

# 纯查询命令，不需要锁和 root
case "${1:-}" in
    --help|-h)
        cat <<EOF
PD-proxy v${VERSION} — 多协议代理一键部署

用法:
  pd                         进入交互菜单
  pd --install <协议>         非交互安装指定协议
  pd --uninstall <协议>       卸载协议
  pd --upgrade <协议>         升级协议二进制（保留配置）
  pd --restart <协议>         重启协议服务
  pd --stop <协议>             停止协议服务
  pd --log <协议>              查看协议日志（最近50行）
  pd --config <协议>          仅输出客户端配置（无日志）
  pd --config-all             输出所有已安装协议的配置
  pd --export                 导出所有配置到 /opt/pd/export.conf
  pd --status                查看所有协议状态
  pd --show                  查看所有协议配置
  pd --bbr                   开启 BBR 优化
  pd --update                更新 pd 自身
  pd --remove-all            卸载全部（加 --yes 跳过确认）
  pd --help                  显示此帮助

协议:
  snell       Snell v5 (Surge 主力)
  hy2         Hysteria2 (Surge + Shadowrocket)
  vless       VLESS Reality (仅 Shadowrocket)
  anytls      AnyTLS (beta)

环境变量:
  PD_SNELL_PORT=12345        手动指定端口
  PD_HY2_PORT=12346
  PD_VLESS_PORT=12347
  PD_ANYTLS_PORT=12348
  
示例:
  curl -fsSL https://raw.githubusercontent.com/DDIPP1005/PD-proxy/main/install.sh | bash -s -- --install snell
  PD_SNELL_PORT=12345 pd --install snell
EOF
        exit 0 ;;
    --version|-v)
        echo "PD-proxy v${VERSION}"; exit 0 ;;
esac

# ============================================================
# 颜色 & 常量
# ============================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# 管道或重定向时自动去色
if [ ! -t 1 ]; then
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

BASE_DIR="/opt/pd"
STATE_FILE="$BASE_DIR/state"
INSTALLED_BIN="/usr/local/bin/pd"
LOCK_FILE="/tmp/pd-proxy.lock"

# 并发锁
exec 200>"$LOCK_FILE"
flock -n 200 || die "已有 PD-proxy 进程在运行，请稍后再试"

# 临时文件
mktemp_pd() { mktemp /tmp/pd-XXXXXX; }
trap 'rm -f /tmp/pd-* 2>/dev/null' EXIT

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
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_PRETTY="${PRETTY_NAME:-unknown}"
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
        local p=$(( $(od -An -N2 -i /dev/urandom | tr -d ' ') % 50001 + 10000 ))
        if ! echo "$used_ports" | grep -q " $p "; then
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

verify_download() {
    local file="$1" label="$2" min_bytes="${3:-100000}"
    if [ ! -f "$file" ]; then
        die "$label 下载失败：文件不存在"
    fi
    local size
    size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "0")
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

add_firewall() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port"/tcp >/dev/null 2>&1 || true
        ufw allow "$port"/udp >/dev/null 2>&1 || true
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
        # 持久化：优先用 netfilter-persistent，否则手动 save
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1 || true
        elif [ -d /etc/iptables ]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
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
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1 || true
        elif [ -d /etc/iptables ]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
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
    apt-get install -y -qq qrencode >/dev/null 2>&1 || warn "qrencode 安装失败，跳过二维码生成"
}

gen_qr() {
    command -v qrencode >/dev/null 2>&1 || return
    qrencode -t ANSIUTF8 -m 1 -s 1 "$1" 2>/dev/null || true
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
        line="${line} ${field}=${value}"
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

# 协议元数据: key, name, dir, bin, service, mem_mb, disk_mb
declare -A PROTO=()

register_protocols() {
    # ---- Snell v5 ----
    PROTO[snell_key]="snell"
    PROTO[snell_name]="Snell v5"
    PROTO[snell_dir]="/opt/snell"
    PROTO[snell_bin]="/opt/snell/snell-server"
    PROTO[snell_service]="snell"
    PROTO[snell_mem]="5MB"
    PROTO[snell_disk]="20"

    # ---- Hysteria2 ----
    PROTO[hy2_key]="hy2"
    PROTO[hy2_name]="Hysteria2"
    PROTO[hy2_dir]="/opt/hysteria2"
    PROTO[hy2_bin]="/opt/hysteria2/hysteria"
    PROTO[hy2_service]="hysteria2"
    PROTO[hy2_mem]="18MB"
    PROTO[hy2_disk]="30"

    # ---- VLESS Reality ----
    PROTO[vless_key]="vless"
    PROTO[vless_name]="VLESS Reality"
    PROTO[vless_dir]="/opt/xray"
    PROTO[vless_bin]="/opt/xray/xray"
    PROTO[vless_service]="xray"
    PROTO[vless_mem]="30MB"
    PROTO[vless_disk]="60"

    # ---- AnyTLS ----
    PROTO[anytls_key]="anytls"
    PROTO[anytls_name]="AnyTLS"
    PROTO[anytls_dir]="/opt/anytls"
    PROTO[anytls_bin]="/opt/anytls/anytls-server"
    PROTO[anytls_service]="anytls"
    PROTO[anytls_mem]="5MB"
    PROTO[anytls_disk]="20"
}

# 获取协议元数据
pkey()   { echo "${PROTO[${1}_key]}"; }
pname()  { echo "${PROTO[${1}_name]}"; }
pdir()   { echo "${PROTO[${1}_dir]}"; }
pbin()   { echo "${PROTO[${1}_bin]}"; }
psvc()   { echo "${PROTO[${1}_service]}"; }
pmem()   { echo "${PROTO[${1}_mem]}"; }
pdisk()  { echo "${PROTO[${1}_disk]}"; }

ALL_PROTOS="snell hy2 vless anytls"

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
    echo -e "${BOLD}  $1 ✅ 安装完成${RESET}"
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
    if [ -f "$cache_file" ] && [ "$(($(date +%s) - $(stat -f%m "$cache_file" 2>/dev/null || stat -c%Y "$cache_file" 2>/dev/null || echo 0)))" -lt 86400 ]; then
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
    # 3. 级联探测 (v5.0.1 → v5.0.9, v5.1.0 → v5.1.5)
    for ver_prefix in "5.0" "5.1"; do
        local start=1 end=9
        [ "$ver_prefix" = "5.1" ] && end=5
        local minor=$start
        while [ $minor -le $end ]; do
            local probe="v${ver_prefix}.${minor}"
            local probe_url="https://dl.nssurge.com/snell/snell-server-${probe}-linux-${ARCH}.zip"
            if curl -fsI --max-time 10 "$probe_url" >/dev/null 2>&1; then
                echo "$probe" | tee "$cache_file"; return 0
            fi
            minor=$((minor + 1))
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
    local port="$1" psk="$2"
    local ipv6_enabled="false"
    has_ipv6 && ipv6_enabled="true"
    cat > "$(pdir snell)/snell.conf" <<EOF
[snell-server]
listen = 0.0.0.0:${port}
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
    output_header "Snell v5" "$port"
    echo -e "PSK:    ${GREEN}${psk}${RESET}"
    echo ""
    echo -e "${CYAN}[Surge 配置]${RESET}"
    echo -e "${GREEN}Proxy = snell, ${IP}, ${port}, psk=${psk}, version=5, reuse=true, tfo=true${RESET}"
    output_footer
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
    curl -fSL# --retry 3 --connect-timeout 15 --max-time 300 -o "$(pbin hy2)" "$url" \
        || die "Hysteria2 下载失败: $url"
    chmod +x "$(pbin hy2)"
    verify_download "$(pbin hy2)" "Hysteria2" 5000000
    info "Hysteria2 下载完成"
}

hy2_configure() {
    local port="$1" pass="$2"
    cat > "$(pdir hy2)/config.yaml" <<EOF
listen: :${port}

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
    echo -e "${GREEN}Proxy = hysteria2, ${IP}, ${port}, password=${pass}, sni=www.bing.com, skip-cert-verify=true${RESET}"
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
    step "生成 Reality 密钥..."
    local keys
    keys=$("$(pbin vless)" x25519 2>/dev/null) || die "Xray x25519 密钥生成失败"
    local privkey
    privkey=$(echo "$keys" | grep "Private" | awk '{print $3}')
    local pubkey
    pubkey=$(echo "$keys" | grep "Public" | awk '{print $3}')
    local shortid
    shortid=$(openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | xxd -p)
    [ -n "$privkey" ] || die "Reality 私钥生成失败"

    # 保存公钥供输出使用
    echo "$pubkey" > "$(pdir vless)/.pubkey"
    echo "$shortid" > "$(pdir vless)/.shortid"

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
        "dest": "addons.mozilla.org:443",
        "serverNames": ["addons.mozilla.org", "www.microsoft.com"],
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
    local pubkey shortid
    pubkey=$(cat "$(pdir vless)/.pubkey" 2>/dev/null || echo "未知")
    shortid=$(cat "$(pdir vless)/.shortid" 2>/dev/null || echo "未知")
    local link="vless://${uuid}@${IP}:${port}?encryption=none&security=reality&sni=addons.mozilla.org&fp=chrome&pbk=${pubkey}&sid=${shortid}&type=tcp&flow=xtls-rprx-vision#PD-VLESS"

    output_header "VLESS Reality" "$port"
    echo -e "UUID:   ${GREEN}${uuid}${RESET}"
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
    echo "$pass" > "$(pdir anytls)/.password"
    chmod 600 "$(pdir anytls)/.password"
}

anytls_service_args() {
    local pass
    pass=$(cat "$(pdir anytls)/.password")
    echo "-l 0.0.0.0:${1} -p ${pass}"
}

anytls_output() {
    local port="$1" pass="$2"
    local link="anytls://${pass}@${IP}:${port}#PD-AnyTLS"
    output_header "AnyTLS" "$port"
    echo -e "密码:   ${GREEN}${pass}${RESET}"
    echo ""
    echo -e "${CYAN}[Surge]${RESET}"
    echo -e "${YELLOW}⚠ Surge 对 AnyTLS 的支持未官方确认${RESET}"
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

    # 0. 预检
    check_disk "$(pdisk "$proto")"
    if state_installed "$key"; then
        warn "$name 已安装，跳过"
        return 0
    fi

    # 1. 端口
    local port
    local port_var="PD_$(echo "$key" | tr '[:lower:]' '[:upper:]')_PORT"
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
        systemctl daemon-reload
        del_firewall '$_rollback_port'
        rm -rf '$dir'
        state_del '$key'
        die '安装失败，已回滚，检查上述错误信息'
    " ERR

    # 2. 密码
    local pass
    pass=$(rand_pass)

    # 3. 版本
    local ver=""
    if declare -f "${proto}_get_version" >/dev/null 2>&1; then
        step "获取版本..."
        ver=$("${proto}_get_version")
        info "版本: $ver"
    fi

    # 4. 下载
    if [ "$proto" = "vless" ] && ! command -v python3 >/dev/null 2>&1; then
        info "安装 python3（VLESS 需要）..."
        apt-get install -y -qq python3 >/dev/null || die "python3 安装失败"
    fi
    "${proto}_download" "$ver"

    # 5. 配置
    step "写入配置..."
    "${proto}_configure" "$port" "$pass"

    # 6. systemd
    step "注册服务..."
    write_systemd "$svc" "$bin" "$("${proto}_service_args" "$port")"
    register_and_start "$svc"

    # 7. 防火墙 & 验证
    add_firewall "$port"
    verify_port "$port" "$svc" || warn "请检查服务状态"

    # 8. 保存状态
    state_set "$key" "port" "$port"
    state_set "$key" "status" "installed"
    state_set "$key" "version" "$ver"

    # 9. 输出配置
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
    systemctl daemon-reload
    systemctl reset-failed "${svc}.service" 2>/dev/null || true

    [ -n "$port" ] && del_firewall "$port"
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
            local psk
            psk=$(grep -oP 'psk\s*=\s*\K.+' "$(pdir snell)/snell.conf" 2>/dev/null || echo "")
            echo "Proxy = snell, ${IP}, ${port}, psk=${psk}, version=5, reuse=true, tfo=true" ;;
        hy2)
            local pass
            pass=$(grep -oP 'password:\s*\K.+' "$(pdir hy2)/config.yaml" 2>/dev/null || echo "")
            echo "Proxy = hysteria2, ${IP}, ${port}, password=${pass}, sni=www.bing.com, skip-cert-verify=true"
            echo ""
            echo "# Shadowrocket: hysteria2://${pass}@${IP}:${port}?sni=www.bing.com&insecure=1#PD-HY2" ;;
        vless)
            local uuid pubkey shortid
            if command -v python3 >/dev/null 2>&1; then
                uuid=$(python3 -c "import json,sys; c=json.load(open(sys.argv[1])); print(c['inbounds'][0]['settings']['clients'][0]['id'])" "$(pdir vless)/config.json" 2>/dev/null || echo "")
            else
                uuid=""
            fi
            pubkey=$(cat "$(pdir vless)/.pubkey" 2>/dev/null || echo "")
            shortid=$(cat "$(pdir vless)/.shortid" 2>/dev/null || echo "")
            echo "# Surge 不支持 VLESS"
            echo "vless://${uuid}@${IP}:${port}?encryption=none&security=reality&sni=addons.mozilla.org&fp=chrome&pbk=${pubkey}&sid=${shortid}&type=tcp&flow=xtls-rprx-vision#PD-VLESS" ;;
        anytls)
            local pass
            pass=$(cat "$(pdir anytls)/.password" 2>/dev/null || echo "")
            echo "anytls, ${IP}, ${port}, password=${pass}"
            echo ""
            echo "# Shadowrocket: anytls://${pass}@${IP}:${port}#PD-AnyTLS" ;;
    esac
}

# ============================================================
# 状态 & 配置查看
# ============================================================

show_status() {
    title "PD-proxy 状态"
    echo -e "${CYAN}══════════════════════════════════════════${RESET}"
    local has_any=false
    for proto in $ALL_PROTOS; do
        local key=$(pkey "$proto")
        local name=$(pname "$proto")
        if state_installed "$key"; then
            has_any=true
            local port=$(state_get "$key" "port")
            local ver=$(state_get "$key" "version")
            local svc=$(psvc "$proto")
            local st uptime=""
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                st="✅ 运行中"
                local started
                started=$(systemctl show "$svc" --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2)
                if [ -n "$started" ]; then
                    local now=$(date +%s)
                    local start_ts=$(date -d "$started" +%s 2>/dev/null || echo 0)
                    local elapsed=$((now - start_ts))
                    if [ $elapsed -gt 86400 ]; then
                        uptime="$(($elapsed / 86400))天"
                    elif [ $elapsed -gt 3600 ]; then
                        uptime="$(($elapsed / 3600))小时"
                    else
                        uptime="$(($elapsed / 60))分钟"
                    fi
                fi
            else
                st="❌ 已停止"
            fi
            printf "  %-15s 端口 %-7s %s %s  %s  v%s\n" "$name" "$port" "$st" "${uptime}" "$(pmem "$proto")" "$ver"
        else
            printf "  %-15s ${YELLOW}未安装${RESET}\n" "$name"
        fi
    done
    echo -e "${CYAN}══════════════════════════════════════════${RESET}"
    echo -e "系统: ${OS_PRETTY} | IP: ${IP} | 内存: ${MEM_AVAIL}MB 可用"
    echo -e "${CYAN}══════════════════════════════════════════${RESET}"
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
                if command -v python3 >/dev/null 2>&1; then
                    uuid=$(python3 -c "import json,sys; c=json.load(open(sys.argv[1])); print(c['inbounds'][0]['settings']['clients'][0]['id'])" "$(pdir vless)/config.json" 2>/dev/null || echo "未知")
                else
                    uuid="未知"
                fi
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
        curl -fsSL "$SCRIPT_URL" -o "$BASE_DIR/install.sh" || {
            warn "无法从 GitHub 同步最新脚本，使用当前版本"
            return 1
        }
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
# 主菜单
# ============================================================

main_menu() {
    clear 2>/dev/null || true
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║            PD-proxy  v${VERSION}              ║"
    echo "╠══════════════════════════════════════════╣"
    printf "║  ${RESET}${BOLD}系统:${RESET} %-26s${BOLD}${CYAN}║\n" "$(echo "$OS_PRETTY" | cut -c1-26)"
    printf "║  ${RESET}${BOLD}架构:${RESET} %-5s | ${BOLD}内存:${RESET} %-6s MB${BOLD}${CYAN}       ║\n" "$ARCH" "$MEM_AVAIL"
    printf "║  ${RESET}${BOLD}IP:${RESET}   %-28s${BOLD}${CYAN}║\n" "$IP"
    echo "╠══════════════════════════════════════════╣"
    printf "║  ${RESET}${BOLD}Snell v5${RESET}   [%s]  Surge 主力              ${BOLD}${CYAN}║\n" "$(pmem snell)"
    printf "║  ${RESET}${BOLD}Hysteria2${RESET}  [%s] Surge + Shadowrocket     ${BOLD}${CYAN}║\n" "$(pmem hy2)"
    printf "║  ${RESET}${BOLD}VLESS${RESET}      [%s] 仅 Shadowrocket           ${BOLD}${CYAN}║\n" "$(pmem vless)"
    printf "║  ${RESET}${BOLD}AnyTLS${RESET}     [%s] 新兴协议 (beta)           ${BOLD}${CYAN}║\n" "$(pmem anytls)"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${RESET}"

    echo " 1) 安装 Snell v5     (Surge)"
    echo " 2) 安装 Hysteria2    (Surge + Shadowrocket)"
    echo " 3) 安装 VLESS Reality (仅 Shadowrocket)"
    echo " 4) 安装 AnyTLS       (Surge + Shadowrocket, beta)"
    echo " 5) 查看状态"
    echo " 6) 查看配置"
    echo " 7) 卸载协议"
    echo " 8) 开启 BBR"
    echo " 9) 全部卸载"
    echo " 0) 退出"
    echo ""
    echo -n "选择 [0-9]: "
    read -r choice

    case "$choice" in
        1) install_protocol snell; press_enter; main_menu ;;
        2) install_protocol hy2; press_enter; main_menu ;;
        3) install_protocol vless; press_enter; main_menu ;;
        4) install_protocol anytls; press_enter; main_menu ;;
        5) show_status; press_enter; main_menu ;;
        6) show_config; press_enter; main_menu ;;
        7) remove_menu; press_enter; main_menu ;;
        8) enable_bbr; press_enter; main_menu ;;
        9) remove_all ;;
        0) info "再见 👋"; exit 0 ;;
        *) main_menu ;;
    esac
}

press_enter() {
    echo ""
    echo -n "回车返回菜单..."
    read -r
}

remove_menu() {
    echo ""
    echo "卸载协议:"
    echo "1) Snell v5"
    echo "2) Hysteria2"
    echo "3) VLESS Reality"
    echo "4) AnyTLS"
    echo "0) 返回"
    echo -n "选择: "
    read -r rc
    case "$rc" in
        1) uninstall_protocol snell ;;
        2) uninstall_protocol hy2 ;;
        3) uninstall_protocol vless ;;
        4) uninstall_protocol anytls ;;
        0) return ;;
    esac
}

# ============================================================
# 入口
# ============================================================

# 交互式协议选择
pick_proto() {
    local action="$1" func="$2"
    echo ""
    echo "选择要${action}的协议:"
    local i=1
    for p in $ALL_PROTOS; do
        if state_installed "$(pkey "$p")"; then
            echo "  $i) $(pname "$p")"
            eval "_pick_$i=$p"
            i=$((i + 1))
        fi
    done
    [ $i -eq 1 ] && { warn "没有已安装的协议"; return; }
    echo -n "选择: "
    read -r pick
    local target
    eval "target=\$_pick_$pick"
    [ -n "${target:-}" ] || { warn "无效选择"; return; }
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
    info "配置已导出到 /opt/pd/export.conf"
}

# 注册协议表
register_protocols

# 解析命令行
case "${1:-}" in
    --install|-i)
        [ -z "${2:-}" ] && die "用法: pd --install <snell|hy2|vless|anytls>"
        check_root; detect_os; detect_arch; get_ip; get_mem
        install_deps; install_qrencode; self_install || warn "pd 更新失败，使用缓存版本"
        case "${2}" in
            snell) install_protocol snell ;;
            hy2|hysteria2) install_protocol hy2 ;;
            vless|xray) install_protocol vless ;;
            anytls) install_protocol anytls ;;
            *) die "未知协议: $2，可选: snell hy2 vless anytls" ;;
        esac
        exit 0 ;;
    --uninstall|-r)
        [ -z "${2:-}" ] && die "用法: pd --uninstall <snell|hy2|vless|anytls>"
        check_root; detect_os
        case "${2}" in
            snell) uninstall_protocol snell ;;
            hy2|hysteria2) uninstall_protocol hy2 ;;
            vless|xray) uninstall_protocol vless ;;
            anytls) uninstall_protocol anytls ;;
            all|--all) remove_all ;;
            *) die "未知协议: $2" ;;
        esac
        exit 0 ;;
    --upgrade|-u)
        [ -z "${2:-}" ] && die "用法: pd --upgrade <snell|hy2|vless|anytls>"
        check_root; detect_os; detect_arch; get_ip
        case "${2}" in
            snell) upgrade_protocol snell ;;
            hy2|hysteria2) upgrade_protocol hy2 ;;
            vless|xray) upgrade_protocol vless ;;
            anytls) upgrade_protocol anytls ;;
            *) die "未知协议: $2" ;;
        esac
        exit 0 ;;
    --restart)
        [ -z "${2:-}" ] && die "用法: pd --restart <snell|hy2|vless|anytls>"
        check_root
        case "${2}" in
            snell) restart_service snell ;;
            hy2|hysteria2) restart_service hy2 ;;
            vless|xray) restart_service vless ;;
            anytls) restart_service anytls ;;
            *) die "未知协议: $2" ;;
        esac
        exit 0 ;;
    --stop)
        [ -z "${2:-}" ] && die "用法: pd --stop <snell|hy2|vless|anytls>"
        check_root
        case "${2}" in
            snell) stop_service snell ;;
            hy2|hysteria2) stop_service hy2 ;;
            vless|xray) stop_service vless ;;
            anytls) stop_service anytls ;;
            *) die "未知协议: $2" ;;
        esac
        exit 0 ;;
    --log|-l)
        [ -z "${2:-}" ] && die "用法: pd --log <snell|hy2|vless|anytls>"
        case "${2}" in
            snell) show_log snell ;;
            hy2|hysteria2) show_log hy2 ;;
            vless|xray) show_log vless ;;
            anytls) show_log anytls ;;
            *) die "未知协议: $2" ;;
        esac
        exit 0 ;;
    --config-all)
        detect_os; detect_arch; get_ip
        for p in $ALL_PROTOS; do
            if state_installed "$(pkey "$p")"; then
                echo "=== $(pname "$p") ==="
                show_config_only "$p"
                echo ""
            fi
        done
        exit 0 ;;
    --export)
        check_root; run_export
        exit 0 ;;
    --config|-c)
        [ -z "${2:-}" ] && die "用法: pd --config <snell|hy2|vless|anytls>"
        detect_os; detect_arch; get_ip; show_config_only "${2}"
        exit 0 ;;
    --status|-s)
        detect_os; detect_arch; get_ip; get_mem; show_status
        exit 0 ;;
    --show|--config)
        detect_os; detect_arch; get_ip; get_mem; show_config
        exit 0 ;;
    --bbr)
        check_root; enable_bbr
        exit 0 ;;
    --update)
        check_root; PD_UPDATE=1 self_install
        info "PD-proxy 已更新到最新版"
        exit 0 ;;
    --remove-all)
        check_root
        [ "${2:-}" = "--yes" ] && PD_YES=1
        remove_all
        exit 0 ;;
esac

# 交互模式
check_root
detect_os
detect_arch
get_ip
get_mem
install_deps
install_qrencode
self_install || warn "pd 更新失败，使用缓存版本"

# 已有安装 → 完整管理面板
if state_installed snell || state_installed hy2 || state_installed vless || state_installed anytls; then
    show_status
    echo ""
    echo " 安装: 1)Snell 2)HY2 3)VLESS 4)AnyTLS"
    echo " 管理: u)升级 r)重启 s)停止 l)日志"
    echo " 查看: c)配置行 C)完整配置 e)导出"
    echo " 系统: b)BBR   d)卸载   R)全部卸载"
    echo "       q)退出"
    echo ""
    echo -n "选择: "
    read -r cc
    case "$cc" in
        1) install_protocol snell; press_enter ;;
        2) install_protocol hy2; press_enter ;;
        3) install_protocol vless; press_enter ;;
        4) install_protocol anytls; press_enter ;;
        u) pick_proto "升级" upgrade_protocol; press_enter ;;
        r) pick_proto "重启" restart_service; press_enter ;;
        s) pick_proto "停止" stop_service; press_enter ;;
        l) pick_proto "日志" show_log ;;
        c) pick_proto "配置" show_config_only ;;
        C) show_config; press_enter ;;
        e) run_export; press_enter ;;
        b) enable_bbr; press_enter ;;
        d) remove_menu; press_enter ;;
        R) remove_all ;;
        q) info "再见 👋"; exit 0 ;;
        *) ;;
    esac
    exec "$0"  # 重新进入菜单（刷新状态）
else
    main_menu
fi
