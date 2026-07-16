# PD-proxy

> 一个 `pd` 命令，部署和管理 Snell、Hysteria2、VLESS Reality 与 AnyTLS。

<p>
  <kbd>v3.8.0</kbd>
  <kbd>Debian / Ubuntu</kbd>
  <kbd>amd64 / arm64</kbd>
  <kbd>Surge / Shadowrocket</kbd>
</p>

[快速开始](#快速开始) · [支持协议](#支持协议) · [常用命令](#常用命令) · [部署示例](#部署示例) · [旧版更新](#旧版无中断更新) · [故障诊断](#故障诊断)

---

## 主要特点

- **统一管理**：交互菜单与完整 CLI，安装、升级、启停、日志、配置集中处理。
- **失败回滚**：安装、升级和 Snell 模式切换采用事务流程，验证失败自动尝试恢复。
- **双栈支持**：支持 IPv4、IPv6 和双栈，只输出实际验证可用的地址。
- **安全更新**：HTTPS 下载、可选 SHA-256 严格校验、原子写入和资源所有权保护。
- **一键诊断**：`pd --doctor` 检查服务、端口、监听族、防火墙和 BBR。

## 支持协议

| 协议 | 标识 | 传输 | 客户端 | 说明 |
|---|---|---|---|---|
| Snell v5 | `snell` | TCP | Surge | 默认模式 |
| Snell v4 + ShadowTLS | `snell` | TCP | Surge | ShadowTLS v2 / v3 |
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

## 部署示例

### Snell + ShadowTLS

```bash
sudo env PD_SNELL_MODE=shadowtls \
  PD_SNELL_TLS_VERSION=v3 \
  PD_SNELL_TLS_SNI=www.microsoft.com \
  pd --install snell
```

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

## 旧版无中断更新

v3.7.x 已安装节点不需要重装协议。只替换管理脚本即可：

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
| `PD_SNELL_MODE=shadowtls` | Snell v4 + ShadowTLS |
| `PD_SNELL_TLS_VERSION=v2/v3` | ShadowTLS 版本 |
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
- 安装与变更操作需要 Root

主要目录：`/opt/pd/`、`/opt/snell/`、`/opt/hysteria2/`、`/opt/xray/`、`/opt/anytls/`。
