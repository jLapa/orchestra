#!/usr/bin/env bash
# =============================================================================
# warp.sh — Cloudflare WARP управление
# Модуль Orchestra | Этап 7
# =============================================================================
set -euo pipefail

[[ -n "${WARP_MODULE_LOADED:-}" ]] && return 0
readonly WARP_MODULE_LOADED=1

# =============================================================================
# МЕНЮ МОДУЛЯ
# =============================================================================

warp_menu() {
    clear
    section "warp — Cloudflare WARP"

    # Текущий статус
    if command -v warp-cli &>/dev/null; then
        local status
        status=$(warp-cli --accept-tos status 2>/dev/null | head -1 || echo "не определён")
        echo -e "  ${GR}Статус WARP:${N} ${status}"
    else
        echo -e "  ${Y}!${N} WARP не установлен"
    fi
    echo ""

    echo -e "  ${C}1${N}) Установить WARP"
    echo -e "  ${C}2${N}) Подключить / переподключить"
    echo -e "  ${C}3${N}) Отключить"
    echo -e "  ${C}4${N}) Статус и статистика"
    echo -e "  ${C}5${N}) Проверить внешний IP через WARP"
    echo -e "  ${C}6${N}) Удалить WARP"
    echo -e "  ${C}0${N}) Назад"
    echo ""

    ask "Выбор" "1"
    case "$REPLY" in
        1) warp_install ;;
        2) warp_connect ;;
        3) warp_disconnect ;;
        4) warp_status ;;
        5) warp_check_ip ;;
        6) warp_uninstall ;;
        0) return 0 ;;
        *) warn "Неверный выбор" ;;
    esac
}

# =============================================================================
# УСТАНОВКА
# =============================================================================

warp_install() {
    section "Установка Cloudflare WARP"

    if command -v warp-cli &>/dev/null; then
        info "WARP уже установлен"
        warp_connect
        return 0
    fi

    # Репозиторий Cloudflare
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor \
        -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
        || { error "Ошибка получения GPG ключа Cloudflare"; return 1; }

    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
https://pkg.cloudflareclient.com/ bookworm main" \
        > /etc/apt/sources.list.d/cloudflare-client.list

    apt-get update -qq 2>/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cloudflare-warp \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        2>&1 | grep -E "^(Setting up|already)" || true

    systemctl enable warp-svc
    systemctl start warp-svc
    sleep 5

    info "WARP установлен"
    warp_connect
}

# =============================================================================
# ПОДКЛЮЧЕНИЕ
# =============================================================================

warp_connect() {
    section "Подключение WARP"

    if ! command -v warp-cli &>/dev/null; then
        error "WARP не установлен — сначала установи (пункт 1)"
        return 1
    fi

    # Сбрасываем старую регистрацию
    warp-cli --accept-tos registration delete 2>/dev/null || true
    sleep 2

    # Новая регистрация
    warp-cli --accept-tos registration new || { error "Ошибка регистрации"; return 1; }

    # Режим proxy (SOCKS5 на локальном порту)
    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos proxy port 40000
    warp-cli --accept-tos connect

    # Ждём подключения
    local waited=0
    step_msg "Ожидаю подключения WARP..."
    while [[ $waited -lt 30 ]]; do
        if warp-cli --accept-tos status 2>/dev/null | grep -q "Connected"; then
            break
        fi
        sleep 2
        ((waited+=2)) || true
        echo -n "."
    done
    echo ""

    if warp-cli --accept-tos status 2>/dev/null | grep -q "Connected"; then
        info "WARP подключён"
        warp_check_ip
    else
        warn "WARP не подключился — проверь логи: journalctl -u warp-svc -n 20"
        return 1
    fi
}

# =============================================================================
# ОТКЛЮЧЕНИЕ
# =============================================================================

warp_disconnect() {
    warp-cli --accept-tos disconnect 2>/dev/null || true
    info "WARP отключён"
    warn "Xray теперь использует прямое подключение"
    warn "Перезапусти Xray если нужно изменить outbound: systemctl restart xray"
}

# =============================================================================
# СТАТУС
# =============================================================================

warp_status() {
    section "Статус WARP"

    if ! command -v warp-cli &>/dev/null; then
        warn "WARP не установлен"
        return 0
    fi

    warp-cli --accept-tos status 2>/dev/null
    echo ""

    # Проверяем что SOCKS5 слушает
    if ss -tlnp 2>/dev/null | grep -q ":40000"; then
        info "SOCKS5 proxy слушает на 127.0.0.1:40000"
    else
        warn "SOCKS5 proxy не найден на порту 40000"
    fi

    # Systemd
    systemctl status warp-svc --no-pager -l 2>/dev/null | head -10 || true
}

# =============================================================================
# ПРОВЕРКА ВНЕШНЕГО IP
# =============================================================================

warp_check_ip() {
    echo ""
    step_msg "Прямой IP сервера:"
    local direct_ip
    direct_ip=$(curl -4s https://ifconfig.me --max-time 8 2>/dev/null || echo "?")
    echo -e "  ${GR}Прямой:${N} ${direct_ip}"

    step_msg "IP через WARP SOCKS5:"
    local warp_ip
    warp_ip=$(curl -4s --socks5 127.0.0.1:40000 https://ifconfig.me --max-time 10 2>/dev/null || echo "недоступен")
    echo -e "  ${GR}WARP:${N}   ${warp_ip}"

    if [[ "$direct_ip" != "$warp_ip" && "$warp_ip" != "недоступен" ]]; then
        info "WARP работает: трафик выходит через ${warp_ip}"
    elif [[ "$warp_ip" == "недоступен" ]]; then
        warn "WARP SOCKS5 не отвечает"
    else
        warn "IP совпадает — WARP может не работать как outbound"
    fi
}

# =============================================================================
# УДАЛЕНИЕ
# =============================================================================

warp_uninstall() {
    ask_yn "Удалить Cloudflare WARP полностью?" "нет"
    [[ $? -ne 0 ]] && return 0

    warp-cli --accept-tos disconnect 2>/dev/null || true
    warp-cli --accept-tos registration delete 2>/dev/null || true
    systemctl stop warp-svc 2>/dev/null || true
    systemctl disable warp-svc 2>/dev/null || true

    DEBIAN_FRONTEND=noninteractive apt-get remove -y cloudflare-warp 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

    info "WARP удалён"
    warn "Обнови конфиг Xray чтобы использовать прямой outbound"
}
