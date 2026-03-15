#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  Smart Proxy Installer — Сервер А
#  Интерактивная установка Xray с раздельной маршрутизацией
# ══════════════════════════════════════════════════════════════

set -e

# ─── Цвета ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "${CYAN}[i]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; }
ask()   { echo -ne "${BOLD}$1${NC}"; }
line()  { echo -e "${DIM}────────────────────────────────────────${NC}"; }

if [[ $EUID -ne 0 ]]; then
    err "Запусти скрипт от root: sudo bash install.sh"
    exit 1
fi

clear
echo ""
echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo -e "${BOLD}  Smart Proxy — Установка на сервер А    ${NC}"
echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo ""
echo -e "Этот скрипт:"
echo -e "  1. Остановит 3X-UI (если есть)"
echo -e "  2. Установит Xray"
echo -e "  3. Сгенерирует ключи Reality и UUID клиента"
echo -e "  4. Настроит маршрутизацию:"
echo -e "     ${DIM}• Заблокированные сервисы → через сервер Б${NC}"
echo -e "     ${DIM}• Всё остальное → напрямую с сервера А${NC}"
echo -e "  5. Установит утилиту manage-routes"
echo ""
line

# ══════════════════════════════════════════════════════════════
# ЭТАП 1: Останавливаем 3X-UI и ставим Xray
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}ЭТАП 1/3 — Установка Xray${NC}"
echo ""

# ─── Останавливаем 3X-UI ─────────────────────────────────────
if systemctl is-active --quiet x-ui 2>/dev/null; then
    info "Останавливаю 3X-UI..."
    systemctl stop x-ui
    systemctl disable x-ui
    ok "3X-UI остановлен"
elif systemctl list-unit-files | grep -q x-ui 2>/dev/null; then
    info "3X-UI найден, но не запущен. Отключаю..."
    systemctl disable x-ui 2>/dev/null || true
    ok "3X-UI отключён"
else
    info "3X-UI не найден"
fi

# ─── Устанавливаем Xray ──────────────────────────────────────
if command -v xray &> /dev/null; then
    CURRENT_VER=$(xray version 2>/dev/null | head -1 || echo "unknown")
    info "Xray уже установлен: ${CURRENT_VER}"
    ask "Переустановить/обновить? [y/N]: "
    read -r REINSTALL
    if [[ "$REINSTALL" == "y" || "$REINSTALL" == "Y" ]]; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        ok "Xray обновлён"
    fi
else
    info "Устанавливаю Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    ok "Xray установлен"
fi

# ─── Geo-файлы ───────────────────────────────────────────────
info "Скачиваю geosite.dat и geoip.dat..."
mkdir -p /usr/local/share/xray
wget -qO /usr/local/share/xray/geosite.dat \
    https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat
wget -qO /usr/local/share/xray/geoip.dat \
    https://github.com/v2fly/geoip/releases/latest/download/geoip.dat
ok "Geo-файлы скачаны"

# ─── vnstat ───────────────────────────────────────────────────
if ! command -v vnstat &> /dev/null; then
    info "Устанавливаю vnstat..."
    apt-get update -qq && apt-get install -y -qq vnstat > /dev/null 2>&1
    systemctl enable vnstat > /dev/null 2>&1
    systemctl start vnstat > /dev/null 2>&1
    ok "vnstat установлен"
fi

line

# ══════════════════════════════════════════════════════════════
# ЭТАП 2: Генерация ключей + сбор данных сервера Б
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}ЭТАП 2/3 — Генерация ключей и настройка${NC}"
echo ""

# ─── Генерируем UUID ──────────────────────────────────────────
CLIENT_UUID=$(xray uuid)
ok "UUID клиента сгенерирован: ${CYAN}${CLIENT_UUID}${NC}"

# ─── Генерируем Reality ключи ─────────────────────────────────
KEYS_OUTPUT=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS_OUTPUT" | grep "Private" | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEYS_OUTPUT" | grep "Public" | awk '{print $NF}')
ok "Reality Private Key: ${DIM}${PRIVATE_KEY}${NC}"
ok "Reality Public Key:  ${CYAN}${PUBLIC_KEY}${NC}"

# ─── Генерируем Short ID ─────────────────────────────────────
SHORT_ID=$(openssl rand -hex 8)
ok "Short ID: ${CYAN}${SHORT_ID}${NC}"

# ─── Reality dest/SNI ─────────────────────────────────────────
echo ""
ask "Reality Target (dest) [ads.x5.ru:443]: "
read -r REALITY_DEST
[[ -z "$REALITY_DEST" ]] && REALITY_DEST="ads.x5.ru:443"

DEFAULT_SNI=$(echo "$REALITY_DEST" | sed 's/:.*$//')
ask "Reality SNI [${DEFAULT_SNI}]: "
read -r REALITY_SNI
[[ -z "$REALITY_SNI" ]] && REALITY_SNI="$DEFAULT_SNI"

ask "Порт inbound [443]: "
read -r INBOUND_PORT
[[ -z "$INBOUND_PORT" ]] && INBOUND_PORT="443"

echo ""
line
echo ""

# ─── Параметры сервера Б — парсинг из VLESS-ссылки ───────────
echo -e "${BOLD}Параметры сервера Б (Финляндия):${NC}"
echo -e "${DIM}Вставь VLESS-ссылку из Remnanode (начинается с vless://)${NC}"
echo ""

ask "VLESS-ссылка сервера Б: "
read -r VLESS_LINK

if [[ ! "$VLESS_LINK" =~ ^vless:// ]]; then
    err "Ссылка должна начинаться с vless://"
    exit 1
fi

# Парсим ссылку: vless://UUID@ADDRESS:PORT?params#name
SERVER_B_UUID=$(echo "$VLESS_LINK" | sed 's|vless://||' | cut -d'@' -f1)
ADDR_PORT=$(echo "$VLESS_LINK" | sed 's|vless://[^@]*@||' | cut -d'?' -f1)
SERVER_B_ADDRESS=$(echo "$ADDR_PORT" | cut -d':' -f1)
SERVER_B_PORT=$(echo "$ADDR_PORT" | cut -d':' -f2)

# Парсим query-параметры
QUERY=$(echo "$VLESS_LINK" | grep -oP '\?\K[^#]+' || echo "")
get_param() { echo "$QUERY" | tr '&' '\n' | grep "^$1=" | cut -d'=' -f2- | sed 's/%2F/\//g'; }

SERVER_B_PATH=$(get_param "path")
SERVER_B_SNI=$(get_param "sni")
SERVER_B_HOST=$(get_param "host")
SERVER_B_MODE=$(get_param "mode")
SERVER_B_FP=$(get_param "fp")
SERVER_B_ALPN=$(get_param "alpn")

[[ -z "$SERVER_B_PATH" ]] && SERVER_B_PATH="/xhttp"
[[ -z "$SERVER_B_SNI" ]] && SERVER_B_SNI="$SERVER_B_ADDRESS"
[[ -z "$SERVER_B_HOST" ]] && SERVER_B_HOST="$SERVER_B_SNI"
[[ -z "$SERVER_B_MODE" ]] && SERVER_B_MODE="auto"
[[ -z "$SERVER_B_FP" ]] && SERVER_B_FP="chrome"
[[ -z "$SERVER_B_ALPN" ]] && SERVER_B_ALPN="h2,http/1.1"

# Конвертируем alpn в JSON массив: "h2,http/1.1" → ["h2","http/1.1"]
ALPN_JSON=$(echo "$SERVER_B_ALPN" | sed 's/,/","/g' | sed 's/^/["/' | sed 's/$/"]/')

echo ""
ok "Распарсено из ссылки:"
echo -e "  Адрес:  ${CYAN}${SERVER_B_ADDRESS}${NC}"
echo -e "  Порт:   ${CYAN}${SERVER_B_PORT}${NC}"
echo -e "  UUID:   ${CYAN}${SERVER_B_UUID}${NC}"
echo -e "  Path:   ${CYAN}${SERVER_B_PATH}${NC}"
echo -e "  SNI:    ${CYAN}${SERVER_B_SNI}${NC}"
echo -e "  Mode:   ${CYAN}${SERVER_B_MODE}${NC}"
echo -e "  ALPN:   ${CYAN}${SERVER_B_ALPN}${NC}"

echo ""
ok "Все параметры собраны"
line

# ══════════════════════════════════════════════════════════════
# ЭТАП 3: Генерация конфига и запуск
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}ЭТАП 3/3 — Генерация конфига${NC}"
echo ""

CONFIG_PATH="/usr/local/etc/xray/config.json"

if [[ -f "$CONFIG_PATH" ]]; then
    cp "$CONFIG_PATH" "${CONFIG_PATH}.backup.$(date +%s)"
    ok "Старый конфиг сохранён в бэкап"
fi

cat > "$CONFIG_PATH" << XRAY_EOF
{
  "log": {
    "access": "none",
    "dnsLog": false,
    "loglevel": "warning"
  },
  "api": {
    "tag": "api",
    "services": ["HandlerService", "LoggerService", "StatsService"]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "statsUserDownlink": true,
        "statsUserUplink": true
      }
    },
    "system": {
      "statsInboundDownlink": true,
      "statsInboundUplink": true,
      "statsOutboundDownlink": true,
      "statsOutboundUplink": true
    }
  },
  "dns": {
    "servers": [
      {
        "address": "https://dns.google/dns-query",
        "skipFallback": true
      },
      {
        "address": "localhost"
      }
    ]
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "outboundTag": "block",
        "ip": ["geoip:private"]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "protocol": ["bittorrent"]
      },
      {
        "type": "field",
        "domain": [
          "domain:youtube.com",
          "domain:youtu.be",
          "domain:googlevideo.com",
          "domain:ytimg.com",
          "domain:ggpht.com",
          "domain:youtube-nocookie.com",
          "domain:youtubei.googleapis.com",

          "domain:instagram.com",
          "domain:cdninstagram.com",
          "domain:facebook.com",
          "domain:fbcdn.net",
          "domain:fb.com",
          "domain:facebook.net",
          "domain:fbsbx.com",
          "domain:whatsapp.com",
          "domain:whatsapp.net",
          "domain:threads.net",

          "domain:twitter.com",
          "domain:x.com",
          "domain:t.co",
          "domain:twimg.com",
          "domain:tweetdeck.com",

          "domain:discord.com",
          "domain:discordapp.com",
          "domain:discord.gg",
          "domain:discordapp.net",
          "domain:discord.media",
          "domain:discordcdn.com",

          "domain:twitch.tv",
          "domain:twitchcdn.net",
          "domain:twitchsvc.net",
          "domain:jtvnw.net",

          "domain:netflix.com",
          "domain:nflxvideo.net",
          "domain:nflximg.net",
          "domain:nflxext.com",
          "domain:nflxso.net",
          "domain:fast.com",

          "domain:spotify.com",
          "domain:spotifycdn.com",
          "domain:scdn.co",

          "domain:openai.com",
          "domain:chatgpt.com",
          "domain:oaiusercontent.com",
          "domain:anthropic.com",
          "domain:claude.ai",
          "domain:gemini.google.com",
          "domain:bard.google.com",
          "domain:deepmind.google",
          "domain:grok.com",
          "domain:x.ai",
          "domain:perplexity.ai",
          "domain:midjourney.com",
          "domain:suno.com",
          "domain:suno.ai",

          "domain:reddit.com",
          "domain:redd.it",
          "domain:redditmedia.com",
          "domain:redditstatic.com",

          "domain:linkedin.com",
          "domain:licdn.com",

          "domain:disneyplus.com",
          "domain:disney-plus.net",
          "domain:hbomax.com",
          "domain:max.com",
          "domain:hbo.com",
          "domain:primevideo.com",

          "domain:soundcloud.com",
          "domain:medium.com",
          "domain:patreon.com",
          "domain:vimeo.com",
          "domain:dailymotion.com",
          "domain:archive.org",

          "domain:rutracker.org",
          "domain:rutracker.net",
          "domain:nnmclub.to",

          "domain:proton.me",
          "domain:protonmail.com",
          "domain:torproject.org",

          "domain:viber.com",
          "domain:pixiv.net",
          "domain:pximg.net",
          "domain:tumblr.com",
          "domain:flickr.com",

          "domain:tiktok.com",
          "domain:tiktokcdn.com",
          "domain:tiktokv.com",
          "domain:musical.ly",

          "domain:steampowered.com",
          "domain:steamcommunity.com",
          "domain:steamstatic.com",
          "domain:steamcdn-a.akamaihd.net"
        ],
        "outboundTag": "proxy-to-b"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "direct"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "api",
      "listen": "127.0.0.1",
      "port": 62789,
      "protocol": "tunnel",
      "settings": {
        "address": "127.0.0.1"
      }
    },
    {
      "tag": "vless-reality",
      "port": ${INBOUND_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${CLIENT_UUID}",
            "email": "me@proxy",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"],
          "spiderX": "/"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": false
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "AsIs"
      }
    },
    {
      "tag": "proxy-to-b",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${SERVER_B_ADDRESS}",
            "port": ${SERVER_B_PORT},
            "users": [
              {
                "id": "${SERVER_B_UUID}",
                "encryption": "none",
                "flow": ""
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${SERVER_B_SNI}",
          "allowInsecure": false,
          "fingerprint": "${SERVER_B_FP}",
          "alpn": ${ALPN_JSON}
        },
        "xhttpSettings": {
          "path": "${SERVER_B_PATH}",
          "host": "${SERVER_B_HOST}",
          "mode": "${SERVER_B_MODE}"
        }
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {
        "response": { "type": "http" }
      }
    }
  ]
}
XRAY_EOF

ok "Конфиг сгенерирован"

# ─── Валидация ────────────────────────────────────────────────
info "Проверяю конфиг..."
if xray run -test -c "$CONFIG_PATH" 2>&1; then
    ok "Конфиг валиден"
else
    err "Ошибка в конфиге!"
    exit 1
fi

# ─── manage-routes ────────────────────────────────────────────
info "Устанавливаю утилиту manage-routes..."

cat > /usr/local/bin/manage-routes << 'MANAGE_SCRIPT'
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo -e "${RED}Запусти от root: sudo manage-routes${NC}"; exit 1; }

case "${1:-}" in
    add)
        [[ -z "${2:-}" ]] && { echo "manage-routes add домен.com"; exit 1; }
        D=$(echo "$2" | sed 's|https\?://||;s|/.*||')
        grep -q "\"domain:${D}\"" "$CONFIG" && { echo -e "${YELLOW}${D} уже есть${NC}"; exit 0; }
        cp "$CONFIG" "${CONFIG}.bak"
        sed -i "/\"outboundTag\": \"proxy-to-b\"/i\\          \"domain:${D}\"," "$CONFIG"
        if xray run -test -c "$CONFIG" > /dev/null 2>&1; then
            systemctl restart xray
            echo -e "${GREEN}✓ ${D} → через сервер Б${NC}"
        else
            cp "${CONFIG}.bak" "$CONFIG"; echo -e "${RED}✗ Ошибка, откат${NC}"
        fi ;;
    remove|rm)
        [[ -z "${2:-}" ]] && { echo "manage-routes remove домен.com"; exit 1; }
        D=$(echo "$2" | sed 's|https\?://||;s|/.*||')
        grep -q "\"domain:${D}\"" "$CONFIG" || { echo -e "${YELLOW}${D} не найден${NC}"; exit 0; }
        cp "$CONFIG" "${CONFIG}.bak"
        sed -i "/\"domain:${D}\"/d" "$CONFIG"
        if xray run -test -c "$CONFIG" > /dev/null 2>&1; then
            systemctl restart xray
            echo -e "${GREEN}✓ ${D} удалён${NC}"
        else
            cp "${CONFIG}.bak" "$CONFIG"; echo -e "${RED}✗ Ошибка, откат${NC}"
        fi ;;
    list|ls)
        echo -e "${CYAN}Домены через сервер Б:${NC}"
        grep -oP '"domain:[^"]+' "$CONFIG" | sed 's/"domain:/  • /'
        echo -e "\n${CYAN}Всего: $(grep -c '"domain:' "$CONFIG")${NC}" ;;
    check)
        [[ -z "${2:-}" ]] && { echo "manage-routes check домен.com"; exit 1; }
        D=$(echo "$2" | sed 's|https\?://||;s|/.*||')
        if grep -q "\"domain:${D}\"" "$CONFIG"; then
            echo -e "${D} → ${CYAN}через сервер Б (зарубежный IP)${NC}"
        else
            echo -e "${D} → ${GREEN}direct (IP сервера А)${NC}"
        fi ;;
    traffic|stats) command -v vnstat &>/dev/null && vnstat -m || echo "apt install vnstat" ;;
    restart) systemctl restart xray && echo -e "${GREEN}✓ Xray перезапущен${NC}" ;;
    test) xray run -test -c "$CONFIG" ;;
    status) systemctl status xray --no-pager -l ;;
    *)
        echo -e "\n${CYAN}manage-routes${NC} — управление маршрутами\n"
        echo "  add <домен>      Добавить → через Б"
        echo "  remove <домен>   Убрать из проксирования"
        echo "  list             Все домены через Б"
        echo "  check <домен>    Проверить маршрут"
        echo "  traffic          Статистика трафика"
        echo "  restart          Перезапустить Xray"
        echo "  test             Проверить конфиг"
        echo "  status           Статус Xray"
        echo "" ;;
esac
MANAGE_SCRIPT

chmod +x /usr/local/bin/manage-routes
ok "manage-routes установлен"

# ─── Cron ─────────────────────────────────────────────────────
CRON_JOB='0 4 * * 0 wget -qO /usr/local/share/xray/geosite.dat https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat && wget -qO /usr/local/share/xray/geoip.dat https://github.com/v2fly/geoip/releases/latest/download/geoip.dat && systemctl restart xray'
(crontab -l 2>/dev/null | grep -v "geosite.dat"; echo "$CRON_JOB") | crontab -
ok "Автообновление geo-файлов настроено"

# ─── Запуск ───────────────────────────────────────────────────
info "Запускаю Xray..."
systemctl enable xray > /dev/null 2>&1
systemctl restart xray

if systemctl is-active --quiet xray; then
    ok "Xray работает"
else
    err "Xray не запустился! journalctl -u xray -n 30"
    exit 1
fi

# ══════════════════════════════════════════════════════════════
# ГОТОВО
# ══════════════════════════════════════════════════════════════

SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || echo "АДРЕС_СЕРВЕРА")

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Установка завершена!${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}┌─ Данные для подключения VPN-клиента ───────────${NC}"
echo -e "│"
echo -e "│  Адрес:       ${CYAN}${SERVER_IP}${NC}"
echo -e "│  Порт:        ${CYAN}${INBOUND_PORT}${NC}"
echo -e "│  Протокол:    ${CYAN}VLESS${NC}"
echo -e "│  UUID:        ${CYAN}${CLIENT_UUID}${NC}"
echo -e "│  Flow:        ${CYAN}xtls-rprx-vision${NC}"
echo -e "│  Безопасность: ${CYAN}Reality${NC}"
echo -e "│  SNI:         ${CYAN}${REALITY_SNI}${NC}"
echo -e "│  Fingerprint: ${CYAN}chrome${NC}"
echo -e "│  Public Key:  ${CYAN}${PUBLIC_KEY}${NC}"
echo -e "│  Short ID:    ${CYAN}${SHORT_ID}${NC}"
echo -e "│"
echo -e "${BOLD}└────────────────────────────────────────────────${NC}"
echo ""
echo -e "${BOLD}VLESS-ссылка (скопируй в Streisand / Happ):${NC}"
echo ""
echo -e "${CYAN}vless://${CLIENT_UUID}@${SERVER_IP}:${INBOUND_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#SmartProxy-A${NC}"
echo ""
line
echo ""
echo -e "${BOLD}Команды:${NC}"
echo -e "  sudo manage-routes list     — домены через Б"
echo -e "  sudo manage-routes add X    — добавить домен"
echo -e "  sudo manage-routes traffic  — трафик"
echo -e "  journalctl -u xray -f       — логи"
echo ""
echo -e "${BOLD}Bypass для клиента (сервисы со скриншота):${NC}"
echo -e "${DIM}Добавь эти домены в Direct/Bypass в Streisand/Happ,${NC}"
echo -e "${DIM}чтобы они шли напрямую, минуя VPN (экономия трафика):${NC}"
echo ""
echo -e "alfabank.ru, vtb.ru, online.sberbank.ru, psbank.ru, mtsbank.ru,"
echo -e "nspk.ru, sbp.nspk.ru, moex.com, ozon.ru, wildberries.ru,"
echo -e "megamarket.ru, market.yandex.ru, vkusvill.ru, auchan.ru,"
echo -e "magnit.ru, dixy.ru, spar.ru, metro-cc.ru, av.ru, 5ka.ru,"
echo -e "perekrestok.ru, x5.ru, samokat.ru, eda.yandex.ru, lavka.yandex.ru,"
echo -e "petrovich.ru, detmir.ru, rzd.ru, aeroflot.ru, pobeda.aero,"
echo -e "tutu.ru, 2gis.ru, taximaxim.ru, citydrive.ru, dzen.ru,"
echo -e "rutube.ru, ivi.ru, okko.tv, kion.ru, kinopoisk.ru,"
echo -e "music.yandex.ru, music.mts.ru, mts-live.ru, avito.ru,"
echo -e "domclick.ru, vkusnoitochka.ru, burgerking.ru, beeline.ru,"
echo -e "megafon.ru, mts.ru, rt.ru, tele2.ru, motivtelecom.ru,"
echo -e "sberbank.ru, tinkoff.ru, gosuslugi.ru, nalog.gov.ru,"
echo -e "mos.ru, vk.com, ok.ru, mail.ru, yandex.ru, ya.ru"
echo ""
