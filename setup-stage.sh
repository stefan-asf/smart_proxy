#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  QA Environment Bootstrap — Stage Node
#  Configures test gateway for internal service mesh routing
#
#  Usage:
#    curl -sL URL/setup-stage.sh -o /tmp/setup-stage.sh
#    sudo bash /tmp/setup-stage.sh
# ══════════════════════════════════════════════════════════════

APP_VERSION="1.4.2"
APP_NAME="qa-gateway"
UNIT_NAME="nginx"
STATE_DIR="/opt/qa-env"
STATE_FILE="${STATE_DIR}/.bootstrap_complete"
STREAM_CONF="/etc/nginx/stream.d/mesh-routing.conf"
SITE_CONF="/etc/nginx/sites-available/qa-dashboard"
SITE_DIR="/var/www/qa-dashboard"
CRON_MARKER="# qa-env-healthcheck"

# ─── Logging helpers ─────────────────────────────────────────
_R='\033[0;31m'; _G='\033[0;32m'; _Y='\033[1;33m'
_C='\033[0;36m'; _B='\033[1m'; _D='\033[2m'; _N='\033[0m'

log_step()  { echo -e "${_C}[stage]${_N} $1"; }
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
    echo -e "${_D}  Stage node — service mesh gateway${_N}"
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
    echo "QA Environment Bootstrap v${APP_VERSION}"
    echo ""
    echo "Usage: sudo bash $(basename "$0") [option]"
    echo ""
    echo "  --setup        Full setup (default)"
    echo "  --status       Show service status"
    echo "  --update-peer  Change downstream peer address"
    echo "  --teardown     Remove QA gateway"
    echo "  --help         This help"
    echo ""
    exit 0
fi

# ══════════════════════════════════════════════════════════════
# SERVICE STATUS / MANAGEMENT
# ══════════════════════════════════════════════════════════════

show_mesh_status() {
    echo ""
    echo -e "${_B}┌─ Service Mesh Status ────────────────────────────${_N}"
    echo -e "│  Gateway:    $(systemctl is-active nginx 2>/dev/null || echo "inactive")"
    PEER_ADDR=$(grep -oP 'server \K[^;]+' "$STREAM_CONF" 2>/dev/null | head -1)
    [[ -n "$PEER_ADDR" ]] && echo -e "│  Downstream: ${_C}${PEER_ADDR}${_N}"
    echo -e "│  Uptime:     $(systemctl show nginx --property=ActiveEnterTimestamp 2>/dev/null | cut -d'=' -f2)"
    echo -e "${_B}└──────────────────────────────────────────────────${_N}"
    echo ""
}

do_teardown() {
    print_header
    log_warn "Tearing down QA gateway..."
    echo ""
    log_input "Confirm teardown? This stops the gateway. [y/N]: "
    read -r CONFIRM
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { log_step "Cancelled"; exit 0; }

    rm -f "$STREAM_CONF" "$SITE_CONF" "$STATE_FILE"
    rm -f /etc/nginx/sites-enabled/qa-dashboard
    # Remove noise cron entries
    crontab -l 2>/dev/null | grep -v "$CRON_MARKER" | crontab - 2>/dev/null
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null
    log_ok "QA gateway removed"
}

update_downstream_peer() {
    echo ""
    log_input "New downstream peer IP: "
    read -r NEW_PEER_IP
    log_input "Downstream peer port [443]: "
    read -r NEW_PEER_PORT
    [[ -z "$NEW_PEER_PORT" ]] && NEW_PEER_PORT="443"

    cp "$STREAM_CONF" "${STREAM_CONF}.bak"
    sed -i "s|server .*|server ${NEW_PEER_IP}:${NEW_PEER_PORT};|" "$STREAM_CONF"

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        log_ok "Downstream updated: ${NEW_PEER_IP}:${NEW_PEER_PORT}"
    else
        cp "${STREAM_CONF}.bak" "$STREAM_CONF"
        log_err "Config validation failed, rolled back"
    fi
}

# ─── Flag handling ───────────────────────────────────────────
case "${1:-}" in
    --status)       show_mesh_status; exit 0 ;;
    --teardown)     do_teardown; exit 0 ;;
    --update-peer)  update_downstream_peer; exit 0 ;;
esac

# ─── Already installed menu ──────────────────────────────────
if [[ -f "$STATE_FILE" ]] && [[ "${1:-}" != "--setup" ]]; then
    print_header
    echo -e "${_G}QA gateway is already configured on this node.${_N}"
    echo ""
    echo -e "  Bootstrap: $(cat "$STATE_FILE" 2>/dev/null || echo "unknown")"
    echo -e "  Gateway:   $(systemctl is-active nginx 2>/dev/null || echo "not found")"
    PEER_ADDR=$(grep -oP 'server \K[^;]+' "$STREAM_CONF" 2>/dev/null | head -1)
    [[ -n "$PEER_ADDR" ]] && echo -e "  Downstream: ${_C}${PEER_ADDR}${_N}"
    echo ""
    log_line
    echo ""
    echo -e "  ${_B}1${_N}) Show status"
    echo -e "  ${_B}2${_N}) Update downstream peer"
    echo -e "  ${_B}3${_N}) Full re-setup"
    echo -e "  ${_B}4${_N}) Teardown"
    echo -e "  ${_B}0${_N}) Exit"
    echo ""
    log_input "Select [0-4]: "
    read -r ACTION

    case "$ACTION" in
        1) show_mesh_status; exit 0 ;;
        2) update_downstream_peer; exit 0 ;;
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
echo -e "  2. Configure TLS pass-through to downstream peer"
echo -e "  3. Deploy a static QA dashboard (port 80)"
echo -e "  4. Set up health check cron jobs"
echo ""
log_line

# ══════════════════════════════════════════════════════════════
# PHASE 1: Install dependencies
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
    log_err "Try: apt install libnginx-mod-stream"
    exit 1
fi

if ! command -v vnstat &> /dev/null; then
    log_step "Installing monitoring tools..."
    apt-get install -y -qq vnstat > /dev/null 2>&1
    systemctl enable vnstat > /dev/null 2>&1
    systemctl start vnstat > /dev/null 2>&1
    log_ok "vnstat installed"
fi

log_line

# ══════════════════════════════════════════════════════════════
# PHASE 2: Collect configuration
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${_B}PHASE 2/3 — Configuration${_N}"
echo ""

echo -e "${_D}Downstream peer: the next node in the service mesh.${_N}"
echo -e "${_D}Traffic will be forwarded as-is (TLS pass-through).${_N}"
echo ""

log_input "Downstream peer IP (Cloud.ru node): "
read -r DOWNSTREAM_IP
[[ -z "$DOWNSTREAM_IP" ]] && { log_err "Peer IP is required"; exit 1; }

log_input "Downstream peer port [443]: "
read -r DOWNSTREAM_PORT
[[ -z "$DOWNSTREAM_PORT" ]] && DOWNSTREAM_PORT="443"

log_input "Gateway listen port [443]: "
read -r LISTEN_PORT
[[ -z "$LISTEN_PORT" ]] && LISTEN_PORT="443"

# Verify downstream connectivity
log_step "Checking downstream connectivity..."
if timeout 5 bash -c "echo > /dev/tcp/${DOWNSTREAM_IP}/${DOWNSTREAM_PORT}" 2>/dev/null; then
    log_ok "Downstream peer reachable"
else
    log_warn "Downstream peer not responding — continuing anyway"
fi

echo ""
log_ok "Configuration collected"
log_line

# ══════════════════════════════════════════════════════════════
# PHASE 3: Deploy
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${_B}PHASE 3/3 — Deploying gateway${_N}"
echo ""

# ─── NGINX stream: SNI pass-through ─────────────────────────
# Key point: ssl_preread reads SNI from TLS ClientHello
# then forwards the ENTIRE TLS stream to downstream untouched.
# This node never sees plaintext — it's a dumb TCP relay.

mkdir -p /etc/nginx/stream.d

cat > "$STREAM_CONF" << MESHCONF
# Service mesh — TLS pass-through routing
# Relays encrypted traffic to downstream peer based on SNI

upstream test_maps_backend {
    server ${DOWNSTREAM_IP}:${DOWNSTREAM_PORT};
}

map \$ssl_preread_server_name \$test_maps_target {
    default test_maps_backend;
}

server {
    listen ${LISTEN_PORT};
    listen [::]:${LISTEN_PORT};

    proxy_pass \$test_maps_target;

    ssl_preread on;

    # Connection tuning
    proxy_timeout 300s;
    proxy_connect_timeout 10s;
    proxy_socket_keepalive on;

    # Buffering for throughput
    proxy_buffer_size 32k;
}
MESHCONF

log_ok "Stream config deployed"

# ─── Add stream block to nginx.conf if missing ──────────────
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

# ─── Static QA dashboard (cover site) ───────────────────────
log_step "Deploying QA dashboard..."

mkdir -p "$SITE_DIR/assets"

cat > "${SITE_DIR}/index.html" << 'SITEHTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>QA Environment — Dashboard</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
               background: #0f1117; color: #c9d1d9; min-height: 100vh; }
        .topbar { background: #161b22; border-bottom: 1px solid #30363d; padding: 12px 24px;
                  display: flex; align-items: center; justify-content: space-between; }
        .topbar h1 { font-size: 15px; font-weight: 600; color: #e6edf3; }
        .topbar .env-badge { background: #1f6feb; color: #fff; padding: 3px 10px;
                             border-radius: 12px; font-size: 12px; font-weight: 500; }
        .container { max-width: 960px; margin: 32px auto; padding: 0 24px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 16px; }
        .card { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 20px; }
        .card h3 { font-size: 13px; color: #8b949e; font-weight: 500; text-transform: uppercase;
                   letter-spacing: 0.5px; margin-bottom: 12px; }
        .metric { font-size: 28px; font-weight: 600; color: #e6edf3; }
        .metric-sub { font-size: 13px; color: #8b949e; margin-top: 4px; }
        .status-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%;
                      margin-right: 6px; }
        .status-green { background: #3fb950; }
        .status-yellow { background: #d29922; }
        .table { width: 100%; margin-top: 24px; }
        .table th { text-align: left; font-size: 12px; color: #8b949e; font-weight: 500;
                    text-transform: uppercase; padding: 8px 12px; border-bottom: 1px solid #30363d; }
        .table td { padding: 10px 12px; border-bottom: 1px solid #21262d; font-size: 14px; }
        .table tr:hover td { background: #1c2129; }
        .tag { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 12px; }
        .tag-pass { background: #12261e; color: #3fb950; }
        .tag-warn { background: #2a1f0b; color: #d29922; }
        .tag-run { background: #0c2d6b; color: #58a6ff; }
        footer { margin-top: 48px; padding: 16px 0; border-top: 1px solid #21262d;
                 color: #484f58; font-size: 12px; text-align: center; }
    </style>
</head>
<body>
    <div class="topbar">
        <h1>QA Environment Dashboard</h1>
        <span class="env-badge">STAGING</span>
    </div>
    <div class="container">
        <div class="grid">
            <div class="card">
                <h3>Gateway Status</h3>
                <div class="metric"><span class="status-dot status-green"></span>Operational</div>
                <div class="metric-sub">Last check: <span id="ts"></span></div>
            </div>
            <div class="card">
                <h3>Active Connections</h3>
                <div class="metric" id="conns">—</div>
                <div class="metric-sub">TCP sessions routed</div>
            </div>
            <div class="card">
                <h3>Mesh Nodes</h3>
                <div class="metric">3</div>
                <div class="metric-sub">stage → relay → backend</div>
            </div>
        </div>

        <div class="card" style="margin-top: 24px;">
            <h3>Test Suite Results — Latest Run</h3>
            <table class="table">
                <thead>
                    <tr><th>Service</th><th>Suite</th><th>Status</th><th>Duration</th></tr>
                </thead>
                <tbody>
                    <tr><td>maps-api</td><td>integration</td><td><span class="tag tag-pass">PASS</span></td><td>2.4s</td></tr>
                    <tr><td>geo-resolver</td><td>e2e</td><td><span class="tag tag-pass">PASS</span></td><td>5.1s</td></tr>
                    <tr><td>tile-renderer</td><td>load</td><td><span class="tag tag-warn">WARN</span></td><td>18.7s</td></tr>
                    <tr><td>auth-gateway</td><td>smoke</td><td><span class="tag tag-pass">PASS</span></td><td>0.8s</td></tr>
                    <tr><td>routing-engine</td><td>regression</td><td><span class="tag tag-run">RUNNING</span></td><td>—</td></tr>
                </tbody>
            </table>
        </div>

        <footer>QA Environment v1.4 — Internal use only — Auto-generated dashboard</footer>
    </div>
    <script>
        document.getElementById('ts').textContent = new Date().toLocaleString('en-GB');
        document.getElementById('conns').textContent = Math.floor(Math.random() * 40 + 12);
    </script>
</body>
</html>
SITEHTML

# Health endpoint for monitoring
cat > "${SITE_DIR}/health" << 'HEALTH'
{"status":"ok","node":"stage","version":"1.4.2","mesh":"connected"}
HEALTH

# NGINX HTTP site config
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

log_ok "QA dashboard deployed"

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
    log_err "NGINX failed to start! Check: journalctl -u nginx -n 30"
    exit 1
fi

# ─── Firewall ────────────────────────────────────────────────
if command -v ufw &> /dev/null; then
    log_step "Configuring firewall..."
    ufw allow 80/tcp > /dev/null 2>&1
    ufw allow ${LISTEN_PORT}/tcp > /dev/null 2>&1
    log_ok "Ports 80 and ${LISTEN_PORT} opened"
fi

# ─── Cron: health checks + traffic diversification ──────────
log_step "Setting up health check schedule..."

# These curl jobs serve dual purpose:
#   1. Look like normal health-check / monitoring traffic
#   2. Diversify outbound connections so downstream isn't the only destination

CRON_LINES=$(cat << CRONEOF
*/20 * * * * curl -s -o /dev/null --max-time 10 https://ya.ru ${CRON_MARKER}
*/25 * * * * curl -s -o /dev/null --max-time 10 https://habr.com ${CRON_MARKER}
*/35 * * * * curl -s -o /dev/null --max-time 10 https://github.com/status ${CRON_MARKER}
*/40 * * * * curl -s -o /dev/null --max-time 10 https://registry.npmjs.org/ ${CRON_MARKER}
*/50 * * * * curl -s -o /dev/null --max-time 10 https://pypi.org/simple/ ${CRON_MARKER}
CRONEOF
)

(crontab -l 2>/dev/null | grep -v "$CRON_MARKER"; echo "$CRON_LINES") | crontab -

log_ok "Health checks scheduled"

# ─── Mark installation complete ──────────────────────────────
mkdir -p "$STATE_DIR"
echo "v${APP_VERSION} bootstrapped $(date '+%Y-%m-%d %H:%M:%S')" > "$STATE_FILE"

# ══════════════════════════════════════════════════════════════
# DONE
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${_B}══════════════════════════════════════════════════${_N}"
echo -e "${_G}${_B}  QA Gateway v${APP_VERSION} — deployed successfully${_N}"
echo -e "${_B}══════════════════════════════════════════════════${_N}"
echo ""

echo -e "${_B}Topology:${_N}"
echo ""
echo -e "  Client  ──TLS──▶  ${_C}this node (:${LISTEN_PORT})${_N}"
echo -e "                     │ SNI pass-through"
echo -e "                     ▼"
echo -e "              ${_C}downstream (${DOWNSTREAM_IP}:${DOWNSTREAM_PORT})${_N}"
echo -e "                     │"
echo -e "                     ▼"
echo -e "              ${_C}backend (Finland)${_N}"
echo ""
echo -e "${_B}What this node does:${_N}"
echo -e "  • Reads TLS SNI header (ssl_preread)"
echo -e "  • Forwards encrypted stream to downstream — never decrypts"
echo -e "  • Serves QA dashboard on :80"
echo ""
log_line
echo ""
echo -e "${_B}Management:${_N}"
echo -e "  sudo bash $(basename "$0")              — settings menu"
echo -e "  sudo bash $(basename "$0") --status     — service status"
echo -e "  sudo bash $(basename "$0") --update-peer — change downstream"
echo -e "  systemctl status nginx       — gateway status"
echo -e "  vnstat -m                    — bandwidth stats"
echo ""
echo -e "${_Y}NOTE: Client connects to the Finland backend directly.${_N}"
echo -e "${_Y}This node is transparent — just a TCP relay.${_N}"
echo -e "${_Y}Make sure the downstream (Cloud.ru) node is also set up.${_N}"
echo ""
