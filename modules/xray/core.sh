#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE - Модуль Xray Core (modules/xray/core.sh)
# =============================================================================

XRAY_VERSION_PINNED="${XRAY_VERSION_PINNED:-26.11.9}"
XRAY_SHA256_64="b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82"
XRAY_SHA256_ARM64="64ed6858982a7f5eb85d88b811089063bd4f17561f4c8f44e0f1dc8e6f6430be"

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONFIG_DIR="${XRAY_CONFIG_DIR:-/usr/local/etc/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-${XRAY_CONFIG_DIR}/config.json}"
XRAY_SHARE_DIR="${XRAY_SHARE_DIR:-/usr/local/share/xray}"
SYSTEMD_SYSTEM_DIR="${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"

download_and_verify_xray() {
    local target_zip="$1"
    local arch
    arch="$(get_arch)"
    local url="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION_PINNED}/Xray-linux-${arch}.zip"
    local expected_hash="$XRAY_SHA256_64"
    if [[ "$arch" == "arm64-v8a" ]]; then
        expected_hash="$XRAY_SHA256_ARM64"
    fi

    log "Скачивание Xray-core v${XRAY_VERSION_PINNED} (${arch})..."
    if ! curl -fsSL --connect-timeout 15 --max-time 120 "$url" -o "$target_zip"; then
        error "Не удалось скачать Xray-core по адресу: $url"
    fi

    log "Проверка контрольной суммы SHA-256..."
    local actual_hash
    actual_hash="$(sha256sum "$target_zip" | awk '{print $1}')"
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        rm -f "$target_zip"
        error "Контрольная сумма SHA-256 не совпадает! Ожидалось: $expected_hash, получено: $actual_hash"
    fi
    log "Верификация SHA-256 успешно пройдена."
}

install_xray_binaries() {
    local tmp_zip
    tmp_zip="$(mktemp /tmp/xray_install.XXXXXX.zip 2>/dev/null || mktemp)"
    download_and_verify_xray "$tmp_zip"

    mkdir -p "$XRAY_CONFIG_DIR" "$XRAY_SHARE_DIR" "$(dirname "$XRAY_BIN")"
    unzip -q -o "$tmp_zip" xray -d "$(dirname "$XRAY_BIN")"
    unzip -q -o "$tmp_zip" geoip.dat geosite.dat -d "$XRAY_SHARE_DIR/" || true
    rm -f "$tmp_zip"
    chmod +x "$XRAY_BIN"
}

deploy_xray_systemd_service() {
    mkdir -p "${SYSTEMD_SYSTEM_DIR}"
    cat > "${SYSTEMD_SYSTEM_DIR}/xray.service" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=on-failure
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray
}

update_xray_core() {
    title "ОБНОВЛЕНИЕ ЯДРА XRAY-CORE"
    check_root
    init_state_dir

    local current_ver
    current_ver="$($XRAY_BIN version 2>/dev/null | awk 'NR==1 {print $2}')"
    log "Текущая версия Xray: ${current_ver:-не установлена}"

    local force_update=0
    if [[ "${1:-}" == "--force" || "${1:-}" == "-f" || "${FORCE:-}" == "1" ]]; then
        force_update=1
    fi

    if [[ $force_update -eq 0 && -n "$current_ver" && "$current_ver" == "$XRAY_VERSION_PINNED" ]]; then
        log "Ядро Xray уже обновлено до версии ${current_ver}. Обновление не требуется."
        return 0
    fi

    local tmp_dir
    tmp_dir="$(mktemp -d /tmp/xray_update.XXXXXX 2>/dev/null || mktemp -d)"
    local tmp_zip="${tmp_dir}/xray.zip"
    local tmp_extract="${tmp_dir}/extract"
    mkdir -p "$tmp_extract"
    download_and_verify_xray "$tmp_zip"

    unzip -q -o "$tmp_zip" xray -d "${tmp_extract}/"
    chmod +x "${tmp_extract}/xray"

    log "Проверка текущей конфигурации новым бинарником..."
    if "${tmp_extract}/xray" run -test -config "$XRAY_CONFIG"; then
        log "Тест пройден успешно. Создание резервной копии старого бинарника..."
        create_backup "$XRAY_BIN"
        local backup_bin="${LAST_BACKUP_PATH:-}"

        log "Применение обновления..."
        install -m 755 "${tmp_extract}/xray" "$XRAY_BIN"
        if is_traffic_limit_exceeded; then
            warn "Лимит трафика исчерпан — бинарник Xray обновлён без запуска службы."
            log "Обновление бинарника завершено! Версия: $($XRAY_BIN version | head -n 1)"
            rm -rf "$tmp_dir"
            return 0
        fi
        set +e
        systemctl restart xray
        local restart_rc=$?
        set -e

        if [[ $restart_rc -eq 0 ]] && systemctl is-active --quiet xray; then
            if ! ensure_xray_api_healthy; then
                warn "Внимание: служба xray-api не смогла запуститься после перезапуска Xray!"
            fi
            log "Обновление завершено успешно! Версия: $($XRAY_BIN version | head -n 1)"
        else
            warn "Xray не запустился после обновления! Выполняем откат на предыдущую версию..."
            local xray_rb_ok=false
            if [[ -f "$backup_bin" ]]; then
                install -m 755 "$backup_bin" "$XRAY_BIN"
                if systemctl restart xray 2>/dev/null && systemctl is-active --quiet xray 2>/dev/null; then
                    xray_rb_ok=true
                    log "Откат на предыдущую версию успешно выполнен и подтвержден."
                fi
            fi
            if [[ "$xray_rb_ok" != "true" ]]; then
                warn "Служба Xray не смогла перезапуститься после отката на резервную копию!"
            fi
            rm -rf "$tmp_dir"
            error "Обновление прервано из-за сбоя запуска службы."
        fi
    else
        rm -rf "$tmp_dir"
        error "Тест новой версии провалился. Обновление отменено."
    fi
    rm -rf "$tmp_dir"
}

update_node() {
    title "КОМПЛЕКСНОЕ ОБНОВЛЕНИЕ УТИЛИТЫ И КОНФИГУРАЦИИ УЗЛА"
    check_root
    init_state_dir
    cleanup_legacy_traffic_watchdog_residue
    acquire_just1knode_lock
    trap release_just1knode_lock RETURN EXIT

    local target="${1:-all}"
    local is_menu="${2:-0}"

    if [[ "$target" == "core" ]]; then
        update_xray_core
        release_just1knode_lock
        trap - RETURN EXIT
        return
    fi

    info "1/4. Загрузка исходных модулей из репозитория GitHub..."
    local repo_url="${JUST1KNODE_REPO_URL:-${JUST1KBOT_REPO_URL:-https://github.com/justik13/just1knode}}"
    local ref="${JUST1KNODE_REF:-${JUST1KBOT_REF:-main}}"
    local tmp_tar
    tmp_tar="$(mktemp /tmp/just1knode_update.XXXXXX.tar.gz 2>/dev/null || mktemp)"
    local tmp_dir
    tmp_dir="$(mktemp -d /tmp/just1knode_update_dir.XXXXXX 2>/dev/null || mktemp -d)"

    local archive_urls=()
    if [[ "$ref" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
        archive_urls+=("${repo_url}/archive/${ref}.tar.gz")
    else
        archive_urls+=(
            "${repo_url}/archive/${ref}.tar.gz"
            "${repo_url}/archive/refs/tags/${ref}.tar.gz"
            "${repo_url}/archive/refs/heads/${ref}.tar.gz"
        )
    fi

    local download_ok=0
    for archive_url in "${archive_urls[@]}"; do
        if curl -fsSL --connect-timeout 15 --max-time 120 "$archive_url" -o "$tmp_tar" 2>/dev/null || wget -q --timeout=120 --tries=2 -O "$tmp_tar" "$archive_url" 2>/dev/null; then
            download_ok=1
            break
        fi
    done

    if [[ $download_ok -eq 1 ]]; then
        info "2/4. Распаковка и проверка целостности архива..."
        if ! tar -xzf "$tmp_tar" -C "$tmp_dir" --strip-components=1 --no-same-owner 2>/dev/null; then
            rm -rf "$tmp_tar" "$tmp_dir"
            error "Ошибка целостности архива: распаковка не удалась. Обновление прервано."
        fi

        local node_src_dir=""
        if [[ -d "${tmp_dir}/just1knode" ]]; then
            node_src_dir="${tmp_dir}/just1knode"
        elif [[ -f "${tmp_dir}/just1knode.sh" ]]; then
            node_src_dir="${tmp_dir}"
        fi

        # Валидация синтаксиса shell-скриптов перед установкой (с изоляцией независимых модулей transports/)
        local broken_transport_names=()
        if [[ -n "$node_src_dir" ]]; then
            local syntax_err=0
            while IFS= read -r -d '' sh_file; do
                if [[ "$sh_file" == *"/modules/transports/"* ]]; then
                    if ! bash -n "$sh_file"; then
                        local b_name
                        b_name="$(basename "$sh_file")"
                        broken_transport_names+=("$b_name")
                        warn "Модуль '${b_name}' содержит синтаксическую ошибку и изолирован от обновления (остальные компоненты обновятся)."
                    fi
                else
                    if ! bash -n "$sh_file"; then
                        warn "Критическая синтаксическая ошибка в ядре обновления: $sh_file"
                        syntax_err=1
                    fi
                fi
            done < <(find "$node_src_dir" -maxdepth 4 -type f -name "*.sh" -print0 2>/dev/null)

            if [[ $syntax_err -ne 0 ]]; then
                rm -rf "$tmp_tar" "$tmp_dir"
                error "Обновление прервано: обнаружены синтаксические ошибки в базовых файлах релиза."
            fi
        fi

        # Обновление модулей утилиты и/или API
        if [[ -n "$node_src_dir" || -d "${tmp_dir}/scripts/xray_api" ]]; then
            info "3/4. Синхронизация модулей и сервисов узла..."
            # Подготовка безопасного каталога для резервных копий
            local backup_root=""
            local node_backup=""
            local code_backup=""
            local venv_backup=""
            local node_dir="${INSTALL_DIR:-/opt/just1knode}"
            local api_dir="${XRAY_API_DIR:-/opt/xray-api}"
            local api_was_active=false

            mkdir -p "${BACKUP_DIR:-/var/backups/just1knode}"
            chmod 700 "${BACKUP_DIR:-/var/backups/just1knode}" 2>/dev/null || true
            backup_root="$(mktemp -d "${BACKUP_DIR:-/var/backups/just1knode}/update_bak.XXXXXXXXXX" 2>/dev/null || mktemp -d -t just1knode_update_bak.XXXXXXXXXX)"
            chmod 700 "$backup_root" 2>/dev/null || true

            # 1. Резервная копия just1knode
            if [[ -n "$node_src_dir" && -d "$node_dir" ]]; then
                node_backup="${backup_root}/just1knode"
                mkdir -p "$node_backup"
                if ! cp -a "${node_dir}/." "$node_backup/" 2>/dev/null; then
                    rm -rf "$backup_root" "$tmp_tar" "$tmp_dir"
                    error "Не удалось создать резервную копию ${node_dir}. Обновление отменено."
                fi
            fi

            # 2. Резервная копия xray-api и venv
            if [[ -d "${tmp_dir}/scripts/xray_api" && -d "$api_dir" ]]; then
                if systemctl is-active --quiet xray-api 2>/dev/null; then
                    api_was_active=true
                fi
                code_backup="${backup_root}/xray_api"
                mkdir -p "$code_backup"
                if ! cp -a "${api_dir}/." "$code_backup/" 2>/dev/null; then
                    rm -rf "$backup_root" "$tmp_tar" "$tmp_dir"
                    error "Не удалось создать резервную копию исходных файлов ${api_dir}. Обновление отменено."
                fi
                rm -rf "$code_backup"/venv*

                if [[ -d "${api_dir}/venv" ]]; then
                    venv_backup="${api_dir}/venv_bak_$$"
                    if ! cp -a "${api_dir}/venv" "$venv_backup" 2>/dev/null; then
                        rm -rf "$backup_root" "$venv_backup" "$tmp_tar" "$tmp_dir"
                        error "Не удалось создать резервную копию venv для ${api_dir}. Обновление отменено."
                    fi
                fi
            fi

            # Функция транзакционного отката компонентов узла
            rollback_node_components() {
                warn "Сбой обновления компонентов узла! Запуск транзакционного отката..."
                local rb_ok=true

                # Откат just1knode
                if [[ -n "$node_backup" && -d "$node_backup" ]]; then
                    find "$node_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
                    if ! cp -a "$node_backup"/. "${node_dir}/" 2>/dev/null; then
                        warn "Критическая ошибка: не удалось восстановить файлы ${node_dir} из бэкапа!"
                        rb_ok=false
                    else
                        if [[ -f "${node_dir}/just1knode.sh" ]]; then
                            chmod +x "${node_dir}/just1knode.sh" 2>/dev/null || true
                            ln -sf "${node_dir}/just1knode.sh" /usr/local/bin/just1knode 2>/dev/null || true
                        fi
                        log "Модули ${node_dir} успешно восстановлены из резервной копии."
                    fi
                fi

                # Откат xray-api
                if [[ -n "$code_backup" && -d "$code_backup" ]]; then
                    find "$api_dir" -mindepth 1 -maxdepth 1 ! -name 'venv*' -exec rm -rf {} + 2>/dev/null || true
                    if ! cp -a "$code_backup"/. "${api_dir}/" 2>/dev/null; then
                        warn "Критическая ошибка: не удалось восстановить файлы ${api_dir} из бэкапа!"
                        rb_ok=false
                    fi
                    if [[ -n "$venv_backup" && -d "$venv_backup" ]]; then
                        rm -rf "${api_dir}/venv"
                        if ! mv "$venv_backup" "${api_dir}/venv" 2>/dev/null; then
                            warn "Критическая ошибка: не удалось восстановить venv для ${api_dir}!"
                            rb_ok=false
                        fi
                        venv_backup=""
                    fi
                    ensure_xrayapi_user
                    chown -R root:xrayapi "$api_dir" 2>/dev/null || true
                    chmod -R 750 "$api_dir" 2>/dev/null || true
                    if [[ "$api_was_active" == "true" ]]; then
                        if ! systemctl restart xray-api 2>/dev/null && ! systemctl start xray-api 2>/dev/null; then
                            warn "Служба xray-api не смогла перезапуститься после отката."
                            rb_ok=false
                        elif ! systemctl is-active --quiet xray-api 2>/dev/null; then
                            warn "Служба xray-api не активна после отката."
                            rb_ok=false
                        else
                            log "Служба xray-api успешно восстановлена и перезапущена на исходной версии."
                        fi
                    fi
                fi

                if [[ "$rb_ok" == "true" ]]; then
                    log "Транзакционный откат компонентов узла успешно завершен и подтвержден."
                    rm -rf "$backup_root"
                    return 0
                else
                    warn "ВНИМАНИЕ: Откат завершился с ошибками! Резервная копия сохранена в: ${backup_root}"
                    warn "Используйте данную директорию для ручного восстановления узла."
                    return 1
                fi
            }

            # 3. Установка обновлений just1knode
            if [[ -n "$node_src_dir" ]]; then
                mkdir -p "$node_dir"
                find "$node_dir" -mindepth 1 -maxdepth 1 ! -name 'scripts' -exec rm -rf {} + 2>/dev/null || true
                local copy_ok=1
                if [[ "$node_src_dir" == "${tmp_dir}/just1knode" ]]; then
                    cp -a "${node_src_dir}/." "${node_dir}/" 2>/dev/null || copy_ok=0
                else
                    cp -a "${node_src_dir}/just1knode.sh" "${node_dir}/" 2>/dev/null || copy_ok=0
                    cp -a "${node_src_dir}/VERSION" "${node_dir}/" 2>/dev/null || true
                    cp -a "${node_src_dir}/lib" "${node_dir}/" 2>/dev/null || copy_ok=0
                    cp -a "${node_src_dir}/modules" "${node_dir}/" 2>/dev/null || copy_ok=0
                fi
                if [[ $copy_ok -ne 1 ]]; then
                    rollback_node_components || true
                    rm -rf "$tmp_tar" "$tmp_dir"
                    error "Не удалось скопировать модули в ${node_dir}. Обновление прервано."
                fi
                # Изоляция повреждённых транспортных модулей: не ломаем работающий узел, откатываем только проблемный модуль
                if [[ ${#broken_transport_names[@]} -gt 0 ]]; then
                    local bn
                    for bn in "${broken_transport_names[@]}"; do
                        rm -f "${node_dir}/modules/transports/${bn}" 2>/dev/null || true
                        if [[ -n "$node_backup" && -f "${node_backup}/modules/transports/${bn}" ]] && bash -n "${node_backup}/modules/transports/${bn}" 2>/dev/null; then
                            cp -a "${node_backup}/modules/transports/${bn}" "${node_dir}/modules/transports/${bn}" 2>/dev/null || true
                            warn "Модуль '${bn}': оставлена предыдущая рабочая версия."
                        fi
                    done
                fi
                if [[ -d "${node_src_dir}/scripts/systemd" ]]; then
                    mkdir -p "${node_dir}/scripts/systemd"
                    cp -a "${node_src_dir}/scripts/systemd/." "${node_dir}/scripts/systemd/" 2>/dev/null || true
                fi
                local fetched_sha=""
                if command -v git >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
                    fetched_sha="$(timeout 5s git ls-remote "$repo_url" "refs/heads/${ref}" 2>/dev/null | awk '{print $1}' || true)"
                    if [[ ! "$fetched_sha" =~ ^[0-9a-f]{40}$ ]]; then
                        fetched_sha="$(timeout 5s git ls-remote "$repo_url" "$ref" 2>/dev/null | awk '{print $1}' || true)"
                    fi
                fi
                if [[ ! "$fetched_sha" =~ ^[0-9a-f]{40}$ && "$ref" =~ ^[0-9a-fA-F]{40}$ ]]; then
                    fetched_sha="$ref"
                fi
                if [[ "$fetched_sha" =~ ^[0-9a-f]{40}$ ]]; then
                    printf '%s\n' "$fetched_sha" > "${node_dir}/COMMIT" 2>/dev/null || true
                fi
                if [[ -f "${node_dir}/just1knode.sh" ]]; then
                    chmod +x "${node_dir}/just1knode.sh" 2>/dev/null || true
                    ln -sf "${node_dir}/just1knode.sh" /usr/local/bin/just1knode 2>/dev/null || true
                fi
                if [[ -f "${tmp_dir}/scripts/xray_api/app.py" && \
                      -f "${tmp_dir}/scripts/xray_api/requirements.txt" && \
                      -f "${tmp_dir}/scripts/xray_api/xray-api.service" ]]; then
                    local xray_cache_staging="${node_dir}/scripts/.xray_api_stage_$$"
                    local xray_cache_dest="${node_dir}/scripts/xray_api"
                    rm -rf "$xray_cache_staging"
                    mkdir -p "$xray_cache_staging"
                    if cp -a "${tmp_dir}/scripts/xray_api/." "$xray_cache_staging/" 2>/dev/null; then
                        if [[ -f "${xray_cache_staging}/app.py" && \
                              -f "${xray_cache_staging}/requirements.txt" && \
                              -f "${xray_cache_staging}/xray-api.service" ]]; then
                            rm -rf "${xray_cache_dest}.old"
                            [[ -d "$xray_cache_dest" ]] && mv "$xray_cache_dest" "${xray_cache_dest}.old" 2>/dev/null || true
                            mv "$xray_cache_staging" "$xray_cache_dest" 2>/dev/null || true
                            rm -rf "${xray_cache_dest}.old"
                        fi
                    fi
                    rm -rf "$xray_cache_staging"
                fi
                log "Модули ${node_dir} успешно обновлены и проверены."
            fi

            # 4. Установка обновлений xray-api
            if [[ -d "${tmp_dir}/scripts/xray_api" && -d "$api_dir" ]]; then
                if ! cp -a "${tmp_dir}/scripts/xray_api/." "${api_dir}/" 2>/dev/null; then
                    rollback_node_components || true
                    rm -rf "$tmp_tar" "$tmp_dir"
                    error "Не удалось скопировать исходные файлы ${api_dir}. Обновление прервано."
                fi
                if [[ -x "${api_dir}/venv/bin/pip" && -f "${api_dir}/requirements.txt" ]]; then
                    if ! "${api_dir}/venv/bin/pip" install -q -r "${api_dir}/requirements.txt" --no-cache-dir; then
                        rollback_node_components || true
                        rm -rf "$tmp_tar" "$tmp_dir"
                        error "Ошибка обновления зависимостей Python для xray-api. Обновление прервано."
                    fi
                fi
                ensure_xrayapi_user
                chown -R root:xrayapi "$api_dir" 2>/dev/null || true
                chmod -R 750 "$api_dir" 2>/dev/null || true
                if [[ -f "${api_dir}/xray-api.service" ]]; then
                    cp "${api_dir}/xray-api.service" /etc/systemd/system/xray-api.service 2>/dev/null || true
                    systemctl daemon-reload 2>/dev/null || true
                fi
                if [[ "$api_was_active" == "true" ]]; then
                    systemctl reset-failed xray-api 2>/dev/null || true
                    if ! systemctl restart xray-api 2>/dev/null || ! systemctl is-active --quiet xray-api 2>/dev/null; then
                        rollback_node_components || true
                        rm -rf "$tmp_tar" "$tmp_dir"
                        error "Служба xray-api не смогла перезапуститься после обновления."
                    fi
                fi
                log "Компоненты ${api_dir} успешно обновлены с синхронизацией Python-зависимостей и перезапуском службы."
            fi

            # Полный успех обновления компонентов узла - очистка бэкапов
            rm -rf "$backup_root"
            [[ -n "$venv_backup" && -d "$venv_backup" ]] && rm -rf "$venv_backup"
        fi

        rm -rf "$tmp_tar" "$tmp_dir"
    else
        warn "Не удалось загрузить архив с GitHub. Используем текущие установленные модули для самовосстановления."
        rm -rf "$tmp_tar" "$tmp_dir"
    fi

    # Если модули утилиты были обновлены на диске, перезапускаем второй этап из новой версии,
    # чтобы гарантированно исключить выполнение устаревших функций из памяти Bash
    local node_dir="${INSTALL_DIR:-/opt/just1knode}"
    local bin_path="${node_dir}/just1knode.sh"
    [[ -x "$bin_path" ]] || bin_path="/usr/local/bin/just1knode"
    if [[ -x "$bin_path" ]]; then
        release_just1knode_lock 2>/dev/null || true
        trap - RETURN EXIT
        exec "$bin_path" update-post "$target" "${is_menu:-0}"
    fi

    # Защитный fallback (если exec недоступен): повторная загрузка модулей с диска
    if [[ -d "$node_dir" ]]; then
        source "${node_dir}/lib/common.sh" 2>/dev/null || true
        source "${node_dir}/lib/module_loader.sh" 2>/dev/null || true
        source "${node_dir}/lib/builder.sh" 2>/dev/null || true
        source "${node_dir}/modules/xray/core.sh" 2>/dev/null || true
        source "${node_dir}/modules/roles/base.sh" 2>/dev/null || true
        source "${node_dir}/modules/roles/ru_hub.sh" 2>/dev/null || true
        source "${node_dir}/modules/roles/eu_hub.sh" 2>/dev/null || true
        source "${node_dir}/modules/roles/exit_node.sh" 2>/dev/null || true
        if declare -F load_all_transport_modules >/dev/null 2>&1; then
            load_all_transport_modules || true
        fi
    fi

    update_node_post "$target" "${is_menu:-0}"
}

update_node_post() {
    local target="${1:-all}"
    local is_menu="${2:-0}"

    check_root
    acquire_just1knode_lock
    trap release_just1knode_lock RETURN EXIT

    info "4/4. Самодиагностика, авто-конфигурация и проверка сетевых политик..."
    if declare -F load_all_transport_modules >/dev/null 2>&1; then
        load_all_transport_modules || true
    fi
    heal_node_firewall_and_stealth
    cleanup_legacy_traffic_watchdog_residue
    if declare -f reconcile_traffic_limit_on_update >/dev/null 2>&1; then
        reconcile_traffic_limit_on_update
    fi

    local role
    role="$(get_state_val "role" "unconfigured")"

    if [[ "$role" == "ru_hub" || "$role" == "eu_hub" || "$role" == "exit_node" ]]; then
        if declare -F heal_v2_role_config >/dev/null 2>&1; then
            heal_v2_role_config
        fi
    else
        if declare -F setup_base_api_nginx >/dev/null 2>&1 && [[ -f "${XRAY_API_CONFIG_ENV:-/etc/xray-api/config.env}" ]]; then
            setup_base_api_nginx || true
        fi
        warn "Узел не настроен (роль не определена). Автоматическая оптимизация Xray пропущена."
    fi

    # Обновляем systemd trigger (just1knode-apply.path / service) при наличии xray-api
    if [[ -f "${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}/xray-api.service" ]] && declare -F deploy_apply_trigger_units >/dev/null 2>&1; then
        deploy_apply_trigger_units || true
    fi

    local has_xray="0"
    if [[ "$role" == "ru_hub" || "$role" == "eu_hub" || "$role" == "exit_node" ]] || [[ -x "${XRAY_BIN:-/usr/local/bin/xray}" && -f "${XRAY_CONFIG:-/usr/local/etc/xray/config.json}" ]]; then
        has_xray="1"
    fi

    if [[ "$target" == "all" && "$has_xray" == "1" ]]; then
        update_xray_core
    fi

    title "ОБНОВЛЕНИЕ И АВТО-КОНФИГУРАЦИЯ УЗЛА УСПЕШНО ЗАВЕРШЕНЫ!"
    echo -e "${GREEN}✔ Модули just1knode, сетевые политики и конфигурация роли (${role:-unconfigured}) приведены к эталону.${NC}\n"

    release_just1knode_lock
    trap - RETURN EXIT

    local node_dir="${INSTALL_DIR:-/opt/just1knode}"
    local bin_path="${node_dir}/just1knode.sh"
    [[ -x "$bin_path" ]] || bin_path="/usr/local/bin/just1knode"
    if [[ "$is_menu" == "1" && -x "$bin_path" && -t 0 ]]; then
        read -rp "Нажмите Enter для возврата в меню..."
        exec "$bin_path"
    fi
}

