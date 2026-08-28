#!/usr/bin/env bash
set -Eeuo pipefail

# sing-box-google: minimal VPS-only 5-in-1 deployment
# 1) VLESS-Reality
# 2) Hysteria2
# 3) AnyTLS
# 4) VLESS-CF-WS (Cloudflare Tunnel)
# 5) Cloudflare WARP egress
#
# Supported: Debian/Ubuntu, amd64/arm64.
# Main configuration is written to /etc/singbox-google.

PROJECT_NAME="sing-box-google"
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
WARP_MODE="${WARP_MODE:-all}"          # all|off
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"
CF_HOST="${CF_HOST:-}"
SERVER_ADDR="${SERVER_ADDR:-}"

GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
BLUE='\033[36m'
RESET='\033[0m'

log() { printf "${GREEN}[+]${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${RESET} %s\n" "$*" >&2; }
die() { printf "${RED}[x]${RESET} %s\n" "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行。"
}

check_os() {
  [[ -f /etc/os-release ]] || die "无法识别系统。仅支持 Debian/Ubuntu。"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) die "当前系统 ${ID:-unknown} 暂不支持；请使用 Debian/Ubuntu。" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

install_dependencies() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl jq openssl tar gzip iproute2
}

download() {
  local url="$1" dest="$2"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 "$url" -o "$dest"
}

install_sing_box() {
  local tmp pkg
  tmp="$(mktemp -d)"
  pkg="sing-box-${SING_BOX_VERSION}-linux-${ARCH}"
  log "安装 sing-box ${SING_BOX_VERSION} (${ARCH})"
  download \
    "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${pkg}.tar.gz" \
    "${tmp}/sing-box.tar.gz"
  tar -xzf "${tmp}/sing-box.tar.gz" -C "$tmp"
  install -m 0755 "${tmp}/${pkg}/sing-box" "$SING_BOX_BIN"
  rm -rf "$tmp"
  "$SING_BOX_BIN" version >/dev/null
}

install_cloudflared() {
  log "安装 cloudflared ${CLOUDFLARED_VERSION} (${ARCH})"
  download \
    "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${ARCH}" \
    "$CLOUDFLARED_BIN"
  chmod 0755 "$CLOUDFLARED_BIN"
  "$CLOUDFLARED_BIN" --version >/dev/null
}

install_wgcf() {
  log "安装 wgcf ${WGCF_VERSION} (${ARCH})"
  download \
    "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${ARCH}" \
    "$WGCF_BIN"
  chmod 0755 "$WGCF_BIN"
  "$WGCF_BIN" --version >/dev/null
}

install_cli() {
  if curl -fsSL --connect-timeout 10 --max-time 60 "$SELF_URL" -o "${BIN_DIR}/sb"; then
    chmod 0755 "${BIN_DIR}/sb"
  else
    warn "无法写入快捷命令 sb；主服务不受影响。"
  fi
}

port_in_use() {
  local proto="$1" port="$2"
  if [[ "$proto" == "udp" ]]; then
    ss -H -lun 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}$"
  else
    ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
  fi
}

stop_existing_services() {
  systemctl stop "${CF_SERVICE_NAME}.service" >/dev/null 2>&1 || true
  systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
}

check_ports() {
  local failed=0
  for item in "tcp:${REALITY_PORT}" "udp:${HY2_PORT}" "tcp:${ANYTLS_PORT}" "tcp:${WS_PORT}"; do
    local proto="${item%%:*}" port="${item##*:}"
    if port_in_use "$proto" "$port"; then
      warn "${proto^^} 端口 ${port} 已被占用。可通过环境变量修改端口后重试。"
      failed=1
    fi
  done
  [[ "$failed" -eq 0 ]] || die "存在端口冲突。"
}

generate_certificate() {
  mkdir -p "$INSTALL_DIR"
  chmod 0700 "$INSTALL_DIR"
  if [[ ! -s "$CERT_FILE" || ! -s "$KEY_FILE" ]]; then
    log "生成 Hysteria2 / AnyTLS 自签证书"
    openssl req -x509 -nodes -newkey ec \
      -pkeyopt ec_paramgen_curve:prime256v1 \
      -days 3650 \
      -keyout "$KEY_FILE" \
      -out "$CERT_FILE" \
      -subj "/CN=${TLS_SNI}" >/dev/null 2>&1
    chmod 0600 "$KEY_FILE"
    chmod 0644 "$CERT_FILE"
  fi
}

random_hex() { openssl rand -hex "${1:-16}"; }

generate_credentials() {
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

  [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] \
    || die "Reality 密钥生成失败。"
}

provision_warp() {
  WARP_ENABLED="false"
  WARP_PRIVATE_KEY=""
  WARP_ADDRESS4=""
  WARP_ADDRESS6=""
  WARP_PEER_PUBLIC_KEY=""
  WARP_PEER_PORT="2408"
  WARP_SERVER=""

  [[ "$WARP_MODE" != "off" ]] || {
    warn "WARP_MODE=off：跳过 CF WARP。"
    return 0
  }

  local warp_dir="${INSTALL_DIR}/warp"
  mkdir -p "$warp_dir"
  chmod 0700 "$warp_dir"

  log "注册 Cloudflare WARP"
  (
    if [[ ! -s "${warp_dir}/wgcf-account.toml" ]]; then
      "$WGCF_BIN" register --accept-tos --config "${warp_dir}/wgcf-account.toml"
    fi
    "$WGCF_BIN" generate \
      --config "${warp_dir}/wgcf-account.toml" \
      --profile "${warp_dir}/wgcf-profile.conf"
  ) || {
    warn "WARP 注册/配置失败，将继续安装四个代理入口，但 WARP 出站关闭。"
    return 0
  }

  local profile="${warp_dir}/wgcf-profile.conf"
  [[ -s "$profile" ]] || {
    warn "未生成 WARP profile，将关闭 WARP 出站。"
    return 0
  }

  WARP_PRIVATE_KEY="$(awk -F' *= *' '/^PrivateKey *=/ {print $2; exit}' "$profile")"
  WARP_PEER_PUBLIC_KEY="$(awk -F' *= *' '/^PublicKey *=/ {print $2; exit}' "$profile")"
  WARP_PEER_PORT="$(awk -F' *= *' '/^Endpoint *=/ {gsub(/\r/,"",$2); sub(/^.*:/,"",$2); print $2; exit}' "$profile")"
  [[ "$WARP_PEER_PORT" =~ ^[0-9]+$ ]] || WARP_PEER_PORT="2408"

  local address_line
  address_line="$(awk -F' *= *' '/^Address *=/ {print $2; exit}' "$profile")"
  WARP_ADDRESS4="$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' <<<"$address_line" | head -n1 || true)"
  WARP_ADDRESS6="$(grep -oE '([0-9A-Fa-f]{0,4}:){2,}[0-9A-Fa-f:]+/[0-9]+' <<<"$address_line" | head -n1 || true)"

  if curl -4fsS --connect-timeout 3 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
    WARP_SERVER="162.159.192.1"
  elif curl -6fsS --connect-timeout 3 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
    WARP_SERVER="2606:4700:d0::a29f:c001"
  fi

  if [[ -z "$WARP_PRIVATE_KEY" || -z "$WARP_PEER_PUBLIC_KEY" || -z "$WARP_ADDRESS4$WARP_ADDRESS6" || -z "$WARP_SERVER" ]]; then
    warn "WARP profile 不完整，将关闭 WARP 出站。"
    return 0
  fi

  WARP_ENABLED="true"
  log "CF WARP 已就绪，将作为 VPS 代理流量默认出口。"
}

generate_singbox_config() {
  local route_final="direct"
  [[ "$WARP_ENABLED" == "true" ]] && route_final="warp"

  jq -n \
    --argjson reality_port "$REALITY_PORT" \
    --argjson hy2_port "$HY2_PORT" \
    --argjson anytls_port "$ANYTLS_PORT" \
    --argjson ws_port "$WS_PORT" \
    --arg reality_uuid "$REALITY_UUID" \
    --arg ws_uuid "$WS_UUID" \
    --arg hy2_password "$HY2_PASSWORD" \
    --arg hy2_obfs "$HY2_OBFS" \
    --arg anytls_password "$ANYTLS_PASSWORD" \
    --arg reality_sni "$REALITY_SNI" \
    --arg tls_sni "$TLS_SNI" \
    --arg reality_private_key "$REALITY_PRIVATE_KEY" \
    --arg reality_short_id "$REALITY_SHORT_ID" \
    --arg cert "$CERT_FILE" \
    --arg key "$KEY_FILE" \
    --arg ws_path "$WS_PATH" \
    --arg route_final "$route_final" \
    --arg warp_enabled "$WARP_ENABLED" \
    --arg warp_private_key "$WARP_PRIVATE_KEY" \
    --arg warp_address4 "$WARP_ADDRESS4" \
    --arg warp_address6 "$WARP_ADDRESS6" \
    --arg warp_server "$WARP_SERVER" \
    --argjson warp_port "$WARP_PEER_PORT" \
    --arg warp_public_key "$WARP_PEER_PUBLIC_KEY" \
    '
    {
      log: {level: "warn", timestamp: true},
      dns: {
        servers: [{type: "local", tag: "local-dns"}],
        final: "local-dns",
        strategy: "prefer_ipv4"
      },
      inbounds: [
        {
          type: "vless",
          tag: "vless-reality-in",
          listen: "::",
          listen_port: $reality_port,
          users: [{name: "default", uuid: $reality_uuid, flow: "xtls-rprx-vision"}],
          tls: {
            enabled: true,
            server_name: $reality_sni,
            reality: {
              enabled: true,
              handshake: {server: $reality_sni, server_port: 443},
              private_key: $reality_private_key,
              short_id: [$reality_short_id]
            }
          }
        },
        {
          type: "hysteria2",
          tag: "hysteria2-in",
          listen: "::",
          listen_port: $hy2_port,
          users: [{name: "default", password: $hy2_password}],
          obfs: {type: "salamander", password: $hy2_obfs},
          tls: {
            enabled: true,
            alpn: ["h3"],
            certificate_path: $cert,
            key_path: $key
          }
        },
        {
          type: "anytls",
          tag: "anytls-in",
          listen: "::",
          listen_port: $anytls_port,
          users: [{name: "default", password: $anytls_password}],
          tls: {
            enabled: true,
            certificate_path: $cert,
            key_path: $key
          }
        },
        {
          type: "vless",
          tag: "vless-cf-ws-in",
          listen: "127.0.0.1",
          listen_port: $ws_port,
          users: [{name: "default", uuid: $ws_uuid}],
          transport: {type: "ws", path: $ws_path}
        }
      ],
      outbounds: [{type: "direct", tag: "direct"}],
      route: {
        auto_detect_interface: true,
        default_domain_resolver: "local-dns",
        final: $route_final
      }
    }
    + (
      if $warp_enabled == "true" then
        {
          endpoints: [
            {
              type: "wireguard",
              tag: "warp",
              mtu: 1280,
              address: [$warp_address4, $warp_address6] | map(select(length > 0)),
              private_key: $warp_private_key,
              peers: [
                {
                  address: $warp_server,
                  port: $warp_port,
                  public_key: $warp_public_key,
                  allowed_ips: ["0.0.0.0/0", "::/0"],
                  persistent_keepalive_interval: 30
                }
              ]
            }
          ]
        }
      else {}
      end
    )
    ' > "$CONFIG_FILE"

  chmod 0600 "$CONFIG_FILE"
  "$SING_BOX_BIN" check -c "$CONFIG_FILE"
}

write_state() {
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

create_systemd_service() {
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=sing-box-google multi-protocol proxy
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
  systemctl is-active --quiet "${SERVICE_NAME}.service" \
    || { journalctl -u "${SERVICE_NAME}.service" -n 80 --no-pager >&2; die "sing-box 服务启动失败。"; }
}

create_cloudflared_service() {
  cat > "$CF_RUNNER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
INSTALL_DIR="/etc/singbox-google"
# shellcheck disable=SC1091
source "${INSTALL_DIR}/state.env"
if [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then
  exec /usr/local/bin/cloudflared tunnel --no-autoupdate run --token "${CF_TUNNEL_TOKEN}"
else
  exec /usr/local/bin/cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:${WS_PORT}"
fi
EOF
  chmod 0700 "$CF_RUNNER"

  cat > "/etc/systemd/system/${CF_SERVICE_NAME}.service" <<EOF
[Unit]
Description=Cloudflare Tunnel for sing-box VLESS-WS
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
}

get_server_addr() {
  if [[ -n "${SERVER_ADDR:-}" ]]; then
    printf '%s' "$SERVER_ADDR"
    return
  fi

  local v4 v6
  v4="$(curl -4fsS --connect-timeout 5 --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "$v4" ]]; then
    printf '%s' "$v4"
    return
  fi
  v6="$(curl -6fsS --connect-timeout 5 --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
  [[ -n "$v6" ]] && printf '%s' "$v6" && return
  hostname -I | awk '{print $1}'
}

discover_cf_host() {
  # Fixed tunnel: caller supplies the hostname because cloudflared token alone
  # does not expose the dashboard Public Hostname.
  if [[ -n "${CF_TUNNEL_TOKEN:-}" && -n "${CF_HOST:-}" ]]; then
    printf '%s' "$CF_HOST"
    return
  fi

  local host=""
  for _ in $(seq 1 30); do
    host="$(journalctl -u "${CF_SERVICE_NAME}.service" -n 120 --no-pager 2>/dev/null \
      | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' \
      | tail -n1 | sed 's#https://##' || true)"
    [[ -n "$host" ]] && break
    sleep 1
  done
  printf '%s' "$host"
}

yaml_quote() {
  # YAML single-quoted scalar.
  printf "'%s'" "$(sed "s/'/''/g" <<<"$1")"
}

generate_flclash() {
  # shellcheck disable=SC1090
  source "$STATE_FILE"

  local server cfhost
  server="$(get_server_addr)"
  cfhost="$(discover_cf_host)"

  [[ -n "$server" ]] || die "无法检测 VPS 公网地址，请使用 SERVER_ADDR=... 指定。"

  cat > "$FLCLASH_FILE" <<EOF
# Auto-generated by sing-box-google.
# Contains private credentials. Do not publish.
mode: rule
log-level: warning
ipv6: true

dns:
  enable: true
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  use-system-hosts: false
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
    alpn:
      - h3

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
  else
    cat >> "$FLCLASH_FILE" <<'EOF'

  # VLESS-CF-WS tunnel hostname is not ready yet.
  # Run `sb show` after cloudflared obtains a hostname.
EOF
  fi

  cat >> "$FLCLASH_FILE" <<'EOF'

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

  - name: "Auto"
    type: url-test
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 80
    proxies:
      - "VLESS-Reality"
      - "Hysteria2"
      - "AnyTLS"
EOF
  [[ -n "$cfhost" ]] && echo '      - "VLESS-CF-WS"' >> "$FLCLASH_FILE"
  cat >> "$FLCLASH_FILE" <<'EOF'

rules:
  - MATCH,Proxy
EOF

  chmod 0600 "$FLCLASH_FILE"

  # Refresh the persisted values discovered at runtime.
  SERVER_ADDR="$server"
  CF_HOST="$cfhost"
  write_state
}

open_firewall_ports() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${REALITY_PORT}/tcp" >/dev/null
    ufw allow "${HY2_PORT}/udp" >/dev/null
    ufw allow "${ANYTLS_PORT}/tcp" >/dev/null
    log "已在 UFW 放行所需公网端口。"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${REALITY_PORT}/tcp" >/dev/null
    firewall-cmd --permanent --add-port="${HY2_PORT}/udp" >/dev/null
    firewall-cmd --permanent --add-port="${ANYTLS_PORT}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    log "已在 firewalld 放行所需公网端口。"
  else
    warn "未主动修改防火墙。请在云厂商安全组放行 TCP ${REALITY_PORT}, TCP ${ANYTLS_PORT}, UDP ${HY2_PORT}。"
  fi
}

show_summary() {
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  printf "\n${BLUE}================ sing-box-google ================${RESET}\n"
  printf "VLESS-Reality : TCP %s\n" "$REALITY_PORT"
  printf "Hysteria2     : UDP %s\n" "$HY2_PORT"
  printf "AnyTLS        : TCP %s\n" "$ANYTLS_PORT"
  printf "VLESS-CF-WS   : %s%s\n" "${CF_HOST:-等待 Cloudflare Tunnel 分配域名}" "$WS_PATH"
  printf "CF WARP egress: %s\n" "$([[ "$WARP_ENABLED" == "true" ]] && echo ON || echo OFF)"
  printf "FlClash 配置  : %s\n" "$FLCLASH_FILE"
  printf "快捷命令      : sb\n"
  printf "${BLUE}=================================================${RESET}\n\n"
}

install_all() {
  require_root
  check_os
  detect_arch
  install_dependencies
  stop_existing_services
  check_ports
  mkdir -p "$INSTALL_DIR"
  chmod 0700 "$INSTALL_DIR"

  if [[ -n "$CF_TUNNEL_TOKEN" && -z "$CF_HOST" ]]; then
    warn "检测到 CF_TUNNEL_TOKEN，但未设置 CF_HOST；固定隧道可以运行，但 FlClash 暂时无法生成 CF-WS 节点。"
  fi

  install_sing_box
  install_cloudflared
  install_wgcf
  generate_certificate
  generate_credentials
  provision_warp
  generate_singbox_config
  write_state
  create_systemd_service
  create_cloudflared_service
  open_firewall_ports
  generate_flclash
  install_cli
  show_summary
  log "安装完成。运行 'sb show' 查看完整 FlClash 配置。"
}

status_cmd() {
  require_root
  printf "%-30s %s\n" "$SERVICE_NAME" "$(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || true)"
  printf "%-30s %s\n" "$CF_SERVICE_NAME" "$(systemctl is-active "${CF_SERVICE_NAME}.service" 2>/dev/null || true)"
  [[ -f "$STATE_FILE" ]] && show_summary
}

show_cmd() {
  require_root
  [[ -s "$STATE_FILE" ]] || die "尚未安装。"
  generate_flclash
  show_summary
  cat "$FLCLASH_FILE"
}

restart_cmd() {
  require_root
  systemctl restart "${SERVICE_NAME}.service"
  systemctl restart "${CF_SERVICE_NAME}.service"
  sleep 2
  status_cmd
}

logs_cmd() {
  require_root
  journalctl -u "${SERVICE_NAME}.service" -u "${CF_SERVICE_NAME}.service" -n 120 --no-pager
}

uninstall_cmd() {
  require_root
  systemctl disable --now "${CF_SERVICE_NAME}.service" >/dev/null 2>&1 || true
  systemctl disable --now "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${CF_SERVICE_NAME}.service" "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload
  rm -f "$SING_BOX_BIN" "$CLOUDFLARED_BIN" "$WGCF_BIN" "${BIN_DIR}/sb"
  rm -rf "$INSTALL_DIR"
  log "已卸载 sing-box-google。"
}

menu() {
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
  case "$choice" in
    1) install_all ;;
    2) status_cmd ;;
    3) show_cmd ;;
    4) restart_cmd ;;
    5) logs_cmd ;;
    6) uninstall_cmd ;;
    0) exit 0 ;;
    *) die "无效选择。" ;;
  esac
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    install) install_all ;;
    status) status_cmd ;;
    show) show_cmd ;;
    restart) restart_cmd ;;
    logs) logs_cmd ;;
    uninstall) uninstall_cmd ;;
    "" )
      if [[ -t 0 ]]; then
        menu
      else
        install_all
      fi
      ;;
    *)
      cat <<EOF
用法:
  sb install
  sb status
  sb show
  sb restart
  sb logs
  sb uninstall

一键安装:
  bash <(curl -fsSL ${SELF_URL})
EOF
      exit 1
      ;;
  esac
}

main "$@"
