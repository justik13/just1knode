# Архитектурная карта `just1knode`

## 1. Назначение, стек и способы запуска

`just1knode` (версия `VERSION` / `pyproject.toml`: `3.0.0`) — модульный CLI-менеджер серверных узлов Xray и HTTP-агент управления (`xray-api`) для трёхуровневой топологии:
- `ru_hub` — входной шлюз (VLESS TLS, VLESS XHTTP + CDN-субмодули, проксирование `/sub/` на домен бота, маршрутизация РФ → `direct`, зарубежного трафика → мосты `eu_hub`).
- `eu_hub` — чистый транзитный мост на `443/tcp` (без `freedom`, только форвардинг в `exit_node` + `blackhole`).
- `exit_node` — финальный выходной узел на `443/tcp` (только от разрешённых хабов → `freedom` + Anti-Abuse).

**Стек:**
- **Управление узлом:** Bash (`set -euo pipefail`, принудительный UTF-8) + системный `python3` для JSON/атомарных операций и генерации конфигов (`scripts/config_builder.py`).
- **HTTP-агент `xray-api`:** Python `>=3.12`, FastAPI, Uvicorn, `grpcio`, `protobuf`, Pydantic (`scripts/xray_api/requirements.txt`), запускается в собственном venv `/opt/xray-api/venv`.
- **Системные компоненты хоста (Linux):** `xray` (зафиксирован `XRAY_VERSION_PINNED=26.11.9`, SHA-256 проверка для `amd64` и `arm64-v8a`), `nginx` (+ `libnginx-mod-stream`), `certbot` (Standalone HTTP-01), `ufw`, `iptables` (`xt_string`, `mark`), `vnstat`.
- **Контейнерный стенд:** `Dockerfile` + `docker-entrypoint.sh` поднимают реальный `xray` и `uvicorn` без `systemd`/Nginx.

**Способы запуска и systemd-юниты:**
- **CLI / TUI:** `just1knode.sh` (на хосте устанавливается в `/opt/just1knode` с симлинком `/usr/local/bin/just1knode`). При запуске через pipe (`curl | bash`) или без `lib/common.sh` рядом выполняет автономный bootstrap из архива GitHub (с защитой от path traversal) и `exec`. Без аргументов открывает `main_menu`; на чистом сервере запускает мастер `ensure_v2_base_stack_installed` с полной очисткой при отмене.
- **Основные подкоманды CLI:** `base-install`, `role [select|change]`, `ru-hub`, `eu-hub`, `exit-node`, `vless-tls [install|uninstall]`, `vless-xhttp [install|uninstall]`, `yandex-cdn [install|uninstall]`, `turboflare [install|uninstall]`, `module <id> [install|uninstall]`, `creds`, `apply-pending`, `backup`, `restore`, `limit [set|reset-day|disable|check|status]`, `status`, `doctor`, `heal`, `set-bot-ip`, `--apply-antiabuse`, `remove-antiabuse`, `update [all|core|geo|config]`, `update-post`, `reset`, `uninstall`.
- **Systemd-юниты на боевом узле:**
  - `xray.service` (`modules/xray/core.sh`) — `User=root`, `CAP_NET_ADMIN CAP_NET_BIND_SERVICE`, `LimitNOFILE=1000000`.
  - `xray-api.service` (`scripts/xray_api/xray-api.service`, деплой в `modules/xray/api.sh`) — `User=xrayapi`, `UMask=0007`, `uvicorn app:app --host 127.0.0.1 --port 5001 --workers 1 --proxy-headers --forwarded-allow-ips=127.0.0.1`, `ProtectSystem=strict`, `NoNewPrivileges=true`.
  - `just1knode-apply.path` + `just1knode-apply.service` (`scripts/systemd/`) — root-триггер на появление `/etc/just1knode/.apply_pending`, запускает `oneshot` `/usr/local/bin/just1knode apply-pending`.
  - `just1knode-traffic-limit.timer` + `.service` (`lib/traffic_limit.sh`) — каждые 15 мин вызывает `just1knode limit check`.
  - `just1knode-geodata.timer` + `.service` (`modules/xray/core.sh`) — еженедельно (только для `ru_hub`) запускает `just1knode update geodata --quiet`.
  - `just1knode-antiabuse.service` (`lib/common.sh`) — `oneshot` при загрузке ОС, восстанавливает цепочку `JUST1KNODE-ANTIABUSE`.
  - `nginx.service.d/limits.conf` (`lib/common.sh`) — drop-in `LimitNOFILE=65535`.
- **Обновление (`just1knode update`):** двухфазное (`update_node` → `exec just1knode.sh update-post`), чтобы auto-heal конфигов, прав, UFW, Xray и geodata выполнялся уже новым кодом на диске; при сбое синхронизации `/opt/just1knode` или `/opt/xray-api` (включая `venv`) выполняется транзакционный откат.

## 2. Ключевые директории и файлы

- `just1knode.sh` — главный диспетчер CLI, TUI-панель, bootstrap-установщик, `status`, `doctor` (полный аудит модулей, служб, gRPC, Xray, Nginx, SSL, UFW, мостов, `/sub/`, XHTTP через CDN, Anti-Abuse, IPv6, ICMP), `reset`, `uninstall` (полное удаление с fail-closed верификацией остатков).
- `lib/`:
  - `lib/common.sh` — логирование, межпроцессная блокировка `flock`, валидация IPv4/FQDN, sysctl hardening (BBR, отключение IPv6, ICMP stealth, conntrack), Zero-Lockout UFW и синхронизация белых списков портов (`8444`, `443`), `set_bot_ip`, генерация `just1k-xhttp-upstreams.conf`, правила iptables `JUST1KNODE-ANTIABUSE`.
  - `lib/state.sh` — атомарные операции с `state.json` и `links.json` (`fcntl.flock`, `O_NOFOLLOW`, `os.replace`), fail-closed защита от битого JSON (`.corrupted.bak`), helpers для `modules`.
  - `lib/module_loader.sh` — динамический загрузчик `modules/transports/*.sh` с изоляцией сбоев (проверка `bash -n`, контракта функций и JSON-метаданных/спецификаций, запись ошибок в `module_errors.json`), общий жизненный цикл CDN-модулей.
  - `lib/builder.sh` — обёртка над `scripts/config_builder.py`: валидация `xray run -test`, выкладка конфигов Xray и Nginx, чистка legacy stream443, `nginx -t` с полным откатом при ошибке.
  - `lib/ssl.sh` — проверка/автовыпуск сертификатов Let's Encrypt (Standalone HTTP-01 с временным открытием `:80` и остановкой Nginx/Docker на `:80`), синхронизация копий в `/usr/local/etc/xray/tls/`, деплой renewal-хуков (`pre`/`post`/`deploy`).
  - `lib/traffic_limit.sh` — учёт месячного трафика через `vnstat --json m 1`, управление конфигом лимита, таймером и флагом `traffic_limit_exceeded`.
  - `lib/backup.sh` — файловые бэкапы (ретеншен `BACKUP_RETENTION_COUNT=10`) и tar-архивация/восстановление `/usr/local/etc/xray` и `/etc/just1knode` (с защитой от path traversal).
- `modules/`:
  - `modules/xray/core.sh` — установка/обновление `Xray-core` (SHA-256 + тест конфига + откат), обновление `geoip.dat`/`geosite.dat` (SHA-256 + тест через `XRAY_LOCATION_ASSET`), таймер geodata, двухфазный `update_node`/`update_node_post`.
  - `modules/xray/api.sh` — пользователь/группа `xrayapi`, деплой кода и venv в `/opt/xray-api`, генерация `config.env`, `xray-api.service`, `just1knode-apply.{path,service}`, `harden_node_permissions`.
  - `modules/roles/base.sh` — stub-конфиг Xray, Nginx API `:8444` и fallback `:80`, транзакционное применение `apply_v2_hub_configuration` (с хэш-дедупликацией `.applied_xray_hash` и откатом), `apply_pending_node_updates`, мастер `select_role_wizard` и `change_role_guarded`.
  - `modules/roles/ru_hub.sh`, `modules/roles/eu_hub.sh`, `modules/roles/exit_node.sh` — ролевые TUI-меню и локальное управление связями/белыми списками.
  - `modules/transports/vless_tls.sh`, `modules/transports/vless_xhttp.sh` — базовые транспортные модули для `ru_hub`.
  - `modules/transports/cdn_yandex.sh`, `modules/transports/cdn_turboflare.sh` — дочерние CDN-модули (`parent: "vless_xhttp"`) со спецификациями портов, тегов, параметров XHTTP и списков CIDR провайдеров.
- `scripts/`:
  - `scripts/config_builder.py` — единый детерминированный генератор JSON-конфига Xray и Nginx-конфига `just1k-ru-hub.conf`.
  - `scripts/systemd/just1knode-apply.path`, `scripts/systemd/just1knode-apply.service` — юниты root-применения отложенных изменений.
  - `scripts/xray_api/`:
    - `scripts/xray_api/app.py` — FastAPI-приложение, аутентификация/rate-limit, lifespan (восстановление клиентов + фоновый SOCKS5 bridge-probe на `ru_hub`), epoch fencing, идемпотентность, телеметрия.
    - `scripts/xray_api/schemas.py` — Pydantic-схемы и строгие валидаторы UUID, IPv4, FQDN SNI и безопасных путей Nginx/XHTTP.
    - `scripts/xray_api/xray_grpc.py` — gRPC-клиент к Xray (`HandlerService`, `StatsService`) и in-memory реестр `_active_users`.
    - `scripts/xray_api/client_store.py` — локальный crash-recovery кэш `clients.json` с per-service состояниями, версиями и tombstone (автоочистка старше 14 дней).
    - `scripts/xray_api/epoch_manager.py` — вычисление и хранение `node_epoch` по `xray_pid`, `starttime` (`/proc/<pid>/stat`) и `boot_id` (`/proc/sys/kernel/random/boot_id`).
    - `scripts/xray_api/idempotency_store.py` — SQLite WAL-хранилище идемпотентных ответов (ротация при `>2000` записей).
    - `scripts/xray_api/compile_proto.py`, `scripts/xray_api/proto/`, `scripts/xray_api/generated/` — `.proto` Xray и каталог скомпилированных gRPC-стабов.
    - `scripts/xray_api/requirements.txt`, `scripts/xray_api/xray-api.service` — зависимости и шаблон юнита.
- Конфигурация и CI: `VERSION`, `pyproject.toml`, `.shellcheckrc`, `.github/workflows/tests.yml` (ShellCheck, `compileall`, `ruff`, `pytest`), `Dockerfile`, `docker-entrypoint.sh`, `tests/test_config_builder.py`.

## 3. Основные потоки и контракт `just1knode` ↔ `just1kbot`

### Потоки установки и конфигурации
1. **Bootstrap и роль:** `ensure_v2_base_stack_installed` ставит базовые пакеты, Nginx, sysctl hardening, `vnstat`, Xray со stub-конфигом, `xray-api`, UFW (`BOT_IP` → `8444/tcp`) → вызывает `select_role_wizard` (роль + FQDN → выпуск Let's Encrypt → инициализация `state.json` и `tunnel_uuid` для `eu_hub`/`exit_node`).
2. **Сборка и применение конфигов:** `apply_v2_hub_configuration` (`modules/roles/base.sh`) → бэкапит текущие конфиги Xray/Nginx → применяет sysctl и синхронизирует TLS → вызывает `assemble_v2_hub_config` (`lib/builder.sh`) → запускает `scripts/config_builder.py` → проверяет `xray run -test` → атомарно обновляет `config.json` → генерирует `just1k-ru-hub.conf` (или `just1k-fallback80.conf`) + `just1k-xhttp-upstreams.conf` → проверяет `nginx -t` → перезагружает Nginx и перезапускает Xray (только при изменении SHA-256 конфига) → обновляет geodata-таймер, UFW и Anti-Abuse. При сбое `nginx -t` или старта `xray` выполняется откат конфигов.
3. **Асинхронное обновление топологии от бота:** бот шлёт `PUT /v1/node/links` → `xray-api` валидирует схему, атомарно пишет `links.json` и создаёт `.apply_pending` → `just1knode-apply.path` запускает root-процесс `just1knode apply-pending` → переносит `.apply_pending` в `.apply_running`, выполняет `apply_v2_hub_configuration` (до 3 проходов при новых запросах во время сборки) и фиксирует итог в `last_apply.json`.
4. **Проксирование подписок (`/sub/`):** на `ru_hub` при сборке `just1k-ru-hub.conf` (активен `vless_xhttp` **или** есть локационные маршруты Стандарта `/std/<loc>`) и заданном `bot_domain` Nginx проксирует `/sub/` (и кастомный `sub_path_prefix`, если не под `/sub/`) на `https://<bot_domain>` (`proxy_ssl_server_name on`), восстанавливая реальный IP клиента через `geo` (доверенные CIDR активных CDN) + `map` (включая `X-Forwarded-For-Y`) в `X-Real-IP` и `X-Forwarded-For`.

### HTTP-контракт `xray-api` (`just1kbot` → `just1knode`)
- **Периметр и авторизация:** Nginx терминирует TLS на `:8444` (открыт в UFW строго для `BOT_IP`) и проксирует в `127.0.0.1:5001`. Документация OpenAPI/Swagger отключена. Все `/v1/*` требуют заголовок `X-API-Key` (`secrets.compare_digest` с `XRAY_API_KEY`). При 15 ошибках авторизации за 60 с с одного IP возвращается `429` + `Retry-After` (блокировка 120 с). Успешный `/v1/*` запрос обновляет `bot_status.json` (не чаще раза в 30 с).
- **`GET /healthz`, `GET /health`** (без `X-API-Key`): fail-closed liveness/readiness (`200` или `503` при падении Xray/gRPC или `epoch_synced=false`), возвращает только `{ok, status, service, xray_running, grpc_ok, epoch_synced}` без секретов.
- **`GET /v1/health`** (auth): полный health + auto-discovery + телеметрия. Fail-closed `503` при сбое Xray/gRPC, порче `clients.json` или рассинхронизации эпохи. Возвращает метаданные узла (`role`, `country_code`, `domain`, `cdn_domain`, `cdn_domains`, `sub_path_prefix`, `secret_base_path`, `bridge_uuid`, `modules`, `module_errors`, `last_apply`, `ssl_cert`, `links`, `sni_routes`, `xhttp_locations`, `inbounds`, `traffic_limit`, `bot_connected`, `bot_last_seen_at`, `system_load`) и health-поля (`xray_running`, `grpc_ok`, `active_clients_count`, `services`, `capabilities`, `node_epoch`, `boot_id`, `starttime`, `sync_status`, `synchronized`, `last_synced_at`, `disk_usage`, на `ru_hub` также `bridge_health`).
- **`GET /v1/node/status`** (auth): read-only метаданные узла (без health-полей).
- **`PUT /v1/node/links`** (auth): тело `NodeLinksUpdateRequest` (`standard`, `bi`, `probe_bridges`, `exit_nodes`, `allowed_ru_ips`, `allowed_hub_ips`, `incoming_ru_hubs`, `incoming_hubs`, `routes`). Сохраняет `links.json` и ставит `.apply_pending` (если содержимое совпало и `last_apply.json.ok == true` или apply уже идёт — возвращает `unchanged: true`).
- **`GET /v1/traffic/snapshot`** (auth): на `eu_hub`/`exit_node` возвращает хостовые счётчики `/proc/net/dev` и `users: {}`. На `ru_hub` делает double-checked чтение эпохи до/после gRPC `QueryStats(pattern="user>>>", reset=False)` (fallback: `GetUsersStats`, до 3 попыток, при дрейфе эпохи — `503`, при сбое gRPC — `502`). Возвращает `node_epoch`, `boot_id`, `starttime`, `timestamp`, `users`, `users_by_service` (`vless` по `:std`, `white_internet` по `:wi`, агрегация по `email.split(":")[0]`), `host_tx_bytes`, `host_rx_bytes`.
- **`POST /v1/clients/sync` и `POST /v1/clients`** (auth): тело `ClientSyncRequest` (`client_id`/`uuid`, `desired_state`/`state`/`is_active`, `version`, `email`, `expected_node_epoch`, `idempotency_key`, `service`: `"vless"|"white_internet"|"wl"`).
  - На `eu_hub`/`exit_node` — no-op (`status: "success"`, `inbounds: []`).
  - Двухфазный epoch fencing: проверка `expected_node_epoch` до мутации (`412`) и неизменности эпохи после (`412`).
  - Монотонный per-service version fencing: устаревшая версия или tombstone → `200` с `result: "already_newer"`, `fenced: true`.
  - Долговременная идемпотентность (`idempotency_key` в SQLite с проверкой совпадения параметров → `409` при конфликте, валидация против эпохи и `client_store`).
  - Применение через gRPC `HandlerService.AlterInbound` (`AddUserOperation` / `RemoveUserOperation`), read-after-write проверка и откат RAM Xray при частичном сбое, ошибке верификации или ошибке записи `clients.json` (`500`).
- **`POST /v1/clients/batch-sync`** (auth): тело `ClientBatchSyncRequest` (`clients`, до 2000 записей). Выполняется под `_state_mutation_lock`, сохраняет `clients.json` одной атомарной записью (при сбое диска откатывает все gRPC-мутации), возвращает `{status: "ok"|"partial", succeeded, failed}`.
- **`DELETE /v1/clients/{uuid}`** (auth, query: `version`, `service`): удаляет клиента из целевых инбаундов, проверяет эпоху (`412`), пишет `tombstone` в `clients.json` и очищает `idempotency.db` по `client_id`.
- **`POST /v1/clients/inventory` и `GET /v1/clients/inventory`** (auth, опционально `InventoryRequest`: `client_ids` до 1000, `service`): возвращает `node_epoch`, `managed_inbounds`, `inventory` (`observed_state`: `"active"|"disabled"|"partial"`, `inbounds`, `all_inbounds_matched`, `version`). Без `client_ids` включает активных и недавних (48 ч) неактивных/tombstoned клиентов.

## 4. Хранение данных, внешние интеграции и переменные окружения

**Пути на диске:**
- Установка CLI: `/opt/just1knode` (включая маркер `/opt/just1knode/COMMIT`), симлинк `/usr/local/bin/just1knode`.
- Агент API: `/opt/xray-api` (исходники + `venv`), `/etc/xray-api/config.env` (`640 root:xrayapi`), `/var/lib/xray-api/epoch.json` и `epoch.lock` (`xrayapi:xrayapi`).
- Состояние `/etc/just1knode` (SGID `2770 root:xrayapi`):
  - `state.json` (`640`, read-only для `xrayapi`) + `.lock` — роль, домен, `api_key`, `api_url`, `bot_ip`, `country_code`, `tunnel_uuid`, `secret_base_path`, `bot_domain`, `sub_path_prefix`, `cdn_domain`, `abuse_protection`, `repo_ref`, `modules`, локальные whitelist IP.
  - `clients.json` (`660`) + `.lock` — локальный crash-recovery кэш клиентов (`clients.<uuid>.service_states`, `service_emails`, `tombstone`).
  - `links.json` (`660`) + `.lock` — связи топологии от админки бота.
  - `idempotency.db` (+ WAL, `660`) — SQLite-кэш идемпотентных операций.
  - `.apply_pending` (`660`), `.apply_running` (`644`), `last_apply.json` (`644`), `.applied_xray_hash` (`644`).
  - `bot_status.json` (`640`), `module_errors.json` (`640`), `traffic_limit.json` (`640`), `traffic_limit_exceeded` (флаг).
- Xray: `/usr/local/bin/xray`, `/usr/local/etc/xray/config.json` (`640 root:xrayapi`), `/usr/local/etc/xray/tls/`, `/usr/local/share/xray/{geoip.dat,geosite.dat}`.
- Nginx и SSL: `/etc/nginx/sites-{available,enabled}/{just1k-vless-api,just1k-ru-hub,just1k-fallback80}.conf`, `/etc/nginx/conf.d/just1k-xhttp-upstreams.conf`, `/etc/nginx/fallback_ssl/`, `/etc/letsencrypt/live/<domain>/`, `/etc/letsencrypt/renewal-hooks/{pre,post,deploy}/`.
- Система и бэкапы: `/etc/sysctl.d/99-disable-ipv6.conf`, `/etc/modules-load.d/just1knode.conf`, `/etc/ufw/sysctl.conf`, `/var/backups/just1knode/`, `/run/lock/just1knode/just1knode.lock`, флаги `/run/just1knode_*`.

**Внешние интеграции:**
- GitHub: архивы и `git ls-remote` для `justik13/just1knode`, релизы `XTLS/Xray-core`, `XTLS/Xray-rules-dat` (`geoip-lite.dat`, `geosite.dat` + `.sha256sum`).
- Let's Encrypt ACME (`certbot certonly --standalone --http-01-port 80`).
- Детекция IPv4 (`api.ipify.org`, `ifconfig.me`, `icanhazip.com`) и страны (`ipwho.is`, `ipinfo.io`).
- Зондирование мостов с `ru_hub` через локальный SOCKS5 (`BRIDGE_PROBE_URLS`) и Xray `observatory` (`probeURL`, `generate_204`) при балансировке `leastPing`.
- `vnstat` — локальный демон учёта трафика хостинга.

**Критичные переменные окружения (имена из кода):**
- `xray-api` (`/etc/xray-api/config.env`, `scripts/xray_api/*`): `XRAY_API_KEY`, `XRAY_GRPC_HOST`, `XRAY_GRPC_PORT`, `XRAY_CONFIG_PATH`, `CLIENTS_FILE_PATH`, `STATE_FILE_PATH`, `LINKS_FILE_PATH`, `APPLY_PENDING_PATH`, `MODULE_ERRORS_PATH`, `EPOCH_FILE_PATH`, `EPOCH_LOCK_PATH`, `IDEMPOTENCY_DB_PATH`, `CDN_DOMAIN`, `WHITE_INTERNET_CDN_DOMAIN`, `WHITE_INTERNET_PATH`, `WHITE_INTERNET_SUB_PATH_PREFIX`, `XRAY_INBOUND_TAGS`, `SSL_CERT_PATH`, `XRAY_TLS_DIR`, `LETSENCRYPT_DIR`, `BRIDGE_PROBE_INTERVAL`, `BRIDGE_PROBE_TIMEOUT`, `BRIDGE_PROBE_MIN_BYTES`, `BRIDGE_PROBE_URLS`.
- CLI / инсталлятор (`just1knode.sh`, `lib/*`, `modules/*`): `INSTALL_DIR`, `STATE_DIR`, `STATE_FILE`, `CLIENTS_FILE`, `LINKS_FILE`, `BACKUP_DIR`, `BACKUP_RETENTION_COUNT`, `XRAY_BIN`, `XRAY_CONFIG_DIR`, `XRAY_CONFIG`, `XRAY_SHARE_DIR`, `XRAY_VERSION_PINNED`, `XRAY_GEODATA_BASE_URL`, `XRAY_API_DIR`, `XRAY_API_ETC`, `XRAY_API_LIB`, `XRAY_API_CONFIG_ENV`, `NGINX_CONF_DIR`, `SYSTEMD_SYSTEM_DIR`, `MODULES_TRANSPORTS_DIR`, `MODULE_ERRORS_FILE`, `JUST1KNODE_REPO_URL`, `JUST1KNODE_REF`, `JUST1KNODE_ROLE`, `JUST1KNODE_DOMAIN`, `JUST1KNODE_COUNTRY`, `JUST1KNODE_GLOBAL_BIN`, `JUST1KNODE_INTERACTIVE`, `JUST1KNODE_ALLOW_CUSTOM_INSTALL_RM`.
- Docker-стенд (`docker-entrypoint.sh`): `NODE_ROLE`, `PORT`, `GRPC_PORT`, `XRAY_API_KEY`, `LOCATION_CODE`, `DOMAIN`.

## 5. Неочевидные ограничения, инварианты и жёсткие связи

1. **Изоляция привилегий (`xrayapi` vs `root`):** `xray-api` не имеет прав root, `state.json` открыт ему строго на чтение (`640`), а пересборка Xray/Nginx/UFW делегирована root-службе через файловый триггер `.apply_pending` → `just1knode-apply.path`. Зависший `.apply_running` старше `150` с или старше `btime` ОС автоматически очищается агентом.
2. **Строго `--workers 1` и `--proxy-headers` в Uvicorn (`xray-api.service`):** `_active_users`, `_active_users_epoch`, `_state_mutation_lock`, `_inflight_op_locks`, `_bridge_health_state` и кэш auth rate-limit живут в памяти одного процесса (несколько воркеров нарушат инварианты). Флаги `--proxy-headers --forwarded-allow-ips=127.0.0.1` критичны для корректного `request.client.host` в auth rate-limit за Nginx `:8444`.
3. **Жёсткое разделение `vless` (`:std`) и `white_internet` (`:wi`) и локационная маршрутизация по email:**
   - Теги инбаундов разделены пространствами имён: `just1k-vless-*` / `just1k-vless-direct` (`vless`; только `just1k-vless-direct` использует `flow: xtls-rprx-vision`) и `just1k-wl-*` (`white_internet`; `flow: ""`).
   - На `exit_node` входной bridge-инбаунд тоже носит тег `just1k-vless-direct` (без `fallbacks`), поэтому `get_all_managed_inbounds()` обязан явно возвращать `[]` для ролей `eu_hub`/`exit_node`.
   - Формат Xray email критичен сразу для двух механизмов: на `ru_hub` прямой `just1k-vless-direct` (`:443`) маршрутизирует клиента в конкретную локацию `exit_node` по `user` regex (`regexp::<loc>:std$` / `regexp::<loc>$`, передаётся ботом как `<device_uuid>:<loc>:std`), а `GET /v1/traffic/snapshot` разделяет и агрегирует трафик по суффиксам `:std` / `:wi` и префиксу `email.split(":")[0]` (символ `>>>` запрещён валидатором, т.к. это разделитель `QueryStats`).
   - Порты на `ru_hub` фиксированы/выделяются последовательно: базовые CDN — `8003` (`cdn_yandex`), `8004` (`cdn_turboflare`), локационная матрица БИ `локация × CDN` (`just1k-wl-inbound-<loc>__<cdn>`) — от `8005`, локационные XHTTP-инбаунды Стандарта (`/std/<loc>`) — от `8105`, локальный SOCKS5-зонд — `10809`, gRPC API Xray — `127.0.0.1:10085`.
4. **Сцепка портов `443` / `8080` / `80` и порядок сборки Bash ↔ Python:**
   - На `ru_hub` при одновременной работе `vless_tls` и Nginx (`vless_xhttp` или локации `/std/<loc>`) порт `443` занимает Xray и проксирует fallback на `127.0.0.1:8080` с `xver: 1`, а Nginx слушает `127.0.0.1:8080 proxy_protocol`. Без `vless_tls` порт `443 ssl` слушает напрямую Nginx (с `ssl_reject_handshake on` при Nginx `>=1.19.4`). При чистом `vless_tls` без локаций (и на `eu_hub`/`exit_node`) поднимается `just1k-fallback80.conf` на `127.0.0.1:80`.
   - `sync_xhttp_upstreams_conf` (`lib/common.sh`) строит `just1k-xhttp-upstreams.conf`, парся **уже записанный** `/usr/local/etc/xray/config.json`, поэтому порядок в `lib/builder.sh` нельзя менять: `config_builder.py` → `xray run -test` → запись `config.json` → `sync_xhttp_upstreams_conf` → `nginx -t`.
5. **Zero-Leak, Zero-Trust, TLS мостов и связка `mark=255` ↔ `iptables`:**
   - На `ru_hub` `outbounds[0]` обязан быть `just1k-wl-block` (blackhole): зарубежный трафик без моста блокируется, в `direct` идёт только RU-трафик (`geosite:category-ru`, `geosite:tld-ru`, `domain:ru/su/xn--p1ai`, `geoip:ru`).
   - На `eu_hub` `freedom` запрещён; на `eu_hub` и `exit_node` порт `443` закрыт в UFW для мира (whitelist IP из `state.json` и `links.json`), а клиентские API-операции являются no-op.
   - `freedom`-outbounds в `config_builder.py` выставляют `sockopt.mark=255` и `domainStrategy=UseIPv4`; цепочка `JUST1KNODE-ANTIABUSE` в `lib/common.sh` дропает пакеты с `--mark 255` в приватные/loopback CIDR (защита от SSRF).
   - Для всех bridge-узлов обязателен FQDN в `sni` (голый IP отклоняется и в `schemas.py`, и в `config_builder.py`). Плечо `ru_hub` → `eu_hub` использует `fingerprint: "firefox"`, `eu_hub` → `exit_node` — `fingerprint: "unsafe"`; при наличии `/usr/local/share/ca-certificates/just1k-internal-ca.crt` или `/etc/just1knode/ca.crt` подключается внутренний CA для проверки TLS мостов.
6. **Иерархия модулей, Fault Isolation и смена роли:**
   - `cdn_yandex` и `cdn_turboflare` зависят от родителя `vless_xhttp` (нельзя установить CDN без `vless_xhttp` и нельзя удалить `vless_xhttp` при активном CDN).
   - `change_role_guarded` запрещает смену роли при `count_enabled_modules > 0`.
   - Битый модуль в `modules/transports/` изолируется в `BROKEN_MODULE_IDS` / `module_errors.json` и передаётся в `config_builder.py` через `broken_csv`, не ломая остальные транспорты и обновление ядра.
7. **Атомарность, хэш-дедупликация и `EpochManager`:**
   - `apply_v2_hub_configuration` пропускает `systemctl restart xray`, если SHA-256 нового `config.json` совпадает с `.applied_xray_hash` и `xray` активен.
   - При перезапуске `xray` смена `(pid, starttime)` создаёт новую `node_epoch`, после чего `xray-api` инвалидирует `_active_users` и восстанавливает активных клиентов из `clients.json` (не SSOT, а ephemeral crash-recovery hint; при сбоях восстановления действует cooldown `60` с).
   - На `ru_hub` фоновый SOCKS5-зонд (`_bridge_probe_loop`) проверяет до 2 тегов на IP `eu_hub` строго последовательно (пауза `1.5` с, минимум `36864` байт) и автоматически пропускает цикл во время `.apply_pending`/`.apply_running`.
8. **Инвариант `traffic_limit_exceeded`:** `lib/traffic_limit.sh` не создаёт systemd drop-in в `xray.service.d`, а использует файл-флаг `/etc/just1knode/traffic_limit_exceeded`. При его наличии конфиги/бинарники/сертификаты/гео-базы обновляются без запуска `xray`.
9. **Fail-closed защита от порчи и symlink PrivEsc:** `lib/state.sh`, `scripts/config_builder.py` и `ClientStore` отказываются перезаписывать повреждённые JSON-файлы; `harden_node_permissions` и `init_state_dir` удаляют неожиданные симлинки на конфигах/state-файлах; `config_builder.py` и `schemas.py` отклоняют небезопасные пути Nginx (`..`, зарезервированные `/sub`, `/std`, `/none` для `secret_base_path`).
