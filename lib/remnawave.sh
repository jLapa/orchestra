#!/usr/bin/env bash
# =============================================================================
# remnawave.sh — Remnawave Panel + Node управление
# Модуль Orchestra | Этап 5
# =============================================================================
set -euo pipefail

[[ -n "${REMNAWAVE_MODULE_LOADED:-}" ]] && return 0
readonly REMNAWAVE_MODULE_LOADED=1

# =============================================================================
# КОНСТАНТЫ
# =============================================================================

readonly RW_BASE_DIR="/opt/remnawave"
readonly RW_PANEL_DIR="${RW_BASE_DIR}/panel"
readonly RW_NODE_DIR="${RW_BASE_DIR}/node"
readonly RW_ENV_FILE="${RW_PANEL_DIR}/.env"
readonly RW_NODE_ENV_FILE="${RW_NODE_DIR}/.env"
readonly RW_COMPOSE_PANEL="${RW_PANEL_DIR}/docker-compose.yml"
readonly RW_COMPOSE_NODE="${RW_NODE_DIR}/docker-compose.yml"

# Docker образы
readonly RW_PANEL_IMAGE="ghcr.io/remnawave/backend:latest"
readonly RW_NODE_IMAGE="ghcr.io/remnawave/node:latest"
readonly RW_POSTGRES_IMAGE="postgres:17-alpine"
readonly RW_VALKEY_IMAGE="valkey/valkey:8-alpine"

# Порты
readonly RW_PANEL_PORT="3000"
readonly RW_PANEL_METRICS_PORT="3001"
readonly RW_NODE_PORT="2095"

# =============================================================================
# ФУНКЦИИ-ЗАГЛУШКИ (на случай, если main orchestra.sh не загружен)
# =============================================================================

# validate_port — если не определена в orchestra.sh, определяем здесь
if ! declare -f validate_port >/dev/null 2>&1; then
    validate_port() {
        local port="${1}"
        local check_occupied="${2:-false}"
        
        [[ -z "$port" ]] && { echo "ERROR: Порт не указан" >&2; return 1; }
        
        if ! [[ "$port" =~ ^[0-9]+$ ]]; then
            echo "ERROR: Порт '$port' не является числом" >&2
            return 1
        fi
        
        if [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
            echo "ERROR: Порт '$port' вне допустимого диапазона (1-65535)" >&2
            return 1
        fi
        
        return 0
    }
fi

# =============================================================================
# МЕНЮ МОДУЛЯ
# =============================================================================

remnawave_menu() {
    clear
    section "remnawave — Panel + Node"

    _rw_show_status_brief

    echo ""
    echo -e "  ${BOLD}Панель (Panel):${N}"
    echo -e "  ${C}1${N}) Установить панель"
    echo -e "  ${C}2${N}) Статус панели"
    echo -e "  ${C}3${N}) Перезапустить панель"
    echo -e "  ${C}4${N}) Показать URL и логин"
    echo -e "  ${C}5${N}) Обновить панель"
    echo ""
    echo -e "  ${BOLD}Нода (Node):${N}"
    echo -e "  ${C}6${N}) Установить ноду"
    echo -e "  ${C}7${N}) Статус ноды"
    echo -e "  ${C}8${N}) Перезапустить ноду"
    echo -e "  ${C}9${N}) Обновить ноду"
    echo ""
    echo -e "  ${BOLD}Обслуживание:${N}"
    echo -e "  ${C}10${N}) Показать логи панели"
    echo -e "  ${C}11${N}) Показать логи ноды"
    echo -e "  ${C}12${N}) Удалить панель"
    echo -e "  ${C}13${N}) Удалить ноду"
    echo -e "  ${C}0${N}) Назад"
    echo ""

    ask "Выбор" "1"
    case "$REPLY" in
        1)  remnawave_install_panel ;;
        2)  remnawave_status_panel ;;
        3)  remnawave_restart_panel ;;
        4)  remnawave_show_access ;;
        5)  remnawave_update_panel ;;
        6)  remnawave_install_node ;;
        7)  remnawave_status_node ;;
        8)  remnawave_restart_node ;;
        9)  remnawave_update_node ;;
        10) remnawave_logs_panel ;;
        11) remnawave_logs_node ;;
        12) remnawave_uninstall_panel ;;
        13) remnawave_uninstall_node ;;
        0)  return 0 ;;
        *)  warn "Неверный выбор" ;;
    esac
}

_rw_show_status_brief() {
    local panel_ok="  ${GR}●${N} Панель: не установлена"
    local node_ok="  ${GR}●${N} Нода:   не установлена"

    if [[ -f "${RW_COMPOSE_PANEL}" ]]; then
        if docker compose -f "${RW_COMPOSE_PANEL}" ps 2>/dev/null | grep -q "Up"; then
            panel_ok="  ${G}●${N} Панель: запущена"
        else
            panel_ok="  ${R}●${N} Панель: остановлена"
        fi
    fi

    if [[ -f "${RW_COMPOSE_NODE}" ]]; then
        if docker compose -f "${RW_COMPOSE_NODE}" ps 2>/dev/null | grep -q "Up"; then
            node_ok="  ${G}●${N} Нода:   запущена"
        else
            node_ok="  ${R}●${N} Нода:   остановлена"
        fi
    fi

    echo -e "$panel_ok"
    echo -e "$node_ok"
}

# =============================================================================
# УСТАНОВКА ПАНЕЛИ
# =============================================================================

remnawave_install_panel() {
    section "Установка Remnawave Panel"

    if [[ -f "${RW_COMPOSE_PANEL}" ]]; then
        warn "Панель уже установлена в ${RW_PANEL_DIR}"
        ask_yn "Переустановить?" "нет"
        [[ $? -ne 0 ]] && return 0
        remnawave_uninstall_panel silent
    fi

    hint "Remnawave Panel" \
        "Docker-стек: PostgreSQL 17 + Valkey (Redis-совместимый) + Backend" \
        "Панель управления VPN-сервисом с веб-интерфейсом и REST API" \
        "После установки потребуется настроить домен через nginx/proxy"

    # --- сбор параметров ---
    ask "Домен для панели (например: panel.example.com)" ""
    local panel_domain="$REPLY"
    [[ -z "$panel_domain" ]] && { warn "Домен не введён"; return 1; }
    validate_domain "$panel_domain" "required" "false" || return 1

    ask "Домен для SUB подписок (например: sub.example.com)" ""
    local sub_domain="$REPLY"
    [[ -z "$sub_domain" ]] && { warn "SUB-домен не введён"; return 1; }
    validate_domain "$sub_domain" "required" "true" || return 1
    # SUB-домен может быть за CF Proxy — предупреждение не критично

    ask "Порт панели" "${RW_PANEL_PORT}"
    local panel_port="$REPLY"
    validate_port "$panel_port" || return 1

    ask "Логин администратора" "admin"
    local admin_user="$REPLY"
    [[ -z "$admin_user" ]] && { warn "Логин не может быть пустым"; return 1; }

    local admin_pass
    admin_pass=$(openssl rand -hex 12)
    ask "Пароль администратора (Enter — сгенерировать: ${admin_pass})" "$admin_pass"
    [[ -n "$REPLY" ]] && admin_pass="$REPLY"

    # --- параметры БД ---
    local db_pass
    db_pass=$(openssl rand -hex 16)

    local jwt_auth_secret
    jwt_auth_secret=$(openssl rand -hex 32)

    local jwt_api_secret
    jwt_api_secret=$(openssl rand -hex 32)

    local metrics_user="prometheus"
    local metrics_pass
    metrics_pass=$(openssl rand -hex 12)

    local superadmin_pass
    superadmin_pass=$(openssl rand -hex 16)

    # --- сводка ---
    echo ""
    echo -e "  ${BOLD}Параметры установки:${N}"
    echo -e "  ${GR}Панель:${N}    https://${panel_domain}"
    echo -e "  ${GR}Подписки:${N}  https://${sub_domain}"
    echo -e "  ${GR}Порт:${N}      ${panel_port}"
    echo -e "  ${GR}Логин:${N}     ${admin_user}"
    echo -e "  ${GR}Пароль:${N}    ${admin_pass}"
    echo ""

    ask_yn "Начать установку?" "да"
    [[ $? -ne 0 ]] && return 0

    # --- этапы ---
    local -A RW_PARAMS=(
        [PANEL_DOMAIN]="$panel_domain"
        [SUB_DOMAIN]="$sub_domain"
        [PANEL_PORT]="$panel_port"
        [ADMIN_USER]="$admin_user"
        [ADMIN_PASS]="$admin_pass"
        [DB_PASS]="$db_pass"
        [JWT_AUTH_SECRET]="$jwt_auth_secret"
        [JWT_API_SECRET]="$jwt_api_secret"
        [METRICS_USER]="$metrics_user"
        [METRICS_PASS]="$metrics_pass"
        [SUPERADMIN_PASS]="$superadmin_pass"
    )

    run_step "rw_panel" "docker_install"      "_rw_ensure_docker"
    run_step "rw_panel" "dirs"                "_rw_panel_create_dirs"
    run_step "rw_panel" "env"                 "_rw_panel_write_env" \
        "$panel_domain" "$sub_domain" "$panel_port" \
        "$db_pass" "$jwt_auth_secret" "$jwt_api_secret" \
        "$metrics_user" "$metrics_pass" "$superadmin_pass"
    run_step "rw_panel" "compose"             "_rw_panel_write_compose" "$panel_port"
    run_step "rw_panel" "pull"                "_rw_panel_pull"
    run_step "rw_panel" "start"               "_rw_panel_start"
    run_step "rw_panel" "wait_healthy"        "_rw_panel_wait_healthy" "$panel_port"
    run_step "rw_panel" "create_admin"        "_rw_panel_create_admin" "$panel_port" "$admin_user" "$admin_pass"

    info "Remnawave Panel установлена"
    echo ""
    remnawave_show_access
}

_rw_ensure_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
        return 0
    fi
    step_msg "Устанавливаем Docker..."
    curl -4fsSL https://get.docker.com | bash 2>&1 | tail -5
    systemctl enable docker
    systemctl start docker
    # docker compose plugin
    if ! docker compose version &>/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-plugin \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" 2>/dev/null || true
    fi
}

_rw_panel_create_dirs() {
    mkdir -p "${RW_PANEL_DIR}"
    mkdir -p "${RW_PANEL_DIR}/db-data"
    mkdir -p "${RW_PANEL_DIR}/valkey-data"
}

_rw_panel_write_env() {
    local panel_domain="$1"
    local sub_domain="$2"
    local panel_port="$3"
    local db_pass="$4"
    local jwt_auth_secret="$5"
    local jwt_api_secret="$6"
    local metrics_user="$7"
    local metrics_pass="$8"
    local superadmin_pass="$9"

    cat > "${RW_ENV_FILE}" << EOF
# Orchestra — Remnawave Panel
# Создан: $(date '+%Y-%m-%d %H:%M:%S')
# Не редактируй JWT секреты после запуска!

# === Домены ===
APP_HOST=0.0.0.0
APP_PORT=${panel_port}
METRICS_PORT=${RW_PANEL_METRICS_PORT}
PUBLIC_DOMAIN=https://${panel_domain}
SUB_PUBLIC_DOMAIN=https://${sub_domain}

# === База данных ===
DATABASE_URL=postgresql://remnawave:${db_pass}@remnawave-db:5432/remnawave
POSTGRES_USER=remnawave
POSTGRES_PASSWORD=${db_pass}
POSTGRES_DB=remnawave

# === Valkey (Redis) ===
REDIS_HOST=remnawave-valkey
REDIS_PORT=6379

# === JWT ===
JWT_AUTH_SECRET=${jwt_auth_secret}
JWT_API_TOKENS_SECRET=${jwt_api_secret}

# === Метрики ===
METRICS_USER=${metrics_user}
METRICS_PASS=${metrics_pass}
IS_METRICS_ENABLED=true

# === Суперадмин (первый запуск) ===
SUPERADMIN_PASSWORD=${superadmin_pass}

# === Настройки ===
NODE_ENV=production
IS_DOCS_ENABLED=false
EXPIRED_USER_DELETION_ENABLED=false
LOG_LEVEL=info
EOF

    chmod 600 "${RW_ENV_FILE}"
}

_rw_panel_write_compose() {
    local panel_port="$1"

    cat > "${RW_COMPOSE_PANEL}" << 'COMPEOF'
# Orchestra — Remnawave Panel docker-compose
version: "3.8"

networks:
  remnawave-net:
    name: remnawave-net
    driver: bridge

volumes:
  db-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ./db-data
  valkey-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ./valkey-data

services:
  remnawave-db:
    image: postgres:17-alpine
    container_name: remnawave-db
    hostname: remnawave-db
    restart: always
    env_file: .env
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
    volumes:
      - db-data:/var/lib/postgresql/data
    networks:
      - remnawave-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

  remnawave-valkey:
    image: valkey/valkey:8-alpine
    container_name: remnawave-valkey
    hostname: remnawave-valkey
    restart: always
    volumes:
      - valkey-data:/data
    networks:
      - remnawave-net
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  remnawave:
    image: ghcr.io/remnawave/backend:latest
    container_name: remnawave
    hostname: remnawave
    restart: always
    env_file: .env
    ports:
      - "127.0.0.1:${APP_PORT}:${APP_PORT}"
      - "127.0.0.1:${METRICS_PORT}:${METRICS_PORT}"
    networks:
      - remnawave-net
    depends_on:
      remnawave-db:
        condition: service_healthy
      remnawave-valkey:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:${APP_PORT}/api/health || exit 1"]
      interval: 15s
      timeout: 10s
      retries: 5
      start_period: 60s
COMPEOF
}

_rw_panel_pull() {
    step_msg "Скачиваем Docker образы..."
    docker compose -f "${RW_COMPOSE_PANEL}" pull 2>&1 | grep -E "Pulling|Pull complete|already" | head -20 || true
}

_rw_panel_start() {
    step_msg "Запускаем панель..."
    docker compose -f "${RW_COMPOSE_PANEL}" up -d 2>&1
}

_rw_panel_wait_healthy() {
    local panel_port="$1"
    local waited=0
    local max=120

    step_msg "Ожидаем готовности панели (до ${max}с)..."

    while [[ $waited -lt $max ]]; do
        if curl -4s --max-time 3 "http://127.0.0.1:${panel_port}/api/health" 2>/dev/null \
                | grep -q "ok\|healthy\|up"; then
            info "Панель отвечает"
            return 0
        fi
        sleep 5
        ((waited+=5)) || true
        echo -n "."
    done
    echo ""

    # Проверяем логи на предмет ошибок
    warn "Панель не ответила за ${max}с, проверяю логи..."
    docker compose -f "${RW_COMPOSE_PANEL}" logs --tail=20 remnawave 2>/dev/null || true
    # Не fail — панель может просто медленно стартовать
    return 0
}

_rw_panel_create_admin() {
    local panel_port="$1"
    local admin_user="$2"
    local admin_pass="$3"
    local waited=0

    step_msg "Создаём учётную запись администратора..."

    # Ждём API
    while [[ $waited -lt 60 ]]; do
        local response
        response=$(curl -4s --max-time 5 \
            -X POST "http://127.0.0.1:${panel_port}/api/auth/register" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"${admin_user}\",\"password\":\"${admin_pass}\"}" \
            2>/dev/null || echo "")

        if echo "$response" | grep -q "token\|success\|created\|already"; then
            info "Администратор создан: ${admin_user}"
            return 0
        fi

        if echo "$response" | grep -qi "exists\|conflict"; then
            info "Администратор уже существует: ${admin_user}"
            return 0
        fi

        sleep 5
        ((waited+=5)) || true
    done

    # Не критично — пользователь может создать через SUPERADMIN_PASSWORD
    warn "Не удалось создать admin через API — используй SUPERADMIN_PASSWORD из .env"
    return 0
}

# =============================================================================
# УСТАНОВКА НОДЫ
# =============================================================================

remnawave_install_node() {
    section "Установка Remnawave Node"

    if [[ -f "${RW_COMPOSE_NODE}" ]]; then
        warn "Нода уже установлена в ${RW_NODE_DIR}"
        ask_yn "Переустановить?" "нет"
        [[ $? -ne 0 ]] && return 0
        remnawave_uninstall_node silent
    fi

    hint "Remnawave Node" \
        "Docker-контейнер: Remnawave Node (Xray-based)" \
        "SECRET_KEY получается из панели — Nodes → Add Node" \
        "Нода может быть на этом же сервере или на отдельном"

    ask "SECRET_KEY из панели (Nodes → Add Node → Copy secret)" ""
    local node_secret="$REPLY"
    [[ -z "$node_secret" ]] && { warn "SECRET_KEY не введён"; return 1; }

    ask "Домен/IP панели для подключения ноды" ""
    local panel_addr="$REPLY"
    [[ -z "$panel_addr" ]] && { warn "Адрес панели не введён"; return 1; }

    ask "Порт API панели" "${RW_PANEL_PORT}"
    local panel_api_port="$REPLY"
    validate_port "$panel_api_port" || return 1

    ask "Порт ноды (GRPC входящий)" "${RW_NODE_PORT}"
    local node_port="$REPLY"
    validate_port "$node_port" || return 1

    ask "Порт Xray на ноде (VLESS Reality)" "443"
    local xray_port="$REPLY"
    validate_port "$xray_port" || return 1

    echo ""
    echo -e "  ${BOLD}Параметры ноды:${N}"
    echo -e "  ${GR}Панель:${N}   ${panel_addr}:${panel_api_port}"
    echo -e "  ${GR}Нода:${N}     0.0.0.0:${node_port} (GRPC)"
    echo -e "  ${GR}Xray:${N}     0.0.0.0:${xray_port}"
    echo ""

    ask_yn "Начать установку?" "да"
    [[ $? -ne 0 ]] && return 0

    run_step "rw_node" "docker_install"  "_rw_ensure_docker"
    run_step "rw_node" "dirs"            "_rw_node_create_dirs"
    run_step "rw_node" "env"             "_rw_node_write_env" \
        "$node_secret" "$panel_addr" "$panel_api_port" "$node_port" "$xray_port"
    run_step "rw_node" "compose"         "_rw_node_write_compose" "$node_port" "$xray_port"
    run_step "rw_node" "pull"            "_rw_node_pull"
    run_step "rw_node" "start"           "_rw_node_start"
    run_step "rw_node" "wait_healthy"    "_rw_node_wait_healthy" "$node_port"
    run_step "rw_node" "firewall"        "_rw_node_open_firewall" "$node_port" "$xray_port"

    info "Remnawave Node установлена"
    echo ""
    echo -e "  ${G}✓${N} Нода запущена на порту ${node_port} (GRPC)"
    echo -e "  ${G}✓${N} Добавь в панели: ${panel_addr} → Nodes → укажи адрес этого сервера"
}

_rw_node_create_dirs() {
    mkdir -p "${RW_NODE_DIR}"
    mkdir -p "${RW_NODE_DIR}/logs"
}

_rw_node_write_env() {
    local node_secret="$1"
    local panel_addr="$2"
    local panel_api_port="$3"
    local node_port="$4"
    local xray_port="$5"

    cat > "${RW_NODE_ENV_FILE}" << EOF
# Orchestra — Remnawave Node
# Создан: $(date '+%Y-%m-%d %H:%M:%S')

# === Подключение к панели ===
APP_TLS_MODE=none
REMNAWAVE_PANEL_URL=http://${panel_addr}:${panel_api_port}
SECRET_KEY=${node_secret}

# === Порты ноды ===
NODE_HOST=0.0.0.0
NODE_PORT=${node_port}

# === Xray ===
XRAY_PORT=${xray_port}

# === Логи ===
LOG_LEVEL=info
EOF

    chmod 600 "${RW_NODE_ENV_FILE}"
}

_rw_node_write_compose() {
    local node_port="$1"
    local xray_port="$2"

    cat > "${RW_COMPOSE_NODE}" << COMPEOF
# Orchestra — Remnawave Node docker-compose
version: "3.8"

networks:
  remnawave-node-net:
    name: remnawave-node-net
    driver: bridge

services:
  remnawave-node:
    image: ghcr.io/remnawave/node:latest
    container_name: remnawave-node
    hostname: remnawave-node
    restart: always
    env_file: .env
    ports:
      - "0.0.0.0:${node_port}:${node_port}"
      - "0.0.0.0:${xray_port}:${xray_port}"
    volumes:
      - ./logs:/var/log/remnawave-node
    networks:
      - remnawave-node-net
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:${node_port}/health 2>/dev/null || exit 1"]
      interval: 15s
      timeout: 10s
      retries: 5
      start_period: 30s
COMPEOF
}

_rw_node_pull() {
    step_msg "Скачиваем образ ноды..."
    docker compose -f "${RW_COMPOSE_NODE}" pull 2>&1 | grep -E "Pulling|Pull complete|already" | head -10 || true
}

_rw_node_start() {
    step_msg "Запускаем ноду..."
    docker compose -f "${RW_COMPOSE_NODE}" up -d 2>&1
}

_rw_node_wait_healthy() {
    local node_port="$1"
    local waited=0
    local max=60

    step_msg "Ожидаем готовности ноды (до ${max}с)..."

    while [[ $waited -lt $max ]]; do
        if curl -4s --max-time 3 "http://127.0.0.1:${node_port}/health" 2>/dev/null \
                | grep -q "ok\|healthy\|up"; then
            info "Нода отвечает"
            return 0
        fi
        sleep 5
        ((waited+=5)) || true
        echo -n "."
    done
    echo ""
    warn "Нода не ответила — проверь: docker compose -f ${RW_COMPOSE_NODE} logs"
    return 0
}

_rw_node_open_firewall() {
    local node_port="$1"
    local xray_port="$2"

    if command -v ufw &>/dev/null; then
        ufw allow "${node_port}/tcp" comment "Remnawave Node GRPC" 2>/dev/null || true
        ufw allow "${xray_port}/tcp" comment "Remnawave Node Xray" 2>/dev/null || true
        info "UFW: открыты порты ${node_port} и ${xray_port}"
    fi
}

# =============================================================================
# СТАТУС
# =============================================================================

remnawave_status_panel() {
    section "Статус Remnawave Panel"

    if [[ ! -f "${RW_COMPOSE_PANEL}" ]]; then
        warn "Панель не установлена"
        return 0
    fi

    echo -e "  ${BOLD}Контейнеры:${N}"
    docker compose -f "${RW_COMPOSE_PANEL}" ps 2>/dev/null | \
        while IFS= read -r line; do echo "  ${line}"; done

    echo ""
    echo -e "  ${BOLD}Ресурсы:${N}"
    docker stats --no-stream --format "  {{.Name}}: CPU={{.CPUPerc}} MEM={{.MemUsage}}" \
        remnawave remnawave-db remnawave-valkey 2>/dev/null || true

    # Health check
    local panel_port
    panel_port=$(grep "^APP_PORT=" "${RW_ENV_FILE}" 2>/dev/null | cut -d= -f2 || echo "${RW_PANEL_PORT}")

    echo ""
    step_msg "Проверяем API..."
    local health
    health=$(curl -4s --max-time 5 "http://127.0.0.1:${panel_port}/api/health" 2>/dev/null || echo "нет ответа")
    echo -e "  ${GR}Health:${N} ${health}"
}

remnawave_status_node() {
    section "Статус Remnawave Node"

    if [[ ! -f "${RW_COMPOSE_NODE}" ]]; then
        warn "Нода не установлена"
        return 0
    fi

    echo -e "  ${BOLD}Контейнеры:${N}"
    docker compose -f "${RW_COMPOSE_NODE}" ps 2>/dev/null | \
        while IFS= read -r line; do echo "  ${line}"; done

    echo ""
    echo -e "  ${BOLD}Ресурсы:${N}"
    docker stats --no-stream --format "  {{.Name}}: CPU={{.CPUPerc}} MEM={{.MemUsage}}" \
        remnawave-node 2>/dev/null || true

    # Xray внутри ноды
    local xray_port
    xray_port=$(grep "^XRAY_PORT=" "${RW_NODE_ENV_FILE}" 2>/dev/null | cut -d= -f2 || echo "443")

    echo ""
    step_msg "Проверяем порт Xray ${xray_port}..."
    if ss -tlnp 2>/dev/null | grep -q ":${xray_port}"; then
        echo -e "  ${G}✓${N} Xray слушает :${xray_port}"
    else
        echo -e "  ${Y}!${N} Xray не найден на :${xray_port}"
    fi
}

# =============================================================================
# ПЕРЕЗАПУСК
# =============================================================================

remnawave_restart_panel() {
    [[ ! -f "${RW_COMPOSE_PANEL}" ]] && { warn "Панель не установлена"; return 1; }
    step_msg "Перезапускаем панель..."
    docker compose -f "${RW_COMPOSE_PANEL}" restart 2>&1
    info "Панель перезапущена"
}

remnawave_restart_node() {
    [[ ! -f "${RW_COMPOSE_NODE}" ]] && { warn "Нода не установлена"; return 1; }
    step_msg "Перезапускаем ноду..."
    docker compose -f "${RW_COMPOSE_NODE}" restart 2>&1
    info "Нода перезапущена"
}

# =============================================================================
# ОБНОВЛЕНИЕ
# =============================================================================

remnawave_update_panel() {
    section "Обновление Remnawave Panel"
    [[ ! -f "${RW_COMPOSE_PANEL}" ]] && { warn "Панель не установлена"; return 1; }

    step_msg "Скачиваем новые образы..."
    docker compose -f "${RW_COMPOSE_PANEL}" pull 2>&1 | grep -E "Pulling|Pull complete|up to date" | head -20

    step_msg "Перезапускаем с новыми образами..."
    docker compose -f "${RW_COMPOSE_PANEL}" up -d 2>&1

    info "Панель обновлена"
    docker compose -f "${RW_COMPOSE_PANEL}" ps 2>/dev/null || true
}

remnawave_update_node() {
    section "Обновление Remnawave Node"
    [[ ! -f "${RW_COMPOSE_NODE}" ]] && { warn "Нода не установлена"; return 1; }

    step_msg "Скачиваем новый образ ноды..."
    docker compose -f "${RW_COMPOSE_NODE}" pull 2>&1 | grep -E "Pulling|Pull complete|up to date" | head -10

    step_msg "Перезапускаем с новым образом..."
    docker compose -f "${RW_COMPOSE_NODE}" up -d 2>&1

    info "Нода обновлена"
    docker compose -f "${RW_COMPOSE_NODE}" ps 2>/dev/null || true
}

# =============================================================================
# ДОСТУП И CREDENTIALS
# =============================================================================

remnawave_show_access() {
    section "Доступ к Remnawave Panel"

    if [[ ! -f "${RW_ENV_FILE}" ]]; then
        warn "Панель не установлена"
        return 0
    fi

    local panel_domain
    panel_domain=$(grep "^PUBLIC_DOMAIN=" "${RW_ENV_FILE}" 2>/dev/null | cut -d= -f2 | sed 's|https://||')
    local sub_domain
    sub_domain=$(grep "^SUB_PUBLIC_DOMAIN=" "${RW_ENV_FILE}" 2>/dev/null | cut -d= -f2 | sed 's|https://||')
    local panel_port
    panel_port=$(grep "^APP_PORT=" "${RW_ENV_FILE}" 2>/dev/null | cut -d= -f2 || echo "${RW_PANEL_PORT}")

    echo -e "  ${BOLD}URL панели:${N}"
    echo -e "  ${G}https://${panel_domain}${N}"
    echo -e "  ${GR}(локально: http://127.0.0.1:${panel_port})${N}"
    echo ""
    echo -e "  ${BOLD}SUB домен:${N} ${sub_domain}"
    echo ""
    echo -e "  ${BOLD}Конфиг:${N} ${RW_ENV_FILE}"
    echo ""

    # Показываем credentials (с предупреждением)
    local superadmin_pass
    superadmin_pass=$(grep "^SUPERADMIN_PASSWORD=" "${RW_ENV_FILE}" 2>/dev/null | cut -d= -f2 || echo "?")
    echo -e "  ${Y}SUPERADMIN_PASSWORD:${N} ${superadmin_pass}"
    echo -e "  ${GR}(используй при первом входе, затем смени пароль)${N}"
}

# =============================================================================
# ЛОГИ
# =============================================================================

remnawave_logs_panel() {
    [[ ! -f "${RW_COMPOSE_PANEL}" ]] && { warn "Панель не установлена"; return 1; }
    echo -e "  ${GR}(Ctrl+C для выхода)${N}"
    docker compose -f "${RW_COMPOSE_PANEL}" logs -f --tail=50 remnawave 2>/dev/null || true
}

remnawave_logs_node() {
    [[ ! -f "${RW_COMPOSE_NODE}" ]] && { warn "Нода не установлена"; return 1; }
    echo -e "  ${GR}(Ctrl+C для выхода)${N}"
    docker compose -f "${RW_COMPOSE_NODE}" logs -f --tail=50 remnawave-node 2>/dev/null || true
}

# =============================================================================
# УДАЛЕНИЕ
# =============================================================================

remnawave_uninstall_panel() {
    local silent="${1:-}"

    if [[ "$silent" != "silent" ]]; then
        ask_yn "Удалить Remnawave Panel (данные БД БУДУТ УДАЛЕНЫ)?" "нет"
        [[ $? -ne 0 ]] && return 0
    fi

    if [[ -f "${RW_COMPOSE_PANEL}" ]]; then
        docker compose -f "${RW_COMPOSE_PANEL}" down -v 2>/dev/null || true
    fi

    rm -rf "${RW_PANEL_DIR}"
    info "Remnawave Panel удалена"
}

remnawave_uninstall_node() {
    local silent="${1:-}"

    if [[ "$silent" != "silent" ]]; then
        ask_yn "Удалить Remnawave Node?" "нет"
        [[ $? -ne 0 ]] && return 0
    fi

    if [[ -f "${RW_COMPOSE_NODE}" ]]; then
        docker compose -f "${RW_COMPOSE_NODE}" down 2>/dev/null || true
    fi

    rm -rf "${RW_NODE_DIR}"
    info "Remnawave Node удалена"
}
