#!/usr/bin/env bash
# =============================================================================
# sys.sh — Базовый hardening системы
# Модуль Orchestra | Этап 2
# =============================================================================
# Загружается через: source lib/sys.sh
# Требует: orchestra.sh уже загружен (функции info/warn/error/run_step/etc.)
# =============================================================================
set -euo pipefail

# Защита от повторного source
[[ -n "${SYS_MODULE_LOADED:-}" ]] && return 0
readonly SYS_MODULE_LOADED=1

# =============================================================================
# КОНФИГУРАЦИЯ МОДУЛЯ (заполняется через sys_collect_config)
# =============================================================================

SYS_SSH_PORT=""
SYS_ADMIN_IP=""
SYS_DISABLE_IPV6=""
SYS_NTP_SERVER="pool.ntp.org"
SYS_TIMEZONE="Europe/Moscow"
SYS_PERMIT_ROOT="prohibit-password"  # yes | prohibit-password | no
SYS_INSTALL_BBR="yes"

# =============================================================================
# МЕНЮ МОДУЛЯ
# =============================================================================

sys_menu() {
    clear
    section "sys — Hardening системы"

    echo -e "  ${C}1${N}) Полная установка (SSH + UFW + BBR + sysctl + fail2ban + NTP)"
    echo -e "  ${C}2${N}) Только sysctl + BBR"
    echo -e "  ${C}3${N}) Только SSH hardening"
    echo -e "  ${C}4${N}) Только UFW файрвол"
    echo -e "  ${C}5${N}) Только fail2ban"
    echo -e "  ${C}6${N}) NTP / часовой пояс"
    echo -e "  ${C}7${N}) Статус hardening"
    echo -e "  ${C}0${N}) Назад"
    echo ""

    ask "Выбор" "1"
    local choice="$REPLY"

    case "$choice" in
        1) sys_full_install ;;
        2) sys_apply_sysctl ;;
        3) sys_setup_ssh_interactive ;;
        4) sys_setup_ufw_interactive ;;
        5) sys_setup_fail2ban_interactive ;;
        6) sys_setup_ntp_interactive ;;
        7) sys_show_status ;;
        0) return 0 ;;
        *) warn "Неизвестный выбор" ;;
    esac
}

# =============================================================================
# ПОЛНАЯ УСТАНОВКА
# =============================================================================

sys_full_install() {
    section "Полный hardening системы"

    # Сбор конфигурации
    sys_collect_config

    # Итоговая сводка
    sys_show_config_summary

    ask_yn "Начать hardening?" "да" || { warn "Отменено"; return 1; }

    # Инициализация прогресса
    local server_ip
    server_ip=$(get_server_ip 2>/dev/null) || server_ip="local"
    init_progress "sys" "${server_ip}"
    check_resume_prompt

    echo ""
    section "Установка — прогресс"

    run_step "update_packages"    _sys_update_packages    "Обновление пакетов"
    run_step "install_deps"       _sys_install_deps       "Установка зависимостей"
    run_step "apply_sysctl"       _sys_apply_sysctl       "Применение sysctl (BBR + оптимизация)"
    run_step "setup_ufw"          _sys_setup_ufw          "Файрвол UFW"
    run_step "setup_ssh"          _sys_setup_ssh          "SSH hardening"
    run_step "setup_fail2ban"     _sys_setup_fail2ban     "fail2ban (защита от брутфорса)"
    run_step "setup_ntp"          _sys_setup_ntp          "NTP (синхронизация времени)"
    run_step "setup_logrotate"    _sys_setup_logrotate    "Logrotate"
    run_step "setup_autoupdate"   _sys_setup_autoupdate   "Автообновления безопасности"
    run_step "finalize_sys"       _sys_finalize           "Итог"

    mark_module_done "sys" "${server_ip}"

    # Сохраняем конфиг
    state_set "${server_ip}" "SSH_PORT" "${SYS_SSH_PORT}"
    state_set "${server_ip}" "ADMIN_IP" "${SYS_ADMIN_IP}"
    state_set "${server_ip}" "IPV6_DISABLED" "${SYS_DISABLE_IPV6}"
}

# =============================================================================
# СБОР КОНФИГУРАЦИИ
# =============================================================================

sys_collect_config() {
    section "Конфигурация hardening"

    # SSH порт
    hint "SSH порт" \
        "Стандартный порт 22 сканируется ботами постоянно." \
        "Рекомендуем: 2222, 22222 или любой 1024-65535." \
        "ВАЖНО: не забудь открыть этот порт в UFW до смены!"
    ask "SSH порт" "2222"
    SYS_SSH_PORT="$REPLY"

    # Валидация порта
    if ! [[ "$SYS_SSH_PORT" =~ ^[0-9]+$ ]] || \
       [[ "$SYS_SSH_PORT" -lt 1 ]] || \
       [[ "$SYS_SSH_PORT" -gt 65535 ]]; then
        error "Некорректный порт: ${SYS_SSH_PORT}"
        return 1
    fi

    # IP администратора для whitelist
    hint "IP администратора" \
        "Этот IP будет добавлен в whitelist fail2ban и UFW." \
        "Рекомендуем указать свой реальный IP." \
        "Узнать свой IP: https://ifconfig.me" \
        "Оставь пустым — whitelist не создаётся (риск самоблокировки!)"
    ask "Ваш IP для whitelist (Enter — пропустить)" ""
    SYS_ADMIN_IP="$REPLY"

    if [[ -n "$SYS_ADMIN_IP" ]] && \
       ! [[ "$SYS_ADMIN_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        warn "Некорректный IP: ${SYS_ADMIN_IP}, whitelist не будет создан"
        SYS_ADMIN_IP=""
    fi

    # IPv6
    ask_yn "Отключить IPv6? (рекомендуется для VPN-серверов)" "да"
    SYS_DISABLE_IPV6=$([ $? -eq 0 ] && echo "yes" || echo "no")

    # Часовой пояс
    ask "Часовой пояс" "Europe/Moscow"
    SYS_TIMEZONE="$REPLY"

    # NTP сервер
    ask "NTP сервер" "pool.ntp.org"
    SYS_NTP_SERVER="$REPLY"
}

# Сводка конфигурации перед установкой
sys_show_config_summary() {
    echo ""
    echo -e "${BOLD}  Параметры hardening:${N}"
    echo -e "  ${GR}SSH порт:${N}         ${SYS_SSH_PORT}"
    echo -e "  ${GR}Admin IP whitelist:${N} ${SYS_ADMIN_IP:-не задан}"
    echo -e "  ${GR}Отключить IPv6:${N}   ${SYS_DISABLE_IPV6}"
    echo -e "  ${GR}Часовой пояс:${N}     ${SYS_TIMEZONE}"
    echo -e "  ${GR}NTP сервер:${N}       ${SYS_NTP_SERVER}"
    echo ""
}

# =============================================================================
# ШАГИ УСТАНОВКИ (внутренние функции с префиксом _sys_)
# =============================================================================

_sys_update_packages() {
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq
    apt-get upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

    return 0
}

_sys_install_deps() {
    local packages=(
        curl wget gnupg2 ca-certificates
        ufw fail2ban
        chrony
        logrotate
        unattended-upgrades apt-listchanges
        net-tools iproute2 iptables ipset
        lsof htop
        openssl
        python3
        git
        jq
        dnsutils
        iputils-ping
        netcat-openbsd
    )

    apt-get install -y -qq "${packages[@]}" \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

    return 0
}

# =============================================================================
# SYSCTL + BBR
# =============================================================================

_sys_apply_sysctl() {
    # Проверяем поддержку BBR
    local bbr_available=false
    if modprobe tcp_bbr 2>/dev/null; then
        bbr_available=true
    fi

    # Записываем конфиг
    cat > /etc/sysctl.d/99-orchestra.conf << 'SYSCTL_EOF'
# =============================================================================
# Orchestra — sysctl оптимизация
# ВНИМАНИЕ: не редактируй вручную — файл перезаписывается orchestra
# =============================================================================

# --- IPv6 ---
# Отключаем IPv6 (генерируем ссылки через IPv4)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# --- IP Forwarding ---
# ip_forward=1 нужен для WARP/WireGuard
net.ipv4.ip_forward = 1

# --- rp_filter ---
# ВАЖНО: =2 (loose), НЕ =1 (strict) — strict ломает асимметричный роутинг WARP
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# --- Защита от спуфинга ---
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.default.accept_source_route = 0

# --- ICMP ---
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ratelimit = 100
net.ipv4.icmp_ignore_bogus_error_responses = 1

# --- TCP hardening ---
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192

# --- TCP оптимизация ---
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_sack = 1
# ECN=2 (accept but don't initiate) — некоторые провайдеры дропают ECN=1
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 9
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# --- Сетевые буферы ---
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 5000

# --- BBR (обязательно) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Безопасность ядра ---
kernel.yama.ptrace_scope = 1
kernel.randomize_va_space = 2
fs.suid_dumpable = 0

# --- Файловые дескрипторы ---
fs.file-max = 2097152

# --- Память ---
# swappiness=10, НЕ =0 — при =0 риск OOM killer
vm.swappiness = 10

# УБРАНО: tcp_fack (удалён из ядра 4.20+, вызывает ошибку на Debian 12)
# УБРАНО: log_martians (спамит syslog на нагруженных серверах)
# УБРАНО: лишние IPv6 параметры при disable_ipv6=1
SYSCTL_EOF

    # Если IPv6 НЕ отключаем — убираем блок IPv6 из конфига
    if [[ "${SYS_DISABLE_IPV6}" == "no" ]]; then
        sed -i '/disable_ipv6/d' /etc/sysctl.d/99-orchestra.conf
    fi

    # Применяем через sysctl -p — корректно обрабатывает многозначные параметры
    # (tcp_rmem, tcp_wmem содержат пробелы — sysctl -w без кавычек их ломает)
    local sysctl_out
    sysctl_out=$(sysctl -p /etc/sysctl.d/99-orchestra.conf 2>&1) || true
    # Фильтруем реальные ошибки (не просто вывод применённых параметров)
    echo "$sysctl_out" | grep -iE "^sysctl:.*error|unknown key|invalid" | \
        while IFS= read -r sysctl_err; do
            warn "sysctl: ${sysctl_err}"
        done || true

    # Проверяем BBR
    if [[ "$bbr_available" == "true" ]]; then
        local active_cc
        active_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
        if [[ "$active_cc" == "bbr" ]]; then
            info "BBR активен: ${active_cc}"
        else
            warn "BBR не активен (текущий: ${active_cc}) — возможно, нужна перезагрузка"
        fi
    else
        warn "BBR недоступен на этом ядре — параметры сохранены, применятся после обновления ядра"
    fi

    return 0
}

# Публичная функция для вызова из меню без full install
sys_apply_sysctl() {
    section "Применение sysctl + BBR"
    SYS_DISABLE_IPV6="${SYS_DISABLE_IPV6:-yes}"
    _sys_apply_sysctl
}

# =============================================================================
# SSH HARDENING
# =============================================================================

_sys_setup_ssh() {
    local sshd_config="/etc/ssh/sshd_config"
    local backup_file="/etc/ssh/sshd_config.orchestra-backup"

    # Бэкап оригинального конфига
    [[ ! -f "$backup_file" ]] && cp "$sshd_config" "$backup_file"

    # Генерируем новый конфиг
    cat > /etc/ssh/sshd_config.d/99-orchestra.conf << EOF
# Orchestra SSH hardening
# Резервная копия оригинала: ${backup_file}

Port ${SYS_SSH_PORT}

# Аутентификация
PermitRootLogin ${SYS_PERMIT_ROOT}
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no

# Безопасность сессий
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
MaxAuthTries 4
MaxSessions 10
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2

# Отключаем устаревшие протоколы
Protocol 2
HostbasedAuthentication no
IgnoreRhosts yes

# Баннер
Banner none
EOF

    # Проверяем синтаксис конфига
    if ! sshd -t 2>/dev/null; then
        warn "Ошибка синтаксиса sshd_config — откатываем"
        rm -f /etc/ssh/sshd_config.d/99-orchestra.conf
        return 1
    fi

    # Запоминаем текущий порт до перезапуска
    local old_ssh_port
    old_ssh_port=$(ss -tlnp 2>/dev/null | grep -E 'sshd|ssh' | \
        awk '{print $4}' | grep -oP ':\K[0-9]+' | head -1 || echo "22")

    # Перезапускаем SSH — ОСТОРОЖНО: сессия может прерваться!
    # Используем reload вместо restart чтобы не убить текущую сессию
    if systemctl is-active --quiet ssh 2>/dev/null; then
        systemctl reload ssh
    elif systemctl is-active --quiet sshd 2>/dev/null; then
        systemctl reload sshd
    else
        warn "SSH сервис не найден — конфиг записан, перезапусти вручную"
    fi

    # Ждём пока SSH начнёт слушать на новом порту (до 10 сек)
    local waited=0
    while [[ $waited -lt 10 ]]; do
        if ss -tlnp 2>/dev/null | grep -E 'sshd|ssh' | grep -q ":${SYS_SSH_PORT}"; then
            break
        fi
        sleep 1
        ((waited++)) || true
    done

    # Удаляем временное UFW-правило для старого порта если UFW активен
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        _sys_ufw_remove_temp_ssh "${old_ssh_port}" "${SYS_SSH_PORT}" 2>/dev/null || true
    fi

    warn "SSH теперь слушает на порту ${SYS_SSH_PORT}"
    warn "Для следующего подключения: ssh -p ${SYS_SSH_PORT} root@<ip>"

    return 0
}

sys_setup_ssh_interactive() {
    section "SSH Hardening"
    hint "SSH Hardening" \
        "Меняем порт SSH для снижения количества атак ботов." \
        "После смены порта ОБЯЗАТЕЛЬНО открой новый порт в UFW." \
        "Текущая SSH-сессия останется активной."
    ask "SSH порт" "2222"
    SYS_SSH_PORT="$REPLY"
    _sys_setup_ssh
}

# =============================================================================
# UFW ФАЙРВОЛ
# =============================================================================

_sys_setup_ufw() {
    # Определяем ТЕКУЩИЙ активный SSH-порт (до смены)
    # БЕЗОПАСНОСТЬ: открываем его ПЕРВЫМ — иначе локаут при аварии
    local current_ssh_port
    current_ssh_port=$(ss -tlnp 2>/dev/null | grep -E 'sshd|ssh' | \
        awk '{print $4}' | grep -oP ':\K[0-9]+' | head -1 || echo "22")
    [[ -z "$current_ssh_port" ]] && current_ssh_port="22"

    # Отключаем IPv6 в UFW если IPv6 отключён глобально
    if [[ "${SYS_DISABLE_IPV6:-yes}" == "yes" ]] && [[ -f /etc/default/ufw ]]; then
        sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw
    fi

    # Сбрасываем правила UFW
    ufw --force reset 2>/dev/null || true

    # По умолчанию — всё запрещаем входящее, исходящее разрешаем
    ufw default deny incoming
    ufw default allow outgoing

    # ПЕРВОЕ ПРАВИЛО: текущий SSH-порт (защита от локаута при аварии)
    if [[ "$current_ssh_port" != "$SYS_SSH_PORT" ]]; then
        ufw allow "${current_ssh_port}/tcp" comment "SSH current (temp)"
        warn "Временно открыт текущий SSH-порт ${current_ssh_port} до перезапуска SSH"
    fi

    # Новый SSH-порт
    ufw allow "${SYS_SSH_PORT}/tcp" comment "SSH"

    # Стандартные порты VPN
    ufw allow 80/tcp  comment "HTTP (certbot + decoy)"
    ufw allow 443/tcp comment "HTTPS / Xray"

    # Whitelist администратора
    if [[ -n "${SYS_ADMIN_IP:-}" ]]; then
        ufw allow from "${SYS_ADMIN_IP}" comment "Admin whitelist"
        info "UFW whitelist добавлен для ${SYS_ADMIN_IP}"
    fi

    # Отключаем логирование UFW (спамит в консоль)
    ufw logging off

    # Включаем UFW без интерактивного запроса
    ufw --force enable

    info "UFW включён. Статус:"
    ufw status numbered

    return 0
}

# Удалить временное правило текущего SSH-порта после успешного перемещения
# Вызывается в конце _sys_setup_ssh когда SSH уже слушает на новом порту
_sys_ufw_remove_temp_ssh() {
    local current_ssh_port="${1}"
    local new_ssh_port="${2}"

    [[ "$current_ssh_port" == "$new_ssh_port" ]] && return 0
    [[ -z "$current_ssh_port" ]] && return 0

    # Удаляем временное правило для старого порта
    local rule_num
    rule_num=$(ufw status numbered 2>/dev/null | \
        grep "${current_ssh_port}/tcp.*SSH current" | \
        grep -oP '^\[\s*\K[0-9]+' | head -1)

    if [[ -n "$rule_num" ]]; then
        ufw --force delete "${rule_num}" 2>/dev/null || true
        info "UFW: временное правило для порта ${current_ssh_port} удалено"
    fi
}

sys_setup_ufw_interactive() {
    section "Настройка UFW"

    ask "SSH порт (должен совпадать с текущим)" "2222"
    SYS_SSH_PORT="$REPLY"

    ask "IP администратора для whitelist (Enter — пропустить)" ""
    SYS_ADMIN_IP="$REPLY"

    _sys_setup_ufw
}

# Открыть порт в UFW (публичная утилита для других модулей)
ufw_allow() {
    local port="${1}"
    local proto="${2:-tcp}"
    local comment="${3:-orchestra}"

    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "${port}/${proto}" comment "${comment}" 2>/dev/null || true
        info "UFW: открыт порт ${port}/${proto}"
    fi
}

# =============================================================================
# FAIL2BAN
# =============================================================================

_sys_setup_fail2ban() {
    # Главный конфиг orchestra
    cat > /etc/fail2ban/jail.d/orchestra.conf << EOF
[DEFAULT]
bantime  = 7d
findtime = 10m
maxretry = 3
banaction = iptables-multiport
backend = auto

# Whitelist администратора
$([ -n "${SYS_ADMIN_IP:-}" ] && echo "ignoreip = 127.0.0.1/8 ::1 ${SYS_ADMIN_IP}" || echo "ignoreip = 127.0.0.1/8 ::1")

[sshd]
enabled  = true
port     = ${SYS_SSH_PORT}
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 7d
EOF

    # Запускаем fail2ban
    systemctl enable fail2ban
    systemctl restart fail2ban

    # Проверяем статус
    sleep 2
    if fail2ban-client status sshd &>/dev/null; then
        info "fail2ban активен, jail sshd запущен"
    else
        warn "fail2ban запущен, но jail sshd ещё инициализируется"
    fi

    return 0
}

sys_setup_fail2ban_interactive() {
    section "Настройка fail2ban"

    ask "SSH порт (для jail)" "2222"
    SYS_SSH_PORT="$REPLY"

    ask "IP администратора для whitelist (Enter — пропустить)" ""
    SYS_ADMIN_IP="$REPLY"

    _sys_setup_fail2ban
}

# Добавить кастомный jail fail2ban (используется другими модулями)
# fail2ban_add_jail "xray" "/var/log/xray/*.log" "regex" 443
fail2ban_add_jail() {
    local jail_name="${1}"
    local log_path="${2}"
    local filter_regex="${3}"
    local port="${4:-443}"

    local filter_file="/etc/fail2ban/filter.d/${jail_name}.conf"
    local jail_file="/etc/fail2ban/jail.d/${jail_name}.conf"

    # Создаём фильтр
    cat > "$filter_file" << EOF
[Definition]
failregex = ${filter_regex}
ignoreregex =
EOF

    # Создаём jail
    cat > "$jail_file" << EOF
[${jail_name}]
enabled  = true
port     = ${port}
logpath  = ${log_path}
filter   = ${jail_name}
maxretry = 3
bantime  = 7d
EOF

    systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban
    info "fail2ban jail '${jail_name}' добавлен"
}

# =============================================================================
# NTP / ЧАСОВОЙ ПОЯС
# =============================================================================

_sys_setup_ntp() {
    # Устанавливаем часовой пояс
    if timedatectl set-timezone "${SYS_TIMEZONE}" 2>/dev/null; then
        info "Часовой пояс: ${SYS_TIMEZONE}"
    else
        warn "Не удалось установить часовой пояс ${SYS_TIMEZONE}"
    fi

    # Настраиваем chrony (точнее ntpd для серверов)
    if command -v chronyc &>/dev/null; then
        # Конфиг chrony
        cat > /etc/chrony/chrony.conf << EOF
# Orchestra NTP конфиг
server ${SYS_NTP_SERVER} iburst prefer
server 1.ru.pool.ntp.org iburst
server time.cloudflare.com iburst

makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
        systemctl enable chrony
        systemctl restart chrony
        sleep 2

        # Принудительная синхронизация
        chronyc makestep 2>/dev/null || true
        info "NTP синхронизирован через chrony"
        chronyc tracking | grep "System time" || true

    elif command -v ntpd &>/dev/null; then
        systemctl enable ntp 2>/dev/null || true
        systemctl restart ntp 2>/dev/null || true
        info "NTP запущен (ntpd)"
    else
        warn "NTP клиент не найден — время может дрейфовать"
    fi

    return 0
}

sys_setup_ntp_interactive() {
    section "Настройка NTP"
    ask "Часовой пояс" "Europe/Moscow"
    SYS_TIMEZONE="$REPLY"
    ask "NTP сервер" "pool.ntp.org"
    SYS_NTP_SERVER="$REPLY"
    _sys_setup_ntp
}

# =============================================================================
# LOGROTATE
# =============================================================================

_sys_setup_logrotate() {
    # Logrotate для Orchestra
    cat > /etc/logrotate.d/orchestra << 'EOF'
/opt/orchestra/state/orchestra.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF

    # Logrotate для Xray (создаём заранее)
    cat > /etc/logrotate.d/xray << 'EOF'
/var/log/xray/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    postrotate
        systemctl reload xray 2>/dev/null || true
    endscript
}
EOF

    info "Logrotate настроен для orchestra и xray"
    return 0
}

# =============================================================================
# АВТООБНОВЛЕНИЯ БЕЗОПАСНОСТИ
# =============================================================================

_sys_setup_autoupdate() {
    # Устанавливаем пакет если нет (на минимальных образах может отсутствовать)
    if ! command -v unattended-upgrades &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades apt-listchanges \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" || {
            warn "Не удалось установить unattended-upgrades — пропускаем автообновления"
            return 0
        }
    fi

    # unattended-upgrades
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};

Unattended-Upgrade::Package-Blacklist {
    // Не обновляем xray автоматически — есть свой механизм
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    systemctl enable unattended-upgrades
    systemctl restart unattended-upgrades

    info "Автообновления безопасности настроены"
    return 0
}

# =============================================================================
# ФИНАЛИЗАЦИЯ
# =============================================================================

_sys_finalize() {
    local server_ip
    server_ip=$(get_server_ip 2>/dev/null) || server_ip="?"

    echo ""
    section "Hardening завершён"

    echo -e "  ${G}✓${N} sysctl оптимизация применена"
    echo -e "  ${G}✓${N} BBR включён"
    echo -e "  ${G}✓${N} SSH перенесён на порт ${SYS_SSH_PORT}"
    echo -e "  ${G}✓${N} UFW активен"
    echo -e "  ${G}✓${N} fail2ban защищает SSH"
    echo -e "  ${G}✓${N} NTP синхронизирован"
    echo -e "  ${G}✓${N} Logrotate настроен"
    echo -e "  ${G}✓${N} Автообновления безопасности включены"
    echo ""

    if [[ "${SYS_DISABLE_IPV6}" == "yes" ]]; then
        echo -e "  ${G}✓${N} IPv6 отключён"
    fi

    echo ""
    warn "═══ ВАЖНО ══════════════════════════════════════════════════════"
    warn "SSH теперь на порту ${SYS_SSH_PORT}"
    warn "Следующее подключение: ssh -p ${SYS_SSH_PORT} root@${server_ip}"
    if [[ -n "${SYS_ADMIN_IP:-}" ]]; then
        warn "Whitelist IP: ${SYS_ADMIN_IP}"
    fi
    warn "════════════════════════════════════════════════════════════════"
    echo ""

    return 0
}

# =============================================================================
# СТАТУС HARDENING
# =============================================================================

sys_show_status() {
    section "Статус hardening системы"

    # BBR
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    local qdisc
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
    [[ "$cc" == "bbr" ]] && \
        echo -e "  ${G}✓${N} BBR активен (qdisc: ${qdisc})" || \
        echo -e "  ${R}✗${N} BBR не активен (текущий: ${cc})"

    # IPv6
    local ipv6_status
    ipv6_status=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "?")
    [[ "$ipv6_status" == "1" ]] && \
        echo -e "  ${G}✓${N} IPv6 отключён" || \
        echo -e "  ${Y}!${N} IPv6 включён (${ipv6_status})"

    # SSH порт
    local ssh_port
    ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | grep -oP ':\K[0-9]+' | head -1 || echo "?")
    echo -e "  ${G}✓${N} SSH слушает на порту: ${ssh_port}"

    # UFW
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo -e "  ${G}✓${N} UFW активен"
        ufw status numbered 2>/dev/null | grep -v "^Status" | head -10 | \
            while IFS= read -r line; do echo "    ${line}"; done
    elif command -v ufw &>/dev/null; then
        echo -e "  ${R}✗${N} UFW не активен"
    else
        echo -e "  ${Y}!${N} UFW не установлен"
    fi

    # fail2ban
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo -e "  ${G}✓${N} fail2ban активен"
        fail2ban-client status 2>/dev/null | grep "Jail list" | \
            while IFS= read -r line; do echo "    ${line}"; done || true
    else
        echo -e "  ${R}✗${N} fail2ban не запущен"
    fi

    # NTP
    if command -v chronyc &>/dev/null && systemctl is-active --quiet chrony 2>/dev/null; then
        local offset
        offset=$(chronyc tracking 2>/dev/null | grep "System time" | awk '{print $4, $5}' || echo "?")
        echo -e "  ${G}✓${N} NTP (chrony) активен, смещение: ${offset}"
    else
        echo -e "  ${Y}!${N} NTP не определён"
    fi

    # Автообновления
    if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
        echo -e "  ${G}✓${N} Автообновления активны"
    else
        echo -e "  ${Y}!${N} Автообновления не настроены"
    fi

    echo ""
}
