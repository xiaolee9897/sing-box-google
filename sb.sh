#!/usr/bin/env bash
set -Eeuo pipefail

# sing-box-google: VPS-only 5-in-1
# VLESS-Reality + Hysteria2 + AnyTLS + VLESS-CF-WS + Cloudflare WARP egress
# Debian/Ubuntu, amd64/arm64

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
WS_PATH="${WS_PATH:-/vless}"
REALITY_SNI="${REALITY_SNI:-www.cloudflare.com}"
TLS_SNI="${TLS_SNI:-www.bing.com}"
WARP_MODE="${WARP_MODE:-all}"
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"
CF_HOST="${CF_HOST:-}"
SERVER_ADDR="${SERVER_ADDR:-}"

GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; BLUE='\033[36m'; RESET='\033[0m'
log(){ printf "${GREEN}[+]${RESET} %s\n" "$*"; }
warn(){ printf "${YELLOW}[!]${RESET} %s\n" "$*" >&2; }
die(){ printf "${RED}[x]${RESET} %s\n" "$*" >&2; exit 1; }
require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行。"; }

check_os(){
  [[ -f /etc/os-release ]] || die "无法识别系统。"
  . /etc/os-release
  case "${ID:-}" in debian|ubuntu) ;; *) die "仅支持 Debian/Ubuntu。";; esac
}

detect_arch(){
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

install_dependencies(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl jq openssl tar gzip iproute2
}

download(){
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 "$1" -o "$2"
}

install_sing_box(){
  local tmp pkg
  tmp="$(mktemp -d)"; pkg="sing-box-${SING_BOX_VERSION}-linux-${ARCH}"
  log "安装 sing-box ${SING_BOX_VERSION} (${ARCH})"
  download "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${pkg}.tar.gz" "${tmp}/sing-box.tar.gz"
  tar -xzf "${tmp}/sing-box.tar.gz" -C "$tmp"
  install -m 0755 "${tmp}/${pkg}/sing-box" "$SING_BOX_BIN"
  rm -rf "$tmp"
  "$SING_BOX_BIN" version >/dev/null
}

install_cloudflared(){
  log "安装 cloudflared ${CLOUDFLARED_VERSION} (${ARCH})"
  download "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${ARCH}" "$CLOUDFLARED_BIN"
  chmod 0755 "$CLOUDFLARED_BIN"
  "$CLOUDFLARED_BIN" --version >/dev/null
}

install_wgcf(){
  log "安装 wgcf ${WGCF_VERSION} (${ARCH})"
  download "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${ARCH}" "$WGCF_BIN"
  chmod 0755 "$WGCF_BIN"
  # wgcf v2.2.x does not implement --version. --help is the safe executable check.
  "$WGCF_BIN" --help >/dev/null
}

install_cli(){
  if curl -fsSL --connect-timeout 10 --max-time 60 "$SELF_URL" -o "${BIN_DIR}/sb"; then
    chmod 0755 "${BIN_DIR}/sb"
  else
    warn "快捷命令 sb 写入失败；主服务不受影响。"
  fi
}

stop_existing_services(){
  systemctl stop "${CF_SERVICE_NAME}.service" >/dev/null 2>&1 || true
  systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
}

port_in_use(){
  local proto="$1" port="$2"
  if [[ "$proto" == udp ]]; then
    ss -H -lun 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}$"
  else
    ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
  fi
}

check_ports(){
  local failed=0 item proto port
  for item in "tcp:${REALITY_PORT}" "udp:${HY2_PORT}" "tcp:${ANYTLS_PORT}" "tcp:${WS_PORT}"; do
    proto="${item%%:*}"; port="${item##*:}"
    if port_in_use "$proto" "$port"; then warn "${proto^^} ${port} 已被占用。"; failed=1; fi
  done
  [[ $failed -eq 0 ]] || die "存在端口冲突。"
}

random_hex(){ openssl rand -hex "${1:-16}"; }

generate_certificate(){
  mkdir -p "$INSTALL_DIR"; chmod 0700 "$INSTALL_DIR"
  if [[ ! -s "$CERT_FILE" || ! -s "$KEY_FILE" ]]; then
    log "生成 Hysteria2 / AnyTLS 自签证书"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
      -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${TLS_SNI}" >/dev/null 2>&1
    chmod 0600 "$KEY_FILE"; chmod 0644 "$CERT_FILE"
  fi
}

generate_credentials(){
  REALITY_UUID="$("$SING_BOX_BIN" generate uuid)"
  WS_UUID="$("$SING_BOX_BIN" generate uuid)"
  HY2_PASSWORD="$(random_hex 24)"
  HY2_OBFS="$(random_hex 16)"
  ANYTLS_PASSWORD="$(random_hex 24)"
  REALITY_SHORT_ID="$(random_hex 8)"
  local keypair
  keypair="$("$SING_BOX_BIN" generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(awk -F': ' '/PrivateKey/ {print $2; exit}' <<<"$keypair")"
  REALITY_PUBLIC_KEY="$(awk -F': ' '/PublicKey/ {print $2; exit}' <<<"$keypair")"
  [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || die "Reality 密钥生成失败。"
}

provision_warp(){
  WARP_ENABLED=false; WARP_PRIVATE_KEY=""; WARP_ADDRESS4=""; WARP_ADDRESS6=""
  WARP_PEER_PUBLIC_KEY=""; WARP_PEER_PORT=2408; WARP_SERVER=""
  [[ "$WARP_MODE" != off ]] || { warn "WARP_MODE=off：跳过 WARP。"; return 0; }

  local warp_dir="${INSTALL_DIR}/warp" profile address_line
  mkdir -p "$warp_dir"; chmod 0700 "$warp_dir"
  log "注册 Cloudflare WARP"
  if [[ ! -s "${warp_dir}/wgcf-account.toml" ]]; then
    if ! "$WGCF_BIN" register --accept-tos --config "${warp_dir}/wgcf-account.toml"; then
      warn "WARP 注册失败；继续安装四个代理入口。"; return 0
    fi
  fi
  if ! "$WGCF_BIN" generate --config "${warp_dir}/wgcf-account.toml" --profile "${warp_dir}/wgcf-profile.conf"; then
    warn "WARP profile 生成失败；继续安装四个代理入口。"; return 0
  fi

  profile="${warp_dir}/wgcf-profile.conf"
  [[ -s "$profile" ]] || { warn "WARP profile 为空。"; return 0; }
  WARP_PRIVATE_KEY="$(awk -F' *= *' '/^PrivateKey *=/ {print $2; exit}' "$profile")"
  WARP_PEER_PUBLIC_KEY="$(awk -F' *= *' '/^PublicKey *=/ {print $2; exit}' "$profile")"
  WARP_PEER_PORT="$(awk -F' *= *' '/^Endpoint *=/ {gsub(/\r/,"",$2); sub(/^.*:/,"",$2); print $2; exit}' "$profile")"
  [[ "$WARP_PEER_PORT" =~ ^[0-9]+$ ]] || WARP_PEER_PORT=2408
  address_line="$(awk -F' *= *' '/^Address *=/ {print $2; exit}' "$profile")"
  WARP_ADDRESS4="$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' <<<"$address_line" | head -n1 || true)"
  WARP_ADDRESS6="$(grep -oE '([0-9A-Fa-f]{0,4}:){2,}[0-9A-Fa-f:]+/[0-9]+' <<<"$address_line" | head -n1 || true)"
  if curl -4fsS --connect-timeout 3 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
    WARP_SERVER="162.159.192.1"
  elif curl -6fsS --connect-timeout 3 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
    WARP_SERVER="2606:4700:d0::a29f:c001"
  fi
  if [[ -z "$WARP_PRIVATE_KEY" || -z "$WARP_PEER_PUBLIC_KEY" || -z "$WARP_ADDRESS4$WARP_ADDRESS6" || -z "$WARP_SERVER" ]]; then
    warn "WARP profile 不完整；继续使用直连出口。"; return 0
  fi
  WARP_ENABLED=true
  log "CF WARP 已就绪。"
}

generate_singbox_config(){
  local route_final=direct
  [[ "$WARP_ENABLED" == true ]] && route_final=warp
  jq -n \
    --argjson rp "$REALITY_PORT" --argjson hp "$HY2_PORT" --argjson ap "$ANYTLS_PORT" --argjson wp "$WS_PORT" \
    --arg ru "$REALITY_UUID" --arg wu "$WS_UUID" --arg hpass "$HY2_PASSWORD" --arg hobfs "$HY2_OBFS" \
    --arg apass "$ANYTLS_PASSWORD" --arg rsni "$REALITY_SNI" --arg tsni "$TLS_SNI" \
    --arg rpriv "$REALITY_PRIVATE_KEY" --arg rsid "$REALITY_SHORT_ID" --arg cert "$CERT_FILE" --arg key "$KEY_FILE" \
    --arg wsp "$WS_PATH" --arg final "$route_final" --arg we "$WARP_ENABLED" --arg wpriv "$WARP_PRIVATE_KEY" \
    --arg wa4 "$WARP_ADDRESS4" --arg wa6 "$WARP_ADDRESS6" --arg wserver "$WARP_SERVER" \
    --argjson wport "$WARP_PEER_PORT" --arg wpub "$WARP_PEER_PUBLIC_KEY" '
    {
      log:{level:"warn",timestamp:true},
      dns:{servers:[{type:"local",tag:"local-dns"}],final:"local-dns",strategy:"prefer_ipv4"},
      inbounds:[
        {type:"vless",tag:"vless-reality-in",listen:"::",listen_port:$rp,users:[{name:"default",uuid:$ru,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$rsni,reality:{enabled:true,handshake:{server:$rsni,server_port:443},private_key:$rpriv,short_id:[$rsid]}}},
        {type:"hysteria2",tag:"hysteria2-in",listen:"::",listen_port:$hp,users:[{name:"default",password:$hpass}],obfs:{type:"salamander",password:$hobfs},tls:{enabled:true,alpn:["h3"],certificate_path:$cert,key_path:$key}},
        {type:"anytls",tag:"anytls-in",listen:"::",listen_port:$ap,users:[{name:"default",password:$apass}],tls:{enabled:true,certificate_path:$cert,key_path:$key}},
        {type:"vless",tag:"vless-cf-ws-in",listen:"127.0.0.1",listen_port:$wp,users:[{name:"default",uuid:$wu}],transport:{type:"ws",path:$wsp}}
      ],
      outbounds:[{type:"direct",tag:"direct"}],
      route:{auto_detect_interface:true,default_domain_resolver:"local-dns",final:$final}
    }
    + (if $we=="true" then {endpoints:[{type:"wireguard",tag:"warp",mtu:1280,address:[$wa4,$wa6]|map(select(length>0)),private_key:$wpriv,peers:[{address:$wserver,port:$wport,public_key:$wpub,allowed_ips:["0.0.0.0/0","::/0"],persistent_keepalive_interval:30}]}]} else {} end)
  ' > "$CONFIG_FILE"
  chmod 0600 "$CONFIG_FILE"
  "$SING_BOX_BIN" check -c "$CONFIG_FILE"
}

write_state(){
  cat > "$STATE_FILE" <<EOF
REALITY_PORT=${REALITY_PORT}
HY2_PORT=${HY2_PORT}
ANYTLS_PORT=${ANYTLS_PORT}
WS_PORT=${WS_PORT}
WS_PATH=$(printf '%q' "$WS_PATH")
REALITY_SNI=$(printf '%q' "$REALITY_SNI")
TLS_SNI=$(printf '%q' "$TLS_SNI")
REALITY_UUID=$(printf '%q' "$REALITY_UUID")
WS_UUID=$(printf '%q' "$WS_UUID")
HY2_PASSWORD=$(printf '%q' "$HY2_PASSWORD")
HY2_OBFS=$(printf '%q' "$HY2_OBFS")
ANYTLS_PASSWORD=$(printf '%q' "$ANYTLS_PASSWORD")
REALITY_PUBLIC_KEY=$(printf '%q' "$REALITY_PUBLIC_KEY")
REALITY_SHORT_ID=$(printf '%q' "$REALITY_SHORT_ID")
WARP_ENABLED=${WARP_ENABLED}
CF_TUNNEL_TOKEN=$(printf '%q' "$CF_TUNNEL_TOKEN")
CF_HOST=$(printf '%q' "$CF_HOST")
SERVER_ADDR=$(printf '%q' "$SERVER_ADDR")
EOF
  chmod 0600 "$STATE_FILE"
}

create_systemd_service(){
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=sing-box-google
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
EOF
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}.service"
  sleep 2
  systemctl is-active --quiet "${SERVICE_NAME}.service" || { journalctl -u "${SERVICE_NAME}.service" -n 80 --no-pager >&2; die "sing-box 启动失败。"; }
}

create_cloudflared_service(){
  cat > "$CF_RUNNER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/singbox-google/state.env
if [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then
  exec /usr/local/bin/cloudflared tunnel --no-autoupdate run --token "${CF_TUNNEL_TOKEN}"
else
  exec /usr/local/bin/cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:${WS_PORT}"
fi
EOF
  chmod 0700 "$CF_RUNNER"
  cat > "/etc/systemd/system/${CF_SERVICE_NAME}.service" <<EOF
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
EOF
  systemctl daemon-reload
  systemctl enable --now "${CF_SERVICE_NAME}.service"
  sleep 2
  systemctl is-active --quiet "${CF_SERVICE_NAME}.service" || warn "cloudflared 尚未进入 active，请用 sb logs 检查。"
}

get_server_addr(){
  [[ -n "${SERVER_ADDR:-}" ]] && { printf '%s' "$SERVER_ADDR"; return; }
  local v4 v6
  v4="$(curl -4fsS --connect-timeout 5 --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$v4" ]] && { printf '%s' "$v4"; return; }
  v6="$(curl -6fsS --connect-timeout 5 --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
  [[ -n "$v6" ]] && { printf '%s' "$v6"; return; }
  hostname -I | awk '{print $1}'
}

discover_cf_host(){
  [[ -n "${CF_TUNNEL_TOKEN:-}" && -n "${CF_HOST:-}" ]] && { printf '%s' "$CF_HOST"; return; }
  journalctl -u "${CF_SERVICE_NAME}.service" -n 160 --no-pager 2>/dev/null | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | tail -n1 | sed 's#https://##' || true
}

yaml_quote(){ printf "'%s'" "$(sed "s/'/''/g" <<<"$1")"; }

generate_flclash(){
  source "$STATE_FILE"
  local server cfhost
  server="$(get_server_addr)"; cfhost="$(discover_cf_host)"
  [[ -n "$server" ]] || die "无法检测公网地址，请使用 SERVER_ADDR=... 指定。"
  cat > "$FLCLASH_FILE" <<EOF
mode: rule
log-level: warning
ipv6: true
dns:
  enable: true
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
proxies:
  - name: "VLESS-Reality"
    type: vless
    server: $(yaml_quote "$server")
    port: ${REALITY_PORT}
    uuid: $(yaml_quote "$REALITY_UUID")
    network: tcp
    tls: true
    udp: true
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
EOF
  if [[ -n "$cfhost" ]]; then
    cat >> "$FLCLASH_FILE" <<EOF
  - name: "VLESS-CF-WS"
    type: vless
    server: $(yaml_quote "$cfhost")
    port: 443
    uuid: $(yaml_quote "$WS_UUID")
    network: ws
    tls: true
    udp: true
    servername: $(yaml_quote "$cfhost")
    client-fingerprint: chrome
    ws-opts:
      path: $(yaml_quote "$WS_PATH")
      headers:
        Host: $(yaml_quote "$cfhost")
EOF
  fi
  cat >> "$FLCLASH_FILE" <<EOF
proxy-groups:
  - name: "Proxy"
    type: select
    proxies:
      - "VLESS-Reality"
      - "Hysteria2"
      - "AnyTLS"
EOF
  [[ -n "$cfhost" ]] && echo '      - "VLESS-CF-WS"' >> "$FLCLASH_FILE"
  cat >> "$FLCLASH_FILE" <<'EOF'
      - DIRECT
rules:
  - MATCH,Proxy
EOF
  chmod 0600 "$FLCLASH_FILE"
  SERVER_ADDR="$server"; CF_HOST="$cfhost"; write_state
}

open_firewall_ports(){
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${REALITY_PORT}/tcp" >/dev/null; ufw allow "${HY2_PORT}/udp" >/dev/null; ufw allow "${ANYTLS_PORT}/tcp" >/dev/null
  else
    warn "请在云防火墙放行 TCP ${REALITY_PORT}, TCP ${ANYTLS_PORT}, UDP ${HY2_PORT}。"
  fi
}

show_summary(){
  source "$STATE_FILE"
  printf "\n${BLUE}================ sing-box-google ================${RESET}\n"
  printf "VLESS-Reality : TCP %s\n" "$REALITY_PORT"
  printf "Hysteria2     : UDP %s\n" "$HY2_PORT"
  printf "AnyTLS        : TCP %s\n" "$ANYTLS_PORT"
  printf "VLESS-CF-WS   : %s%s\n" "${CF_HOST:-等待 Tunnel 域名}" "$WS_PATH"
  printf "CF WARP egress: %s\n" "$([[ "$WARP_ENABLED" == true ]] && echo ON || echo OFF)"
  printf "FlClash       : %s\n" "$FLCLASH_FILE"
  printf "${BLUE}=================================================${RESET}\n\n"
}

install_all(){
  require_root; check_os; detect_arch; install_dependencies; stop_existing_services; check_ports
  mkdir -p "$INSTALL_DIR"; chmod 0700 "$INSTALL_DIR"
  install_sing_box; install_cloudflared; install_wgcf; generate_certificate; generate_credentials; provision_warp
  generate_singbox_config; write_state; create_systemd_service; create_cloudflared_service; open_firewall_ports
  generate_flclash; install_cli; show_summary
  log "安装完成。运行 sb show 查看配置。"
}

status_cmd(){ require_root; printf "%-30s %s\n" "$SERVICE_NAME" "$(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || true)"; printf "%-30s %s\n" "$CF_SERVICE_NAME" "$(systemctl is-active "${CF_SERVICE_NAME}.service" 2>/dev/null || true)"; [[ -f "$STATE_FILE" ]] && show_summary; }
show_cmd(){ require_root; [[ -s "$STATE_FILE" ]] || die "尚未安装。"; generate_flclash; show_summary; cat "$FLCLASH_FILE"; }
restart_cmd(){ require_root; systemctl restart "${SERVICE_NAME}.service"; systemctl restart "${CF_SERVICE_NAME}.service"; sleep 2; status_cmd; }
logs_cmd(){ require_root; journalctl -u "${SERVICE_NAME}.service" -u "${CF_SERVICE_NAME}.service" -n 150 --no-pager; }
uninstall_cmd(){ require_root; systemctl disable --now "${CF_SERVICE_NAME}.service" >/dev/null 2>&1 || true; systemctl disable --now "${SERVICE_NAME}.service" >/dev/null 2>&1 || true; rm -f "/etc/systemd/system/${CF_SERVICE_NAME}.service" "/etc/systemd/system/${SERVICE_NAME}.service"; systemctl daemon-reload; rm -f "$SING_BOX_BIN" "$CLOUDFLARED_BIN" "$WGCF_BIN" "${BIN_DIR}/sb"; rm -rf "$INSTALL_DIR"; log "已卸载。"; }

menu(){
  cat <<'EOF'
sing-box-google
1) 一键安装 / 重装
2) 查看状态
3) 显示 / 刷新 FlClash 配置
4) 重启服务
5) 查看日志
6) 卸载
0) 退出
EOF
  read -r -p "请选择: " choice
  case "$choice" in 1) install_all;; 2) status_cmd;; 3) show_cmd;; 4) restart_cmd;; 5) logs_cmd;; 6) uninstall_cmd;; 0) exit 0;; *) die "无效选择。";; esac
}

main(){
  case "${1:-}" in
    install) install_all;; status) status_cmd;; show) show_cmd;; restart) restart_cmd;; logs) logs_cmd;; uninstall) uninstall_cmd;;
    "") if [[ -t 0 ]]; then menu; else install_all; fi ;;
    *) echo "用法: sb {install|status|show|restart|logs|uninstall}"; exit 1;;
  esac
}
main "$@"
