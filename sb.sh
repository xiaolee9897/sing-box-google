#!/usr/bin/env bash
set -Eeuo pipefail

# sing-box-google selectable deployment
# five:       VLESS-Reality + Hysteria2 + AnyTLS + VLESS-CF-WS + VLESS-CF-WARP
# direct:     VLESS-Reality + Hysteria2 + AnyTLS
# cloudflare: VLESS-CF-WS + VLESS-CF-WARP

INSTALL_DIR="${INSTALL_DIR:-/etc/singbox-google}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
SING_BOX_BIN="${BIN_DIR}/sing-box"
CLOUDFLARED_BIN="${BIN_DIR}/cloudflared"
WGCF_BIN="${BIN_DIR}/wgcf"
SERVICE_NAME="singbox-google"
CF_SERVICE_NAME="cloudflared-singbox-google"
STATE_FILE="${INSTALL_DIR}/state.env"
CONFIG_FILE="${INSTALL_DIR}/config.json"
FLCLASH_FILE="${INSTALL_DIR}/flclash.yaml"
CERT_FILE="${INSTALL_DIR}/server.crt"
KEY_FILE="${INSTALL_DIR}/server.key"
CF_RUNNER="${INSTALL_DIR}/run-cloudflared.sh"
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
PRESERVE_CREDENTIALS="${PRESERVE_CREDENTIALS:-true}"
DEPLOY_MODE="${DEPLOY_MODE:-five}"

G='\033[32m'; Y='\033[33m'; R='\033[31m'; B='\033[36m'; N='\033[0m'
log(){ printf "${G}[+]${N} %s\n" "$*"; }
warn(){ printf "${Y}[!]${N} %s\n" "$*" >&2; }
die(){ printf "${R}[x]${N} %s\n" "$*" >&2; exit 1; }

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行。"; }
check_os(){
  [[ -f /etc/os-release ]] || die "无法识别系统。"
  . /etc/os-release
  case "${ID:-}" in debian|ubuntu) ;; *) die "仅支持 Debian/Ubuntu。";; esac
}
detect_arch(){ case "$(uname -m)" in x86_64|amd64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) die "不支持的 CPU 架构";; esac; }
install_dependencies(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl jq openssl tar gzip iproute2
}
download(){ curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 "$1" -o "$2"; }

validate_mode(){
  case "$DEPLOY_MODE" in five|direct|cloudflare) ;; *) die "DEPLOY_MODE 仅支持 five|direct|cloudflare。";; esac
}
uses_direct(){ [[ "$DEPLOY_MODE" == five || "$DEPLOY_MODE" == direct ]]; }
uses_cf(){ [[ "$DEPLOY_MODE" == five || "$DEPLOY_MODE" == cloudflare ]]; }

install_binaries(){
  local tmp pkg
  tmp="$(mktemp -d)"; pkg="sing-box-${SING_BOX_VERSION}-linux-${ARCH}"
  log "安装 sing-box ${SING_BOX_VERSION}"
  download "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${pkg}.tar.gz" "${tmp}/sb.tgz"
  tar -xzf "${tmp}/sb.tgz" -C "$tmp"
  install -m 0755 "${tmp}/${pkg}/sing-box" "$SING_BOX_BIN"
  rm -rf "$tmp"
  "$SING_BOX_BIN" version >/dev/null

  if uses_cf; then
    log "安装 cloudflared ${CLOUDFLARED_VERSION}"
    download "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${ARCH}" "$CLOUDFLARED_BIN"
    chmod 0755 "$CLOUDFLARED_BIN"
    "$CLOUDFLARED_BIN" --version >/dev/null

    log "安装 wgcf ${WGCF_VERSION}"
    download "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${ARCH}" "$WGCF_BIN"
    chmod 0755 "$WGCF_BIN"
    "$WGCF_BIN" --help >/dev/null
  fi
}

stop_services(){
  systemctl stop "${CF_SERVICE_NAME}.service" >/dev/null 2>&1 || true
  systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
}
port_busy(){
  local proto="$1" port="$2"
  if [[ "$proto" == udp ]]; then
    ss -H -lun 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}$"
  else
    ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
  fi
}
check_ports(){
  local bad=0 item proto port
  if uses_cf; then
    [[ "$WS_PORT" != "$WARP_WS_PORT" ]] || die "WS_PORT 与 WARP_WS_PORT 不能相同。"
    [[ "$WS_PATH" != "$WARP_WS_PATH" ]] || die "WS_PATH 与 WARP_WS_PATH 不能相同。"
  fi
  local items=()
  if uses_direct; then items+=("tcp:${REALITY_PORT}" "udp:${HY2_PORT}" "tcp:${ANYTLS_PORT}"); fi
  if uses_cf; then items+=("tcp:${WS_PORT}" "tcp:${WARP_WS_PORT}"); fi
  for item in "${items[@]}"; do
    proto="${item%%:*}"; port="${item##*:}"
    if port_busy "$proto" "$port"; then warn "${proto^^} ${port} 已被占用。"; bad=1; fi
  done
  [[ "$bad" -eq 0 ]] || die "存在端口冲突。"
}

load_existing_credentials(){
  [[ "$PRESERVE_CREDENTIALS" == true && -s "$STATE_FILE" ]] || return 1
  local requested_mode="$DEPLOY_MODE" requested_token="$CF_TUNNEL_TOKEN" requested_cf_host="$CF_HOST" requested_warp_host="$WARP_CF_HOST" requested_server="$SERVER_ADDR"
  source "$STATE_FILE"
  DEPLOY_MODE="$requested_mode"
  [[ -n "$requested_token" ]] && CF_TUNNEL_TOKEN="$requested_token"
  [[ -n "$requested_cf_host" ]] && CF_HOST="$requested_cf_host"
  [[ -n "$requested_warp_host" ]] && WARP_CF_HOST="$requested_warp_host"
  [[ -n "$requested_server" ]] && SERVER_ADDR="$requested_server"
  [[ -n "${REALITY_UUID:-}" && -n "${WS_UUID:-}" && -n "${WARP_WS_UUID:-}" && -n "${HY2_PASSWORD:-}" && -n "${HY2_OBFS:-}" && -n "${ANYTLS_PASSWORD:-}" && -n "${REALITY_PUBLIC_KEY:-}" && -n "${REALITY_PRIVATE_KEY:-}" && -n "${REALITY_SHORT_ID:-}" ]] || return 1
  log "复用现有节点凭据（PRESERVE_CREDENTIALS=true）"
  return 0
}

generate_credentials(){
  if load_existing_credentials; then return 0; fi
  REALITY_UUID="$($SING_BOX_BIN generate uuid)"
  WS_UUID="$($SING_BOX_BIN generate uuid)"
  WARP_WS_UUID="$($SING_BOX_BIN generate uuid)"
  HY2_PASSWORD="$(openssl rand -hex 24)"
  HY2_OBFS="$(openssl rand -hex 16)"
  ANYTLS_PASSWORD="$(openssl rand -hex 24)"
  REALITY_SHORT_ID="$(openssl rand -hex 8)"
  local kp
  kp="$($SING_BOX_BIN generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(awk -F': ' '/PrivateKey/{print $2;exit}' <<<"$kp")"
  REALITY_PUBLIC_KEY="$(awk -F': ' '/PublicKey/{print $2;exit}' <<<"$kp")"
  [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || die "Reality 密钥生成失败。"
}

generate_certificate(){
  uses_direct || return 0
  mkdir -p "$INSTALL_DIR"; chmod 0700 "$INSTALL_DIR"
  if [[ ! -s "$CERT_FILE" || ! -s "$KEY_FILE" ]]; then
    log "生成 Hysteria2 / AnyTLS 自签证书"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
      -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${TLS_SNI}" >/dev/null 2>&1
    chmod 0600 "$KEY_FILE"; chmod 0644 "$CERT_FILE"
  fi
}

provision_warp(){
  WARP_ENABLED=false
  WARP_PRIVATE_KEY=""; WARP_ADDRESS4=""; WARP_ADDRESS6=""; WARP_PEER_PUBLIC_KEY=""; WARP_PEER_PORT=2408; WARP_SERVER=""
  uses_cf || return 0
  [[ "$WARP_MODE" != off ]] || { warn "WARP_MODE=off：不生成 VLESS-CF-WARP 节点。"; return 0; }
  local d="$INSTALL_DIR/warp" p address_line endpoint
  mkdir -p "$d"; chmod 0700 "$d"
  log "配置 Cloudflare WARP"
  if [[ ! -s "$d/wgcf-account.toml" ]]; then
    "$WGCF_BIN" register --accept-tos --config "$d/wgcf-account.toml" || { warn "WARP 注册失败；CF-WS 继续安装。"; return 0; }
  fi
  "$WGCF_BIN" generate --config "$d/wgcf-account.toml" --profile "$d/wgcf-profile.conf" || { warn "WARP profile 生成失败；CF-WS 继续安装。"; return 0; }
  p="$d/wgcf-profile.conf"
  address_line="$(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$p" | head -1 | tr -d '\r')"
  WARP_PRIVATE_KEY="$(sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' "$p" | head -1 | tr -d '\r')"
  WARP_PEER_PUBLIC_KEY="$(sed -n 's/^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*//p' "$p" | head -1 | tr -d '\r')"
  endpoint="$(sed -n 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*//p' "$p" | head -1 | tr -d '\r')"
  WARP_PEER_PORT="${endpoint##*:}"; [[ "$WARP_PEER_PORT" =~ ^[0-9]+$ ]] || WARP_PEER_PORT=2408
  WARP_ADDRESS4="$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' <<<"$address_line" | head -1 || true)"
  WARP_ADDRESS6="$(grep -oE '([0-9A-Fa-f]{0,4}:){2,}[0-9A-Fa-f:]+/[0-9]+' <<<"$address_line" | head -1 || true)"
  if curl -4fsS --connect-timeout 3 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
    WARP_SERVER=162.159.192.1
  elif curl -6fsS --connect-timeout 3 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
    WARP_SERVER=2606:4700:d0::a29f:c001
  fi
  [[ ${#WARP_PRIVATE_KEY} -eq 44 ]] || { warn "WARP 私钥格式异常；CF-WS 继续安装。"; return 0; }
  [[ ${#WARP_PEER_PUBLIC_KEY} -eq 44 ]] || { warn "WARP 公钥格式异常；CF-WS 继续安装。"; return 0; }
  [[ -n "$WARP_ADDRESS4$WARP_ADDRESS6$WARP_SERVER" ]] || { warn "WARP 参数不完整；CF-WS 继续安装。"; return 0; }
  WARP_ENABLED=true
  log "WARP 已启用，仅 VLESS-CF-WARP 节点使用 WARP 出站"
}

generate_singbox_config(){
  local direct_enabled=false cf_enabled=false
  uses_direct && direct_enabled=true
  uses_cf && cf_enabled=true
  jq -n \
    --argjson rp "$REALITY_PORT" --argjson hp "$HY2_PORT" --argjson ap "$ANYTLS_PORT" \
    --argjson wp "$WS_PORT" --argjson wwp "$WARP_WS_PORT" \
    --arg ru "$REALITY_UUID" --arg wu "$WS_UUID" --arg wwu "$WARP_WS_UUID" \
    --arg hpass "$HY2_PASSWORD" --arg hobfs "$HY2_OBFS" --arg apass "$ANYTLS_PASSWORD" \
    --arg rsni "$REALITY_SNI" --arg rpriv "$REALITY_PRIVATE_KEY" --arg rsid "$REALITY_SHORT_ID" \
    --arg cert "$CERT_FILE" --arg key "$KEY_FILE" --arg wsp "$WS_PATH" --arg wwsp "$WARP_WS_PATH" \
    --arg de "$direct_enabled" --arg ce "$cf_enabled" \
    --arg we "$WARP_ENABLED" --arg wpriv "$WARP_PRIVATE_KEY" --arg wa4 "$WARP_ADDRESS4" --arg wa6 "$WARP_ADDRESS6" \
    --arg wsrv "$WARP_SERVER" --argjson wport "$WARP_PEER_PORT" --arg wpub "$WARP_PEER_PUBLIC_KEY" '
    ({
      log:{level:"warn",timestamp:true},
      dns:{servers:[{type:"local",tag:"dns"}],final:"dns",strategy:"prefer_ipv4"},
      inbounds: (
        (if $de=="true" then [
          {type:"vless",tag:"reality",listen:"::",listen_port:$rp,users:[{uuid:$ru,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$rsni,reality:{enabled:true,handshake:{server:$rsni,server_port:443},private_key:$rpriv,short_id:[$rsid]}}},
          {type:"hysteria2",tag:"hy2",listen:"::",listen_port:$hp,users:[{password:$hpass}],obfs:{type:"salamander",password:$hobfs},tls:{enabled:true,alpn:["h3"],certificate_path:$cert,key_path:$key}},
          {type:"anytls",tag:"anytls",listen:"::",listen_port:$ap,users:[{password:$apass}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}
        ] else [] end)
        +
        (if $ce=="true" then [{type:"vless",tag:"cf-ws",listen:"127.0.0.1",listen_port:$wp,users:[{uuid:$wu}],transport:{type:"ws",path:$wsp}}] else [] end)
        +
        (if $ce=="true" and $we=="true" then [{type:"vless",tag:"cf-warp-ws",listen:"127.0.0.1",listen_port:$wwp,users:[{uuid:$wwu}],transport:{type:"ws",path:$wwsp}}] else [] end)
      ),
      outbounds:[{type:"direct",tag:"direct"}],
      route:{auto_detect_interface:true,default_domain_resolver:"dns",rules:(if $ce=="true" and $we=="true" then [{inbound:["cf-warp-ws"],action:"route",outbound:"warp"}] else [] end),final:"direct"}
    }) + (if $ce=="true" and $we=="true" then {
      endpoints:[{type:"wireguard",tag:"warp",mtu:1280,address:[$wa4,$wa6]|map(select(length>0)),private_key:$wpriv,peers:[{address:$wsrv,port:$wport,public_key:$wpub,allowed_ips:["0.0.0.0/0","::/0"],persistent_keepalive_interval:30}]}]
    } else {} end)
  ' > "$CONFIG_FILE"
  chmod 0600 "$CONFIG_FILE"
  "$SING_BOX_BIN" check -c "$CONFIG_FILE"
}

write_state(){
  cat > "$STATE_FILE" <<EOF_STATE
DEPLOY_MODE=$(printf %q "$DEPLOY_MODE")
REALITY_PORT=${REALITY_PORT}
HY2_PORT=${HY2_PORT}
ANYTLS_PORT=${ANYTLS_PORT}
WS_PORT=${WS_PORT}
WARP_WS_PORT=${WARP_WS_PORT}
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
REALITY_PRIVATE_KEY=$(printf %q "$REALITY_PRIVATE_KEY")
REALITY_PUBLIC_KEY=$(printf %q "$REALITY_PUBLIC_KEY")
REALITY_SHORT_ID=$(printf %q "$REALITY_SHORT_ID")
WARP_ENABLED=${WARP_ENABLED}
CF_TUNNEL_TOKEN=$(printf %q "$CF_TUNNEL_TOKEN")
CF_HOST=$(printf %q "$CF_HOST")
WARP_CF_HOST=$(printf %q "$WARP_CF_HOST")
SERVER_ADDR=$(printf %q "$SERVER_ADDR")
EOF_STATE
  chmod 0600 "$STATE_FILE"
}

remove_cf_service(){
  systemctl disable --now "${CF_SERVICE_NAME}.service" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${CF_SERVICE_NAME}.service" "$CF_RUNNER"
}

create_services(){
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF_UNIT
[Unit]
Description=sing-box-google (${DEPLOY_MODE})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SING_BOX_BIN} run -c ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF_UNIT

  if uses_cf; then
    cat > "$CF_RUNNER" <<'EOF_RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/singbox-google/state.env
if [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then
  exec /usr/local/bin/cloudflared tunnel --no-autoupdate run --token "$CF_TUNNEL_TOKEN"
else
  exec /usr/local/bin/cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:${WS_PORT}"
fi
EOF_RUNNER
    chmod 0700 "$CF_RUNNER"
    cat > "/etc/systemd/system/${CF_SERVICE_NAME}.service" <<EOF_UNIT
[Unit]
Description=Cloudflare Tunnel for sing-box-google
After=${SERVICE_NAME}.service network-online.target
Requires=${SERVICE_NAME}.service

[Service]
Type=simple
ExecStart=${CF_RUNNER}
Restart=always
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF_UNIT
  else
    remove_cf_service
  fi

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}.service"
  sleep 2
  systemctl is-active --quiet "${SERVICE_NAME}.service" || { journalctl -u "${SERVICE_NAME}.service" -n 80 --no-pager >&2 || true; die "sing-box 启动失败。"; }
  if uses_cf; then
    systemctl enable --now "${CF_SERVICE_NAME}.service"
    sleep 2
    systemctl is-active --quiet "${CF_SERVICE_NAME}.service" || { journalctl -u "${CF_SERVICE_NAME}.service" -n 80 --no-pager >&2 || true; die "cloudflared 启动失败。"; }
  fi
}

open_firewall_ports(){
  uses_direct || return 0
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${REALITY_PORT}/tcp" >/dev/null
    ufw allow "${HY2_PORT}/udp" >/dev/null
    ufw allow "${ANYTLS_PORT}/tcp" >/dev/null
    log "已在 UFW 放行公网入口。"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${REALITY_PORT}/tcp" >/dev/null
    firewall-cmd --permanent --add-port="${HY2_PORT}/udp" >/dev/null
    firewall-cmd --permanent --add-port="${ANYTLS_PORT}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    log "已在 firewalld 放行公网入口。"
  else
    warn "未修改云厂商安全组；请确保 TCP ${REALITY_PORT}, UDP ${HY2_PORT}, TCP ${ANYTLS_PORT} 已放行。"
  fi
}

get_server_addr(){
  [[ -n "${SERVER_ADDR:-}" ]] && { printf '%s' "$SERVER_ADDR"; return; }
  curl -4fsS --connect-timeout 5 --max-time 8 https://api.ipify.org 2>/dev/null || curl -6fsS --connect-timeout 5 --max-time 8 https://api64.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'
}
quick_tunnel_host(){
  uses_cf || return 0
  journalctl -u "${CF_SERVICE_NAME}.service" -n 160 --no-pager 2>/dev/null | grep -oE 'https://[A-Za-z0-9-]+\.trycloudflare\.com' | tail -1 | sed 's#https://##' || true
}
yaml_quote(){ printf "'%s'" "$(sed "s/'/''/g" <<<"$1")"; }

generate_flclash(){
  source "$STATE_FILE"
  DEPLOY_MODE="${DEPLOY_MODE:-five}"
  local server="" cfhost="" warphost=""
  if uses_direct; then
    server="$(get_server_addr)"
    [[ -n "$server" ]] || die "无法检测 VPS 公网地址，请用 SERVER_ADDR=... 指定。"
  fi
  if uses_cf; then
    cfhost="${CF_HOST:-$(quick_tunnel_host)}"
    warphost="${WARP_CF_HOST:-}"
  fi
  cat > "$FLCLASH_FILE" <<EOF_YAML
# sing-box-google complete FlClash / Mihomo configuration
# Deploy mode: ${DEPLOY_MODE}
# PRIVATE CONFIG - contains node credentials
mode: rule
log-level: warning
ipv6: true
allow-lan: false
unified-delay: true
tcp-concurrent: true

dns:
  enable: true
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  use-hosts: true
  use-system-hosts: false
  respect-rules: false
  fake-ip-filter:
    - "+.lan"
    - "+.local"
    - "+.localhost"
    - "+.home.arpa"
    - "localhost"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
  default-nameserver: [1.1.1.1, 8.8.8.8]
  nameserver:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
  proxy-server-nameserver: [1.1.1.1, 8.8.8.8]

sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  override-destination: false
  sniff:
    HTTP:
      ports: [80, 8080-8880]
      override-destination: false
    TLS:
      ports: [443, 8443, 9443]
    QUIC:
      ports: [443, 8443]

proxies:
EOF_YAML
  if uses_direct; then
    cat >> "$FLCLASH_FILE" <<EOF_YAML
  - name: "VLESS-Reality"
    type: vless
    server: $(yaml_quote "$server")
    port: ${REALITY_PORT}
    uuid: $(yaml_quote "$REALITY_UUID")
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: $(yaml_quote "$REALITY_SNI")
    client-fingerprint: chrome
    reality-opts:
      public-key: $(yaml_quote "$REALITY_PUBLIC_KEY")
      short-id: $(yaml_quote "$REALITY_SHORT_ID")

  - name: "Hysteria2"
    type: hysteria2
    server: $(yaml_quote "$server")
    port: ${HY2_PORT}
    password: $(yaml_quote "$HY2_PASSWORD")
    obfs: salamander
    obfs-password: $(yaml_quote "$HY2_OBFS")
    sni: $(yaml_quote "$TLS_SNI")
    skip-cert-verify: true
    alpn: [h3]

  - name: "AnyTLS"
    type: anytls
    server: $(yaml_quote "$server")
    port: ${ANYTLS_PORT}
    password: $(yaml_quote "$ANYTLS_PASSWORD")
    sni: $(yaml_quote "$TLS_SNI")
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: true
EOF_YAML
  fi
  if uses_cf && [[ -n "$cfhost" ]]; then
    cat >> "$FLCLASH_FILE" <<EOF_YAML

  - name: "VLESS-CF-WS"
    type: vless
    server: $(yaml_quote "$cfhost")
    port: 443
    uuid: $(yaml_quote "$WS_UUID")
    network: ws
    udp: true
    tls: true
    servername: $(yaml_quote "$cfhost")
    client-fingerprint: chrome
    skip-cert-verify: false
    ws-opts:
      path: $(yaml_quote "$WS_PATH")
      headers:
        Host: $(yaml_quote "$cfhost")
EOF_YAML
  fi
  if uses_cf && [[ "$WARP_ENABLED" == true && -n "$warphost" ]]; then
    cat >> "$FLCLASH_FILE" <<EOF_YAML

  - name: "VLESS-CF-WARP"
    type: vless
    server: $(yaml_quote "$warphost")
    port: 443
    uuid: $(yaml_quote "$WARP_WS_UUID")
    network: ws
    udp: true
    tls: true
    servername: $(yaml_quote "$warphost")
    client-fingerprint: chrome
    skip-cert-verify: false
    ws-opts:
      path: $(yaml_quote "$WARP_WS_PATH")
      headers:
        Host: $(yaml_quote "$warphost")
EOF_YAML
  fi
  cat >> "$FLCLASH_FILE" <<'EOF_YAML'

proxy-groups:
  - name: "Proxy"
    type: select
    proxies:
      - "Auto"
EOF_YAML
  if uses_direct; then
    echo '      - "VLESS-Reality"' >> "$FLCLASH_FILE"
    echo '      - "Hysteria2"' >> "$FLCLASH_FILE"
    echo '      - "AnyTLS"' >> "$FLCLASH_FILE"
  fi
  uses_cf && [[ -n "$cfhost" ]] && echo '      - "VLESS-CF-WS"' >> "$FLCLASH_FILE"
  uses_cf && [[ "$WARP_ENABLED" == true && -n "$warphost" ]] && echo '      - "VLESS-CF-WARP"' >> "$FLCLASH_FILE"
  cat >> "$FLCLASH_FILE" <<'EOF_YAML'
      - DIRECT

  - name: "Auto"
    type: url-test
    url: "https://www.gstatic.com/generate_204"
    interval: 300
    tolerance: 80
    lazy: true
    proxies:
EOF_YAML
  if uses_direct; then
    echo '      - "VLESS-Reality"' >> "$FLCLASH_FILE"
    echo '      - "Hysteria2"' >> "$FLCLASH_FILE"
    echo '      - "AnyTLS"' >> "$FLCLASH_FILE"
  fi
  uses_cf && [[ -n "$cfhost" ]] && echo '      - "VLESS-CF-WS"' >> "$FLCLASH_FILE"
  uses_cf && [[ "$WARP_ENABLED" == true && -n "$warphost" ]] && echo '      - "VLESS-CF-WARP"' >> "$FLCLASH_FILE"
  cat >> "$FLCLASH_FILE" <<'EOF_YAML'

rules:
  - MATCH,Proxy
EOF_YAML
  chmod 0600 "$FLCLASH_FILE"
  [[ -n "$server" ]] && SERVER_ADDR="$server"
  [[ -n "$CF_TUNNEL_TOKEN" || -z "$cfhost" ]] || CF_HOST="$cfhost"
  write_state
}

show_summary(){
  source "$STATE_FILE"
  DEPLOY_MODE="${DEPLOY_MODE:-five}"
  printf "\n${B}=== sing-box-google ===${N}\n"
  printf "Mode: %s\n" "$DEPLOY_MODE"
  if uses_direct; then
    printf "Reality: %s/tcp direct\n" "$REALITY_PORT"
    printf "HY2: %s/udp direct\n" "$HY2_PORT"
    printf "AnyTLS: %s/tcp direct\n" "$ANYTLS_PORT"
  fi
  if uses_cf; then
    printf "CF-WS: %s%s -> 127.0.0.1:%s -> direct\n" "${CF_HOST:-Quick-Tunnel}" "$WS_PATH" "$WS_PORT"
    printf "CF-WARP: %s%s -> 127.0.0.1:%s -> WARP (%s)\n" "${WARP_CF_HOST:-未配置}" "$WARP_WS_PATH" "$WARP_WS_PORT" "$WARP_ENABLED"
  fi
  printf "FlClash: %s\n\n" "$FLCLASH_FILE"
}

install_cli(){
  if curl -fsSL --connect-timeout 10 --max-time 60 "$SELF_URL" -o "${BIN_DIR}/sb"; then chmod 0755 "${BIN_DIR}/sb"; else warn "快捷命令 sb 写入失败。"; fi
}

install_mode(){
  DEPLOY_MODE="$1"
  validate_mode
  require_root; check_os; detect_arch; install_dependencies
  stop_services; check_ports
  mkdir -p "$INSTALL_DIR"; chmod 0700 "$INSTALL_DIR"
  install_binaries; generate_certificate; generate_credentials; provision_warp
  generate_singbox_config; write_state; create_services; open_firewall_ports
  generate_flclash; install_cli; show_summary
  log "安装完成。运行 'sb show' 查看完整 FlClash 配置。"
}

status_cmd(){
  require_root
  printf "%-32s %s\n" "$SERVICE_NAME" "$(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || true)"
  if [[ -s "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    DEPLOY_MODE="${DEPLOY_MODE:-five}"
    if uses_cf; then printf "%-32s %s\n" "$CF_SERVICE_NAME" "$(systemctl is-active "${CF_SERVICE_NAME}.service" 2>/dev/null || true)"; else printf "%-32s %s\n" "$CF_SERVICE_NAME" "disabled (direct mode)"; fi
    show_summary
  fi
}
show_cmd(){ require_root; [[ -s "$STATE_FILE" ]] || die "尚未安装。"; generate_flclash; show_summary; cat "$FLCLASH_FILE"; }
restart_cmd(){
  require_root; [[ -s "$STATE_FILE" ]] || die "尚未安装。"; source "$STATE_FILE"; DEPLOY_MODE="${DEPLOY_MODE:-five}"
  systemctl restart "${SERVICE_NAME}.service"; uses_cf && systemctl restart "${CF_SERVICE_NAME}.service"; sleep 2; status_cmd
}
logs_cmd(){
  require_root; [[ -s "$STATE_FILE" ]] || die "尚未安装。"; source "$STATE_FILE"; DEPLOY_MODE="${DEPLOY_MODE:-five}"
  if uses_cf; then journalctl -u "${SERVICE_NAME}.service" -u "${CF_SERVICE_NAME}.service" -n 160 --no-pager; else journalctl -u "${SERVICE_NAME}.service" -n 160 --no-pager; fi
}
uninstall_cmd(){
  require_root
  systemctl disable --now "${CF_SERVICE_NAME}.service" "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${CF_SERVICE_NAME}.service" "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload
  rm -f "$SING_BOX_BIN" "$CLOUDFLARED_BIN" "$WGCF_BIN" "${BIN_DIR}/sb"
  rm -rf "$INSTALL_DIR"
  log "已卸载。"
}

menu(){
  cat <<'EOF_MENU'
sing-box-google
1) 一键五协议
2) 一键三协议：Reality + HY2 + AnyTLS
3) 一键二协议：CF-WS + CF-WARP
4) 查看状态
5) 显示 / 刷新 FlClash 配置
6) 重启服务
7) 查看日志
8) 卸载
0) 退出
EOF_MENU
  read -r -p '请选择: ' choice
  case "$choice" in
    1) install_mode five;;
    2) install_mode direct;;
    3) install_mode cloudflare;;
    4) status_cmd;;
    5) show_cmd;;
    6) restart_cmd;;
    7) logs_cmd;;
    8) uninstall_cmd;;
    0) exit 0;;
    *) die "无效选择。";;
  esac
}

main(){
  case "${1:-}" in
    install)
      case "${2:-five}" in five|direct|cloudflare) install_mode "${2:-five}";; *) die "安装模式仅支持: five|direct|cloudflare";; esac
      ;;
    status) status_cmd;;
    show) show_cmd;;
    restart) restart_cmd;;
    logs) logs_cmd;;
    uninstall) uninstall_cmd;;
    "") if [[ -t 0 ]]; then menu; else install_mode "${DEPLOY_MODE:-five}"; fi;;
    *) die "未知命令。可用: install [five|direct|cloudflare]|status|show|restart|logs|uninstall";;
  esac
}
main "$@"
