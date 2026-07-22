# PD-proxy

> 一个 `pd` 命令，部署和管理 Snell、Hysteria2、VLESS Reality、AnyTLS 与独立 IPv4 端口转发。

<p>
  <kbd>v4.0.0</kbd>
  <kbd>Debian / Ubuntu</kbd>
  <kbd>amd64 / arm64</kbd>
  <kbd>Surge / Shadowrocket</kbd>
</p>

[快速开始](#快速开始) · [支持协议](#支持协议) · [常用命令](#常用命令) · [部署示例](#部署示例) · [端口转发](#ipv4-单端口转发) · [旧版更新](#旧版无中断更新) · [故障诊断](#故障诊断)

---

## 主要特点

- **统一管理**：交互菜单与完整 CLI，安装、升级、启停、日志、配置集中处理。
- **失败回滚**：安装、升级和 Snell 模式切换采用事务流程，验证失败自动尝试恢复。
- **双栈支持**：支持 IPv4、IPv6 和双栈，只输出实际验证可用的地址。
- **Snell 多版本**：安装时可选 v4、v5、v6，并按所选大版本自动解析官方最新资产。
- **ShadowTLS 可切换**：安装时可启用，也可在 Snell 深入管理中后续启用、修改或关闭，无需重装 Snell。
- **安全更新**：HTTPS 下载、可选 SHA-256 严格校验、原子写入和资源所有权保护。
- **独立端口转发**：通过 nftables DNAT/MASQUERADE 管理 IPv4 TCP、UDP 或 TCP+UDP 单端口转发，支持启停、修改、修复与开机恢复。
- **一键诊断**：`pd --doctor` 检查服务、端口、监听族、防火墙和 BBR。

## 支持协议

| 协议 | 标识 | 传输 | 客户端 | 说明 |
|---|---|---|---|---|
| Snell v4 / v5 / v6 | `snell` | TCP | Surge | 默认选择 v5；v6 支持 `default` / `unshaped` |
| Snell + ShadowTLS | `snell` | TCP | Surge | ShadowTLS v2 / v3，可后续启用、修改或关闭 |
| Hysteria2 | `hy2` | UDP | Surge、Shadowrocket | 支持端口跳跃 |
| VLESS Reality | `vless` | TCP | Shadowrocket | Reality + TCP Vision |
| AnyTLS | `anytls` | TCP | Surge、Shadowrocket | 轻量 TLS 隧道 |

## 快速开始

### 1. 下载脚本

```bash
curl --proto '=https' --proto-redir '=https' -fsSLo install.sh \
  https://raw.githubusercontent.com/DDIPP1005/PD-proxy/main/install.sh
```

> [!NOTE]
> 私有仓库无法直接使用普通 raw 地址时，请在 GitHub 下载 `install.sh`，再通过可信方式上传到 VPS。不要把 GitHub Token 写进 URL 或命令历史。

### 2. 检查并运行

```bash
bash -n install.sh
sudo bash install.sh
```

> [!IMPORTANT]
> 交互菜单必须先下载再执行，不能使用 `curl ... | bash`，否则菜单无法读取键盘输入。

安装完成后即可使用：

```bash
pd --status
sudo pd --config-all
sudo pd --doctor
```

### 非交互安装

```bash
sudo bash install.sh --install snell
sudo bash install.sh --install hy2
sudo bash install.sh --install vless
sudo bash install.sh --install anytls
```

环境变量必须与 `--install <协议>` 同时使用，单独设置变量不会开始安装。

选择 Snell 大版本：

```bash
sudo env PD_SNELL_MAJOR=4 bash install.sh --install snell
sudo env PD_SNELL_MAJOR=5 bash install.sh --install snell
sudo env PD_SNELL_MAJOR=6 PD_SNELL_V6_MODE=unshaped \
  bash install.sh --install snell
```

未设置 `PD_SNELL_MAJOR` 时默认安装 v5。脚本优先从 Snell 官方英文发布说明中的真实下载资产解析所选大版本最新版；无法读取时再探测下载源，最后才使用上次成功缓存。要求官方最新版检测失败时直接停止，可设置 `PD_STRICT_LATEST=1`；需要固定具体版本时使用 `PD_SNELL_VERSION=vX.Y.Z`。

## 常用命令

| 命令 | 用途 | 权限 |
|---|---|---|
| `pd` | 打开交互菜单 | Root |
| `pd --status` | 查看服务状态 | 普通用户 |
| `pd --show` | 查看状态和全部配置 | 建议 Root |
| `pd --config <协议>` | 显示单协议配置 | 建议 Root |
| `pd --config-all` | 显示全部配置 | 建议 Root |
| `pd --install <协议>` | 安装协议 | Root |
| `pd --upgrade <协议>` | 升级协议服务端程序 | Root |
| `pd --update` | 只更新管理脚本 | Root |
| `pd --restart <协议>` | 重启并验证服务 | Root |
| `pd --stop <协议>` / `pd --start <协议>` | 停止 / 启动服务 | Root |
| `pd --log <协议>` | 查看日志 | 普通用户 |
| `pd --doctor [--json]` | 只读诊断 | 建议 Root |
| `pd --export` | 导出配置到 `/opt/pd/export.conf` | Root |
| `pd --bbr` / `pd --bbrv3` | 启用 BBR / 安装 BBRv3 内核 | Root |
| `pd --remove-all --yes` | 删除可确认由脚本管理的资源 | Root |

> `pd --upgrade` 更新代理程序；`pd --update` 更新管理脚本，两者用途不同。

端口转发目前通过 Root 交互菜单管理：运行 `sudo pd`，选择“端口转发”。

## 部署示例

### Snell + ShadowTLS

```bash
sudo env PD_SNELL_MODE=shadowtls \
  PD_SNELL_MAJOR=6 \
  PD_SNELL_TLS_VERSION=v3 \
  PD_SNELL_TLS_SNI=www.microsoft.com \
  pd --install snell
```

已经安装 Snell 后，可运行 `sudo pd`，依次进入“协议管理 → Snell → Snell 深入管理”启用、修改或关闭 ShadowTLS。切换时保留 Snell 版本、PSK 和二进制；验证失败会回滚原模式。

Snell v6 的 Surge 配置会按服务端模式输出 `mode=unshaped` 或 `mode=unsafe-raw`；启用 ShadowTLS 时自动使用 `unsafe-raw`，关闭后恢复切换前模式。

### Hysteria2 端口跳跃

```bash
sudo env PD_HY2_HOP=5 pd --install hy2
# 或指定完整范围
sudo env PD_HY2_HOP_RANGE=30000-30100 pd --install hy2
```

### VLESS Reality

```bash
sudo env PD_VLESS_DEST=addons.mozilla.org:443 \
  PD_VLESS_SNI=addons.mozilla.org \
  pd --install vless
```

### IPv4、IPv6 与双栈

```bash
sudo env PD_LISTEN_FAMILY=ipv4 pd --install snell
sudo env PD_LISTEN_FAMILY=ipv6 pd --install snell
sudo env PD_LISTEN_FAMILY=dual pd --install snell
```

支持值：`auto`、`ipv4`、`ipv6`、`dual`。双栈模式启动后必须验证两个地址族，否则回滚。

> [!NOTE]
> Snell v4/v5 普通模式受上游服务端能力限制，仅使用 IPv4 监听；Snell v6 以及 ShadowTLS 公网前端可按实际网络能力使用双栈。脚本不会为未验证成功的地址族输出客户端配置。

## IPv4 单端口转发

适用于把中转服务器 A 的一个公网入口端口转发到目标服务器 B 的固定 IPv4 与服务端口：

```text
客户端 → A公网IPv4:入口端口 → B固定IPv4:目标端口
```

只需在中转服务器 A 安装并运行 PD-proxy；B 只需运行实际服务，并允许来自 A 的访问。运行：

```bash
sudo pd
# 选择：端口转发
```

菜单支持：

- 添加、查看和修改规则；
- 启用、停用和删除单条规则；
- 检查并修复运行态；
- 删除全部由 PD-proxy 管理的转发资源。

当前版本边界：

- 仅支持固定目标 IPv4，不支持域名、IPv6、端口段、多目标负载均衡或故障切换；
- 每条规则使用单个入口端口和单个目标端口，协议可选 TCP、UDP 或 TCP+UDP；
- 入口端口不得与已安装代理协议或其他端口转发规则冲突；停用规则仍保留该入口端口；
- 默认使用 MASQUERADE，目标服务器 B 通常看到的是中转服务器 A 的地址，而不是客户端真实源地址；
- 脚本不会自动修改云厂商安全组；需自行放行 A 的入口端口，并确保 B 允许 A 访问目标端口。

运行态使用独立资源：

- nftables：`table ip pd_port_forward`；
- iptables：`PD_PORT_FORWARD` 链，用于兼容 FORWARD 策略；
- systemd：`pd-port-forward.service`，开机自动恢复已启用规则；
- sysctl：`/etc/sysctl.d/99-pd-port-forward.conf`，持久化 IPv4 转发；
- 状态与生成文件：`/opt/pd/forward/`。

脚本只覆盖和删除带有 PD-proxy 所有权标记的对象，不覆盖 Docker、UFW 或用户已有防火墙资源。删除最后一条规则会清理自有 nftables、iptables、systemd 与持久化文件；为避免影响其他服务，移除持久化文件时不会擅自关闭当前运行中的 `ip_forward`。

## 旧版无中断更新

v3.7.x / v3.8.x / v3.9.x 已安装节点不需要重装协议。只替换管理脚本即可：

```bash
bash -n ./install.sh
sudo cp -a /opt/pd/install.sh "/opt/pd/install.sh.bak.$(date +%Y%m%d-%H%M%S)"
sudo install -o root -g root -m 0755 ./install.sh /opt/pd/.install.sh.new
sudo mv -f /opt/pd/.install.sh.new /opt/pd/install.sh

pd --version
sudo pd --doctor
```

该流程不会重启协议、修改端口、密码、配置或防火墙。旧状态可能出现 `snell.family`、`snell.firewall` 等警告，这不代表代理服务已经故障。

## 故障诊断

```bash
sudo pd --doctor
sudo pd --doctor --json
```

Doctor 会检查：

- 系统、架构和 systemd；
- 协议状态、目录、二进制和 unit；
- 服务、端口、TCP / UDP 与 IPv4 / IPv6 监听；
- ShadowTLS 双层、Hysteria2 hop 和防火墙；
- 公网地址与 BBR 状态。

存在确认故障时返回非零；无法安全判断的项目显示为 `warn`。

## BBR 与 BBRv3

```bash
sudo pd --bbr
sudo pd --bbrv3
```

- BBR 配置写入 `/etc/sysctl.d/99-pdproxy.conf`，不会改写 `/etc/sysctl.conf`。
- BBRv3 使用 XanMod 内核，安装成功后通常需要重启。
- OpenVZ / LXC 等受限容器可能不支持更换内核。

<details>
<summary><strong>常用环境变量</strong></summary>

| 变量 | 用途 |
|---|---|
| `PD_SNELL_MAJOR=4/5/6` | 选择 Snell 大版本，默认 v5 |
| `PD_SNELL_MODE=shadowtls` | 安装 Snell 时同时启用 ShadowTLS |
| `PD_SNELL_TLS_VERSION=v2/v3` | ShadowTLS 版本 |
| `PD_SNELL_TLS_SNI=host` | ShadowTLS 握手 SNI |
| `PD_SNELL_V6_MODE=default/unshaped` | Snell v6 服务端模式 |
| `PD_SNELL_VERSION=vX.Y.Z` | 固定所选大版本的具体 Snell 版本 |
| `PD_SNELL_MANUAL_TIMEOUT=6` | 官方发布说明读取超时秒数 |
| `PD_SNELL_PROBE_PARALLEL=12` | 下载源版本探测并发数 |
| `PD_STRICT_LATEST=1` | 官方最新版检测失败时拒绝回退 |
| `PD_HY2_HOP=5` | HY2 连续端口跳跃 |
| `PD_HY2_HOP_RANGE=30000-30100` | 自定义 HY2 跳跃范围 |
| `PD_VLESS_DEST=host:443` | Reality 目标地址 |
| `PD_ANYTLS_SNI=host` | AnyTLS 客户端 SNI |
| `PD_*_PORT=端口` | 指定对应协议端口 |
| `PD_LISTEN_FAMILY=auto/ipv4/ipv6/dual` | 监听地址族 |
| `PD_PUBLIC_HOST=host` | 客户端配置使用的公网域名 |
| `PD_STRICT_CHECKSUM=1` | 缺少所需摘要时拒绝继续 |
| `PD_SCRIPT_SHA256=...` | 固定管理脚本 SHA-256 |
| `PD_BBR_BANDWIDTH=2000` | 指定带宽 Mbps |
| `PD_BBR_REGION=asia/overseas` | BBR 地区策略 |

更多选项请运行 `pd --help`。

</details>

<details>
<summary><strong>安全与卸载边界</strong></summary>

- 状态、导出和凭据文件使用受限权限与原子写入。
- 下载限制为 HTTPS，可启用 SHA-256 严格校验。
- AnyTLS 与 ShadowTLS 上游仍需通过 argv 传递密码；脚本通过 unit 权限和 systemd 沙箱降低暴露范围，但 root 仍可能读取。
- `pd --remove-all` 只删除所有权能够确认的资源；用户原有、旧状态未记录或已被修改的资源会保留。
- XanMod 内核不会自动删除，避免误删当前启动内核。

</details>

## 系统要求

- Debian / Ubuntu
- amd64 / arm64
- Bash 4.0+
- systemd
- 使用端口转发功能时需要 nftables、iptables 与 IPv4 转发能力
- 安装与变更操作需要 Root

主要目录：`/opt/pd/`、`/opt/pd/forward/`、`/opt/snell/`、`/opt/hysteria2/`、`/opt/xray/`、`/opt/anytls/`。
