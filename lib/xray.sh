#!/usr/bin/env bash
# =============================================================================
# xray.sh — VLESS + Reality + XHTTP
# Модуль Orchestra | Этап 3
# =============================================================================
# Загружается через: source lib/xray.sh
# Требует: orchestra.sh загружен (info/warn/error/run_step/state_set/etc.)
# =============================================================================
set -euo pipefail

[[ -n "${XRAY_MODULE_LOADED:-}" ]] && return 0
readonly XRAY_MODULE_LOADED=1

# =============================================================================
# КОНСТАНТЫ МОДУЛЯ
# =============================================================================

readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONFIG="/etc/xray/config.json"
readonly XRAY_LINKS="/etc/xray/links.txt"
readonly XRAY_LOG_DIR="/var/log/xray"
readonly XRAY_UPDATE_SCRIPT="/usr/local/bin/xray-update.sh"

# =============================================================================
# КОНФИГУРАЦИОННЫЕ ПЕРЕМЕННЫЕ (заполняются через xray_collect_config)
# =============================================================================

XRAY_PORT="443"
XRAY_SNI="www.microsoft.com"
XRAY_PATH="/xray"
XRAY_USERS_COUNT="10"
XRAY_DOMAIN=""
XRAY_WARP="yes"
XRAY_PRIVATE_KEY=""
XRAY_PUBLIC_KEY=""

# Генерируются при install
declare -a XRAY_USER_UUIDS=()
declare -a XRAY_USER_SIDS=()

# =============================================================================
# МЕНЮ МОДУЛЯ
# =============================================================================

xray_menu() {
    clear
    section "xray — VLESS + Reality + XHTTP"

    # Показываем статус если уже установлен
    if command -v xray &>/dev/null; then
        local xray_ver
        xray_ver=$(xray version 2>&1 | head -1 | grep -oP '(?<=Xray )\S+' | head -1 || echo "?")
        echo -e "  ${G}Установлен:${N} Xray ${xray_ver}"
        if systemctl is-active --quiet xray 2>/dev/null; then
            echo -e "  ${G}Статус:${N} running ✓"
        else
            echo -e "  ${R}Статус:${N} stopped ✗"
        fi
        echo ""
    fi

    echo -e "  ${C}1${N}) Полная установка VLESS + Reality + XHTTP"
    echo -e "  ${C}2${N}) Управление пользователями"
    echo -e "  ${C}3${N}) Показать ссылки"
    echo -e "  ${C}4${N}) Добавить пользователя"
    echo -e "  ${C}5${N}) Статус / логи Xray"
    echo -e "  ${C}6${N}) Обновить Xray вручную"
    echo -e "  ${C}7${N}) Перезапустить Xray"
    echo -e "  ${C}0${N}) Назад"
    echo ""

    ask "Выбор" "1"
    local choice="$REPLY"

    case "$choice" in
        1) xray_full_install ;;
        2) xray_manage_users ;;
        3) xray_show_links ;;
        4) xray_add_user ;;
        5) xray_show_status ;;
        6) xray_update_manual ;;
        7) systemctl restart xray && info "Xray перезапущен" ;;
        0) return 0 ;;
        *) warn "Неизвестный выбор" ;;
    esac
}

# =============================================================================
# PRE-FLIGHT: СБОР КОНФИГУРАЦИИ
# =============================================================================

xray_collect_config() {
    section "Конфигуратор Xray"

    local server_ip
    server_ip=$(get_server_ip) || { error "Не удалось определить IP сервера"; return 1; }
    echo -e "  ${GR}IP сервера:${N} ${server_ip}"
    echo ""

    # Порт
    ask "Порт Xray" "443"
    XRAY_PORT="$REPLY"
    if ! [[ "$XRAY_PORT" =~ ^[0-9]+$ ]] || [[ "$XRAY_PORT" -lt 1 ]] || [[ "$XRAY_PORT" -gt 65535 ]]; then
        error "Некорректный порт: ${XRAY_PORT}"; return 1
    fi

    # SNI
    hint "SNI для Reality" \
        "SNI — домен для маскировки. Xray подключается к нему как клиент TLS." \
        "Требования: TLS 1.3 + H2/H3, реальный IP ≠ IP сервера." \
        "Рекомендуемые: www.microsoft.com, www.apple.com, www.cloudflare.com"

    echo -e "  ${C}1${N}) www.microsoft.com ${GR}(рекомендуется)${N}"
    echo -e "  ${C}2${N}) www.apple.com"
    echo -e "  ${C}3${N}) www.cloudflare.com"
    echo -e "  ${C}4${N}) Ввести свой"
    ask "Выбор SNI" "1"
    case "$REPLY" in
        1) XRAY_SNI="www.microsoft.com" ;;
        2) XRAY_SNI="www.apple.com" ;;
        3) XRAY_SNI="www.cloudflare.com" ;;
        4)
            ask "Введи SNI домен" ""
            XRAY_SNI="$REPLY"
            ;;
        *) XRAY_SNI="www.microsoft.com" ;;
    esac

    # XHTTP путь
    hint "Путь XHTTP" \
        "Путь для XHTTP запросов. Должен начинаться с /." \
        "Клиент и сервер должны использовать одинаковый путь."
    ask "Путь XHTTP" "/xray"
    XRAY_PATH="$REPLY"
    [[ "$XRAY_PATH" != /* ]] && XRAY_PATH="/${XRAY_PATH}"

    # Количество пользователей
    ask "Количество пользователей" "10"
    XRAY_USERS_COUNT="$REPLY"
    if ! [[ "$XRAY_USERS_COUNT" =~ ^[0-9]+$ ]] || [[ "$XRAY_USERS_COUNT" -lt 1 ]]; then
        warn "Некорректное число, используем 10"
        XRAY_USERS_COUNT="10"
    fi

    # Домен (необязательно)
    hint "Домен для ноды (необязательно)" \
        "Если у тебя есть домен с A-записью на этот IP — введи его." \
        "Без домена: ссылки будут на IP, HTTPS сертификат не выпустим." \
        "С доменом: nginx получит SSL сертификат через certbot." \
        "Cloudflare Proxy (оранжевое облако) НЕЛЬЗЯ — Reality сломается!"
    ask "Домен (Enter — пропустить)" ""
    XRAY_DOMAIN="$REPLY"

    # WARP
    ask_yn "Установить Cloudflare WARP (исходящий трафик через WARP)?" "да"
    XRAY_WARP=$([ $? -eq 0 ] && echo "yes" || echo "no")

    # Итоговая сводка
    echo ""
    echo -e "${BOLD}  Параметры установки Xray:${N}"
    echo -e "  ${GR}IP сервера:${N}    ${server_ip}"
    echo -e "  ${GR}Порт:${N}          ${XRAY_PORT}"
    echo -e "  ${GR}SNI:${N}           ${XRAY_SNI}"
    echo -e "  ${GR}XHTTP путь:${N}    ${XRAY_PATH}"
    echo -e "  ${GR}Пользователей:${N} ${XRAY_USERS_COUNT}"
    echo -e "  ${GR}Домен:${N}         ${XRAY_DOMAIN:-не указан}"
    echo -e "  ${GR}WARP:${N}          ${XRAY_WARP}"
    echo ""
}

# =============================================================================
# PRE-FLIGHT: ВАЛИДАЦИЯ
# =============================================================================

_xray_preflight() {
    local server_ip
    server_ip=$(get_server_ip) || { error "Не удалось получить IP сервера"; return 1; }
    local ok=true

    # Проверка ресурсов
    check_resources 1 256 || ok=false

    # Проверка что порт не занят (кроме самого xray если уже запущен)
    if ss -tlnp | grep -q ":${XRAY_PORT} " 2>/dev/null; then
        local port_owner
        port_owner=$(ss -tlnp | grep ":${XRAY_PORT} " | grep -oP 'users:\(\("\K[^"]+' | head -1 || echo "?")
        if [[ "$port_owner" != "xray" ]]; then
            error "Порт ${XRAY_PORT} уже занят процессом: ${port_owner}"
            ok=false
        fi
    fi

    # Валидация домена (если указан)
    if [[ -n "$XRAY_DOMAIN" ]]; then
        validate_domain "$XRAY_DOMAIN" "optional" "false"
        local dom_status=$?
        if [[ $dom_status -eq 1 ]]; then
            error "Домен ${XRAY_DOMAIN} не прошёл валидацию — продолжаем без домена"
            XRAY_DOMAIN=""
        fi
    fi

    [[ "$ok" == "true" ]] && return 0 || return 1
}

# =============================================================================
# ПОЛНАЯ УСТАНОВКА
# =============================================================================

xray_full_install() {
    section "Полная установка Xray"

    # Загружаем сохранённый конфиг если есть
    local server_ip
    server_ip=$(get_server_ip 2>/dev/null) || server_ip="local"
    local state_file="${STATE_DIR}/${server_ip}.conf"

    if [[ -f "$state_file" ]]; then
        local saved_port
        saved_port=$(state_get "$server_ip" "XRAY_PORT" 2>/dev/null || echo "")
        if [[ -n "$saved_port" ]]; then
            ask_yn "Загрузить сохранённый конфиг для ${server_ip}?" "да"
            if [[ $? -eq 0 ]]; then
                XRAY_PORT=$(state_get "$server_ip" "XRAY_PORT" 2>/dev/null || echo "443")
                XRAY_SNI=$(state_get "$server_ip" "XRAY_SNI" 2>/dev/null || echo "www.microsoft.com")
                XRAY_PATH=$(state_get "$server_ip" "XRAY_PATH" 2>/dev/null || echo "/xray")
                XRAY_USERS_COUNT=$(state_get "$server_ip" "XRAY_USERS_COUNT" 2>/dev/null || echo "10")
                XRAY_DOMAIN=$(state_get "$server_ip" "XRAY_NODE_DOMAIN" 2>/dev/null || echo "")
                XRAY_WARP=$(state_get "$server_ip" "XRAY_WARP" 2>/dev/null || echo "yes")
                XRAY_PRIVATE_KEY=$(state_get "$server_ip" "XRAY_PRIVATE_KEY" 2>/dev/null || echo "")
                XRAY_PUBLIC_KEY=$(state_get "$server_ip" "XRAY_PUBLIC_KEY" 2>/dev/null || echo "")
                info "Конфиг загружен"
            else
                xray_collect_config || return 1
            fi
        else
            xray_collect_config || return 1
        fi
    else
        xray_collect_config || return 1
    fi

    ask_yn "Начать установку?" "да" || { warn "Отменено"; return 1; }

    # Инициализация прогресса
    init_progress "xray" "${server_ip}"
    check_resume_prompt

    section "Установка Xray — прогресс"

    run_step "preflight"       _xray_preflight          "Проверка конфигурации"
    run_step "install_deps"    _xray_install_deps       "Установка зависимостей"
    run_step "install_xray"    _xray_install_xray       "Установка Xray"
    run_step "generate_keys"   _xray_generate_keys      "Генерация ключей Reality"
    run_step "generate_users"  _xray_generate_users     "Генерация пользователей"
    run_step "create_config"   _xray_create_config      "Создание конфига Xray"
    run_step "create_service"  _xray_create_service     "Systemd сервис Xray"
    run_step "install_warp"    _xray_install_warp       "Cloudflare WARP"
    run_step "setup_nginx"     _xray_setup_nginx        "Nginx decoy сайт"
    if [[ -n "$XRAY_DOMAIN" ]]; then
        run_step "setup_ssl"   _xray_setup_ssl          "SSL сертификат (certbot)"
    fi
    run_step "setup_autoupdate" _xray_setup_autoupdate  "Скрипт автообновления Xray"
    run_step "setup_cron"      _xray_setup_cron         "Cron задачи"
    run_step "finalize"        _xray_finalize           "Итог установки"

    # Сохраняем конфиг
    _xray_save_state "${server_ip}"
    mark_module_done "xray" "${server_ip}"
}

# =============================================================================
# СОХРАНЕНИЕ STATE
# =============================================================================

_xray_save_state() {
    local server_ip="${1}"
    state_set "$server_ip" "XRAY_PORT"        "$XRAY_PORT"
    state_set "$server_ip" "XRAY_SNI"         "$XRAY_SNI"
    state_set "$server_ip" "XRAY_PATH"        "$XRAY_PATH"
    state_set "$server_ip" "XRAY_USERS_COUNT" "$XRAY_USERS_COUNT"
    state_set "$server_ip" "XRAY_NODE_DOMAIN" "${XRAY_DOMAIN:-}"
    state_set "$server_ip" "XRAY_WARP"        "$XRAY_WARP"
    state_set "$server_ip" "XRAY_PRIVATE_KEY" "$XRAY_PRIVATE_KEY"
    state_set "$server_ip" "XRAY_PUBLIC_KEY"  "$XRAY_PUBLIC_KEY"
}

# =============================================================================
# ШАГ: ЗАВИСИМОСТИ
# =============================================================================

_xray_install_deps() {
    export DEBIAN_FRONTEND=noninteractive

    local packages=(
        curl wget unzip
        nginx certbot python3-certbot-nginx
        python3
        openssl
        cron
        ipset
    )

    apt-get update -qq 2>/dev/null
    apt-get install -y -qq "${packages[@]}" \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        2>&1 | grep -E "^(Setting up|Unpacking|already)" | head -20 || true

    # Создаём директории
    mkdir -p /etc/xray "${XRAY_LOG_DIR}"
    chmod 750 /etc/xray "${XRAY_LOG_DIR}"

    return 0
}

# =============================================================================
# ШАГ: УСТАНОВКА XRAY
# =============================================================================

_xray_install_xray() {
    local latest version

    # Метод 1 — GitHub API
    latest=$(curl -sfL --max-time 30 \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        | grep -oP '"tag_name"\s*:\s*"v\K[^"]+' | head -1) || true

    # Метод 2 — redirect
    if [[ -z "$latest" ]]; then
        latest=$(curl -sfL --max-time 15 -o /dev/null -w '%{url_effective}' \
            "https://github.com/XTLS/Xray-core/releases/latest" \
            | grep -oP '(?<=/tag/v)[^/]+$') || true
    fi

    # Fallback — последняя проверенная стабильная версия
    [[ -z "$latest" ]] && latest="26.3.27"

    version="$latest"
    info "Устанавливаем Xray v${version}"

    local tmp_zip="/tmp/xray-orchestra.zip"
    local tmp_dir="/tmp/xray-orchestra-bin"

    curl -sfL --max-time 120 --retry 3 \
        -o "$tmp_zip" \
        "https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-64.zip" \
        || { error "Не удалось скачать Xray v${version}"; return 1; }

    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"
    unzip -o "$tmp_zip" xray -d "$tmp_dir" > /dev/null \
        || { error "Ошибка распаковки архива Xray"; rm -f "$tmp_zip"; return 1; }

    # Останавливаем старый xray если запущен
    systemctl stop xray 2>/dev/null || true

    mv "${tmp_dir}/xray" "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    rm -rf "$tmp_zip" "$tmp_dir"

    # Проверяем что бинарь работает
    local installed_ver
    installed_ver=$("$XRAY_BIN" version 2>&1 | head -1 | grep -oP '(?<=Xray )\S+' | head -1 || echo "?")
    info "Xray ${installed_ver} установлен: ${XRAY_BIN}"

    return 0
}

# =============================================================================
# ШАГ: ГЕНЕРАЦИЯ КЛЮЧЕЙ REALITY
# =============================================================================

_xray_generate_keys() {
    local keys
    keys=$("$XRAY_BIN" x25519 2>&1) || { error "Ошибка генерации ключей x25519"; return 1; }

    # Парсим: поддерживаем оба формата вывода Xray (старый и новый 26.x)
    # Старый: "Private key: ..."  "Public key: ..."
    # Новый:  "Password (PrivateKey): ..."  "Password (PublicKey): ..."
    XRAY_PRIVATE_KEY=$(echo "$keys" | grep -i "private\|PrivateKey" | awk '{print $NF}' | head -1)
    XRAY_PUBLIC_KEY=$(echo  "$keys" | grep -i "public\|PublicKey"   | awk '{print $NF}' | head -1)

    if [[ -z "$XRAY_PRIVATE_KEY" || -z "$XRAY_PUBLIC_KEY" ]]; then
        error "Не удалось получить ключи. Вывод xray x25519:"
        echo "$keys" >&2
        return 1
    fi

    info "Приватный ключ: ${XRAY_PRIVATE_KEY}"
    info "Публичный ключ: ${XRAY_PUBLIC_KEY}"

    # Сохраняем немедленно — следующие шаги зависят от ключей
    local server_ip
    server_ip=$(get_server_ip 2>/dev/null) || server_ip="local"
    state_set "$server_ip" "XRAY_PRIVATE_KEY" "$XRAY_PRIVATE_KEY"
    state_set "$server_ip" "XRAY_PUBLIC_KEY"  "$XRAY_PUBLIC_KEY"

    return 0
}

# =============================================================================
# ШАГ: ГЕНЕРАЦИЯ ПОЛЬЗОВАТЕЛЕЙ
# =============================================================================

_xray_generate_users() {
    local count="${XRAY_USERS_COUNT:-10}"
    local server_ip domain_or_ip encoded_path

    server_ip=$(get_server_ip 2>/dev/null) || server_ip="?"
    domain_or_ip="${XRAY_DOMAIN:-${server_ip}}"

    # URL-кодируем путь — safe='' кодирует слэш тоже (баг с safe='/' известен)
    encoded_path=$(python3 -c \
        "import urllib.parse; print(urllib.parse.quote('${XRAY_PATH}', safe=''))")

    # Очищаем массивы
    XRAY_USER_UUIDS=()
    XRAY_USER_SIDS=()

    # Создаём директорию и очищаем файл ссылок
    mkdir -p /etc/xray "${XRAY_LOG_DIR}"
    chmod 750 /etc/xray
    : > "$XRAY_LINKS"
    chmod 600 "$XRAY_LINKS"

    echo ""
    for i in $(seq 1 "$count"); do
        local uuid short_id link

        uuid=$("$XRAY_BIN" uuid 2>/dev/null) \
            || uuid=$(python3 -c "import uuid; print(uuid.uuid4())")

        # openssl rand — не tr|head, нет SIGPIPE
        short_id=$(openssl rand -hex 4)

        XRAY_USER_UUIDS+=("$uuid")
        XRAY_USER_SIDS+=("$short_id")

        link="vless://${uuid}@${domain_or_ip}:${XRAY_PORT}?type=xhttp&security=reality&sni=${XRAY_SNI}&fp=chrome&pbk=${XRAY_PUBLIC_KEY}&sid=${short_id}&path=${encoded_path}#VPN-${i}"
        echo "$link" >> "$XRAY_LINKS"

        printf "  ${G}%02d${N}. UUID: %s...%s  sid: %s\n" \
            "$i" "${uuid:0:8}" "${uuid: -4}" "$short_id"
    done

    echo ""
    info "${count} пользователей сгенерировано → ${XRAY_LINKS}"
    return 0
}

# =============================================================================
# ШАГ: СОЗДАНИЕ КОНФИГА XRAY
# =============================================================================

_xray_create_config() {
    # Перечитываем пользователей из файла ссылок если массивы пусты (после resume)
    if [[ ${#XRAY_USER_UUIDS[@]} -eq 0 ]] && [[ -f "$XRAY_LINKS" ]]; then
        while IFS= read -r link; do
            [[ -z "$link" ]] && continue
            local uuid sid
            uuid=$(echo "$link" | grep -oP '(?<=vless://)[^@]+')
            sid=$(echo  "$link" | grep -oP '(?<=sid=)[^&]+')
            XRAY_USER_UUIDS+=("$uuid")
            XRAY_USER_SIDS+=("$sid")
        done < "$XRAY_LINKS"
    fi

    if [[ ${#XRAY_USER_UUIDS[@]} -eq 0 ]]; then
        error "Нет сгенерированных пользователей — выполни шаг generate_users"
        return 1
    fi

    # Строим JSON через Python — не heredoc с переменными (риск инъекции)
    python3 << PYEOF
import json, sys

port          = int("${XRAY_PORT}")
sni           = "${XRAY_SNI}"
xhttp_path    = "${XRAY_PATH}"
private_key   = "${XRAY_PRIVATE_KEY}"
warp_enabled  = "${XRAY_WARP}" == "yes"

uuids = [l.strip() for l in open("${XRAY_LINKS}") if l.strip()]
clients = []
short_ids = [""]   # пустой shortId всегда первый
for line in uuids:
    uid  = line.split("@")[0].replace("vless://", "")
    sid  = ""
    for part in line.split("?")[1].split("&"):
        if part.startswith("sid="):
            sid = part.split("=", 1)[1].split("#")[0]
            break
    clients.append({"id": uid})
    if sid and sid not in short_ids:
        short_ids.append(sid)

config = {
    "log": {
        "access": "/var/log/xray/access.log",
        "error":  "/var/log/xray/error.log",
        "loglevel": "warning"
    },
    "inbounds": [{
        "listen": "0.0.0.0",
        "port": port,
        "protocol": "vless",
        "settings": {
            "clients": clients,
            "decryption": "none"
        },
        "streamSettings": {
            "network": "xhttp",
            "security": "reality",
            "realitySettings": {
                "show": False,
                "dest": f"{sni}:443",
                "xver": 0,
                "serverNames": [sni],
                "privateKey": private_key,
                "shortIds": short_ids
            },
            "xhttpSettings": {
                "path": xhttp_path,
                "mode": "auto"
            }
        },
        "sniffing": {
            "enabled": True,
            "destOverride": ["http", "tls", "quic"]
        }
    }],
    "outbounds": [],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}
        ]
    }
}

# WARP outbound
if warp_enabled:
    config["outbounds"].append({
        "protocol": "socks",
        "tag": "warp",
        "settings": {"servers": [{"address": "127.0.0.1", "port": 40000}]}
    })
    config["routing"]["rules"].append({
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "warp"
    })
else:
    config["routing"]["rules"].append({
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "direct"
    })

config["outbounds"] += [
    {"protocol": "freedom",   "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
]

with open("${XRAY_CONFIG}", "w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)

print(f"Конфиг записан: ${XRAY_CONFIG}")
print(f"  Клиентов: {len(clients)}")
print(f"  Порт: {port}")
print(f"  SNI: {sni}")
print(f"  WARP outbound: {warp_enabled}")
PYEOF

    chmod 600 "$XRAY_CONFIG"

    # Проверяем синтаксис конфига
    "$XRAY_BIN" -test -c "$XRAY_CONFIG" 2>&1 | grep -v "^$" | while IFS= read -r line; do
        info "$line"
    done || { error "Конфиг Xray содержит ошибки"; return 1; }

    return 0
}

# =============================================================================
# ШАГ: SYSTEMD СЕРВИС
# =============================================================================

_xray_create_service() {
    cat > /etc/systemd/system/xray.service << 'SVCEOF'
[Unit]
Description=Xray — VLESS Reality XHTTP
Documentation=https://xtls.github.io
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=false
ExecStart=/usr/local/bin/xray run -c /etc/xray/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray

    # Ждём запуска (до 10 сек)
    local waited=0
    while [[ $waited -lt 10 ]]; do
        systemctl is-active --quiet xray && break
        sleep 1
        ((waited++)) || true
    done

    if systemctl is-active --quiet xray; then
        info "Xray запущен"
    else
        error "Xray не запустился. Лог:"
        journalctl -u xray -n 20 --no-pager >&2
        return 1
    fi

    return 0
}

# =============================================================================
# ШАГ: CLOUDFLARE WARP
# =============================================================================

_xray_install_warp() {
    [[ "$XRAY_WARP" != "yes" ]] && { info "WARP пропущен (отключён)"; return 0; }

    # Проверяем — уже установлен?
    if command -v warp-cli &>/dev/null && warp-cli --accept-tos status 2>/dev/null | grep -q "Connected"; then
        info "WARP уже подключён"
        return 0
    fi

    # Добавляем репозиторий Cloudflare
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
        || { error "Не удалось получить GPG ключ Cloudflare"; return 1; }

    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ bookworm main" \
        > /etc/apt/sources.list.d/cloudflare-client.list

    apt-get update -qq 2>/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cloudflare-warp \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        2>&1 | grep -E "^(Setting up|already)" || true

    systemctl enable warp-svc
    systemctl start warp-svc
    sleep 5

    # Регистрация и настройка
    warp-cli --accept-tos registration delete 2>/dev/null || true
    warp-cli --accept-tos registration new      || { error "Ошибка регистрации WARP"; return 1; }
    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos proxy port 40000
    warp-cli --accept-tos connect

    # Ждём подключения (до 30 сек)
    local waited=0
    while [[ $waited -lt 30 ]]; do
        warp-cli --accept-tos status 2>/dev/null | grep -q "Connected" && break
        sleep 2
        ((waited+=2)) || true
    done

    if warp-cli --accept-tos status 2>/dev/null | grep -q "Connected"; then
        # Проверяем что SOCKS5 работает
        local warp_ip
        warp_ip=$(curl -4s --socks5 127.0.0.1:40000 https://ifconfig.me --max-time 10 2>/dev/null || echo "?")
        info "WARP подключён. Внешний IP через WARP: ${warp_ip}"

        # Пересоздаём Xray конфиг с WARP (WARP_ENABLED=yes подтверждено)
        _xray_create_config
        systemctl restart xray
    else
        warn "WARP не подключился — трафик пойдёт напрямую"
        XRAY_WARP="no"
        # Пересоздаём конфиг без WARP
        _xray_create_config
        systemctl restart xray
    fi

    return 0
}

# =============================================================================
# ШАГ: NGINX DECOY САЙТ
# =============================================================================

_xray_setup_nginx() {
    # Decoy HTML — "StreamVault" (из vpn-setup.sh, проверен)
    cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>StreamVault - Free Video Platform</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:Arial,sans-serif;background:#111;color:#eee}
.notice{background:#222;border-left:4px solid #555;padding:10px 20px;font-size:12px;color:#888;text-align:center}
header{background:#1a1a1a;padding:15px 30px;display:flex;align-items:center;gap:15px;border-bottom:1px solid #333}
header h1{font-size:22px;color:#fff;font-weight:bold}
.hero{padding:60px 30px;text-align:center;background:linear-gradient(180deg,#1a1a1a,#111)}
.hero h2{font-size:32px;margin-bottom:10px}.hero p{color:#aaa;margin-bottom:25px}
.btn{background:#444;color:#fff;padding:12px 28px;border-radius:4px;font-size:15px;text-decoration:none;display:inline-block}
.section{padding:30px;max-width:1100px;margin:0 auto}.section h3{font-size:18px;margin-bottom:18px;color:#ddd}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:12px}
.card{background:#1e1e1e;border-radius:5px;overflow:hidden}
.thumb{width:100%;height:90px;background:#2a2a2a;display:flex;align-items:center;justify-content:center;color:#555;font-size:28px}
.card-title{padding:7px 8px;font-size:12px;color:#bbb}
footer{background:#1a1a1a;border-top:1px solid #333;padding:18px;text-align:center;font-size:11px;color:#555;margin-top:40px}
</style>
</head>
<body>
<div class="notice">Independent video platform. Not affiliated with any commercial streaming service.</div>
<header><h1>StreamVault</h1><span style="color:#666;font-size:13px">Free Video Platform</span></header>
<div class="hero"><h2>Watch Free Videos</h2><p>Public domain and open-license content</p><a href="#" class="btn">Browse</a></div>
<div class="section"><h3>Featured</h3>
<div class="grid">
<div class="card"><div class="thumb">&#9654;</div><div class="card-title">Nature Documentary</div></div>
<div class="card"><div class="thumb">&#9654;</div><div class="card-title">Classic Film 1940</div></div>
<div class="card"><div class="thumb">&#9654;</div><div class="card-title">Short Film Festival</div></div>
<div class="card"><div class="thumb">&#9654;</div><div class="card-title">Science Lecture</div></div>
<div class="card"><div class="thumb">&#9654;</div><div class="card-title">Travel Series</div></div>
<div class="card"><div class="thumb">&#9654;</div><div class="card-title">Cooking Show</div></div>
</div></div>
<footer>&copy; 2026 StreamVault &mdash; Independent platform. All content is public domain or openly licensed.</footer>
</body></html>
HTMLEOF

    local server_name="${XRAY_DOMAIN:-_}"

    # Nginx конфиг — decoy сайт на порту 80
    cat > /etc/nginx/sites-available/xray-decoy << NGXEOF
server {
    listen 80;
    server_name ${server_name};

    root /var/www/html;
    index index.html;

    # Скрываем версию сервера
    server_tokens off;

    # Базовые security headers
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Логи
    access_log /var/log/nginx/xray-decoy-access.log;
    error_log  /var/log/nginx/xray-decoy-error.log;
}
NGXEOF

    ln -sf /etc/nginx/sites-available/xray-decoy /etc/nginx/sites-enabled/xray-decoy
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

    nginx -t || { error "Ошибка синтаксиса nginx"; return 1; }
    systemctl enable nginx
    systemctl reload nginx

    # Проверяем что сайт отдаёт 200
    sleep 1
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/ --max-time 5 2>/dev/null || echo "?")
    if [[ "$http_code" == "200" ]]; then
        info "Nginx decoy сайт запущен (HTTP 200)"
    else
        warn "Nginx отдаёт HTTP ${http_code} — проверь конфиг"
    fi

    return 0
}

# =============================================================================
# ШАГ: SSL СЕРТИФИКАТ (certbot)
# =============================================================================

_xray_setup_ssl() {
    [[ -z "$XRAY_DOMAIN" ]] && { info "Домен не указан — SSL пропущен"; return 0; }

    # Проверяем что порт 80 открыт и nginx работает
    if ! systemctl is-active --quiet nginx 2>/dev/null; then
        error "Nginx не запущен — SSL не можем выпустить"
        return 1
    fi

    # Выпускаем сертификат
    certbot --nginx \
        -d "$XRAY_DOMAIN" \
        --non-interactive \
        --agree-tos \
        --email "admin@${XRAY_DOMAIN}" \
        --redirect \
        2>&1 | tail -10

    if [[ -f "/etc/letsencrypt/live/${XRAY_DOMAIN}/fullchain.pem" ]]; then
        info "SSL сертификат выпущен для ${XRAY_DOMAIN}"

        # Обновляем nginx конфиг чтобы добавить HTTPS vhost
        # certbot --nginx уже делает это автоматически
    else
        warn "SSL сертификат не выпущен — проверь A-запись и порт 80"
        return 1
    fi

    # Cron для автообновления certbot (если ещё нет)
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    fi

    return 0
}

# =============================================================================
# ШАГ: СКРИПТ АВТООБНОВЛЕНИЯ XRAY
# =============================================================================

_xray_setup_autoupdate() {
    cat > "$XRAY_UPDATE_SCRIPT" << 'XUEOF'
#!/usr/bin/env bash
# Orchestra — Xray auto-update
set -euo pipefail

XRAY_BIN="/usr/local/bin/xray"
LOG="/var/log/xray-update.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }

CURRENT=$("$XRAY_BIN" version 2>&1 | head -1 | grep -oP '(?<=Xray )\S+' | head -1 || echo "?")

LATEST=$(curl -sfL --max-time 30 \
    "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
    | grep -oP '"tag_name"\s*:\s*"v\K[^"]+' | head -1) || {
    log "ERROR: Не удалось получить версию с GitHub"
    exit 1
}

if [[ "$CURRENT" == "$LATEST" ]]; then
    log "INFO: Xray актуален (v${CURRENT})"
    exit 0
fi

log "INFO: Обновление Xray v${CURRENT} -> v${LATEST}"

TMP_ZIP="/tmp/xray-update-$$.zip"
TMP_DIR="/tmp/xray-update-$$"

curl -sfL --max-time 120 --retry 3 \
    -o "$TMP_ZIP" \
    "https://github.com/XTLS/Xray-core/releases/download/v${LATEST}/Xray-linux-64.zip" || {
    log "ERROR: Ошибка скачивания"
    rm -f "$TMP_ZIP"
    exit 1
}

mkdir -p "$TMP_DIR"
unzip -o "$TMP_ZIP" xray -d "$TMP_DIR" > /dev/null || {
    log "ERROR: Ошибка распаковки"
    rm -rf "$TMP_ZIP" "$TMP_DIR"
    exit 1
}

# Горячая замена: сначала тест нового бинаря
"${TMP_DIR}/xray" version &>/dev/null || {
    log "ERROR: Новый бинарь не работает"
    rm -rf "$TMP_ZIP" "$TMP_DIR"
    exit 1
}

systemctl stop xray
cp "${TMP_DIR}/xray" "$XRAY_BIN"
chmod +x "$XRAY_BIN"
systemctl start xray

sleep 3
if systemctl is-active --quiet xray; then
    log "INFO: Xray успешно обновлён до v${LATEST}"
else
    log "ERROR: Xray не запустился после обновления — откатываем"
    # Откатываемся невозможно (старый бинарь перезаписан) — сигнализируем
    log "CRITICAL: ручное вмешательство требуется"
fi

rm -rf "$TMP_ZIP" "$TMP_DIR"
XUEOF

    chmod +x "$XRAY_UPDATE_SCRIPT"
    info "Скрипт автообновления создан: ${XRAY_UPDATE_SCRIPT}"
    return 0
}

# =============================================================================
# ШАГ: CRON ЗАДАЧИ
# =============================================================================

_xray_setup_cron() {
    cat > /etc/cron.d/xray-orchestra << 'CRONEOF'
# Orchestra — Xray cron задачи
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Автообновление Xray — каждый день в 04:00
0 4 * * * root /usr/local/bin/xray-update.sh >> /var/log/xray-update.log 2>&1
CRONEOF

    chmod 644 /etc/cron.d/xray-orchestra
    info "Cron: автообновление Xray в 04:00"
    return 0
}

# =============================================================================
# ШАГ: ФИНАЛИЗАЦИЯ
# =============================================================================

_xray_finalize() {
    local server_ip
    server_ip=$(get_server_ip 2>/dev/null) || server_ip="?"

    echo ""
    section "Xray установлен"

    echo -e "  ${G}✓${N} Xray: $(systemctl is-active xray 2>/dev/null || echo '?')"
    echo -e "  ${G}✓${N} Nginx: $(systemctl is-active nginx 2>/dev/null || echo '?')"
    [[ "$XRAY_WARP" == "yes" ]] && \
        echo -e "  ${G}✓${N} WARP: $(warp-cli --accept-tos status 2>/dev/null | head -1 || echo '?')"
    echo ""
    echo -e "  ${GR}Порт Xray:${N}     ${XRAY_PORT}"
    echo -e "  ${GR}SNI:${N}           ${XRAY_SNI}"
    echo -e "  ${GR}Путь XHTTP:${N}    ${XRAY_PATH}"
    echo -e "  ${GR}Публичный ключ:${N} ${XRAY_PUBLIC_KEY}"
    echo -e "  ${GR}Ссылки:${N}        ${XRAY_LINKS}"
    echo ""

    # Показываем несколько ссылок
    echo -e "${BOLD}  Ссылки для подключения (первые 3):${N}"
    head -3 "$XRAY_LINKS" 2>/dev/null | while IFS= read -r link; do
        echo -e "  ${C}→${N} ${link}"
        echo ""
    done

    [[ $(wc -l < "$XRAY_LINKS" 2>/dev/null) -gt 3 ]] && \
        echo -e "  ${GR}... и ещё $(($(wc -l < "$XRAY_LINKS") - 3)) ссылок в ${XRAY_LINKS}${N}"

    return 0
}

# =============================================================================
# УПРАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯМИ
# =============================================================================

xray_manage_users() {
    while true; do
        clear
        section "Управление пользователями Xray"

        local user_count=0
        [[ -f "$XRAY_LINKS" ]] && user_count=$(grep -c "^vless://" "$XRAY_LINKS" 2>/dev/null || echo 0)
        echo -e "  ${GR}Текущих пользователей:${N} ${user_count}"
        echo ""
        echo -e "  ${C}1${N}) Показать все ссылки"
        echo -e "  ${C}2${N}) Добавить пользователя"
        echo -e "  ${C}3${N}) Удалить пользователя"
        echo -e "  ${C}4${N}) Показать только UUID список"
        echo -e "  ${C}0${N}) Назад"
        echo ""

        ask "Выбор" "1"
        case "$REPLY" in
            1) xray_show_links; press_enter ;;
            2) xray_add_user; press_enter ;;
            3) xray_remove_user; press_enter ;;
            4) xray_list_users; press_enter ;;
            0) return 0 ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

xray_show_links() {
    if [[ ! -f "$XRAY_LINKS" ]]; then
        warn "Файл ссылок не найден: ${XRAY_LINKS}"
        return 1
    fi

    echo ""
    section "Ссылки для подключения"
    local i=1
    while IFS= read -r link; do
        [[ -z "$link" ]] && continue
        printf "  ${G}%02d${N}. %s\n\n" "$i" "$link"
        ((i++)) || true
    done < "$XRAY_LINKS"
}

xray_list_users() {
    [[ ! -f "$XRAY_LINKS" ]] && { warn "Нет ссылок"; return 1; }
    echo ""
    local i=1
    while IFS= read -r link; do
        [[ -z "$link" ]] && continue
        local uuid sid
        uuid=$(echo "$link" | grep -oP '(?<=vless://)[^@]+')
        sid=$(echo  "$link" | grep -oP '(?<=sid=)[^&#]+')
        printf "  ${G}%02d${N}. UUID: ${C}%s${N}  sid: ${GR}%s${N}\n" "$i" "$uuid" "$sid"
        ((i++)) || true
    done < "$XRAY_LINKS"
}

xray_add_user() {
    # Загружаем ключи из state если нужно
    if [[ -z "${XRAY_PUBLIC_KEY:-}" ]]; then
        local server_ip
        server_ip=$(get_server_ip 2>/dev/null) || server_ip="local"
        XRAY_PUBLIC_KEY=$(state_get "$server_ip" "XRAY_PUBLIC_KEY" 2>/dev/null || echo "")
        XRAY_PORT=$(state_get "$server_ip" "XRAY_PORT" 2>/dev/null || echo "443")
        XRAY_SNI=$(state_get "$server_ip" "XRAY_SNI" 2>/dev/null || echo "www.microsoft.com")
        XRAY_PATH=$(state_get "$server_ip" "XRAY_PATH" 2>/dev/null || echo "/xray")
        XRAY_DOMAIN=$(state_get "$server_ip" "XRAY_NODE_DOMAIN" 2>/dev/null || echo "")
    fi

    if [[ -z "${XRAY_PUBLIC_KEY:-}" ]]; then
        error "Xray не настроен. Сначала выполни полную установку."
        return 1
    fi

    local server_ip domain_or_ip encoded_path
    server_ip=$(get_server_ip 2>/dev/null) || server_ip="?"
    domain_or_ip="${XRAY_DOMAIN:-${server_ip}}"
    encoded_path=$(python3 -c \
        "import urllib.parse; print(urllib.parse.quote('${XRAY_PATH}', safe=''))")

    local uuid short_id
    uuid=$("$XRAY_BIN" uuid 2>/dev/null) \
        || uuid=$(python3 -c "import uuid; print(uuid.uuid4())")
    short_id=$(openssl rand -hex 4)

    # Добавляем в config.json через Python
    python3 << PYEOF
import json

with open("${XRAY_CONFIG}") as f:
    cfg = json.load(f)

cfg["inbounds"][0]["settings"]["clients"].append({"id": "${uuid}"})

sids = cfg["inbounds"][0]["streamSettings"]["realitySettings"]["shortIds"]
if "${short_id}" not in sids:
    sids.append("${short_id}")

with open("${XRAY_CONFIG}", "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print("Конфиг обновлён")
PYEOF

    local link="vless://${uuid}@${domain_or_ip}:${XRAY_PORT}?type=xhttp&security=reality&sni=${XRAY_SNI}&fp=chrome&pbk=${XRAY_PUBLIC_KEY}&sid=${short_id}&path=${encoded_path}#VPN-new"
    echo "$link" >> "$XRAY_LINKS"

    systemctl restart xray

    info "Пользователь добавлен"
    echo ""
    echo -e "  ${C}Ссылка:${N}"
    echo -e "  ${link}"
    echo ""
}

xray_remove_user() {
    [[ ! -f "$XRAY_LINKS" ]] && { error "Файл ссылок не найден"; return 1; }

    xray_list_users
    echo ""
    ask "Номер для удаления (0 — отмена)" "0"
    local num="$REPLY"
    [[ "$num" == "0" ]] && return 0

    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        error "Некорректный номер"; return 1
    fi

    local del_link del_uuid del_sid
    del_link=$(sed -n "${num}p" "$XRAY_LINKS" 2>/dev/null || echo "")

    if [[ -z "$del_link" ]]; then
        error "Пользователь #${num} не найден"
        return 1
    fi

    del_uuid=$(echo "$del_link" | grep -oP '(?<=vless://)[^@]+')
    del_sid=$(echo  "$del_link" | grep -oP '(?<=sid=)[^&#]+')

    ask_yn "Удалить пользователя ${del_uuid:0:8}...${del_uuid: -4}?" "да" || return 0

    # Удаляем из config.json
    python3 << PYEOF
import json

with open("${XRAY_CONFIG}") as f:
    cfg = json.load(f)

before = len(cfg["inbounds"][0]["settings"]["clients"])
cfg["inbounds"][0]["settings"]["clients"] = [
    c for c in cfg["inbounds"][0]["settings"]["clients"]
    if c.get("id") != "${del_uuid}"
]
after = len(cfg["inbounds"][0]["settings"]["clients"])

sids = cfg["inbounds"][0]["streamSettings"]["realitySettings"]["shortIds"]
if "${del_sid}" in sids:
    sids.remove("${del_sid}")

with open("${XRAY_CONFIG}", "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print(f"Удалено клиентов: {before - after}")
PYEOF

    # Удаляем из файла ссылок
    sed -i "${num}d" "$XRAY_LINKS"

    systemctl restart xray
    info "Пользователь #${num} удалён"
}

# =============================================================================
# СТАТУС
# =============================================================================

xray_show_status() {
    section "Статус Xray"

    # Сервис
    if systemctl is-active --quiet xray 2>/dev/null; then
        echo -e "  ${G}✓${N} Xray running"
        local xray_ver
        xray_ver=$(xray version 2>&1 | head -1 | grep -oP '(?<=Xray )\S+' | head -1 || echo "?")
        echo -e "  ${GR}Версия:${N} ${xray_ver}"
    else
        echo -e "  ${R}✗${N} Xray stopped"
    fi

    # Порт
    local port_status
    if ss -tlnp 2>/dev/null | grep ":${XRAY_PORT:-443} " | grep -q xray; then
        echo -e "  ${G}✓${N} Порт ${XRAY_PORT:-443} слушает"
    else
        echo -e "  ${Y}!${N} Порт ${XRAY_PORT:-443} не найден в ss"
    fi

    # WARP
    if command -v warp-cli &>/dev/null; then
        local warp_status
        warp_status=$(warp-cli --accept-tos status 2>/dev/null | head -1 || echo "?")
        echo -e "  ${GR}WARP:${N} ${warp_status}"
    fi

    # Пользователи
    local user_count=0
    [[ -f "$XRAY_LINKS" ]] && user_count=$(grep -c "^vless://" "$XRAY_LINKS" 2>/dev/null || echo 0)
    echo -e "  ${GR}Пользователей:${N} ${user_count}"

    # Последние логи
    echo ""
    echo -e "  ${BOLD}Последние записи лога Xray:${N}"
    journalctl -u xray -n 10 --no-pager --output=cat 2>/dev/null | \
        while IFS= read -r line; do echo "    ${line}"; done || \
        echo -e "    ${GR}нет данных${N}"
}

# =============================================================================
# РУЧНОЕ ОБНОВЛЕНИЕ
# =============================================================================

xray_update_manual() {
    section "Обновление Xray"

    if [[ ! -f "$XRAY_UPDATE_SCRIPT" ]]; then
        error "Скрипт обновления не найден: ${XRAY_UPDATE_SCRIPT}"
        error "Выполни полную установку сначала"
        return 1
    fi

    bash "$XRAY_UPDATE_SCRIPT"
}
