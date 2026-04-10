#!/usr/bin/env bash
# =============================================================================
# Orchestra — установщик одной командой
# Версия: 1.0.0
# =============================================================================
set -euo pipefail

# Цвета для вывода
if [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null; then
    readonly R="\033[0;31m"
    readonly G="\033[0;32m"
    readonly Y="\033[0;33m"
    readonly B="\033[0;34m"
    readonly N="\033[0m"
    readonly BOLD="\033[1m"
else
    readonly R="" G="" Y="" B="" N="" BOLD=""
fi

# Функции вывода
info()    { echo -e "${B}[i]${N} $*"; }
success() { echo -e "${G}[✓]${N} $*"; }
warn()    { echo -e "${Y}[!]${N} $*"; }
error()   { echo -e "${R}[✗]${N} $*" >&2; }
fatal()   { error "$*"; exit 1; }

# =============================================================================
# ОСНОВНАЯ ЛОГИКА
# =============================================================================

main() {
    echo -e "${BOLD}Orchestra — установщик одной командой${N}"
    echo "================================================"
    echo ""
    
    # Проверка прав
    if [[ "$(id -u)" -eq 0 ]]; then
        warn "Скрипт запущен от root. Установка в системные директории."
        INSTALL_DIR="/opt/orchestra"
    else
        info "Скрипт запущен от обычного пользователя."
        INSTALL_DIR="${HOME}/.orchestra"
        warn "Рекомендуется запуск от root/sudo для полной функциональности."
        echo ""
        ask_yn "Продолжить установку в ${INSTALL_DIR}?" "да"
        [[ $? -ne 0 ]] && exit 0
    fi
    
    # Проверка зависимостей
    check_dependencies
    
    # Создание директории
    create_directory "$INSTALL_DIR"
    
    # Загрузка Orchestra
    download_orchestra "$INSTALL_DIR"
    
    # Настройка прав
    setup_permissions "$INSTALL_DIR"
    
    # Создание символической ссылки (опционально)
    setup_symlink "$INSTALL_DIR"
    
    # Завершение
    show_summary "$INSTALL_DIR"
}

# =============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# =============================================================================

ask_yn() {
    local prompt="$1"
    local default="${2:-}"
    local reply
    
    if [[ "$default" == "да" ]]; then
        prompt="${prompt} [Да/нет] (Да): "
    elif [[ "$default" == "нет" ]]; then
        prompt="${prompt} [Да/нет] (нет): "
    else
        prompt="${prompt} [Да/нет]: "
    fi
    
    read -r -p "$prompt" reply
    reply="${reply:-$default}"
    
    case "$(echo "$reply" | tr '[:upper:]' '[:lower:]')" in
        д|да|y|yes|1) return 0 ;;
        *) return 1 ;;
    esac
}

check_dependencies() {
    info "Проверяю зависимости..."
    
    local missing=()
    
    # Обязательные
    for cmd in curl git; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    # Рекомендуемые
    local recommended=()
    for cmd in sudo docker sshpass jq; do
        if ! command -v "$cmd" &>/dev/null; then
            recommended+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Отсутствуют обязательные зависимости: ${missing[*]}"
        
        if [[ "$(id -u)" -eq 0 ]]; then
            ask_yn "Установить автоматически?" "да"
            if [[ $? -eq 0 ]]; then
                install_dependencies "${missing[@]}"
            else
                fatal "Установите зависимости вручную: ${missing[*]}"
            fi
        else
            warn "Запустите с sudo или установите вручную: ${missing[*]}"
            ask_yn "Попробовать установить с sudo?" "да"
            if [[ $? -eq 0 ]]; then
                install_dependencies "${missing[@]}"
            else
                fatal "Установите зависимости вручную: ${missing[*]}"
            fi
        fi
    fi
    
    if [[ ${#recommended[@]} -gt 0 ]]; then
        info "Рекомендуемые зависимости (можно установить позже): ${recommended[*]}"
    fi
}

install_dependencies() {
    info "Устанавливаю зависимости: $*"
    
    if command -v apt-get &>/dev/null; then
        # Debian/Ubuntu
        sudo apt-get update
        sudo apt-get install -y "$@" || {
            error "Не удалось установить зависимости"
            return 1
        }
    elif command -v yum &>/dev/null; then
        # RHEL/CentOS
        sudo yum install -y "$@" || {
            error "Не удалось установить зависимости"
            return 1
        }
    elif command -v dnf &>/dev/null; then
        # Fedora
        sudo dnf install -y "$@" || {
            error "Не удалось установить зависимости"
            return 1
        }
    elif command -v pacman &>/dev/null; then
        # Arch
        sudo pacman -S --noconfirm "$@" || {
            error "Не удалось установить зависимости"
            return 1
        }
    else
        error "Не удалось определить менеджер пакетов"
        return 1
    fi
    
    success "Зависимости установлены"
}

create_directory() {
    local dir="$1"
    
    info "Создаю директорию: ${dir}"
    
    if [[ -d "$dir" ]]; then
        warn "Директория уже существует: ${dir}"
        ask_yn "Перезаписать содержимое?" "нет"
        if [[ $? -eq 0 ]]; then
            rm -rf "${dir:?}/"*
            success "Содержимое очищено"
        else
            fatal "Установка отменена"
        fi
    else
        sudo mkdir -p "$dir" 2>/dev/null || mkdir -p "$dir" || {
            fatal "Не удалось создать директорию: ${dir}"
        }
    fi
    
    # Права доступа
    if [[ "$(id -u)" -eq 0 ]]; then
        sudo chmod 755 "$dir"
    else
        chmod 755 "$dir"
    fi
    
    success "Директория создана"
}

download_orchestra() {
    local dir="$1"
    local repo_url="https://github.com/jLapa/orchestra.git"
    local temp_dir
    
    info "Загружаю Orchestra с GitHub..."
    
    # Используем git clone или скачиваем архив
    if command -v git &>/dev/null; then
        temp_dir="$(mktemp -d)"
        trap 'rm -rf "$temp_dir"' EXIT
        
        git clone --depth 1 "$repo_url" "$temp_dir" || {
            error "Не удалось клонировать репозиторий"
            return 1
        }
        
        # Копируем файлы
        cp -r "$temp_dir/." "$dir" || {
            error "Не удалось скопировать файлы"
            return 1
        }
        
        rm -rf "$temp_dir"
        trap - EXIT
    else
        # Fallback: скачиваем архив
        warn "Git не найден, скачиваю архив..."
        local archive_url="https://github.com/jLapa/orchestra/archive/refs/heads/master.tar.gz"
        curl -4fsSL "$archive_url" | tar -xz -C "$dir" --strip-components=1 || {
            error "Не удалось скачать архив"
            return 1
        }
    fi
    
    success "Orchestra загружен"
}

setup_permissions() {
    local dir="$1"
    
    info "Настраиваю права доступа..."
    
    # Основной скрипт
    local main_script="${dir}/orchestra.sh"
    if [[ -f "$main_script" ]]; then
        chmod +x "$main_script"
        success "Права на исполнение: orchestra.sh"
    fi
    
    # Валидационный скрипт
    local validate_script="${dir}/validate.sh"
    if [[ -f "$validate_script" ]]; then
        chmod +x "$validate_script"
        success "Права на исполнение: validate.sh"
    fi
    
    # Установочный скрипт (этот)
    local install_script="${dir}/install.sh"
    if [[ -f "$install_script" ]]; then
        chmod +x "$install_script"
        success "Права на исполнение: install.sh"
    fi
    
    # Модули
    if [[ -d "${dir}/lib" ]]; then
        find "${dir}/lib" -name "*.sh" -exec chmod +x {} \;
        success "Права на исполнение: модули"
    fi
}

setup_symlink() {
    local dir="$1"
    
    if [[ "$(id -u)" -ne 0 ]]; then
        info "Символическая ссылка в /usr/local/bin требует прав root"
        ask_yn "Создать ссылку в ~/.local/bin?" "да"
        if [[ $? -eq 0 ]]; then
            local bin_dir="${HOME}/.local/bin"
            mkdir -p "$bin_dir"
            ln -sf "${dir}/orchestra.sh" "${bin_dir}/orchestra" 2>/dev/null || true
            success "Ссылка создана: ${bin_dir}/orchestra"
            warn "Добавьте в PATH: export PATH=\"\${HOME}/.local/bin:\$PATH\""
        fi
        return
    fi
    
    ask_yn "Создать символическую ссылку /usr/local/bin/orchestra?" "да"
    if [[ $? -eq 0 ]]; then
        ln -sf "${dir}/orchestra.sh" "/usr/local/bin/orchestra"
        success "Ссылка создана: /usr/local/bin/orchestra"
    fi
}

show_summary() {
    local dir="$1"
    
    echo ""
    echo -e "${BOLD}================================================"
    echo -e "          УСТАНОВКА ЗАВЕРШЕНА"
    echo -e "================================================${N}"
    echo ""
    echo -e "${G}Orchestra успешно установлен в:${N}"
    echo -e "  ${dir}"
    echo ""
    
    # Пути
    echo -e "${B}Основные команды:${N}"
    echo -e "  ${dir}/orchestra.sh      # Запуск из директории"
    
    if [[ -f "/usr/local/bin/orchestra" ]] || [[ -f "${HOME}/.local/bin/orchestra" ]]; then
        echo -e "  orchestra              # Глобальная команда"
    fi
    
    echo ""
    echo -e "${B}Проверка установки:${N}"
    echo -e "  ${dir}/validate.sh       # Проверить все модули"
    echo ""
    
    echo -e "${B}Документация:${N}"
    echo -e "  ${dir}/README.md         # Основная документация"
    echo -e "  ${dir}/orchestra-briefing.md  # Контекст проекта"
    echo ""
    
    echo -e "${B}Следующие шаги:${N}"
    echo -e "  1. Перейдите в директорию: ${Y}cd ${dir}${N}"
    echo -e "  2. Запустите: ${Y}./orchestra.sh${N}"
    echo -e "  3. Выберите режим работы (локальный/удалённый/флот)"
    echo ""
    
    if [[ "$(id -u)" -ne 0 ]]; then
        warn "Для полной функциональности может потребоваться sudo"
        echo -e "  ${Y}sudo ./orchestra.sh${N}"
    fi
    
    echo -e "${G}Удачи!${N}"
    echo ""
}

# =============================================================================
# ЗАПУСК
# =============================================================================

# Если скрипт вызван напрямую (не source)
# Используем ${BASH_SOURCE[0]:-$0} для работы через pipe (curl | bash)
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    # Обработка аргументов
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                echo "Использование: $0 [опции]"
                echo "Опции:"
                echo "  --help, -h     Показать эту справку"
                echo "  --dir PATH     Указать директорию установки"
                echo "  --no-symlink   Не создавать символическую ссылку"
                echo "  --skip-deps    Пропустить проверку зависимостей"
                exit 0
                ;;
            --dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            --no-symlink)
                NO_SYMLINK=1
                shift
                ;;
            --skip-deps)
                SKIP_DEPS=1
                shift
                ;;
            *)
                error "Неизвестный аргумент: $1"
                exit 1
                ;;
        esac
    done
    
    # Запуск основной функции
    main "$@"
fi