# PD-proxy

> 一个 `pd` 命令，部署和管理 Snell、Hysteria2、VLESS Reality、AnyTLS 与独立 IPv4 端口转发。

<p>
  <kbd>v4.2.1</kbd>
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

本版改动与升级注意事项见 [v4.2.1 发布说明](RELEASE_NOTES.md)。

## 交互界面

首页分别展示管理脚本版本、协议服务端版本、端口及运行状态；Snell 与 ShadowTLS 独立显示。状态文字不代表真实代理请求已验收。页面采用逐项布局，适合手机 SSH 和窄窗口；转发列表的“已启用”仅表示规则配置，运行检查结果单独展示。

菜单支持 `B` 返回、`Q` 退出；有默认值的选项可直接回车。无效编号会重新提示，端口、域名和转发字段输错后只重填当前项，保留其他输入。交互操作结束后等待回车，再返回菜单；命令行调用不增加等待。

“更新 PD 管理脚本”对应 `pd --update`；协议菜单中的“升级服务端”对应 `pd --upgrade <协议>`。只读诊断位于“诊断与系统工具 → 只读诊断”。取消、执行失败和回滚结果分别提示；失败后可按提示运行 `pd --doctor`。

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

Surge 使用官方 `port-hopping=` 参数；分享 URI 会携带完整跳跃端口范围。


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

支持值：`auto`、`ipv4`、`ipv6`、`dual`。双栈模式启动后必须分别确认两个地址族，否则回滚。仅看到 IPv6 通配监听（`[::]` / `*`）和全局 `bindv6only=0`，不能证明该服务接受 IPv4；无法确认时双栈操作会失败并回滚。`auto` 只记录已确认的监听族。配置输出会重新检查当前监听，旧状态中的可用标记不能单独作为输出依据。只确认一个地址族时，输出该族的公网 IP；`PD_PUBLIC_HOST` 可能解析到另一个地址族，因此只有两个监听族均确认时才作为连接地址输出，TLS SNI 独立保留。没有匹配的公网 IP 时拒绝输出。

Surge 配置行的主机与端口是独立字段，IPv6 地址不带方括号；Shadowrocket 分享 URI 和二维码中的 IPv6 地址仍保留方括号。例如配置行使用 `2001:db8::42, 443`，URI 使用 `[2001:db8::42]:443`。安装完成后的输出、`--config`、`--config-all` 和导出采用相同格式。

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

管理入口和 systemd 实际执行脚本均会在修改前复核转发目录、nft 表内规则及 iptables 链和引用的所有权。发现无标记规则、外来引用、无法识别的规则结构或查询失败时拒绝修改。脚本只覆盖和删除带有 PD-proxy 所有权标记的对象，不覆盖 Docker、UFW 或用户已有防火墙资源。删除最后一条规则会清理自有 nftables、iptables、systemd 与持久化文件；为避免影响其他服务，移除持久化文件时不会擅自关闭当前运行中的 `ip_forward`。

> `pd --update` 仍只替换管理脚本，不重写现有转发执行脚本、不重启服务。已有转发需在单独批准的维护操作中，通过“端口转发 → 检查并修复规则”重新生成执行脚本后，systemd 路径才获得本次保护；该操作会重新加载转发规则。

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

存在确认故障时返回非零；无法安全判断的项目显示为 `warn`。Doctor 会明确标注真实客户端验收尚未执行；退出码为零或 JSON 的 `ok=true` 只说明没有发现确认故障，不代表代理请求可用。

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


## AnyTLS 稳定模式：sing-box 后端

AnyTLS 默认后端已改为 `sing-box`，适合 Surge 长期使用；旧的 `anytls-go` 参考实现保留为 legacy/快速测试模式。

### 推荐安装

```bash
sudo env \
  PD_ANYTLS_BACKEND=sing-box \
  PD_ANYTLS_DOMAIN=node.example.com \
  PD_PUBLIC_HOST=node.example.com \
  PD_ANYTLS_PORT=443 \
  PD_ANYTLS_CERT_MODE=auto \
  bash install.sh --install anytls
```

要求：

- `node.example.com` 已经 A/AAAA 解析到当前 VPS；
- Cloudflare 使用 DNS only，不要橙云代理；
- `80/TCP` 可临时用于 Let's Encrypt standalone 申请证书；
- `443/TCP` 用于 AnyTLS 服务。

### 使用已有证书

```bash
sudo env \
  PD_ANYTLS_BACKEND=sing-box \
  PD_ANYTLS_DOMAIN=node.example.com \
  PD_ANYTLS_CERT_MODE=existing \
  PD_ANYTLS_CERT_PATH=/etc/letsencrypt/live/node.example.com/fullchain.pem \
  PD_ANYTLS_KEY_PATH=/etc/letsencrypt/live/node.example.com/privkey.pem \
  PD_ANYTLS_PORT=443 \
  bash install.sh --install anytls
```

### 保留旧 anytls-go 模式

```bash
sudo env PD_ANYTLS_BACKEND=anytls-go bash install.sh --install anytls
```

### 新增环境变量

| 变量 | 默认值 | 说明 |
|---|---:|---|
| `PD_ANYTLS_BACKEND` | `sing-box` | `sing-box` 稳定模式；`anytls-go` legacy 模式 |
| `PD_ANYTLS_DOMAIN` | `PD_PUBLIC_HOST` | AnyTLS 证书域名与默认输出地址 |
| `PD_ANYTLS_CERT_MODE` | `auto` | `auto` / `existing` / `acme` / `self-signed` |
| `PD_ANYTLS_CERT_PATH` | 空 | 现有证书 fullchain 路径 |
| `PD_ANYTLS_KEY_PATH` | 空 | 现有私钥路径 |
| `PD_ANYTLS_SNI` | 域名 | Surge/客户端 SNI |
| `PD_ANYTLS_REUSE` | `auto` | `auto` / `true` / `false` |
| `PD_ANYTLS_PADDING` | `standard` | `standard` 默认；`none` 关闭 sing-box padding_scheme |
| `PD_ANYTLS_SINGBOX_VERSION` | 空 | 固定 sing-box 版本，例如 `v1.13.14` |


## 真实客户端验收

安装、启动、升级的服务及监听检查不能代替真实代理验收。仓库提供独立的 `tests/accept-proxy.sh`，由操作者在已授权的客户端环境中手动执行，不会被安装、更新或回归测试自动调用。

1. 使用支持待验协议的真实客户端，将一个本机 SOCKS5 入口固定到单个待验节点。关闭 DIRECT 回退、自动切换和会绕过该节点的分流规则；Snell + ShadowTLS 必须启用与服务端匹配的两层配置。
2. 准备一个你控制的 HTTPS 静态测试地址，以及事先通过可信渠道确定的响应正文 SHA-256。不要使用会动态变化的页面，不要把凭据放入 URL。
3. 在客户端执行（替换入口端口、测试地址和摘要）：

```bash
bash tests/accept-proxy.sh socks5h://127.0.0.1:1080 \
  https://probe.example.com/check.txt '替换为响应正文的64位SHA256'
```

工具强制使用指定 SOCKS 入口，禁用 curlrc 和 NO_PROXY 绕过，验证目标 HTTPS 证书，不跟随重定向。三次独立请求均须返回 HTTP 200 且正文摘要匹配；输出真实通过/失败数，任一次失败即返回非零。正文只保存在私有临时目录，退出时删除，不输出响应内容或客户端凭据。

双栈验收须将客户端的**代理服务器地址**分别固定为 VPS 的 IPv4 和 IPv6，各跑一轮；改变目标网站的地址族不能证明 VPS 的两个入口都可用。记录客户端版本、协议/模式、入口地址族和每轮结果。脚本只能证明请求经过指定 SOCKS 入口，不能自动证明客户端没有使用 DIRECT 或其他节点；验收前必须核对客户端路由，并通过客户端连接记录确认选中的节点。

本工具验证 HTTPS 代理请求，不替代 HY2 跳跃端口、UDP 业务或长连接稳定性专项测试。真实 VPS 操作必须另行明确机器、影响范围、回滚方法和验证方法并获得批准。
