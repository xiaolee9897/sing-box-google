# sing-box-google

一个面向 **Debian / Ubuntu VPS** 的五节点一键部署脚本。

当前 `main` 已按真实 VPS + Cloudflare Tunnel + WARP + FlClash 环境完成五节点联调验证。

## 已验证的五节点结构

1. **VLESS-Reality-Vision** → VPS 直连出口
2. **Hysteria2 + Salamander** → VPS 直连出口
3. **AnyTLS** → VPS 直连出口
4. **VLESS-CF-WS** → Cloudflare Tunnel → `127.0.0.1:8080` → VPS 直连出口
5. **VLESS-CF-WARP** → Cloudflare Tunnel → `127.0.0.1:8081` → Cloudflare WARP 出口

WARP 是出站网络。第五个 FlClash 节点是独立 VLESS-WS 入站，由 sing-box 路由规则单独送往 WARP；其它四个节点保持 direct。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xiaolee9897/sing-box-google/main/sb.sh)
```

安装后提供：

```bash
sb status
sb show
sb restart
sb logs
sb uninstall
```

## 推荐：Named Tunnel + 两个 Public Hostname

在 Cloudflare Zero Trust 中只需要创建 **一个 Tunnel**，然后在同一个 Tunnel 中添加两个 Public Hostname：

| Public Hostname | Service |
|---|---|
| `vless.example.com` | `http://localhost:8080` |
| `gwarp.example.com` | `http://localhost:8081` |

安装：

```bash
CF_TUNNEL_TOKEN='你的 Tunnel Token' \
CF_HOST='vless.example.com' \
WARP_CF_HOST='gwarp.example.com' \
bash <(curl -fsSL https://raw.githubusercontent.com/xiaolee9897/sing-box-google/main/sb.sh)
```

Tunnel Token 是敏感凭据，不要上传仓库或粘贴到公开位置。

## 默认端口与路径

| 节点 | 默认值 |
|---|---|
| VLESS-Reality | TCP `443` |
| Hysteria2 | UDP `8443` |
| AnyTLS | TCP `9443` |
| VLESS-CF-WS 回源 | `127.0.0.1:8080`，路径 `/vless` |
| VLESS-CF-WARP 回源 | `127.0.0.1:8081`，路径 `/warp` |

`8080` / `8081` 只绑定 localhost，不需要开放到公网。

默认云安全组只需按实际需要开放：

```text
TCP 443
UDP 8443
TCP 9443
```

## 可覆盖环境变量

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
PRESERVE_CREDENTIALS
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

Cloudflare Dashboard 中的两个 Service 端口必须与 `WS_PORT` / `WARP_WS_PORT` 一致。

## 重装时默认保留节点凭据

默认：

```text
PRESERVE_CREDENTIALS=true
```

如果 `/etc/singbox-google/state.env` 已存在并包含完整凭据，重装会复用：

- Reality UUID / key / short-id
- Hysteria2 password / obfs password
- AnyTLS password
- 普通 CF-WS UUID
- CF-WARP UUID

这样普通升级脚本后重新安装，不需要重新修改客户端节点。

如果明确希望重新生成全部代理凭据：

```bash
PRESERVE_CREDENTIALS=false \
CF_TUNNEL_TOKEN='你的 Token' \
CF_HOST='vless.example.com' \
WARP_CF_HOST='gwarp.example.com' \
bash <(curl -fsSL https://raw.githubusercontent.com/xiaolee9897/sing-box-google/main/sb.sh)
```

## WARP 行为

默认：

```text
WARP_MODE=on
```

脚本使用 `wgcf` 注册或复用 WARP 账户，生成 WireGuard profile，再转换为 sing-box WireGuard Endpoint。

路由固定为：

```text
Reality       -> direct
Hysteria2     -> direct
AnyTLS        -> direct
VLESS-CF-WS   -> direct
VLESS-CF-WARP -> warp
```

WARP profile 的 Base64 PrivateKey/PublicKey 使用不会破坏尾部 `=` 的解析方式，并执行长度校验。

如果 WARP 注册或解析失败，前四节点仍继续安装，第五节点不会写入 FlClash。

关闭 WARP：

```bash
WARP_MODE=off bash <(curl -fsSL https://raw.githubusercontent.com/xiaolee9897/sing-box-google/main/sb.sh)
```

## Quick Tunnel

没有提供 `CF_TUNNEL_TOKEN` 时，脚本仍可为普通 `VLESS-CF-WS` 建立 Quick Tunnel。

Quick Tunnel 只能映射一个本地 URL，因此无法同时提供完整的 `8080 + 8081` 双入口。完整五节点结构应使用 Named Tunnel。

## 完整 FlClash / Mihomo YAML

生成路径：

```text
/etc/singbox-google/flclash.yaml
```

`sb show` 会刷新并输出完整 YAML。

固定 Tunnel + WARP 正常时包含五节点：

```text
VLESS-Reality
Hysteria2
AnyTLS
VLESS-CF-WS
VLESS-CF-WARP
```

同时包含：

- `Proxy` 手动选择组
- `Auto` URL-Test 自动测速组
- Fake-IP DNS
- DoH nameserver
- proxy-server DNS
- HTTP / TLS / QUIC sniffer
- `MATCH,Proxy` 默认规则

YAML 中包含真实 UUID、密码和节点信息，请勿提交到公开仓库。

## 服务与文件

服务：

```text
singbox-google.service
cloudflared-singbox-google.service
```

文件：

```text
/etc/singbox-google/config.json
/etc/singbox-google/state.env
/etc/singbox-google/flclash.yaml
/etc/singbox-google/server.crt
/etc/singbox-google/server.key
/etc/singbox-google/run-cloudflared.sh
/etc/singbox-google/warp/
```

## 默认版本

```text
sing-box     1.13.14
cloudflared  2026.7.1
wgcf         2.2.32
```

均可通过环境变量覆盖。

## 安全与范围

- Debian / Ubuntu
- amd64 / arm64
- systemd
- 不执行 `iptables -F`
- 不关闭 UFW / firewalld
- `8080` / `8081` 只绑定 `127.0.0.1`
- UUID、密码、Reality 私钥、WARP 私钥、Tunnel Token 只保存在 VPS 本地
- 不包含 Serv00 / Hostuno、VMess、TUIC、网页保活及仓库内置大体积代理二进制

仅用于合法的网络连接、隐私保护、测试与学习。使用者应遵守所在地法律法规及云服务商、Cloudflare 的服务条款。
