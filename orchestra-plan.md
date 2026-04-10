# Orchestra — План разработки

> Единый bash-оркестр для развёртывания и управления VPN-инфраструктурой.  
> Работает локально и удалённо, управляет флотом нод, проверяет блокировки,  
> и продаёт подписки через Telegram с 15+ платёжными системами.

---

## Содержание

1. [Концепция](#концепция)
2. [Структура файлов](#структура-файлов)
3. [Валидация домена](#валидация-домена)
4. [Модули](#модули)
5. [Схемы процессов](#схемы-процессов)
   - [Валидация домена](#схема-валидации-домена)
   - [Локальный режим](#локальный-режим)
   - [Удалённый режим](#удалённый-режим)
   - [Fleet-режим](#fleet-режим)
   - [Мониторинг нод](#мониторинг-нод)
   - [Установка Remnawave](#установка-remnawave)
   - [Установка Bedolaga Bot](#установка-bedolaga-bot)
   - [Резервное копирование](#резервное-копирование)
6. [Fleet — формат конфига](#fleet--формат-конфига)
7. [Главное меню](#главное-меню)
8. [Технические принципы](#технические-принципы)
9. [Источники методик](#источники-методик)
10. [Порядок разработки](#порядок-разработки)

---

## Концепция

Orchestra — это **мастер-скрипт**, который:

- Запускается **локально** (на сервере, куда ты залогинен)
- Запускается **удалённо** — SSHится в любой сервер из `nodes.conf` и выполняет там нужный модуль
- Ведёт **fleet** — реестр всех нод с их ролями и состоянием
- Со временем превращается в **командный центр**: деплоить, обновлять, мониторить, проверять блокировки

```
Твой ноутбук / управляющий сервер
         │
         │  SSH
    ┌────┴──────────────────────────────┐
    │                                   │
  Node-01                            Node-02
  31.56.178.11                       31.58.137.10
  role: xray                         role: remnawave-node
```

---

## Концепция доменов

Инфраструктура использует **несколько доменов** с разными назначениями. Каждый домен проходит валидацию A-записи до начала установки зависящего от него компонента.

### Карта доменов

```
example.com  (корневой, твой)
│
├── vpn.example.com       XRAY NODE      A → IP ноды    DNS-only ← Reality требует!
├── node2.example.com     XRAY NODE 2    A → IP ноды 2  DNS-only
│
├── panel.example.com     REMNAWAVE      A → IP панели  DNS-only (скрытый)
├── sub.example.com       SUBSCRIPTIONS  A → IP панели  Cloudflare Proxy OK ✓
│                                        или отдельный VPS / CF Worker
├── bot.example.com       BEDOLAGA BOT   A → IP бота    DNS-only
│
└── (опционально)
    └── api.example.com   REMNAWAVE API  A → IP панели  DNS-only
```

### Cloudflare правила по типу домена

| Домен | Cloudflare Proxy | Причина |
|---|:---:|---|
| `vpn.*` (Xray/Reality) | ❌ DNS-only | Reality проверяет TLS до реального сервера — CF proxy ломает |
| `panel.*` (Remnawave) | ❌ DNS-only | Панель для личного доступа, IP не принципиален |
| **`sub.*` (Подписки)** | ✅ **Можно!** | Только HTTPS GET — CF CDN скрывает IP панели от клиентов |
| `bot.*` (Bedolaga) | ❌ DNS-only | Вебхуки платёжных систем требуют прямого TLS |

### Три варианта SUB архитектуры

**Вариант A — Всё на одном сервере (просто)**
```
panel.example.com ──► nginx ──► :3000  Remnawave Panel
sub.example.com   ──► nginx ──► :3010  Remnawave Sub Page
```
- Плюс: минимум настройки
- Минус: один IP для всего

**Вариант B — SUB за Cloudflare (рекомендуется)**
```
sub.example.com  [оранжевое облако CF] ──► CF CDN ──► сервер :3010
panel.example.com [серое облако]        ──► сервер :3000
```
- Клиент видит только Cloudflare IP — реальный IP панели скрыт
- Remnawave `SUB_PUBLIC_DOMAIN=sub.example.com` — работает через CF
- Xray Reality по-прежнему на `vpn.example.com` без CF

**Вариант C — SUB на отдельном сервере / Cloudflare Worker (максимум)**
```
sub.example.com ──► CF Worker или дешёвый VPS
                    └──► proxy_pass к panel:3010 (по приватной сети)
```
- IP панели не знает никто кроме тебя
- Панель вообще не имеет публичного домена

**Зачем это нужно:**

| Причина | Объяснение |
|---|---|
| **Маскировка панели** | Клиенты знают только `sub.*` — IP панели не раскрывается |
| **Смена сервера** | Переехал — перенаправил SUB, у клиентов ссылки не изменились |
| **DPI устойчивость** | Запрос подписки выглядит как обычный HTTPS к "сайту" |
| **CDN защита** | SUB за Cloudflare — DDoS защита и сокрытие IP |
| **Reality** | Xray-нода использует свой домен, не связанный с панелью |

**Правило:** скрипт не продолжает установку любого компонента если домен не прошёл валидацию.

---

## Структура файлов

```
/opt/orchestra/
├── orchestra.sh              # точка входа, загрузка модулей, главное меню
│                             # содержит: validate_domain(), get_server_ip()
│
├── lib/                      # модули (загружаются по необходимости)
│   ├── sys.sh                # базовая настройка системы и безопасности
│   ├── xray.sh               # VLESS + Reality + XHTTP
│   ├── remnawave.sh          # Remnawave Panel + Node
│   ├── bedolaga.sh           # Telegram-бот продажи подписок
│   ├── proxy.sh              # Nginx / Caddy reverse proxy
│   ├── trafficguard.sh       # блокировка сканеров РКН
│   ├── warp.sh               # Cloudflare WARP
│   ├── backup.sh             # резервные копии
│   └── monitor.sh            # мониторинг и проверка блокировок
│
├── fleet/
│   ├── nodes.conf            # реестр серверов (IP, порт SSH, роль)
│   └── credentials/          # SSH-ключи (chmod 700)
│       ├── node-01.key
│       └── node-02.key
│
├── state/                    # состояние каждого сервера
│   ├── 31.56.178.11.conf
│   ├── 31.58.137.10.conf
│   └── orchestra.log         # общий лог событий
│
└── backups/                  # локальные резервные копии
    └── 2026-04-10_node-01.tar.gz
```

**При первом запуске** скрипт копирует себя в `/opt/orchestra/`, создаёт структуру каталогов и регистрирует команду `orchestra` в `/usr/local/bin/`.

---

## Валидация домена

Общая утилита `validate_domain()` встроена в `orchestra.sh` и вызывается **любым модулем**, которому нужен домен. Никакой модуль не начинает установку без прохождения этой проверки.

### Алгоритм проверки

```
validate_domain "vpn.example.com"
        │
        ▼
┌─────────────────────────────────────┐
│ 1. Получить внешний IPv4 сервера    │
│    curl -4s https://ifconfig.me     │
│    → SERVER_IP=31.56.178.11         │
└──────────────┬──────────────────────┘
               │
        ▼
┌─────────────────────────────────────┐
│ 2. Резолвим A-запись домена         │
│    Метод A: dig +short A domain     │
│    Метод B: host domain (fallback)  │
│    Метод C: curl DNS-over-HTTPS     │
│      cloudflare-dns.com/dns-query   │
│    → DOMAIN_IP=31.56.178.11         │
└──────────────┬──────────────────────┘
               │
        ▼
┌─────────────────────────────────────┐
│ 3. Сравниваем IP                    │
│    SERVER_IP == DOMAIN_IP ?         │
└──────┬──────────────┬───────────────┘
       │ ДА           │ НЕТ
       ▼              ▼
  ┌─────────┐   ┌──────────────────────────────┐
  │  OK ✓   │   │  FAIL ✗                      │
  │ продолжить  │  Домен ведёт на: 1.2.3.4      │
  └─────────┘   │  Сервер:        31.56.178.11  │
                │                               │
                │  Возможные причины:           │
                │  • A-запись не создана        │
                │  • Cloudflare proxy (оранжевый)│
                │  • DNS ещё не обновился       │
                │  • Опечатка в домене          │
                │                               │
                │  [1] Повторить проверку       │
                │  [2] Продолжить без домена    │
                │      (только для Xray, —      │
                │       без SSL и маскировки)   │
                │  [0] Отмена                   │
                └──────────────────────────────┘
```

### Где вызывается

| Домен | Модуль | Обязательность | CF Proxy | Fallback |
|---|---|:---:|:---:|---|
| `vpn.*` (нода) | `xray.sh` | рек. | ❌ | IP в ссылках, без SSL-маскировки |
| `panel.*` | `remnawave.sh` panel | **обяз.** | ❌ | нет HTTPS → нет панели |
| `sub.*` | `remnawave.sh` panel | **обяз.** | ✅ OK | отдельный URL подписок |
| домен ноды | `remnawave.sh` node | рек. | ❌ | нода работает по IP |
| `bot.*` | `bedolaga.sh` | **обяз.** | ❌ | без домена нет вебхуков |
| любой | `proxy.sh` | **обяз.** | зависит | нет SSL сертификата |

### Реализация в коде

```bash
# В orchestra.sh — доступна всем модулям через source

get_server_ip() {
    # Принудительно IPv4, три fallback источника
    curl -4s https://ifconfig.me --max-time 5 2>/dev/null \
    || curl -4s https://api.ipify.org --max-time 5 2>/dev/null \
    || curl -4s https://ipv4.icanhazip.com --max-time 5 2>/dev/null
}

resolve_domain() {
    local domain="$1"
    # Метод A — dig (предпочтительный)
    if command -v dig &>/dev/null; then
        dig +short A "$domain" @1.1.1.1 2>/dev/null | grep -E '^[0-9]+\.' | head -1
        return
    fi
    # Метод B — host
    if command -v host &>/dev/null; then
        host "$domain" 2>/dev/null | awk '/has address/{print $4}' | head -1
        return
    fi
    # Метод C — DNS-over-HTTPS (Cloudflare), работает везде где есть curl
    curl -s "https://cloudflare-dns.com/dns-query?name=${domain}&type=A" \
        -H "Accept: application/dns-json" --max-time 10 2>/dev/null \
    | grep -oP '"data":"\K[0-9.]+'| head -1
}

validate_domain() {
    local domain="$1"
    local required="${2:-optional}"  # "required" или "optional"

    [[ -z "$domain" ]] && { error "Домен не указан"; return 1; }

    info "Проверяю A-запись для ${domain}..."
    local server_ip domain_ip
    server_ip=$(get_server_ip)
    domain_ip=$(resolve_domain "$domain")

    if [[ -z "$domain_ip" ]]; then
        warn "Не удалось получить A-запись для ${domain}"
        warn "DNS ещё не обновился или домен не существует"
        [[ "$required" == "required" ]] && return 1
        return 2  # предупреждение, но не блокировка
    fi

    if [[ "$domain_ip" == "$server_ip" ]]; then
        info "Домен ${domain} → ${domain_ip} ✓ (совпадает с IP сервера)"
        return 0
    else
        error "A-запись ${domain} ведёт на ${domain_ip}"
        error "IP этого сервера: ${server_ip}"
        warn "Убедись, что A-запись создана и Cloudflare proxy отключён (серое облако)"
        [[ "$required" == "required" ]] && return 1
        return 2
    fi
}
```

### Автоматическая настройка DNS через Cloudflare API

Если пользователь предоставляет **Cloudflare API Token**, скрипт сам создаёт все нужные DNS-записи — не нужно заходить в панель CF вручную.

#### Поток автонастройки DNS

```
Пользователь вводит:
  CF_API_TOKEN = "abc123..."
  CF_ZONE_DOMAIN = "example.com"
        │
        ▼
┌──────────────────────────────────────────┐
│  1. Получить Zone ID                     │
│     GET /zones?name=example.com          │
│     → ZONE_ID="abc123zone"              │
└───────────────┬──────────────────────────┘
                │
        ▼
┌──────────────────────────────────────────┐
│  2. Получить IP сервера                  │
│     curl -4s https://ifconfig.me         │
│     → SERVER_IP="31.56.178.11"          │
└───────────────┬──────────────────────────┘
                │
        ▼
┌──────────────────────────────────────────┐
│  3. Создать / обновить A-записи          │
│                                          │
│  vpn.example.com    A → IP  proxy=false  │ ← Reality требует
│  panel.example.com  A → IP  proxy=false  │ ← прямой доступ
│  sub.example.com    A → IP  proxy=true   │ ← CF CDN скрывает IP
│  bot.example.com    A → IP  proxy=false  │ ← вебхуки
│                                          │
│  Если запись уже есть → PATCH (обновить) │
│  Если записи нет → POST (создать)        │
└───────────────┬──────────────────────────┘
                │
        ▼
┌──────────────────────────────────────────┐
│  4. Подождать DNS propagation            │
│     Проверять каждые 10 сек, до 5 мин    │
│     resolve_domain() == SERVER_IP ?      │
└───────────────┬──────────────────────────┘
                │ все записи подтверждены
        ▼
┌──────────────────────────────────────────┐
│  5. Запустить установку                  │
│     (домены уже валидны — pre-flight ✓)  │
└──────────────────────────────────────────┘
```

#### Реализация через curl + CF API v4

```bash
# Получить Zone ID по имени домена
cf_get_zone_id() {
    local domain="$1"  # example.com (корневой)
    curl -s "https://api.cloudflare.com/client/v4/zones?name=${domain}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
    | grep -oP '"id":"\K[^"]+' | head -1
}

# Создать или обновить A-запись
cf_upsert_record() {
    local zone_id="$1"
    local name="$2"     # vpn.example.com
    local ip="$3"       # 31.56.178.11
    local proxied="$4"  # true | false

    # Проверяем — запись уже существует?
    local record_id
    record_id=$(curl -s \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=A&name=${name}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
    | grep -oP '"id":"\K[^"]+' | head -1)

    local method="POST"
    local url="https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records"
    [[ -n "$record_id" ]] && {
        method="PATCH"
        url="${url}/${record_id}"
    }

    local result
    result=$(curl -s -X "$method" "$url" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${ip}\",\"ttl\":1,\"proxied\":${proxied}}")

    echo "$result" | grep -q '"success":true' \
        && info "DNS: ${name} → ${ip} (proxy=${proxied}) ✓" \
        || { error "Ошибка CF API для ${name}"; echo "$result"; return 1; }
}

# Полная автонастройка DNS для сервера
cf_setup_dns() {
    local root_domain="$1"   # example.com
    local server_ip="$2"     # 31.56.178.11

    section "Автонастройка DNS через Cloudflare"

    info "Получаю Zone ID для ${root_domain}..."
    local zone_id
    zone_id=$(cf_get_zone_id "$root_domain")
    [[ -z "$zone_id" ]] && { error "Домен ${root_domain} не найден в Cloudflare"; return 1; }
    info "Zone ID: ${zone_id}"

    # Создаём записи согласно конфигурации
    [[ -n "$NODE_DOMAIN"  ]] && cf_upsert_record "$zone_id" "$NODE_DOMAIN"  "$server_ip" "false"
    [[ -n "$PANEL_DOMAIN" ]] && cf_upsert_record "$zone_id" "$PANEL_DOMAIN" "$server_ip" "false"
    [[ -n "$SUB_DOMAIN"   ]] && cf_upsert_record "$zone_id" "$SUB_DOMAIN"   "$server_ip" "true"  # CF Proxy!
    [[ -n "$BOT_DOMAIN"   ]] && cf_upsert_record "$zone_id" "$BOT_DOMAIN"   "$server_ip" "false"

    # Ждём propagation
    info "Ожидаю обновления DNS (до 5 минут)..."
    local attempts=0
    while [[ $attempts -lt 30 ]]; do
        local resolved
        resolved=$(resolve_domain "$NODE_DOMAIN")
        if [[ "$resolved" == "$server_ip" ]]; then
            info "DNS обновился: ${NODE_DOMAIN} → ${server_ip} ✓"
            return 0
        fi
        sleep 10
        ((attempts++))
        echo -n "."
    done
    warn "DNS ещё не обновился — продолжаем, но проверь позже"
}
```

#### Что спрашивается у пользователя (с инструкциями)

```
[?] Настроить DNS автоматически через Cloudflare? (да/нет) [да]:

  ╔══════════════════════════════════════════════════════════════╗
  ║  Для автонастройки нужен Cloudflare API Token               ║
  ║                                                              ║
  ║  Как получить:                                               ║
  ║  1. Открой https://dash.cloudflare.com/profile/api-tokens   ║
  ║  2. Нажми "Create Token"                                     ║
  ║  3. Выбери шаблон "Edit zone DNS"                            ║
  ║  4. Zone Resources → Include → конкретный домен              ║
  ║  5. Нажми "Continue to summary" → "Create Token"            ║
  ║  6. Скопируй токен (показывается только один раз!)           ║
  ╚══════════════════════════════════════════════════════════════╝

  [?] Cloudflare API Token:
  > ********************************

  ╔══════════════════════════════════════════════════════════════╗
  ║  Корневой домен — это домен верхнего уровня без субдоменов  ║
  ║  Пример: если хочешь vpn.example.com → вводи example.com   ║
  ║  Домен должен быть добавлен в Cloudflare (не обязательно    ║
  ║  куплен там — можно делегировать NS от любого регистратора) ║
  ╚══════════════════════════════════════════════════════════════╝

  [?] Корневой домен (example.com):
  > example.com

  ✓ Домен найден в Cloudflare (Zone ID: abc123...)

  Автоматически создам субдомены:
    vpn.example.com    → 31.56.178.11  [DNS-only]   ← Reality/Xray
    panel.example.com  → 31.56.178.11  [DNS-only]   ← Remnawave
    sub.example.com    → 31.56.178.11  [CF Proxy ✓] ← Подписки
    bot.example.com    → 31.56.178.11  [DNS-only]   ← Bedolaga Bot

  [?] Подтвердить создание записей? (да/нет) [да]:
```

#### Префиксы субдоменов — настраиваемые

```bash
# Дефолты, но пользователь может изменить:
NODE_PREFIX="vpn"       # vpn.example.com
PANEL_PREFIX="panel"    # panel.example.com
SUB_PREFIX="sub"        # sub.example.com
BOT_PREFIX="bot"        # bot.example.com
```

#### CF API Token — минимальные права

Токен нужен только с правами `Zone:DNS:Edit` на конкретную зону — не `Global API Key`. Это безопасно: компрометация токена не даёт доступа к аккаунту CF.

---

### Дополнительные проверки при наличии домена

После успешной валидации A-записи скрипт опционально проверяет:

```bash
check_domain_extras() {
    local domain="$1"

    # Wildcard или CNAME — предупреждение
    local cname
    cname=$(dig +short CNAME "$domain" @1.1.1.1 2>/dev/null)
    [[ -n "$cname" ]] && warn "Домен ${domain} — это CNAME на ${cname}, не прямая A-запись"

    # Порт 80 доступен — нужен для certbot HTTP-01
    if ! timeout 3 bash -c "echo >/dev/tcp/${domain}/80" 2>/dev/null; then
        warn "Порт 80 закрыт на ${domain} — certbot HTTP-01 не сработает"
        warn "Открой порт 80 или используй DNS-01 валидацию"
    fi

    # Cloudflare proxy детект (TTL = 300 → Cloudflare proxy)
    local ttl
    ttl=$(dig +nocmd A "$domain" +noall +answer 2>/dev/null | awk '{print $2}')
    [[ "$ttl" == "300" ]] && warn "Похоже на Cloudflare Proxy (TTL=300) — Reality не будет работать. Переключи на DNS-only (серое облако)"
}
```

---

## Модули

## Конфигурационный паспорт (Pre-flight)

**Главное правило:** скрипт собирает и валидирует **все** необходимые данные **до** начала любой установки. Если хоть одна проверка не прошла — ничего не запускается.

### Порядок работы

```
Запуск модуля (например xray / remnawave / bedolaga)
        │
        ▼
┌───────────────────────────────────────────────────┐
│             PRE-FLIGHT CONFIGURATOR               │
│                                                   │
│  Шаг 1: Собрать все параметры                     │
│  ┌─────────────────────────────────────────────┐  │
│  │ [?] Домен ноды (vpn.*):                     │  │
│  │     → A-запись, DNS-only, Reality           │  │
│  │                                             │  │
│  │ [?] Домен панели (panel.*):   (если нужна)  │  │
│  │     → A-запись, DNS-only                    │  │
│  │                                             │  │
│  │ [?] Домен подписок (sub.*):   (если нужен)  │  │
│  │     → A или CNAME, CF Proxy разрешён        │  │
│  │     Где размещается SUB?                    │  │
│  │       1) На этом же сервере                 │  │
│  │       2) За Cloudflare (рекомендуется)      │  │
│  │       3) На отдельном сервере               │  │
│  │                                             │  │
│  │ [?] Домен бота (bot.*):       (если нужен)  │  │
│  │     → A-запись, DNS-only                    │  │
│  │                                             │  │
│  │ [?] Порт Xray [443]:                        │  │
│  │ [?] Кол-во пользователей [10]:              │  │
│  │ [?] Telegram Bot Token:       (если нужен)  │  │
│  └─────────────────────────────────────────────┘  │
│                                                   │
│  Шаг 2: Валидировать всё сразу                    │
│  ┌─────────────────────────────────────────────┐  │
│  │  vpn.example.com  → 31.56.178.11  [ ✓ / ✗ ]│  │
│  │  CF proxy выключен (TTL≠300)      [ ✓ / ✗ ]│  │
│  │  panel.example.com → 31.56.178.11 [ ✓ / ✗ ]│  │
│  │  sub.example.com  резолвится      [ ✓ / ✗ ]│  │
│  │  sub CF proxy — разрешён          [ ✓  OK  ]│  │
│  │  bot.example.com  → 31.56.178.11  [ ✓ / ✗ ]│  │
│  │  Порт 80 открыт (для certbot)     [ ✓ / ✗ ]│  │
│  │  Порт 443 свободен                [ ✓ / ✗ ]│  │
│  │  Docker установлен (если нужен)   [ ✓ / ✗ ]│  │
│  │  Telegram token валиден           [ ✓ / ✗ ]│  │
│  │  Remnawave API отвечает           [ ✓ / ✗ ]│  │
│  │  Место на диске ≥ 2GB             [ ✓ / ✗ ]│  │
│  │  RAM ≥ 512MB                      [ ✓ / ✗ ]│  │
│  └─────────────────────────────────────────────┘  │
│                                                   │
│  Шаг 3: Показать итоговую сводку                  │
│  ┌─────────────────────────────────────────────┐  │
│  │  Параметры установки:                       │  │
│  │    IP сервера:    31.56.178.11              │  │
│  │    Домен ноды:    vpn.example.com           │  │
│  │    Домен панели:  panel.example.com         │  │
│  │    Домен SUB:     sub.example.com  [CF ✓]  │  │
│  │    Домен бота:    bot.example.com           │  │
│  │    Порт Xray:     443                       │  │
│  │    Пользователей: 10                        │  │
│  │    WARP:          да                        │  │
│  │    TrafficGuard:  да                        │  │
│  │                                             │  │
│  │  Все проверки пройдены ✓                    │  │
│  │  [?] Начать установку? (да/нет):            │  │
│  └─────────────────────────────────────────────┘  │
│         │ нет                 │ да                │
│         ▼                     ▼                   │
│       выход              УСТАНОВКА                │
└───────────────────────────────────────────────────┘
```

### Что валидируется для каждого модуля

| Проверка | xray | remnawave panel | remnawave node | bedolaga |
|---|:---:|:---:|:---:|:---:|
| `vpn.*` домен → A → IP | рек. | — | рек. | — |
| `panel.*` домен → A → IP | — | **обяз.** | — | — |
| `sub.*` домен → A/CNAME | — | **обяз.** | — | — |
| `bot.*` домен → A → IP | — | — | — | **обяз.** |
| CF proxy выключен (TTL≠300) | **обяз.** | **обяз.**¹ | — | **обяз.** |
| CF proxy SUB — разрешён | — | ✅ OK | — | — |
| Порт 80 открыт (certbot) | рек. | **обяз.** | — | **обяз.** |
| Порт 443 свободен | **обяз.** | — | рек. | — |
| Docker установлен | — | **обяз.** | **обяз.** | **обяз.** |
| Remnawave Panel API | — | — | **обяз.** | **обяз.** |
| Telegram Bot Token | — | — | — | **обяз.** |
| Место ≥ 2GB | **обяз.** | **обяз.** | **обяз.** | **обяз.** |
| RAM ≥ 512MB | **обяз.** | **обяз.** | рек. | **обяз.** |

¹ `panel.*` DNS-only обязателен, `sub.*` CF proxy разрешён

### Валидация Telegram Bot Token

```bash
validate_telegram_token() {
    local token="$1"
    local result
    result=$(curl -s "https://api.telegram.org/bot${token}/getMe" --max-time 10)
    if echo "$result" | grep -q '"ok":true'; then
        local bot_name
        bot_name=$(echo "$result" | grep -oP '"username":"\K[^"]+')
        info "Telegram Bot Token валиден: @${bot_name}"
        return 0
    else
        error "Telegram Bot Token недействителен или бот не существует"
        return 1
    fi
}
```

### Валидация Remnawave API

```bash
validate_remnawave_api() {
    local api_url="$1"
    local api_key="$2"
    local result
    result=$(curl -s "${api_url}/api/health" \
        -H "Authorization: Bearer ${api_key}" \
        --max-time 10 -o /dev/null -w "%{http_code}")
    if [[ "$result" == "200" ]]; then
        info "Remnawave API доступен: ${api_url}"
        return 0
    else
        error "Remnawave API недоступен (HTTP ${result}): ${api_url}"
        error "Убедись что панель запущена и API ключ верен"
        return 1
    fi
}
```

### Сохранение конфига паспорта

После прохождения всех проверок конфиг сохраняется в `state/<server_ip>.conf` — при повторном запуске скрипт предлагает загрузить его, не спрашивая всё заново:

```bash
# state/31.56.178.11.conf
SERVER_IP="31.56.178.11"

# Домены
NODE_DOMAIN="vpn.example.com"        # A → этот IP, DNS-only (Reality)
PANEL_DOMAIN="panel.example.com"     # A → этот IP, DNS-only
SUB_DOMAIN="sub.example.com"         # A/CNAME → панель, CF Proxy OK
SUB_MODE="cloudflare"                # same_server | cloudflare | external
BOT_DOMAIN="bot.example.com"         # A → этот IP, DNS-only

# Установленные модули
INSTALLED_MODULES="sys xray proxy trafficguard warp"
INSTALLED_AT="2026-04-10T12:00:00"

# Конфигурация
XRAY_PORT="443"
SSH_PORT="2222"
CFG_WARP="yes"
```

---

## Система шагов и Resume

Установка любого модуля разбита на **именованные шаги**. После каждого шага состояние записывается в `state/<ip>-progress.conf`. Если скрипт прервался — при следующем запуске он предлагает продолжить с места остановки.

### Формат файла прогресса

```bash
# state/31.56.178.11-progress.conf
MODULE="xray"
STARTED_AT="2026-04-10T12:00:00"
UPDATED_AT="2026-04-10T12:03:45"

# Каждый шаг: pending | running | done | failed
STEP_preflight="done"
STEP_install_deps="done"
STEP_install_xray="done"
STEP_generate_keys="done"
STEP_generate_users="failed"   # ← здесь прервалось
STEP_create_config="pending"
STEP_create_service="pending"
STEP_install_warp="pending"
STEP_setup_nginx="pending"
STEP_setup_firewall="pending"
STEP_setup_ssh="pending"
STEP_setup_fail2ban="pending"
STEP_setup_trafficguard="pending"
STEP_finalize="pending"
```

### Движок шагов

```bash
# В orchestra.sh

PROGRESS_FILE=""   # устанавливается при старте модуля

step_status() {
    local step="$1"
    grep -oP "(?<=STEP_${step}=\")[^\"]+" "$PROGRESS_FILE" 2>/dev/null || echo "pending"
}

run_step() {
    local step="$1"
    local func="$2"
    local desc="$3"

    local status
    status=$(step_status "$step")

    # Уже выполнен — пропускаем
    if [[ "$status" == "done" ]]; then
        echo -e "  ${G}[✓ уже выполнен]${N} ${desc}"
        return 0
    fi

    echo -e "\n  ${C}[→]${N} ${desc}..."
    # Помечаем как running
    sed -i "s/STEP_${step}=.*/STEP_${step}=\"running\"/" "$PROGRESS_FILE"
    sed -i "s/UPDATED_AT=.*/UPDATED_AT=\"$(date -u +%FT%T)\"/" "$PROGRESS_FILE"

    # Выполняем
    if $func; then
        sed -i "s/STEP_${step}=.*/STEP_${step}=\"done\"/" "$PROGRESS_FILE"
        echo -e "  ${G}[✓]${N} ${desc}"
    else
        sed -i "s/STEP_${step}=.*/STEP_${step}=\"failed\"/" "$PROGRESS_FILE"
        echo -e "  ${R}[✗]${N} ${desc} — ОШИБКА"
        error "Установка прервана на шаге: ${step}"
        error "Для продолжения запусти скрипт снова"
        exit 1
    fi
}
```

### Пример: шаги модуля xray

```bash
full_install_xray() {
    PROGRESS_FILE="$STATE_DIR/${SERVER_IP}-progress.conf"
    init_progress "xray"   # создаёт файл если нет

    # Проверяем незавершённую установку
    check_resume_prompt

    run_step "preflight"         validate_all_inputs      "Проверка конфигурации"
    run_step "install_deps"      install_deps             "Установка зависимостей"
    run_step "install_xray"      install_xray             "Установка Xray"
    run_step "generate_keys"     generate_xray_keys       "Генерация ключей Reality"
    run_step "generate_users"    generate_users           "Генерация пользователей"
    run_step "create_config"     create_xray_config       "Создание конфига Xray"
    run_step "create_service"    create_xray_service      "Systemd сервис"
    run_step "install_warp"      install_warp             "Cloudflare WARP"
    run_step "setup_nginx"       setup_nginx              "Nginx decoy сайт"
    run_step "setup_ssl"         setup_ssl                "SSL сертификат (certbot)"
    run_step "setup_firewall"    setup_firewall           "Файрвол UFW"
    run_step "setup_ssh"         setup_ssh                "SSH порт"
    run_step "setup_fail2ban"    setup_fail2ban           "fail2ban"
    run_step "setup_sysctl"      setup_sysctl             "Оптимизация sysctl"
    run_step "setup_tguard"      install_trafficguard     "TrafficGuard"
    run_step "setup_cron"        setup_cron               "Cron задачи"
    run_step "finalize"          show_result              "Итог установки"

    mark_module_done "xray"
}
```

### Диалог при прерванной установке

```
╔══════════════════════════════════════════════════╗
║  Обнаружена незавершённая установка (xray)       ║
║  Начата: 2026-04-10 12:00:00                     ║
║                                                  ║
║  Выполнено:                                      ║
║    ✓ Проверка конфигурации                       ║
║    ✓ Установка зависимостей                      ║
║    ✓ Установка Xray                              ║
║    ✓ Генерация ключей Reality                    ║
║    ✗ Генерация пользователей  ← прервалось здесь ║
║    · Создание конфига Xray                       ║
║    · ... (ещё 10 шагов)                          ║
║                                                  ║
║  [1] Продолжить с места остановки                ║
║  [2] Начать заново (сбросить прогресс)           ║
║  [0] Отмена                                      ║
╚══════════════════════════════════════════════════╝
```

### Визуальный прогресс во время установки

```
════════════════════════════════════════
 Установка Xray — шаг 5 из 17
════════════════════════════════════════
  ✓ Проверка конфигурации
  ✓ Установка зависимостей
  ✓ Установка Xray
  ✓ Генерация ключей Reality
  → Генерация пользователей...
  · Создание конфига Xray
  · Systemd сервис
  · Cloudflare WARP
  · ...
```

---

### `sys.sh` — Базовая настройка системы

Всегда выполняется первым на любом новом сервере.

| Что делает | Детали |
|---|---|
| SSH hardening | Смена порта, отключение парольной авторизации, только pubkey |
| UFW | deny in, allow out, whitelist нужных портов |
| fail2ban | SSH + Xray jail, бан 7 дней, whitelist IP администратора |
| BBR | `net.ipv4.tcp_congestion_control=bbr` + `fq` qdisc |
| Unattended-upgrades | Только security patches, авторебут по расписанию |
| sysctl оптимизация | Файловые дескрипторы, буферы сети, TIME_WAIT |
| NTP | chrony для точной синхронизации времени |
| Logrotate | Ротация `/var/log/xray/` и `/var/log/orchestra/` |
| IPv6 | Опциональное отключение |

---

### `xray.sh` — VLESS + Reality + XHTTP

Перенос рабочей логики из `vpn-setup.sh`.

| Что делает | Детали |
|---|---|
| Установка Xray | Последняя версия с GitHub, systemd сервис |
| Ключи Reality | `xray x25519`, приватный + публичный |
| Пользователи | UUID + shortId (openssl rand -hex 4), N штук |
| Конфиг | XHTTP mode auto, WARP outbound, decoy dest |
| Ссылки | VLESS URI, принудительный IPv4 (curl -4) |
| Автообновление | Cron 04:00, проверка новой версии на GitHub |

---

### `remnawave.sh` — Panel + Node

| Режим | Что делает |
|---|---|
| **Panel** | Docker + PostgreSQL + Redis + backend, генерация JWT/secrets, nginx reverse proxy, сохранение credentials |
| **Node** | Docker + контейнер ноды, SECRET_KEY от пользователя, регистрация в `fleet/nodes.conf` |

---

### `bedolaga.sh` — Telegram-бот продажи подписок

> Источник: [BEDOLAGA-DEV/remnawave-bedolaga-telegram-bot](https://github.com/BEDOLAGA-DEV/remnawave-bedolaga-telegram-bot)  
> Лицензия: MIT + Commons Clause — можно использовать для своего бизнеса, нельзя перепродавать сам бот.

**Что делает:**

Полноценная B2C платформа продажи VPN-подписок через Telegram.  
Интегрируется с Remnawave Panel по REST API — создаёт пользователей, выдаёт подписки, следит за трафиком.

**Поддерживаемые платёжные системы (15+):**

| Группа | Системы |
|---|---|
| Telegram | Telegram Stars |
| Российские | YooKassa, CloudPayments, Freekassa, SberPay, RioPay, SeverPay, Pal24 |
| Крипта | CryptoBot, Heleket, Mulenpay, Wata |

**Ключевые возможности:**

| Функция | Детали |
|---|---|
| Продажа подписок | Тарифы, пробный период (trial), автопродление |
| Баланс пользователя | Единый счёт, пополнение любым методом |
| Промокоды | Скидки, бонусные дни, trial-коды |
| Реферальная программа | % с продаж рефералов, вывод средств |
| Поддержка | Тикет-система, SLA 24ч |
| Уведомления | Напоминания о продлении за 3 дня |
| Рассылки | Сегментированные broadcast-сообщения |
| Статистика | Трафик, баланс, история платежей |
| Мини-приложение | Web-кабинет пользователя (React) |
| Игры | Ежедневные конкурсы и призы (опционально) |
| Локализация | RU, EN, UK, ZH, FA |
| Бэкапы | Автоматические, по расписанию cron |

**Инфраструктура бота:**

```
bedolaga-bot      (Python 3.13 async, aiogram)  — порт 8080
bedolaga-db       (PostgreSQL 15)               — внутренний
bedolaga-redis    (Redis 7)                     — внутренний
```

**Требования для установки:**
- Работающая Remnawave Panel с API ключом
- Домен с SSL (для вебхуков платёжных систем)
- Telegram Bot Token от @BotFather
- Опционально: аккаунты в платёжных системах

**Что генерирует скрипт автоматически:**
- `WEB_API_DEFAULT_TOKEN` — `openssl rand -hex 32`
- `CABINET_JWT_SECRET` — `openssl rand -hex 32`
- `REMNAWAVE_WEBHOOK_SECRET` — `openssl rand -hex 32`
- PostgreSQL пароль — `openssl rand -hex 24`

---

### `proxy.sh` — Reverse proxy

Два варианта на выбор:

| | Nginx | Caddy |
|---|---|---|
| SSL | certbot + Let's Encrypt | Автоматический |
| Конфиг | `sites-available/` | `Caddyfile` |
| Upstream | `proxy_pass 127.0.0.1:3000` | `reverse_proxy localhost:3000` |
| Decoy шаблон | 5 случайных шаблонов сайтов | То же |

---

### `trafficguard.sh` — Блокировка сканеров

| Что делает | Детали |
|---|---|
| Установка | Бинарь `traffic-guard`, auto-detect архитектуры |
| Источники | `antiscanner.list` + `government_networks.list` |
| Интеграция | iptables + ipset + UFW |
| Обновление | Cron каждый час |
| Статистика | CSV: IP / ASN / netname / счётчик / последний раз |

---

### `warp.sh` — Cloudflare WARP

| Что делает | Детали |
|---|---|
| Установка | `cloudflare-warp` пакет |
| Подключение | `warp-cli register` + `warp-cli connect` |
| Outbound | SOCKS5 на `127.0.0.1:40000` |
| Проверка | `curl --socks5 127.0.0.1:40000 ifconfig.me` |
| Альтернатива | `wgcf` — WireGuard конфиг от WARP |

---

### `backup.sh` — Резервные копии

**Что бэкапит:**

```
/etc/xray/              — конфиги и ключи Xray
/opt/remnawave/.env     — секреты панели
PostgreSQL dump         — через docker exec
state/*.conf            — состояние флота
fleet/nodes.conf        — реестр нод
```

**Куда:**

| Хранилище | Детали |
|---|---|
| Локально | `/opt/orchestra/backups/` |
| Telegram | Bot API, split по 49 МБ |
| S3 / rclone | Опционально |

**Принципы (из distillium/remnawave-backup-restore):**
- Safety backup автоматически создаётся перед любым `restore`
- Проверка версии перед восстановлением
- Retention policy: хранить не более N бэкапов

---

### `monitor.sh` — Мониторинг и проверка блокировок

Семь уровней проверки каждой ноды:

```
Уровень 1  ICMP ping           живой ли сервер
Уровень 2  TCP :443            порт открыт снаружи
Уровень 3  TLS handshake       Xray отвечает (curl --resolve SNI)
Уровень 4  HTTP decoy          сайт-легенда отдаёт 200
Уровень 5  ipregion.sh -j      ASN + ISP + страна (17 GeoIP источников)
Уровень 6  checker.sh          Netflix/YouTube не блокируют IP
Уровень 7  zapret-info         IP входит в реестр РКН (выгрузка)
```

**Вывод fleet monitor:**

```
╔═══════════════╦══════╦══════╦═════╦══════════════╦═════╗
║ Node          ║ Ping ║ :443 ║ TLS ║ ASN / ISP    ║ RKN ║
╠═══════════════╬══════╬══════╬═════╬══════════════╬═════╣
║ 31.56.178.11  ║  ✓   ║  ✓   ║  ✓  ║ AS56971/CGI  ║  ✓  ║
║ 31.58.137.10  ║  ✓   ║  ✓   ║  ✓  ║ AS56971/CGI  ║  ✓  ║
╚═══════════════╩══════╩══════╩═════╩══════════════╩═════╝
```

**Глубокая диагностика одной ноды:**

```bash
orchestra diag 31.56.178.11
# запускает ipregion.sh + checker.sh + полный отчёт
```

---

## Схемы процессов

### Локальный режим

```
Запуск: bash orchestra.sh
            │
            ▼
    ┌───────────────┐
    │  check_root   │ ── нет root ──► exit
    └───────┬───────┘
            │
    ┌───────▼───────┐
    │  load_state   │  читает /opt/orchestra/state/local.conf
    └───────┬───────┘
            │
    ┌───────▼────────────────┐
    │      main_menu         │
    │  ┌─────────────────┐   │
    │  │ 1) sys          │   │
    │  │ 2) xray         │   │
    │  │ 3) remnawave    │   │
    │  │ 4) proxy        │   │
    │  │ 5) warp         │   │
    │  │ 6) trafficguard │   │
    │  │ 7) backup       │   │
    │  │ 8) fleet        │   │
    │  │ 9) monitor      │   │
    │  └─────────────────┘   │
    └───────┬────────────────┘
            │  выбор модуля
            ▼
    ┌───────────────┐
    │  load lib/    │  source lib/sys.sh / xray.sh / ...
    │  module.sh    │
    └───────┬───────┘
            │
            ▼
    ┌───────────────┐
    │  run module   │  выполняет функции модуля
    │  function()   │
    └───────┬───────┘
            │
    ┌───────▼───────┐
    │  save_state   │  обновляет state/local.conf
    └───────┬───────┘
            │
            ▼
       main_menu  (возврат)
```

---

### Удалённый режим

```
Запуск: orchestra remote 31.58.137.10 sys
            │
            ▼
    ┌────────────────────┐
    │  load fleet config │  читает fleet/nodes.conf
    │  найти 31.58.137.10│
    └────────┬───────────┘
             │
    ┌────────▼───────────┐
    │  SSH connect       │
    │  ssh -p 2222       │
    │  -i credentials/   │
    │  root@31.58.137.10 │
    └────────┬───────────┘
             │  соединение установлено
             ▼
    ┌────────────────────┐
    │  upload module     │  scp lib/sys.sh → /tmp/orch_sys.sh
    └────────┬───────────┘
             │
    ┌────────▼───────────┐
    │  execute remote    │  ssh "bash /tmp/orch_sys.sh --auto"
    │  (non-interactive) │
    └────────┬───────────┘
             │  вывод в реальном времени (tee)
             ▼
    ┌────────────────────┐
    │  save remote state │  записывает state/31.58.137.10.conf
    └────────┬───────────┘
             │
    ┌────────▼───────────┐
    │  cleanup           │  rm /tmp/orch_sys.sh на ноде
    └────────────────────┘
```

---

### Fleet-режим

```
Запуск: orchestra fleet deploy xray
            │
            ▼
    ┌────────────────────────┐
    │  parse nodes.conf      │
    │  ┌────────────────┐    │
    │  │ node-01: xray  │    │
    │  │ node-02: rw    │    │
    │  │ node-03: xray  │    │
    │  └────────────────┘    │
    └────────┬───────────────┘
             │  для каждой ноды параллельно
             ▼
    ┌────────────────────────────────────────────┐
    │                                            │
  node-01                node-02             node-03
  SSH connect           SSH connect         SSH connect
      │                     │                   │
  upload xray.sh        upload xray.sh      upload xray.sh
      │                     │                   │
  execute --auto        execute --auto      execute --auto
      │                     │                   │
  save state            save state          save state
      │                     │                   │
    done                  done                done
    │                     │                   │
    └─────────────────────┴───────────────────┘
                          │
                  ┌───────▼────────┐
                  │ fleet summary  │
                  │ node-01: ✓ OK  │
                  │ node-02: ✓ OK  │
                  │ node-03: ✗ FAIL│
                  └────────────────┘
```

---

### Мониторинг нод

```
Запуск: orchestra fleet monitor
            │
            ▼
    ┌────────────────────┐
    │  load nodes.conf   │
    └────────┬───────────┘
             │  для каждой ноды
             ▼
    ╔════════════════════════════════════════╗
    ║         Проверка одной ноды            ║
    ╠════════════════════════════════════════╣
    ║                                        ║
    ║  L1: ping <ip>          ──► ✓ / ✗     ║
    ║         │ ✗                            ║
    ║         └──► ALERT: сервер недоступен  ║
    ║                                        ║
    ║  L2: nc -z <ip> 443     ──► ✓ / ✗     ║
    ║         │ ✗                            ║
    ║         └──► ALERT: порт закрыт        ║
    ║                                        ║
    ║  L3: curl --resolve     ──► ✓ / ✗     ║
    ║       SNI:443:<ip>                     ║
    ║         │ ✗                            ║
    ║         └──► ALERT: Xray не отвечает   ║
    ║                                        ║
    ║  L4: curl http://<ip>   ──► 200 / ?   ║
    ║         │ ✗                            ║
    ║         └──► ALERT: decoy сломан       ║
    ║                                        ║
    ║  L5: ipregion.sh -j -i <ip>           ║
    ║       ──► ASN / ISP / страна           ║
    ║         │ country = RU                 ║
    ║         └──► WARN: IP определяется     ║
    ║              как российский            ║
    ║                                        ║
    ║  L6: checker.sh (опционально)          ║
    ║       ──► Netflix/YouTube блок?        ║
    ║         │ blocked                      ║
    ║         └──► WARN: IP в blacklist CDN  ║
    ║                                        ║
    ║  L7: zapret-info lookup               ║
    ║       ──► IP в реестре РКН?           ║
    ║         │ found                        ║
    ║         └──► ALERT: IP заблокирован!   ║
    ║                                        ║
    ╚════════════════════════════════════════╝
             │
             ▼
    ┌────────────────────┐
    │  итоговая таблица  │  (все ноды)
    └────────┬───────────┘
             │  если есть ALERT
             ▼
    ┌────────────────────┐
    │  уведомление       │  Telegram Bot API
    │  в Telegram        │
    └────────────────────┘
```

---

### Установка Remnawave

```
Выбор: remnawave_menu
            │
     ┌──────┴──────┐
     │             │
  Panel mode    Node mode
     │             │
     ▼             ▼
install_docker  install_docker
     │             │
     ▼             ▼
спросить        спросить
домен           panel_url
                + SECRET_KEY
     │             │
     ▼             ▼
скачать         создать
docker-compose  docker-compose
prod.yml        для ноды
     │             │
     ▼             ▼
генерировать    записать .env
JWT, PG_PASS,   (SECRET_KEY,
secrets         NODE_PORT)
     │             │
     ▼             ▼
настроить       открыть
nginx proxy     порт в UFW
     │             │
     ▼             ▼
docker          docker
compose up -d   compose up -d
     │             │
     ▼             ▼
сохранить       добавить ноду
credentials     в nodes.conf
     │             │
     └──────┬──────┘
            ▼
    show_result()
    ┌─────────────────────────┐
    │ Remnawave установлена   │
    │ URL: http://domain      │
    │ Creds: state/creds.txt  │
    │ Следующий шаг: certbot  │
    └─────────────────────────┘
```

---

### Установка Bedolaga Bot

```
Запуск: bedolaga_install
            │
            ▼
    ┌────────────────────────────────────┐
    │  Предварительные проверки          │
    │  ┌─────────────────────────────┐   │
    │  │ Docker установлен?          │   │
    │  │ Remnawave Panel запущена?   │   │
    │  │ Домен указывает на сервер?  │   │
    │  └─────────────────────────────┘   │
    └────────┬───────────────────────────┘
             │  всё OK
             ▼
    ┌────────────────────────────────────┐
    │  Интерактивный конфигуратор        │
    │                                    │
    │  [?] Telegram Bot Token:           │
    │  [?] Admin Telegram ID(s):         │
    │  [?] Домен бота (bot.example.com): │
    │  [?] Remnawave API URL:            │
    │  [?] Remnawave API Key:            │
    │                                    │
    │  Платёжные системы:                │
    │  [?] Telegram Stars? (да/нет)      │
    │  [?] YooKassa? (да/нет)            │
    │    └─► Shop ID + API Key           │
    │  [?] CryptoBot? (да/нет)           │
    │    └─► API Token                   │
    │  [?] Другие? (пропустить)          │
    └────────┬───────────────────────────┘
             │
             ▼
    ┌────────────────────────────────────┐
    │  Генерация секретов                │
    │  WEB_API_TOKEN    = rand-hex 32    │
    │  JWT_SECRET       = rand-hex 32    │
    │  WEBHOOK_SECRET   = rand-hex 32    │
    │  POSTGRES_PASS    = rand-hex 24    │
    └────────┬───────────────────────────┘
             │
             ▼
    ┌────────────────────────────────────┐
    │  Создание /opt/bedolaga/.env       │
    │  (все переменные, chmod 600)       │
    └────────┬───────────────────────────┘
             │
             ▼
    ┌────────────────────────────────────┐
    │  git clone репозитория             │
    │  (или скачать release архив)       │
    └────────┬───────────────────────────┘
             │
             ▼
    ┌────────────────────────────────────┐
    │  Настройка nginx reverse proxy     │
    │  bot.example.com → 127.0.0.1:8080 │
    │  + certbot SSL                     │
    └────────┬───────────────────────────┘
             │
             ▼
    ┌────────────────────────────────────┐
    │  docker compose up -d              │
    │  (bot + PostgreSQL + Redis)        │
    └────────┬───────────────────────────┘
             │  ждём health check
             ▼
    ┌────────────────────────────────────┐
    │  Проверка: GET /health → 200?      │──✗──► WARN + показать логи
    └────────┬───────────────────────────┘
             │ ✓
             ▼
    ┌────────────────────────────────────┐
    │  Настройка Telegram webhook        │
    │  (автоматически через Bot API)     │
    └────────┬───────────────────────────┘
             │
             ▼
    ╔════════════════════════════════════╗
    ║  ✓ Bedolaga Bot установлен!        ║
    ║                                    ║
    ║  Бот:     @your_bot               ║
    ║  Панель:  https://bot.example.com ║
    ║  Creds:   state/bedolaga-creds.txt║
    ║                                    ║
    ║  Следующие шаги:                   ║
    ║  1) Открой бота в Telegram         ║
    ║  2) /start → создай тарифы         ║
    ║  3) Настрой платёжные системы      ║
    ║  4) Подключи Remnawave в настройках║
    ╚════════════════════════════════════╝
```

---

### Полный стек (все компоненты вместе)

```
┌─────────────────────────────────────────────────────────────────┐
│                    ПОЛНАЯ ИНФРАСТРУКТУРА                        │
└─────────────────────────────────────────────────────────────────┘

  Cloudflare DNS
  ├── vpn.example.com    ──[DNS-only]──► Node server :443
  ├── panel.example.com  ──[DNS-only]──► Panel server :3000
  ├── sub.example.com    ──[CF Proxy]──► CF CDN ──► Panel :3010  ← скрыт!
  └── bot.example.com    ──[DNS-only]──► Panel server :8080

  ┌──────────────────────────────────────────┐
  │           Panel Server                   │
  │  sys.sh    ← hardening, BBR, sysctl      │
  │  nginx     ← SSL, reverse proxy          │
  │    ├── panel.example.com → :3000         │
  │    ├── sub.example.com   → :3010         │
  │    └── bot.example.com   → :8080         │
  │  remnawave ← Panel + PostgreSQL + Redis  │
  │  bedolaga  ← Bot + PostgreSQL + Redis    │
  │  trafficguard ← блокировка сканеров      │
  └──────────────────────────────────────────┘

  ┌──────────────────────────────────────────┐
  │           Node Server 1                  │
  │  sys.sh    ← hardening, BBR, sysctl      │
  │  xray      ← VLESS + Reality + XHTTP :443│
  │    └── dest: vpn.example.com (decoy)     │
  │  warp      ← WARP SOCKS5 outbound        │
  │  trafficguard ← блокировка сканеров      │
  └──────────────────────────────────────────┘

  ┌──────────────────────────────────────────┐
  │           Node Server 2                  │
  │  sys.sh    ← hardening                   │
  │  remnawave-node ← Docker node agent      │
  │  warp      ← WARP outbound               │
  │  trafficguard                            │
  └──────────────────────────────────────────┘

  Поток данных:
  Клиент ──► sub.example.com [CF] ──► Panel ──► Получил конфиг
  Клиент ──► vpn.example.com :443  ──► Xray  ──► Интернет (через WARP)
  Клиент ──► Telegram Bot          ──► Bedolaga ──► Remnawave API
                                                  └──► Выдал подписку
```

---

### Резервное копирование

```
Запуск: backup_menu
            │
     ┌──────┴──────────────┐
     │                     │
  backup now           restore
     │                     │
     ▼                     ▼
что бэкапить?        выбрать бэкап
┌───────────┐        из списка
│ xray conf │             │
│ rw .env   │        ┌────▼──────────────┐
│ pg dump   │        │ safety backup NOW │
│ state/    │        │ (перед restore)   │
└─────┬─────┘        └────┬──────────────┘
      │                   │
      ▼                   ▼
tar + gzip          проверить версию
      │             совместимости
      ▼                   │ несовместима
куда сохранить?     └──► WARN + confirm
┌────────────┐            │
│ local      │            ▼
│ telegram   │      docker compose down
│ s3/rclone  │      распаковать архив
└─────┬──────┘      docker compose up
      │                   │
      ▼                   ▼
retention policy    verify health
удалить старые      (curl /health)
      │
      ▼
уведомление
в Telegram
(файл ≤ 49MB,
 иначе split)
```

---

## Fleet — формат конфига

**`fleet/nodes.conf`:**

```ini
[node-01]
host        = 31.56.178.11
port        = 2222
user        = root
role        = xray
key         = /opt/orchestra/fleet/credentials/node-01.key
installed   = 2026-04-10
xray_ver    = 26.3.27
last_check  = 2026-04-10T12:00:00
status      = ok

[node-02]
host        = 31.58.137.10
port        = 2222
user        = root
role        = remnawave-node
key         = /opt/orchestra/fleet/credentials/node-02.key
installed   = 2026-04-10
rw_ver      = 2026.3.846.0
panel_url   = https://panel.example.com
last_check  = 2026-04-10T12:00:00
status      = ok
```

**Доступные команды fleet:**

```bash
orchestra fleet status                    # статус всех нод (таблица)
orchestra fleet monitor                   # проверка блокировок L1-L7
orchestra fleet deploy <node> <module>    # задеплоить модуль на ноду
orchestra fleet deploy all xray           # деплой на все ноды с role=xray
orchestra fleet update-all               # обновить Xray/Remnawave на всех
orchestra fleet backup <node>             # бэкап конкретной ноды
orchestra fleet add                       # мастер добавления новой ноды
orchestra diag <ip>                       # глубокая диагностика ноды
```

---

## Главное меню

```
╔══════════════════════════════════════════╗
║       Orchestra — VPN Fleet Manager      ║
╠══════════════════════════════════════════╣
║  ── Текущий сервер ──                    ║
║  1) Базовая настройка системы            ║
║  2) VLESS + Reality + XHTTP              ║
║  3) Remnawave (panel / node)             ║
║  4) Bedolaga Bot (продажа подписок)      ║
║  5) Reverse proxy (nginx / caddy)        ║
║  ── Сервисы ──                           ║
║  6) Cloudflare WARP                      ║
║  7) TrafficGuard                         ║
║  8) Резервные копии                      ║
║  ── Флот ──                              ║
║  9) Управление нодами (fleet)            ║
║  10) Мониторинг и проверка блокировок    ║
║  0) Выход                                ║
╚══════════════════════════════════════════╝
```

### Подменю Bedolaga Bot

```
╔══════════════════════════════════════════╗
║       Bedolaga — Продажа подписок        ║
╠══════════════════════════════════════════╣
║  1) Установить бота                      ║
║  2) Статус (docker compose ps)           ║
║  3) Просмотр логов                       ║
║  4) Управление платёжными системами      ║
║  5) Обновить бота (git pull + rebuild)   ║
║  6) Удалить бота                         ║
║  0) Назад                                ║
╚══════════════════════════════════════════╝
```

---

## UX-принципы: инструкции на каждом шаге

Каждый запрос нетривиальных данных сопровождается контекстной подсказкой в рамке. Пользователь никогда не должен гадать откуда что взять.

### Шаблон подсказки

```bash
hint() {
    # Выводит контекстную подсказку перед вопросом
    echo -e "\n${B}╔══════════════════════════════════════════════════════╗${N}"
    while IFS= read -r line; do
        printf "${B}║${N}  %-52s${B}║${N}\n" "$line"
    done <<< "$1"
    echo -e "${B}╚══════════════════════════════════════════════════════╝${N}"
}
```

### Примеры подсказок для каждого параметра

| Параметр | Подсказка |
|---|---|
| **SSH порт** | Порт по умолчанию 22. Меняем чтобы снизить брутфорс. Запомни новый порт — без него не подключишься |
| **Домен** | Нужна A-запись на IP этого сервера. CF proxy должен быть выключен (серое облако) |
| **CF API Token** | dash.cloudflare.com → Profile → API Tokens → Create Token → Edit zone DNS |
| **Telegram Bot Token** | Напиши @BotFather → /newbot → скопируй токен формата 123456:ABC-DEF |
| **Admin Telegram ID** | Напиши @userinfobot — он ответит твой ID. Можно несколько через запятую |
| **Remnawave API Key** | Панель Remnawave → Settings → API Tokens → Create Token |
| **YooKassa Shop ID** | yookassa.ru → Настройки магазина → shopId |
| **CF Zone Domain** | Домен верхнего уровня без субдоменов: если нужен vpn.site.com — вводи site.com |
| **SNI для Reality** | Легитимный сайт с TLS 1.3. Рекомендуем www.microsoft.com |
| **WARP** | Cloudflare WARP скрывает IP сервера при исходящих соединениях. Рекомендуется |

### Цветовая схема подсказок

```
[?] cyan    — вопрос, ожидаем ввод
[✓] green   — успех, шаг выполнен
[!] yellow  — предупреждение, можно продолжить
[✗] red     — ошибка, нужно исправить
[→] white   — текущий выполняемый шаг
[·] grey    — ожидающий шаг
╔══╗ blue   — информационная рамка / подсказка
```

---

## Технические принципы

| Принцип | Источник | Реализация |
|---|---|---|
| Idempotent ops | Все репо | Проверка состояния до любого действия |
| Credential export | DigneZzZ | `state/<ip>-creds.txt`, chmod 600 |
| Multi-mirror download | eGamesAPI | jsDelivr → raw.github → ghproxy |
| Safety backup before restore | distillium | Авто-бэкап до любого restore |
| Unix socket vs TCP | eGamesAPI | Nginx → Xray через socket |
| BBR + sysctl | eGamesAPI | Обязательная оптимизация сети |
| Arch auto-detect | traffic-guard | `uname -m` → правильный бинарь |
| Log rate limiting | traffic-guard | 10 пакетов/мин, не спамить логи |
| Telegram split 49MB | DigneZzZ | `split` для больших бэкапов |
| Decoy templates | DigneZzZ selfsteal | 5+ шаблонов сайтов-легенд |
| IPv4-first | собственный опыт | `curl -4s` для генерации ссылок |
| SIGPIPE fix | собственный опыт | `openssl rand -hex 4` вместо `tr \| head` |
| JSON мониторинг | bench.gig.ovh | `ipregion.sh -j` для парсинга |
| Consensus geo | bench.gig.ovh | 17 GeoIP источников, голосование |

---

## Источники методик

| Репозиторий | Что берём |
|---|---|
| [eGamesAPI/remnawave-reverse-proxy](https://github.com/eGamesAPI/remnawave-reverse-proxy) | nginx + unix socket, BBR, multi-mirror CDN, decoy шаблоны |
| [DigneZzZ/remnawave-scripts](https://github.com/DigneZzZ/remnawave-scripts) | Docker deploy, credential export, Caddy, WARP/Tor менеджер, backup система |
| [distillium/remnawave-backup-restore](https://github.com/distillium/remnawave-backup-restore) | Safety backup, retention policy, версионность, Telegram доставка |
| [legiz-ru/my-remnawave](https://github.com/legiz-ru/my-remnawave) | Subscription templates, multi-client конфиги |
| [dotX12/traffic-guard](https://github.com/dotX12/traffic-guard) | iptables + ipset, arch auto-detect, WHOIS/ASN аналитика |
| [bench.gig.ovh](https://bench.gig.ovh) | `ipregion.sh -j` (17 GeoIP), `checker.sh` (CDN репутация) |
| [BEDOLAGA-DEV/remnawave-bedolaga-telegram-bot](https://github.com/BEDOLAGA-DEV/remnawave-bedolaga-telegram-bot) | Telegram-биллинг, 15+ платёжных систем, auto-renewal, referral |

---

## Порядок разработки

```
Этап 1 — Скелет
  ├── orchestra.sh (точка входа, загрузка модулей, меню)
  ├── fleet/nodes.conf (формат и парсер)
  └── state/ (read/write состояния)

Этап 2 — Системная база
  └── lib/sys.sh (hardening, BBR, sysctl, fail2ban, UFW, NTP)
      Включает финальный sysctl.conf:
      - ip_forward = 1 (для WARP)
      - rp_filter = 2 (loose, совместимо с WARP)
      - tcp_fack удалён (нет в ядре 4.20+)
      - tcp_ecn = 2 (безопасный режим)
      - swappiness = 10

Этап 3 — Xray модуль
  └── lib/xray.sh (перенос vpn-setup.sh, IPv4-first)

Этап 4 — Мониторинг
  └── lib/monitor.sh (L1-L7 проверки, ipregion.sh, zapret)

Этап 5 — Remnawave
  └── lib/remnawave.sh (panel + node, docker-compose)

Этап 6 — Bedolaga Bot  ← НОВЫЙ ЭТАП
  └── lib/bedolaga.sh
      - Конфигуратор (токен, admin IDs, домен, API key, платёжки)
      - Генерация секретов (openssl rand)
      - git clone + .env сборка
      - nginx vhost для bot.domain.com
      - certbot SSL
      - docker compose up -d
      - health check polling
      - Telegram webhook регистрация

Этап 7 — Сервисы
  ├── lib/proxy.sh (nginx/caddy)
  ├── lib/warp.sh
  └── lib/trafficguard.sh

Этап 8 — Резервные копии
  └── lib/backup.sh
      - Покрывает: xray, remnawave, bedolaga (все три DB)
      - local + telegram + s3

Этап 9 — Fleet-режим
  └── Удалённый деплой, параллельное выполнение, fleet summary
```

---

## Важные ограничения Bedolaga

| Аспект | Детали |
|---|---|
| **Лицензия** | MIT + Commons Clause — нельзя перепродавать сам бот как сервис |
| **Зависимость** | Требует работающую Remnawave Panel (не автономен) |
| **Домен** | Обязателен для вебхуков платёжных систем (HTTPS) |
| **Python** | Версия строго 3.13 (контейнер включает) |
| **Первый запуск** | ~60 секунд на старт PostgreSQL + Redis + миграции |
| **Платёжки** | Каждую нужно регистрировать отдельно на их стороне |

---

*Версия плана: 1.0 — 2026-04-10*
