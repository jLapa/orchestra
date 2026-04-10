# Orchestra — Брифинг для новой сессии

> Этот документ — полный контекст проекта для передачи в новую сессию Claude.  
> Читай внимательно — здесь всё что нужно чтобы продолжить без потери контекста.

---

## 1. Что уже сделано и работает

### Продакшн сервер — 31.56.178.11
- **SSH:** порт 2222, пользователь root, пароль `j_QEndsseZ3O0TQOC`
- **Xray 26.3.27** — работает, VLESS + Reality + XHTTP, порт 443
- **Reality SNI:** www.microsoft.com
- **Путь XHTTP:** /xray
- **Публичный ключ Reality:** `Qc-zwPirdJbuQedu7m3NjrJJSKuUB0cWaQDl4uw7oW4`
- **21 клиент** (UUID + shortId)
- **Cloudflare WARP** — установлен, SOCKS5 outbound на 127.0.0.1:40000
- **TrafficGuard** — блокировка РКН/сканеров через iptables+ipset
- **fail2ban** — SSH jail, бан 7 дней, whitelist 93.94.148.168
- **nginx** — decoy сайт "StreamVault" на порту 80
- **UFW** — открыты 443, 80, 2222
- **Автообновления** — unattended-upgrades + cron Xray update 04:00
- **Домен:** netflixfree.online (зарегистрирован, DNS пока не настроен полностью)

### Тестовый сервер — 31.58.137.10
- **SSH:** порт 2222, пользователь root, пароль `=tznpaaE67N3SR8i6S`
- Прошёл полную тестовую установку через `vpn-setup.sh`
- Все компоненты работают

### Файл vpn-setup.sh — C:/Users/RED/vpn-setup.sh
Рабочий bash скрипт (~750 строк). Полная автоустановка VPN сервера.  
**Все 6 багов найдены и исправлены:**

| Баг | Проблема | Исправление |
|---|---|---|
| 1 | `main_menu` блокировал при `source` | `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` |
| 2 | GitHub API grep не находил версию | `grep -oP '"tag_name"\s*:\s*"v\K[^"]+'` |
| 3 | `xray x25519` изменил формат вывода | `grep -i "private" \| awk '{print $NF}'` |
| 4 | `urllib.parse.quote` не кодировал `/` | `quote('/xray', safe='')` |
| 5 | `tr \| head` SIGPIPE убивал скрипт при `set -euo pipefail` | `openssl rand -hex 4` |
| 6 | `curl ifconfig.me` возвращал IPv6 | `curl -4s ifconfig.me` (принудительный IPv4) |

**Ключевые функции скрипта:**
- `run_configurator()` — интерактивный диалог сбора параметров
- `install_deps()`, `install_xray()`, `generate_xray_keys()`, `generate_users()`
- `create_xray_config()` — генерирует `/etc/xray/config.json` с WARP outbound
- `install_warp()` — Cloudflare WARP + SOCKS5
- `setup_nginx()` — decoy сайт
- `setup_firewall()`, `setup_ssh()`, `setup_fail2ban()`
- `setup_auto_updates()`, `setup_xray_autoupdate()`, `install_trafficguard()`, `setup_cron()`
- `remnawave_server()`, `remnawave_node()` — базовая установка Remnawave

**Известные особенности:**
- `set -euo pipefail` — строгий режим, любая ошибка = выход
- Ссылки сохраняются в `/etc/xray/links.txt` (chmod 600)
- Состояние в `/etc/xray-setup.conf`
- Subdomains/nodes регистрируются в `/opt/orchestra/fleet/nodes.conf`

---

## 2. Новый проект — Orchestra

### Суть
Переписать и расширить `vpn-setup.sh` в **модульную систему** `orchestra.sh` — мастер-скрипт для развёртывания и управления VPN-инфраструктурой из нескольких серверов.

### Файл плана — C:/Users/RED/orchestra-plan.md
Детальный план с ASCII-схемами всех процессов. **Обязательно прочитай его перед написанием кода.**

---

## 3. Архитектура Orchestra

### Структура файлов
```
/opt/orchestra/
├── orchestra.sh              # точка входа + общие утилиты
├── lib/
│   ├── sys.sh                # hardening системы
│   ├── xray.sh               # VLESS + Reality + XHTTP
│   ├── remnawave.sh          # Remnawave Panel + Node
│   ├── bedolaga.sh           # Telegram-бот продажи подписок
│   ├── proxy.sh              # Nginx / Caddy
│   ├── trafficguard.sh       # блокировка сканеров
│   ├── warp.sh               # Cloudflare WARP
│   ├── backup.sh             # резервные копии
│   └── monitor.sh            # мониторинг нод + блокировки
├── fleet/
│   ├── nodes.conf            # реестр серверов
│   └── credentials/          # SSH-ключи (chmod 700)
├── state/
│   ├── <ip>.conf             # конфиг/состояние сервера
│   ├── <ip>-progress.conf    # прогресс установки (для resume)
│   └── orchestra.log
└── backups/
```

### Режимы работы
1. **Локальный** — `orchestra` — запуск на текущем сервере
2. **Удалённый** — `orchestra remote <ip> <module>` — SSH + upload + execute
3. **Fleet** — `orchestra fleet <команда>` — управление всеми нодами

---

## 4. Ключевые архитектурные решения

### A. Конфигурационный паспорт (Pre-flight)
**Правило:** скрипт собирает ВСЕ параметры и валидирует их ДО начала установки.  
Никакой установки если хоть одна обязательная проверка не прошла.

Порядок:
1. Сбор всех параметров через диалог (с инструкциями)
2. Валидация всего сразу (домены, токены, порты, ресурсы)
3. Итоговая сводка параметров
4. Подтверждение → УСТАНОВКА

### B. Система шагов и Resume
Каждый шаг установки имеет статус: `pending → running → done / failed`  
Статус пишется в `state/<ip>-progress.conf` после каждого шага.  
При прерывании → при следующем запуске скрипт предлагает продолжить с места остановки.

```bash
run_step "install_xray" install_xray "Установка Xray"
# → если step уже done: пропускает
# → если failed: пробует снова
# → пишет running → done/failed в progress файл
```

### C. Домены — обязательные, с автонастройкой
Каждый компонент требует домен с валидной A-записью.

**Карта доменов:**
```
vpn.example.com    → IP ноды    DNS-only (CF proxy НЕЛЬЗЯ — Reality сломается)
panel.example.com  → IP панели  DNS-only
sub.example.com    → IP панели  CF Proxy МОЖНО (скрывает IP панели от клиентов!)
bot.example.com    → IP бота    DNS-only
```

**Автонастройка DNS через Cloudflare API v4:**  
Если пользователь даёт CF API Token → скрипт сам создаёт все A-записи  
с правильным proxy-статусом, ждёт propagation, валидирует.

```bash
# Минимальные права токена: Zone:DNS:Edit для конкретной зоны
# Создать на: dash.cloudflare.com → Profile → API Tokens → Edit zone DNS
cf_upsert_record "$zone_id" "vpn.example.com" "$server_ip" "false"  # DNS-only
cf_upsert_record "$zone_id" "sub.example.com" "$server_ip" "true"   # CF Proxy
```

**Детект Cloudflare Proxy по TTL:**
```bash
# TTL=300 → Cloudflare proxy включён (оранжевое облако)
# Для Reality-доменов это ОШИБКА → предупреждаем и блокируем
```

**Fallback резолвинга домена (три метода):**
```bash
# 1. dig +short A domain @1.1.1.1
# 2. host domain
# 3. curl https://cloudflare-dns.com/dns-query?name=domain&type=A (DoH)
```

### D. UX — инструкция на каждый параметр
Перед каждым нетривиальным вопросом — рамка с объяснением и ссылкой.

```
╔══════════════════════════════════════════════════╗
║  Как получить Cloudflare API Token:              ║
║  1. dash.cloudflare.com → Profile → API Tokens   ║
║  2. Create Token → Edit zone DNS                 ║
║  3. Выбери свой домен → Create Token             ║
╚══════════════════════════════════════════════════╝
[?] Cloudflare API Token:
```

**Параметры с инструкциями:**
- CF API Token — где создать, какие права
- Telegram Bot Token — @BotFather → /newbot
- Admin Telegram ID — @userinfobot
- Remnawave API Key — панель → Settings → API Tokens
- Домен — что такое A-запись, DNS-only vs CF proxy
- SNI для Reality — что это, какой выбрать

### E. Цветовая схема
```
[?] cyan    — вопрос
[✓] green   — успех
[!] yellow  — предупреждение
[✗] red     — ошибка
[→] white   — текущий шаг
[·] grey    — ожидающий шаг
╔══╗ blue   — подсказка/инструкция
```

---

## 5. Модули — детали реализации

### sys.sh — Базовый hardening
Применяется первым на любом новом сервере.

**sysctl.conf — финальный (исправленный):**
```ini
# IPv6 отключаем (генерируем ссылки через IPv4)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# IPv4 — ip_forward=1 нужен для WARP/WireGuard
net.ipv4.ip_forward = 1

# rp_filter=2 (loose) — strict=1 ломает асимметричный роутинг WARP
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# Защита от спуфинга
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0

# ICMP
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ratelimit = 100
net.ipv4.icmp_ignore_bogus_error_responses = 1

# TCP hardening
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192

# TCP оптимизация
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_ecn = 2              # НЕ 1 — некоторые провайдеры дропают ECN
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 5000

# BBR — обязательно
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Безопасность ядра
kernel.yama.ptrace_scope = 1
kernel.randomize_va_space = 2
fs.suid_dumpable = 0
fs.file-max = 2097152
vm.swappiness = 10               # НЕ 0 — риск OOM

# УБРАНО: tcp_fack (нет в ядре 4.20+, вызывает ошибку)
# УБРАНО: log_martians (спамит syslog на нагруженном сервере)
# УБРАНО: лишние IPv6 параметры при disable_ipv6=1
```

### xray.sh — VLESS + Reality + XHTTP
Перенос логики из рабочего `vpn-setup.sh` в модуль.  
**Критично:** `curl -4s` для IPv4-first при определении IP сервера.

### remnawave.sh — Panel + Node
**Panel:** Docker (PostgreSQL 17 + Redis/Valkey + backend), JWT генерируется автоматически  
**Node:** Docker контейнер, SECRET_KEY берётся из панели  
**SUB_PUBLIC_DOMAIN** — отдельный параметр, может быть за CF Proxy

### bedolaga.sh — Telegram-бот продажи подписок
- Репо: https://github.com/BEDOLAGA-DEV/remnawave-bedolaga-telegram-bot
- Python 3.13 + aiogram, Docker (бот + PostgreSQL + Redis)
- Порт 8080, health check `/health`
- Лицензия: MIT + Commons Clause (использовать для бизнеса можно, перепродавать бот нельзя)
- **Требует:** работающую Remnawave Panel + домен с SSL + Bot Token
- **15+ платёжных систем:** YooKassa, Telegram Stars, CryptoBot, CloudPayments, Freekassa...
- Секреты генерируются автоматически: `openssl rand -hex 32`

### monitor.sh — 7 уровней проверки нод
```
L1: ICMP ping
L2: TCP :443
L3: TLS handshake (curl --resolve SNI)
L4: HTTP decoy → 200
L5: ipregion.sh -j -i <ip>  → ASN/ISP/страна (17 GeoIP источников)
L6: checker.sh               → Netflix/YouTube репутация IP (опционально)
L7: zapret-info              → IP в реестре РКН
```
Уведомления в Telegram при ALERT.

### backup.sh
Бэкапит: `/etc/xray/`, `/opt/remnawave/.env`, PostgreSQL dump, `state/*.conf`  
Хранит: локально + Telegram (split 49MB) + S3/rclone  
**Safety backup автоматически перед любым restore**

---

## 6. Fleet — управление нодами

### nodes.conf
```ini
[node-01]
host        = 31.56.178.11
port        = 2222
user        = root
role        = xray
key         = /opt/orchestra/fleet/credentials/node-01.key
node_domain = vpn.example.com
installed   = 2026-04-10
status      = ok

[node-02]
host        = 31.58.137.10
port        = 2222
user        = root
role        = remnawave-node
key         = /opt/orchestra/fleet/credentials/node-02.key
panel_url   = https://panel.example.com
status      = ok
```

### Команды fleet
```bash
orchestra fleet status          # таблица статусов всех нод
orchestra fleet monitor         # L1-L7 проверка блокировок
orchestra fleet deploy all xray # деплой модуля на все ноды
orchestra fleet update-all      # обновление Xray/Remnawave
orchestra diag <ip>             # глубокая диагностика (ipregion + checker)
```

---

## 7. Порядок разработки (этапы)

```
Этап 1 — Скелет (начинаем отсюда)
  ├── orchestra.sh: точка входа, загрузка модулей, главное меню
  ├── Общие утилиты: info/warn/error/section/ask/hint/press_enter
  ├── validate_domain() — резолвинг + сравнение с IP сервера
  ├── get_server_ip() — curl -4s с тремя fallback
  ├── cf_setup_dns() — Cloudflare API автонастройка DNS
  ├── run_step() — движок шагов с записью прогресса
  ├── check_resume_prompt() — диалог продолжения при прерывании
  ├── fleet/nodes.conf парсер (read_node / write_node / list_nodes)
  └── state/ read/write

Этап 2 — sys.sh
  └── hardening, sysctl (см. выше), BBR, fail2ban, UFW, NTP, logrotate

Этап 3 — xray.sh
  └── перенос vpn-setup.sh с адаптацией под run_step() и модульность

Этап 4 — monitor.sh
  └── L1-L7, ipregion.sh интеграция, Telegram алерты

Этап 5 — remnawave.sh
  └── panel + node, docker-compose генерация, SUB домен

Этап 6 — bedolaga.sh
  └── git clone + .env генерация + nginx vhost + certbot + health check

Этап 7 — proxy.sh, warp.sh, trafficguard.sh

Этап 8 — backup.sh
  └── xray + remnawave + bedolaga DB, telegram split, retention

Этап 9 — fleet remote mode
  └── SSH upload + execute, параллельность, fleet summary
```

---

## 8. Критичные технические нюансы (выученные на ошибках)

| Нюанс | Деталь |
|---|---|
| `set -euo pipefail` + pipe | `tr \| head` → SIGPIPE exit 141 → скрипт падает. Используй `openssl rand -hex N` |
| Xray x25519 вывод | Формат изменился: `Password (PublicKey):` вместо `Public key:`. Парсить через `grep -i "public\|password" \| awk '{print $NF}'` |
| `curl ifconfig.me` | Без `-4` может вернуть IPv6. Всегда `curl -4s` |
| `urllib.parse.quote` | `quote('/xray')` → `/xray` (не кодирует слэш). Нужно `quote('/xray', safe='')` |
| `source script.sh` | Блокирует если в конце есть `main_menu` с `read`. Защита: `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` |
| GitHub API JSON | `"tag_name": "v1.2.3"` — есть пробел после двоеточия. Паттерн: `'"tag_name"\s*:\s*"v\K[^"]+'` |
| Reality + Cloudflare | CF Proxy (оранжевое облако) ломает Reality — TLS проксируется через CF. TTL=300 = CF proxy включён |
| WARP + rp_filter | `rp_filter=1` (strict) дропает пакеты WARP из-за асимметричного роутинга. Нужно `=2` (loose) |
| tcp_fack | Удалён из ядра Linux 4.20. На Debian 12 вызывает ошибку sysctl. Не использовать |
| nohup + SSH | `nohup cmd &` при SSH сессии может не сохранить процесс. Использовать `screen -dmS name cmd` |
| Xray version 26.x | Актуальная стабильная версия — 26.3.27. API GitHub для latest работает |

---

## 9. Fleet Remote Mode (Управление флотом)

Orchestra поддерживает управление флотом нод через центральный мастер-сервер. Все ноды регистрируются в `nodes.conf`, после чего можно выполнять массовый деплой модулей параллельно.

### Конфигурация нод
- Файл регистрации: `/opt/orchestra/fleet/nodes.conf`
- Формат записи: `node_name|host|port|user|role|key_path|status|installed`
- Утилиты: `add_node`, `read_node`, `write_node`, `list_nodes`

### SSH подключение
- Поддержка SSH ключей (приоритет) и пароля через `sshpass`
- Функции: `ssh_connect`, `ssh_upload`, `ssh_execute`
- Автоматическое определение BatchMode при наличии ключа

### Деплой модулей
1. **Одиночный деплой**: `fleet_deploy_module node_name module [auto]`
2. **Параллельный деплой на все ноды**: `fleet_deploy_module_all module [auto]`
3. **Интерактивный выбор**: через меню Fleet (пункты 2 и 3)

### Меню Fleet
- **Статус всех нод (ping + порты)** — быстрая проверка доступности
- **Деплой модуля на ноду** — интерактивный выбор ноды и модуля
- **Деплой модуля на ВСЕ ноды (параллельно)** — массовый деплой с фоновым выполнением
- **Добавить ноду** — регистрация новой ноды в fleet
- **Сводка флота** — статистика по статусам и ролям

### Параллельное выполнение
- Каждая нода обрабатывается в отдельном фоновом процессе
- Вывод каждой ноды префиксируется её именем
- Ожидание завершения всех процессов с подсчётом успешных/неуспешных
- Автоматическое обновление статуса ноды в nodes.conf

### Пример использования
```bash
# Добавить ноду
orchestra.sh --fleet-add-node

# Деплой системного hardening на все ноды
orchestra.sh --fleet-deploy-all sys --auto

# Проверить статус флота
orchestra.sh --fleet-status
```

---

## 10. Источники и репозитории изученные в проекте

| Репо/источник | Что взято |
|---|---|
| [eGamesAPI/remnawave-reverse-proxy](https://github.com/eGamesAPI/remnawave-reverse-proxy) | nginx + unix socket, BBR, multi-mirror CDN, decoy шаблоны |
| [DigneZzZ/remnawave-scripts](https://github.com/DigneZzZ/remnawave-scripts) | Docker deploy, credential export, WARP manager, backup |
| [distillium/remnawave-backup-restore](https://github.com/distillium/remnawave-backup-restore) | Safety backup, retention, версионность, Telegram 49MB split |
| [legiz-ru/my-remnawave](https://github.com/legiz-ru/my-remnawave) | Subscription templates, multi-client конфиги |
| [dotX12/traffic-guard](https://github.com/dotX12/traffic-guard) | iptables+ipset, arch detect, WHOIS/ASN аналитика |
| [BEDOLAGA-DEV/remnawave-bedolaga-telegram-bot](https://github.com/BEDOLAGA-DEV/remnawave-bedolaga-telegram-bot) | Telegram биллинг, 15+ платёжных систем |
| [bench.gig.ovh](https://bench.gig.ovh) | `ipregion.sh -j` (17 GeoIP), `checker.sh` (репутация IP) |
| Cloudflare API v4 | DNS автонастройка через curl |

---

## 11. Файлы на локальной машине

| Файл | Описание |
|---|---|
| `C:/Users/RED/vpn-setup.sh` | Рабочий скрипт установки VPN (все баги исправлены) |
| `C:/Users/RED/orchestra-plan.md` | Детальный план Orchestra с ASCII-схемами |
| `C:/Users/RED/orchestra-briefing.md` | Этот файл |
| `/tmp/ssh_pass_test.sh` | SSH пароль для тестового сервера (локальный temp) |
| `/tmp/ssh_pass_prod.sh` | SSH пароль для продакшн сервера (локальный temp) |

---

## 12. Инструкция для продолжения в новой сессии

1. Прочитай `C:/Users/RED/orchestra-plan.md` — там полный план с диаграммами
2. Прочитай `C:/Users/RED/vpn-setup.sh` — там рабочий код который нужно адаптировать
3. Начинай с **Этапа 1** (Скелет) — `orchestra.sh` с утилитами, валидацией домена, CF API, движком шагов
4. Каждый модуль пиши в отдельный файл `lib/*.sh`
5. Тестируй на сервере 31.58.137.10 (порт 2222, пароль `=tznpaaE67N3SR8i6S`)
6. Подключение: `ssh -p 2222 root@31.58.137.10` через SSH_ASKPASS

**Приоритет при написании кода:**
- Сначала скелет (`orchestra.sh`) с общими функциями
- Потом `sys.sh` (hardening — нужен всегда первым)
- Потом `xray.sh` (перенос рабочего кода)
- Остальные модули по порядку этапов

**Стиль кода:**
- Всё на русском (сообщения, комментарии)
- `set -euo pipefail` в каждом файле
- Никакого `tr | head` → только `openssl rand -hex N`
- Никакого `curl ifconfig.me` → только `curl -4s`
- Каждая функция → одна ответственность
- Каждый шаг → через `run_step()`

---

*Создано: 2026-04-10 | Версия брифинга: 1.0*
