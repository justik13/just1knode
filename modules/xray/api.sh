#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE - Модуль Xray API Агента (modules/xray/api.sh)
# =============================================================================

XRAY_API_DIR="${XRAY_API_DIR:-/opt/xray-api}"
XRAY_API_ETC="${XRAY_API_ETC:-/etc/xray-api}"
XRAY_API_LIB="${XRAY_API_LIB:-/var/lib/xray-api}"
XRAY_API_CONFIG_ENV="${XRAY_API_CONFIG_ENV:-${XRAY_API_ETC}/config.env}"
SYSTEMD_SYSTEM_DIR="${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
STATE_DIR="${STATE_DIR:-/etc/just1knode}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/state.json}"
CLIENTS_FILE="${CLIENTS_FILE:-${STATE_DIR}/clients.json}"

JUST1KNODE_REPO_URL="${JUST1KNODE_REPO_URL:-${JUST1KBOT_REPO_URL:-https://github.com/justik13/just1knode}}"
JUST1KNODE_REF="${JUST1KNODE_REF:-${JUST1KNODE_BRANCH:-${JUST1KBOT_REF:-${JUST1KBOT_BRANCH:-}}}}"
if [[ -z "$JUST1KNODE_REF" && -d "${INSTALL_DIR:-/opt/just1knode}/.git" ]] && command -v git >/dev/null 2>&1; then
    JUST1KNODE_REF="$(git -C "${INSTALL_DIR:-/opt/just1knode}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
    [[ "$JUST1KNODE_REF" == "HEAD" ]] && JUST1KNODE_REF=""
fi
if [[ -z "$JUST1KNODE_REF" ]] && declare -F get_state_val >/dev/null 2>&1; then
    JUST1KNODE_REF="$(get_state_val "repo_ref" "")"
elif [[ -z "$JUST1KNODE_REF" && -f "${STATE_FILE}" ]] && command -v python3 >/dev/null 2>&1; then
    JUST1KNODE_REF="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("repo_ref") or "")' "${STATE_FILE}" 2>/dev/null || true)"
fi
JUST1KNODE_REF="${JUST1KNODE_REF:-main}"

ensure_xrayapi_user() {
    if ! getent group xrayapi >/dev/null 2>&1; then
        groupadd -r xrayapi 2>/dev/null || true
    fi
    if ! id -u xrayapi >/dev/null 2>&1; then
        if getent group xrayapi >/dev/null 2>&1; then
            useradd -r -g xrayapi -s /usr/sbin/nologin -d "${XRAY_API_DIR}" -M xrayapi 2>/dev/null || useradd -r -s /usr/sbin/nologin -d "${XRAY_API_DIR}" -M xrayapi
        else
            useradd -r -s /usr/sbin/nologin -d "${XRAY_API_DIR}" -M xrayapi
        fi
    fi
    if ! id -u xrayapi >/dev/null 2>&1; then
        warn "Не удалось создать системного пользователя xrayapi"
        return 1
    fi
}

deploy_xray_api_sources() {
    mkdir -p "${XRAY_API_DIR}"
    local project_xray_api=""
    local cand_dirs=(
        "${SCRIPT_DIR}/scripts/xray_api"
        "${SCRIPT_DIR}/../scripts/xray_api"
        "${SCRIPT_DIR}/../../scripts/xray_api"
        "${INSTALL_DIR:-/opt/just1knode}/scripts/xray_api"
        "/opt/just1knode/scripts/xray_api"
        "/app/scripts/xray_api"
    )
    for cand in "${cand_dirs[@]}"; do
        if [[ -d "$cand" && -f "$cand/app.py" ]]; then
            project_xray_api="$cand"
            break
        fi
    done

    if [[ -n "$project_xray_api" ]]; then
        log "Копирование локальных исходников агента xray-api из репозитория..."
        cp -r "$project_xray_api"/* "${XRAY_API_DIR}/"
    elif [[ -f "${XRAY_API_DIR}/app.py" ]]; then
        log "Использование существующих исходников xray-api в ${XRAY_API_DIR}..."
    else
        log "Автономная загрузка модулей xray-api (ref: $JUST1KNODE_REF)..."
        local tmp_tar
        tmp_tar="$(mktemp /tmp/just1k_repo.XXXXXX.tar.gz 2>/dev/null || mktemp)"
        local tmp_extracted
        tmp_extracted="$(mktemp -d /tmp/just1k_extracted.XXXXXX 2>/dev/null || mktemp -d)"
        local archive_urls=()
        if [[ "$JUST1KNODE_REF" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
            archive_urls+=("${JUST1KNODE_REPO_URL}/archive/${JUST1KNODE_REF}.tar.gz")
        else
            archive_urls+=(
                "${JUST1KNODE_REPO_URL}/archive/${JUST1KNODE_REF}.tar.gz"
                "${JUST1KNODE_REPO_URL}/archive/refs/tags/${JUST1KNODE_REF}.tar.gz"
                "${JUST1KNODE_REPO_URL}/archive/refs/heads/${JUST1KNODE_REF}.tar.gz"
            )
        fi
        local download_ok=0
        for archive_url in "${archive_urls[@]}"; do
            if curl -fsSL --connect-timeout 15 --max-time 120 "$archive_url" -o "$tmp_tar" 2>/dev/null; then
                download_ok=1
                break
            fi
        done
        if [[ $download_ok -ne 1 ]]; then
            rm -rf "$tmp_tar" "$tmp_extracted"
            warn "Не удалось загрузить архив репозитория для развертывания xray-api ($JUST1KNODE_REF)."
            return 1
        fi

        local tar_entries
        if ! tar_entries="$(tar -tzf "$tmp_tar" 2>/dev/null)" || [[ -z "$tar_entries" ]] || printf '%s\n' "$tar_entries" | grep -Eq '(^/|^\.\./|/\.\./|/\.\.$|^\.\.$)'; then
            rm -rf "$tmp_tar" "$tmp_extracted"
            warn "Архив репозитория для xray-api поврежден или содержит небезопасные пути."
            return 1
        fi
        if ! tar -xzf "$tmp_tar" -C "$tmp_extracted" --strip-components=1 --no-same-owner 2>/dev/null; then
            rm -rf "$tmp_tar" "$tmp_extracted"
            warn "Не удалось распаковать архив репозитория для xray-api."
            return 1
        fi
        if [[ -d "${tmp_extracted}/scripts/xray_api" ]]; then
            cp -r "${tmp_extracted}/scripts/xray_api"/* "${XRAY_API_DIR}/"
            mkdir -p "${INSTALL_DIR:-/opt/just1knode}/scripts/xray_api"
            cp -r "${tmp_extracted}/scripts/xray_api"/* "${INSTALL_DIR:-/opt/just1knode}/scripts/xray_api/" 2>/dev/null || true
        fi
        rm -rf "$tmp_tar" "$tmp_extracted"
    fi
    if [[ ! -f "${XRAY_API_DIR}/app.py" ]]; then
        warn "Исходный файл ${XRAY_API_DIR}/app.py не найден после установки xray-api."
        return 1
    fi
    chown -R root:xrayapi "${XRAY_API_DIR}" 2>/dev/null || true
    chmod -R 750 "${XRAY_API_DIR}" 2>/dev/null || true
}

setup_xray_api_venv() {
    if ! ensure_xrayapi_user; then
        return 1
    fi
    mkdir -p "${XRAY_API_DIR}"
    local venv_dir="${XRAY_API_DIR}/venv"
    local venv_py="${venv_dir}/bin/python3"
    local venv_pip="${venv_dir}/bin/pip"
    local venv_uvicorn="${venv_dir}/bin/uvicorn"

    if [[ ! -d "$venv_dir" || ! -x "$venv_py" || ! -f "$venv_uvicorn" ]]; then
        log "Создание venv в ${venv_dir}..."
        # При обнаружении поврежденного venv без python или pip выполняем полную очистку каталога
        if [[ -d "$venv_dir" && (! -x "$venv_py" || ! -x "$venv_pip") ]]; then
            rm -rf "$venv_dir" 2>/dev/null || true
        fi
        if ! python3 -m venv --clear "$venv_dir" 2>/dev/null && ! python3 -m venv "$venv_dir" 2>/dev/null; then
            warn "Попытка доустановки системных пакетов python3-venv/python3-full..."
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq 2>/dev/null || true
            apt-get install -y -qq python3-venv python3-full python3-pip 2>/dev/null || true
            if ! python3 -m venv --clear "$venv_dir" 2>/dev/null && ! python3 -m venv "$venv_dir" 2>/dev/null; then
                warn "Не удалось создать venv для xray-api даже после установки системных пакетов."
                return 1
            fi
        fi
    fi

    # Гарантия наличия и работоспособности pip внутри venv (Ubuntu 24.04/Debian ensurepip bootstrap)
    local pip_available=0
    if [[ -x "$venv_py" ]] && "$venv_py" -m pip --version >/dev/null 2>&1; then
        pip_available=1
    elif [[ -x "$venv_pip" ]] && "$venv_pip" --version >/dev/null 2>&1; then
        pip_available=1
    fi

    if [[ $pip_available -eq 0 && -x "$venv_py" ]]; then
        log "Инициализация ensurepip внутри venv..."
        "$venv_py" -m ensurepip --default-pip >/dev/null 2>&1 || "$venv_py" -m ensurepip --upgrade >/dev/null 2>&1 || true
        if "$venv_py" -m pip --version >/dev/null 2>&1; then
            pip_available=1
        fi
    fi

    if [[ $pip_available -eq 0 ]]; then
        warn "В venv ${venv_dir} отсутствует pip. Попытка установки системных пакетов python3-venv/python3-full..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq 2>/dev/null || true
        apt-get install -y -qq python3-venv python3-full python3-pip 2>/dev/null || true
        if [[ -x "$venv_py" ]]; then
            "$venv_py" -m ensurepip --default-pip >/dev/null 2>&1 || true
            if "$venv_py" -m pip --version >/dev/null 2>&1; then
                pip_available=1
            fi
        fi
    fi

    if [[ $pip_available -eq 0 ]]; then
        warn "Не удалось инициализировать pip внутри виртуального окружения ${venv_dir}."
        return 1
    fi

    # Создание исполняемой обертки/симлинка pip, если создан только модуль python3 -m pip
    if [[ ! -x "$venv_pip" && -x "$venv_py" ]]; then
        printf '#!/bin/sh\nexec "%s" -m pip "$@"\n' "$venv_py" > "$venv_pip" 2>/dev/null || true
        chmod 755 "$venv_pip" 2>/dev/null || true
    fi

    local pip_exec=()
    if [[ -x "$venv_py" ]]; then
        pip_exec=("$venv_py" -m pip)
    elif [[ -x "$venv_pip" ]]; then
        pip_exec=("$venv_pip")
    fi

    # Обновление pip до актуальной версии
    "${pip_exec[@]}" install --no-cache-dir --upgrade pip >/dev/null 2>&1 || true

    if [[ -f "${XRAY_API_DIR}/requirements.txt" ]]; then
        log "Установка зафиксированных зависимостей xray-api..."
        if ! "${pip_exec[@]}" install --no-cache-dir -r "${XRAY_API_DIR}/requirements.txt"; then
            warn "Не удалось установить зависимости pip для xray-api."
            return 1
        fi
    else
        warn "Файл ${XRAY_API_DIR}/requirements.txt не найден, пропуск pip install."
    fi

    if [[ ! -f "$venv_uvicorn" ]]; then
        warn "Служебный бинарник uvicorn не обнаружен в ${venv_dir}/bin после установки зависимостей."
        return 1
    fi

    # Автоматическая компиляция protobuf proto-файлов для gRPC
    if [[ -f "${XRAY_API_DIR}/compile_proto.py" ]]; then
        log "Компиляция gRPC protobuf файлов..."
        "${venv_py}" "${XRAY_API_DIR}/compile_proto.py" >/dev/null 2>&1 || {
            warn "Предупреждение: ошибка компиляции proto-файлов через compile_proto.py"
            "${venv_py}" "${XRAY_API_DIR}/compile_proto.py" || true
        }
    fi

    # Гарантия прав доступа для пользователя xrayapi (защита от umask 027)
    chown -R root:xrayapi "${venv_dir}" 2>/dev/null || true
    chmod -R 755 "${venv_dir}" 2>/dev/null || true
}

deploy_apply_trigger_units() {
    local systemd_dir="${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
    local src_dir="${SCRIPT_DIR:-${INSTALL_DIR:-/opt/just1knode}}/scripts/systemd"
    local global_bin="${JUST1KNODE_GLOBAL_BIN:-/usr/local/bin/just1knode}"
    mkdir -p "$systemd_dir" 2>/dev/null || true

    if [[ -f "${src_dir}/just1knode-apply.path" && -f "${src_dir}/just1knode-apply.service" ]]; then
        cp -f "${src_dir}/just1knode-apply.path" "${systemd_dir}/just1knode-apply.path"
        sed "s|/usr/local/bin/just1knode|${global_bin}|g; s|/etc/just1knode|${STATE_DIR}|g" \
            "${src_dir}/just1knode-apply.service" > "${systemd_dir}/just1knode-apply.service"
        sed -i "s|/etc/just1knode|${STATE_DIR}|g" "${systemd_dir}/just1knode-apply.path" 2>/dev/null || true
    else
        cat > "${systemd_dir}/just1knode-apply.path" <<EOF
[Unit]
Description=Just1kNode Pending Configuration Trigger Path

[Path]
PathExists=${STATE_DIR}/.apply_pending
Unit=just1knode-apply.service

[Install]
WantedBy=multi-user.target
EOF
        cat > "${systemd_dir}/just1knode-apply.service" <<EOF
[Unit]
Description=Just1kNode Apply Pending Configuration Changes
After=network.target xray.service nginx.service

[Service]
Type=oneshot
ExecStart=${global_bin} apply-pending
TimeoutStartSec=90
EOF
    fi
    chmod 644 "${systemd_dir}/just1knode-apply.path" "${systemd_dir}/just1knode-apply.service" 2>/dev/null || true
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable --now just1knode-apply.path >/dev/null 2>&1 || true
    fi
}

harden_node_permissions() {
    local le_dir="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
    local xray_cfg_dir="${XRAY_CONFIG_DIR:-/usr/local/etc/xray}"
    local state_dir="${STATE_DIR:-/etc/just1knode}"
    local state_file="${STATE_FILE:-${state_dir}/state.json}"
    local clients_file="${CLIENTS_FILE:-${state_dir}/clients.json}"
    local links_file="${LINKS_FILE:-${state_dir}/links.json}"

    local has_xrayapi=0
    if getent group xrayapi >/dev/null 2>&1; then
        has_xrayapi=1
    elif [[ -d "${XRAY_API_DIR:-/opt/xray-api}" || -f "${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}/xray-api.service" ]]; then
        if declare -F ensure_xrayapi_user >/dev/null 2>&1 && ensure_xrayapi_user; then
            getent group xrayapi >/dev/null 2>&1 && has_xrayapi=1
        fi
    fi

    # Права на чтение/синхронизацию TLS сертификатов и конфигурации Xray
    if [[ -d "${le_dir}/live" ]]; then
        chmod 755 "$le_dir" 2>/dev/null || true
        if [[ $has_xrayapi -eq 1 ]]; then
            chown root:xrayapi "$le_dir" "${le_dir}/live" 2>/dev/null || true
        fi
        chmod 750 "${le_dir}/live" 2>/dev/null || true
    fi
    if [[ -d "${xray_cfg_dir}" ]]; then
        chmod 755 "$xray_cfg_dir" 2>/dev/null || true
    fi
    if [[ -d "${xray_cfg_dir}/tls" ]]; then
        if [[ $has_xrayapi -eq 1 ]]; then
            chown root:xrayapi "${xray_cfg_dir}/tls" 2>/dev/null || true
        fi
        chmod 750 "${xray_cfg_dir}/tls" 2>/dev/null || true
    fi
    if [[ -f "${xray_cfg_dir}/config.json" ]]; then
        if [[ $has_xrayapi -eq 1 ]]; then
            chown root:xrayapi "${xray_cfg_dir}/config.json" 2>/dev/null || true
        fi
        chmod 640 "${xray_cfg_dir}/config.json" 2>/dev/null || true
    fi

    # Права на каталог состояния (SGID 2770; state.json — read-only 640 для группы xrayapi)
    if [[ -d "${state_dir}" ]]; then
        if [[ $has_xrayapi -eq 1 ]]; then
            chown -R root:xrayapi "${state_dir}" 2>/dev/null || true
        fi
        chmod 2770 "${state_dir}" 2>/dev/null || true
        if [[ -f "${clients_file}" ]]; then
            [[ $has_xrayapi -eq 1 ]] && { chown root:xrayapi "${clients_file}" 2>/dev/null || true; }
            chmod 660 "${clients_file}" 2>/dev/null || true
        fi
        if [[ -f "${state_file}" ]]; then
            [[ $has_xrayapi -eq 1 ]] && { chown root:xrayapi "${state_file}" 2>/dev/null || true; }
            chmod 640 "${state_file}" 2>/dev/null || true
        fi
        if [[ -f "${links_file}" ]]; then
            [[ $has_xrayapi -eq 1 ]] && { chown root:xrayapi "${links_file}" 2>/dev/null || true; }
            chmod 660 "${links_file}" 2>/dev/null || true
        fi
        if [[ $has_xrayapi -eq 1 ]]; then
            find "${state_dir}" -maxdepth 1 -type f -name "*.lock" -exec chown -h root:xrayapi {} + 2>/dev/null || true
            find "${state_dir}" -maxdepth 1 -type f -name "idempotency.db*" -exec chown -h root:xrayapi {} + 2>/dev/null || true
        fi
        find "${state_dir}" -maxdepth 1 -type f -name "*.lock" -exec chmod 660 {} + 2>/dev/null || true
        find "${state_dir}" -maxdepth 1 -type f -name "idempotency.db*" -exec chmod 660 {} + 2>/dev/null || true
    fi
}

deploy_xray_api_service() {
    local api_key="${1:-}"
    local cdn_domain="${2:-}"

    if [[ -z "$api_key" && -f "${XRAY_API_CONFIG_ENV}" ]]; then
        api_key="$(grep -m1 '^XRAY_API_KEY=' "${XRAY_API_CONFIG_ENV}" 2>/dev/null | cut -d= -f2- || true)"
    fi
    if [[ -z "$api_key" ]]; then
        warn "XRAY_API_KEY не передан и отсутствует в ${XRAY_API_CONFIG_ENV}."
        return 1
    fi
    if [[ -z "$cdn_domain" && -f "${XRAY_API_CONFIG_ENV}" ]]; then
        cdn_domain="$(grep -m1 '^CDN_DOMAIN=' "${XRAY_API_CONFIG_ENV}" 2>/dev/null | cut -d= -f2- || true)"
    fi

    if ! ensure_xrayapi_user; then
        return 1
    fi
    mkdir -p "${XRAY_API_ETC}" "${STATE_DIR}" "${XRAY_API_LIB}"
    if ! deploy_xray_api_sources; then
        return 1
    fi
    if ! setup_xray_api_venv; then
        return 1
    fi

    cat > "${XRAY_API_CONFIG_ENV}" <<EOF
XRAY_API_KEY=${api_key}
XRAY_GRPC_HOST=127.0.0.1
XRAY_GRPC_PORT=10085
CLIENTS_FILE_PATH=${STATE_DIR}/clients.json
LINKS_FILE_PATH=${STATE_DIR}/links.json
APPLY_PENDING_PATH=${STATE_DIR}/.apply_pending
MODULE_ERRORS_PATH=${STATE_DIR}/module_errors.json
EPOCH_FILE_PATH=${XRAY_API_LIB}/epoch.json
STATE_FILE_PATH=${STATE_FILE}
CDN_DOMAIN=${cdn_domain}
EOF

    chmod 640 "${XRAY_API_CONFIG_ENV}"
    chown root:xrayapi "${XRAY_API_CONFIG_ENV}" 2>/dev/null || true
    chmod 750 "${XRAY_API_ETC}"
    chown -R xrayapi:xrayapi "${XRAY_API_LIB}" 2>/dev/null || true
    chmod 750 "${XRAY_API_LIB}"

    # Права на чтение/синхронизацию TLS сертификатов, конфигурации Xray и каталога состояния
    local le_dir="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
    local xray_cfg_dir="${XRAY_CONFIG_DIR:-/usr/local/etc/xray}"
    mkdir -p "${le_dir}/live" "${xray_cfg_dir}/tls" 2>/dev/null || true
    harden_node_permissions

    # Финальная синхронизация прав на каталог агента
    chown -R root:xrayapi "${XRAY_API_DIR}" 2>/dev/null || true
    chmod -R 750 "${XRAY_API_DIR}" 2>/dev/null || true
    if [[ -d "${XRAY_API_DIR}/venv" ]]; then
        chmod -R 755 "${XRAY_API_DIR}/venv" 2>/dev/null || true
    fi

    cat > "${SYSTEMD_SYSTEM_DIR}/xray-api.service" <<EOF
[Unit]
Description=Just1kNode Xray API Agent
After=network.target xray.service
Wants=xray.service
StartLimitIntervalSec=30
StartLimitBurst=15

[Service]
Type=simple
User=xrayapi
Group=xrayapi
UMask=0007
WorkingDirectory=${XRAY_API_DIR}
EnvironmentFile=${XRAY_API_CONFIG_ENV}
ExecStart=${XRAY_API_DIR}/venv/bin/uvicorn app:app --host 127.0.0.1 --port 5001 --workers 1 --proxy-headers --forwarded-allow-ips=127.0.0.1 --log-level info
Restart=always
RestartSec=3
LimitNOFILE=65535
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
ReadWritePaths=${STATE_DIR} ${XRAY_API_LIB} -${LETSENCRYPT_DIR:-/etc/letsencrypt} -${XRAY_CONFIG_DIR:-/usr/local/etc/xray}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now xray-api
    deploy_apply_trigger_units
}
