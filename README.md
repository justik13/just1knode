# ⚡ JUST1KNODE

Модульная серверная утилита, панель управления и микросервисы для автономных узлов туннелирования **AmneziaWG** и **Xray VLESS over XHTTP** (Белый Интернет).

---

## 🚀 Быстрая установка

Развертывание на чистом сервере Ubuntu (22.04 / 24.04):

```bash
curl -sSL https://raw.githubusercontent.com/justik13/just1knode/main/just1knode.sh | bash
```

После выполнения команды в системе автоматически регистрируется глобальная утилита `/usr/local/bin/just1knode`.

---

## 🛠 Поддерживаемые роли узлов

1. **Origin (Головной узел Xray VLESS)**:
   - Входной туннельный шлюз VLESS over XHTTP через Yandex Cloud CDN.
   - Nginx с оптимизацией Zero Buffering и HTTP/1.1 keepalive upstreams (100k запросов).
   - Bodiless GET Uplink (защита от 413 ошибок на CDN-прокси).
   - Локальный FastAPI микросервис управления клиентами `xray-api` (порт 8444).
   - Автоматическое получение и продление SSL через Let's Encrypt (Certbot).

2. **Relay (Промежуточный узел ретрансляции)**:
   - VLESS over TLS прямое туннелирование между CDN/Origin и конечными точками выхода.
   - Автоматический подбор и валидация Let's Encrypt сертификатов по дате выпуска.
   - Полносвязная синхронизация со шлюзом Origin (`just1knode relay add`).

3. **AmneziaWG (Узел Amnezia 2.0 / 3.x)**:
   - Нативный сетевой стек WireGuard/AmneziaWG в ядре Linux (`awg0`).
   - Поддержка расширенных параметров обфускации (`Jc`, `Jmin`, `Jmax`, `S1-S4`, `H1-H4`, `I1-I5`).
   - Изолированный FastAPI микросервис `amnezia-api` (порт 8443) с доступом строго с доверенного IP бота (`BOT_IP`).
   - Динамическое распределение IP-адресов подсети `/22` без лимита в 254 пира.

---

## 📋 Основные команды CLI

```bash
just1knode                      # Интерактивное меню управления
just1knode status               # Полный статус узла, служб и сетевых интерфейсов
just1knode doctor               # Комплексная диагностика (Xray, API, TLS, Nginx, UFW, IPv6, ICMP)
just1knode update               # Штатное обновление модулей узла и микросервисов
just1knode update core          # Обновление бинарного ядра Xray-core до актуальной версии
just1knode reset                # Сброс локальной конфигурации роли узла
just1knode uninstall            # Безопасное удаление утилиты и компонентов с подтверждением
```

### Управление релеями (Origin):

```bash
just1knode relay add "Название" IP PORT DOMAIN SNI   # Добавить узел Relay в ротацию
just1knode relay list                                 # Список активных релеев
just1knode relay rename <ID> "Новое имя"              # Переименовать релей
just1knode relay remove <ID>                          # Удалить релей
```

---

## 🔒 Сетевая безопасность и Zero-Signature

- **Отказоустойчивый фаервол (UFW Fail-Closed)**: Управляющие порты API (`8443/tcp`, `8444/tcp`) открываются строго и адресно для `BOT_IP`. Любая попытка неавторизованного доступа блокируется на уровне ядра.
- **Stealth ICMP Mode**: Отключение ответов на ICMP Echo Request (`net.ipv4.icmp_echo_ignore_all = 1`) с сохранением в `/etc/sysctl.d/99-just1k-stealth.conf` для защиты от DPI-сканеров и активного зондирования.
- **IPv6 Leak Protection**: Принудительное отключение IPv6 стека на уровне ядра (`disable_ipv6 = 1`) для исключения утечек сетевого трафика.
- **Anti-Abuse Engine**: Блокировка SMTP спам-портов (25/tcp) и сигнатур BitTorrent на уровне правил фаервола.

---

## 🏗 Архитектура репозитория

```text
just1knode/
├── just1knode.sh              # Главный исполняемый диспетчер (CLI)
├── VERSION                    # Текущая версия утилиты
├── lib/                       # Библиотеки ядра (common, state, ssl, backup, watchdog)
├── modules/
│   ├── amnezia/               # Модуль AmneziaWG
│   └── xray/                  # Модули Xray (core, origin, relay, relays_manage, api)
├── scripts/
│   ├── xray_api/              # FastAPI служба Xray API + proto + gRPC
│   └── amnezia_api/           # FastAPI служба Amnezia API
├── docs/                      # Инженерно-техническая документация
├── tests/                     # Сьют автоматических тестов
└── .github/workflows/         # CI/CD: ShellCheck + Python tests + Test Suite
```

---

## 📚 Документация

Подробные инженерные руководства доступны в каталоге [docs/](docs/README.md):
- [Руководство по Белому Интернету (Whitelist Master Guide)](docs/WL/WHITELIST_MASTER_GUIDE.md)
- [Спецификация AmneziaWG 2.0 (Amnezia Technical Reference)](docs/amnezia_docs.md)
- [Спецификация клиента INCY (INCY Master Guide)](docs/INCY_MASTER_GUIDE.md)
- [Модель угроз и сетевая безопасность ТСПУ](docs/NETWORK_SECURITY_AND_TSPU.md)
