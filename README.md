# Orchestra — Модульный Bash-оркестратор VPN инфраструктуры

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/Bash-5.1+-green.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20WSL-blue)](https://learn.microsoft.com/windows/wsl/)
[![GitHub](https://img.shields.io/badge/GitHub-Repository-blue)](https://github.com/jLapa/orchestra)

> **Профессиональный оркестратор для развёртывания и управления VPN инфраструктурой с поддержкой флота серверов**

Orchestra — это модульная система управления VPN инфраструктурой, написанная на Bash. Поддерживает развёртывание Xray (VLESS+Reality+XHTTP), Remnawave Panel/Node, Bedolaga Telegram бота, системного hardening, мониторинга, бэкапов и управления флотом серверов через единый интерфейс.

> **🎯 Проект развернут на GitHub и готов к использованию!**

## 🚀 Возможности

### 📦 Модульная архитектура (9 модулей)
- **`sys.sh`** — Системный hardening, безопасность, настройка SSH, UFW, fail2ban
- **`xray.sh`** — Xray-core (v26.3.27) с VLESS+Reality+XHTTP, Cloudflare WARP outbound
- **`remnawave.sh`** — Remnawave Panel + Node управление через Docker
- **`bedolaga.sh`** — Bedolaga Telegram бот с 15+ платёжными системами
- **`monitor.sh`** — Мониторинг нод L1-L7 + Telegram алерты + ipregion.sh
- **`proxy.sh`** — Nginx/Caddy reverse proxy + SSL (Let's Encrypt)
- **`trafficguard.sh`** — Блокировка сканеров и РКН сетей через iptables+ipset
- **`warp.sh`** — Cloudflare WARP управление (SOCKS5 outbound)
- **`backup.sh`** — Резервные копии Xray + Remnawave + Bedolaga + state

### 🎯 Три режима работы
1. **Локальный режим** — установка компонентов на текущий сервер
2. **Удалённый режим** — управление одним выбранным сервером
3. **Флот-режим** — централизованное управление множеством нод

### ⚡ Параллельный деплой
- Массовый деплой модулей на все ноды флота одновременно
- Каждая нода обрабатывается в отдельном фоновом процессе
- Префиксация вывода `[имя_ноды]` для лёгкой отладки
- Автоматический подсчёт успешных/неуспешных деплоев

### 🔐 Безопасность по умолчанию
- Full Reality + XHTTP поверхность
- Cloudflare WARP как outbound (маскировка трафика)
- TrafficGuard для блокировки РКН сетей и сканеров
- fail2ban с whitelist и 7-дневным баном
- UFW только с необходимыми портами (443, 80, SSH)
- Автоматические обновления security patches

## 📁 Структура проекта

```
orchestra/
├── orchestra.sh              # Главный скрипт-оркестратор
├── README.md                 # Эта документация
├── .gitignore               # Игнорирование секретов и временных файлов
├── orchestra-briefing.md     # Полный контекст проекта
├── orchestra-plan.md         # Детальный план с ASCII-схемами
├── validate.sh              # Скрипт валидации модулей
└── lib/                     # Модули Orchestra
    ├── sys.sh              # Системный hardening
    ├── xray.sh             # Xray-core управление
    ├── remnawave.sh        # Remnawave Panel+Node
    ├── bedolaga.sh         # Bedolaga Telegram bot
    ├── monitor.sh          # Мониторинг L1-L7
    ├── proxy.sh            # Nginx reverse proxy
    ├── trafficguard.sh     # Блокировка РКН/сканеров
    ├── warp.sh             # Cloudflare WARP
    └── backup.sh           # Резервные копии
```

## 🏗️ Установка и настройка

### Настройка окружения

По умолчанию Orchestra ожидает работу из директории `/opt/orchestra`. Если вы запускаете из другой директории, выполните:

```bash
# Создать символическую ссылку
sudo ln -s "$(pwd)" /opt/orchestra

# Или изменить переменную ORCHESTRA_DIR в orchestra.sh
# Измените строку: readonly ORCHESTRA_DIR="/opt/orchestra"
```

### Инициализация директорий

При первом запуске скрипт автоматически создаст необходимые директории. Если возникают ошибки записи логов, создайте их вручную:

```bash
sudo mkdir -p /opt/orchestra/{state,fleet/credentials,backups,lib}
sudo chmod 700 /opt/orchestra/fleet/credentials
```

### Проверка зависимостей

Убедитесь, что установлены необходимые утилиты:

```bash
sudo apt-get update
sudo apt-get install -y curl wget git sshpass jq dnsutils
```

## ⚡ Установка одной командой

Для быстрой установки Orchestra выполните:

```bash
# Автоматическая установка (требует sudo для системной установки)
curl -4fsSL https://raw.githubusercontent.com/jLapa/orchestra/master/install.sh | sudo bash

# Или без sudo (установка в домашнюю директорию)
curl -4fsSL https://raw.githubusercontent.com/jLapa/orchestra/master/install.sh | bash
```

Скрипт установки:
1. Проверит зависимости и установит недостающие
2. Скачает последнюю версию Orchestra с GitHub
3. Установит в `/opt/orchestra` (при root) или `~/.orchestra` (без root)
4. Настроит права доступа
5. Создаст символическую ссылку для глобального вызова (опционально)

После установки перейдите в директорию и запустите Orchestra:

```bash
cd /opt/orchestra  # или ~/.orchestra
./orchestra.sh
```

## 🚀 Быстрый старт

### Предварительные требования
- Linux (Debian/Ubuntu) или WSL2 на Windows
- Bash 5.1+
- Права root (или sudo)
- SSH доступ к целевым серверам (для удалённого режима)

### Установка и запуск

```bash
# Клонирование репозитория
git clone https://github.com/jLapa/orchestra.git
cd orchestra

# Назначение прав исполнения
chmod +x orchestra.sh

# Запуск в интерактивном режиме
./orchestra.sh

# Или с параметрами
./orchestra.sh --help
./orchestra.sh --local-install sys
./orchestra.sh --remote-deploy 31.56.178.11 xray --auto
```

## 📖 Основные команды

### Локальная установка
```bash
./orchestra.sh --local-install [модуль]        # Установка модуля локально
./orchestra.sh --local-install-all             # Установка всех модулей
```

### Удалённый деплой
```bash
./orchestra.sh --remote-deploy IP модуль [--auto]  # Деплой на удалённый сервер
./orchestra.sh --remote-ssh IP "команда"          # Выполнение команды через SSH
```

### Управление флотом
```bash
./orchestra.sh --fleet-add-node                # Добавить ноду в fleet
./orchestra.sh --fleet-deploy-all модуль       # Деплой на ВСЕ ноды флота
./orchestra.sh --fleet-status                  # Статус всех нод
./orchestra.sh --fleet-summary                 # Сводка по флоту
```

### Интерактивные режимы
```bash
./orchestra.sh                                 # Главное меню
./orchestra.sh --local                         # Локальное меню
./orchestra.sh --remote                        # Удалённое меню
./orchestra.sh --fleet                         # Флот-меню
```

## 🏗️ Архитектура

### Движок шагов (`run_step()`)
Каждая операция в Orchestra выполняется через движок шагов:
```bash
run_step "Описание шага" "команда_выполнения"
```
- Автоматическое логирование
- Обработка ошибок с rollback
- Прогресс-бар и временные метки
- Запись состояния в `${PROGRESS_FILE}`

### State management
- Все состояния сохраняются в `${STATE_DIR}/`
- Автоматическое восстановление при прерывании
- Версионность конфигов
- Миграции между версиями

### SSH оркестрация
- Поддержка SSH ключей (приоритет) и пароля через `sshpass`
- Функции: `ssh_connect`, `ssh_upload`, `ssh_execute`
- Автоматическое определение `BatchMode=yes` при наличии ключа
- Таймауты и обработка ошибок подключения

## 🔧 Конфигурация

### Основные переменные (настраиваются при первом запуске)
```bash
NODE_DOMAIN="vpn.yourdomain.com"      # Основной домен ноды
PANEL_DOMAIN="panel.yourdomain.com"   # Домен Remnawave Panel
BOT_DOMAIN="bot.yourdomain.com"       # Домен Bedolaga бота
CF_API_TOKEN="your_cloudflare_token"  # Токен Cloudflare API
CF_ZONE_ID="your_zone_id"             # Zone ID Cloudflare
```

### Файл конфигурации флота (`nodes.conf`)
```
node_01|31.56.178.11|22|root|/home/user/.ssh/id_rsa|xray|ok|2024-04-10
node_02|104.253.175.173|2222|root||remnawave-node|pending|2024-04-10
```

Формат: `имя|IP|порт|пользователь|путь_к_ключу|роль|статус|дата_установки`

## 📊 Мониторинг и алерты

### Уровни проверки (L1-L7)
- **L1**: ICMP ping — базовая доступность
- **L2**: TCP порт 443 — доступность сервиса
- **L3**: TLS handshake — работоспособность TLS
- **L4**: HTTP decoy → 200 — проверка decoy-сайта
- **L5**: IP region (ASN/ISP/страна) — геолокация
- **L6**: Репутация IP (Netflix/YouTube) — проверка блокировок
- **L7**: РКН реестр — проверка блокировок РКН

### Telegram алерты
- Настройка через `monitor.sh → Настроить Telegram алерты`
- Отправка при: недоступности сервера, блокировке РКН, ошибках портов
- Поддержка emoji и форматирования Markdown
- Daemon-режим с проверкой каждые 5 минут

## 💾 Бэкапы и восстановление

### Что бэкапится
- Конфиги Xray (`/etc/xray/`)
- Remnawave `.env` и `docker-compose.yml`
- Bedolaga `.env` и `docker-compose.yml`
- Дампы PostgreSQL (Remnawave + Bedolaga)
- Orchestra state (`${STATE_DIR}/` и `nodes.conf`)

### Особенности
- Автоматическая ротация (хранить 7 последних бэкапов)
- Split на части ≤49MB для Telegram
- Автоматические бэкапы через cron
- Safety backup перед восстановлением

## 🔄 Рабочие процессы

### 1. Развёртывание новой ноды
```bash
./orchestra.sh --fleet-add-node
# → Ввод: имя, IP, порт, пользователь, роль, ключ SSH
./orchestra.sh --fleet-deploy-all sys --auto
./orchestra.sh --fleet-deploy-all xray --auto
# → Параллельный деплой hardening и Xray на все ноды
```

### 2. Мониторинг флота
```bash
./orchestra.sh --fleet-status
# → Проверка ping и порта 443 на всех нодах
./orchestra.sh --fleet-summary
# → Сводка: всего нод, OK/ошибки, роли, дата обновления
```

### 3. Экстренное восстановление
```bash
./orchestra.sh --local backup
# → Создание бэкапа
./orchestra.sh --local restore
# → Восстановление из выбранного бэкапа
```

## 🛡️ Безопасность

### Реализованные меры
1. **Network security**: UFW + fail2ban + TrafficGuard
2. **Traffic masking**: Reality + XHTTP + Cloudflare WARP
3. **Credential protection**: Отдельные `.env` файлы, исключённые из git
4. **SSH hardening**: Отключение root-логина по паролю, только ключи
5. **Auto updates**: unattended-upgrades + cron для Xray
6. **Monitoring**: L1-L7 checks + Telegram алерты
7. **Backup**: Ежедневные бэкапы с retention 7 дней

### Рекомендации для production
1. Используйте отдельные SSH ключи для каждой ноды
2. Настройте VPN для доступа к panel-интерфейсам
3. Регулярно обновляйте Xray через `./orchestra.sh --local xray --update`
4. Мониторьте логи через `journalctl -u xray -f`
5. Используйте GeoDNS для распределения нагрузки

## 🛠️ Устранение неполадок

### Cloudflare Proxy detection

Если скрипт неправильно определяет состояние Cloudflare Proxy (оранжевое/серое облако), обновите скрипт до версии, исправляющей проверку TTL=300 + IP диапазоны Cloudflare.

### Remnawave Panel установка

При ошибке `validate_port: command not found` или `docker_install: command not found` обновите модуль `remnawave.sh`. Исправления:
- Добавлена функция `validate_port()` для совместимости
- Исправлен вызов `_rw_ensure_docker` вместо `docker_install`
- Добавлены вызовы `init_progress` и `check_resume_prompt`

### Ошибка записи логов

Если возникает ошибка `No such file or directory` для `/opt/orchestra/state/orchestra.log`, создайте директории вручную (см. раздел «Инициализация директорий»).

### Тестирование модулей

Для проверки всех модулей на синтаксические ошибки выполните:

```bash
./validate.sh
```

## 📝 Лицензия

MIT License — смотрите файл [LICENSE](LICENSE).

## 🤝 Вклад в проект

1. Форкните репозиторий
2. Создайте ветку для фичи (`git checkout -b feature/amazing-feature`)
3. Закоммитьте изменения (`git commit -m 'Add amazing feature'`)
4. Запушьте в ветку (`git push origin feature/amazing-feature`)
5. Откройте Pull Request

### Стиль кода
- Всё на русском (сообщения, комментарии)
- `set -euo pipefail` в каждом файле
- Никакого `tr | head` → только `openssl rand -hex N`
- Никакого `curl ifconfig.me` → только `curl -4s`
- Каждая функция → одна ответственность
- Каждый шаг → через `run_step()`

## 📞 Поддержка

- **Issues**: [GitHub Issues](https://github.com/jLapa/orchestra/issues)
- **Документация**: [`orchestra-briefing.md`](orchestra-briefing.md) и [`orchestra-plan.md`](orchestra-plan.md)
- **Тестовые серверы**: В брифинге указаны тестовые серверы с SSH доступом

---

**Orchestra** — профессиональный инструмент для управления VPN инфраструктурой.  
Разработано с ❤️ для DevOps инженеров, которым нужен контроль и автоматизация.

*Последнее обновление: 2026-04-11 | Версия: 1.0.0*