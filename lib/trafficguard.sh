#!/usr/bin/env bash
# =============================================================================
# trafficguard.sh — Блокировка сканеров и РКН сетей
# Модуль Orchestra | Этап 7
# =============================================================================
set -euo pipefail

[[ -n "${TRAFFICGUARD_MODULE_LOADED:-}" ]] && return 0
readonly TRAFFICGUARD_MODULE_LOADED=1

readonly TG_BIN="/usr/local/bin/traffic-guard"
readonly TG_LOG="/var/log/traffic-guard.log"
readonly TG_CRON="/etc/cron.d/trafficguard-orchestra"

readonly TG_LIST_GOVT="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list"
readonly TG_LIST_SCAN="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list"

# =============================================================================
# МЕНЮ
# =============================================================================

trafficguard_menu() {
    clear
    section "trafficguard — Блокировка сканеров РКН"

    if command -v traffic-guard &>/dev/null; then
        echo -e "  ${G}✓${N} TrafficGuard установлен"
    else
        echo -e "  ${Y}!${N} TrafficGuard не установлен"
    fi
    echo ""

    echo -e "  ${C}1${N}) Установить TrafficGuard"
    echo -e "  ${C}2${N}) Обновить списки блокировок"
    echo -e "  ${C}3${N}) Статус (заблокировано IP/сетей)"
    echo -e "  ${C}4${N}) Удалить все блокировки"
    echo -e "  ${C}5${N}) Удалить TrafficGuard"
    echo -e "  ${C}0${N}) Назад"
    echo ""

    ask "Выбор" "1"
    case "$REPLY" in
        1) trafficguard_install ;;
        2) trafficguard_update ;;
        3) trafficguard_status ;;
        4) trafficguard_flush ;;
        5) trafficguard_uninstall ;;
        0) return 0 ;;
        *) warn "Неверный выбор" ;;
    esac
}

# =============================================================================
# УСТАНОВКА
# =============================================================================

trafficguard_install() {
    section "Установка TrafficGuard"

    if command -v traffic-guard &>/dev/null; then
        info "TrafficGuard уже установлен"
        trafficguard_update
        return 0
    fi

    # Зависимости
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        iptables ipset curl \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" 2>/dev/null || true

    # Установка через официальный скрипт
    step_msg "Загружаем установщик TrafficGuard..."
    curl -fsSL https://raw.githubusercontent.com/dotX12/traffic-guard/master/install.sh \
        | bash 2>&1 | tail -5 \
        || { error "Ошибка установки TrafficGuard"; return 1; }

    if ! command -v traffic-guard &>/dev/null; then
        error "TrafficGuard не найден после установки"
        return 1
    fi

    info "TrafficGuard установлен: ${TG_BIN}"

    # Применяем списки
    trafficguard_update

    # Настраиваем cron
    _trafficguard_setup_cron

    return 0
}

# =============================================================================
# ОБНОВЛЕНИЕ СПИСКОВ
# =============================================================================

trafficguard_update() {
    section "Обновление списков блокировок"

    command -v traffic-guard &>/dev/null || { error "TrafficGuard не установлен"; return 1; }

    step_msg "Применяем списки РКН и антисканеров..."
    traffic-guard full \
        -u "${TG_LIST_GOVT}" \
        -u "${TG_LIST_SCAN}" \
        2>&1 | tail -10 \
        || { error "Ошибка обновления списков"; return 1; }

    info "Списки блокировок обновлены"
    trafficguard_status
}

# =============================================================================
# СТАТУС
# =============================================================================

trafficguard_status() {
    section "Статус TrafficGuard"

    if ! command -v ipset &>/dev/null; then
        warn "ipset не установлен"
        return 0
    fi

    local sets
    sets=$(ipset list -n 2>/dev/null | grep -E "traffic|blocked|government|antiscanner" || echo "")

    if [[ -z "$sets" ]]; then
        warn "Активных ipset-сетей TrafficGuard не найдено"
    else
        echo -e "  ${BOLD}Активные ipset наборы:${N}"
        while IFS= read -r set_name; do
            local count
            count=$(ipset list "$set_name" 2>/dev/null | grep -c "^[0-9]" || echo "?")
            echo -e "  ${G}✓${N} ${set_name}: ${count} записей"
        done <<< "$sets"
    fi

    # iptables правила TrafficGuard
    echo ""
    echo -e "  ${BOLD}iptables правила:${N}"
    iptables -L INPUT -n --line-numbers 2>/dev/null | \
        grep -E "match-set|DROP|traffic" | head -10 | \
        while IFS= read -r line; do echo "    ${line}"; done || \
        echo -e "    ${GR}нет правил${N}"

    # Лог (последние записи)
    if [[ -f "$TG_LOG" ]]; then
        echo ""
        echo -e "  ${BOLD}Последние записи лога:${N}"
        tail -5 "$TG_LOG" | while IFS= read -r line; do echo "    ${line}"; done
    fi
}

# =============================================================================
# СБРОС БЛОКИРОВОК
# =============================================================================

trafficguard_flush() {
    ask_yn "Удалить все правила TrafficGuard (iptables + ipset)?" "нет"
    [[ $? -ne 0 ]] && return 0

    # Очищаем iptables правила связанные с ipset
    iptables -L INPUT -n --line-numbers 2>/dev/null | \
        grep "match-set" | awk '{print $1}' | sort -rn | \
        while read -r num; do
            iptables -D INPUT "$num" 2>/dev/null || true
        done

    # Удаляем ipset наборы
    ipset list -n 2>/dev/null | grep -E "traffic|blocked|government|antiscanner" | \
        while IFS= read -r set_name; do
            ipset destroy "$set_name" 2>/dev/null || true
            echo -e "  ${GR}Удалён ipset:${N} ${set_name}"
        done

    warn "Все блокировки TrafficGuard сброшены"
}

# =============================================================================
# УДАЛЕНИЕ
# =============================================================================

trafficguard_uninstall() {
    ask_yn "Удалить TrafficGuard полностью?" "нет"
    [[ $? -ne 0 ]] && return 0

    trafficguard_flush

    rm -f "$TG_BIN" "$TG_CRON"
    info "TrafficGuard удалён"
}

# =============================================================================
# CRON
# =============================================================================

_trafficguard_setup_cron() {
    cat > "$TG_CRON" << EOF
# Orchestra — TrafficGuard обновление списков каждый час
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

0 * * * * root traffic-guard full -u ${TG_LIST_GOVT} -u ${TG_LIST_SCAN} >> ${TG_LOG} 2>&1
EOF
    chmod 644 "$TG_CRON"
    info "Cron: обновление списков каждый час"
}
