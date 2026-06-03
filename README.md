# PD-proxy

多协议代理一键部署脚本，专为 Surge / Shadowrocket 用户设计。

**3469 行纯 Bash，零运行时依赖。** 一条命令，五分钟内从空白 VPS 到全协议跑通。

---

## 为什么选 PD-proxy

- **一条命令部署五种协议** — 不用分别找 Snell、Hysteria2、Xray 的安装教程
- **Surge 配置直达** — `pd --config snell` 输出可直接粘贴进 Surge，含 ShadowTLS 版本、端口范围等完整参数
- **安装即优化** — 内置 BBR 全参数调优（22+ 项内核参数 + 交互测速 + fq 持久化），装完协议即可跑满带宽
- **防御式设计** — 安装失败自动回滚，不留残留文件，不污染系统配置
- **智能版本管理** — Snell 双 KB 源自动探测最新版，XanMod 按 CPU flags 选最优包，pd 更新防回退

---

## 安装

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/DDIPP1005/PD-proxy/main/install.sh)"
```

安装后自动生成 `pd` 命令，直接进入交互菜单。支持通过环境变量一键非交互部署：

```bash
PD_SNELL_MODE=shadowtls PD_HY2_HOP=5 bash -c "$(curl -fsSL ...)"
```

---

## 协议支持

| 协议 | 内存 | 磁盘 | Surge | Shadowrocket | 说明 |
|------|:----:|:----:|:-----:|:------------:|------|
| **Snell v5** | 5MB | 20MB | ✅ | ❌ | QUIC 传输，推荐首选 |
| Snell + ShadowTLS | +3MB | +10MB | ✅ | ❌ | v4 TCP + TLS 伪装，支持 v2/v3 |
| **Hysteria2** | 18MB | 30MB | ✅ | ✅ | 端口跳跃 / 端口范围，双端通用 |
| VLESS Reality | 30MB | 60MB | ❌ | ✅ | Xray 核心，Reality 伪装 |
| **AnyTLS** | 5MB | 20MB | ✅ | ✅ | 轻量 TLS 隧道，双端通用 |

---

## 使用方式

### 交互菜单

```bash
pd          # 进入主菜单
```

```
══════  PD-proxy v3.7.4  ══════
  Snell v5    安装 📦  运行中 (5.2.3)  端口: 12345 14MB
  Hysteria2   未安装
  VLESS       未安装
  AnyTLS      未安装
══════════════════════════════

  [1] 安装协议    [2] 管理协议
  [3] 查看配置    [4] 系统工具
  [Q] 退出
```

安装子菜单支持自定义端口（自动分配 / 手动指定），Snell 安装支持 ShadowTLS 版本选择（v2 / v3）。

### CLI 常用命令

```bash
# 安装
pd --install snell                 # Snell v5
PD_SNELL_MODE=shadowtls pd --install snell   # Snell v4 + ShadowTLS
pd --install hy2                   # Hysteria2
pd --install vless                 # VLESS Reality
pd --install anytls                # AnyTLS

# 查看
pd --status                        # 状态概览
pd --show                          # 完整配置 + 二维码
pd --config snell                  # 仅 Surge 配置行（最常用）
pd --config-all                    # 所有协议配置行

# 管理
pd --restart snell                 # 重启
pd --log snell                     # 日志
pd --upgrade snell                 # 升级二进制
pd --remove-all --yes              # 卸载一切
```

---

## BBR 优化

PD-proxy 内置 TCP 优化引擎，一键开启 22+ 项内核参数调优。

```bash
pd --bbr                           # 进入交互引导（测速→地区→缓冲），或秒开
```

**交互引导流程**：① 自动/手动 speedtest 测速（10 个附近服务器重试）→ ② 选择服务地区（亚太/欧美）→ ③ 自动计算最优 TCP 缓冲区 → ④ 写入 `/etc/sysctl.d/99-pdproxy.conf` → ⑤ 即时生效 + systemd 开机持久化。

**调优参数覆盖**：拥塞控制（BBR + fq）、TCP 缓冲区（按带宽+地区分档计算）、连接复用、TCP Fast Open、UDP 缓冲（Hysteria2/QUIC）、Keepalive、TIME_WAIT 回收、虚拟内存调度、MSS 防分片、tc fq + iptables 开机持久化。

支持环境变量跳过交互，直接指定带宽策略：

```bash
PD_BBR_BANDWIDTH=2000 PD_BBR_REGION=overseas pd --bbr   # 2Gbps 欧美节点
```

另可独立安装 XanMod BBRv3 内核（需重启，安装前预检磁盘空间）：

```bash
pd --bbrv3                         # CPU flags 自动选 v1/v2/v3 包
```

---

## 环境变量

所有变量均可在一键安装命令中前置传入。

### 协议选择
| 变量 | 默认 | 说明 |
|------|------|------|
| `PD_SNELL_MODE` | `standard` | `shadowtls` = Snell v4 + TLS 伪装 |
| `PD_SNELL_VERSION` | 自动探测 | 锁定 Snell 版本，如 `v5.2.12` |
| `PD_SNELL_TLS_VERSION` | `v3` | ShadowTLS 协议版本：`v3` 或 `v2` |
| `PD_SNELL_TLS_SNI` | `www.microsoft.com` | ShadowTLS 伪装 SNI |
| `PD_HY2_HOP` | `0` | Hysteria2 端口跳跃数（3/5） |
| `PD_HY2_HOP_RANGE` | 自动分配 | 端口跳跃范围，如 `30000-30100` |
| `PD_VLESS_DEST` | `addons.mozilla.org:443` | Reality 伪装目标 |
| `PD_ANYTLS_SNI` | 空 | AnyTLS 伪装 SNI |

### 端口指定
| 变量 | 默认 | 说明 |
|------|------|------|
| `PD_SNELL_PORT` | 自动分配 | Snell 监听端口 |
| `PD_HY2_PORT` | 自动分配 | Hysteria2 监听端口 |
| `PD_VLESS_PORT` | 自动分配 | VLESS 监听端口 |
| `PD_ANYTLS_PORT` | 自动分配 | AnyTLS 监听端口 |

### Snell 版本探测
| 变量 | 默认 | 说明 |
|------|------|------|
| `PD_SNELL_MANUAL_TIMEOUT` | `6` | Surge KB/手册抓取超时秒数（2–15） |
| `PD_SNELL_PROBE_PARALLEL` | `12` | 版本探测并发请求数（2–32） |
| `PD_STRICT_LATEST` | `0` | `1`=KB 不可达时拒绝安装 |

### BBR 调优
| 变量 | 默认 | 说明 |
|------|------|------|
| `PD_BBR_BANDWIDTH` | 交互测速 | 上传带宽 Mbps，影响 TCP 缓冲大小 |
| `PD_BBR_REGION` | 交互选择 | `overseas`=欧美高延迟大缓冲 |
| `PD_XANMOD_PACKAGE` | 自动检测 | XanMod 内核包名（v1/v2/v3） |

### 其他
| 变量 | 默认 | 说明 |
|------|------|------|
| `PD_SCRIPT_URL` | GitHub raw | 脚本下载地址，自建镜像可覆盖 |

---

## 安装路径

| 路径 | 内容 |
|------|------|
| `/opt/pd/` | 脚本 + 状态文件 |
| `/usr/local/bin/pd` | pd 命令（→ `/opt/pd/install.sh`） |
| `/opt/snell/` | Snell 二进制 + 配置 |
| `/opt/shadowtls/` | ShadowTLS 二进制 |
| `/opt/hysteria/` | Hysteria2 二进制 + 证书 + 配置 |
| `/opt/xray/` | Xray-core 二进制 + 配置 |
| `/opt/anytls/` | AnyTLS 二进制 + 密码 |
| `/etc/sysctl.d/99-pdproxy.conf` | BBR 内核参数 |
| `/usr/local/bin/pd-bbr-apply.sh` | BBR 开机恢复脚本 |
| `/etc/systemd/system/pd-bbr-apply.service` | BBR 持久化服务 |

---

## 系统要求

- **系统**：Debian / Ubuntu（amd64 / arm64）
- **Shell**：bash 4.0+
- **权限**：root
- **虚拟化**：KVM / 裸金属（OpenVZ / LXC 部分功能受限）
