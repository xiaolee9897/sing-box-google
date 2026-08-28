# sing-box-google

一个面向 **Debian / Ubuntu VPS** 的精简一键部署脚本。

当前 `main` 只保留实际使用的 VPS 功能，不再包含 Serv00/Hostuno、网页保活、内置大体积二进制等历史代码。

## 五合一能力

1. **VLESS-Reality-Vision** — TCP
2. **Hysteria2 + Salamander** — UDP
3. **AnyTLS** — TCP
4. **VLESS-CF-WS** — VLESS WebSocket + Cloudflare Tunnel
5. **Cloudflare WARP** — 作为 VPS 代理流量的默认出站

> WARP 是出站 VPN，不是第五个 sing-box 入站监听器。FlClash 中生成四个可选 VPS 节点；这四个节点默认统一经 VPS 上的 WARP 出口访问互联网。

## 设计目标

- 一键安装，默认无需域名和证书
- sing-box 单进程承载 Reality / Hysteria2 / AnyTLS / VLESS-WS
- VLESS-CF-WS 默认使用 Cloudflare Quick Tunnel；支持固定 Tunnel Token
- WARP 使用 `wgcf` 注册，并通过 sing-box 1.13+ WireGuard Endpoint 接入
- 自动生成 FlClash / Mihomo YAML
- systemd 守护与开机自启
- 不关闭系统防火墙；仅在检测到 UFW/firewalld 已启用时放行必要端口
- 配置及凭据仅保存在 VPS 本地 `/etc/singbox-google`

## 支持范围

- Debian / Ubuntu
- amd64 / arm64
- systemd
- IPv4、IPv6 或双栈 VPS

不再支持：

- Serv00 / Hostuno
- VMess
- TUIC
- Web 保活
- GitHub Actions 保活
- 仓库内置 sing-box 二进制

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xiaolee9897/sing-box-google/main/sb.sh)
```

首次安装完成后会写入快捷命令：

```bash
sb
```

也可以直接：

```bash
sb status
sb show
sb restart
sb logs
sb uninstall
```

`sb show` 会刷新 Cloudflare Tunnel 域名并输出完整 FlClash 配置。

## 默认端口

| 功能 | 默认端口 | 协议 |
|---|---:|---|
| VLESS-Reality | 443 | TCP |
| Hysteria2 | 8443 | UDP |
| AnyTLS | 9443 | TCP |
| VLESS-CF-WS 本地回源 | 8080 | TCP，仅监听 127.0.0.1 |

VLESS-CF-WS 的 `8080` 不需要对公网开放。

云厂商安全组至少需要放行：

- TCP 443
- UDP 8443
- TCP 9443

## 自定义端口

安装前通过环境变量覆盖：

```bash
REALITY_PORT=10443 \
HY2_PORT=18443 \
ANYTLS_PORT=19443 \
bash <(curl -fsSL https://raw.githubusercontent.com/xiaolee9897/sing-box-google/main/sb.sh)
```

可用变量：

```text
REALITY_PORT
HY2_PORT
ANYTLS_PORT
WS_PORT
WS_PATH
REALITY_SNI
TLS_SNI
SERVER_ADDR
WARP_MODE
CF_TUNNEL_TOKEN
CF_HOST
SING_BOX_VERSION
CLOUDFLARED_VERSION
WGCF_VERSION
```

## Cloudflare Tunnel

### 默认：Quick Tunnel

不填写任何 Cloudflare 参数即可安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xiaolee9897/sing-box-google/main/sb.sh)
```

脚本会启动 Quick Tunnel 并尝试自动提取：

```text
*.trycloudflare.com
```

Quick Tunnel 域名在服务重启后可能变化，因此更适合测试或备用节点。

### 固定 Tunnel

如果已经在 Cloudflare Zero Trust 中创建 Tunnel，并将 Public Hostname 的 Service 指向：

```text
http://localhost:8080
```

可以安装时传入：

```bash
CF_TUNNEL_TOKEN='你的 Tunnel Token' \
CF_HOST='你的固定域名' \
bash <(curl -fsSL https://raw.githubusercontent.com/xiaolee9897/sing-box-google/main/sb.sh)
```

固定 Tunnel 更适合长期使用。

## Cloudflare WARP

默认：

```text
WARP_MODE=all
```

脚本会：

1. 下载 `wgcf`
2. 注册免费 WARP 设备
3. 生成 WireGuard profile
4. 转换为 sing-box 1.13+ WireGuard Endpoint
5. 将 VPS 代理流量的默认出站设置为 WARP

如果 WARP 注册失败，四个入站节点仍会继续安装，但会明确显示：

```text
CF WARP egress: OFF
```

如果明确不需要 WARP：

```bash
WARP_MODE=off bash <(curl -fsSL https://raw.githubusercontent.com/xiaolee9897/sing-box-google/main/sb.sh)
```

## FlClash 配置

生成位置：

```text
/etc/singbox-google/flclash.yaml
```

配置包含：

- VLESS-Reality
- Hysteria2
- AnyTLS
- VLESS-CF-WS
- `Proxy` 手动选择组
- `Auto` 自动测速组

查看：

```bash
sb show
```

文件包含真实节点凭据，请勿公开上传。

## 文件布局

```text
/etc/singbox-google/
├── config.json
├── state.env
├── server.crt
├── server.key
├── flclash.yaml
├── run-cloudflared.sh
└── warp/
```

程序：

```text
/usr/local/bin/sing-box
/usr/local/bin/cloudflared
/usr/local/bin/wgcf
/usr/local/bin/sb
```

服务：

```text
singbox-google.service
cloudflared-singbox-google.service
```

## 版本策略

默认固定版本，避免上游最新版本突然改变配置格式导致一键脚本失效：

```text
sing-box     1.13.14
cloudflared  2026.7.1
wgcf         2.2.32
```

均可通过环境变量覆盖。

## 安全说明

- 不把 UUID、密码、Reality 私钥、WARP 私钥上传到 GitHub
- `state.env`、`config.json`、`flclash.yaml` 权限为 root 本地文件
- VLESS-WS 仅绑定 `127.0.0.1`
- 不执行 `iptables -F`
- 不自动关闭 UFW/firewalld
- 不再把预编译代理二进制提交进仓库

## 与旧版的关系

本仓库最初基于社区 `sing-box-yg` 相关代码演化。此次重构保留仓库原有 GPL-3.0 License，并把 `main` 收敛为面向 VPS 的小型、可审计实现。

旧版约 150 KB 的多用途 `sb.sh` 同时包含大量 Serv00、VMess、TUIC、订阅、保活、网页及兼容逻辑；当前版本按实际需求重写，不再继承这些未使用路径。

## 免责声明

仅用于合法的网络连接、隐私保护、测试与学习。使用者应遵守所在地法律法规及云服务商、Cloudflare 的服务条款。
