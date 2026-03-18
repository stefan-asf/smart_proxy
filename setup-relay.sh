#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  QA Environment Bootstrap — Relay Node
#  Configures intermediate relay for service mesh routing
#
#  Usage:
#    curl -sL URL/setup-relay.sh -o /tmp/setup-relay.sh
#    sudo bash /tmp/setup-relay.sh
# ══════════════════════════════════════════════════════════════

APP_VERSION="1.4.2"
APP_NAME="qa-relay"
STATE_DIR="/opt/qa-env"
STATE_FILE="${STATE_DIR}/.bootstrap_complete"
STREAM_CONF="/etc/nginx/stream.d/mesh-routing.conf"
SITE_CONF="/etc/nginx/sites-available/qa-dashboard"
SITE_DIR="/var/www/qa-dashboard"
CRON_MARKER="# qa-env-healthcheck"

# ─── Logging helpers ─────────────────────────────────────────
_R='\033[0;31m'; _G='\033[0;32m'; _Y='\033[1;33m'
_C='\033[0;36m'; _B='\033[1m'; _D='\033[2m'; _N='\033[0m'

log_step()  { echo -e "${_C}[relay]${_N} $1"; }
log_ok()    { echo -e "${_G}[  ok ]${_N} $1"; }
log_warn()  { echo -e "${_Y}[ warn]${_N} $1"; }
log_err()   { echo -e "${_R}[error]${_N} $1"; }
log_input() { echo -ne "${_B}$1${_N}"; }
log_line()  { echo -e "${_D}─────────────────────────────────────────────────${_N}"; }

print_header() {
    clear
    echo ""
    echo -e "${_B}══════════════════════════════════════════════════${_N}"
    echo -e "${_B}  QA Environment Bootstrap v${APP_VERSION}${_N}"
    echo -e "${_D}  Relay node — service mesh forwarder${_N}"
    echo -e "${_B}══════════════════════════════════════════════════${_N}"
    echo ""
}

# ─── Root check ──────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    log_err "Run as root: sudo bash $(basename "$0")"
    exit 1
fi

# ─── Help ────────────────────────────────────────────────────
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo ""
    echo "QA Environment Bootstrap v${APP_VERSION} — Relay node"
    echo ""
    echo "Usage: sudo bash $(basename "$0") [option]"
    echo ""
    echo "  --setup         Full setup (default)"
    echo "  --status        Show service status"
    echo "  --update-peer   Change backend address"
    echo "  --teardown      Remove relay"
    echo "  --help          This help"
    echo ""
    exit 0
fi

# ══════════════════════════════════════════════════════════════
# MANAGEMENT FUNCTIONS
# ══════════════════════════════════════════════════════════════

show_mesh_status() {
    echo ""
    echo -e "${_B}┌─ Relay Node Status ─────────────────────────────${_N}"
    echo -e "│  NGINX:     $(systemctl is-active nginx 2>/dev/null || echo "inactive")"
    PEER_ADDR=$(grep -oP 'server \K[^;]+' "$STREAM_CONF" 2>/dev/null | head -1)
    [[ -n "$PEER_ADDR" ]] && echo -e "│  Backend:   ${_C}${PEER_ADDR}${_N}"
    echo -e "│  Uptime:    $(systemctl show nginx --property=ActiveEnterTimestamp 2>/dev/null | cut -d'=' -f2)"
    echo -e "${_B}└──────────────────────────────────────────────────${_N}"
    echo ""
}

do_teardown() {
    print_header
    log_warn "Tearing down relay node..."
    echo ""
    log_input "Confirm teardown? [y/N]: "
    read -r CONFIRM
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { log_step "Cancelled"; exit 0; }

    rm -f "$STREAM_CONF" "$SITE_CONF" "$STATE_FILE"
    rm -f /etc/nginx/sites-enabled/qa-dashboard
    crontab -l 2>/dev/null | grep -v "$CRON_MARKER" | crontab - 2>/dev/null
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null
    log_ok "Relay removed"
}

update_backend_peer() {
    echo ""
    log_input "New backend IP (Finland): "
    read -r NEW_PEER_IP
    log_input "Backend port [443]: "
    read -r NEW_PEER_PORT
    [[ -z "$NEW_PEER_PORT" ]] && NEW_PEER_PORT="443"

    cp "$STREAM_CONF" "${STREAM_CONF}.bak"
    sed -i "s|server .*|server ${NEW_PEER_IP}:${NEW_PEER_PORT};|" "$STREAM_CONF"

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        log_ok "Backend updated: ${NEW_PEER_IP}:${NEW_PEER_PORT}"
    else
        cp "${STREAM_CONF}.bak" "$STREAM_CONF"
        log_err "Config validation failed, rolled back"
    fi
}

# ─── Flag handling ───────────────────────────────────────────
case "${1:-}" in
    --status)      show_mesh_status; exit 0 ;;
    --teardown)    do_teardown; exit 0 ;;
    --update-peer) update_backend_peer; exit 0 ;;
esac

# ─── Already installed menu ──────────────────────────────────
if [[ -f "$STATE_FILE" ]] && [[ "${1:-}" != "--setup" ]]; then
    print_header
    echo -e "${_G}Relay node is already configured.${_N}"
    echo ""
    echo -e "  Bootstrap: $(cat "$STATE_FILE" 2>/dev/null || echo "unknown")"
    echo -e "  NGINX:     $(systemctl is-active nginx 2>/dev/null || echo "not found")"
    PEER_ADDR=$(grep -oP 'server \K[^;]+' "$STREAM_CONF" 2>/dev/null | head -1)
    [[ -n "$PEER_ADDR" ]] && echo -e "  Backend:   ${_C}${PEER_ADDR}${_N}"
    echo ""
    log_line
    echo ""
    echo -e "  ${_B}1${_N}) Show status"
    echo -e "  ${_B}2${_N}) Update backend address"
    echo -e "  ${_B}3${_N}) Full re-setup"
    echo -e "  ${_B}4${_N}) Teardown"
    echo -e "  ${_B}0${_N}) Exit"
    echo ""
    log_input "Select [0-4]: "
    read -r ACTION

    case "$ACTION" in
        1) show_mesh_status; exit 0 ;;
        2) update_backend_peer; exit 0 ;;
        3) log_warn "Starting full re-setup..."; sleep 1 ;;
        4) do_teardown; exit 0 ;;
        *) exit 0 ;;
    esac
fi

# ══════════════════════════════════════════════════════════════
# FULL SETUP
# ══════════════════════════════════════════════════════════════

print_header
echo -e "This script will:"
echo -e "  1. Install NGINX with stream module"
echo -e "  2. Configure TLS pass-through to backend"
echo -e "  3. Deploy relay dashboard (port 80)"
echo -e "  4. Set up health checks"
echo ""
log_line

# ══════════════════════════════════════════════════════════════
# PHASE 1: Install
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${_B}PHASE 1/3 — Installing dependencies${_N}"
echo ""

log_step "Updating package index..."
apt-get update -qq

log_step "Installing nginx + stream module..."
apt-get install -y -qq nginx libnginx-mod-stream > /dev/null 2>&1

if nginx -V 2>&1 | grep -q "stream"; then
    log_ok "NGINX installed, stream module available"
else
    log_err "NGINX stream module not found"
    exit 1
fi

if ! command -v vnstat &> /dev/null; then
    log_step "Installing monitoring tools..."
    apt-get install -y -qq vnstat > /dev/null 2>&1
    systemctl enable vnstat > /dev/null 2>&1
    systemctl start vnstat > /dev/null 2>&1
    log_ok "vnstat installed"
fi

# ─── Stop 3X-UI if present (frees port 443) ─────────────────
if systemctl is-active --quiet x-ui 2>/dev/null; then
    log_step "Stopping existing panel service..."
    systemctl stop x-ui
    systemctl disable x-ui
    log_ok "Panel service stopped"
elif systemctl list-unit-files 2>/dev/null | grep -q x-ui; then
    systemctl disable x-ui 2>/dev/null || true
    log_ok "Panel service disabled"
fi

log_line

# ══════════════════════════════════════════════════════════════
# PHASE 2: Configuration
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${_B}PHASE 2/3 — Configuration${_N}"
echo ""

echo -e "${_D}Backend: the final node in the mesh (Finland).${_N}"
echo -e "${_D}Traffic is forwarded as-is (TLS pass-through, no decryption).${_N}"
echo ""

log_input "Backend IP (Finland node): "
read -r BACKEND_IP
[[ -z "$BACKEND_IP" ]] && { log_err "Backend IP is required"; exit 1; }

log_input "Backend port [443]: "
read -r BACKEND_PORT
[[ -z "$BACKEND_PORT" ]] && BACKEND_PORT="443"

log_input "Relay listen port [443]: "
read -r LISTEN_PORT
[[ -z "$LISTEN_PORT" ]] && LISTEN_PORT="443"

log_step "Checking backend connectivity..."
if timeout 5 bash -c "echo > /dev/tcp/${BACKEND_IP}/${BACKEND_PORT}" 2>/dev/null; then
    log_ok "Backend reachable"
else
    log_warn "Backend not responding — continuing anyway"
fi

echo ""
log_ok "Configuration collected"
log_line

# ══════════════════════════════════════════════════════════════
# PHASE 3: Deploy
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${_B}PHASE 3/3 — Deploying relay${_N}"
echo ""

# ─── NGINX stream: SNI pass-through to Finland ───────────────
mkdir -p /etc/nginx/stream.d

cat > "$STREAM_CONF" << MESHCONF
# Service mesh relay — TLS pass-through to backend
# Forwards encrypted stream without decryption

upstream test_maps_endpoint {
    server ${BACKEND_IP}:${BACKEND_PORT};
}

map \$ssl_preread_server_name \$test_maps_route {
    default test_maps_endpoint;
}

server {
    listen ${LISTEN_PORT};
    listen [::]:${LISTEN_PORT};

    proxy_pass \$test_maps_route;

    ssl_preread on;

    proxy_timeout 300s;
    proxy_connect_timeout 10s;
    proxy_socket_keepalive on;
    proxy_buffer_size 32k;
}
MESHCONF

log_ok "Stream relay config deployed"

# ─── Stream block in nginx.conf ──────────────────────────────
if ! grep -q "stream {" /etc/nginx/nginx.conf; then
    cat >> /etc/nginx/nginx.conf << 'STBLOCK'

# Service mesh — stream routing
stream {
    include /etc/nginx/stream.d/*.conf;
}
STBLOCK
    log_ok "Stream block added to nginx.conf"
else
    log_ok "Stream block already present"
fi

# ─── Relay dashboard (cover site) ────────────────────────────
log_step "Deploying relay dashboard..."

mkdir -p "$SITE_DIR"

cat > "${SITE_DIR}/index.html" << 'SITEHTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>QA Environment — Relay</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
               background: #0f1117; color: #c9d1d9; min-height: 100vh; }
        .topbar { background: #161b22; border-bottom: 1px solid #30363d; padding: 12px 24px;
                  display: flex; align-items: center; justify-content: space-between; }
        .topbar h1 { font-size: 15px; font-weight: 600; color: #e6edf3; }
        .topbar .env-badge { background: #8957e5; color: #fff; padding: 3px 10px;
                             border-radius: 12px; font-size: 12px; font-weight: 500; }
        .container { max-width: 720px; margin: 32px auto; padding: 0 24px; }
        .card { background: #161b22; border: 1px solid #30363d; border-radius: 8px;
                padding: 20px; margin-bottom: 16px; }
        .card h3 { font-size: 13px; color: #8b949e; font-weight: 500; text-transform: uppercase;
                   letter-spacing: 0.5px; margin-bottom: 12px; }
        .metric { font-size: 28px; font-weight: 600; color: #e6edf3; }
        .metric-sub { font-size: 13px; color: #8b949e; margin-top: 4px; }
        .status-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%;
                      margin-right: 6px; background: #3fb950; }
        .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
        footer { margin-top: 40px; color: #484f58; font-size: 12px; text-align: center; }
    </style>
</head>
<body>
    <div class="topbar">
        <h1>QA Relay Node</h1>
        <span class="env-badge">RELAY</span>
    </div>
    <div class="container">
        <div class="grid">
            <div class="card">
                <h3>Node Status</h3>
                <div class="metric"><span class="status-dot"></span>Forwarding</div>
                <div class="metric-sub">TLS pass-through active</div>
            </div>
            <div class="card">
                <h3>Throughput</h3>
                <div class="metric" id="tp">—</div>
                <div class="metric-sub">requests / min (avg)</div>
            </div>
        </div>
        <div class="card">
            <h3>Mesh Topology</h3>
            <div style="font-family: monospace; font-size: 14px; line-height: 1.8; color: #8b949e;">
                stage-node → <span style="color: #e6edf3; font-weight: 600;">this relay</span> → backend-node
            </div>
        </div>
        <footer>QA Environment v1.4 — Relay — Internal use only</footer>
    </div>
    <script>
        document.getElementById('tp').textContent = Math.floor(Math.random() * 80 + 20);
    </script>
</body>
</html>
SITEHTML

cat > "${SITE_DIR}/health" << 'HEALTH'
{"status":"ok","node":"relay","version":"1.4.2","mesh":"forwarding"}
HEALTH

cat > "$SITE_CONF" << 'HTTPCONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/qa-dashboard;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    location = /health {
        default_type application/json;
        try_files /health =404;
    }

    location = /robots.txt {
        return 200 "User-agent: *\nDisallow: /\n";
        add_header Content-Type text/plain;
    }
}
HTTPCONF

ln -sf "$SITE_CONF" /etc/nginx/sites-enabled/qa-dashboard
rm -f /etc/nginx/sites-enabled/default

log_ok "Relay dashboard deployed"

# ─── Validate and start ──────────────────────────────────────
log_step "Validating NGINX config..."
if nginx -t 2>/dev/null; then
    log_ok "Config valid"
else
    log_err "NGINX config validation failed!"
    nginx -t
    exit 1
fi

systemctl enable nginx > /dev/null 2>&1
systemctl restart nginx

if systemctl is-active --quiet nginx; then
    log_ok "NGINX running"
else
    log_err "NGINX failed to start!"
    exit 1
fi

# ─── Firewall ────────────────────────────────────────────────
if command -v ufw &> /dev/null; then
    log_step "Configuring firewall..."
    ufw allow 80/tcp > /dev/null 2>&1
    ufw allow ${LISTEN_PORT}/tcp > /dev/null 2>&1
    log_ok "Ports 80 and ${LISTEN_PORT} opened"
fi

# ─── Cron: health checks ────────────────────────────────────
log_step "Setting up health checks..."

CRON_LINES=$(cat << CRONEOF
*/25 * * * * curl -s -o /dev/null --max-time 10 https://ya.ru ${CRON_MARKER}
*/30 * * * * curl -s -o /dev/null --max-time 10 https://hub.docker.com ${CRON_MARKER}
*/40 * * * * curl -s -o /dev/null --max-time 10 https://api.github.com/zen ${CRON_MARKER}
*/45 * * * * curl -s -o /dev/null --max-time 10 https://registry.npmjs.org/ ${CRON_MARKER}
CRONEOF
)

(crontab -l 2>/dev/null | grep -v "$CRON_MARKER"; echo "$CRON_LINES") | crontab -

log_ok "Health checks scheduled"

# ─── Mark installation ───────────────────────────────────────
mkdir -p "$STATE_DIR"
echo "v${APP_VERSION} relay $(date '+%Y-%m-%d %H:%M:%S')" > "$STATE_FILE"

# ══════════════════════════════════════════════════════════════
# DONE
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${_B}══════════════════════════════════════════════════${_N}"
echo -e "${_G}${_B}  QA Relay v${APP_VERSION} — deployed successfully${_N}"
echo -e "${_B}══════════════════════════════════════════════════${_N}"
echo ""

RELAY_IP=$(curl -s4 ifconfig.me 2>/dev/null || echo "THIS_SERVER_IP")

echo -e "${_B}Topology:${_N}"
echo ""
echo -e "  Stage (Yandex)  ──TLS──▶  ${_C}this relay (:${LISTEN_PORT})${_N}"
echo -e "                              │ SNI pass-through"
echo -e "                              ▼"
echo -e "                        ${_C}backend (${BACKEND_IP}:${BACKEND_PORT})${_N}"
echo ""
echo -e "${_B}What this node does:${_N}"
echo -e "  • Receives TCP from stage node (Yandex)"
echo -e "  • Reads SNI, forwards encrypted stream to backend"
echo -e "  • Never decrypts traffic"
echo -e "  • Serves relay dashboard on :80"
echo ""
log_line
echo ""
echo -e "${_B}Management:${_N}"
echo -e "  sudo bash $(basename "$0")              — settings menu"
echo -e "  sudo bash $(basename "$0") --status     — status"
echo -e "  sudo bash $(basename "$0") --update-peer — change backend"
echo -e "  systemctl status nginx       — NGINX status"
echo -e "  vnstat -m                    — bandwidth"
echo ""
echo -e "${_Y}IMPORTANT: Update the Stage node (Yandex) to point${_N}"
echo -e "${_Y}downstream to this relay: ${RELAY_IP}:${LISTEN_PORT}${_N}"
echo ""
