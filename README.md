# sing-box-google

一个面向 **Debian / Ubuntu VPS** 的可选协议一键部署脚本。

当前 `main` 支持三种安装模式：

1. **一键五协议**
   - VLESS-Reality-Vision → direct
   - Hysteria2 + Salamander → direct
   - AnyTLS → direct
   - VLESS-CF-WS → Cloudflare Tunnel → `127.0.0.1:8080` → direct
   - VLESS-CF-WARP → Cloudflare Tunnel → `127.0.0.1:8081` → WARP
2. **一键三协议**
   - VLESS-Reality-Vision
   - Hysteria2 + Salamander
   - AnyTLS
3. **一键二协议**
   - VLESS-CF-WS
   - VLESS-CF-WARP

除协议组合外，原有 WARP、Cloudflare Tunnel、FlClash、凭据复用、状态/日志/重启/卸载逻辑保持一致。

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xiaolee9897/sing-box-google/main/sb.sh)
```

菜单：

```text
1) 一键五协议
2) 一键三协议：Reality + HY2 + AnyTLS
3) 一键二协议：CF-WS + CF-WARP
4) 查看状态
5) 显示 / 刷新 FlClash 配置
6) 重启服务
7) 查看日志
8) 卸载
0) 退出
```

也可以直接调用：

```bash
sb install five
sb install direct
sb install cloudflare
```

非交互执行默认仍为五协议，也可以用：

```bash
DEPLOY_MODE=direct bash <(curl -fsSL https://raw.githubusercontent.com/xiaolee9897/sing-box-google/main/sb.sh)
```

## 推荐分工

如果同时使用 Google Cloud 与 Azure，可按成本和入口特性分工：

```text
Google Cloud / direct:
  VLESS-Reality
  Hysteria2
  AnyTLS

Azure / cloudflare:
  VLESS-CF-WS
  VLESS-CF-WARP
```

三协议模式不会启动 `cloudflared-singbox-google.service`，也不会生成 8080/8081 Cloudflare 入站或 WARP Endpoint。

二协议模式不会生成 Reality/Hysteria2/AnyTLS 入站，也不需要开放 443/8443/9443 作为直连代理端口。

## Cloudflare Named Tunnel

完整 CF-WS + CF-WARP 推荐一个 Named Tunnel 配两个 Public Hostname：

| Public Hostname | Service |
|---|---|
| `vless.example.com` | `http://localhost:8080` |
| `gwarp.example.com` | `http://localhost:8081` |

例如：

```bash
CF_TUNNEL_TOKEN='你的 Tunnel Token' \
CF_HOST='vless.example.com' \
WARP_CF_HOST='gwarp.example.com' \
bash <(curl -fsSL https://raw.githubusercontent.com/xiaolee9897/sing-box-google/main/sb.sh)
```

然后选择 `1` 或 `3`。

Tunnel Token 是敏感凭据，不要提交到仓库或公开位置。

## 默认端口与路径

| 节点 | 默认值 |
|---|---|
| VLESS-Reality | TCP `443` |
| Hysteria2 | UDP `8443` |
| AnyTLS | TCP `9443` |
| VLESS-CF-WS | `127.0.0.1:8080`，路径 `/vless` |
| VLESS-CF-WARP | `127.0.0.1:8081`，路径 `/warp` |

`8080` / `8081` 只绑定 localhost，不需要开放到公网。

三协议 / 五协议模式下，云安全组按实际需要开放：

```text
TCP 443
UDP 8443
TCP 9443
```

## 可覆盖环境变量

```text
DEPLOY_MODE
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

`DEPLOY_MODE` 支持：

```text
five
 direct
cloudflare
```

## 重装 / 切换模式时保留凭据

默认：

```text
PRESERVE_CREDENTIALS=true
```

如果 `/etc/singbox-google/state.env` 已存在，脚本优先复用已有：

- Reality UUID / key / short-id
- Hysteria2 password / obfs password
- AnyTLS password
- CF-WS UUID
- CF-WARP UUID

因此可以从五协议切到三协议而不改变三个直连节点的客户端参数，也可以以后再切回五协议。

若明确要重新生成全部代理凭据：

```bash
PRESERVE_CREDENTIALS=false bash <(curl -fsSL https://raw.githubusercontent.com/xiaolee9897/sing-box-google/main/sb.sh)
```

## WARP 行为

WARP 只在包含 Cloudflare 节点的 `five` / `cloudflare` 模式中配置。

默认：

```text
WARP_MODE=on
```

路由：

```text
VLESS-CF-WS   -> direct
VLESS-CF-WARP -> warp
```

WARP profile 的 Base64 PrivateKey/PublicKey 使用保留尾部 `=` 的解析方式，并执行长度校验。

如果 WARP 注册或解析失败，CF-WS 仍继续安装，CF-WARP 不写入最终 FlClash。

## Quick Tunnel

未提供 `CF_TUNNEL_TOKEN` 时，脚本仍可以为普通 CF-WS 建立 Quick Tunnel。

Quick Tunnel 只能自动映射一个本地 URL，因此不能完整提供 `8080 + 8081` 双入口。五协议或二协议的完整 CF-WS + CF-WARP 应使用 Named Tunnel。

## FlClash / Mihomo YAML

生成路径：

```text
/etc/singbox-google/flclash.yaml
```

`sb show` 会根据当前安装模式只输出实际存在的节点，并包含：

- `Proxy` 手动选择组
- `Auto` URL-Test 自动测速组
- Fake-IP DNS
- DoH nameserver
- HTTP / TLS / QUIC sniffer
- `MATCH,Proxy` 默认规则

YAML 包含真实 UUID、密码和节点信息，请勿提交到公开仓库。

## 服务

所有模式：

```text
singbox-google.service
```

五协议 / 二协议模式另外启用：

```text
cloudflared-singbox-google.service
```

切换到三协议模式时，脚本会停止并移除 Cloudflare Tunnel systemd service，避免继续产生不必要的 Cloudflare Tunnel 流量。

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
- `8080` / `8081` 仅绑定 `127.0.0.1`
- UUID、密码、Reality 私钥、WARP 私钥、Tunnel Token 只保存在 VPS 本地
- 不包含 Serv00 / Hostuno、VMess、TUIC、网页保活及仓库内置大体积代理二进制

仅用于合法的网络连接、隐私保护、测试与学习。使用者应遵守所在地法律法规及云服务商、Cloudflare 的服务条款。
