# sing-box-google

一个面向 **Debian / Ubuntu VPS** 的精简一键部署脚本。

## 五节点结构

1. **VLESS-Reality-Vision** → VPS 直连出口
2. **Hysteria2 + Salamander** → VPS 直连出口
3. **AnyTLS** → VPS 直连出口
4. **VLESS-CF-WS** → Cloudflare Tunnel → `127.0.0.1:8080` → VPS 直连出口
5. **VLESS-CF-WARP** → Cloudflare Tunnel → `127.0.0.1:8081` → Cloudflare WARP 出口

WARP 本身仍然是出站网络，不是公网入站协议；第五个 FlClash 节点是一个独立的 VLESS-WS 入口，并由 sing-box 路由规则单独送入 WARP。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xiaolee9897/sing-box-google/main/sb.sh)
```

安装后：

```bash
sb status
sb show
sb restart
sb logs
sb uninstall
```

## 推荐：固定 Cloudflare Tunnel

在 Cloudflare Zero Trust 中只需要一个 Tunnel，但添加两个 Public Hostname：

| Public Hostname | Service |
|---|---|
| `vless.example.com` | `http://localhost:8080` |
| `gwarp.example.com` | `http://localhost:8081` |

然后一键安装：

```bash
CF_TUNNEL_TOKEN='你的 Tunnel Token' \
CF_HOST='vless.example.com' \
WARP_CF_HOST='gwarp.example.com' \
bash <(curl -fsSL https://raw.githubusercontent.com/xiaolee9897/sing-box-google/main/sb.sh)
```

Tunnel Token 属于敏感凭据，不要上传或粘贴到公开位置。

## 默认端口与路径

| 节点 | 默认值 |
|---|---|
| VLESS-Reality | TCP `443` |
| Hysteria2 | UDP `8443` |
| AnyTLS | TCP `9443` |
| VLESS-CF-WS 回源 | `127.0.0.1:8080`，路径 `/vless` |
| VLESS-CF-WARP 回源 | `127.0.0.1:8081`，路径 `/warp` |

8080/8081 仅监听 localhost，不需要在云防火墙开放。

云安全组只需按实际使用开放公网协议端口，例如默认：

```text
TCP 443
UDP 8443
TCP 9443
```

## 可修改环境变量

所有主要参数都可以在一键命令前覆盖：

```text
REALITY_PORT
HY2_PORT
ANYTLS_PORT
WS_PORT
WARP_WS_PORT
WS_PATH
WARP_WS_PATH
REALITY_SNI
TLS_SNI
WARP_MODE
CF_TUNNEL_TOKEN
CF_HOST
WARP_CF_HOST
SERVER_ADDR
SING_BOX_VERSION
CLOUDFLARED_VERSION
WGCF_VERSION
```

例如：

```bash
WS_PORT=18080 \
WARP_WS_PORT=18081 \
WS_PATH='/cf' \
WARP_WS_PATH='/warp' \
CF_TUNNEL_TOKEN='你的 Token' \
CF_HOST='vless.example.com' \
WARP_CF_HOST='gwarp.example.com' \
bash <(curl -fsSL https://raw.githubusercontent.com/xiaolee9897/sing-box-google/main/sb.sh)
```

Cloudflare Dashboard 中的两个 Service 端口必须和 `WS_PORT` / `WARP_WS_PORT` 一致。

## WARP 行为

默认：

```text
WARP_MODE=on
```

脚本会下载 `wgcf`，注册或读取 WARP 账户，生成 WireGuard profile，并转换为 sing-box 1.13+ WireGuard Endpoint。

路由策略是：

```text
Reality       -> direct
Hysteria2     -> direct
AnyTLS        -> direct
VLESS-CF-WS   -> direct
VLESS-CF-WARP -> warp
```

如果 WARP 注册失败，前四个节点仍继续安装，第五个 WARP 节点不会写入 FlClash。

若明确不需要 WARP：

```bash
WARP_MODE=off bash <(curl -fsSL https://raw.githubusercontent.com/xiaolee9897/sing-box-google/main/sb.sh)
```

## Quick Tunnel

未提供 `CF_TUNNEL_TOKEN` 时，脚本仍可以为普通 VLESS-CF-WS 创建 Quick Tunnel。

但 Quick Tunnel 只能自动映射一个本地 URL，因此**不能同时提供 8080 和 8081 两个固定入口**。要使用完整五节点结构，请使用 Named Tunnel + 两个 Public Hostname。

## FlClash

生成位置：

```text
/etc/singbox-google/flclash.yaml
```

完整固定 Tunnel + WARP 成功时包含：

```text
VLESS-Reality
Hysteria2
AnyTLS
VLESS-CF-WS
VLESS-CF-WARP
```

以及 `Proxy` 手动选择组和 `Auto` 自动测速组。

运行：

```bash
sb show
```

即可刷新并输出完整配置。

## 默认版本

```text
sing-box     1.13.14
cloudflared  2026.7.1
wgcf         2.2.32
```

均可通过环境变量覆盖。

## 安全与范围

- 仅支持 Debian / Ubuntu、amd64 / arm64、systemd VPS
- 不再包含 Serv00 / Hostuno、VMess、TUIC、网页保活、大体积预编译二进制
- 不执行 `iptables -F`
- 不自动关闭 UFW / firewalld
- UUID、密码、Reality 私钥、WARP 私钥和 Tunnel Token 仅保存在 VPS 本地 `/etc/singbox-google`
- `8080` / `8081` 仅绑定 `127.0.0.1`

仅用于合法的网络连接、隐私保护、测试与学习。使用者应遵守所在地法律法规以及云服务商和 Cloudflare 的服务条款。
