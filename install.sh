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

# ─── Утилиты ─────────────────────────────────────────────────
info()  { echo -e "${CYAN}[i]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; }
ask()   { echo -ne "${BOLD}$1${NC}"; }
line()  { echo -e "${DIM}────────────────────────────────────────${NC}"; }

# ─── Проверка root ────────────────────────────────────────────
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
echo -e "  2. Установит Xray с актуальными geo-файлами"
echo -e "  3. Настроит маршрутизацию:"
echo -e "     ${DIM}• Сервисы из белого списка → bypass (на клиенте)${NC}"
echo -e "     ${DIM}• Заблокированные сервисы → через сервер Б${NC}"
echo -e "     ${DIM}• Всё остальное → напрямую с сервера А${NC}"
echo -e "  4. Установит утилиту manage-routes"
echo ""
line

# ══════════════════════════════════════════════════════════════
# ЭТАП 1: Сбор данных
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}ЭТАП 1/4 — Параметры текущего подключения (сервер А)${NC}"
echo -e "${DIM}Возьми эти данные из 3X-UI → Inbound → настройки${NC}"
echo ""

# ─── Inbound: клиенты ─────────────────────────────────────────
CLIENTS_JSON="[]"
CLIENT_COUNT=0

while true; do
    CLIENT_COUNT=$((CLIENT_COUNT + 1))
    echo -e "${CYAN}Клиент #${CLIENT_COUNT}:${NC}"
    
    ask "  UUID: "
    read -r CLIENT_UUID
    
    if [[ -z "$CLIENT_UUID" ]]; then
        CLIENT_COUNT=$((CLIENT_COUNT - 1))
        if [[ $CLIENT_COUNT -eq 0 ]]; then
            err "Нужен хотя бы один клиент"
            continue
        fi
        break
    fi
    
    ask "  Email (для идентификации, напр. user1@proxy): "
    read -r CLIENT_EMAIL
    [[ -z "$CLIENT_EMAIL" ]] && CLIENT_EMAIL="client${CLIENT_COUNT}@proxy"
    
    ask "  Flow [xtls-rprx-vision]: "
    read -r CLIENT_FLOW
    [[ -z "$CLIENT_FLOW" ]] && CLIENT_FLOW="xtls-rprx-vision"
    
    # Добавляем в JSON массив
    if [[ "$CLIENTS_JSON" == "[]" ]]; then
        CLIENTS_JSON="[{\"id\":\"${CLIENT_UUID}\",\"email\":\"${CLIENT_EMAIL}\",\"flow\":\"${CLIENT_FLOW}\"}]"
    else
        CLIENTS_JSON="${CLIENTS_JSON%]},{\"id\":\"${CLIENT_UUID}\",\"email\":\"${CLIENT_EMAIL}\",\"flow\":\"${CLIENT_FLOW}\"}]"
    fi
    
    echo ""
    ask "Добавить ещё клиента? [y/N]: "
    read -r MORE
    [[ "$MORE" != "y" && "$MORE" != "Y" ]] && break
    echo ""
done

ok "Добавлено клиентов: ${CLIENT_COUNT}"
echo ""
line

# ─── Inbound: порт ────────────────────────────────────────────
ask "Порт inbound [443]: "
read -r INBOUND_PORT
[[ -z "$INBOUND_PORT" ]] && INBOUND_PORT="443"

# ─── Reality настройки ────────────────────────────────────────
echo ""
echo -e "${BOLD}Reality настройки:${NC}"
echo ""

ask "Target (dest), напр. ads.x5.ru:443: "
read -r REALITY_DEST
[[ -z "$REALITY_DEST" ]] && { err "Target обязателен"; exit 1; }

# Извлекаем домен из dest для SNI по умолчанию
DEFAULT_SNI=$(echo "$REALITY_DEST" | sed 's/:.*$//')

ask "SNI [${DEFAULT_SNI}]: "
read -r REALITY_SNI
[[ -z "$REALITY_SNI" ]] && REALITY_SNI="$DEFAULT_SNI"

ask "Private Key: "
read -r REALITY_PRIVATE_KEY
[[ -z "$REALITY_PRIVATE_KEY" ]] && { err "Private Key обязателен"; exit 1; }

ask "Short IDs (через запятую, напр. 9b92e326,2a,d028): "
read -r REALITY_SHORT_IDS_RAW
[[ -z "$REALITY_SHORT_IDS_RAW" ]] && { err "Short IDs обязательны"; exit 1; }

# Конвертируем "a,b,c" → ["a","b","c"]
REALITY_SHORT_IDS=$(echo "$REALITY_SHORT_IDS_RAW" | sed 's/,/","/g' | sed 's/^/["/' | sed 's/$/"]/')

ask "SpiderX [/]: "
read -r SPIDER_X
[[ -z "$SPIDER_X" ]] && SPIDER_X="/"

ask "uTLS fingerprint [chrome]: "
read -r UTLS_FP
[[ -z "$UTLS_FP" ]] && UTLS_FP="chrome"

echo ""
ok "Reality настройки получены"
line

# ─── Сервер Б ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}ЭТАП 2/4 — Параметры сервера Б (Финляндия)${NC}"
echo -e "${DIM}Возьми из Remnanode${NC}"
echo ""

ask "Адрес сервера Б (IP или домен): "
read -r SERVER_B_ADDRESS
[[ -z "$SERVER_B_ADDRESS" ]] && { err "Адрес обязателен"; exit 1; }

ask "Порт сервера Б [443]: "
read -r SERVER_B_PORT
[[ -z "$SERVER_B_PORT" ]] && SERVER_B_PORT="443"

ask "UUID клиента на сервере Б: "
read -r SERVER_B_UUID
[[ -z "$SERVER_B_UUID" ]] && { err "UUID обязателен"; exit 1; }

ask "Path для XHTTP [/xhttp]: "
read -r SERVER_B_PATH
[[ -z "$SERVER_B_PATH" ]] && SERVER_B_PATH="/xhttp"

ask "SNI сервера Б [${SERVER_B_ADDRESS}]: "
read -r SERVER_B_SNI
[[ -z "$SERVER_B_SNI" ]] && SERVER_B_SNI="$SERVER_B_ADDRESS"

echo ""
ok "Параметры сервера Б получены"
line

# ─── Email для маршрутизации ──────────────────────────────────
echo ""
echo -e "${BOLD}Маршрутизация по пользователям${NC}"
echo -e "${DIM}Укажи email пользователя, чей трафик пойдёт через Б.${NC}"
echo -e "${DIM}Остальные клиенты будут всегда идти через direct (А).${NC}"
echo ""

ask "Email для проксирования через Б (из введённых выше) [все клиенты]: "
read -r PROXY_USER_EMAIL

echo ""
line

# ══════════════════════════════════════════════════════════════
# ЭТАП 3: Установка
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}ЭТАП 3/4 — Установка компонентов${NC}"
echo ""

# ─── Останавливаем 3X-UI ─────────────────────────────────────
if systemctl is-active --quiet x-ui 2>/dev/null; then
    info "Останавливаю 3X-UI..."
    systemctl stop x-ui
    systemctl disable x-ui
    ok "3X-UI остановлен и отключён"
else
    info "3X-UI не найден или уже остановлен"
fi

# ─── Устанавливаем Xray ──────────────────────────────────────
if command -v xray &> /dev/null; then
    info "Xray уже установлен: $(xray version | head -1)"
    ask "Переустановить/обновить? [y/N]: "
    read -r REINSTALL
    if [[ "$REINSTALL" == "y" || "$REINSTALL" == "Y" ]]; then
        info "Обновляю Xray..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        ok "Xray обновлён"
    fi
else
    info "Устанавливаю Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    ok "Xray установлен: $(xray version | head -1)"
fi

# ─── Скачиваем geo-файлы ─────────────────────────────────────
info "Скачиваю актуальные geosite.dat и geoip.dat..."
mkdir -p /usr/local/share/xray

wget -qO /usr/local/share/xray/geosite.dat \
    https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat
wget -qO /usr/local/share/xray/geoip.dat \
    https://github.com/v2fly/geoip/releases/latest/download/geoip.dat

ok "Geo-файлы обновлены"

# ─── vnstat для мониторинга трафика ───────────────────────────
if ! command -v vnstat &> /dev/null; then
    info "Устанавливаю vnstat (мониторинг трафика)..."
    apt-get update -qq && apt-get install -y -qq vnstat > /dev/null 2>&1
    systemctl enable vnstat > /dev/null 2>&1
    systemctl start vnstat > /dev/null 2>&1
    ok "vnstat установлен"
else
    ok "vnstat уже установлен"
fi

line

# ══════════════════════════════════════════════════════════════
# ЭТАП 4: Генерация конфига
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}ЭТАП 4/4 — Генерация конфига Xray${NC}"
echo ""

CONFIG_PATH="/usr/local/etc/xray/config.json"

# Бэкап старого конфига
if [[ -f "$CONFIG_PATH" ]]; then
    cp "$CONFIG_PATH" "${CONFIG_PATH}.backup.$(date +%s)"
    ok "Старый конфиг сохранён в бэкап"
fi

# ─── Формируем routing rules для user-based маршрутизации ─────
# Если указан конкретный email — только его трафик идёт через Б
# Если не указан — все клиенты проходят через общие правила

if [[ -n "$PROXY_USER_EMAIL" ]]; then
    USER_RULE_B="\"user\": [\"${PROXY_USER_EMAIL}\"],"
    USER_COMMENT_B="// Только трафик пользователя ${PROXY_USER_EMAIL}"
else
    USER_RULE_B=""
    USER_COMMENT_B="// Все пользователи"
fi

# ─── Генерируем конфиг ────────────────────────────────────────
cat > "$CONFIG_PATH" << 'XRAY_CONFIG_HEREDOC'
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
XRAY_CONFIG_HEREDOC

# ─── Добавляем правило proxy-to-b ────────────────────────────
# Если есть user-based фильтрация, добавляем поле user
if [[ -n "$PROXY_USER_EMAIL" ]]; then
    cat >> "$CONFIG_PATH" << XRAY_PROXY_RULE
      {
        "type": "field",
        "user": ["${PROXY_USER_EMAIL}"],
        "domain": [
XRAY_PROXY_RULE
else
    cat >> "$CONFIG_PATH" << 'XRAY_PROXY_RULE'
      {
        "type": "field",
        "domain": [
XRAY_PROXY_RULE
fi

# ─── Список заблокированных доменов ───────────────────────────
cat >> "$CONFIG_PATH" << 'BLOCKED_DOMAINS'
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
BLOCKED_DOMAINS

# Закрываем правило proxy-to-b
cat >> "$CONFIG_PATH" << 'XRAY_PROXY_RULE_END'
        ],
        "outboundTag": "proxy-to-b"
      },
XRAY_PROXY_RULE_END

# ─── Дефолтное правило: всё остальное → direct ───────────────
cat >> "$CONFIG_PATH" << 'XRAY_DEFAULT_RULE'
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "direct"
      }
    ]
  },
XRAY_DEFAULT_RULE

# ─── Inbounds ────────────────────────────────────────────────
cat >> "$CONFIG_PATH" << XRAY_INBOUNDS
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
        "clients": ${CLIENTS_JSON},
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
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ${REALITY_SHORT_IDS},
          "spiderX": "${SPIDER_X}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": false
      }
    }
  ],
XRAY_INBOUNDS

# ─── Outbounds ───────────────────────────────────────────────
cat >> "$CONFIG_PATH" << XRAY_OUTBOUNDS
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
          "fingerprint": "chrome"
        },
        "xhttpSettings": {
          "path": "${SERVER_B_PATH}"
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
XRAY_OUTBOUNDS

ok "Конфиг сгенерирован: ${CONFIG_PATH}"

# ─── Валидация конфига ────────────────────────────────────────
info "Проверяю конфиг..."
if xray run -test -c "$CONFIG_PATH" 2>&1; then
    ok "Конфиг валиден"
else
    err "Ошибка в конфиге! Проверь параметры."
    err "Бэкап сохранён: ${CONFIG_PATH}.backup.*"
    exit 1
fi

# ─── Устанавливаем manage-routes ──────────────────────────────
info "Устанавливаю утилиту manage-routes..."

cat > /usr/local/bin/manage-routes << 'MANAGE_SCRIPT'
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo -e "${RED}Запусти от root${NC}"; exit 1; }

case "${1:-}" in
    add)
        [[ -z "${2:-}" ]] && { echo "Использование: manage-routes add домен.com"; exit 1; }
        D=$(echo "$2" | sed 's|https\?://||;s|/.*||')
        grep -q "\"domain:${D}\"" "$CONFIG" && { echo -e "${YELLOW}${D} уже в списке${NC}"; exit 0; }
        cp "$CONFIG" "${CONFIG}.bak"
        sed -i "/\"outboundTag\": \"proxy-to-b\"/i\\          \"domain:${D}\"," "$CONFIG"
        if xray run -test -c "$CONFIG" > /dev/null 2>&1; then
            systemctl restart xray
            echo -e "${GREEN}✓ Добавлен: ${D} → через сервер Б${NC}"
        else
            cp "${CONFIG}.bak" "$CONFIG"
            echo -e "${RED}✗ Ошибка, откат${NC}"
        fi
        ;;
    remove|rm)
        [[ -z "${2:-}" ]] && { echo "Использование: manage-routes remove домен.com"; exit 1; }
        D=$(echo "$2" | sed 's|https\?://||;s|/.*||')
        grep -q "\"domain:${D}\"" "$CONFIG" || { echo -e "${YELLOW}${D} не найден${NC}"; exit 0; }
        cp "$CONFIG" "${CONFIG}.bak"
        sed -i "/\"domain:${D}\"/d" "$CONFIG"
        if xray run -test -c "$CONFIG" > /dev/null 2>&1; then
            systemctl restart xray
            echo -e "${GREEN}✓ Удалён: ${D}${NC}"
        else
            cp "${CONFIG}.bak" "$CONFIG"
            echo -e "${RED}✗ Ошибка, откат${NC}"
        fi
        ;;
    list|ls)
        echo -e "${CYAN}Домены через сервер Б:${NC}"
        grep -oP '"domain:[^"]+' "$CONFIG" | sed 's/"domain:/  • /'
        echo ""
        echo -e "${CYAN}Всего: $(grep -c '"domain:' "$CONFIG") доменов${NC}"
        ;;
    check)
        [[ -z "${2:-}" ]] && { echo "Использование: manage-routes check домен.com"; exit 1; }
        D=$(echo "$2" | sed 's|https\?://||;s|/.*||')
        if grep -q "\"domain:${D}\"" "$CONFIG"; then
            echo -e "${D} → ${CYAN}proxy-to-b (финский IP)${NC}"
        else
            echo -e "${D} → ${GREEN}direct (российский IP с сервера А)${NC}"
        fi
        ;;
    traffic|stats)
        if command -v vnstat &> /dev/null; then
            vnstat -m
        else
            echo "vnstat не установлен: apt install vnstat"
        fi
        ;;
    restart)
        systemctl restart xray && echo -e "${GREEN}✓ Xray перезапущен${NC}"
        ;;
    test)
        xray run -test -c "$CONFIG"
        ;;
    status)
        systemctl status xray --no-pager -l
        ;;
    *)
        echo ""
        echo -e "${CYAN}manage-routes${NC} — управление маршрутами Xray"
        echo ""
        echo "  add <домен>      Добавить домен → через сервер Б"
        echo "  remove <домен>   Убрать домен из проксирования"
        echo "  list             Показать все домены через Б"
        echo "  check <домен>    Проверить маршрут домена"
        echo "  traffic          Статистика трафика"
        echo "  restart          Перезапустить Xray"
        echo "  test             Проверить конфиг"
        echo "  status           Статус Xray"
        echo ""
        echo "Примеры:"
        echo "  manage-routes add tiktok.com"
        echo "  manage-routes remove steampowered.com"
        echo "  manage-routes list"
        echo ""
        ;;
esac
MANAGE_SCRIPT

chmod +x /usr/local/bin/manage-routes
ok "Утилита manage-routes установлена"

# ─── Cron для обновления geo-файлов ──────────────────────────
info "Настраиваю автообновление geo-файлов (каждое воскресенье 4:00)..."

CRON_JOB='0 4 * * 0 wget -qO /usr/local/share/xray/geosite.dat https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat && wget -qO /usr/local/share/xray/geoip.dat https://github.com/v2fly/geoip/releases/latest/download/geoip.dat && systemctl restart xray'

(crontab -l 2>/dev/null | grep -v "geosite.dat"; echo "$CRON_JOB") | crontab -
ok "Cron-задача добавлена"

# ─── Запускаем Xray ──────────────────────────────────────────
info "Запускаю Xray..."
systemctl enable xray > /dev/null 2>&1
systemctl restart xray

if systemctl is-active --quiet xray; then
    ok "Xray запущен и работает"
else
    err "Xray не запустился! Проверь логи: journalctl -u xray -n 30"
    exit 1
fi

# ══════════════════════════════════════════════════════════════
# ГОТОВО
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Установка завершена!${NC}"
echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo ""
echo -e "Конфиг:          ${CONFIG_PATH}"
echo -e "Управление:      ${CYAN}manage-routes${NC}"
echo -e "Логи:            journalctl -u xray -f"
echo -e "Трафик:          vnstat -m"
echo ""
line
echo ""
echo -e "${BOLD}Что осталось сделать на клиенте (Streisand / Happ):${NC}"
echo ""
echo -e "  Подключение к серверу А — настройки ${BOLD}не меняются${NC}."
echo -e "  Тот же UUID, порт, Reality — всё как было."
echo ""
echo -e "  Для экономии трафика настрой bypass для RU-сервисов."
echo -e "  В routing клиента добавь в Direct/Bypass ${BOLD}конкретные домены${NC}:"
echo ""
echo -e "  ${DIM}# Банки${NC}"
echo -e "  alfabank.ru, vtb.ru, online.sberbank.ru, psbank.ru,"
echo -e "  mtsbank.ru, nspk.ru, sbp.nspk.ru, moex.com"
echo ""
echo -e "  ${DIM}# Маркетплейсы${NC}"
echo -e "  ozon.ru, wildberries.ru, megamarket.ru, market.yandex.ru"
echo ""
echo -e "  ${DIM}# Магазины / доставка${NC}"
echo -e "  vkusvill.ru, auchan.ru, magnit.ru, dixy.ru, spar.ru,"
echo -e "  metro-cc.ru, av.ru, 5ka.ru, perekrestok.ru, x5.ru,"
echo -e "  samokat.ru, eda.yandex.ru, lavka.yandex.ru,"
echo -e "  petrovich.ru, detmir.ru"
echo ""
echo -e "  ${DIM}# Транспорт${NC}"
echo -e "  rzd.ru, aeroflot.ru, pobeda.aero, tutu.ru"
echo ""
echo -e "  ${DIM}# Карты / навигация${NC}"
echo -e "  2gis.ru, taximaxim.ru, citydrive.ru"
echo ""
echo -e "  ${DIM}# Развлечения${NC}"
echo -e "  dzen.ru, rutube.ru, ivi.ru, okko.tv, kion.ru,"
echo -e "  kinopoisk.ru"
echo ""
echo -e "  ${DIM}# Музыка${NC}"
echo -e "  music.yandex.ru, music.mts.ru, stroiki.com"
echo ""
echo -e "  ${DIM}# Билеты / объявления${NC}"
echo -e "  mts-live.ru, avito.ru, domclick.ru"
echo ""
echo -e "  ${DIM}# Фастфуд${NC}"
echo -e "  vkusnoitochka.ru, burgerking.ru"
echo ""
echo -e "  ${DIM}# Операторы связи${NC}"
echo -e "  beeline.ru, megafon.ru, mts.ru, rt.ru, tele2.ru,"
echo -e "  motivtelecom.ru, sberbank-telecom.ru, t-mobile.ru"
echo ""
echo -e "  ${DIM}# Транспортные компании${NC}"
echo -e "  dellin.ru, gse.ru, yandex.ru"
echo ""
echo -e "  ${DIM}Или одной строкой (для Streisand):${NC}"
echo -e "  ${CYAN}alfabank.ru,vtb.ru,online.sberbank.ru,ozon.ru,wildberries.ru,${NC}"
echo -e "  ${CYAN}megamarket.ru,market.yandex.ru,vkusvill.ru,5ka.ru,rzd.ru,${NC}"
echo -e "  ${CYAN}2gis.ru,dzen.ru,rutube.ru,ivi.ru,avito.ru,mts.ru,beeline.ru,${NC}"
echo -e "  ${CYAN}megafon.ru,rt.ru,yandex.ru,vk.com,mail.ru,ok.ru${NC}"
echo ""
line
echo ""
echo -e "${BOLD}Быстрые команды:${NC}"
echo -e "  manage-routes list          — все домены через Б"
echo -e "  manage-routes add site.com  — добавить домен"
echo -e "  manage-routes traffic       — статистика трафика"
echo ""
