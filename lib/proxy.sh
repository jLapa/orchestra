#!/usr/bin/env bash
# =============================================================================
# proxy.sh — Nginx / Caddy reverse proxy + SSL
# Модуль Orchestra | Этап 7
# =============================================================================
set -euo pipefail

[[ -n "${PROXY_MODULE_LOADED:-}" ]] && return 0
readonly PROXY_MODULE_LOADED=1

# =============================================================================
# МЕНЮ
# =============================================================================

proxy_menu() {
    clear
    section "proxy — Reverse Proxy + SSL"

    echo -e "  ${C}1${N}) Nginx vhost + SSL (certbot) для домена"
    echo -e "  ${C}2${N}) Обновить SSL сертификат вручную"
    echo -e "  ${C}3${N}) Список vhost-ов"
    echo -e "  ${C}4${N}) Перезагрузить nginx"
    echo -e "  ${C}5${N}) Статус nginx"
    echo -e "  ${C}0${N}) Назад"
    echo ""

    ask "Выбор" "1"
    case "$REPLY" in
        1) proxy_add_vhost ;;
        2) proxy_renew_ssl ;;
        3) proxy_list_vhosts ;;
        4) nginx -t && systemctl reload nginx && info "Nginx перезагружен" ;;
        5) proxy_status ;;
        0) return 0 ;;
        *) warn "Неверный выбор" ;;
    esac
}

# =============================================================================
# ДОБАВИТЬ VHOST
# =============================================================================

proxy_add_vhost() {
    section "Добавить Nginx vhost"

    hint "Nginx reverse proxy + SSL" \
        "Создаём vhost для домена с SSL через Let's Encrypt." \
        "Домен должен уметь A-запись на IP этого сервера." \
        "Порт 80 должен быть открыт для certbot HTTP-01."

    ask "Домен" ""
    local domain="$REPLY"
    [[ -z "$domain" ]] && { warn "Домен не введён"; return 1; }

    # Валидация домена
    validate_domain "$domain" "required" "false" || return 1
    check_domain_extras "$domain"

    ask "Upstream порт (куда проксируем)" "3000"
    local upstream_port="$REPLY"

    ask "Описание/комментарий (для конфига)" "${domain}"
    local comment="$REPLY"

    # Устанавливаем nginx + certbot если нет
    _proxy_ensure_nginx
    _proxy_ensure_certbot

    # Создаём vhost
    _proxy_create_vhost "$domain" "$upstream_port" "$comment"

    # Выпускаем SSL
    _proxy_issue_ssl "$domain"
}

_proxy_ensure_nginx() {
    command -v nginx &>/dev/null && return 0
    step_msg "Устанавливаем nginx..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" 2>/dev/null
    systemctl enable nginx
    systemctl start nginx
}

_proxy_ensure_certbot() {
    command -v certbot &>/dev/null && return 0
    step_msg "Устанавливаем certbot..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        certbot python3-certbot-nginx \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" 2>/dev/null
}

_proxy_create_vhost() {
    local domain="${1}"
    local upstream_port="${2}"
    local comment="${3}"
    local conf_file="/etc/nginx/sites-available/${domain}"

    cat > "$conf_file" << NGXEOF
# Orchestra — ${comment}
# Создан: $(date '+%Y-%m-%d %H:%M:%S')

server {
    listen 80;
    server_name ${domain};

    # Заглушка для certbot HTTP-01
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    # Редирект на HTTPS (после выпуска сертификата)
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name ${domain};

    # SSL — будет заполнено certbot
    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    # Security headers
    server_tokens off;
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Proxy к upstream
    location / {
        proxy_pass         http://127.0.0.1:${upstream_port};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }

    access_log /var/log/nginx/${domain}-access.log;
    error_log  /var/log/nginx/${domain}-error.log;
}
NGXEOF

    # Временно используем только HTTP блок (до выпуска сертификата)
    # Создаём упрощённый конфиг для certbot
    cat > "/etc/nginx/sites-available/${domain}-http-only" << NGXEOF2
# Временный HTTP конфиг для certbot
server {
    listen 80;
    server_name ${domain};
    root /var/www/html;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 200 "OK";
        add_header Content-Type text/plain;
    }
}
NGXEOF2

    ln -sf "/etc/nginx/sites-available/${domain}-http-only" \
           "/etc/nginx/sites-enabled/${domain}"

    nginx -t && systemctl reload nginx
    info "Vhost ${domain} создан (HTTP)"
}

_proxy_issue_ssl() {
    local domain="${1}"

    step_msg "Выпускаем SSL сертификат для ${domain}..."

    certbot certonly --nginx \
        -d "$domain" \
        --non-interactive \
        --agree-tos \
        --email "admin@${domain}" \
        2>&1 | tail -5

    if [[ ! -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
        error "Сертификат не выпущен"
        return 1
    fi

    # Переключаем на полный HTTPS конфиг
    rm -f "/etc/nginx/sites-enabled/${domain}"
    rm -f "/etc/nginx/sites-available/${domain}-http-only"
    ln -sf "/etc/nginx/sites-available/${domain}" \
           "/etc/nginx/sites-enabled/${domain}"

    nginx -t && systemctl reload nginx
    info "SSL сертификат выпущен. Vhost ${domain} активен (HTTPS)"

    # Cron автообновления
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; \
         echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") \
         | crontab -
        info "Cron: автообновление сертификатов в 03:00"
    fi
}

# =============================================================================
# ОБНОВЛЕНИЕ SSL
# =============================================================================

proxy_renew_ssl() {
    section "Обновление SSL сертификатов"
    certbot renew --quiet --post-hook "systemctl reload nginx" 2>&1
    info "Сертификаты обновлены"
}

# =============================================================================
# СПИСОК VHOST-ОВ
# =============================================================================

proxy_list_vhosts() {
    section "Активные vhost-ы nginx"

    ls /etc/nginx/sites-enabled/ 2>/dev/null | while IFS= read -r vhost; do
        local ssl_status="${GR}HTTP${N}"
        if [[ -f "/etc/letsencrypt/live/${vhost}/fullchain.pem" ]]; then
            # Проверяем срок действия
            local expiry
            expiry=$(openssl x509 \
                -in "/etc/letsencrypt/live/${vhost}/fullchain.pem" \
                -noout -enddate 2>/dev/null \
                | cut -d= -f2 || echo "?")
            ssl_status="${G}HTTPS${N} (до ${expiry})"
        fi
        echo -e "  ${C}${vhost}${N} — ${ssl_status}"
    done
}

# =============================================================================
# СТАТУС
# =============================================================================

proxy_status() {
    section "Статус Nginx"

    if systemctl is-active --quiet nginx 2>/dev/null; then
        echo -e "  ${G}✓${N} nginx running"
        nginx -v 2>&1 | while IFS= read -r line; do echo "    ${line}"; done
    else
        echo -e "  ${R}✗${N} nginx не запущен"
    fi

    echo ""
    echo -e "  ${BOLD}Конфигурация:${N}"
    nginx -t 2>&1 | while IFS= read -r line; do echo "    ${line}"; done

    echo ""
    echo -e "  ${BOLD}Слушаемые порты:${N}"
    ss -tlnp 2>/dev/null | grep nginx | \
        while IFS= read -r line; do echo "    ${line}"; done || \
        echo -e "    ${GR}нет данных${N}"
}
