#!/usr/bin/env bash
# =============================================================================
# setup-auto.sh — Автоустановка: sys + xray (VLESS+Reality+XHTTP) + remnawave panel
# Запуск без диалогов, все параметры прописаны ниже.
# =============================================================================
set -euo pipefail

# === Цвета (упрощённые, для логов) ===
R="\033[0;31m"; G="\033[0;32m"; Y="\033[0;33m"; B="\033[0;34m"
C="\033[0;36m"; N="\033[0m"; BOLD="\033[1m"; GR="\033[0;90m"

log()  { echo -e "${B}[AUTO]${N} $*"; }
ok()   { echo -e "${G}[ OK ]${N} $*"; }
warn() { echo -e "${Y}[WARN]${N} $*"; }
die()  { echo -e "${R}[FAIL]${N} $*" >&2; exit 1; }

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║    Orchestra — Автоустановка (sys + xray + rw)       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${N}"

[[ "$(id -u)" -ne 0 ]] && die "Требуется root"

# =============================================================================
# STEP 0: Клонирование Orchestra с GitHub
# =============================================================================

log "Клонирую Orchestra из GitHub..."

ORCH_DIR="/opt/orchestra"

if [[ -d "$ORCH_DIR/.git" ]]; then
    warn "Orchestra уже установлена в ${ORCH_DIR} — обновляю..."
    git -C "$ORCH_DIR" config core.autocrlf false
    git -C "$ORCH_DIR" reset --hard HEAD 2>&1 | tail -1
    git -C "$ORCH_DIR" pull --ff-only 2>&1 | tail -3
else
    if [[ -d "$ORCH_DIR" ]]; then
        warn "Директория ${ORCH_DIR} существует — очищаю..."
        rm -rf "${ORCH_DIR:?}"
    fi
    git clone --depth 1 https://github.com/jLapa/orchestra.git "$ORCH_DIR" \
        || die "Не удалось клонировать репозиторий"
fi

chmod +x "$ORCH_DIR/orchestra.sh" "$ORCH_DIR/lib/"*.sh 2>/dev/null || true
ok "Orchestra клонирована в ${ORCH_DIR}"

# =============================================================================
# STEP 1: Загрузка orchestra.sh (без запуска меню)
# =============================================================================

log "Загружаю orchestra.sh..."

cd "$ORCH_DIR"
export ORCHESTRA_SOURCED="true"   # предотвращает запуск main_menu
# shellcheck source=/dev/null
source "$ORCH_DIR/orchestra.sh"
source "$ORCH_DIR/lib/sys.sh"
source "$ORCH_DIR/lib/xray.sh"
source "$ORCH_DIR/lib/remnawave.sh"

ok "Функции загружены"

# Создаём нужные директории (init_directories() иначе вызывается только через self_install)
init_directories

# Определяем IP один раз
SERVER_IP=$(get_server_ip 2>/dev/null) || die "Не удалось определить IP сервера"
ok "IP сервера: ${SERVER_IP}"

# =============================================================================
# ПАРАМЕТРЫ УСТАНОВКИ (редактируй здесь)
# =============================================================================

# --- sys.sh ---
SYS_SSH_PORT="22"               # SSH порт остаётся 22 (не меняем)
SYS_ADMIN_IP=""                 # Whitelist IP (пусто = без whitelist)
SYS_DISABLE_IPV6="yes"          # Отключить IPv6
SYS_TIMEZONE="Europe/Moscow"    # Часовой пояс
SYS_NTP_SERVER="pool.ntp.org"   # NTP сервер
SYS_PERMIT_ROOT="yes"           # yes — root по паролю разрешён (у нас нет SSH ключей)

# --- xray.sh ---
XRAY_PORT="443"
XRAY_SNI="www.microsoft.com"
XRAY_PATH="/xray"
XRAY_USERS_COUNT="10"
XRAY_DOMAIN=""                  # Без домена — ссылки на IP
XRAY_WARP="yes"

# --- remnawave panel ---
RW_ADMIN_USER="admin"
RW_ADMIN_PASS=$(openssl rand -hex 12)
RW_PANEL_ADMIN_PORT="3000"

# =============================================================================
# STEP 2: sys.sh — Hardening
# =============================================================================

echo ""
echo -e "${BOLD}══════ ЭТАП 1: Системный hardening (sys.sh) ══════${N}"

init_progress "sys" "${SERVER_IP}"
# check_resume_prompt пропустим — на чистом сервере нет done/failed шагов

run_step "update_packages"  _sys_update_packages  "Обновление пакетов"
run_step "install_deps"     _sys_install_deps     "Установка зависимостей"
run_step "apply_sysctl"     _sys_apply_sysctl     "sysctl (BBR + оптимизация)"
run_step "setup_ufw"        _sys_setup_ufw        "UFW файрвол"
run_step "setup_ssh"        _sys_setup_ssh        "SSH hardening"
run_step "setup_fail2ban"   _sys_setup_fail2ban   "fail2ban"
run_step "setup_ntp"        _sys_setup_ntp        "NTP (chrony)"
run_step "setup_logrotate"  _sys_setup_logrotate  "Logrotate"
run_step "setup_autoupdate" _sys_setup_autoupdate "Автообновления безопасности"

state_set "${SERVER_IP}" "SSH_PORT" "${SYS_SSH_PORT}"
mark_module_done "sys" "${SERVER_IP}"
ok "sys.sh завершён"

# =============================================================================
# STEP 3: xray.sh — VLESS + Reality + XHTTP
# =============================================================================

echo ""
echo -e "${BOLD}══════ ЭТАП 2: Xray VLESS + Reality + XHTTP ══════${N}"

init_progress "xray" "${SERVER_IP}"

run_step "preflight"        _xray_preflight         "Проверка конфигурации"
run_step "install_deps"     _xray_install_deps      "Зависимости Xray"
run_step "install_xray"     _xray_install_xray      "Установка Xray"
run_step "generate_keys"    _xray_generate_keys     "Ключи Reality (x25519)"
run_step "generate_users"   _xray_generate_users    "Генерация пользователей (${XRAY_USERS_COUNT} шт)"
run_step "create_config"    _xray_create_config     "Конфиг Xray (/etc/xray/config.json)"
run_step "create_service"   _xray_create_service    "Systemd сервис xray"
run_step "install_warp"     _xray_install_warp      "Cloudflare WARP"
run_step "setup_nginx"      _xray_setup_nginx       "Nginx decoy сайт (порт 80)"
run_step "setup_autoupdate" _xray_setup_autoupdate  "Скрипт автообновления Xray"
run_step "setup_cron"       _xray_setup_cron        "Cron задачи"
run_step "finalize"         _xray_finalize          "Итог Xray"

_xray_save_state "${SERVER_IP}"
mark_module_done "xray" "${SERVER_IP}"
ok "xray.sh завершён"

# =============================================================================
# STEP 4: remnawave panel — Docker (без nginx/SSL, доступ по IP:3000)
# =============================================================================

echo ""
echo -e "${BOLD}══════ ЭТАП 3: Remnawave Panel (Docker) ══════${N}"

# Генерация секретов
_RW_P_DOMAIN="${SERVER_IP}"
_RW_P_SUB="${SERVER_IP}"
_RW_P_PORT="${RW_PANEL_ADMIN_PORT}"
_RW_P_DB_PASS=$(openssl rand -hex 16)
_RW_P_JWT_AUTH=$(openssl rand -hex 32)
_RW_P_JWT_API=$(openssl rand -hex 32)
_RW_P_MUSER="prometheus"
_RW_P_MPASS=$(openssl rand -hex 12)
_RW_P_SADMIN=$(openssl rand -hex 16)
_RW_P_ADMIN_USER="${RW_ADMIN_USER}"
_RW_P_ADMIN_PASS="${RW_ADMIN_PASS}"

# Обёртки для run_step (без аргументов)
_rw_step_panel_env()     { _rw_panel_write_env     "$_RW_P_DOMAIN" "$_RW_P_SUB" "$_RW_P_PORT" \
                            "$_RW_P_DB_PASS" "$_RW_P_JWT_AUTH" "$_RW_P_JWT_API" \
                            "$_RW_P_MUSER" "$_RW_P_MPASS" "$_RW_P_SADMIN"; }
_rw_step_panel_compose() { _rw_panel_write_compose "$_RW_P_PORT"; }
_rw_step_panel_healthy() { _rw_panel_wait_healthy  "$_RW_P_PORT"; }
_rw_step_panel_admin()   { _rw_panel_create_admin  "$_RW_P_PORT" "$_RW_P_ADMIN_USER" "$_RW_P_ADMIN_PASS"; }

# Патч compose: открываем панель на 0.0.0.0 (без nginx, прямой доступ по IP:3000)
_rw_step_patch_compose() {
    sed -i \
        's|"127\.0\.0\.1:\${APP_PORT}:\${APP_PORT}"|"0.0.0.0:${APP_PORT}:${APP_PORT}"|g' \
        "${RW_COMPOSE_PANEL}"
    # Перезапускаем чтобы применить новый binding
    docker compose -f "${RW_COMPOSE_PANEL}" up -d 2>&1 | tail -3
}

# Открываем порт 3000 через UFW
_rw_step_open_ufw() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${_RW_P_PORT}/tcp" comment "Remnawave Panel" 2>/dev/null || true
        info "UFW: разрешён порт ${_RW_P_PORT}/tcp"
    fi
}

init_progress "remnawave-panel" "${SERVER_IP}"

run_step "rw_ensure_docker"   "_rw_ensure_docker"       "Установка Docker"
run_step "rw_panel_dirs"      "_rw_panel_create_dirs"   "Директории панели"
run_step "rw_panel_env"       "_rw_step_panel_env"      "Конфигурация .env"
run_step "rw_panel_compose"   "_rw_step_panel_compose"  "Docker Compose файл"
run_step "rw_panel_pull"      "_rw_panel_pull"          "Загрузка Docker образов"
run_step "rw_panel_start"     "_rw_panel_start"         "Запуск контейнеров"
run_step "rw_patch_compose"   "_rw_step_patch_compose"  "Открытие порта 0.0.0.0 в compose"
run_step "rw_open_ufw"        "_rw_step_open_ufw"       "UFW правило для панели"
# nginx/SSL пропускаем — нет домена
run_step "rw_panel_healthy"   "_rw_step_panel_healthy"  "Ожидание готовности панели"
run_step "rw_panel_admin"     "_rw_step_panel_admin"    "Создание администратора"

mark_module_done "remnawave-panel" "${SERVER_IP}"
ok "Remnawave Panel установлена"

# =============================================================================
# ИТОГОВАЯ СВОДКА
# =============================================================================

echo ""
echo -e "${BOLD}${G}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║             УСТАНОВКА ЗАВЕРШЕНА                      ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${N}"

echo -e "${BOLD}  Xray VLESS + Reality + XHTTP:${N}"
echo -e "  ${GR}Порт:${N}         ${XRAY_PORT}"
echo -e "  ${GR}SNI:${N}          ${XRAY_SNI}"
echo -e "  ${GR}XHTTP путь:${N}   ${XRAY_PATH}"
echo -e "  ${GR}Пользователи:${N} ${XRAY_USERS_COUNT} шт"
echo -e "  ${GR}Публичный ключ:${N} ${XRAY_PUBLIC_KEY:-см. /etc/xray/links.txt}"
echo -e "  ${GR}Ссылки:${N}       /etc/xray/links.txt"
echo ""
echo -e "${BOLD}  Remnawave Panel:${N}"
echo -e "  ${GR}URL:${N}          http://${SERVER_IP}:${RW_PANEL_ADMIN_PORT}"
echo -e "  ${GR}Логин:${N}        ${RW_ADMIN_USER}"
echo -e "  ${GR}Пароль:${N}       ${RW_ADMIN_PASS}"
echo -e "  ${GR}SUPERADMIN:${N}   см. ${RW_ENV_FILE}"
echo ""
echo -e "${BOLD}  Xray ссылки:${N}"
cat /etc/xray/links.txt 2>/dev/null || echo "  (пока нет — перезапусти xray)"
echo ""
echo -e "${Y}  Следующие шаги:${N}"
echo -e "  1. Зайди на http://${SERVER_IP}:${RW_PANEL_ADMIN_PORT} и создай ноду"
echo -e "  2. Добавь клиентов в Remnawave Panel"
echo -e "  3. При наличии домена — запусти orchestra.sh для настройки nginx + SSL"
echo ""
