# PD-proxy

面向 Surge / Shadowrocket 的 Debian、Ubuntu 多协议部署脚本，支持 Snell、Hysteria2、VLESS Reality 和 AnyTLS。

脚本是单个 Bash 文件，但不是“零依赖”：安装过程会按协议使用或安装 `curl`、CA 证书、OpenSSL、`iproute2`、`unzip`，HY2 hop 还需要 nftables；BBR、二维码等功能有额外可选依赖。

## 安装

建议先通过 HTTPS 下载到本地，再运行；交互菜单不能使用 `curl ... | bash`，因为脚本流会占用标准输入。

```bash
curl --proto '=https' --proto-redir '=https' -fsSLo install.sh \
  https://raw.githubusercontent.com/DDIPP1005/PD-proxy/main/install.sh
sudo bash install.sh
```

非交互安装必须同时给出 CLI 动作和协议，不能只设置环境变量：

```bash
sudo env PD_SNELL_MODE=shadowtls PD_LISTEN_FAMILY=dual \
  bash install.sh --install snell

sudo env PD_HY2_HOP=5 PD_HY2_PORT=30000 \
  bash install.sh --install hy2
```

安装后会创建 `pd` 命令。CLI 对未知参数、缺少参数和多余参数立即返回 2，不会落入交互菜单。

## 协议与路径

| 协议 | 服务路径 | 客户端 | 说明 |
|---|---|---|---|
| Snell v5 | `/opt/snell/` | Surge | 标准 Snell |
| Snell v4 + ShadowTLS | `/opt/snell/`、`/opt/shadowtls/` | Surge | ShadowTLS v2/v3 外层 |
| Hysteria2 | `/opt/hysteria2/` | Surge、Shadowrocket | UDP，可选 nftables 端口跳跃 |
| VLESS Reality | `/opt/xray/` | Shadowrocket | TCP Vision + Reality |
| AnyTLS | `/opt/anytls/` | Surge、Shadowrocket | AnyTLS 服务端默认填充 |

内存和磁盘占用取决于上游版本、系统和运行负载，脚本不承诺固定数值或固定部署时长。

## 常用命令

```bash
pd                                  # 交互菜单
pd --install snell                  # 安装
pd --upgrade snell                  # 升级
pd --restart snell                  # 重启
pd --stop snell                     # 停止
pd --start snell                    # 启动
pd --log snell                      # ShadowTLS 模式同时显示两层日志
pd --config snell                   # 单协议配置
pd --config-all                     # 全部配置
pd --status                         # 状态概览
pd --show                           # 配置详情
pd --export                         # 写入 /opt/pd/export.conf（0600）
pd --doctor                         # 只读诊断
pd --doctor --json                  # 机器可读诊断
pd --remove-all --yes               # 删除可确认由本脚本管理的资源
```

README 中的状态文字仅是命令用途说明，不是某台服务器的真实截图或性能证明；请以本机 `pd --status` 和 `pd --doctor` 输出为准。

安装、升级和 Snell 模式切换使用事务。服务必须通过对应 TCP/UDP 及监听地址族验证；ShadowTLS 会验证内外两层，HY2 hop 会验证 unit 和 nft 范围。验证失败时操作返回非零并尝试回滚。

## 公网地址与监听族

自动公网地址探测只使用显式 HTTPS，并把重定向限制为 HTTPS。同一地址族的有效来源如果互相冲突，该族不会用于生成配置。无法得到可用地址时不会输出带“未知”主机的配置。

建议在 NAT、多出口、DNS 入口或自动探测不稳定时显式指定：

```bash
sudo env PD_PUBLIC_HOST=proxy.example.com pd --config snell
sudo env PD_PUBLIC_IPV4=203.0.113.10 PD_PUBLIC_IPV6=2001:db8::10 pd --config-all
```

`PD_LISTEN_FAMILY` 支持：

| 值 | 行为 |
|---|---|
| `auto` | 结合全局 IPv6 和 `net.ipv6.bindv6only` 选择安全默认值 |
| `ipv4` | 请求仅 IPv4 |
| `ipv6` | 请求仅 IPv6；没有全局 IPv6 时失败 |
| `dual` | 请求双栈；启动后必须实测两族，否则回滚 |

配置输出只包含实际验证的地址族。旧状态没有监听族字段时，查看配置会只读检查当前 socket，不会凭“机器存在 IPv6”猜测。

## 下载和更新校验

脚本直接发起的 curl 下载都限制为 HTTPS，重定向也只能到 HTTPS（系统已有的 APT 源协议由管理员配置决定；脚本新增的 XanMod 源使用 HTTPS）。GitHub release 资产会尽可能读取 GitHub release API 提供的官方 SHA-256 digest；上游没有可读取摘要时会明确警告，并继续做 HTTPS、文件大小和 ELF/语法检查。

严格环境可设置：

```bash
export PD_STRICT_CHECKSUM=1          # 没有官方资产摘要就拒绝安装
export PD_SCRIPT_SHA256='替换为从受信渠道取得的64位十六进制摘要'
export PD_XANMOD_KEY_SHA256='替换为从受信渠道取得的64位十六进制摘要'
sudo --preserve-env=PD_STRICT_CHECKSUM,PD_SCRIPT_SHA256 pd --update
```

自定义 `PD_SCRIPT_URL` 必须是 HTTPS，并且必须同时提供 `PD_SCRIPT_SHA256`；否则拒绝更新。这里没有声称不存在的签名或信任链：HTTPS 和同一 release 上的摘要不能替代独立签名。

## 凭据保护与剩余限制

脚本入口设置 `umask 077`。状态、导出、协议私钥/密码文件使用 0600 和原子替换；systemd unit、脚本和二进制使用明确权限。

Snell、HY2 和 Xray 从受限配置文件读取凭据。当前脚本所支持的 AnyTLS 与 ShadowTLS 上游 CLI 仍需要把密码作为 argv 传入，没有使用虚构的“密码文件参数”。因此它们的 unit 使用 0600，并以 systemd `DynamicUser`、`NoNewPrivileges`、只读系统和额外沙箱限制运行。剩余限制是：root 或有权读取 `/proc`/systemd 配置的主体仍可能看到 argv；若上游将来提供凭据文件或 systemd credentials 接口，应优先迁移。

## BBR 与 BBRv3

```bash
pd --bbr
pd --bbrv3
```

BBR 自动测速最多尝试 5 个附近服务器；失败时使用 1000 Mbps 默认值。也可避免交互和测速：

```bash
sudo env PD_BBR_BANDWIDTH=2000 PD_BBR_REGION=overseas pd --bbr
```

脚本只写自己的 `/etc/sysctl.d/99-pdproxy.conf`，不会注释或改写用户的 `/etc/sysctl.conf`。BBR 或 BBRv3 不支持、安装失败、验证失败时返回非零；用户在确认提示中取消返回 0。BBRv3 使用 HTTPS XanMod APT 源，安装内核后通常需要重启。

自动测速若安装 `/usr/local/bin/speedtest`、BBRv3 若创建 `/swapfile`，都会记录所有权和校验信息；已存在的同名用户资源不会覆盖。

## remove-all 的准确范围

`pd --remove-all` 不是“卸载系统里的一切”。它只删除状态中记录且仍能确认所有权的：

- PD-proxy 协议目录、unit、防火墙规则和 HY2 hop 资源；
- `/opt/pd` 状态、脚本、导出和 `/usr/local/bin/pd` 链接；
- 本脚本创建且未被修改的 BBR sysctl、持久化 unit/脚本、MSS rule、speedtest、swap、XanMod 源和 keyring。

用户原有资源、所有权记录缺失的旧资源、内容已变化的资源会保留并报告。XanMod 内核包不会自动删除，因为自动删除当前或启动内核不安全。删除 sysctl 文件也不会猜测安装前的运行时值；参数会保持到重启或管理员重新加载 sysctl。即时应用的 tc fq 同样不会猜测原 qdisc，会保留到重启或管理员调整。历史 `/etc/sysctl.conf.pdproxy.bak` 无法证明所有权时同样保留。

## doctor 检查范围

`pd --doctor` 不申请写锁、不安装依赖、不改配置。非 root 可运行但可能看不到 0600 状态/unit、journal 和 socket 进程归属；完整诊断建议使用 root。它检查：

- OS、架构和 systemd；
- 公网地址的一致性；
- 状态、目录、二进制和 unit 是否一致；
- 服务、端口、TCP/UDP 与 IPv4/IPv6 实际监听；
- 防火墙记录、HY2 hop、ShadowTLS 双层；
- 当前 BBR 状态。

存在失败项时返回非零；警告项用于需要管理员确认但不能安全推断的情况。`--json` 的诊断内容写到 stdout，网络或权限警告可能写到 stderr。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `PD_SNELL_MODE` | `standard` | `shadowtls` 使用 Snell v4 + ShadowTLS |
| `PD_SNELL_VERSION` | 自动探测 | 固定 Snell 版本，如 `v5.2.12` |
| `PD_SNELL_TLS_VERSION` | `v3` | `v2` 或 `v3` |
| `PD_SNELL_TLS_SNI` | `www.microsoft.com` | ShadowTLS SNI |
| `PD_HY2_HOP` | `0` | 端口跳跃数量，支持 3/5 |
| `PD_HY2_HOP_RANGE` | 空 | 自定义连续范围，如 `30000-30100` |
| `PD_VLESS_DEST` | `addons.mozilla.org:443` | Reality 目标 |
| `PD_ANYTLS_SNI` | 空 | 客户端链接使用的 SNI |
| `PD_SNELL_PORT` 等 | 自动 | 各协议显式端口 |
| `PD_LISTEN_FAMILY` | `auto` | `auto/ipv4/ipv6/dual` |
| `PD_PUBLIC_HOST` | 空 | 公网 DNS 名，配置输出优先使用 |
| `PD_PUBLIC_IPV4` | 自动 | 显式公网 IPv4 |
| `PD_PUBLIC_IPV6` | 自动 | 显式公网 IPv6 |
| `PD_STRICT_LATEST` | `0` | Snell 文档不可达时拒绝探测回退 |
| `PD_STRICT_CHECKSUM` | `0` | 缺少官方资产 digest 时失败 |
| `PD_SCRIPT_URL` | 官方 GitHub raw | 自定义时必须是 HTTPS 并固定 SHA-256 |
| `PD_SCRIPT_SHA256` | 空 | 自更新脚本 SHA-256 |
| `PD_XANMOD_KEY_SHA256` | 空 | XanMod archive.key SHA-256；严格模式需要 |
| `PD_BBR_BANDWIDTH` | 交互/1000 | Mbps |
| `PD_BBR_REGION` | 交互/`asia` | `asia` 或 `overseas` |

变量只影响当前进程。普通 shell 可先 `export VAR=value`；通过 `sudo` 时推荐 `sudo env VAR=value pd ...`，或明确使用 `sudo --preserve-env=VAR`，不要假设 sudo 会保留所有 export。

## 系统要求

- Debian / Ubuntu，amd64 或 arm64；
- Bash 4.0+、systemd；安装和变更需要 root，doctor 可非 root 运行但完整检查需要 root；
- KVM/裸金属可使用全部功能；OpenVZ/LXC 通常不能更换内核或使用部分网络能力。
