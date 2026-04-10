#!/usr/bin/env bash
# =============================================================================
# backup.sh — Резервные копии (Xray + Remnawave + Bedolaga + state)
# Модуль Orchestra | Этап 8
# =============================================================================
set -euo pipefail

[[ -n "${BACKUP_MODULE_LOADED:-}" ]] && return 0
readonly BACKUP_MODULE_LOADED=1

readonly BACKUP_RETENTION=7          # хранить N последних бэкапов
readonly BACKUP_TG_MAX_MB=49         # Telegram лимит файла

# =============================================================================
# МЕНЮ
# =============================================================================

backup_menu() {
    clear
    section "backup — Резервные копии"

    echo -e "  ${C}1${N}) Создать бэкап сейчас"
    echo -e "  ${C}2${N}) Список бэкапов"
    echo -e "  ${C}3${N}) Восстановить из бэкапа"
    echo -e "  ${C}4${N}) Настроить Telegram для отправки бэкапов"
    echo -e "  ${C}5${N}) Настроить автоматические бэкапы (cron)"
    echo -e "  ${C}6${N}) Очистить старые бэкапы"
    echo -e "  ${C}0${N}) Назад"
    echo ""

    ask "Выбор" "1"
    case "$REPLY" in
        1) backup_create ;;
        2) backup_list ;;
        3) backup_restore_interactive ;;
        4) backup_setup_telegram ;;
        5) backup_setup_cron ;;
        6) backup_cleanup ;;
        0) return 0 ;;
        *) warn "Неверный выбор" ;;
    esac
}

# =============================================================================
# СОЗДАНИЕ БЭКАПА
# =============================================================================

backup_create() {
    section "Создание резервной копии"

    local ts
    ts=$(date '+%Y-%m-%d_%H-%M-%S')
    local server_ip
    server_ip=$(get_server_ip 2>/dev/null) || server_ip="unknown"
    local backup_name="${ts}_${server_ip}"
    local backup_dir="${BACKUP_DIR}/${backup_name}"
    local backup_archive="${BACKUP_DIR}/${backup_name}.tar.gz"

    mkdir -p "$backup_dir"

    # --- Xray ---
    if [[ -d /etc/xray ]]; then
        step_msg "Бэкап Xray конфига..."
        cp -r /etc/xray "${backup_dir}/xray" 2>/dev/null || true
        info "Xray: /etc/xray/ ✓"
    fi

    # --- Remnawave ---
    if [[ -f /opt/remnawave/.env ]]; then
        step_msg "Бэкап Remnawave .env..."
        mkdir -p "${backup_dir}/remnawave"
        cp /opt/remnawave/.env "${backup_dir}/remnawave/" 2>/dev/null || true
        [[ -f /opt/remnawave/docker-compose.yml ]] && \
            cp /opt/remnawave/docker-compose.yml "${backup_dir}/remnawave/" 2>/dev/null || true
        info "Remnawave: .env + docker-compose ✓"
    fi

    # --- Remnawave PostgreSQL dump ---
    if command -v docker &>/dev/null && docker ps 2>/dev/null | grep -q "remnawave.*postgres\|postgres.*remnawave"; then
        step_msg "Дамп PostgreSQL Remnawave..."
        local pg_container
        pg_container=$(docker ps --format "{{.Names}}" 2>/dev/null | \
            grep -E "postgres|pg" | grep -v "bedolaga" | head -1 || echo "")

        if [[ -n "$pg_container" ]]; then
            mkdir -p "${backup_dir}/remnawave"
            docker exec "$pg_container" \
                pg_dumpall -U postgres 2>/dev/null \
                > "${backup_dir}/remnawave/db_dump.sql" \
                && info "PostgreSQL dump ✓" \
                || warn "Не удалось создать PostgreSQL dump"
        fi
    fi

    # --- Bedolaga ---
    if [[ -f /opt/bedolaga/.env ]]; then
        step_msg "Бэкап Bedolaga .env..."
        mkdir -p "${backup_dir}/bedolaga"
        cp /opt/bedolaga/.env "${backup_dir}/bedolaga/" 2>/dev/null || true
        [[ -f /opt/bedolaga/docker-compose.yml ]] && \
            cp /opt/bedolaga/docker-compose.yml "${backup_dir}/bedolaga/" 2>/dev/null || true
        info "Bedolaga: .env + docker-compose ✓"
    fi

    # --- Bedolaga PostgreSQL dump ---
    if command -v docker &>/dev/null && docker ps 2>/dev/null | grep -q "bedolaga.*postgres\|postgres.*bedolaga"; then
        step_msg "Дамп PostgreSQL Bedolaga..."
        local pg_bedolaga
        pg_bedolaga=$(docker ps --format "{{.Names}}" 2>/dev/null | \
            grep -E "bedolaga.*postgres|bedolaga.*pg" | head -1 || echo "")

        if [[ -n "$pg_bedolaga" ]]; then
            mkdir -p "${backup_dir}/bedolaga"
            docker exec "$pg_bedolaga" \
                pg_dumpall -U postgres 2>/dev/null \
                > "${backup_dir}/bedolaga/db_dump.sql" \
                && info "Bedolaga PostgreSQL dump ✓" \
                || warn "Не удалось создать Bedolaga PostgreSQL dump"
        fi
    fi

    # --- Orchestra state ---
    step_msg "Бэкап Orchestra state..."
    mkdir -p "${backup_dir}/orchestra"
    cp -r "${STATE_DIR}/"*.conf "${backup_dir}/orchestra/" 2>/dev/null || true
    cp "${NODES_CONF}" "${backup_dir}/orchestra/nodes.conf" 2>/dev/null || true
    info "Orchestra state ✓"

    # --- Архивируем ---
    step_msg "Создаём архив..."
    tar -czf "$backup_archive" -C "$BACKUP_DIR" "$backup_name" 2>/dev/null
    rm -rf "$backup_dir"

    local size_mb
    size_mb=$(du -m "$backup_archive" | awk '{print $1}')
    info "Бэкап создан: ${backup_archive} (${size_mb}MB)"

    # --- Отправляем в Telegram если настроен ---
    local server_ip_local
    server_ip_local=$(get_server_ip 2>/dev/null) || server_ip_local="local"
    local tg_token
    tg_token=$(state_get "$server_ip_local" "BACKUP_TG_TOKEN" 2>/dev/null || echo "")
    local tg_chat
    tg_chat=$(state_get  "$server_ip_local" "BACKUP_TG_CHAT"  2>/dev/null || echo "")

    if [[ -n "$tg_token" && -n "$tg_chat" ]]; then
        backup_send_telegram "$backup_archive" "$tg_token" "$tg_chat"
    fi

    # --- Ротация ---
    backup_cleanup_silent

    return 0
}

# =============================================================================
# ОТПРАВКА В TELEGRAM (split 49MB)
# =============================================================================

backup_send_telegram() {
    local file="${1}"
    local tg_token="${2}"
    local tg_chat="${3}"
    local file_size_mb
    file_size_mb=$(du -m "$file" | awk '{print $1}')

    step_msg "Отправка бэкапа в Telegram..."

    if [[ $file_size_mb -le $BACKUP_TG_MAX_MB ]]; then
        # Файл помещается целиком
        curl -s --max-time 120 \
            "https://api.telegram.org/bot${tg_token}/sendDocument" \
            -F "chat_id=${tg_chat}" \
            -F "document=@${file}" \
            -F "caption=🗄 Orchestra backup $(basename "$file")" \
            -o /dev/null \
            && info "Бэкап отправлен в Telegram" \
            || warn "Ошибка отправки в Telegram"
    else
        # Split: разбиваем на части по 49MB
        local part_dir
        part_dir=$(mktemp -d)
        local base_name
        base_name=$(basename "$file" .tar.gz)

        split -b "${BACKUP_TG_MAX_MB}M" "$file" "${part_dir}/${base_name}.part"

        local part_num=1
        local total_parts
        total_parts=$(ls "${part_dir}/"* | wc -l)

        for part_file in "${part_dir}/"*; do
            step_msg "Отправка части ${part_num}/${total_parts}..."
            curl -s --max-time 120 \
                "https://api.telegram.org/bot${tg_token}/sendDocument" \
                -F "chat_id=${tg_chat}" \
                -F "document=@${part_file}" \
                -F "caption=🗄 Backup ${base_name} [${part_num}/${total_parts}]" \
                -o /dev/null \
                || warn "Ошибка отправки части ${part_num}"
            ((part_num++)) || true
            sleep 2  # Пауза между частями
        done

        rm -rf "$part_dir"
        info "Бэкап отправлен в Telegram (${total_parts} частей)"
    fi
}

# =============================================================================
# СПИСОК БЭКАПОВ
# =============================================================================

backup_list() {
    section "Список бэкапов"

    if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls "${BACKUP_DIR}"/*.tar.gz 2>/dev/null)" ]]; then
        warn "Бэкапов нет: ${BACKUP_DIR}"
        return 0
    fi

    printf "  %-40s %8s\n" "Файл" "Размер"
    printf "  %-40s %8s\n" "────────────────────────────────────────" "────────"

    local i=1
    ls -t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | while IFS= read -r f; do
        local size
        size=$(du -h "$f" | awk '{print $1}')
        local fname
        fname=$(basename "$f")
        printf "  ${C}%2d${N}. %-40s ${GR}%8s${N}\n" "$i" "${fname:0:40}" "$size"
        ((i++)) || true
    done
}

# =============================================================================
# ВОССТАНОВЛЕНИЕ
# =============================================================================

backup_restore_interactive() {
    section "Восстановление из бэкапа"

    if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls "${BACKUP_DIR}"/*.tar.gz 2>/dev/null)" ]]; then
        warn "Нет доступных бэкапов"
        return 0
    fi

    backup_list

    ask "Имя файла бэкапа (полное, без пути) или номер" ""
    local choice="$REPLY"
    [[ -z "$choice" ]] && return 0

    local backup_file=""
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        backup_file=$(ls -t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | sed -n "${choice}p")
    else
        backup_file="${BACKUP_DIR}/${choice}"
    fi

    if [[ ! -f "$backup_file" ]]; then
        error "Файл не найден: ${backup_file}"
        return 1
    fi

    warn "ВНИМАНИЕ: Восстановление перезапишет текущие конфиги!"

    # Safety backup перед восстановлением
    step_msg "Создаю safety backup перед восстановлением..."
    backup_create

    ask_yn "Продолжить восстановление из ${backup_file}?" "нет"
    [[ $? -ne 0 ]] && { warn "Отменено"; return 0; }

    backup_restore "$backup_file"
}

backup_restore() {
    local archive="${1}"

    local restore_dir
    restore_dir=$(mktemp -d)
    tar -xzf "$archive" -C "$restore_dir" 2>/dev/null \
        || { error "Ошибка распаковки архива"; rm -rf "$restore_dir"; return 1; }

    local extracted_dir
    extracted_dir=$(ls "$restore_dir" | head -1)
    local base_dir="${restore_dir}/${extracted_dir}"

    # Восстанавливаем Xray
    if [[ -d "${base_dir}/xray" ]]; then
        step_msg "Восстанавливаем Xray конфиг..."
        systemctl stop xray 2>/dev/null || true
        cp -r "${base_dir}/xray/"* /etc/xray/ 2>/dev/null || true
        chmod 600 /etc/xray/*.json /etc/xray/*.txt 2>/dev/null || true
        systemctl start xray
        info "Xray восстановлен"
    fi

    # Восстанавливаем Remnawave .env
    if [[ -f "${base_dir}/remnawave/.env" ]]; then
        step_msg "Восстанавливаем Remnawave .env..."
        cp "${base_dir}/remnawave/.env" /opt/remnawave/.env 2>/dev/null || true
        info "Remnawave .env восстановлен"
        warn "Перезапусти Remnawave вручную: cd /opt/remnawave && docker compose up -d"
    fi

    # Восстанавливаем Bedolaga .env
    if [[ -f "${base_dir}/bedolaga/.env" ]]; then
        step_msg "Восстанавливаем Bedolaga .env..."
        cp "${base_dir}/bedolaga/.env" /opt/bedolaga/.env 2>/dev/null || true
        info "Bedolaga .env восстановлен"
        warn "Перезапусти Bedolaga вручную: cd /opt/bedolaga && docker compose up -d"
    fi

    # Восстанавливаем Orchestra state
    if [[ -d "${base_dir}/orchestra" ]]; then
        step_msg "Восстанавливаем Orchestra state..."
        cp "${base_dir}/orchestra/"*.conf "${STATE_DIR}/" 2>/dev/null || true
        [[ -f "${base_dir}/orchestra/nodes.conf" ]] && \
            cp "${base_dir}/orchestra/nodes.conf" "$NODES_CONF" 2>/dev/null || true
        info "Orchestra state восстановлен"
    fi

    rm -rf "$restore_dir"
    info "Восстановление завершено"
}

# =============================================================================
# НАСТРОЙКА TELEGRAM
# =============================================================================

backup_setup_telegram() {
    section "Настройка Telegram для бэкапов"

    hint "Telegram для бэкапов" \
        "Бэкапы будут отправляться в чат/канал Telegram." \
        "Бот должен быть добавлен в чат с правами на отправку файлов." \
        "Файлы > 49MB разбиваются на части автоматически."

    ask_secret "Bot Token"
    [[ -z "$REPLY" ]] && return 0
    local tg_token="$REPLY"

    ask "Chat ID (личный или канал, например -100123456789)" ""
    [[ -z "$REPLY" ]] && return 0
    local tg_chat="$REPLY"

    # Тест
    local test_result
    test_result=$(curl -s --max-time 10 \
        "https://api.telegram.org/bot${tg_token}/sendMessage" \
        -d "chat_id=${tg_chat}" \
        -d "text=🗄 Orchestra Backup настроен!" \
        2>/dev/null)

    if echo "$test_result" | grep -q '"ok":true'; then
        info "Telegram для бэкапов настроен"
        local server_ip
        server_ip=$(get_server_ip 2>/dev/null) || server_ip="local"
        state_set "$server_ip" "BACKUP_TG_TOKEN" "$tg_token"
        state_set "$server_ip" "BACKUP_TG_CHAT"  "$tg_chat"
    else
        error "Ошибка отправки в Telegram — проверь токен и chat_id"
    fi
}

# =============================================================================
# CRON АВТОБЭКАП
# =============================================================================

backup_setup_cron() {
    section "Автоматические бэкапы"

    echo -e "  ${C}1${N}) Ежедневно в 03:00"
    echo -e "  ${C}2${N}) Раз в неделю (воскресенье 03:00)"
    echo -e "  ${C}3${N}) Свой интервал"
    echo -e "  ${C}0${N}) Отмена"
    echo ""

    ask "Выбор" "1"
    local schedule=""
    case "$REPLY" in
        1) schedule="0 3 * * *" ;;
        2) schedule="0 3 * * 0" ;;
        3)
            ask "Cron расписание (например: 0 3 * * *)" "0 3 * * *"
            schedule="$REPLY"
            ;;
        0) return 0 ;;
        *) warn "Неверный выбор"; return 0 ;;
    esac

    cat > /etc/cron.d/orchestra-backup << CRONEOF
# Orchestra — автоматические бэкапы
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${schedule} root bash -c 'source ${ORCHESTRA_DIR}/orchestra.sh && source ${ORCHESTRA_DIR}/lib/backup.sh && backup_create' >> ${ORCHESTRA_LOG} 2>&1
CRONEOF

    chmod 644 /etc/cron.d/orchestra-backup
    info "Автобэкап настроен: ${schedule}"
}

# =============================================================================
# ОЧИСТКА СТАРЫХ БЭКАПОВ
# =============================================================================

backup_cleanup_silent() {
    # Удаляем бэкапы старше BACKUP_RETENTION штук (без вывода)
    ls -t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | \
        tail -n "+$((BACKUP_RETENTION + 1))" | \
        while IFS= read -r old_backup; do
            rm -f "$old_backup"
        done
}

backup_cleanup() {
    section "Очистка старых бэкапов"

    local total
    total=$(ls "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | wc -l || echo 0)
    info "Всего бэкапов: ${total}, хранить: ${BACKUP_RETENTION}"

    if [[ $total -le $BACKUP_RETENTION ]]; then
        info "Очистка не нужна"
        return 0
    fi

    local to_delete=$((total - BACKUP_RETENTION))
    ask_yn "Удалить ${to_delete} старых бэкапов?" "да"
    [[ $? -ne 0 ]] && return 0

    ls -t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | \
        tail -n "+$((BACKUP_RETENTION + 1))" | \
        while IFS= read -r old_backup; do
            rm -f "$old_backup"
            echo -e "  ${GR}Удалён:${N} $(basename "$old_backup")"
        done

    info "Очистка завершена"
}
