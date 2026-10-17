# JUST1KNODE

Модульная серверная утилита, панель управления и микросервисы для автономных узлов AmneziaWG и Xray (VLESS over XHTTP и VLESS TLS).

---

## Быстрая установка

Развертывание на чистом сервере Ubuntu (22.04 / 24.04) или Debian (11 / 12):

```bash
curl -fsSL https://raw.githubusercontent.com/justik13/just1knode/main/just1knode.sh | bash
```

Скрипт развертывает модули в `/opt/just1knode` и регистрирует утилиту `/usr/local/bin/just1knode`.

---

## Поддерживаемые роли узлов

1. **Origin (входной шлюз Белого Интернета в РФ):**
   - Прием трафика VLESS over XHTTP через Yandex Cloud CDN.
   - Nginx Zero Buffering и HTTP/1.1 keepalive upstreams (100k запросов).
   - Bodiless GET Uplink (защита от ошибок 413 на CDN-прокси).
   - Локальный FastAPI микросервис `xray-api` (порт 8444, доступ строго по `BOT_IP`).
   - Автоматический выпуск и продление SSL через Let's Encrypt (Certbot).
2. **Relay (выходной шлюз Белого Интернета за рубежом):**
   - VLESS TLS туннелирование между Origin и интернетом.
   - Автоматический подбор и валидация сертификатов Let's Encrypt по дате выпуска.
   - Добавление в ротацию на Origin командой `just1knode relay add`.
3. **Direct VLESS TLS (прямой узел стандартного доступа):**
   - Прямой высокоскоростной VLESS TLS узел на собственном домене.
   - Локальный микросервис `xray-api` (порт 8444, доступ строго по `BOT_IP`).
   - Клиентское подключение через INCY по subscription feed (`/sub/access/{token}`).
4. **AmneziaWG (узел стандартного доступа AWG):**
   - Нативный сетевой стек WireGuard/AmneziaWG в ядре Linux (`awg0`).
   - Поддержка параметров обфускации (`Jc`, `Jmin`, `Jmax`, `S1-S4`, `H1-H4`, `I1-I5`).
   - Изолированный FastAPI микросервис `amnezia-api` (порт 8443, доступ строго по `BOT_IP`).
   - Динамическое распределение IP-адресов подсети `/22` без ограничения в 254 пира.

---

## Команды CLI (`just1knode`)

### Интерактивное меню

```bash
just1knode
```

### Основные команды

| Команда | Описание |
|---|---|
| `just1knode status` | Статус служб (`xray`, `nginx`, `xray-api`, `amnezia-api`), открытые порты, пиры |
| `just1knode doctor` | 12 уровней самодиагностики: службы, порты, API, Xray, Nginx, SSL, DNS, UFW, IPv6, ICMP |
| `just1knode heal` | Автоматическое самовосстановление поврежденных конфигураций Nginx и Xray |
| `just1knode update` | Обновление модулей утилиты и перепроверка конфигураций |
| `just1knode update core` | Обновление бинарного ядра Xray-core до актуальной версии |
| `just1knode set-bot-ip <IP>` | Обновление доверенного IP бота для доступа к управляющим портам API |
| `just1knode anti-abuse` | Накатка правил блокировки SMTP (порт 25) и BitTorrent |
| `just1knode reset` | Сброс локальной конфигурации роли узла |
| `just1knode uninstall` | Удаление утилиты и компонентов (флаги: `--force`, `--purge-backups`) |

### Установка ролей

| Команда | Описание |
|---|---|
| `just1knode install origin` | Развертывание роли Origin (Xray VLESS XHTTP + Nginx + Certbot) |
| `just1knode install relay` | Развертывание роли Relay (Xray VLESS TLS) |
| `just1knode install vless` | Развертывание роли прямого узла VLESS TLS |
| `just1knode install amnezia` | Развертывание роли узла AmneziaWG |

### Управление релеями (на сервере Origin)

| Команда | Описание |
|---|---|
| `just1knode relay list` | Список подключенных Relay-узлов |
| `just1knode relay add "Название" IP PORT DOMAIN SNI` | Добавить Relay-узел в ротацию |
| `just1knode relay rename <ID> "Новое имя"` | Переименовать Relay-узел |
| `just1knode relay remove <ID>` | Удалить Relay-узел |

### Контроль трафика узла (`traffic_watchdog`)

| Команда | Описание |
|---|---|
| `just1knode limit status` | Текущий объем переданного трафика и статус лимита |
| `just1knode limit set <GB> [день] [tg_token] [tg_chat]` | Установка месячного лимита трафика с алертами в Telegram |
| `just1knode limit check` | Ручная проверка расхода трафика |
| `just1knode limit disable` | Отключение лимитирования трафика |

### Бэкап и восстановление AmneziaWG

| Команда | Описание |
|---|---|
| `just1knode amnezia backup` | Создание резервной копии ключей и конфигураций AWG |
| `just1knode amnezia restore` | Восстановление конфигурации AWG из бэкапа |

---

## Сетевая безопасность и периметр

- **UFW Fail-Closed:** Управляющие порты `amnezia-api` (`8443/tcp`) и `xray-api` (`8444/tcp`) открываются строго и адресно для `BOT_IP`. Прямые запросы из внешней сети сбрасываются.
- **Stealth ICMP:** Отключение ответов на ICMP Echo Request (`net.ipv4.icmp_echo_ignore_all = 1`) с персистентным сохранением в `/etc/sysctl.d/99-just1k-stealth.conf` для защиты от сетевого сканирования.
- **Отключение IPv6:** Принудительное отключение IPv6 стека на уровне ядра (`disable_ipv6 = 1`) для исключения утечек сетевого трафика.
- **Защита от абуза:** Блокировка SMTP спам-портов (`25/tcp`) и сигнатур BitTorrent на уровне правил фаервола.

---

## Архитектура репозитория

```text
just1knode/
├── just1knode.sh              # Главный исполняемый диспетчер (CLI)
├── VERSION                    # Текущая версия утилиты
├── lib/                       # Общие модули ядра
│   ├── common.sh              # Базовые функции логирования и валидации
│   ├── state.sh               # Хранение состояния и параметров узла
│   ├── ssl.sh                 # Управление сертификатами Let's Encrypt
│   ├── backup.sh              # Механизмы создания и восстановления бэкапов
│   ├── traffic_watchdog.sh    # Служба мониторинга трафика
│   └── traffic_watchdog.py    # Логика подсчета байтов и Telegram-алертов
├── modules/
│   ├── amnezia/               # Модуль установки и настройки AmneziaWG
│   └── xray/                  # Модули Xray (core, origin, relay, relays_manage, api)
├── scripts/
│   ├── xray_api/              # FastAPI служба Xray API + proto + gRPC
│   └── amnezia_api/           # FastAPI служба Amnezia API
├── docs/                      # Инженерно-техническая документация
├── tests/                     # Сьют автоматических тестов
└── .github/workflows/         # CI/CD автоматизация
```

---

## Инженерная документация

Подробные руководства доступны в каталоге [`docs/`](docs/README.md):
- [Руководство по Белому Интернету (Whitelist Master Guide)](docs/WL/WHITELIST_MASTER_GUIDE.md)
- [Спецификация AmneziaWG 2.0 (Amnezia Technical Reference)](docs/amnezia_docs.md)
- [Спецификация клиента INCY (INCY Master Guide)](docs/INCY_MASTER_GUIDE.md)
- [Модель угроз и сетевая безопасность ТСПУ](docs/NETWORK_SECURITY_AND_TSPU.md)
