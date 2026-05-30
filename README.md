# PD-proxy

多协议代理一键部署脚本，专为 Surge / Shadowrocket 用户设计。

数据驱动架构，全独立二进制，零运行时依赖。支持 Snell v5 / Snell v4 (ShadowTLS) / Hysteria2 / VLESS Reality / AnyTLS 四种协议。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DDIPP1005/PD-proxy/main/install.sh)
```

安装后通过 `pd` 命令管理。首次运行进入交互菜单，后续每次自动显示状态面板。

## 协议

| 协议 | 内存 | 磁盘 | Surge | Shadowrocket | 备注 |
|------|------|------|:-----:|:------------:|------|
| Snell v5 | 5MB | 20MB | ✅ | ❌ | Surge 专用，推荐首选 |
| + ShadowTLS | +3MB | +10MB | ✅ | ❌ | Snell v4 TCP + TLS 伪装 |
| Hysteria2 | 18MB | 30MB | ✅ | ✅ | 支持端口跳跃 |
| VLESS Reality | 30MB | 60MB | ❌ | ✅ | 仅 Shadowrocket，Reality 伪装 |
| AnyTLS | 5MB | 20MB | ✅ | ✅ | Surge 官方已支持 |

> Snell v5 QUIC 仅 Surge 可用。VLESS 仅 Shadowrocket 可用。

## 管理命令

```bash
pd                  # 交互菜单（状态面板 + 15 个操作）
```

### CLI 命令（15 个）

```bash
# 安装 / 卸载
pd --install snell        # 安装 Snell v5（默认推荐）
pd --install hy2          # 安装 Hysteria2
pd --install vless        # 安装 VLESS Reality
pd --install anytls       # 安装 AnyTLS
pd --uninstall snell      # 卸载指定协议
pd --uninstall all        # 卸载全部（需确认）
pd --remove-all --yes     # 静默卸载全部

# 服务管理
pd --upgrade snell        # 升级协议二进制（保留配置）
pd --restart snell        # 重启服务
pd --stop snell           # 停止服务
pd --start snell          # 启动已停止的服务

# 查看
pd --status               # 状态一览：端口/运行时间/内存/版本
pd --show                 # 完整配置（含二维码）
pd --config snell         # 仅输出 Surge 配置行（无冗余）
pd --config-all           # 输出所有已安装协议配置行
pd --log snell            # 查看最近 50 行日志
pd --export               # 导出所有配置到 /opt/pd/export.conf

# 系统
pd --bbr                  # 一键开启 BBR 优化
pd --update               # 更新 pd 自身
pd --help                 # 帮助
```

### 交互菜单

二级菜单架构（v2.5.0+）：

```
主菜单: 1)安装 2)管理 3)查看 4)系统 Q)退出
  安装: 1)Snell 2)HY2 3)VLESS 4)AnyTLS
  管理: 1)升级 2)重启 3)停止 4)启动 5)日志 6)卸载
  查看: 1)单协议 2)全部配置 3)导出
  系统: 1)BBR 2)全部卸载
```

## 环境变量

### 端口指定

```bash
PD_SNELL_PORT=12345 pd --install snell
PD_HY2_PORT=12346   pd --install hy2
PD_VLESS_PORT=12347 pd --install vless
PD_ANYTLS_PORT=12348 pd --install anytls
```

### Snell + ShadowTLS

```bash
PD_SNELL_MODE=shadowtls PD_SNELL_TLS_SNI=www.microsoft.com pd --install snell
```

### Hysteria2 端口跳跃

```bash
PD_HY2_HOP=3 pd --install hy2   # 3 端口跳跃
PD_HY2_HOP=5 pd --install hy2   # 5 端口跳跃
```

### VLESS Reality 自定义

```bash
PD_VLESS_DEST=swdist.apple.com:443 PD_VLESS_TRANSPORT=grpc PD_VLESS_FP=ios pd --install vless
```

### AnyTLS 伪装

```bash
PD_ANYTLS_SNI=www.microsoft.com pd --install anytls
```

## 安装路径

| 路径 | 说明 |
|------|------|
| `/opt/pd/` | 脚本和状态文件 |
| `/opt/snell/` | Snell 二进制 + 配置 |
| `/opt/shadowtls/` | ShadowTLS 二进制 |
| `/opt/hysteria/` | Hysteria2 二进制 + 证书 + 配置 |
| `/opt/xray/` | Xray-core 二进制 + 配置 |
| `/opt/anytls/` | AnyTLS 二进制 + 密码 |
| `/usr/local/bin/pd` | pd 命令（→ /opt/pd/install.sh 软链） |

## 架构

- **数据驱动**：协议元数据定义在关联数组中，新增协议只需加一块定义 + 实现 `*_download` / `*_configure` / `*_output` 三个函数
- **统一安装流水线**：所有协议走同一套流程（依赖→端口→密码→版本→下载→配置→systemd→防火墙→验证→保存状态→输出配置）
- **安装失败自动回滚**：停服务 + 删 systemd 单元 + 关防火墙 + 清目录 + 删状态记录
- **并发锁**：flock 防止多个 pd 实例同时操作
- **零外部依赖**：状态管理用纯 bash flat file，不依赖数据库

## 安全

- 凭据文件（`export.conf`）+ 配置文件均 `chmod 600`
- 二维码生成走 stdin，密钥不出现在 `/proc/cmdline`
- 临时文件显式追踪，退出不误删其他进程文件
- 下载的二进制验证 ELF 头 + 最小文件大小
- `iptables-save` 写入前自动备份

## 系统要求

- Debian / Ubuntu（amd64 / arm64）
- bash 4.0+
- root 权限
