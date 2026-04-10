#!/usr/bin/env bash
# =============================================================================
# bedolaga.sh — Bedolaga Telegram Bot управление
# Модуль Orchestra | Этап 6
# =============================================================================
set -euo pipefail

[[ -n "${BEDOLAGA_MODULE_LOADED:-}" ]] && return 0
readonly BEDOLAGA_MODULE_LOADED=1

# =============================================================================
# КОНСТАНТЫ
# =============================================================================

readonly BDL_BASE_DIR="/opt/bedolaga"
readonly BDL_ENV_FILE="${BDL_BASE_DIR}/.env"
readonly BDL_COMPOSE_FILE="${BDL_BASE_DIR}/docker-compose.yml"
readonly BDL_VENV_DIR="${BDL_BASE_DIR}/venv"
readonly BDL_LOG_DIR="/var/log/bedolaga"
readonly BDL_SERVICE_FILE="/etc/systemd/system/bedolaga.service"

# Python версия
readonly BDL_PYTHON_VER="3.13"
readonly BDL_PYTHON_BIN="python${BDL_PYTHON_VER}"

# Docker образ (если используется Docker-режим)
readonly BDL_DOCKER_IMAGE="ghcr.io/remnawave/bedolaga:latest"

# Поддерживаемые платёжные системы
readonly BDL_PAYMENT_SYSTEMS=(
    "yookassa"
    "freekassa"
    "cryptobot"
    "tribute"
    "stars"
    "lava"
    "xrocket"
    "payok"
    "rukassa"
    "robokassa"
    "heleket"
    "anypay"
    "enot"
    "crystalpay"
    "aaio"
)

# =============================================================================
# МЕНЮ МОДУЛЯ
# =============================================================================

bedolaga_menu() {
    clear
    section "bedolaga — Telegram Bot"

    _bdl_show_status_brief

    echo ""
    echo -e "  ${C}1${N}) Установить бота"
    echo -e "  ${C}2${N}) Статус"
    echo -e "  ${C}3${N}) Запустить / перезапустить"
    echo -e "  ${C}4${N}) Остановить"
    echo -e "  ${C}5${N}) Показать конфигурацию"
    echo -e "  ${C}6${N}) Редактировать .env"
    echo -e "  ${C}7${N}) Показать логи"
    echo -e "  ${C}8${N}) Обновить бота"
    echo -e "  ${C}9${N}) Удалить"
    echo -e "  ${C}0${N}) Назад"
    echo ""

    ask "Выбор" "1"
    case "$REPLY" in
        1) bedolaga_install ;;
        2) bedolaga_status ;;
        3) bedolaga_restart ;;
        4) bedolaga_stop ;;
        5) bedolaga_show_config ;;
        6) bedolaga_edit_env ;;
        7) bedolaga_logs ;;
        8) bedolaga_update ;;
        9) bedolaga_uninstall ;;
        0) return 0 ;;
        *) warn "Неверный выбор" ;;
    esac
}

_bdl_show_status_brief() {
    local status_line="  ${GR}●${N} Бот: не установлен"

    if [[ -f "${BDL_SERVICE_FILE}" ]]; then
        if systemctl is-active --quiet bedolaga 2>/dev/null; then
            status_line="  ${G}●${N} Бот: запущен (systemd)"
        else
            status_line="  ${R}●${N} Бот: остановлен (systemd)"
        fi
    elif [[ -f "${BDL_COMPOSE_FILE}" ]]; then
        if docker compose -f "${BDL_COMPOSE_FILE}" ps 2>/dev/null | grep -q "Up"; then
            status_line="  ${G}●${N} Бот: запущен (Docker)"
        else
            status_line="  ${R}●${N} Бот: остановлен (Docker)"
        fi
    fi

    echo -e "$status_line"
}

# =============================================================================
# УСТАНОВКА
# =============================================================================

bedolaga_install() {
    section "Установка Bedolaga Bot"

    if [[ -d "${BDL_BASE_DIR}" ]] && [[ -f "${BDL_ENV_FILE}" ]]; then
        warn "Бот уже установлен в ${BDL_BASE_DIR}"
        ask_yn "Переустановить?" "нет"
        [[ $? -ne 0 ]] && return 0
        bedolaga_uninstall silent
    fi

    hint "Bedolaga Telegram Bot" \
        "Бот для продажи VPN-подписок через Telegram" \
        "Интеграция с Remnawave Panel через API" \
        "Поддержка 15+ платёжных систем"

    # =================== ОСНОВНЫЕ ПАРАМЕТРЫ ===================

    echo -e "\n  ${BOLD}=== Telegram Bot ===${N}"

    ask "Bot Token (от @BotFather)" ""
    local bot_token="$REPLY"
    [[ -z "$bot_token" ]] && { warn "Bot Token не введён"; return 1; }
    # Валидация формата токена
    if ! echo "$bot_token" | grep -qP '^\d+:[A-Za-z0-9_-]{35,}$'; then
        warn "Формат токена неверный (ожидается: 1234567890:ABC...)"
        return 1
    fi

    ask "Admin Telegram ID (числовой)" ""
    local admin_id="$REPLY"
    [[ -z "$admin_id" ]] && { warn "Admin ID не введён"; return 1; }
    if ! echo "$admin_id" | grep -qP '^\d+$'; then
        warn "Admin ID должен быть числом"
        return 1
    fi

    ask "Название магазина (отображается в боте)" "VPN Store"
    local shop_name="$REPLY"

    # =================== REMNAWAVE API ===================

    echo -e "\n  ${BOLD}=== Remnawave Panel ===${N}"

    ask "URL панели Remnawave (например: https://panel.example.com)" ""
    local panel_url="$REPLY"
    [[ -z "$panel_url" ]] && { warn "URL панели не введён"; return 1; }

    ask "API токен панели (Settings → API Tokens)" ""
    local panel_api_token="$REPLY"
    [[ -z "$panel_api_token" ]] && { warn "API токен не введён"; return 1; }

    ask "Inbound UUID из панели (Inbounds → UUID)" ""
    local inbound_uuid="$REPLY"

    ask "SUB домен для ссылок подписки" ""
    local sub_domain="$REPLY"

    # =================== БАЗА ДАННЫХ ===================

    echo -e "\n  ${BOLD}=== База данных ===${N}"

    echo -e "  Режим базы данных:"
    echo -e "  ${C}1${N}) SQLite (простой, для одного бота)"
    echo -e "  ${C}2${N}) PostgreSQL (рекомендуется для продакшн)"
    ask "Выбор" "1"
    local db_mode="$REPLY"

    local db_url=""
    if [[ "$db_mode" == "2" ]]; then
        ask "PostgreSQL URL (postgresql://user:pass@host:5432/db)" ""
        db_url="$REPLY"
        if [[ -z "$db_url" ]]; then
            warn "URL БД не введён — используем SQLite"
            db_url="sqlite+aiosqlite:///./bedolaga.db"
        fi
    else
        db_url="sqlite+aiosqlite:///./bedolaga.db"
    fi

    # =================== ПЛАТЁЖНЫЕ СИСТЕМЫ ===================

    echo -e "\n  ${BOLD}=== Платёжные системы ===${N}"
    echo -e "  ${GR}Оставь пустым те системы, которые не используешь${N}"
    echo ""

    local -A payment_keys

    _bdl_ask_payment "YooKassa (ЮКасса)" "yookassa" payment_keys \
        "YOOKASSA_SHOP_ID" "Shop ID" \
        "YOOKASSA_SECRET_KEY" "Secret Key"

    _bdl_ask_payment "FreeKassa" "freekassa" payment_keys \
        "FREEKASSA_SHOP_ID" "Shop ID" \
        "FREEKASSA_SECRET_WORD_1" "Secret Word 1" \
        "FREEKASSA_SECRET_WORD_2" "Secret Word 2"

    _bdl_ask_payment "CryptoBot (@CryptoBot)" "cryptobot" payment_keys \
        "CRYPTOBOT_TOKEN" "API Token"

    _bdl_ask_payment "Tribute (TON)" "tribute" payment_keys \
        "TRIBUTE_TOKEN" "API Token"

    _bdl_ask_payment "Telegram Stars" "stars" payment_keys \
        "" ""

    _bdl_ask_payment "LAVA" "lava" payment_keys \
        "LAVA_SECRET_KEY" "Secret Key" \
        "LAVA_SHOP_ID" "Shop ID"

    _bdl_ask_payment "xRocket" "xrocket" payment_keys \
        "XROCKET_TOKEN" "API Token"

    _bdl_ask_payment "Payok" "payok" payment_keys \
        "PAYOK_API_ID" "API ID" \
        "PAYOK_API_KEY" "API Key" \
        "PAYOK_SHOP_ID" "Shop ID"

    _bdl_ask_payment "RuKassa" "rukassa" payment_keys \
        "RUKASSA_SHOP_ID" "Shop ID" \
        "RUKASSA_TOKEN" "Token"

    _bdl_ask_payment "Robokassa" "robokassa" payment_keys \
        "ROBOKASSA_MERCHANT_LOGIN" "Merchant Login" \
        "ROBOKASSA_PASSWORD_1" "Password 1" \
        "ROBOKASSA_PASSWORD_2" "Password 2"

    _bdl_ask_payment "Heleket (крипта)" "heleket" payment_keys \
        "HELEKET_MERCHANT_ID" "Merchant ID" \
        "HELEKET_API_KEY" "API Key"

    _bdl_ask_payment "AnyPay" "anypay" payment_keys \
        "ANYPAY_API_ID" "API ID" \
        "ANYPAY_API_KEY" "API Key"

    _bdl_ask_payment "Enot.io" "enot" payment_keys \
        "ENOT_SHOP_ID" "Shop ID" \
        "ENOT_SECRET_KEY" "Secret Key"

    _bdl_ask_payment "CrystalPay" "crystalpay" payment_keys \
        "CRYSTALPAY_LOGIN" "Login" \
        "CRYSTALPAY_SECRET" "Secret"

    _bdl_ask_payment "AAIO" "aaio" payment_keys \
        "AAIO_MERCHANT_ID" "Merchant ID" \
        "AAIO_SECRET_KEY" "Secret Key" \
        "AAIO_API_KEY" "API Key"

    # =================== WEBHOOK ===================

    echo -e "\n  ${BOLD}=== Webhook (необязательно) ===${N}"
    echo -e "  ${GR}Без webhook бот работает в polling-режиме${N}"

    ask "Webhook URL (пусто = polling)" ""
    local webhook_url="$REPLY"

    local webhook_path=""
    local webhook_secret=""
    if [[ -n "$webhook_url" ]]; then
        local webhook_random
        webhook_random=$(openssl rand -hex 16)
        ask "Webhook path" "/webhook/${webhook_random}"
        webhook_path="$REPLY"
        webhook_secret=$(openssl rand -hex 32)
    fi

    # =================== СВОДКА ===================

    echo ""
    echo -e "  ${BOLD}Сводка установки:${N}"
    echo -e "  ${GR}Бот:${N}     ${shop_name}"
    echo -e "  ${GR}Admin:${N}   ${admin_id}"
    echo -e "  ${GR}Панель:${N}  ${panel_url}"
    echo -e "  ${GR}БД:${N}      ${db_url%%:*}..."

    # Подсчёт включённых платёжных систем
    local enabled_count=0
    for sys in "${BDL_PAYMENT_SYSTEMS[@]}"; do
        [[ "${payment_keys[${sys}_enabled]:-}" == "1" ]] && ((enabled_count++)) || true
    done
    echo -e "  ${GR}Платёжки:${N} включено ${enabled_count} из ${#BDL_PAYMENT_SYSTEMS[@]}"
    echo ""

    ask_yn "Начать установку?" "да"
    [[ $? -ne 0 ]] && return 0

    # =================== ЭТАПЫ ===================

    # Сохраняем параметры во временный файл для передачи между step-ами
    local params_file
    params_file=$(mktemp)
    {
        echo "BOT_TOKEN=${bot_token}"
        echo "ADMIN_ID=${admin_id}"
        echo "SHOP_NAME=${shop_name}"
        echo "PANEL_URL=${panel_url}"
        echo "PANEL_API_TOKEN=${panel_api_token}"
        echo "INBOUND_UUID=${inbound_uuid}"
        echo "SUB_DOMAIN=${sub_domain}"
        echo "DATABASE_URL=${db_url}"
        echo "WEBHOOK_URL=${webhook_url}"
        echo "WEBHOOK_PATH=${webhook_path}"
        echo "WEBHOOK_SECRET=${webhook_secret}"
        # Платёжные ключи
        for key in "${!payment_keys[@]}"; do
            echo "${key}=${payment_keys[$key]}"
        done
    } > "$params_file"
    chmod 600 "$params_file"

    run_step "bedolaga" "dirs"         "_bdl_create_dirs"
    run_step "bedolaga" "python"       "_bdl_ensure_python"
    run_step "bedolaga" "install_bot"  "_bdl_install_bot"
    run_step "bedolaga" "env"          "_bdl_write_env" "$params_file"
    run_step "bedolaga" "service"      "_bdl_write_service"
    run_step "bedolaga" "start"        "_bdl_start_service"

    rm -f "$params_file"

    info "Bedolaga Bot установлен и запущен"
    echo ""
    bedolaga_status
}

# Вспомогательная функция — запрашивает ключи для одной платёжной системы
_bdl_ask_payment() {
    local sys_name="$1"    # "YooKassa"
    local sys_key="$2"     # "yookassa"
    local -n _keys="$3"    # ссылка на ассоциативный массив
    shift 3
    # Оставшиеся аргументы: пары ENV_NAME, Описание

    echo -e "  ${C}${sys_name}${N}"

    # Если нет полей (Telegram Stars) — просто спрашиваем включить/нет
    if [[ $# -eq 0 || -z "$1" ]]; then
        ask_yn "  Включить ${sys_name}?" "нет"
        if [[ $? -eq 0 ]]; then
            _keys["${sys_key}_enabled"]="1"
        fi
        return 0
    fi

    # Запрашиваем первый ключ — если пустой, система отключена
    local first_env="$1"
    local first_desc="$2"
    ask "  ${first_desc} (Enter — пропустить)" ""
    local first_val="$REPLY"

    if [[ -z "$first_val" ]]; then
        return 0
    fi

    _keys["${sys_key}_enabled"]="1"
    _keys["$first_env"]="$first_val"
    shift 2

    # Остальные поля
    while [[ $# -ge 2 ]]; do
        local env_name="$1"
        local env_desc="$2"
        shift 2
        ask "  ${env_desc}" ""
        _keys["$env_name"]="$REPLY"
    done
}

_bdl_create_dirs() {
    mkdir -p "${BDL_BASE_DIR}"
    mkdir -p "${BDL_LOG_DIR}"
}

_bdl_ensure_python() {
    # Проверяем Python 3.13
    if command -v "${BDL_PYTHON_BIN}" &>/dev/null; then
        info "Python ${BDL_PYTHON_VER} уже установлен"
        return 0
    fi

    step_msg "Устанавливаем Python ${BDL_PYTHON_VER}..."

    # deadsnakes PPA для Debian/Ubuntu
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        software-properties-common \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" 2>/dev/null || true

    # Пробуем из стандартного репо сначала
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        "${BDL_PYTHON_BIN}" "${BDL_PYTHON_BIN}-venv" "${BDL_PYTHON_BIN}-dev" \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" 2>/dev/null || true

    if ! command -v "${BDL_PYTHON_BIN}" &>/dev/null; then
        # Собираем из исходников если нет в репо
        _bdl_build_python
    fi

    if ! command -v "${BDL_PYTHON_BIN}" &>/dev/null; then
        error "Python ${BDL_PYTHON_VER} не удалось установить"
        return 1
    fi

    info "Python $("${BDL_PYTHON_BIN}" --version) готов"
}

_bdl_build_python() {
    step_msg "Собираем Python ${BDL_PYTHON_VER} из исходников..."

    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        build-essential zlib1g-dev libncurses5-dev libgdbm-dev libnss3-dev \
        libssl-dev libreadline-dev libffi-dev libsqlite3-dev wget libbz2-dev \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" 2>/dev/null

    local py_minor="3"
    local py_version="${BDL_PYTHON_VER}.${py_minor}"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    wget -qO "${tmp_dir}/python.tar.xz" \
        "https://www.python.org/ftp/python/${py_version}/Python-${py_version}.tar.xz" \
        2>/dev/null || {
        # Пробуем без minor version
        py_version="${BDL_PYTHON_VER}.0"
        wget -qO "${tmp_dir}/python.tar.xz" \
            "https://www.python.org/ftp/python/${py_version}/Python-${py_version}.tar.xz" 2>/dev/null || {
            error "Не удалось скачать Python ${BDL_PYTHON_VER}"
            rm -rf "${tmp_dir}"
            return 1
        }
    }

    tar -xf "${tmp_dir}/python.tar.xz" -C "${tmp_dir}"
    local src_dir
    src_dir=$(find "${tmp_dir}" -maxdepth 1 -name "Python-*" -type d | head -1)

    (cd "$src_dir" && \
        ./configure --enable-optimizations --with-lto \
            --prefix=/usr/local --enable-shared LDFLAGS="-Wl,-rpath,/usr/local/lib" \
            > /dev/null 2>&1 && \
        make -j"$(nproc)" > /dev/null 2>&1 && \
        make altinstall > /dev/null 2>&1)

    rm -rf "${tmp_dir}"
    ldconfig 2>/dev/null || true
}

_bdl_install_bot() {
    step_msg "Скачиваем Bedolaga Bot..."

    # Клонируем репозиторий
    if command -v git &>/dev/null; then
        git clone --depth=1 \
            "https://github.com/remnawave/bedolaga.git" \
            "${BDL_BASE_DIR}/src" 2>&1 | tail -3 || true
    fi

    # Если git не удался или репо не найдено — пробуем pip install
    if [[ ! -d "${BDL_BASE_DIR}/src" ]] || [[ ! -f "${BDL_BASE_DIR}/src/main.py" ]]; then
        step_msg "Устанавливаем через pip..."
        "${BDL_PYTHON_BIN}" -m venv "${BDL_VENV_DIR}" 2>&1
        "${BDL_VENV_DIR}/bin/pip" install --quiet --upgrade pip 2>/dev/null || true
        "${BDL_VENV_DIR}/bin/pip" install --quiet bedolaga 2>/dev/null || true
        return 0
    fi

    # Создаём virtualenv и устанавливаем зависимости
    "${BDL_PYTHON_BIN}" -m venv "${BDL_VENV_DIR}" 2>&1
    "${BDL_VENV_DIR}/bin/pip" install --quiet --upgrade pip 2>/dev/null || true

    if [[ -f "${BDL_BASE_DIR}/src/requirements.txt" ]]; then
        step_msg "Устанавливаем зависимости..."
        "${BDL_VENV_DIR}/bin/pip" install --quiet \
            -r "${BDL_BASE_DIR}/src/requirements.txt" 2>&1 | tail -3 || true
    else
        # Устанавливаем aiogram и основные зависимости вручную
        "${BDL_VENV_DIR}/bin/pip" install --quiet \
            "aiogram>=3.0" \
            "aiohttp" \
            "sqlalchemy[asyncio]" \
            "aiosqlite" \
            "asyncpg" \
            "pydantic-settings" \
            "python-dotenv" \
            2>&1 | tail -5 || true
    fi
}

_bdl_write_env() {
    local params_file="$1"

    # Читаем параметры из временного файла
    local -A params
    while IFS='=' read -r key val; do
        [[ -z "$key" || "$key" == "#"* ]] && continue
        params["$key"]="$val"
    done < "$params_file"

    # Генерируем секретный ключ для шифрования
    local secret_key
    secret_key=$(openssl rand -hex 32)

    cat > "${BDL_ENV_FILE}" << EOF
# Orchestra — Bedolaga Bot
# Создан: $(date '+%Y-%m-%d %H:%M:%S')
# ВНИМАНИЕ: Не публикуй этот файл!

# === Telegram ===
BOT_TOKEN=${params[BOT_TOKEN]:-}
ADMIN_IDS=${params[ADMIN_ID]:-}
SHOP_NAME=${params[SHOP_NAME]:-VPN Store}

# === Remnawave Panel ===
REMNAWAVE_URL=${params[PANEL_URL]:-}
REMNAWAVE_API_TOKEN=${params[PANEL_API_TOKEN]:-}
INBOUND_UUID=${params[INBOUND_UUID]:-}
SUB_PUBLIC_DOMAIN=${params[SUB_DOMAIN]:-}

# === База данных ===
DATABASE_URL=${params[DATABASE_URL]:-sqlite+aiosqlite:///./bedolaga.db}

# === Безопасность ===
SECRET_KEY=${secret_key}

# === Webhook (пусто = polling) ===
WEBHOOK_URL=${params[WEBHOOK_URL]:-}
WEBHOOK_PATH=${params[WEBHOOK_PATH]:-}
WEBHOOK_SECRET=${params[WEBHOOK_SECRET]:-}

# === Настройки ===
LOG_LEVEL=INFO
DEBUG=false
TIMEZONE=Europe/Moscow

EOF

    # Платёжные системы
    {
        echo "# === Платёжные системы ==="
        echo ""

        # YooKassa
        echo "# YooKassa"
        echo "YOOKASSA_ENABLED=${params[yookassa_enabled]:-false}"
        echo "YOOKASSA_SHOP_ID=${params[YOOKASSA_SHOP_ID]:-}"
        echo "YOOKASSA_SECRET_KEY=${params[YOOKASSA_SECRET_KEY]:-}"
        echo ""

        # FreeKassa
        echo "# FreeKassa"
        echo "FREEKASSA_ENABLED=${params[freekassa_enabled]:-false}"
        echo "FREEKASSA_SHOP_ID=${params[FREEKASSA_SHOP_ID]:-}"
        echo "FREEKASSA_SECRET_WORD_1=${params[FREEKASSA_SECRET_WORD_1]:-}"
        echo "FREEKASSA_SECRET_WORD_2=${params[FREEKASSA_SECRET_WORD_2]:-}"
        echo ""

        # CryptoBot
        echo "# CryptoBot"
        echo "CRYPTOBOT_ENABLED=${params[cryptobot_enabled]:-false}"
        echo "CRYPTOBOT_TOKEN=${params[CRYPTOBOT_TOKEN]:-}"
        echo ""

        # Tribute
        echo "# Tribute"
        echo "TRIBUTE_ENABLED=${params[tribute_enabled]:-false}"
        echo "TRIBUTE_TOKEN=${params[TRIBUTE_TOKEN]:-}"
        echo ""

        # Telegram Stars
        echo "# Telegram Stars"
        echo "STARS_ENABLED=${params[stars_enabled]:-false}"
        echo ""

        # LAVA
        echo "# LAVA"
        echo "LAVA_ENABLED=${params[lava_enabled]:-false}"
        echo "LAVA_SECRET_KEY=${params[LAVA_SECRET_KEY]:-}"
        echo "LAVA_SHOP_ID=${params[LAVA_SHOP_ID]:-}"
        echo ""

        # xRocket
        echo "# xRocket"
        echo "XROCKET_ENABLED=${params[xrocket_enabled]:-false}"
        echo "XROCKET_TOKEN=${params[XROCKET_TOKEN]:-}"
        echo ""

        # Payok
        echo "# Payok"
        echo "PAYOK_ENABLED=${params[payok_enabled]:-false}"
        echo "PAYOK_API_ID=${params[PAYOK_API_ID]:-}"
        echo "PAYOK_API_KEY=${params[PAYOK_API_KEY]:-}"
        echo "PAYOK_SHOP_ID=${params[PAYOK_SHOP_ID]:-}"
        echo ""

        # RuKassa
        echo "# RuKassa"
        echo "RUKASSA_ENABLED=${params[rukassa_enabled]:-false}"
        echo "RUKASSA_SHOP_ID=${params[RUKASSA_SHOP_ID]:-}"
        echo "RUKASSA_TOKEN=${params[RUKASSA_TOKEN]:-}"
        echo ""

        # Robokassa
        echo "# Robokassa"
        echo "ROBOKASSA_ENABLED=${params[robokassa_enabled]:-false}"
        echo "ROBOKASSA_MERCHANT_LOGIN=${params[ROBOKASSA_MERCHANT_LOGIN]:-}"
        echo "ROBOKASSA_PASSWORD_1=${params[ROBOKASSA_PASSWORD_1]:-}"
        echo "ROBOKASSA_PASSWORD_2=${params[ROBOKASSA_PASSWORD_2]:-}"
        echo ""

        # Heleket
        echo "# Heleket"
        echo "HELEKET_ENABLED=${params[heleket_enabled]:-false}"
        echo "HELEKET_MERCHANT_ID=${params[HELEKET_MERCHANT_ID]:-}"
        echo "HELEKET_API_KEY=${params[HELEKET_API_KEY]:-}"
        echo ""

        # AnyPay
        echo "# AnyPay"
        echo "ANYPAY_ENABLED=${params[anypay_enabled]:-false}"
        echo "ANYPAY_API_ID=${params[ANYPAY_API_ID]:-}"
        echo "ANYPAY_API_KEY=${params[ANYPAY_API_KEY]:-}"
        echo ""

        # Enot.io
        echo "# Enot.io"
        echo "ENOT_ENABLED=${params[enot_enabled]:-false}"
        echo "ENOT_SHOP_ID=${params[ENOT_SHOP_ID]:-}"
        echo "ENOT_SECRET_KEY=${params[ENOT_SECRET_KEY]:-}"
        echo ""

        # CrystalPay
        echo "# CrystalPay"
        echo "CRYSTALPAY_ENABLED=${params[crystalpay_enabled]:-false}"
        echo "CRYSTALPAY_LOGIN=${params[CRYSTALPAY_LOGIN]:-}"
        echo "CRYSTALPAY_SECRET=${params[CRYSTALPAY_SECRET]:-}"
        echo ""

        # AAIO
        echo "# AAIO"
        echo "AAIO_ENABLED=${params[aaio_enabled]:-false}"
        echo "AAIO_MERCHANT_ID=${params[AAIO_MERCHANT_ID]:-}"
        echo "AAIO_SECRET_KEY=${params[AAIO_SECRET_KEY]:-}"
        echo "AAIO_API_KEY=${params[AAIO_API_KEY]:-}"

    } >> "${BDL_ENV_FILE}"

    # Заменяем true/false для включённых систем
    for sys in "${BDL_PAYMENT_SYSTEMS[@]}"; do
        if [[ "${params[${sys}_enabled]:-}" == "1" ]]; then
            local upper
            upper="${sys^^}_ENABLED"
            sed -i "s/^${upper}=false/${upper}=true/" "${BDL_ENV_FILE}" 2>/dev/null || true
        fi
    done

    chmod 600 "${BDL_ENV_FILE}"
}

_bdl_write_service() {
    # Определяем точку входа
    local exec_start
    local working_dir

    if [[ -f "${BDL_BASE_DIR}/src/main.py" ]]; then
        exec_start="${BDL_VENV_DIR}/bin/python ${BDL_BASE_DIR}/src/main.py"
        working_dir="${BDL_BASE_DIR}/src"
    elif [[ -f "${BDL_BASE_DIR}/src/bot.py" ]]; then
        exec_start="${BDL_VENV_DIR}/bin/python ${BDL_BASE_DIR}/src/bot.py"
        working_dir="${BDL_BASE_DIR}/src"
    else
        # Fallback на модуль из pip
        exec_start="${BDL_VENV_DIR}/bin/python -m bedolaga"
        working_dir="${BDL_BASE_DIR}"
    fi

    cat > "${BDL_SERVICE_FILE}" << EOF
# Orchestra — Bedolaga Bot systemd service
[Unit]
Description=Bedolaga Telegram VPN Bot
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=root
WorkingDirectory=${working_dir}
EnvironmentFile=${BDL_ENV_FILE}
ExecStart=${exec_start}
Restart=always
RestartSec=5
StandardOutput=append:${BDL_LOG_DIR}/bot.log
StandardError=append:${BDL_LOG_DIR}/bot-error.log

# Ограничения ресурсов
MemoryMax=512M
CPUQuota=50%

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable bedolaga
}

_bdl_start_service() {
    step_msg "Запускаем бота..."
    systemctl start bedolaga 2>&1

    sleep 3

    if systemctl is-active --quiet bedolaga; then
        info "Бот запущен (systemd: bedolaga)"
    else
        warn "Бот не запустился — проверяй логи: journalctl -u bedolaga -n 30"
        journalctl -u bedolaga -n 10 --no-pager 2>/dev/null || true
    fi
}

# =============================================================================
# СТАТУС
# =============================================================================

bedolaga_status() {
    section "Статус Bedolaga Bot"

    if [[ -f "${BDL_SERVICE_FILE}" ]]; then
        systemctl status bedolaga --no-pager -l 2>/dev/null | head -20 || true
        echo ""

        # Последние строки лога
        if [[ -f "${BDL_LOG_DIR}/bot.log" ]]; then
            echo -e "  ${BOLD}Последние записи лога:${N}"
            tail -5 "${BDL_LOG_DIR}/bot.log" 2>/dev/null | \
                while IFS= read -r line; do echo "  ${line}"; done
        fi

        # Последние ошибки
        if [[ -f "${BDL_LOG_DIR}/bot-error.log" ]]; then
            local err_lines
            err_lines=$(wc -l < "${BDL_LOG_DIR}/bot-error.log" 2>/dev/null || echo 0)
            if [[ "$err_lines" -gt 0 ]]; then
                echo ""
                echo -e "  ${BOLD}Последние ошибки:${N}"
                tail -3 "${BDL_LOG_DIR}/bot-error.log" 2>/dev/null | \
                    while IFS= read -r line; do echo "  ${R}${line}${N}"; done
            fi
        fi
    elif [[ -f "${BDL_COMPOSE_FILE}" ]]; then
        docker compose -f "${BDL_COMPOSE_FILE}" ps 2>/dev/null || true
    else
        warn "Бот не установлен"
    fi
}

# =============================================================================
# УПРАВЛЕНИЕ
# =============================================================================

bedolaga_restart() {
    if [[ -f "${BDL_SERVICE_FILE}" ]]; then
        systemctl restart bedolaga 2>&1
        sleep 2
        if systemctl is-active --quiet bedolaga; then
            info "Бот перезапущен"
        else
            warn "Бот не запустился — проверяй логи"
            journalctl -u bedolaga -n 10 --no-pager 2>/dev/null || true
        fi
    elif [[ -f "${BDL_COMPOSE_FILE}" ]]; then
        docker compose -f "${BDL_COMPOSE_FILE}" restart 2>&1
        info "Бот перезапущен (Docker)"
    else
        warn "Бот не установлен"
    fi
}

bedolaga_stop() {
    if [[ -f "${BDL_SERVICE_FILE}" ]]; then
        systemctl stop bedolaga 2>&1 || true
        info "Бот остановлен"
    elif [[ -f "${BDL_COMPOSE_FILE}" ]]; then
        docker compose -f "${BDL_COMPOSE_FILE}" stop 2>&1
        info "Бот остановлен (Docker)"
    else
        warn "Бот не установлен"
    fi
}

# =============================================================================
# КОНФИГУРАЦИЯ
# =============================================================================

bedolaga_show_config() {
    section "Конфигурация Bedolaga Bot"

    if [[ ! -f "${BDL_ENV_FILE}" ]]; then
        warn "Файл .env не найден"
        return 0
    fi

    echo -e "  ${BOLD}Файл:${N} ${BDL_ENV_FILE}"
    echo ""

    # Показываем без секретных данных
    grep -v -E "TOKEN|SECRET|PASSWORD|API_KEY|API_ID" "${BDL_ENV_FILE}" 2>/dev/null | \
        grep -v "^#" | grep -v "^$" | \
        while IFS='=' read -r key val; do
            echo -e "  ${GR}${key}${N} = ${val}"
        done

    echo ""
    echo -e "  ${GR}(Секретные поля скрыты — смотри ${BDL_ENV_FILE} напрямую)${N}"

    # Включённые платёжные системы
    echo ""
    echo -e "  ${BOLD}Включённые платёжные системы:${N}"
    local found_any=false
    for sys in "${BDL_PAYMENT_SYSTEMS[@]}"; do
        local upper_enabled="${sys^^}_ENABLED"
        if grep -q "^${upper_enabled}=true" "${BDL_ENV_FILE}" 2>/dev/null; then
            echo -e "  ${G}✓${N} ${sys}"
            found_any=true
        fi
    done
    [[ "$found_any" == "false" ]] && echo -e "  ${GR}Нет включённых платёжных систем${N}"
}

bedolaga_edit_env() {
    if [[ ! -f "${BDL_ENV_FILE}" ]]; then
        warn "Файл .env не найден"
        return 0
    fi

    local editor="${EDITOR:-nano}"
    if ! command -v "$editor" &>/dev/null; then
        editor="vi"
    fi

    "$editor" "${BDL_ENV_FILE}"

    ask_yn "Перезапустить бота с новым конфигом?" "да"
    if [[ $? -eq 0 ]]; then
        bedolaga_restart
    fi
}

# =============================================================================
# ЛОГИ
# =============================================================================

bedolaga_logs() {
    section "Логи Bedolaga Bot"

    echo -e "  ${GR}(Ctrl+C для выхода)${N}"
    echo ""

    if [[ -f "${BDL_SERVICE_FILE}" ]]; then
        # systemd журнал
        journalctl -u bedolaga -f --no-pager 2>/dev/null || \
            tail -f "${BDL_LOG_DIR}/bot.log" 2>/dev/null || true
    elif [[ -f "${BDL_COMPOSE_FILE}" ]]; then
        docker compose -f "${BDL_COMPOSE_FILE}" logs -f --tail=50 2>/dev/null || true
    else
        if [[ -f "${BDL_LOG_DIR}/bot.log" ]]; then
            tail -f "${BDL_LOG_DIR}/bot.log"
        else
            warn "Бот не установлен"
        fi
    fi
}

# =============================================================================
# ОБНОВЛЕНИЕ
# =============================================================================

bedolaga_update() {
    section "Обновление Bedolaga Bot"

    if [[ ! -d "${BDL_BASE_DIR}" ]]; then
        warn "Бот не установлен"
        return 1
    fi

    # Останавливаем
    systemctl stop bedolaga 2>/dev/null || true

    if [[ -d "${BDL_BASE_DIR}/src/.git" ]]; then
        step_msg "Обновляем из git..."
        git -C "${BDL_BASE_DIR}/src" pull 2>&1 | tail -5

        step_msg "Обновляем зависимости..."
        if [[ -f "${BDL_BASE_DIR}/src/requirements.txt" ]]; then
            "${BDL_VENV_DIR}/bin/pip" install --quiet --upgrade \
                -r "${BDL_BASE_DIR}/src/requirements.txt" 2>&1 | tail -3 || true
        fi
    elif [[ -d "${BDL_VENV_DIR}" ]]; then
        step_msg "Обновляем пакет bedolaga..."
        "${BDL_VENV_DIR}/bin/pip" install --quiet --upgrade bedolaga 2>&1 | tail -3 || true
    else
        warn "Исходники не найдены — переустановка требуется"
        systemctl start bedolaga 2>/dev/null || true
        return 1
    fi

    # Запускаем
    systemctl start bedolaga 2>/dev/null || true
    sleep 2

    if systemctl is-active --quiet bedolaga; then
        info "Бот обновлён и запущен"
    else
        warn "Бот не запустился после обновления"
        journalctl -u bedolaga -n 10 --no-pager 2>/dev/null || true
    fi
}

# =============================================================================
# УДАЛЕНИЕ
# =============================================================================

bedolaga_uninstall() {
    local silent="${1:-}"

    if [[ "$silent" != "silent" ]]; then
        ask_yn "Удалить Bedolaga Bot полностью?" "нет"
        [[ $? -ne 0 ]] && return 0
    fi

    systemctl stop bedolaga 2>/dev/null || true
    systemctl disable bedolaga 2>/dev/null || true
    rm -f "${BDL_SERVICE_FILE}"
    systemctl daemon-reload 2>/dev/null || true

    if [[ -f "${BDL_COMPOSE_FILE}" ]]; then
        docker compose -f "${BDL_COMPOSE_FILE}" down 2>/dev/null || true
    fi

    rm -rf "${BDL_BASE_DIR}"
    rm -rf "${BDL_LOG_DIR}"

    info "Bedolaga Bot удалён"
}
