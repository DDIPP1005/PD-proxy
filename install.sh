#!/usr/bin/env bash
# ============================================================
# PD-proxy — 多协议代理一键部署脚本
# 协议: Snell v5 | Hysteria2 | VLESS Reality | AnyTLS
# 仓库: https://github.com/DDIPP1005/PD-proxy
# ============================================================
set -euo pipefail

# ============================================================
# 颜色 & 常量
# ============================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

VERSION="1.0.0"
SCRIPT_URL="https://raw.githubusercontent.com/DDIPP1005/PD-proxy/main/install.sh"
BASE_DIR="/opt/pd"
SNELL_DIR="/opt/snell"; HY2_DIR="/opt/hysteria2"
XRAY_DIR="/opt/xray"; ANYTLS_DIR="/opt/anytls"

# ============================================================
# 日志函数
# ============================================================
info()  { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[!]${RESET} $*"; }
err()   { echo -e "${RED}[✗]${RESET} $*" >&2; }
step()  { echo -e "${CYAN}[>]${RESET} $*"; }
title() { echo -e "\n${BOLD}${CYAN}$*${RESET}"; }

# ============================================================
# 公共工具
# ============================================================

check_root() {
    [ "$(id -u)" = "0" ] || { err "请用 root 运行: sudo bash install.sh"; exit 1; }
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
    else
        OS_ID="unknown"
    fi
    case "$OS_ID" in
        debian|ubuntu) OS="debian" ;;
        *) OS="unknown" ;;
    esac
    [ "$OS" = "debian" ] || { err "仅支持 Debian/Ubuntu，当前: $OS_ID"; exit 1; }
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) err "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
}

get_ip() {
    IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 ip.sb 2>/dev/null || echo "未知")
}

get_mem() {
    MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
    MEM_AVAIL=$(free -m | awk '/^Mem:/{print $7}')
}

rand_port() {
    while true; do
        PORT=$(( RANDOM % 50001 + 10000 ))
        ss -tlnp | grep -q ":${PORT} " || { echo "$PORT"; return; }
    done
}

rand_pass() {
    openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64 | tr -d '='
}

install_qrencode() {
    command -v qrencode &>/dev/null && return
    info "安装 qrencode..."
    apt-get update -qq && apt-get install -y -qq qrencode &>/dev/null || true
}

gen_qr() {
    local text="$1"
    command -v qrencode &>/dev/null || return
    qrencode -t ANSIUTF8 -m 1 -s 1 "$text" 2>/dev/null
}

add_firewall() {
    local port="$1"
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$port"/tcp &>/dev/null || true
        ufw allow "$port"/udp &>/dev/null || true
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
    fi
}

del_firewall() {
    local port="$1"
    if command -v ufw &>/dev/null; then
        ufw delete allow "$port"/tcp &>/dev/null || true
        ufw delete allow "$port"/udp &>/dev/null || true
    elif command -v iptables &>/dev/null; then
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
    fi
}

verify_port() {
    local port="$1"
    sleep 1
    ss -tlnp | grep -q ":${port} " && return 0
    warn "端口 $port 未监听，请检查: journalctl -u $2 -n 20"
    return 1
}

install_deps() {
    local pkgs="curl ca-certificates"
    apt-get update -qq &>/dev/null
    apt-get install -y -qq $pkgs &>/dev/null
}

trap_cleanup() {
    rm -f /tmp/pd-proxy.lock
    rm -rf /tmp/pd-*
}
trap trap_cleanup EXIT

# Lock file to prevent concurrent runs
exec 200>/tmp/pd-proxy.lock
flock -n 200 || { err "已有 PD-proxy 进程在运行"; exit 1; }

# ============================================================
# Snell v5
# ============================================================

get_snell_version() {
    local v
    v=$(curl -s https://manual.nssurge.com/others/snell.html | grep -oP 'snell-server-v\K5\.[0-9]+\.[0-9]+[a-z0-9]*' | grep -v b | head -1)
    [ -n "$v" ] && echo "v$v" || echo "v5.0.0"
}

install_snell() {
    title "安装 Snell v5"
    
    # 版本
    step "获取最新版本..."
    SNELL_VER=$(get_snell_version)
    info "版本: $SNELL_VER"
    
    # 端口
    if [ -n "${PD_SNELL_PORT:-}" ]; then
        SNELL_PORT="$PD_SNELL_PORT"
    else
        SNELL_PORT=$(rand_port)
    fi
    info "端口: $SNELL_PORT"
    
    # PSK
    SNELL_PSK=$(rand_pass)
    
    # 下载
    step "下载 Snell $SNELL_VER..."
    local url="https://dl.nssurge.com/snell/snell-server-${SNELL_VER#v}-linux-${ARCH}.zip"
    mkdir -p "$SNELL_DIR"
    curl -fsSL --retry 3 --connect-timeout 10 -o /tmp/pd-snell.zip "$url"
    unzip -o /tmp/pd-snell.zip -d "$SNELL_DIR" &>/dev/null
    chmod +x "$SNELL_DIR/snell-server"
    info "Snell 安装完成"
    
    # 配置
    step "写入配置..."
    cat > "$SNELL_DIR/snell.conf" <<EOF
[snell-server]
listen = 0.0.0.0:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = true
EOF
    chmod 600 "$SNELL_DIR/snell.conf"
    
    # systemd
    step "注册服务..."
    cat > /etc/systemd/system/snell.service <<EOF
[Unit]
Description=Snell v5 Proxy
After=network.target

[Service]
Type=simple
ExecStart=$SNELL_DIR/snell-server -c $SNELL_DIR/snell.conf
Restart=always
RestartSec=5
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable snell &>/dev/null
    systemctl restart snell
    
    # 防火墙 & 验证
    add_firewall "$SNELL_PORT"
    verify_port "$SNELL_PORT" "snell"
    
    # 输出
    echo ""
    echo -e "${BOLD}══════════════════════════════${RESET}"
    echo -e "${BOLD}  Snell v5 ✅ 安装完成${RESET}"
    echo -e "${BOLD}══════════════════════════════${RESET}"
    echo -e "端口:   ${GREEN}${SNELL_PORT}${RESET}"
    echo -e "PSK:    ${GREEN}${SNELL_PSK}${RESET}"
    echo ""
    echo -e "${CYAN}[Surge 配置]${RESET}"
    echo -e "${GREEN}HK-Snell = snell, ${IP}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=5, reuse=true, tfo=true${RESET}"
    echo -e "${BOLD}══════════════════════════════${RESET}"
    
    save_state "snell" "$SNELL_PORT" "installed"
}

uninstall_snell() {
    info "卸载 Snell v5..."
    systemctl stop snell 2>/dev/null || true
    systemctl disable snell 2>/dev/null || true
    rm -f /etc/systemd/system/snell.service
    systemctl daemon-reload
    del_firewall "$(get_state_port snell)"
    rm -rf "$SNELL_DIR"
    save_state "snell" "" "uninstalled"
    info "Snell 已卸载"
}

# ============================================================
# Hysteria2
# ============================================================

get_hy2_version() {
    curl -s "https://api.github.com/repos/apernet/hysteria/releases/latest" \
        | grep -oP '"tag_name":\s*"app/\K[^"]+' | head -1
}

install_hy2() {
    title "安装 Hysteria2"
    
    # 版本
    step "获取最新版本..."
    HY2_VER=$(get_hy2_version)
    [ -z "$HY2_VER" ] && HY2_VER="v2.6.1"
    info "版本: $HY2_VER"
    
    # 端口
    if [ -n "${PD_HY2_PORT:-}" ]; then
        HY2_PORT="$PD_HY2_PORT"
    else
        HY2_PORT=$(rand_port)
    fi
    info "端口: $HY2_PORT"
    
    # 密码
    HY2_PASS=$(rand_pass)
    
    # 下载
    step "下载 Hysteria2 $HY2_VER..."
    local url="https://github.com/apernet/hysteria/releases/download/app/${HY2_VER}/hysteria-linux-${ARCH}"
    mkdir -p "$HY2_DIR"
    curl -fsSL --retry 3 --connect-timeout 10 -o "$HY2_DIR/hysteria" "$url"
    chmod +x "$HY2_DIR/hysteria"
    info "Hysteria2 安装完成"
    
    # 配置
    step "写入配置..."
    cat > "$HY2_DIR/config.yaml" <<EOF
listen: :${HY2_PORT}

tls:
  cert: $HY2_DIR/cert.crt
  key: $HY2_DIR/cert.key

auth:
  type: password
  password: ${HY2_PASS}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
EOF
    # 自签证书
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$HY2_DIR/cert.key" -out "$HY2_DIR/cert.crt" \
        -days 3650 -nodes -subj "/CN=bing.com" &>/dev/null
    chmod 600 "$HY2_DIR/config.yaml"
    
    # systemd
    step "注册服务..."
    cat > /etc/systemd/system/hysteria2.service <<EOF
[Unit]
Description=Hysteria2 Proxy
After=network.target

[Service]
Type=simple
ExecStart=$HY2_DIR/hysteria server -c $HY2_DIR/config.yaml
Restart=always
RestartSec=5
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hysteria2 &>/dev/null
    systemctl restart hysteria2
    
    # 防火墙 & 验证
    add_firewall "$HY2_PORT"
    verify_port "$HY2_PORT" "hysteria2"
    
    # 输出
    echo ""
    echo -e "${BOLD}══════════════════════════════${RESET}"
    echo -e "${BOLD}  Hysteria2 ✅ 安装完成${RESET}"
    echo -e "${BOLD}══════════════════════════════${RESET}"
    echo -e "端口:   ${GREEN}${HY2_PORT}${RESET}"
    echo -e "密码:   ${GREEN}${HY2_PASS}${RESET}"
    echo ""
    echo -e "${CYAN}[Surge 配置]${RESET}"
    echo -e "${GREEN}HK-HY2 = hysteria2, ${IP}, ${HY2_PORT}, password=${HY2_PASS}, sni=www.bing.com, skip-cert-verify=true${RESET}"
    echo ""
    echo -e "${CYAN}[Shadowrocket]${RESET}"
    gen_qr "hysteria2://${HY2_PASS}@${IP}:${HY2_PORT}?sni=www.bing.com&insecure=1#PD-HY2"
    echo -e "${BOLD}══════════════════════════════${RESET}"
    
    save_state "hy2" "$HY2_PORT" "installed"
}

uninstall_hy2() {
    info "卸载 Hysteria2..."
    systemctl stop hysteria2 2>/dev/null || true
    systemctl disable hysteria2 2>/dev/null || true
    rm -f /etc/systemd/system/hysteria2.service
    systemctl daemon-reload
    del_firewall "$(get_state_port hy2)"
    rm -rf "$HY2_DIR"
    save_state "hy2" "" "uninstalled"
    info "Hysteria2 已卸载"
}

# ============================================================
# VLESS Reality (Xray-core)
# ============================================================

install_vless() {
    title "安装 VLESS Reality"
    
    # 端口
    if [ -n "${PD_VLESS_PORT:-}" ]; then
        VLESS_PORT="$PD_VLESS_PORT"
    else
        VLESS_PORT=$(rand_port)
    fi
    info "端口: $VLESS_PORT"
    
    # UUID
    VLESS_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || rand_pass | head -c 36)
    
    # Xray 安装
    step "安装 Xray-core..."
    if [ ! -f "$XRAY_DIR/xray" ]; then
        mkdir -p "$XRAY_DIR"
        curl -fsSL --retry 3 --connect-timeout 10 -o /tmp/pd-xray.zip \
            "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH/amd64/64}.zip"
        unzip -o /tmp/pd-xray.zip -d "$XRAY_DIR" &>/dev/null
        chmod +x "$XRAY_DIR/xray"
    fi
    info "Xray-core 安装完成"
    
    # 生成密钥
    step "生成 Reality 密钥..."
    KEYS=$("$XRAY_DIR/xray" x25519 2>/dev/null)
    PRIVATE_KEY=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$KEYS" | grep "Public" | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | xxd -p)
    
    # 配置
    step "写入配置..."
    cat > "$XRAY_DIR/config.json" <<EOF
{
  "inbounds": [{
    "port": ${VLESS_PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${VLESS_UUID}", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "addons.mozilla.org:443",
        "serverNames": ["addons.mozilla.org", "www.microsoft.com"],
        "privateKey": "${PRIVATE_KEY}",
        "shortIds": ["${SHORT_ID}"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    chmod 600 "$XRAY_DIR/config.json"
    
    # systemd
    step "注册服务..."
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray (VLESS Reality)
After=network.target

[Service]
Type=simple
ExecStart=$XRAY_DIR/xray run -c $XRAY_DIR/config.json
Restart=always
RestartSec=5
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xray &>/dev/null
    systemctl restart xray
    
    # 防火墙 & 验证
    add_firewall "$VLESS_PORT"
    verify_port "$VLESS_PORT" "xray"
    
    # 输出
    local vless_link="vless://${VLESS_UUID}@${IP}:${VLESS_PORT}?encryption=none&security=reality&sni=addons.mozilla.org&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#PD-VLESS"
    
    echo ""
    echo -e "${BOLD}══════════════════════════════${RESET}"
    echo -e "${BOLD}  VLESS Reality ✅ 安装完成${RESET}"
    echo -e "${BOLD}══════════════════════════════${RESET}"
    echo -e "端口:   ${GREEN}${VLESS_PORT}${RESET}"
    echo -e "UUID:   ${GREEN}${VLESS_UUID}${RESET}"
    echo ""
    echo -e "${YELLOW}⚠ Surge 不支持 VLESS Reality，请用 Shadowrocket${RESET}"
    echo ""
    echo -e "${CYAN}[Shadowrocket]${RESET}"
    gen_qr "$vless_link"
    echo ""
    echo -e "${CYAN}[通用链接]${RESET}"
    echo -e "${GREEN}${vless_link}${RESET}"
    echo -e "${BOLD}══════════════════════════════${RESET}"
    
    save_state "vless" "$VLESS_PORT" "installed"
}

uninstall_vless() {
    info "卸载 VLESS Reality..."
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
    rm -f /etc/systemd/system/xray.service
    systemctl daemon-reload
    del_firewall "$(get_state_port vless)"
    rm -rf "$XRAY_DIR"
    save_state "vless" "" "uninstalled"
    info "VLESS Reality 已卸载"
}

# ============================================================
# AnyTLS (anytls-go)
# ============================================================

get_anytls_version() {
    curl -s "https://api.github.com/repos/anytls/anytls-go/releases/latest" \
        | grep -oP '"tag_name":\s*"\K[^"]+' | head -1
}

install_anytls() {
    title "安装 AnyTLS (beta)"
    
    # 版本
    step "获取最新版本..."
    ANYTLS_VER=$(get_anytls_version)
    [ -z "$ANYTLS_VER" ] && ANYTLS_VER="v0.0.12"
    info "版本: $ANYTLS_VER"
    
    # 端口
    if [ -n "${PD_ANYTLS_PORT:-}" ]; then
        ANYTLS_PORT="$PD_ANYTLS_PORT"
    else
        ANYTLS_PORT=$(rand_port)
    fi
    info "端口: $ANYTLS_PORT"
    
    # 密码
    ANYTLS_PASS=$(rand_pass)
    
    # 下载
    step "下载 AnyTLS $ANYTLS_VER..."
    local ver_num="${ANYTLS_VER#v}"
    local url="https://github.com/anytls/anytls-go/releases/download/${ANYTLS_VER}/anytls_${ver_num}_linux_${ARCH}.zip"
    mkdir -p "$ANYTLS_DIR"
    curl -fsSL --retry 3 --connect-timeout 10 -o /tmp/pd-anytls.zip "$url"
    unzip -o /tmp/pd-anytls.zip -d "$ANYTLS_DIR" &>/dev/null
    chmod +x "$ANYTLS_DIR/anytls-server"
    info "AnyTLS 安装完成"
    
    # 密码文件
    echo "$ANYTLS_PASS" > "$ANYTLS_DIR/.password"
    chmod 600 "$ANYTLS_DIR/.password"
    
    # systemd
    step "注册服务..."
    cat > /etc/systemd/system/anytls.service <<EOF
[Unit]
Description=AnyTLS Proxy
After=network.target

[Service]
Type=simple
ExecStart=$ANYTLS_DIR/anytls-server -l 0.0.0.0:${ANYTLS_PORT} -p ${ANYTLS_PASS}
Restart=always
RestartSec=5
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable anytls &>/dev/null
    systemctl restart anytls
    
    # 防火墙 & 验证
    add_firewall "$ANYTLS_PORT"
    verify_port "$ANYTLS_PORT" "anytls"
    
    # 输出
    local anytls_link="anytls://${ANYTLS_PASS}@${IP}:${ANYTLS_PORT}#PD-AnyTLS"
    
    echo ""
    echo -e "${BOLD}══════════════════════════════${RESET}"
    echo -e "${BOLD}  AnyTLS ✅ 安装完成${RESET}"
    echo -e "${BOLD}══════════════════════════════${RESET}"
    echo -e "端口:   ${GREEN}${ANYTLS_PORT}${RESET}"
    echo -e "密码:   ${GREEN}${ANYTLS_PASS}${RESET}"
    echo ""
    echo -e "${CYAN}[Surge]${RESET}"
    echo -e "${YELLOW}⚠ Surge 对 AnyTLS 的支持未官方确认，可能需要外部代理模块${RESET}"
    echo -e "${GREEN}anytls, ${IP}, ${ANYTLS_PORT}, password=${ANYTLS_PASS}${RESET}"
    echo ""
    echo -e "${CYAN}[Shadowrocket]${RESET}"
    gen_qr "$anytls_link"
    echo ""
    echo -e "${CYAN}[通用链接]${RESET}"
    echo -e "${GREEN}${anytls_link}${RESET}"
    echo -e "${BOLD}══════════════════════════════${RESET}"
    
    save_state "anytls" "$ANYTLS_PORT" "installed"
}

uninstall_anytls() {
    info "卸载 AnyTLS..."
    systemctl stop anytls 2>/dev/null || true
    systemctl disable anytls 2>/dev/null || true
    rm -f /etc/systemd/system/anytls.service
    systemctl daemon-reload
    del_firewall "$(get_state_port anytls)"
    rm -rf "$ANYTLS_DIR"
    save_state "anytls" "" "uninstalled"
    info "AnyTLS 已卸载"
}

# ============================================================
# 状态管理
# ============================================================

STATE_FILE="$BASE_DIR/state"
[ -d "$BASE_DIR" ] || mkdir -p "$BASE_DIR"

save_state() {
    local name="$1" port="$2" status="$3"
    touch "$STATE_FILE"
    grep -v "^${name} " "$STATE_FILE" > /tmp/pd-state-tmp 2>/dev/null || true
    echo "${name} ${port} ${status}" >> /tmp/pd-state-tmp
    mv /tmp/pd-state-tmp "$STATE_FILE"
}

get_state_port() {
    grep "^${1} " "$STATE_FILE" 2>/dev/null | awk '{print $2}' || echo ""
}

get_state_status() {
    grep "^${1} " "$STATE_FILE" 2>/dev/null | awk '{print $3}' || echo "uninstalled"
}

is_installed() {
    [ "$(get_state_status "$1")" = "installed" ]
}

check_status() {
    local name="$1" service="$2"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "✅ 运行中"
    else
        echo "❌ 已停止"
    fi
}

show_status() {
    title "PD-proxy"
    echo -e "${CYAN}══════════════════════════════════════════${RESET}"
    
    for proto in snell hysteria2 xray anytls; do
        local sname=""
        case $proto in
            snell) sname="Snell v5     " ;;
            hysteria2) sname="Hysteria2    " ;;
            xray) sname="VLESS Reality" ;;
            anytls) sname="AnyTLS       " ;;
        esac
        
        local port=$(get_state_port "$proto")
        if [ "$(get_state_status "$proto")" = "installed" ] && [ -n "$port" ]; then
            local svc=""
            case $proto in
                snell) svc="snell" ;;
                hysteria2) svc="hysteria2" ;;
                xray) svc="xray" ;;
                anytls) svc="anytls" ;;
            esac
            local st=$(check_status "$proto" "$svc")
            local mem=""
            case $proto in
                snell) mem="5MB" ;;
                hysteria2) mem="18MB" ;;
                xray) mem="30MB" ;;
                anytls) mem="5MB" ;;
            esac
            echo -e "  ${sname} 端口 ${port}  ${st}  ${mem}"
        else
            echo -e "  ${sname} ${YELLOW}未安装${RESET}"
        fi
    done
    
    echo -e "${CYAN}══════════════════════════════════════════${RESET}"
    echo -e "系统: $(. /etc/os-release && echo "$PRETTY_NAME") | IP: $IP"
    echo -e "${CYAN}══════════════════════════════════════════${RESET}"
}

# ============================================================
# BBR 优化
# ============================================================

enable_bbr() {
    local kernel_ver=$(uname -r | cut -d. -f1)
    if [ "$kernel_ver" -lt 4 ]; then
        warn "内核版本过低，不支持 BBR"
        return
    fi
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p &>/dev/null
    info "BBR 已开启"
}

# ============================================================
# 自安装（pd 命令）
# ============================================================

self_install() {
    mkdir -p "$BASE_DIR"
    # 直接从 GitHub 下载最新版（最稳健，避免管道模式下 $0 不可靠）
    curl -fsSL "$SCRIPT_URL" -o "$BASE_DIR/install.sh" 2>/dev/null || true
    chmod +x "$BASE_DIR/install.sh" 2>/dev/null || true
    
    # pd 命令
    ln -sf "$BASE_DIR/install.sh" /usr/local/bin/pd 2>/dev/null || true
    
    # 更新脚本
    cat > /usr/local/bin/pd-update <<'UEOF'
#!/bin/bash
echo "正在更新 PD-proxy..."
curl -fsSL https://raw.githubusercontent.com/DDIPP1005/PD-proxy/main/install.sh -o /opt/pd/install.sh
chmod +x /opt/pd/install.sh
echo "更新完成！运行 pd 进入管理"
UEOF
    chmod +x /usr/local/bin/pd-update
}

# ============================================================
# 卸载全部
# ============================================================

remove_all() {
    echo -e "${RED}⚠ 即将卸载所有代理协议和 PD-proxy${RESET}"
    read -rp "确认？输入 yes: " confirm
    [ "$confirm" = "yes" ] || { info "已取消"; return; }
    
    for proto in snell hy2 vless anytls; do
        if is_installed "$proto"; then
            case $proto in
                snell) uninstall_snell ;;
                hysteria2|hy2) uninstall_hy2 ;;
                vless|xray) uninstall_vless ;;
                anytls) uninstall_anytls ;;
            esac
        fi
    done
    
    rm -f /usr/local/bin/pd
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
    echo -e "║  ${RESET}${BOLD}系统:${RESET} $(. /etc/os-release && echo "$PRETTY_NAME" | cut -c1-25)${BOLD}${CYAN}        ║"
    echo -e "║  ${RESET}${BOLD}架构:${RESET} ${ARCH}  |  ${BOLD}内存:${RESET} ${MEM_AVAIL}MB 可用${BOLD}${CYAN}      ║"
    echo -e "║  ${RESET}${BOLD}IP:${RESET}   ${IP}${BOLD}${CYAN}          ║"
    echo "╠══════════════════════════════════════════╣"
    echo -e "║  ${RESET}${BOLD}Snell v5${RESET} [5MB]  Surge 主力协议              ${BOLD}${CYAN}║"
    echo -e "║  ${RESET}${BOLD}Hysteria2${RESET} [20MB] UDP 加速                   ${BOLD}${CYAN}║"
    echo -e "║  ${RESET}${BOLD}VLESS${RESET} [30MB] 仅 Shadowrocket               ${BOLD}${CYAN}║"
    echo -e "║  ${RESET}${BOLD}AnyTLS${RESET} [5MB]  新兴协议 (beta)               ${BOLD}${CYAN}║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${RESET}"
    
    echo "1) 安装 Snell v5      (Surge)"
    echo "2) 安装 Hysteria2     (Surge + Shadowrocket)"
    echo "3) 安装 VLESS Reality (仅 Shadowrocket)"
    echo "4) 安装 AnyTLS (beta) (Surge + Shadowrocket)"
    echo "5) 查看状态"
    echo "6) 卸载协议"
    echo "7) 开启 BBR"
    echo "8) 全部卸载"
    echo "9) 退出"
    echo ""
    read -rp "选择 [1-9]: " choice
    
    case "$choice" in
        1) install_snell; press_enter; main_menu ;;
        2) install_hy2; press_enter; main_menu ;;
        3) install_vless; press_enter; main_menu ;;
        4) install_anytls; press_enter; main_menu ;;
        5) show_status; press_enter; main_menu ;;
        6) remove_menu; press_enter; main_menu ;;
        7) enable_bbr; press_enter; main_menu ;;
        8) remove_all ;;
        9) info "再见 👋"; exit 0 ;;
        *) main_menu ;;
    esac
}

press_enter() {
    echo ""
    read -rp "回车返回菜单..."
}

remove_menu() {
    echo ""
    echo "卸载协议:"
    echo "1) Snell v5"
    echo "2) Hysteria2"
    echo "3) VLESS Reality"
    echo "4) AnyTLS"
    echo "0) 返回"
    read -rp "选择: " rc
    case "$rc" in
        1) uninstall_snell ;;
        2) uninstall_hy2 ;;
        3) uninstall_vless ;;
        4) uninstall_anytls ;;
        0) return ;;
    esac
}

# ============================================================
# 入口
# ============================================================

# 处理命令行参数
case "${1:-}" in
    --status|-s)
        check_root; detect_os; detect_arch; get_ip; get_mem; show_status
        exit 0
        ;;
    --remove|-r)
        check_root
        case "${2:-}" in
            snell) uninstall_snell ;;
            hysteria2|hy2) uninstall_hy2 ;;
            vless|xray) uninstall_vless ;;
            anytls) uninstall_anytls ;;
            all|--all) remove_all ;;
            *) echo "用法: pd --remove <snell|hy2|vless|anytls|all>" ;;
        esac
        exit 0
        ;;
    --remove-all)
        check_root; remove_all
        exit 0
        ;;
esac

# 初始化
check_root
detect_os
detect_arch
get_ip
get_mem
install_deps
self_install

# 如果有已安装的协议 → 直接进管理
if is_installed snell || is_installed hy2 || is_installed vless || is_installed anytls; then
    show_status
    echo ""
    echo "1) 加装新协议"
    echo "2) 卸载某协议"
    echo "3) 开启 BBR"
    echo "4) 全部卸载"
    echo "5) 退出"
    read -rp "选择: " cc
    case "$cc" in
        1) main_menu ;;
        2) remove_menu ;;
        3) enable_bbr ;;
        4) remove_all ;;
        *) info "再见 👋"; exit 0 ;;
    esac
else
    # 无已安装 → Snell 优先推荐
    main_menu
fi
