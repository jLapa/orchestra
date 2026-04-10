#!/usr/bin/env bash
# =============================================================================
# Orchestra — мастер-скрипт управления VPN-инфраструктурой
# Версия: 1.0.0 | Этап 1 — Скелет
# =============================================================================
set -euo pipefail

# =============================================================================
# КОНСТАНТЫ И ПУТИ
# =============================================================================

readonly ORCHESTRA_VERSION="1.0.0"
readonly ORCHESTRA_DIR="/opt/orchestra"
readonly LIB_DIR="${ORCHESTRA_DIR}/lib"
readonly FLEET_DIR="${ORCHESTRA_DIR}/fleet"
readonly STATE_DIR="${ORCHESTRA_DIR}/state"
readonly BACKUP_DIR="${ORCHESTRA_DIR}/backups"
readonly NODES_CONF="${FLEET_DIR}/nodes.conf"
readonly ORCHESTRA_LOG="${STATE_DIR}/orchestra.log"

# Защита от source-блокировки (функции доступны при source, меню — только при прямом запуске)
ORCHESTRA_SOURCED=false
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && ORCHESTRA_SOURCED=true

# =============================================================================
# ЦВЕТОВАЯ СХЕМА
# =============================================================================

# Проверяем поддержку цветов
if [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null; then
    readonly R="\e[31m"      # red    — ошибка
    readonly G="\e[32m"      # green  — успех
    readonly Y="\e[33m"      # yellow — предупреждение
    readonly C="\e[36m"      # cyan   — вопрос / шаг
    readonly B="\e[34m"      # blue   — подсказка
    readonly W="\e[97m"      # white  — текущий шаг
    readonly GR="\e[90m"     # grey   — ожидающий шаг
    readonly BOLD="\e[1m"
    readonly N="\e[0m"       # reset
else
    readonly R="" G="" Y="" C="" B="" W="" GR="" BOLD="" N=""
fi

# =============================================================================
# БАЗОВЫЕ УТИЛИТЫ ВЫВОДА
# =============================================================================

info() {
    local ts
    ts=$(date '+%H:%M:%S')
    echo -e "${G}[✓]${N} ${*}"
    echo "[${ts}] INFO: ${*}" >> "${ORCHESTRA_LOG}" 2>/dev/null || true
}

warn() {
    local ts
    ts=$(date '+%H:%M:%S')
    echo -e "${Y}[!]${N} ${*}"
    echo "[${ts}] WARN: ${*}" >> "${ORCHESTRA_LOG}" 2>/dev/null || true
}

error() {
    local ts
    ts=$(date '+%H:%M:%S')
    echo -e "${R}[✗]${N} ${*}" >&2
    echo "[${ts}] ERROR: ${*}" >> "${ORCHESTRA_LOG}" 2>/dev/null || true
}

step_msg() {
    echo -e "${C}[→]${N} ${*}"
}

pending_msg() {
    echo -e "${GR}[·]${N} ${*}"
}

section() {
    local title="${*}"
    local line
    line=$(printf '═%.0s' $(seq 1 60))
    echo ""
    echo -e "${BOLD}${B}${line}${N}"
    echo -e "${BOLD}${B} ${title}${N}"
    echo -e "${BOLD}${B}${line}${N}"
    echo ""
}

hint() {
    local title="${1}"
    shift
    echo ""
    echo -e "${B}╔══════════════════════════════════════════════════════════════╗${N}"
    echo -e "${B}║${N}  ${BOLD}${title}${N}"
    for line in "${@}"; do
        # Выравниваем строку до ширины блока 60 символов
        local pad
        pad=$(( 60 - ${#line} - 2 ))
        [[ $pad -lt 0 ]] && pad=0
        printf "${B}║${N}  %s%${pad}s${B}║${N}\n" "${line}" ""
    done
    echo -e "${B}╚══════════════════════════════════════════════════════════════╝${N}"
    echo ""
}

press_enter() {
    echo ""
    echo -e "${GR}Нажми Enter для продолжения...${N}"
    read -r
}

# =============================================================================
# ФУНКЦИЯ ВВОДА ask()
# =============================================================================

# ask "Вопрос" "default_value" → сохраняет ответ в REPLY
ask() {
    local prompt="${1}"
    local default="${2:-}"
    local answer

    if [[ -n "$default" ]]; then
        echo -ne "${C}[?]${N} ${prompt} ${GR}[${default}]${N}: "
    else
        echo -ne "${C}[?]${N} ${prompt}: "
    fi

    read -r answer
    if [[ -z "$answer" && -n "$default" ]]; then
        REPLY="$default"
    else
        REPLY="$answer"
    fi
}

# ask_secret — без эха (для паролей/токенов)
ask_secret() {
    local prompt="${1}"
    echo -ne "${C}[?]${N} ${prompt}: "
    read -rs REPLY
    echo ""
}

# ask_yn — да/нет, возвращает 0=да, 1=нет
ask_yn() {
    local prompt="${1}"
    local default="${2:-да}"
    local answer

    echo -ne "${C}[?]${N} ${prompt} ${GR}(да/нет) [${default}]${N}: "
    read -r answer

    answer="${answer:-$default}"
    case "${answer,,}" in
        д|да|y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# ОПРЕДЕЛЕНИЕ IP СЕРВЕРА
# =============================================================================

get_server_ip() {
    local ip

    # Метод 1 — ifconfig.me (принудительно IPv4)
    ip=$(curl -4s https://ifconfig.me --max-time 5 2>/dev/null) && \
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }

    # Метод 2 — ipify.org
    ip=$(curl -4s https://api.ipify.org --max-time 5 2>/dev/null) && \
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }

    # Метод 3 — icanhazip.com (только IPv4 поддомен)
    ip=$(curl -4s https://ipv4.icanhazip.com --max-time 5 2>/dev/null) && \
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }

    # Не удалось определить
    return 1
}

# =============================================================================
# РЕЗОЛВИНГ ДОМЕНА (три метода)
# =============================================================================

resolve_domain() {
    local domain="${1}"
    local ip

    # Метод A — dig (предпочтительный, прямо к 1.1.1.1)
    if command -v dig &>/dev/null; then
        ip=$(dig +short A "${domain}" @1.1.1.1 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
        [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    fi

    # Метод B — host
    if command -v host &>/dev/null; then
        ip=$(host "${domain}" 2>/dev/null | awk '/has address/{print $4}' | head -1)
        [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    fi

    # Метод C — DNS-over-HTTPS Cloudflare (работает везде где есть curl)
    ip=$(curl -s "https://cloudflare-dns.com/dns-query?name=${domain}&type=A" \
        -H "Accept: application/dns-json" \
        --max-time 10 2>/dev/null \
        | grep -oP '"data":"\K[0-9.]+' | head -1)
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }

    return 1
}

# =============================================================================
# ВАЛИДАЦИЯ ДОМЕНА
# =============================================================================

# Проверяет TTL для детекта Cloudflare Proxy (TTL=300 → CF proxy включён)
check_cf_proxy() {
    local domain="${1}"
    local ttl

    if command -v dig &>/dev/null; then
        ttl=$(dig +nocmd A "${domain}" @8.8.8.8 +noall +answer 2>/dev/null | awk '{print $2}' | head -1)
        [[ "$ttl" == "300" ]] && return 0   # CF proxy детектирован
    fi
    return 1  # CF proxy не обнаружен (или не удалось проверить)
}

# validate_domain "vpn.example.com" [required|optional] [allow_cf_proxy]
# Возврат: 0=OK, 1=FAIL (обязательный), 2=WARN (необязательный)
validate_domain() {
    local domain="${1}"
    local required="${2:-optional}"       # required | optional
    local allow_cf_proxy="${3:-false}"    # true | false

    [[ -z "$domain" ]] && { error "Домен не указан"; return 1; }

    step_msg "Проверяю A-запись для ${BOLD}${domain}${N}..."

    # Получаем IP сервера
    local server_ip
    server_ip=$(get_server_ip) || {
        error "Не удалось определить IP сервера"
        [[ "$required" == "required" ]] && return 1 || return 2
    }

    # Резолвим домен
    local domain_ip
    domain_ip=$(resolve_domain "${domain}") || true

    if [[ -z "$domain_ip" ]]; then
        warn "Не удалось получить A-запись для ${domain}"
        warn "DNS ещё не обновился или домен не существует"
        if [[ "$required" == "required" ]]; then
            error "Домен обязателен для продолжения"
            return 1
        fi
        return 2
    fi

    # Детект Cloudflare Proxy
    if check_cf_proxy "${domain}"; then
        if [[ "$allow_cf_proxy" == "true" ]]; then
            info "Домен ${domain} → ${domain_ip} (через Cloudflare Proxy — разрешено ✓)"
        else
            error "Cloudflare Proxy включён для ${domain} (TTL=300)"
            error "Reality требует прямое TLS-соединение — переключи на DNS-only (серое облако)"
            [[ "$required" == "required" ]] && return 1 || return 2
        fi
    fi

    # Сравниваем IP
    if [[ "$domain_ip" == "$server_ip" ]]; then
        info "Домен ${domain} → ${domain_ip} ✓"
        return 0
    else
        error "A-запись ${BOLD}${domain}${N} ведёт на ${domain_ip}"
        error "IP этого сервера: ${server_ip}"
        echo ""
        warn "Возможные причины:"
        warn "  • A-запись не создана или указывает на другой сервер"
        warn "  • Cloudflare Proxy включён (оранжевое облако) — нужно серое"
        warn "  • DNS ещё не обновился (подожди 1-5 минут)"
        warn "  • Опечатка в домене"
        echo ""

        # Интерактивный диалог при ошибке
        if [[ "${ORCHESTRA_SOURCED}" == "false" ]]; then
            while true; do
                echo -e "  ${C}[1]${N} Повторить проверку"
                echo -e "  ${C}[2]${N} Продолжить без домена (только для Xray, без SSL)"
                echo -e "  ${C}[0]${N} Отмена"
                echo -ne "${C}[?]${N} Выбор: "
                local choice
                read -r choice
                case "$choice" in
                    1)
                        validate_domain "${domain}" "${required}" "${allow_cf_proxy}"
                        return $?
                        ;;
                    2)
                        warn "Продолжение без домена — SSL и маскировка недоступны"
                        return 2
                        ;;
                    0) return 1 ;;
                    *) warn "Введи 0, 1 или 2" ;;
                esac
            done
        fi

        [[ "$required" == "required" ]] && return 1 || return 2
    fi
}

# Дополнительные проверки домена (CNAME, порт 80, CF proxy)
check_domain_extras() {
    local domain="${1}"

    # CNAME предупреждение
    if command -v dig &>/dev/null; then
        local cname
        cname=$(dig +short CNAME "${domain}" @1.1.1.1 2>/dev/null)
        [[ -n "$cname" ]] && warn "Домен ${domain} — CNAME на ${cname}, не прямая A-запись"
    fi

    # Проверка порта 80 (нужен для certbot HTTP-01)
    if ! timeout 3 bash -c "echo >/dev/tcp/${domain}/80" 2>/dev/null; then
        warn "Порт 80 закрыт на ${domain} — certbot HTTP-01 может не сработать"
        warn "Открой порт 80 или используй DNS-01 валидацию"
    fi
}

# =============================================================================
# CLOUDFLARE API — АВТОНАСТРОЙКА DNS
# =============================================================================

# Переменные CF (заполняются через cf_setup_dns)
CF_API_TOKEN=""
CF_ZONE_ID=""

# Получить Zone ID по корневому домену
cf_get_zone_id() {
    local root_domain="${1}"
    local response

    response=$(curl -s \
        "https://api.cloudflare.com/client/v4/zones?name=${root_domain}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --max-time 15 2>/dev/null)

    if ! echo "$response" | grep -q '"success":true'; then
        error "Cloudflare API вернул ошибку:"
        echo "$response" | grep -oP '"message":"\K[^"]+' | head -3 >&2 || true
        return 1
    fi

    local zone_id
    zone_id=$(echo "$response" | grep -oP '"id":"\K[^"]+' | head -1)
    [[ -z "$zone_id" ]] && { error "Домен ${root_domain} не найден в Cloudflare"; return 1; }

    echo "$zone_id"
}

# Создать или обновить A-запись
cf_upsert_record() {
    local zone_id="${1}"
    local name="${2}"      # vpn.example.com
    local ip="${3}"        # 31.56.178.11
    local proxied="${4}"   # true | false

    # Проверяем — запись уже существует?
    local existing
    existing=$(curl -s \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=A&name=${name}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        --max-time 15 2>/dev/null)

    local record_id
    record_id=$(echo "$existing" | grep -oP '"id":"\K[^"]+' | head -1)

    local method="POST"
    local url="https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records"
    if [[ -n "$record_id" ]]; then
        method="PATCH"
        url="${url}/${record_id}"
    fi

    local result
    result=$(curl -s -X "${method}" "${url}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --max-time 15 \
        --data "{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${ip}\",\"ttl\":1,\"proxied\":${proxied}}" \
        2>/dev/null)

    if echo "$result" | grep -q '"success":true'; then
        local proxy_label="DNS-only"
        [[ "$proxied" == "true" ]] && proxy_label="CF Proxy ✓"
        info "DNS: ${name} → ${ip} [${proxy_label}]"
        return 0
    else
        error "Ошибка CF API для ${name}:"
        echo "$result" | grep -oP '"message":"\K[^"]+' | head -3 >&2 || true
        return 1
    fi
}

# Полная автонастройка DNS
# Переменные должны быть установлены до вызова:
#   NODE_DOMAIN, PANEL_DOMAIN, SUB_DOMAIN, BOT_DOMAIN (все опциональны)
cf_setup_dns() {
    local root_domain="${1}"
    local server_ip="${2}"

    section "Автонастройка DNS через Cloudflare"

    # Инструкция по токену
    hint "Как получить Cloudflare API Token:" \
        "1. Открой https://dash.cloudflare.com/profile/api-tokens" \
        "2. Нажми 'Create Token'" \
        "3. Выбери шаблон 'Edit zone DNS'" \
        "4. Zone Resources → Include → твой домен" \
        "5. Continue to summary → Create Token" \
        "6. Скопируй токен (показывается ОДИН РАЗ!)"

    if [[ -z "$CF_API_TOKEN" ]]; then
        ask_secret "Cloudflare API Token"
        CF_API_TOKEN="$REPLY"
    fi

    [[ -z "$CF_API_TOKEN" ]] && { error "API Token не введён"; return 1; }

    step_msg "Получаю Zone ID для ${root_domain}..."
    CF_ZONE_ID=$(cf_get_zone_id "${root_domain}") || return 1
    info "Zone ID: ${CF_ZONE_ID}"

    # Показываем план записей
    echo ""
    echo -e "  Автоматически создам субдомены:"
    [[ -n "${NODE_DOMAIN:-}"  ]] && echo -e "    ${C}${NODE_DOMAIN}${N}  → ${server_ip}  ${GR}[DNS-only]${N}   ← Reality/Xray"
    [[ -n "${PANEL_DOMAIN:-}" ]] && echo -e "    ${C}${PANEL_DOMAIN}${N}  → ${server_ip}  ${GR}[DNS-only]${N}   ← Remnawave"
    [[ -n "${SUB_DOMAIN:-}"   ]] && echo -e "    ${C}${SUB_DOMAIN}${N}  → ${server_ip}  ${G}[CF Proxy ✓]${N} ← Подписки"
    [[ -n "${BOT_DOMAIN:-}"   ]] && echo -e "    ${C}${BOT_DOMAIN}${N}  → ${server_ip}  ${GR}[DNS-only]${N}   ← Bedolaga Bot"
    echo ""

    ask_yn "Подтвердить создание записей?" "да" || { warn "Отменено пользователем"; return 1; }

    # Создаём записи
    [[ -n "${NODE_DOMAIN:-}"  ]] && cf_upsert_record "${CF_ZONE_ID}" "${NODE_DOMAIN}"  "${server_ip}" "false"
    [[ -n "${PANEL_DOMAIN:-}" ]] && cf_upsert_record "${CF_ZONE_ID}" "${PANEL_DOMAIN}" "${server_ip}" "false"
    [[ -n "${SUB_DOMAIN:-}"   ]] && cf_upsert_record "${CF_ZONE_ID}" "${SUB_DOMAIN}"   "${server_ip}" "true"
    [[ -n "${BOT_DOMAIN:-}"   ]] && cf_upsert_record "${CF_ZONE_ID}" "${BOT_DOMAIN}"   "${server_ip}" "false"

    # Ждём propagation — проверяем только NODE_DOMAIN (или первый непустой)
    local check_domain="${NODE_DOMAIN:-${PANEL_DOMAIN:-${BOT_DOMAIN:-}}}"
    if [[ -n "$check_domain" ]]; then
        step_msg "Ожидаю обновления DNS (до 5 минут)..."
        local attempts=0
        while [[ $attempts -lt 30 ]]; do
            local resolved
            resolved=$(resolve_domain "${check_domain}") || true
            if [[ "$resolved" == "${server_ip}" ]]; then
                info "DNS обновился: ${check_domain} → ${server_ip} ✓"
                return 0
            fi
            sleep 10
            ((attempts++))
            echo -n "."
        done
        echo ""
        warn "DNS ещё не обновился — продолжаем, проверь позже через: dig A ${check_domain} @1.1.1.1"
    fi

    return 0
}

# =============================================================================
# ДВИЖОК ШАГОВ — run_step() и check_resume_prompt()
# =============================================================================

PROGRESS_FILE=""   # устанавливается в init_progress()

# Инициализация файла прогресса для модуля
init_progress() {
    local module="${1}"
    local ip="${2:-local}"

    PROGRESS_FILE="${STATE_DIR}/${ip}-progress.conf"

    if [[ ! -f "$PROGRESS_FILE" ]]; then
        cat > "$PROGRESS_FILE" << EOF
MODULE="${module}"
STARTED_AT="$(date -u +%FT%T)"
UPDATED_AT="$(date -u +%FT%T)"
EOF
        info "Создан файл прогресса: ${PROGRESS_FILE}"
    fi
}

# Добавить шаг в файл прогресса (если его там нет)
register_step() {
    local step="${1}"
    if ! grep -q "^STEP_${step}=" "$PROGRESS_FILE" 2>/dev/null; then
        echo "STEP_${step}=\"pending\"" >> "$PROGRESS_FILE"
    fi
}

# Получить статус шага
step_status() {
    local step="${1}"
    grep -oP "(?<=STEP_${step}=\")[^\"]+" "${PROGRESS_FILE}" 2>/dev/null || echo "pending"
}

# Обновить статус шага в файле прогресса
set_step_status() {
    local step="${1}"
    local status="${2}"
    local ts
    ts=$(date -u +%FT%T)

    if grep -q "^STEP_${step}=" "${PROGRESS_FILE}"; then
        sed -i "s|^STEP_${step}=.*|STEP_${step}=\"${status}\"|" "${PROGRESS_FILE}"
    else
        echo "STEP_${step}=\"${status}\"" >> "${PROGRESS_FILE}"
    fi
    sed -i "s|^UPDATED_AT=.*|UPDATED_AT=\"${ts}\"|" "${PROGRESS_FILE}"
}

# Основной движок шагов
# run_step "step_name" function_name "Описание шага"
run_step() {
    local step="${1}"
    local func="${2}"
    local desc="${3}"

    register_step "${step}"
    local status
    status=$(step_status "${step}")

    # Уже выполнен — пропускаем
    if [[ "$status" == "done" ]]; then
        echo -e "  ${G}[✓ уже выполнен]${N} ${desc}"
        return 0
    fi

    echo ""
    echo -e "  ${W}[→]${N} ${desc}..."

    # Помечаем как running
    set_step_status "${step}" "running"

    # Выполняем функцию
    if "${func}"; then
        set_step_status "${step}" "done"
        echo -e "  ${G}[✓]${N} ${desc}"
    else
        set_step_status "${step}" "failed"
        echo -e "  ${R}[✗]${N} ${desc} — ОШИБКА"
        error "Установка прервана на шаге: ${step}"
        error "Запусти скрипт снова — он продолжит с этого места"
        exit 1
    fi
}

# Пометить модуль завершённым
mark_module_done() {
    local module="${1}"
    local ip="${2:-local}"
    local state_file="${STATE_DIR}/${ip}.conf"

    # Добавляем модуль в список установленных
    if [[ -f "$state_file" ]]; then
        local current_modules
        current_modules=$(grep -oP '(?<=INSTALLED_MODULES=")[^"]+' "$state_file" 2>/dev/null || echo "")
        if ! echo "$current_modules" | grep -qw "$module"; then
            sed -i "s|^INSTALLED_MODULES=.*|INSTALLED_MODULES=\"${current_modules} ${module}\"|" "$state_file" || true
        fi
    fi

    info "Модуль ${module} установлен успешно"
    rm -f "${STATE_DIR}/${ip}-progress.conf" 2>/dev/null || true
}

# Диалог продолжения при прерванной установке
check_resume_prompt() {
    [[ ! -f "$PROGRESS_FILE" ]] && return 0

    local module started_at
    module=$(grep -oP '(?<=MODULE=")[^"]+' "$PROGRESS_FILE" 2>/dev/null || echo "unknown")
    started_at=$(grep -oP '(?<=STARTED_AT=")[^"]+' "$PROGRESS_FILE" 2>/dev/null || echo "?")

    # Считаем выполненные / упавшие / ожидающие шаги
    local done_steps failed_steps pending_steps
    done_steps=$(grep -c '^STEP_.*="done"' "$PROGRESS_FILE" 2>/dev/null || echo 0)
    failed_steps=$(grep -c '^STEP_.*="failed"' "$PROGRESS_FILE" 2>/dev/null || echo 0)
    pending_steps=$(grep -c '^STEP_.*="pending"' "$PROGRESS_FILE" 2>/dev/null || echo 0)

    # Если только pending шаги (свежий файл — просто создан) — не спрашиваем
    if [[ "$done_steps" -eq 0 && "$failed_steps" -eq 0 ]]; then
        return 0
    fi

    echo ""
    echo -e "${B}╔══════════════════════════════════════════════════════════════╗${N}"
    echo -e "${B}║${N}  ${BOLD}Обнаружена незавершённая установка (${module})${N}"
    echo -e "${B}║${N}  Начата: ${started_at}"
    echo -e "${B}║${N}"
    echo -e "${B}║${N}  ${G}Выполнено:${N} ${done_steps} шагов"
    [[ "$failed_steps" -gt 0 ]] && echo -e "${B}║${N}  ${R}Упало:${N}     ${failed_steps} шагов"
    echo -e "${B}║${N}  ${GR}Осталось:${N}  ${pending_steps} шагов"
    echo -e "${B}║${N}"

    # Показываем список шагов
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^STEP_ ]] || continue
        local step_name="${key#STEP_}"
        local step_val="${val//\"/}"
        case "$step_val" in
            done)    echo -e "${B}║${N}    ${G}✓${N} ${step_name}" ;;
            failed)  echo -e "${B}║${N}    ${R}✗${N} ${step_name}  ← прервалось здесь" ;;
            running) echo -e "${B}║${N}    ${Y}~${N} ${step_name}  (прервано в процессе)" ;;
            pending) echo -e "${B}║${N}    ${GR}·${N} ${step_name}" ;;
        esac
    done < "$PROGRESS_FILE"

    echo -e "${B}║${N}"
    echo -e "${B}║${N}  ${C}[1]${N} Продолжить с места остановки"
    echo -e "${B}║${N}  ${C}[2]${N} Начать заново (сбросить прогресс)"
    echo -e "${B}║${N}  ${C}[0]${N} Отмена"
    echo -e "${B}╚══════════════════════════════════════════════════════════════╝${N}"
    echo ""

    while true; do
        echo -ne "${C}[?]${N} Выбор: "
        local choice
        read -r choice
        case "$choice" in
            1)
                info "Продолжаю с места остановки..."
                # Переводим failed → pending чтобы run_step повторил шаг
                sed -i 's/^STEP_\(.*\)="failed"/STEP_\1="pending"/' "$PROGRESS_FILE"
                sed -i 's/^STEP_\(.*\)="running"/STEP_\1="pending"/' "$PROGRESS_FILE"
                return 0
                ;;
            2)
                warn "Сбрасываю прогресс..."
                rm -f "$PROGRESS_FILE"
                init_progress "${module}"
                return 0
                ;;
            0)
                info "Отмена"
                exit 0
                ;;
            *)
                warn "Введи 0, 1 или 2"
                ;;
        esac
    done
}

# =============================================================================
# ФЛОТ — ПАРСЕР nodes.conf
# =============================================================================

# Проверяем корректность имени ноды (только безопасные символы)
_validate_node_name() {
    local name="${1}"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { error "Некорректное имя ноды: ${name}"; return 1; }
}

# Читает поле из секции ноды
# read_node "node-01" "host"
read_node() {
    local node_name="${1}"
    local field="${2}"

    _validate_node_name "${node_name}" || return 1
    [[ -f "$NODES_CONF" ]] || { error "Файл fleet/nodes.conf не найден"; return 1; }

    # Ищем секцию [node_name] и читаем поле до следующей секции
    awk -v section="[${node_name}]" -v key="${field}" '
        /^\[/ { in_section = ($0 == section) }
        in_section && $0 ~ "^" key "[[:space:]]*=" {
            sub(/^[^=]+=[[:space:]]*/, "")
            print
            exit
        }
    ' "$NODES_CONF"
}

# Записывает / обновляет поле в секции ноды
# write_node "node-01" "status" "ok"
write_node() {
    local node_name="${1}"
    local field="${2}"
    local value="${3}"

    _validate_node_name "${node_name}" || return 1
    [[ -f "$NODES_CONF" ]] || { error "Файл fleet/nodes.conf не найден"; return 1; }

    # Проверяем — секция существует?
    if ! grep -q "^\[${node_name}\]" "$NODES_CONF"; then
        error "Нода ${node_name} не найдена в nodes.conf"
        return 1
    fi

    # Поле уже есть в секции — обновляем
    if awk -v section="[${node_name}]" -v key="${field}" '
        /^\[/ { in_section = ($0 == section) }
        in_section && $0 ~ "^" key "[[:space:]]*=" { found=1 }
        END { exit !found }
    ' "$NODES_CONF"; then
        # Обновляем только внутри нужной секции
        python3 - "${NODES_CONF}" "${node_name}" "${field}" "${value}" << 'PYEOF'
import sys, re

conf_file = sys.argv[1]
section   = sys.argv[2]
field     = sys.argv[3]
value     = sys.argv[4]

with open(conf_file, 'r') as f:
    lines = f.readlines()

in_section = False
updated = False
for i, line in enumerate(lines):
    stripped = line.strip()
    if stripped.startswith('['):
        in_section = (stripped == f'[{section}]')
    if in_section and re.match(rf'^{re.escape(field)}\s*=', line):
        lines[i] = f'{field}        = {value}\n'
        updated = True
        break

with open(conf_file, 'w') as f:
    f.writelines(lines)

sys.exit(0 if updated else 1)
PYEOF
    else
        # Поля нет — добавляем в конец секции
        python3 - "${NODES_CONF}" "${node_name}" "${field}" "${value}" << 'PYEOF'
import sys, re

conf_file = sys.argv[1]
section   = sys.argv[2]
field     = sys.argv[3]
value     = sys.argv[4]

with open(conf_file, 'r') as f:
    content = f.read()

# Вставляем поле после заголовка секции (перед следующей или конец файла)
pattern = rf'(\[{re.escape(section)}\][^\[]*?)(\[|\Z)'
replacement = rf'\g<1>{field}        = {value}\n\2'
new_content = re.sub(pattern, replacement, content, count=1, flags=re.DOTALL)

with open(conf_file, 'w') as f:
    f.write(new_content)
PYEOF
    fi
}

# Добавляет новую ноду в nodes.conf
# add_node "node-03" host port user role [key]
add_node() {
    local node_name="${1}"
    local host="${2}"
    local port="${3:-22}"
    local user="${4:-root}"
    local role="${5:-xray}"
    local key="${6:-}"

    _validate_node_name "${node_name}" || return 1
    [[ -f "$NODES_CONF" ]] || touch "$NODES_CONF"

    if grep -q "^\[${node_name}\]" "$NODES_CONF"; then
        error "Нода ${node_name} уже существует в nodes.conf"
        return 1
    fi

    local key_line=""
    [[ -n "$key" ]] && key_line="key         = ${key}"

    cat >> "$NODES_CONF" << EOF

[${node_name}]
host        = ${host}
port        = ${port}
user        = ${user}
role        = ${role}
${key_line}
installed   = $(date -u +%F)
status      = pending
EOF

    info "Нода ${node_name} (${host}) добавлена в fleet"
}

# Возвращает список всех имён нод
list_nodes() {
    [[ -f "$NODES_CONF" ]] || { error "Файл fleet/nodes.conf не найден"; return 1; }
    grep -oP '(?<=^\[)[^\]]+' "$NODES_CONF"
}

# =============================================================================
# STATE — ЧТЕНИЕ И ЗАПИСЬ КОНФИГА СЕРВЕРА
# =============================================================================

# Читает значение поля из state/<ip>.conf
# state_get "31.56.178.11" "NODE_DOMAIN"
state_get() {
    local ip="${1}"
    local key="${2}"
    local file="${STATE_DIR}/${ip}.conf"

    [[ -f "$file" ]] || return 1
    grep -oP "(?<=^${key}=\")[^\"]+" "$file" 2>/dev/null || return 1
}

# Записывает / обновляет поле в state/<ip>.conf
# state_set "31.56.178.11" "NODE_DOMAIN" "vpn.example.com"
state_set() {
    local ip="${1}"
    local key="${2}"
    local value="${3}"
    local file="${STATE_DIR}/${ip}.conf"

    # Создаём файл если нет
    if [[ ! -f "$file" ]]; then
        cat > "$file" << EOF
SERVER_IP="${ip}"
INSTALLED_MODULES=""
INSTALLED_AT="$(date -u +%FT%T)"
EOF
    fi

    if grep -q "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$file"
    else
        echo "${key}=\"${value}\"" >> "$file"
    fi
}

# Загружает весь state/<ip>.conf в текущий shell (source)
state_load() {
    local ip="${1}"
    local file="${STATE_DIR}/${ip}.conf"

    [[ -f "$file" ]] || return 1
    # shellcheck disable=SC1090
    source "$file"
}

# =============================================================================
# УТИЛИТЫ ВАЛИДАЦИИ
# =============================================================================

# Проверка Telegram Bot Token
validate_telegram_token() {
    local token="${1}"
    local result

    result=$(curl -s "https://api.telegram.org/bot${token}/getMe" \
        --max-time 10 2>/dev/null)

    if echo "$result" | grep -q '"ok":true'; then
        local bot_name
        bot_name=$(echo "$result" | grep -oP '"username":"\K[^"]+')
        info "Telegram Bot Token валиден: @${bot_name}"
        return 0
    else
        local err_msg
        err_msg=$(echo "$result" | grep -oP '"description":"\K[^"]+' || echo "нет ответа")
        error "Telegram Bot Token недействителен: ${err_msg}"
        return 1
    fi
}

# Проверка Remnawave Panel API
validate_remnawave_api() {
    local api_url="${1}"
    local api_key="${2}"
    local http_code

    http_code=$(curl -s "${api_url}/api/health" \
        -H "Authorization: Bearer ${api_key}" \
        --max-time 10 \
        -o /dev/null \
        -w "%{http_code}" 2>/dev/null)

    if [[ "$http_code" == "200" ]]; then
        info "Remnawave API доступен: ${api_url}"
        return 0
    else
        error "Remnawave API недоступен (HTTP ${http_code}): ${api_url}"
        error "Убедись что панель запущена и API ключ верен"
        return 1
    fi
}

# Проверка ресурсов сервера
check_resources() {
    local min_disk_gb="${1:-2}"
    local min_ram_mb="${2:-512}"
    local ok=true

    # Свободное место на диске (GB)
    local free_kb
    free_kb=$(df -k /opt 2>/dev/null | awk 'NR==2{print $4}' || df -k / | awk 'NR==2{print $4}')
    local free_gb=$(( free_kb / 1024 / 1024 ))
    if [[ $free_gb -lt $min_disk_gb ]]; then
        error "Недостаточно места на диске: ${free_gb}GB (нужно ≥${min_disk_gb}GB)"
        ok=false
    else
        info "Место на диске: ${free_gb}GB ✓"
    fi

    # RAM (MB)
    local ram_mb
    ram_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    if [[ $ram_mb -lt $min_ram_mb ]]; then
        error "Недостаточно RAM: ${ram_mb}MB (нужно ≥${min_ram_mb}MB)"
        ok=false
    else
        info "RAM: ${ram_mb}MB ✓"
    fi

    [[ "$ok" == "true" ]] && return 0 || return 1
}

# =============================================================================
# ЗАГРУЗКА МОДУЛЕЙ
# =============================================================================

load_module() {
    local module="${1}"
    local module_file="${LIB_DIR}/${module}.sh"

    if [[ ! -f "$module_file" ]]; then
        error "Модуль не найден: ${module_file}"
        return 1
    fi

    # shellcheck disable=SC1090
    source "$module_file"
    return 0
}

# =============================================================================
# ИНИЦИАЛИЗАЦИЯ СТРУКТУРЫ КАТАЛОГОВ
# =============================================================================

init_directories() {
    local dirs=(
        "${ORCHESTRA_DIR}"
        "${LIB_DIR}"
        "${FLEET_DIR}"
        "${FLEET_DIR}/credentials"
        "${STATE_DIR}"
        "${BACKUP_DIR}"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
    done

    chmod 700 "${FLEET_DIR}/credentials"

    # nodes.conf — если нет, создаём с примером закомментированным
    if [[ ! -f "$NODES_CONF" ]]; then
        cat > "$NODES_CONF" << 'EOF'
# Orchestra Fleet — реестр серверов
# Формат: [имя-ноды]
#   host        = IP или hostname
#   port        = SSH порт (обычно 22 или 2222)
#   user        = SSH пользователь
#   role        = xray | remnawave-panel | remnawave-node | bedolaga | mixed
#   key         = путь к SSH ключу (если используется)
#   node_domain = домен ноды (для Xray)
#   panel_url   = URL панели (для remnawave-node)
#   installed   = дата установки (YYYY-MM-DD)
#   status      = pending | ok | error | maintenance

EOF
        info "Создан fleet/nodes.conf"
    fi

    # Создаём лог если нет
    touch "${ORCHESTRA_LOG}"

    # Регистрируем команду orchestra если ещё нет
    if [[ ! -L /usr/local/bin/orchestra && ! -f /usr/local/bin/orchestra ]]; then
        ln -sf "${ORCHESTRA_DIR}/orchestra.sh" /usr/local/bin/orchestra
        chmod +x "${ORCHESTRA_DIR}/orchestra.sh"
        info "Команда 'orchestra' зарегистрирована в /usr/local/bin/"
    fi
}

# Первый запуск — копируем себя в /opt/orchestra если ещё не там
self_install() {
    local script_path
    script_path=$(readlink -f "${BASH_SOURCE[0]}")

    if [[ "$script_path" != "${ORCHESTRA_DIR}/orchestra.sh" ]]; then
        step_msg "Устанавливаю Orchestra в ${ORCHESTRA_DIR}..."
        init_directories
        cp "$script_path" "${ORCHESTRA_DIR}/orchestra.sh"
        chmod +x "${ORCHESTRA_DIR}/orchestra.sh"

        # Копируем lib/ если есть рядом со скриптом
        local script_lib_dir
        script_lib_dir="$(dirname "$script_path")/lib"
        if [[ -d "$script_lib_dir" ]]; then
            cp -r "$script_lib_dir/"* "${LIB_DIR}/" 2>/dev/null || true
        fi

        info "Orchestra установлена в ${ORCHESTRA_DIR}"
        info "Используй команду: orchestra"
        echo ""
    else
        init_directories
    fi
}

# =============================================================================
# ГЛАВНОЕ МЕНЮ
# =============================================================================

show_banner() {
    echo ""
    echo -e "${B}${BOLD}"
    echo "  ██████╗ ██████╗  ██████╗██╗  ██╗███████╗███████╗████████╗██████╗  █████╗ "
    echo " ██╔═══██╗██╔══██╗██╔════╝██║  ██║██╔════╝██╔════╝╚══██╔══╝██╔══██╗██╔══██╗"
    echo " ██║   ██║██████╔╝██║     ███████║█████╗  ███████╗   ██║   ██████╔╝███████║"
    echo " ██║   ██║██╔══██╗██║     ██╔══██║██╔══╝  ╚════██║   ██║   ██╔══██╗██╔══██║"
    echo " ╚██████╔╝██║  ██║╚██████╗██║  ██║███████╗███████║   ██║   ██║  ██║██║  ██║"
    echo "  ╚═════╝ ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚══════╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝"
    echo -e "${N}"
    echo -e "  ${GR}VPN Infrastructure Manager v${ORCHESTRA_VERSION}${N}"
    echo ""
}

main_menu() {
    while true; do
        clear
        show_banner

        # Статус: IP сервера и список установленных модулей
        local server_ip
        server_ip=$(get_server_ip 2>/dev/null) || server_ip="определяется..."
        echo -e "  ${GR}Сервер: ${W}${server_ip}${N}"

        local state_file="${STATE_DIR}/${server_ip}.conf"
        if [[ -f "$state_file" ]]; then
            local installed_modules
            installed_modules=$(grep -oP '(?<=INSTALLED_MODULES=")[^"]+' "$state_file" 2>/dev/null || echo "")
            [[ -n "$installed_modules" ]] && \
                echo -e "  ${GR}Установлено: ${G}${installed_modules}${N}"
        fi

        echo ""
        echo -e "  ${BOLD}═══ Модули установки ════════════════════════${N}"
        echo -e "  ${C}1${N})  sys          — Hardening системы (SSH, UFW, BBR, fail2ban)"
        echo -e "  ${C}2${N})  xray         — VLESS + Reality + XHTTP"
        echo -e "  ${C}3${N})  remnawave    — Remnawave Panel + Node"
        echo -e "  ${C}4${N})  bedolaga     — Telegram-бот продажи подписок"
        echo -e "  ${C}5${N})  proxy        — Nginx / Caddy reverse proxy"
        echo -e "  ${C}6${N})  warp         — Cloudflare WARP"
        echo -e "  ${C}7${N})  trafficguard — Блокировка сканеров РКН"
        echo ""
        echo -e "  ${BOLD}═══ Управление ══════════════════════════════${N}"
        echo -e "  ${C}8${N})  fleet        — Управление флотом нод"
        echo -e "  ${C}9${N})  monitor      — Мониторинг и проверка блокировок"
        echo -e "  ${C}b${N})  backup       — Резервные копии"
        echo -e "  ${C}d${N})  diag         — Диагностика ноды"
        echo ""
        echo -e "  ${BOLD}═══ Прочее ══════════════════════════════════${N}"
        echo -e "  ${C}s${N})  status       — Статус этого сервера"
        echo -e "  ${C}l${N})  log          — Последние записи лога"
        echo -e "  ${C}0${N})  Выход"
        echo ""

        ask "Выбор" ""
        local choice="${REPLY}"

        case "$choice" in
            1)
                load_module "sys" && sys_menu || warn "Модуль sys недоступен"
                press_enter
                ;;
            2)
                load_module "xray" && xray_menu || warn "Модуль xray недоступен"
                press_enter
                ;;
            3)
                load_module "remnawave" && remnawave_menu || warn "Модуль remnawave недоступен"
                press_enter
                ;;
            4)
                load_module "bedolaga" && bedolaga_menu || warn "Модуль bedolaga недоступен"
                press_enter
                ;;
            5)
                load_module "proxy" && proxy_menu || warn "Модуль proxy недоступен"
                press_enter
                ;;
            6)
                load_module "warp" && warp_menu || warn "Модуль warp недоступен"
                press_enter
                ;;
            7)
                load_module "trafficguard" && trafficguard_menu || warn "Модуль trafficguard недоступен"
                press_enter
                ;;
            8)
                fleet_menu
                press_enter
                ;;
            9)
                load_module "monitor" && monitor_menu || warn "Модуль monitor недоступен"
                press_enter
                ;;
            b|B)
                load_module "backup" && backup_menu || warn "Модуль backup недоступен"
                press_enter
                ;;
            d|D)
                diag_menu
                press_enter
                ;;
            s|S)
                show_server_status
                press_enter
                ;;
            l|L)
                show_log
                press_enter
                ;;
            0|q|Q)
                echo ""
                info "До свидания!"
                echo ""
                exit 0
                ;;
            *)
                warn "Неизвестный выбор: ${choice}"
                sleep 1
                ;;
        esac
    done
}

# =============================================================================
# SSH УТИЛИТЫ ДЛЯ УДАЛЁННОГО РЕЖИМА
# =============================================================================

# Проверка SSH подключения к ноде
# Возвращает 0 если успешно, 1 если ошибка
ssh_connect() {
    local host="${1}"
    local port="${2:-22}"
    local user="${3:-root}"
    local key="${4:-}"
    
    step_msg "Проверка SSH: ${user}@${host}:${port}..."
    
    local ssh_cmd=("ssh" "-o" "ConnectTimeout=10" "-o" "StrictHostKeyChecking=accept-new" "-p" "$port")
    
    # BatchMode только если есть ключ
    if [[ -n "$key" && -f "$key" ]]; then
        ssh_cmd+=("-o" "BatchMode=yes" "-i" "$key")
    fi
    
    # Если есть переменная SSHPASS, используем sshpass
    if [[ -n "${SSHPASS:-}" ]] && command -v sshpass &>/dev/null; then
        ssh_cmd=("sshpass" "-e" "${ssh_cmd[@]}")
    fi
    
    ssh_cmd+=("${user}@${host}" "echo 'SSH OK'")
    
    if "${ssh_cmd[@]}" &>/dev/null; then
        info "SSH подключение успешно"
        return 0
    else
        error "SSH подключение не удалось"
        return 1
    fi
}

# Загрузка файла на ноду через SCP
ssh_upload() {
    local local_file="${1}"
    local host="${2}"
    local port="${3:-22}"
    local user="${4:-root}"
    local key="${5:-}"
    local remote_path="${6:-/tmp/}"
    
    step_msg "Загрузка файла на ${host}:${remote_path}..."
    
    local scp_cmd=("scp" "-o" "ConnectTimeout=10" "-o" "StrictHostKeyChecking=accept-new" "-P" "$port")
    
    if [[ -n "$key" && -f "$key" ]]; then
        scp_cmd+=("-o" "BatchMode=yes" "-i" "$key")
    fi
    
    # Если есть переменная SSHPASS, используем sshpass
    if [[ -n "${SSHPASS:-}" ]] && command -v sshpass &>/dev/null; then
        scp_cmd=("sshpass" "-e" "${scp_cmd[@]}")
    fi
    
    scp_cmd+=("$local_file" "${user}@${host}:${remote_path}")
    
    if "${scp_cmd[@]}" &>/dev/null; then
        info "Файл загружен: $(basename "$local_file") → ${host}:${remote_path}"
        return 0
    else
        error "Ошибка загрузки файла"
        return 1
    fi
}

# Выполнение команды на ноде через SSH
ssh_execute() {
    local host="${1}"
    local port="${2:-22}"
    local user="${3:-root}"
    local key="${4:-}"
    local cmd="${5}"
    
    local ssh_cmd=("ssh" "-o" "ConnectTimeout=10" "-o" "StrictHostKeyChecking=accept-new" "-p" "$port")
    
    if [[ -n "$key" && -f "$key" ]]; then
        ssh_cmd+=("-o" "BatchMode=yes" "-i" "$key")
    fi
    
    # Если есть переменная SSHPASS, используем sshpass
    if [[ -n "${SSHPASS:-}" ]] && command -v sshpass &>/dev/null; then
        ssh_cmd=("sshpass" "-e" "${ssh_cmd[@]}")
    fi
    
    ssh_cmd+=("${user}@${host}" "$cmd")
    
    step_msg "Выполняю команду на ${host}..."
    
    if "${ssh_cmd[@]}" 2>&1; then
        return 0
    else
        return 1
    fi
}

# Деплой модуля на удалённую ноду
fleet_deploy_module() {
    local node_name="${1}"
    local module="${2}"
    local auto="${3:-false}"
    
    local host port user key
    host=$(read_node "$node_name" "host") || { error "Нода ${node_name} не найдена"; return 1; }
    port=$(read_node "$node_name" "port" 2>/dev/null || echo "22")
    user=$(read_node "$node_name" "user" 2>/dev/null || echo "root")
    key=$(read_node "$node_name" "key" 2>/dev/null || echo "")
    
    section "Деплой ${module} на ${node_name} (${host})"
    
    # Проверка существования модуля локально
    local module_file="${LIB_DIR}/${module}.sh"
    if [[ ! -f "$module_file" ]]; then
        error "Модуль ${module} не найден в ${LIB_DIR}"
        return 1
    fi
    
    # Проверка SSH
    if ! ssh_connect "$host" "$port" "$user" "$key"; then
        error "Не удалось подключиться к ноде ${node_name}"
        return 1
    fi
    
    # Загрузка модуля
    local remote_file="/tmp/orchestra-${module}.sh"
    if ! ssh_upload "$module_file" "$host" "$port" "$user" "$key" "$remote_file"; then
        error "Не удалось загрузить модуль на ноду"
        return 1
    fi
    
    # Выполнение модуля в авто-режиме
    local exec_cmd="bash ${remote_file}"
    if [[ "$auto" == "true" ]]; then
        exec_cmd="bash ${remote_file} --auto"
    fi
    
    step_msg "Запускаю модуль на ноде..."
    if ! ssh_execute "$host" "$port" "$user" "$key" "$exec_cmd"; then
        error "Ошибка выполнения модуля на ноде"
        return 1
    fi
    
    # Очистка
    ssh_execute "$host" "$port" "$user" "$key" "rm -f ${remote_file}" &>/dev/null || true
    
    info "Деплой завершён успешно"
    write_node "$node_name" "status" "ok" 2>/dev/null || true
    return 0
}

# Параллельный деплой модуля на все ноды флота
fleet_deploy_module_all() {
    local module="${1}"
    local auto="${2:-false}"
    
    # Проверка существования модуля локально
    local module_file="${LIB_DIR}/${module}.sh"
    if [[ ! -f "$module_file" ]]; then
        error "Модуль ${module} не найден в ${LIB_DIR}"
        return 1
    fi
    
    section "Параллельный деплой ${module} на все ноды флота"
    
    local nodes=()
    while IFS= read -r node_name; do
        nodes+=("$node_name")
    done < <(list_nodes)
    
    local total=${#nodes[@]}
    if [[ $total -eq 0 ]]; then
        warn "Нет нод для деплоя"
        return 0
    fi
    
    info "Деплой на ${total} нод(ы) в параллельном режиме..."
    
    local pids=()
    local results=()
    local failed=0
    local completed=0
    
    # Функция для деплоя одной ноды (запускается в фоне)
    _deploy_one_node() {
        local node_name="$1"
        local module="$2"
        local auto="$3"
        
        # Создаём именованный пайп для захвата вывода
        local pipe_file="/tmp/orchestra-deploy-${node_name}.pipe"
        mkfifo "$pipe_file" 2>/dev/null || true
        
        # Запускаем деплой, перенаправляем вывод в пайп
        fleet_deploy_module "$node_name" "$module" "$auto" > "$pipe_file" 2>&1 &
        local deploy_pid=$!
        
        # Читаем вывод из пайпа, добавляем префикс ноды
        while IFS= read -r line; do
            echo "[${node_name}] $line"
        done < "$pipe_file" &
        local reader_pid=$!
        
        wait $deploy_pid 2>/dev/null
        local ret=$?
        
        # Очистка
        kill $reader_pid 2>/dev/null || true
        rm -f "$pipe_file" 2>/dev/null || true
        
        return $ret
    }
    
    # Запускаем все ноды в фоне
    for node_name in "${nodes[@]}"; do
        _deploy_one_node "$node_name" "$module" "$auto" &
        pids+=($!)
        echo -e "  ${G}▶${N} Запущен деплой на ${C}${node_name}${N} (PID $!)"
    done
    
    # Ожидаем завершения всех процессов
    echo ""
    step_msg "Ожидаю завершения деплоя на ${#pids[@]} нод..."
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null
        local ret=$?
        if [[ $ret -eq 0 ]]; then
            ((completed++)) || true
        else
            ((failed++)) || true
        fi
    done
    
    # Итог
    echo ""
    if [[ $failed -eq 0 ]]; then
        info "Параллельный деплой завершён успешно: ${completed}/${total} нод"
    else
        error "Параллельный деплой завершён с ошибками: ${completed} успешно, ${failed} с ошибкой"
    fi
    
    return $((failed > 0 ? 1 : 0))
}

# =============================================================================
# FLEET МЕНЮ
# =============================================================================

fleet_menu() {
    clear
    section "Fleet — Управление флотом нод"

    if ! list_nodes &>/dev/null; then
        warn "Fleet пуст. Добавь ноды в ${NODES_CONF}"
        echo ""
        echo -e "  ${C}1${N}) Добавить ноду вручную"
        echo -e "  ${C}0${N}) Назад"
        echo ""
        ask "Выбор" "0"
        case "$REPLY" in
            1) fleet_add_node ;;
            *) return 0 ;;
        esac
        return 0
    fi

    # Показываем список нод
    echo ""
    printf "  %-12s %-18s %-8s %-22s %-10s\n" "Имя" "IP" "Порт" "Роль" "Статус"
    printf "  %-12s %-18s %-8s %-22s %-10s\n" "────────────" "──────────────────" "────────" "──────────────────────" "──────────"
    while IFS= read -r node_name; do
        local host port role status
        host=$(read_node "$node_name" "host" 2>/dev/null || echo "?")
        port=$(read_node "$node_name" "port" 2>/dev/null || echo "22")
        role=$(read_node "$node_name" "role" 2>/dev/null || echo "?")
        status=$(read_node "$node_name" "status" 2>/dev/null || echo "?")

        local status_color="${N}"
        case "$status" in
            ok)          status_color="${G}" ;;
            error|fail*) status_color="${R}" ;;
            pending)     status_color="${Y}" ;;
            maintenance) status_color="${Y}" ;;
        esac

        printf "  ${C}%-12s${N} %-18s %-8s %-22s ${status_color}%-10s${N}\n" \
            "$node_name" "$host" "$port" "$role" "$status"
    done < <(list_nodes)

    echo ""
    echo -e "  ${C}1${N}) Статус всех нод (ping + порты)"
    echo -e "  ${C}2${N}) Деплой модуля на ноду"
    echo -e "  ${C}3${N}) Деплой модуля на ВСЕ ноды (параллельно)"
    echo -e "  ${C}4${N}) Добавить ноду"
    echo -e "  ${C}5${N}) Сводка флота"
    echo -e "  ${C}0${N}) Назад"
    echo ""

    ask "Выбор" "0"
    case "$REPLY" in
        1) fleet_status_all ;;
        2) fleet_deploy_interactive ;;
        3) fleet_deploy_all_interactive ;;
        4) fleet_add_node ;;
        5) fleet_summary ;;
        0) return 0 ;;
        *) warn "Неизвестный выбор" ;;
    esac
}

# Быстрый статус всех нод (L1+L2)
fleet_status_all() {
    section "Статус флота"

    while IFS= read -r node_name; do
        local host port
        host=$(read_node "$node_name" "host" 2>/dev/null || echo "")
        port=$(read_node "$node_name" "port" 2>/dev/null || echo "22")

        [[ -z "$host" ]] && continue

        echo -ne "  ${C}${node_name}${N} (${host}): "

        # L1 — ping
        local l1="✓" l2="✓"
        if ! ping -c 1 -W 2 "${host}" &>/dev/null; then
            l1="${R}✗${N}"
            l2="${R}-${N}"
            echo -e "ping=${l1} :443=${l2}"
            write_node "$node_name" "status" "error" 2>/dev/null || true
            continue
        fi

        # L2 — TCP порт 443
        if ! timeout 3 bash -c "echo >/dev/tcp/${host}/443" 2>/dev/null; then
            l2="${R}✗${N}"
            write_node "$node_name" "status" "error" 2>/dev/null || true
        else
            write_node "$node_name" "status" "ok" 2>/dev/null || true
        fi

        echo -e "ping=${G}${l1}${N} :443=${l2}"
    done < <(list_nodes)

    echo ""
}

# Сводка по флоту (статистика)
fleet_summary() {
    section "Сводка флота"
    
    local total=0 ok=0 error=0 pending=0 maintenance=0 unknown=0
    local roles=()
    
    while IFS= read -r node_name; do
        ((total++)) || true
        local status role
        status=$(read_node "$node_name" "status" 2>/dev/null || echo "unknown")
        role=$(read_node "$node_name" "role" 2>/dev/null || echo "unknown")
        
        case "$status" in
            ok)          ((ok++)) || true ;;
            error|fail*) ((error++)) || true ;;
            pending)     ((pending++)) || true ;;
            maintenance) ((maintenance++)) || true ;;
            *)           ((unknown++)) || true ;;
        esac
        
        # Собираем уникальные роли
        if [[ ! " ${roles[*]} " =~ " ${role} " ]]; then
            roles+=("$role")
        fi
    done < <(list_nodes)
    
    if [[ $total -eq 0 ]]; then
        warn "Флот пуст"
        return 0
    fi
    
    echo -e "  ${BOLD}Всего нод:${N} ${total}"
    echo -e "  ${G}✓ OK:${N} ${ok}"
    echo -e "  ${R}✗ Ошибка:${N} ${error}"
    echo -e "  ${Y}⏳ Ожидание:${N} ${pending}"
    echo -e "  ${Y}🔧 Обслуживание:${N} ${maintenance}"
    echo -e "  ${GR}? Неизвестно:${N} ${unknown}"
    echo ""
    
    if [[ ${#roles[@]} -gt 0 ]]; then
        echo -e "  ${BOLD}Роли:${N} ${roles[*]}"
    fi
    
    # Последняя проверка
    local last_check
    last_check=$(stat -c %y "$NODES_CONF" 2>/dev/null | cut -d' ' -f1) || last_check="?"
    echo -e "  ${BOLD}Обновлено:${N} ${last_check}"
}

# Интерактивный деплой модуля на ноду
fleet_deploy_interactive() {
    echo ""
    ask "Имя ноды (из nodes.conf)" ""
    local node_name="$REPLY"
    [[ -z "$node_name" ]] && return 1

    ask "Модуль для деплоя (sys/xray/remnawave/...)" "sys"
    local module="$REPLY"

    ask_yn "Запустить в автоматическом режиме (--auto)?" "да"
    local auto_mode="$([[ $? -eq 0 ]] && echo "true" || echo "false")"

    if ! fleet_deploy_module "$node_name" "$module" "$auto_mode"; then
        error "Деплой не удался"
        return 1
    fi
    
    info "Деплой завершён"
}

# Параллельный деплой модуля на все ноды
fleet_deploy_all_interactive() {
    echo ""
    ask "Модуль для деплоя на все ноды (sys/xray/remnawave/...)" "sys"
    local module="$REPLY"
    [[ -z "$module" ]] && return 1
    
    ask_yn "Запустить в автоматическом режиме (--auto)?" "да"
    local auto_mode="$([[ $? -eq 0 ]] && echo "true" || echo "false")"
    
    ask_yn "Подтверждаете деплой ${module} на ВСЕ ноды флота?" "нет"
    [[ $? -ne 0 ]] && { warn "Отменено"; return 0; }
    
    if ! fleet_deploy_module_all "$module" "$auto_mode"; then
        error "Параллельный деплой завершился с ошибками"
        return 1
    fi
    
    info "Параллельный деплой завершён"
}

# Добавление новой ноды
fleet_add_node() {
    section "Добавить ноду в fleet"

    ask "Имя ноды (например: node-03)" ""
    local node_name="$REPLY"
    [[ -z "$node_name" ]] && { warn "Имя не введено"; return 1; }

    ask "IP или hostname сервера" ""
    local host="$REPLY"
    [[ -z "$host" ]] && { warn "IP не введён"; return 1; }

    ask "SSH порт" "22"
    local port="$REPLY"

    ask "SSH пользователь" "root"
    local user="$REPLY"

    ask "Роль (xray/remnawave-panel/remnawave-node/bedolaga/mixed)" "xray"
    local role="$REPLY"

    ask "Путь к SSH ключу (Enter — пропустить, использовать пароль)" ""
    local key="$REPLY"

    add_node "$node_name" "$host" "$port" "$user" "$role" "$key"
}

# =============================================================================
# ДИАГНОСТИКА
# =============================================================================

diag_menu() {
    section "Диагностика ноды"

    ask "IP ноды для диагностики" ""
    local target_ip="$REPLY"
    [[ -z "$target_ip" ]] && return 1

    echo ""
    step_msg "L1: ICMP ping..."
    if ping -c 3 -W 2 "${target_ip}" &>/dev/null; then
        info "L1 ping ✓"
    else
        error "L1 ping ✗ — сервер недоступен"
        return 1
    fi

    step_msg "L2: TCP :443..."
    if timeout 3 bash -c "echo >/dev/tcp/${target_ip}/443" 2>/dev/null; then
        info "L2 :443 ✓"
    else
        error "L2 :443 ✗ — порт закрыт"
    fi

    step_msg "L3: TLS handshake..."
    if curl -sk --max-time 5 "https://${target_ip}/" -o /dev/null; then
        info "L3 TLS ✓"
    else
        warn "L3 TLS ✗ — возможно, Xray не отвечает или нет сертификата"
    fi

    step_msg "L4: HTTP decoy..."
    local http_code
    http_code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "http://${target_ip}/" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" ]]; then
        info "L4 HTTP decoy ✓ (200)"
    else
        warn "L4 HTTP decoy: код ${http_code}"
    fi

    echo ""
    warn "L5 (ipregion.sh) и L7 (запрет РКН) доступны в модуле monitor"
}

# =============================================================================
# СТАТУС СЕРВЕРА
# =============================================================================

show_server_status() {
    section "Статус сервера"

    local server_ip
    server_ip=$(get_server_ip 2>/dev/null) || server_ip="?"
    echo -e "  ${C}IP сервера:${N} ${server_ip}"

    local state_file="${STATE_DIR}/${server_ip}.conf"
    if [[ -f "$state_file" ]]; then
        echo ""
        echo -e "  ${BOLD}Сохранённая конфигурация:${N}"
        while IFS='=' read -r key val; do
            [[ "$key" =~ ^# ]] && continue
            [[ -z "$key" ]] && continue
            echo -e "    ${GR}${key}${N} = ${val//\"/}"
        done < "$state_file"
    else
        warn "Нет сохранённого конфига для ${server_ip}"
    fi

    echo ""
    echo -e "  ${BOLD}Запущенные сервисы:${N}"
    for svc in xray nginx fail2ban ufw; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "    ${G}✓${N} ${svc}"
        else
            echo -e "    ${GR}·${N} ${svc} (не запущен)"
        fi
    done

    # Docker
    if command -v docker &>/dev/null; then
        echo ""
        echo -e "  ${BOLD}Docker контейнеры:${N}"
        docker ps --format "    ${G}✓${N} {{.Names}} ({{.Status}})" 2>/dev/null || \
            echo -e "    ${GR}(нет запущенных контейнеров)${N}"
    fi
}

# =============================================================================
# ЛОГ
# =============================================================================

show_log() {
    section "Лог Orchestra (последние 50 записей)"
    if [[ -f "$ORCHESTRA_LOG" ]]; then
        tail -50 "$ORCHESTRA_LOG"
    else
        warn "Лог пуст или не найден"
    fi
}

# =============================================================================
# ОБРАБОТКА АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ
# =============================================================================

handle_args() {
    local cmd="${1:-}"
    local arg2="${2:-}"
    local arg3="${3:-}"

    case "$cmd" in
        "remote")
            # orchestra remote <ip> <module>
            local target_ip="$arg2"
            local module="$arg3"
            [[ -z "$target_ip" ]] && { error "Укажи IP: orchestra remote <ip> <module>"; exit 1; }
            [[ -z "$module"    ]] && { error "Укажи модуль: orchestra remote <ip> <module>"; exit 1; }
            warn "Удалённый режим будет реализован в Этапе 9"
            exit 0
            ;;
        "fleet")
            # orchestra fleet <command>
            local fleet_cmd="$arg2"
            case "$fleet_cmd" in
                status)  check_root; init_directories; fleet_status_all ;;
                monitor)
                    check_root; init_directories
                    load_module "monitor" && fleet_monitor_all || warn "Модуль monitor недоступен"
                    ;;
                add)
                    check_root; init_directories
                    fleet_add_node
                    ;;
                *)
                    error "Неизвестная fleet команда: ${fleet_cmd}"
                    echo "Доступно: status | monitor | add"
                    exit 1
                    ;;
            esac
            exit 0
            ;;
        "diag")
            # orchestra diag <ip>
            check_root; init_directories
            local target_ip="$arg2"
            [[ -z "$target_ip" ]] && { error "Укажи IP: orchestra diag <ip>"; exit 1; }
            section "Диагностика: ${target_ip}"
            REPLY="$target_ip"
            diag_menu
            exit 0
            ;;
        "version"|"--version"|"-v")
            echo "Orchestra v${ORCHESTRA_VERSION}"
            exit 0
            ;;
        "help"|"--help"|"-h")
            show_help
            exit 0
            ;;
        "")
            # Без аргументов — главное меню
            return 0
            ;;
        *)
            # Может быть именем модуля — пробуем запустить напрямую
            if [[ -f "${LIB_DIR}/${cmd}.sh" ]]; then
                check_root; init_directories
                load_module "$cmd"
                # Вызываем <module>_menu если функция существует
                if declare -f "${cmd}_menu" &>/dev/null; then
                    "${cmd}_menu"
                else
                    error "Модуль ${cmd} загружен, но не имеет функции ${cmd}_menu"
                fi
                exit 0
            fi
            error "Неизвестная команда: ${cmd}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

show_help() {
    echo ""
    echo -e "${BOLD}Orchestra v${ORCHESTRA_VERSION}${N} — VPN Infrastructure Manager"
    echo ""
    echo -e "${BOLD}Использование:${N}"
    echo "  orchestra                          # Главное меню"
    echo "  orchestra <module>                 # Прямой запуск модуля"
    echo "  orchestra remote <ip> <module>     # Удалённый деплой (Этап 9)"
    echo "  orchestra fleet status             # Статус всех нод"
    echo "  orchestra fleet monitor            # Мониторинг блокировок"
    echo "  orchestra fleet add                # Добавить ноду"
    echo "  orchestra diag <ip>                # Диагностика ноды"
    echo "  orchestra version                  # Версия"
    echo ""
    echo -e "${BOLD}Модули:${N}"
    echo "  sys, xray, remnawave, bedolaga, proxy, warp, trafficguard, backup, monitor"
    echo ""
}

# =============================================================================
# ПРОВЕРКА ПРАВ ROOT
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Orchestra требует прав root"
        error "Запусти: sudo bash orchestra.sh"
        exit 1
    fi
}

# =============================================================================
# ТОЧКА ВХОДА
# =============================================================================

# Если файл используется через source — только загружаем функции, не запускаем меню
if [[ "$ORCHESTRA_SOURCED" == "true" ]]; then
    return 0
fi

# Обработка аргументов
handle_args "${@}"

# Проверка root
check_root

# Первичная установка и инициализация
self_install

# Главное меню
main_menu
