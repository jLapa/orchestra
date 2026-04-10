#!/usr/bin/env bash
# =============================================================================
# monitor.sh — Мониторинг нод L1-L7 + Telegram алерты
# Модуль Orchestra | Этап 4
# =============================================================================
set -euo pipefail

[[ -n "${MONITOR_MODULE_LOADED:-}" ]] && return 0
readonly MONITOR_MODULE_LOADED=1

# =============================================================================
# КОНФИГУРАЦИЯ
# =============================================================================

MONITOR_TG_TOKEN=""
MONITOR_TG_CHAT_ID=""
MONITOR_INTERVAL=300   # секунд между проверками в daemon режиме

# =============================================================================
# МЕНЮ МОДУЛЯ
# =============================================================================

monitor_menu() {
    clear
    section "monitor — Мониторинг нод"

    echo -e "  ${C}1${N}) Проверить все ноды (L1-L4)"
    echo -e "  ${C}2${N}) Полная проверка одной ноды (L1-L7)"
    echo -e "  ${C}3${N}) Таблица статусов fleet"
    echo -e "  ${C}4${N}) Настроить Telegram алерты"
    echo -e "  ${C}5${N}) Запустить мониторинг daemon (фон)"
    echo -e "  ${C}6${N}) Остановить daemon"
    echo -e "  ${C}0${N}) Назад"
    echo ""

    ask "Выбор" "1"
    case "$REPLY" in
        1) fleet_monitor_all ;;
        2)
            ask "IP ноды для полной проверки" ""
            local target_ip="$REPLY"
            [[ -n "$target_ip" ]] && monitor_node_full "$target_ip"
            ;;
        3) monitor_fleet_table ;;
        4) monitor_setup_telegram ;;
        5) monitor_start_daemon ;;
        6) monitor_stop_daemon ;;
        0) return 0 ;;
        *) warn "Неверный выбор" ;;
    esac
}

# =============================================================================
# L1: ICMP PING
# =============================================================================

check_l1_ping() {
    local ip="${1}"
    ping -c 2 -W 3 -q "${ip}" &>/dev/null
}

# =============================================================================
# L2: TCP ПОРТ
# =============================================================================

check_l2_tcp() {
    local ip="${1}"
    local port="${2:-443}"
    timeout 5 bash -c "echo >/dev/tcp/${ip}/${port}" 2>/dev/null
}

# =============================================================================
# L3: TLS HANDSHAKE
# =============================================================================

check_l3_tls() {
    local ip="${1}"
    local sni="${2:-www.microsoft.com}"
    local port="${3:-443}"
    curl -sk --max-time 8 \
        --resolve "${sni}:${port}:${ip}" \
        "https://${sni}:${port}/" \
        -o /dev/null 2>/dev/null
}

# =============================================================================
# L4: HTTP DECOY → 200
# =============================================================================

check_l4_http() {
    local ip="${1}"
    local code
    code=$(curl -s --max-time 8 -o /dev/null -w "%{http_code}" "http://${ip}/" 2>/dev/null || echo "000")
    [[ "$code" == "200" ]]
}

# =============================================================================
# L5: IPREGION (ASN / ISP / СТРАНА)
# =============================================================================

check_l5_ipregion() {
    local ip="${1}"
    local result="{}"

    # Метод A — ip-api.com (бесплатный, лимит 45 req/min)
    result=$(curl -s --max-time 10 \
        "http://ip-api.com/json/${ip}?fields=status,country,countryCode,org,as,isp,query" \
        2>/dev/null || echo "{}")

    local status country org asn
    status=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','fail'))" 2>/dev/null || echo "fail")

    if [[ "$status" == "success" ]]; then
        country=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('country','?'))" 2>/dev/null || echo "?")
        org=$(echo     "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('org','?'))"     2>/dev/null || echo "?")
        asn=$(echo     "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('as','?'))"      2>/dev/null || echo "?")
        echo "${country}|${asn}|${org}"
        return 0
    fi

    # Метод B — ipinfo.io
    result=$(curl -s --max-time 10 "https://ipinfo.io/${ip}/json" 2>/dev/null || echo "{}")
    country=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('country','?'))" 2>/dev/null || echo "?")
    org=$(echo     "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('org','?'))"     2>/dev/null || echo "?")
    echo "${country}|?|${org}"
}

# =============================================================================
# L6: РЕПУТАЦИЯ IP (Netflix / YouTube)
# =============================================================================

check_l6_reputation() {
    local ip="${1}"
    local results=()

    # Netflix — проверяем через их API
    local netflix_code
    netflix_code=$(curl -s --max-time 10 \
        -o /dev/null -w "%{http_code}" \
        --interface "${ip}" \
        "https://www.netflix.com/title/80018499" 2>/dev/null || echo "000")

    if [[ "$netflix_code" == "200" ]]; then
        results+=("Netflix:OK")
    else
        results+=("Netflix:BLOCK")
    fi

    echo "${results[*]}"
}

# =============================================================================
# L7: РЕЕСТР РКН
# =============================================================================

check_l7_rkn() {
    local ip="${1}"

    # Проверяем через zapret-info API
    local result
    result=$(curl -s --max-time 15 \
        "https://api.zapret.info/ip/${ip}" \
        2>/dev/null || echo "{}")

    local blocked
    blocked=$(echo "$result" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    blocked = d.get('blocked', False) or d.get('in_registry', False)
    print('BLOCKED' if blocked else 'OK')
except:
    print('UNKNOWN')
" 2>/dev/null || echo "UNKNOWN")

    echo "$blocked"
}

# =============================================================================
# ПОЛНАЯ ПРОВЕРКА ОДНОЙ НОДЫ (L1-L7)
# =============================================================================

monitor_node_full() {
    local ip="${1}"
    local sni="${2:-www.microsoft.com}"
    local port="${3:-443}"
    local node_name="${4:-${ip}}"

    section "Диагностика ноды: ${node_name} (${ip})"

    local l1 l2 l3 l4 l5_info l6_info l7_status
    local alert_needed=false

    # L1 — Ping
    echo -ne "  L1 ICMP ping .......... "
    if check_l1_ping "$ip"; then
        echo -e "${G}✓ OK${N}"
        l1="ok"
    else
        echo -e "${R}✗ FAIL${N}"
        l1="fail"
        alert_needed=true
        _monitor_alert "ALERT" "$node_name" "L1: сервер не пингуется"
        # Дальше не проверяем — сервер недоступен
        _monitor_update_node_status "$ip" "error"
        return 1
    fi

    # L2 — TCP порт
    echo -ne "  L2 TCP :${port} ........... "
    if check_l2_tcp "$ip" "$port"; then
        echo -e "${G}✓ OK${N}"
        l2="ok"
    else
        echo -e "${R}✗ FAIL${N}"
        l2="fail"
        alert_needed=true
        _monitor_alert "ALERT" "$node_name" "L2: порт ${port} закрыт"
    fi

    # L3 — TLS handshake
    echo -ne "  L3 TLS handshake ...... "
    if check_l3_tls "$ip" "$sni" "$port"; then
        echo -e "${G}✓ OK${N}"
        l3="ok"
    else
        echo -e "${Y}! WARN${N}"
        l3="warn"
    fi

    # L4 — HTTP decoy
    echo -ne "  L4 HTTP decoy ......... "
    if check_l4_http "$ip"; then
        echo -e "${G}✓ 200${N}"
        l4="ok"
    else
        echo -e "${Y}! non-200${N}"
        l4="warn"
    fi

    # L5 — GeoIP
    echo -ne "  L5 GeoIP .............. "
    l5_info=$(check_l5_ipregion "$ip")
    if [[ -n "$l5_info" ]]; then
        local country asn org
        country=$(echo "$l5_info" | cut -d'|' -f1)
        asn=$(echo     "$l5_info" | cut -d'|' -f2)
        org=$(echo     "$l5_info" | cut -d'|' -f3)
        echo -e "${G}${country}${N} | ${GR}${asn}${N} | ${org}"
        [[ "$country" == "RU" ]] && warn "  IP определяется как российский — могут быть проблемы с блокировками"
    else
        echo -e "${Y}? нет данных${N}"
    fi

    # L6 — Репутация
    echo -ne "  L6 Netflix/CDN ........ "
    l6_info=$(check_l6_reputation "$ip" 2>/dev/null || echo "skipped")
    echo -e "${GR}${l6_info}${N}"

    # L7 — РКН реестр
    echo -ne "  L7 РКН реестр ......... "
    l7_status=$(check_l7_rkn "$ip")
    if [[ "$l7_status" == "BLOCKED" ]]; then
        echo -e "${R}✗ ЗАБЛОКИРОВАН${N}"
        alert_needed=true
        _monitor_alert "ALERT" "$node_name" "L7: IP ${ip} в реестре РКН!"
    elif [[ "$l7_status" == "OK" ]]; then
        echo -e "${G}✓ OK${N}"
    else
        echo -e "${GR}? неизвестно${N}"
    fi

    echo ""

    # Обновляем статус ноды в nodes.conf
    if [[ "$l1" == "ok" && "$l2" == "ok" ]]; then
        _monitor_update_node_status "$ip" "ok"
    else
        _monitor_update_node_status "$ip" "error"
    fi

    return 0
}

_monitor_update_node_status() {
    local ip="${1}"
    local status="${2}"

    [[ ! -f "$NODES_CONF" ]] && return 0

    # Находим ноду по IP и обновляем статус
    while IFS= read -r node_name; do
        local node_host
        node_host=$(read_node "$node_name" "host" 2>/dev/null || echo "")
        if [[ "$node_host" == "$ip" ]]; then
            write_node "$node_name" "status" "$status" 2>/dev/null || true
            break
        fi
    done < <(list_nodes 2>/dev/null || true)
}

# =============================================================================
# ПРОВЕРКА ВСЕХ НОД (L1-L4)
# =============================================================================

fleet_monitor_all() {
    section "Мониторинг флота"

    if ! list_nodes &>/dev/null 2>&1; then
        warn "Fleet пуст — нет нод для мониторинга"
        return 0
    fi

    local total=0 ok=0 fail=0

    while IFS= read -r node_name; do
        local host port sni role
        host=$(read_node "$node_name" "host" 2>/dev/null || echo "")
        port=$(read_node "$node_name" "port" 2>/dev/null || echo "443")
        sni=$(read_node  "$node_name" "sni"  2>/dev/null || echo "www.microsoft.com")
        role=$(read_node "$node_name" "role" 2>/dev/null || echo "xray")

        [[ -z "$host" ]] && continue
        ((total++)) || true

        local xray_port="443"
        # Для Xray нод — проверяем порт 443
        [[ "$role" == *"remnawave"* ]] && xray_port="3000"

        echo -ne "  ${C}${node_name}${N} (${host}): "

        local l1_ok=true l2_ok=true
        check_l1_ping "$host"         || l1_ok=false
        check_l2_tcp  "$host" "$xray_port" || l2_ok=false

        if $l1_ok && $l2_ok; then
            echo -e "${G}✓ OK${N}"
            write_node "$node_name" "status" "ok" 2>/dev/null || true
            ((ok++)) || true
        elif ! $l1_ok; then
            echo -e "${R}✗ НЕДОСТУПЕН${N}"
            write_node "$node_name" "status" "error" 2>/dev/null || true
            _monitor_alert "ALERT" "$node_name" "сервер не отвечает на ping"
            ((fail++)) || true
        else
            echo -e "${Y}! порт ${xray_port} закрыт${N}"
            write_node "$node_name" "status" "error" 2>/dev/null || true
            _monitor_alert "WARN" "$node_name" "порт ${xray_port} недоступен"
            ((fail++)) || true
        fi
    done < <(list_nodes)

    echo ""
    echo -e "  ${BOLD}Итого:${N} ${G}${ok} OK${N} / ${R}${fail} FAIL${N} из ${total} нод"
}

# =============================================================================
# ТАБЛИЦА СТАТУСОВ FLEET
# =============================================================================

monitor_fleet_table() {
    section "Статус флота"

    if ! list_nodes &>/dev/null 2>&1; then
        warn "Нет нод в fleet"
        return 0
    fi

    printf "\n  %-14s %-18s %-8s %-22s %-10s\n" \
        "Нода" "IP" "Порт" "Роль" "Статус"
    printf "  %-14s %-18s %-8s %-22s %-10s\n" \
        "──────────────" "──────────────────" "────────" "──────────────────────" "──────────"

    while IFS= read -r node_name; do
        local host port role status installed
        host=$(read_node      "$node_name" "host"      2>/dev/null || echo "?")
        port=$(read_node      "$node_name" "port"      2>/dev/null || echo "22")
        role=$(read_node      "$node_name" "role"      2>/dev/null || echo "?")
        status=$(read_node    "$node_name" "status"    2>/dev/null || echo "?")
        installed=$(read_node "$node_name" "installed" 2>/dev/null || echo "?")

        local sc="${N}"
        case "$status" in
            ok)          sc="${G}" ;;
            error|fail*) sc="${R}" ;;
            pending)     sc="${Y}" ;;
            maintenance) sc="${Y}" ;;
        esac

        printf "  ${C}%-14s${N} %-18s %-8s %-22s ${sc}%-10s${N}\n" \
            "$node_name" "$host" "$port" "$role" "$status"
    done < <(list_nodes)

    echo ""
}

# =============================================================================
# TELEGRAM АЛЕРТЫ
# =============================================================================

_monitor_alert() {
    local level="${1}"   # ALERT | WARN | INFO
    local node="${2}"
    local msg="${3}"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    # Лог всегда
    echo "[${ts}] ${level}: ${node} — ${msg}" >> "${ORCHESTRA_LOG}" 2>/dev/null || true

    # Telegram — только если настроен
    [[ -z "${MONITOR_TG_TOKEN:-}" || -z "${MONITOR_TG_CHAT_ID:-}" ]] && return 0

    local emoji="⚠️"
    [[ "$level" == "ALERT" ]] && emoji="🚨"
    [[ "$level" == "INFO"  ]] && emoji="ℹ️"

    local text="${emoji} *Orchestra Monitor*
Node: \`${node}\`
Status: *${level}*
Message: ${msg}
Time: ${ts}"

    curl -s --max-time 10 \
        "https://api.telegram.org/bot${MONITOR_TG_TOKEN}/sendMessage" \
        -d "chat_id=${MONITOR_TG_CHAT_ID}" \
        -d "parse_mode=Markdown" \
        -d "text=${text}" \
        -o /dev/null 2>/dev/null || true
}

monitor_setup_telegram() {
    section "Настройка Telegram алертов"

    hint "Telegram Bot для алертов" \
        "1. Напиши @BotFather → /newbot → получи токен" \
        "2. Напиши боту /start" \
        "3. Узнай свой chat_id: @userinfobot"

    ask_secret "Bot Token (Enter — пропустить)"
    [[ -z "$REPLY" ]] && return 0
    MONITOR_TG_TOKEN="$REPLY"

    ask "Telegram Chat ID" ""
    MONITOR_TG_CHAT_ID="$REPLY"
    [[ -z "$MONITOR_TG_CHAT_ID" ]] && return 0

    # Тест
    local test_result
    test_result=$(curl -s --max-time 10 \
        "https://api.telegram.org/bot${MONITOR_TG_TOKEN}/sendMessage" \
        -d "chat_id=${MONITOR_TG_CHAT_ID}" \
        -d "text=🔔 Orchestra Monitor подключён!" \
        2>/dev/null)

    if echo "$test_result" | grep -q '"ok":true'; then
        info "Telegram алерты настроены"

        # Сохраняем в конфиг
        local server_ip
        server_ip=$(get_server_ip 2>/dev/null) || server_ip="local"
        state_set "$server_ip" "MONITOR_TG_TOKEN"   "$MONITOR_TG_TOKEN"
        state_set "$server_ip" "MONITOR_TG_CHAT_ID" "$MONITOR_TG_CHAT_ID"
    else
        error "Ошибка отправки сообщения — проверь токен и chat_id"
        echo "$test_result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('description','?'))" 2>/dev/null || true
    fi
}

monitor_send_test() {
    _monitor_alert "INFO" "test" "Тестовое сообщение от Orchestra Monitor"
    info "Тестовое сообщение отправлено"
}

# =============================================================================
# DAEMON РЕЖИМ (фоновый мониторинг)
# =============================================================================

monitor_start_daemon() {
    local pid_file="/var/run/orchestra-monitor.pid"
    local daemon_script="/opt/orchestra/monitor-daemon.sh"

    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        warn "Daemon уже запущен (PID $(cat "$pid_file"))"
        return 0
    fi

    # Загружаем настройки Telegram из state
    local server_ip
    server_ip=$(get_server_ip 2>/dev/null) || server_ip="local"
    MONITOR_TG_TOKEN=$(state_get "$server_ip" "MONITOR_TG_TOKEN" 2>/dev/null || echo "")
    MONITOR_TG_CHAT_ID=$(state_get "$server_ip" "MONITOR_TG_CHAT_ID" 2>/dev/null || echo "")

    ask "Интервал проверки (секунд)" "300"
    MONITOR_INTERVAL="$REPLY"

    # Создаём daemon скрипт
    cat > "$daemon_script" << DAEMONEOF
#!/usr/bin/env bash
set -euo pipefail

ORCHESTRA_DIR="${ORCHESTRA_DIR}"
source "\${ORCHESTRA_DIR}/orchestra.sh"
source "\${ORCHESTRA_DIR}/lib/monitor.sh"

MONITOR_TG_TOKEN="${MONITOR_TG_TOKEN}"
MONITOR_TG_CHAT_ID="${MONITOR_TG_CHAT_ID}"
MONITOR_INTERVAL="${MONITOR_INTERVAL}"

_monitor_alert "INFO" "daemon" "Orchestra Monitor daemon запущен (интервал: \${MONITOR_INTERVAL}s)"

while true; do
    while IFS= read -r node_name; do
        host=\$(read_node "\$node_name" "host" 2>/dev/null || echo "")
        [[ -z "\$host" ]] && continue

        if ! check_l1_ping "\$host"; then
            _monitor_alert "ALERT" "\$node_name" "L1: сервер недоступен!"
        elif ! check_l2_tcp "\$host" "443"; then
            _monitor_alert "ALERT" "\$node_name" "L2: порт 443 закрыт"
        fi

        rkn=\$(check_l7_rkn "\$host")
        [[ "\$rkn" == "BLOCKED" ]] && _monitor_alert "ALERT" "\$node_name" "L7: IP заблокирован РКН!"
    done < <(list_nodes 2>/dev/null || true)

    sleep "\$MONITOR_INTERVAL"
done
DAEMONEOF

    chmod +x "$daemon_script"

    # Запускаем в фоне через nohup + screen (надёжнее чем просто &)
    if command -v screen &>/dev/null; then
        screen -dmS orchestra-monitor bash "$daemon_script"
        info "Daemon запущен в screen-сессии 'orchestra-monitor'"
        info "Просмотр: screen -r orchestra-monitor"
    else
        nohup bash "$daemon_script" >> "${ORCHESTRA_LOG}" 2>&1 &
        echo $! > "$pid_file"
        info "Daemon запущен (PID $!)"
    fi
}

monitor_stop_daemon() {
    local pid_file="/var/run/orchestra-monitor.pid"

    # Останавливаем screen-сессию
    if command -v screen &>/dev/null && screen -list 2>/dev/null | grep -q orchestra-monitor; then
        screen -S orchestra-monitor -X quit 2>/dev/null || true
        info "Screen-сессия orchestra-monitor остановлена"
        return 0
    fi

    # Останавливаем по PID
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            rm -f "$pid_file"
            info "Daemon (PID ${pid}) остановлен"
        else
            warn "Daemon не запущен (PID ${pid} не существует)"
            rm -f "$pid_file"
        fi
    else
        warn "Daemon не запущен"
    fi
}
