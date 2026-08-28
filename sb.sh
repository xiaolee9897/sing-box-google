#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${INSTALL_DIR:-/etc/singbox-google}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
SING_BOX_BIN="$BIN_DIR/sing-box"
CLOUDFLARED_BIN="$BIN_DIR/cloudflared"
WGCF_BIN="$BIN_DIR/wgcf"
SERVICE_NAME="singbox-google"
CF_SERVICE_NAME="cloudflared-singbox-google"
STATE_FILE="$INSTALL_DIR/state.env"
CONFIG_FILE="$INSTALL_DIR/config.json"
FLCLASH_FILE="$INSTALL_DIR/flclash.yaml"
CERT_FILE="$INSTALL_DIR/server.crt"
KEY_FILE="$INSTALL_DIR/server.key"
CF_RUNNER="$INSTALL_DIR/run-cloudflared.sh"
SELF_URL="${SELF_URL:-https://raw.githubusercontent.com/xiaolee9897/sing-box-google/main/sb.sh}"

SING_BOX_VERSION="${SING_BOX_VERSION:-1.13.14}"
CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-2026.7.1}"
WGCF_VERSION="${WGCF_VERSION:-2.2.32}"
REALITY_PORT="${REALITY_PORT:-443}"
HY2_PORT="${HY2_PORT:-8443}"
ANYTLS_PORT="${ANYTLS_PORT:-9443}"
WS_PORT="${WS_PORT:-8080}"
WARP_WS_PORT="${WARP_WS_PORT:-8081}"
WS_PATH="${WS_PATH:-/vless}"
WARP_WS_PATH="${WARP_WS_PATH:-/warp}"
REALITY_SNI="${REALITY_SNI:-www.cloudflare.com}"
TLS_SNI="${TLS_SNI:-www.bing.com}"
WARP_MODE="${WARP_MODE:-on}"
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"
CF_HOST="${CF_HOST:-}"
WARP_CF_HOST="${WARP_CF_HOST:-}"
SERVER_ADDR="${SERVER_ADDR:-}"

G='\033[32m'; Y='\033[33m'; R='\033[31m'; B='\033[36m'; N='\033[0m'
log(){ printf "${G}[+]${N} %s\n" "$*"; }
warn(){ printf "${Y}[!]${N} %s\n" "$*" >&2; }
die(){ printf "${R}[x]${N} %s\n" "$*" >&2; exit 1; }
root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行。"; }

check_os(){ . /etc/os-release; case "${ID:-}" in debian|ubuntu) ;; *) die "仅支持 Debian/Ubuntu。";; esac; }
arch(){ case "$(uname -m)" in x86_64|amd64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) die "不支持的架构";; esac; }
deps(){ export DEBIAN_FRONTEND=noninteractive; apt-get update -y; apt-get install -y ca-certificates curl jq openssl tar gzip iproute2; }
dl(){ curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 "$1" -o "$2"; }

install_bins(){
  local t p; t="$(mktemp -d)"; p="sing-box-${SING_BOX_VERSION}-linux-${ARCH}"
  log "安装 sing-box ${SING_BOX_VERSION}"; dl "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${p}.tar.gz" "$t/sb.tgz"
  tar -xzf "$t/sb.tgz" -C "$t"; install -m755 "$t/$p/sing-box" "$SING_BOX_BIN"; rm -rf "$t"; "$SING_BOX_BIN" version >/dev/null
  log "安装 cloudflared ${CLOUDFLARED_VERSION}"; dl "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${ARCH}" "$CLOUDFLARED_BIN"; chmod 755 "$CLOUDFLARED_BIN"; "$CLOUDFLARED_BIN" --version >/dev/null
  log "安装 wgcf ${WGCF_VERSION}"; dl "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${ARCH}" "$WGCF_BIN"; chmod 755 "$WGCF_BIN"; "$WGCF_BIN" --help >/dev/null
}

stop_services(){ systemctl stop "$CF_SERVICE_NAME" "$SERVICE_NAME" >/dev/null 2>&1 || true; }
port_busy(){ ss -H "$1" 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]$2$"; }
check_ports(){
  local bad=0
  port_busy -ltn "$REALITY_PORT" && { warn "TCP $REALITY_PORT 被占用"; bad=1; }
  port_busy -lun "$HY2_PORT" && { warn "UDP $HY2_PORT 被占用"; bad=1; }
  port_busy -ltn "$ANYTLS_PORT" && { warn "TCP $ANYTLS_PORT 被占用"; bad=1; }
  port_busy -ltn "$WS_PORT" && { warn "TCP $WS_PORT 被占用"; bad=1; }
  port_busy -ltn "$WARP_WS_PORT" && { warn "TCP $WARP_WS_PORT 被占用"; bad=1; }
  [[ "$WS_PORT" != "$WARP_WS_PORT" ]] || die "WS_PORT 与 WARP_WS_PORT 不能相同"
  [[ "$WS_PATH" != "$WARP_WS_PATH" ]] || die "WS_PATH 与 WARP_WS_PATH 不能相同"
  [[ $bad -eq 0 ]] || die "存在端口冲突"
}

cert(){
  mkdir -p "$INSTALL_DIR"; chmod 700 "$INSTALL_DIR"
  if [[ ! -s "$CERT_FILE" || ! -s "$KEY_FILE" ]]; then
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=$TLS_SNI" >/dev/null 2>&1
    chmod 600 "$KEY_FILE"; chmod 644 "$CERT_FILE"
  fi
}

credentials(){
  REALITY_UUID="$($SING_BOX_BIN generate uuid)"; WS_UUID="$($SING_BOX_BIN generate uuid)"; WARP_WS_UUID="$($SING_BOX_BIN generate uuid)"
  HY2_PASSWORD="$(openssl rand -hex 24)"; HY2_OBFS="$(openssl rand -hex 16)"; ANYTLS_PASSWORD="$(openssl rand -hex 24)"; REALITY_SHORT_ID="$(openssl rand -hex 8)"
  local kp; kp="$($SING_BOX_BIN generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(awk -F': ' '/PrivateKey/{print $2;exit}' <<<"$kp")"; REALITY_PUBLIC_KEY="$(awk -F': ' '/PublicKey/{print $2;exit}' <<<"$kp")"
  [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || die "Reality 密钥生成失败"
}

warp(){
  WARP_ENABLED=false; WARP_PRIVATE_KEY=""; WARP_ADDRESS4=""; WARP_ADDRESS6=""; WARP_PEER_PUBLIC_KEY=""; WARP_PEER_PORT=2408; WARP_SERVER=""
  [[ "$WARP_MODE" != off ]] || return 0
  local d="$INSTALL_DIR/warp" p a; mkdir -p "$d"; chmod 700 "$d"
  log "配置 Cloudflare WARP"
  [[ -s "$d/wgcf-account.toml" ]] || "$WGCF_BIN" register --accept-tos --config "$d/wgcf-account.toml" || { warn "WARP 注册失败"; return 0; }
  "$WGCF_BIN" generate --config "$d/wgcf-account.toml" --profile "$d/wgcf-profile.conf" || { warn "WARP profile 生成失败"; return 0; }
  p="$d/wgcf-profile.conf"; a="$(awk -F' *= *' '/^Address *=/{print $2;exit}' "$p")"
  WARP_PRIVATE_KEY="$(awk -F' *= *' '/^PrivateKey *=/{print $2;exit}' "$p")"; WARP_PEER_PUBLIC_KEY="$(awk -F' *= *' '/^PublicKey *=/{print $2;exit}' "$p")"
  WARP_PEER_PORT="$(awk -F' *= *' '/^Endpoint *=/{sub(/^.*:/,"",$2);print $2;exit}' "$p")"; [[ "$WARP_PEER_PORT" =~ ^[0-9]+$ ]] || WARP_PEER_PORT=2408
  WARP_ADDRESS4="$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' <<<"$a" | head -1 || true)"; WARP_ADDRESS6="$(grep -oE '([0-9A-Fa-f]{0,4}:){2,}[0-9A-Fa-f:]+/[0-9]+' <<<"$a" | head -1 || true)"
  if curl -4fsS --max-time 5 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then WARP_SERVER=162.159.192.1; else WARP_SERVER=2606:4700:d0::a29f:c001; fi
  [[ -n "$WARP_PRIVATE_KEY$WARP_PEER_PUBLIC_KEY$WARP_ADDRESS4$WARP_ADDRESS6$WARP_SERVER" ]] || { warn "WARP 参数不完整"; return 0; }
  WARP_ENABLED=true; log "WARP 已启用，仅 VLESS-CF-WARP 节点使用 WARP 出站"
}

config(){
  jq -n --argjson rp "$REALITY_PORT" --argjson hp "$HY2_PORT" --argjson ap "$ANYTLS_PORT" --argjson wp "$WS_PORT" --argjson wwp "$WARP_WS_PORT" \
    --arg ru "$REALITY_UUID" --arg wu "$WS_UUID" --arg wwu "$WARP_WS_UUID" --arg hpass "$HY2_PASSWORD" --arg hobfs "$HY2_OBFS" --arg apass "$ANYTLS_PASSWORD" \
    --arg rsni "$REALITY_SNI" --arg rpriv "$REALITY_PRIVATE_KEY" --arg rsid "$REALITY_SHORT_ID" --arg cert "$CERT_FILE" --arg key "$KEY_FILE" \
    --arg wsp "$WS_PATH" --arg wwsp "$WARP_WS_PATH" --arg we "$WARP_ENABLED" --arg wpriv "$WARP_PRIVATE_KEY" --arg wa4 "$WARP_ADDRESS4" --arg wa6 "$WARP_ADDRESS6" \
    --arg wsrv "$WARP_SERVER" --argjson wport "$WARP_PEER_PORT" --arg wpub "$WARP_PEER_PUBLIC_KEY" '
    {
      log:{level:"warn",timestamp:true}, dns:{servers:[{type:"local",tag:"dns"}],final:"dns",strategy:"prefer_ipv4"},
      inbounds:[
        {type:"vless",tag:"reality",listen:"::",listen_port:$rp,users:[{uuid:$ru,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$rsni,reality:{enabled:true,handshake:{server:$rsni,server_port:443},private_key:$rpriv,short_id:[$rsid]}}},
        {type:"hysteria2",tag:"hy2",listen:"::",listen_port:$hp,users:[{password:$hpass}],obfs:{type:"salamander",password:$hobfs},tls:{enabled:true,alpn:["h3"],certificate_path:$cert,key_path:$key}},
        {type:"anytls",tag:"anytls",listen:"::",listen_port:$ap,users:[{password:$apass}],tls:{enabled:true,certificate_path:$cert,key_path:$key}},
        {type:"vless",tag:"cf-ws",listen:"127.0.0.1",listen_port:$wp,users:[{uuid:$wu}],transport:{type:"ws",path:$wsp}}
      ] + (if $we=="true" then [{type:"vless",tag:"cf-warp-ws",listen:"127.0.0.1",listen_port:$wwp,users:[{uuid:$wwu}],transport:{type:"ws",path:$wwsp}}] else [] end),
      outbounds:[{type:"direct",tag:"direct"}],
      route:{auto_detect_interface:true,default_domain_resolver:"dns",rules:(if $we=="true" then [{inbound:["cf-warp-ws"],action:"route",outbound:"warp"}] else [] end),final:"direct"}
    } + (if $we=="true" then {endpoints:[{type:"wireguard",tag:"warp",mtu:1280,address:[$wa4,$wa6]|map(select(length>0)),private_key:$wpriv,peers:[{address:$wsrv,port:$wport,public_key:$wpub,allowed_ips:["0.0.0.0/0","::/0"],persistent_keepalive_interval:30}]}]} else {} end)
  ' > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"; "$SING_BOX_BIN" check -c "$CONFIG_FILE"
}

state(){
  cat > "$STATE_FILE" <<STATE
REALITY_PORT=$REALITY_PORT
HY2_PORT=$HY2_PORT
ANYTLS_PORT=$ANYTLS_PORT
WS_PORT=$WS_PORT
WARP_WS_PORT=$WARP_WS_PORT
WS_PATH=$(printf %q "$WS_PATH")
WARP_WS_PATH=$(printf %q "$WARP_WS_PATH")
REALITY_SNI=$(printf %q "$REALITY_SNI")
TLS_SNI=$(printf %q "$TLS_SNI")
REALITY_UUID=$(printf %q "$REALITY_UUID")
WS_UUID=$(printf %q "$WS_UUID")
WARP_WS_UUID=$(printf %q "$WARP_WS_UUID")
HY2_PASSWORD=$(printf %q "$HY2_PASSWORD")
HY2_OBFS=$(printf %q "$HY2_OBFS")
ANYTLS_PASSWORD=$(printf %q "$ANYTLS_PASSWORD")
REALITY_PUBLIC_KEY=$(printf %q "$REALITY_PUBLIC_KEY")
REALITY_SHORT_ID=$(printf %q "$REALITY_SHORT_ID")
WARP_ENABLED=$WARP_ENABLED
CF_TUNNEL_TOKEN=$(printf %q "$CF_TUNNEL_TOKEN")
CF_HOST=$(printf %q "$CF_HOST")
WARP_CF_HOST=$(printf %q "$WARP_CF_HOST")
SERVER_ADDR=$(printf %q "$SERVER_ADDR")
STATE
  chmod 600 "$STATE_FILE"
}

services(){
  cat > "/etc/systemd/system/$SERVICE_NAME.service" <<UNIT
[Unit]
Description=sing-box-google
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$SING_BOX_BIN run -c $CONFIG_FILE
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
UNIT
  cat > "$CF_RUNNER" <<'RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/singbox-google/state.env
if [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then
  exec /usr/local/bin/cloudflared tunnel --no-autoupdate run --token "$CF_TUNNEL_TOKEN"
else
  exec /usr/local/bin/cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:${WS_PORT}"
fi
RUNNER
  chmod 700 "$CF_RUNNER"
  cat > "/etc/systemd/system/$CF_SERVICE_NAME.service" <<UNIT
[Unit]
Description=Cloudflare Tunnel for sing-box-google
After=$SERVICE_NAME.service network-online.target
Requires=$SERVICE_NAME.service
[Service]
ExecStart=$CF_RUNNER
Restart=always
RestartSec=5
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload; systemctl enable --now "$SERVICE_NAME"; sleep 2; systemctl is-active --quiet "$SERVICE_NAME" || die "sing-box 启动失败"
  systemctl enable --now "$CF_SERVICE_NAME"
}

server_addr(){ [[ -n "${SERVER_ADDR:-}" ]] && { echo "$SERVER_ADDR"; return; }; curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || curl -6fsS --max-time 8 https://api64.ipify.org; }
quick_host(){ journalctl -u "$CF_SERVICE_NAME" -n 120 --no-pager 2>/dev/null | grep -oE 'https://[A-Za-z0-9-]+\.trycloudflare\.com' | tail -1 | sed 's#https://##' || true; }
yq(){ printf "'%s'" "$(sed "s/'/''/g" <<<"$1")"; }

flclash(){
  source "$STATE_FILE"; local s c warp_ready=false
  s="$(server_addr)"; c="$CF_HOST"; [[ -n "$c" ]] || c="$(quick_host)"
  [[ "$WARP_ENABLED" == true && -n "$CF_TUNNEL_TOKEN" && -n "$WARP_CF_HOST" ]] && warp_ready=true
  cat > "$FLCLASH_FILE" <<YAML
mode: rule
log-level: warning
ipv6: true
dns:
  enable: true
  ipv6: true
  enhanced-mode: fake-ip
  nameserver: [https://1.1.1.1/dns-query, https://8.8.8.8/dns-query]
proxies:
  - name: VLESS-Reality
    type: vless
    server: $(yq "$s")
    port: $REALITY_PORT
    uuid: $(yq "$REALITY_UUID")
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $(yq "$REALITY_SNI")
    client-fingerprint: chrome
    reality-opts: {public-key: $(yq "$REALITY_PUBLIC_KEY"), short-id: $(yq "$REALITY_SHORT_ID")}
  - name: Hysteria2
    type: hysteria2
    server: $(yq "$s")
    port: $HY2_PORT
    password: $(yq "$HY2_PASSWORD")
    obfs: salamander
    obfs-password: $(yq "$HY2_OBFS")
    sni: $(yq "$TLS_SNI")
    skip-cert-verify: true
    alpn: [h3]
  - name: AnyTLS
    type: anytls
    server: $(yq "$s")
    port: $ANYTLS_PORT
    password: $(yq "$ANYTLS_PASSWORD")
    sni: $(yq "$TLS_SNI")
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: true
YAML
  if [[ -n "$c" ]]; then cat >> "$FLCLASH_FILE" <<YAML
  - name: VLESS-CF-WS
    type: vless
    server: $(yq "$c")
    port: 443
    uuid: $(yq "$WS_UUID")
    network: ws
    tls: true
    udp: true
    servername: $(yq "$c")
    client-fingerprint: chrome
    ws-opts: {path: $(yq "$WS_PATH"), headers: {Host: $(yq "$c")}}
YAML
  fi
  if [[ "$warp_ready" == true ]]; then cat >> "$FLCLASH_FILE" <<YAML
  - name: VLESS-CF-WARP
    type: vless
    server: $(yq "$WARP_CF_HOST")
    port: 443
    uuid: $(yq "$WARP_WS_UUID")
    network: ws
    tls: true
    udp: true
    servername: $(yq "$WARP_CF_HOST")
    client-fingerprint: chrome
    ws-opts: {path: $(yq "$WARP_WS_PATH"), headers: {Host: $(yq "$WARP_CF_HOST")}}
YAML
  fi
  cat >> "$FLCLASH_FILE" <<YAML
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - VLESS-Reality
      - Hysteria2
      - AnyTLS
YAML
  [[ -n "$c" ]] && echo '      - VLESS-CF-WS' >> "$FLCLASH_FILE"; [[ "$warp_ready" == true ]] && echo '      - VLESS-CF-WARP' >> "$FLCLASH_FILE"
  cat >> "$FLCLASH_FILE" <<YAML
      - DIRECT
  - name: Auto
    type: url-test
    url: https://www.gstatic.com/generate_204
    interval: 300
    proxies:
      - VLESS-Reality
      - Hysteria2
      - AnyTLS
YAML
  [[ -n "$c" ]] && echo '      - VLESS-CF-WS' >> "$FLCLASH_FILE"; [[ "$warp_ready" == true ]] && echo '      - VLESS-CF-WARP' >> "$FLCLASH_FILE"
  printf '\nrules:\n  - MATCH,Proxy\n' >> "$FLCLASH_FILE"; chmod 600 "$FLCLASH_FILE"
}

firewall(){
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then ufw allow "$REALITY_PORT/tcp" >/dev/null; ufw allow "$HY2_PORT/udp" >/dev/null; ufw allow "$ANYTLS_PORT/tcp" >/dev/null; else warn "云安全组需放行 TCP $REALITY_PORT、TCP $ANYTLS_PORT、UDP $HY2_PORT"; fi
}
summary(){ source "$STATE_FILE"; printf "\n${B}=== sing-box-google ===${N}\nReality: %s/tcp direct\nHY2: %s/udp direct\nAnyTLS: %s/tcp direct\nCF-WS: %s%s -> 127.0.0.1:%s direct\nCF-WARP: %s%s -> 127.0.0.1:%s -> WARP (%s)\nFlClash: %s\n\n" "$REALITY_PORT" "$HY2_PORT" "$ANYTLS_PORT" "${CF_HOST:-Quick-Tunnel}" "$WS_PATH" "$WS_PORT" "${WARP_CF_HOST:-未设置}" "$WARP_WS_PATH" "$WARP_WS_PORT" "$WARP_ENABLED" "$FLCLASH_FILE"; }
install_cli(){ curl -fsSL "$SELF_URL" -o "$BIN_DIR/sb" && chmod 755 "$BIN_DIR/sb" || true; }

install_all(){
  root; check_os; arch; deps; stop_services; check_ports; mkdir -p "$INSTALL_DIR"; chmod 700 "$INSTALL_DIR"
  [[ -n "$CF_TUNNEL_TOKEN" ]] || warn "未设置固定 Tunnel Token：只能生成 Quick Tunnel 的普通 CF-WS，无法同时映射 WARP 节点"
  [[ -n "$WARP_CF_HOST" || -z "$CF_TUNNEL_TOKEN" ]] || warn "WARP_CF_HOST 为空"
  install_bins; cert; credentials; warp; config; state; services; firewall; flclash; install_cli; summary; log "完成，运行 sb show 查看配置"
}
status_cmd(){ root; systemctl is-active "$SERVICE_NAME" || true; systemctl is-active "$CF_SERVICE_NAME" || true; [[ -s "$STATE_FILE" ]] && summary; }
show_cmd(){ root; [[ -s "$STATE_FILE" ]] || die "尚未安装"; flclash; summary; cat "$FLCLASH_FILE"; }
restart_cmd(){ root; systemctl restart "$SERVICE_NAME" "$CF_SERVICE_NAME"; sleep 2; status_cmd; }
logs_cmd(){ root; journalctl -u "$SERVICE_NAME" -u "$CF_SERVICE_NAME" -n 120 --no-pager; }
uninstall_cmd(){ root; systemctl disable --now "$SERVICE_NAME" "$CF_SERVICE_NAME" >/dev/null 2>&1 || true; rm -f "/etc/systemd/system/$SERVICE_NAME.service" "/etc/systemd/system/$CF_SERVICE_NAME.service" "$SING_BOX_BIN" "$CLOUDFLARED_BIN" "$WGCF_BIN" "$BIN_DIR/sb"; rm -rf "$INSTALL_DIR"; systemctl daemon-reload; }
menu(){ printf '1) 一键安装/重装\n2) 状态\n3) FlClash\n4) 重启\n5) 日志\n6) 卸载\n0) 退出\n'; read -r -p '请选择: ' x; case "$x" in 1) install_all;;2) status_cmd;;3) show_cmd;;4) restart_cmd;;5) logs_cmd;;6) uninstall_cmd;;0) exit;;*) die "无效选择";; esac; }
case "${1:-}" in install) install_all;;status) status_cmd;;show) show_cmd;;restart) restart_cmd;;logs) logs_cmd;;uninstall) uninstall_cmd;;"") [[ -t 0 ]] && menu || install_all;;*) echo '用法: sb {install|status|show|restart|logs|uninstall}';; esac
