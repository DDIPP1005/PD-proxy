# PD-proxy

多协议代理一键部署脚本，专为 Surge / Shadowrocket 用户设计。

## 协议

| 协议 | 内存 | Surge | Shadowrocket |
|------|------|:-----:|:------------:|
| Snell v5 | 5MB | ✅ | ✅ |
| Hysteria2 | 20MB | ✅ | ✅ |
| VLESS Reality | 30MB | ❌ | ✅ |
| AnyTLS (beta) | 5MB | ⚠️ | ✅ |

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DDIPP1005/PD-proxy/main/install.sh)
```

## 管理

```bash
pd              # 管理菜单
pd --status     # 状态一览
pd --remove snell   # 卸载某协议
pd --remove-all     # 全部卸载
```

## 系统要求

- Debian / Ubuntu
- root 权限
