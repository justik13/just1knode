#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE - Главный диспетчер и панель управления серверными узлами
# =============================================================================
set -euo pipefail

# Принудительная UTF-8 локаль и режим UTF-8 в Python (PEP 540)
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8


# Определение каталога скрипта с защитой от запуска через pipe (curl | bash)
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
if [[ -n "$SCRIPT_SOURCE" && "$SCRIPT_SOURCE" != "bash" && "$SCRIPT_SOURCE" != "-bash" ]]; then
    if command -v realpath >/dev/null 2>&1; then
        resolved_source="$(realpath "$SCRIPT_SOURCE" 2>/dev/null || echo "$SCRIPT_SOURCE")"
    elif command -v readlink >/dev/null 2>&1; then
        resolved_source="$(readlink -f "$SCRIPT_SOURCE" 2>/dev/null || echo "$SCRIPT_SOURCE")"
    else
        resolved_source="$SCRIPT_SOURCE"
    fi
    SCRIPT_DIR="$(cd "$(dirname "$resolved_source")" 2>/dev/null && pwd)"
fi

# Если скрипт запущен через pipe (curl | bash) или модули не найдены локально:
# выполняем автономную загрузку модулей в /opt/just1knode и перезапускаем
if [[ -z "$SCRIPT_DIR" || ! -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
    INSTALL_DIR="${INSTALL_DIR:-/opt/just1knode}"
    mkdir -p "$INSTALL_DIR"
    
    echo -e "\033[1;34m==>\033[0m \033[1mJUST1KNODE: Инициализация и развертывание модулей в ${INSTALL_DIR}...\033[0m"
    
    if [[ -d "/app/just1knode" && -f "/app/just1knode/lib/common.sh" ]]; then
        cp -a /app/just1knode/. "$INSTALL_DIR/"
        if [[ -d "/app/scripts/xray_api" ]]; then
            mkdir -p "${XRAY_API_DIR:-/opt/xray-api}"
            cp -a /app/scripts/xray_api/. "${XRAY_API_DIR:-/opt/xray-api}/"
            mkdir -p "$INSTALL_DIR/scripts/xray_api"
            cp -a /app/scripts/xray_api/. "$INSTALL_DIR/scripts/xray_api/"
        fi
    else
        JUST1KNODE_REPO_URL="${JUST1KNODE_REPO_URL:-${JUST1KBOT_REPO_URL:-https://github.com/justik13/just1knode}}"
        JUST1KNODE_REF="${JUST1KNODE_REF:-${JUST1KBOT_REF:-main}}"
        
        local_archive_urls=()
        if [[ "$JUST1KNODE_REF" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
            local_archive_urls+=("${JUST1KNODE_REPO_URL}/archive/${JUST1KNODE_REF}.tar.gz")
        else
            local_archive_urls+=(
                "${JUST1KNODE_REPO_URL}/archive/${JUST1KNODE_REF}.tar.gz"
                "${JUST1KNODE_REPO_URL}/archive/refs/tags/${JUST1KNODE_REF}.tar.gz"
                "${JUST1KNODE_REPO_URL}/archive/refs/heads/${JUST1KNODE_REF}.tar.gz"
            )
        fi
        
        tmp_tar="$(mktemp /tmp/just1knode_boot.XXXXXX.tar.gz 2>/dev/null || mktemp)"
        tmp_extract="$(mktemp -d /tmp/just1knode_extract.XXXXXX 2>/dev/null || mktemp -d)"
        
        download_ok=0
        for archive_url in "${local_archive_urls[@]}"; do
            if command -v curl >/dev/null 2>&1; then
                if curl -fsSL --connect-timeout 15 --max-time 120 "$archive_url" -o "$tmp_tar" 2>/dev/null; then
                    download_ok=1
                    break
                fi
            elif command -v wget >/dev/null 2>&1; then
                if wget -q --timeout=120 --tries=2 -O "$tmp_tar" "$archive_url" 2>/dev/null; then
                    download_ok=1
                    break
                fi
            fi
        done
        
        if [[ $download_ok -ne 1 || ! -f "$tmp_tar" ]]; then
            rm -rf "$tmp_tar" "$tmp_extract"
            echo "Ошибка: не удалось скачать архив репозитория (${local_archive_urls[*]})." >&2
            exit 1
        fi
        
        tar -xzf "$tmp_tar" -C "$tmp_extract" --strip-components=1 --no-same-owner
        if [[ -d "$tmp_extract/just1knode" ]]; then
            cp -a "$tmp_extract/just1knode/." "$INSTALL_DIR/"
        else
            cp -a "$tmp_extract/just1knode.sh" "$INSTALL_DIR/" 2>/dev/null || true
            cp -a "$tmp_extract/VERSION" "$INSTALL_DIR/" 2>/dev/null || true
            cp -a "$tmp_extract/lib" "$INSTALL_DIR/" 2>/dev/null || true
            cp -a "$tmp_extract/modules" "$INSTALL_DIR/" 2>/dev/null || true
        fi
        if [[ -d "$tmp_extract/scripts/xray_api" ]]; then
            mkdir -p "${XRAY_API_DIR:-/opt/xray-api}"
            cp -a "$tmp_extract/scripts/xray_api/." "${XRAY_API_DIR:-/opt/xray-api}/"
            mkdir -p "$INSTALL_DIR/scripts/xray_api"
            cp -a "$tmp_extract/scripts/xray_api/." "$INSTALL_DIR/scripts/xray_api/"
        fi
        if [[ -d "$tmp_extract/scripts/systemd" ]]; then
            mkdir -p "$INSTALL_DIR/scripts/systemd"
            cp -a "$tmp_extract/scripts/systemd/." "$INSTALL_DIR/scripts/systemd/"
        fi
        bootstrap_sha=""
        if command -v git >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
            bootstrap_sha="$(timeout 5s git ls-remote "https://github.com/justik13/just1knode" "refs/heads/main" 2>/dev/null | awk '{print $1}' || true)"
        fi
        if [[ "$bootstrap_sha" =~ ^[0-9a-f]{40}$ ]]; then
            printf '%s\n' "$bootstrap_sha" > "$INSTALL_DIR/COMMIT" 2>/dev/null || true
        fi
        unset bootstrap_sha
        rm -rf "$tmp_tar" "$tmp_extract"
    fi
    
    chmod +x "$INSTALL_DIR/just1knode.sh"
    ln -sf "$INSTALL_DIR/just1knode.sh" /usr/local/bin/just1knode
    
    echo -e "\033[1;32m✔\033[0m Модули успешно установлены в ${INSTALL_DIR}"
    echo -e "\033[1;32m✔\033[0m Команда зарегистрирована: \033[1;36mjust1knode\033[0m"
    echo ""
    
    if [[ -t 0 ]]; then
        exec "$INSTALL_DIR/just1knode.sh" "$@"
    elif (exec </dev/tty) 2>/dev/null; then
        exec "$INSTALL_DIR/just1knode.sh" "$@" </dev/tty
    else
        exec "$INSTALL_DIR/just1knode.sh" "$@"
    fi
fi

VERSION_FILE="${SCRIPT_DIR}/VERSION"
JUST1KNODE_VERSION="2.5.1"
if [[ -f "$VERSION_FILE" ]]; then
    JUST1KNODE_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
fi

# Git-коммит рядом с VERSION: доступен при запуске из репозитория или из файла COMMIT.
# На проде (/opt/just1knode без .git) считывается из COMMIT.
JUST1KNODE_COMMIT=""
if [[ -f "${SCRIPT_DIR}/COMMIT" ]]; then
    JUST1KNODE_COMMIT="$(tr -d '[:space:]' < "${SCRIPT_DIR}/COMMIT" 2>/dev/null | cut -c1-7)"
elif [[ -n "${SCRIPT_DIR:-}" ]]; then
    JUST1KNODE_COMMIT="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
fi

# Единая метка версии: "v2.1.2 (abc1234)" или "v2.1.2" без коммита.
node_version_label() {
    if [[ -n "${JUST1KNODE_COMMIT:-}" ]]; then
        echo "v${JUST1KNODE_VERSION} (${JUST1KNODE_COMMIT})"
    else
        echo "v${JUST1KNODE_VERSION}"
    fi
}

# Строка версии внутри бокса панели: центрирование под ширину 61.
print_node_version_box_line() {
    local label pad_left pad_right
    label="Версия: $(node_version_label)"
    pad_left=$(( (61 - ${#label}) / 2 ))
    pad_right=$(( 61 - ${#label} - pad_left ))
    if [[ $pad_left -lt 0 || $pad_right -lt 0 ]]; then
        label="${label:0:61}"
        pad_left=0
        pad_right=0
    fi
    printf '│%*s%s%*s│\n' "$pad_left" "" "$label" "$pad_right" ""
}

# Best-effort проверка новой версии при входе в меню. Строго read-only:
# опрашивает origin/main через git ls-remote, не меняет репозиторий, не вызывает update_node.
# Уведомляет только когда remote SHA отличается от локального;
# при совпадении SHA или ошибках (нет сети/timeout) молча пропускается (fail-safe).
check_node_update_on_entry() {
    local repo_url ref
    repo_url="${JUST1KNODE_REPO_URL:-${JUST1KBOT_REPO_URL:-https://github.com/justik13/just1knode}}"
    ref="${JUST1KNODE_REF:-${JUST1KBOT_REF:-main}}"
    if [[ "$repo_url" != "https://github.com/justik13/just1knode" || "$ref" != "main" ]]; then
        return 0
    fi

    local local_sha=""
    if [[ -f "${SCRIPT_DIR}/COMMIT" ]]; then
        local_sha="$(tr -d '[:space:]' < "${SCRIPT_DIR}/COMMIT" 2>/dev/null || true)"
    elif [[ -n "${JUST1KNODE_LOCAL_SHA:-}" ]]; then
        local_sha="${JUST1KNODE_LOCAL_SHA}"
    elif [[ -d "${SCRIPT_DIR}/.git" ]] && command -v git >/dev/null 2>&1; then
        local_sha="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || true)"
    fi

    if [[ "$local_sha" =~ ^[0-9a-f]{40}$ ]] && command -v git >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
        local remote_sha
        remote_sha="$(timeout 5s git ls-remote "$repo_url" "refs/heads/${ref}" 2>/dev/null | awk '{print $1}' || true)"
        if [[ "$remote_sha" =~ ^[0-9a-f]{40}$ ]]; then
            if [[ "$remote_sha" != "$local_sha" ]]; then
                echo -e "  ${YELLOW}⚠️  Доступны изменения в GitHub origin/${ref}. Воспользуйтесь пунктом «Обновить утилиту».${NC}"
            fi
            return 0
        fi
    fi

    # Fallback на проверку VERSION через curl (для чистых установок без файла COMMIT и без git)
    command -v curl >/dev/null 2>&1 || return 0
    local remote_ver newest
    remote_ver="$(curl -fsSL --max-time 5 "https://raw.githubusercontent.com/justik13/just1knode/main/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$remote_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
    [[ "$JUST1KNODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
    newest="$(printf '%s\n%s\n' "$JUST1KNODE_VERSION" "$remote_ver" | sort -V | tail -n 1)"
    if [[ "$newest" == "$remote_ver" && "$remote_ver" != "$JUST1KNODE_VERSION" ]]; then
        echo -e "  ${YELLOW}⚠️  Доступна новая версия just1knode: v${remote_ver} (у вас v${JUST1KNODE_VERSION}). Воспользуйтесь пунктом «Обновить утилиту».${NC}"
    fi
    return 0
}

# Подключение библиотек
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/backup.sh
source "${SCRIPT_DIR}/lib/backup.sh"
# shellcheck source=lib/state.sh
source "${SCRIPT_DIR}/lib/state.sh"
# shellcheck source=lib/ssl.sh
source "${SCRIPT_DIR}/lib/ssl.sh"
# shellcheck source=lib/traffic_limit.sh
source "${SCRIPT_DIR}/lib/traffic_limit.sh"
# shellcheck source=lib/module_loader.sh
source "${SCRIPT_DIR}/lib/module_loader.sh"
# shellcheck source=lib/builder.sh
source "${SCRIPT_DIR}/lib/builder.sh"

# Подключение системных и ролевых модулей
# shellcheck source=modules/xray/core.sh
source "${SCRIPT_DIR}/modules/xray/core.sh"
# shellcheck source=modules/xray/api.sh
source "${SCRIPT_DIR}/modules/xray/api.sh"
# shellcheck source=modules/roles/base.sh
source "${SCRIPT_DIR}/modules/roles/base.sh"
# shellcheck source=modules/roles/ru_hub.sh
source "${SCRIPT_DIR}/modules/roles/ru_hub.sh"
# shellcheck source=modules/roles/eu_hub.sh
source "${SCRIPT_DIR}/modules/roles/eu_hub.sh"
# shellcheck source=modules/roles/exit_node.sh
source "${SCRIPT_DIR}/modules/roles/exit_node.sh"

# Изолированная динамическая загрузка независимых транспортных и CDN модулей
load_all_transport_modules

# Вспомогательные хелперы статуса для интерфейса v2
get_bot_connection_label() {
    local status_file="${STATE_DIR:-/etc/just1knode}/bot_status.json"
    if [[ ! -f "$status_file" ]]; then
        echo -e "${YELLOW}⚪ Ожидает добавления${NC}"
        return 0
    fi
    local info
    info="$(python3 - "$status_file" <<'PYEOF'
import json, sys, time
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    ts = int(data.get("last_seen_at") or 0)
    ip = str(data.get("bot_ip") or "").strip()
    if ts > 0:
        age = max(0, int(time.time()) - ts)
        if age < 60:
            ago = f"{age}с назад"
        elif age < 3600:
            ago = f"{age // 60}м назад"
        elif age < 86400:
            ago = f"{age // 3600}ч назад"
        else:
            ago = f"{age // 86400}д назад"
        print(f"OK|{ip}|{ago}")
    else:
        print("WAIT||")
except Exception:
    print("WAIT||")
PYEOF
)"
    if [[ "$info" == OK\|* ]]; then
        local rest ip ago
        rest="${info#OK|}"
        ip="${rest%%|*}"
        ago="${rest#*|}"
        if [[ -n "$ip" ]]; then
            echo -e "${GREEN}🟢 Подключен${NC} ${DIM:-}(IP: ${ip}, ${ago})${NC}"
        else
            echo -e "${GREEN}🟢 Подключен${NC} ${DIM:-}(${ago})${NC}"
        fi
    else
        echo -e "${YELLOW}⚪ Ожидает добавления${NC}"
    fi
}

get_ssl_header_summary() {
    local domain
    domain="$(get_state_val "domain" "")"
    [[ -z "$domain" || "$domain" == "-" ]] && domain="$(get_state_val "vless_domain" "")"
    if [[ -n "$domain" && "$domain" != "-" ]]; then
        local exp
        exp="$(get_ssl_cert_expiry "$domain" 2>/dev/null || true)"
        if [[ -n "$exp" ]]; then
            echo -e "${GREEN}🟢 ${domain}${NC} ${DIM:-}(до ${exp})${NC}"
        else
            echo -e "${YELLOW}🟡 ${domain}${NC} ${DIM:-}(нет LE-сертификата)${NC}"
        fi
    else
        echo -e "${CYAN}🔐 Self-Signed${NC} ${DIM:-}(API 8444)${NC}"
    fi
}

show_v2_connection_card() {
    title "ДАННЫЕ ДЛЯ ПОДКЛЮЧЕНИЯ К TELEGRAM-БОТУ"
    local my_ip domain api_url api_key bot_ip role mod_cnt
    my_ip="$(get_public_ipv4 2>/dev/null || echo "<IP_СЕРВЕРА>")"
    domain="$(get_state_val "domain" "")"
    [[ -z "$domain" || "$domain" == "-" ]] && domain="$(get_state_val "vless_domain" "")"
    api_url="$(get_state_val "api_url" "")"
    if [[ -z "$api_url" || "$api_url" == "-" ]]; then
        if [[ -n "$domain" && "$domain" != "-" ]]; then
            api_url="https://${domain}:8444"
        else
            api_url="https://${my_ip}:8444"
        fi
    fi
    api_key="$(get_state_val "api_key" "-")"
    if [[ -z "$api_key" || "$api_key" == "-" ]] && [[ -f "${XRAY_API_CONFIG_ENV:-/etc/xray-api/config.env}" ]]; then
        api_key="$(grep -m1 '^XRAY_API_KEY=' "${XRAY_API_CONFIG_ENV:-/etc/xray-api/config.env}" 2>/dev/null | cut -d= -f2- || echo "-")"
    fi
    bot_ip="$(get_state_val "bot_ip" "не задан")"
    role="$(get_state_val "role" "unconfigured")"

    echo -e "  Роль:        $(role_display_name "$role")"
    echo -e "  Статус бота: $(get_bot_connection_label)"
    echo -e "  URL API:     ${CYAN}${api_url}${NC}"
    echo -e "  IP узла:     ${CYAN}${my_ip}${NC}"
    if [[ -n "$domain" && "$domain" != "-" ]]; then
        echo -e "  Домен:       ${CYAN}${domain}${NC}"
    fi
    echo -e "  API Токен:   ${YELLOW}${api_key}${NC}"
    echo -e "  BOT_IP UFW:  ${CYAN}${bot_ip}${NC}"

    if [[ "$role" == "ru_hub" ]]; then
        mod_cnt="$(count_enabled_modules)"
        echo ""
        if is_module_enabled "cdn_yandex"; then
            local y_dom
            y_dom="$(get_module_val "cdn_yandex" "domain" "-")"
            echo -e "  Yandex CDN:  ${CYAN}${y_dom}${NC}"
        fi
        if is_module_enabled "cdn_turboflare"; then
            local tf_dom
            tf_dom="$(get_module_val "cdn_turboflare" "domain" "-")"
            echo -e "  TurboFlare:  ${CYAN}${tf_dom}${NC}"
        fi
        if is_module_enabled "vless_xhttp"; then
            local bot_dom sub_pref
            bot_dom="$(get_state_val "bot_domain" "-")"
            sub_pref="$(get_state_val "sub_path_prefix" "/sub/wl")"
            echo -e "  Sub-прокси:  ${CYAN}${bot_dom}${NC} (${sub_pref})"
        fi
    elif [[ "$role" == "eu_hub" ]]; then
        local t_uuid
        t_uuid="$(get_state_val "tunnel_uuid" "-")"
        echo -e "  Порт моста:  ${CYAN}443/tcp${NC}"
        echo -e "  Tunnel UUID: ${YELLOW}${t_uuid}${NC}"
    elif [[ "$role" == "exit_node" ]]; then
        local t_uuid
        t_uuid="$(get_state_val "tunnel_uuid" "-")"
        echo -e "  Порт входа:  ${CYAN}443/tcp${NC}"
        echo -e "  Bridge UUID: ${YELLOW}${t_uuid}${NC}"
    fi
    echo ""
}

ensure_v2_base_stack_installed() {
    check_root
    init_state_dir
    clear
    title "БАЗОВАЯ УСТАНОВКА JUST1KNODE v2"
    echo -e "  Обнаружен чистый сервер без развернутого API-агента.\n"
    echo -e "  Будут установлены и настроены:"
    echo -e "    • Базовые пакеты, Nginx и sysctl hardening (BBR, без IPv6, ICMP Stealth)"
    echo -e "    • Служба учета трафика vnstat и ядро Xray (SHA-256) со stub-конфигом"
    echo -e "    • Агент управления xray-api (порт 8444 HTTPS с защитой UFW по BOT_IP)\n"

    local confirm=""
    read -rp "Выполнить базовую установку? [Y/n]: " confirm || true
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        return 1
    fi

    install_base_deps
    install_nginx_if_missing
    apply_node_sysctl_hardening
    ensure_vnstat || true
    install_xray_binaries
    ensure_xray_stub_config
    deploy_xray_systemd_service

    if ! systemctl enable --now xray 2>/dev/null; then
        systemctl restart xray || true
    fi

    local api_key
    api_key="$(get_state_val "api_key" "")"
    if [[ -z "$api_key" || "$api_key" == "-" ]]; then
        api_key="$(openssl rand -hex 24 2>/dev/null || python3 -c 'import secrets; print(secrets.token_hex(24))')"
    fi

    local my_ip
    my_ip="$(get_public_ipv4 2>/dev/null || echo "127.0.0.1")"
    set_state_val "role" "unconfigured"
    set_state_val "api_key" "$api_key"
    set_state_val "api_url" "https://${my_ip}:8444"
    set_state_json_val "modules" "{}"
    set_state_json_val "peers" "[]"

    deploy_xray_api_service "$api_key" ""
    setup_base_api_nginx || warn "Предупреждение при настройке Nginx для API 8444."
    configure_safe_ufw

    echo ""
    local bot_ip_input=""
    while true; do
        read -rp "Введите IPv4 адрес Telegram-бота для доступа к API :8444 (Enter — пропустить и закрыть порт): " bot_ip_input || true
        bot_ip_input="$(echo "$bot_ip_input" | tr -d '[:space:]')"
        if [[ -z "$bot_ip_input" ]]; then
            warn "BOT_IP не задан — порт 8444 закрыт в UFW (задайте позже через пункт [3])."
            break
        fi
        if validate_ipv4 "$bot_ip_input" 2>/dev/null; then
            set_origin_bot_ip "$bot_ip_input" || warn "Не удалось применить BOT_IP в UFW."
            break
        fi
        warn "Некорректный IPv4 адрес: '$bot_ip_input'."
    done

    heal_node_firewall_and_stealth
    clear
    log "✨ Базовая установка Just1kNode v2 завершена!"
    echo ""
    show_v2_connection_card
    read -rp "Нажмите Enter для перехода в главное меню..." || true
    return 0
}

# Автоматическая регистрация команды в /usr/local/bin
ensure_global_symlink() {
    local target="/usr/local/bin/just1knode"
    local current_bin="${SCRIPT_DIR}/just1knode.sh"
    if [[ ! -L "$target" ]] || [[ "$(readlink -f "$target" 2>/dev/null || true)" != "$current_bin" ]]; then
        ln -sf "$current_bin" "$target" 2>/dev/null || true
    fi
}

show_status() {
    title "СТАТУС СЕРВЕРНОГО УЗЛА"
    check_root
    init_state_dir

    local role
    role="$(get_state_val "role" "unconfigured")"
    echo -e "  Версия just1knode:    ${BOLD}${CYAN}$(node_version_label)${NC}"
    echo -e "  Роль узла:            ${BOLD}${GREEN}${role}${NC}"

    if [[ "$role" == "ru_hub" || "$role" == "eu_hub" || "$role" == "exit_node" ]]; then
        local domain api_url bot_ip
        domain="$(get_state_val "domain" "-")"
        api_url="$(get_state_val "api_url" "-")"
        bot_ip="$(get_state_val "bot_ip" "не задан")"
        echo -e "  Отображение:          $(role_display_name "$role")"
        echo -e "  Домен:                ${CYAN}${domain}${NC}"
        echo -e "  API URL:              ${CYAN}${api_url}${NC}"
        echo -e "  BOT_IP:               ${CYAN}${bot_ip}${NC}"
        echo -e "  Статус бота:          $(get_bot_connection_label)"
        echo -e "  SSL:                  $(get_ssl_header_summary)"
        echo -e "  Трафик:               $(get_traffic_limit_summary)"
        if [[ "$role" == "ru_hub" ]]; then
            echo -e "\n  Транспорты:"
            echo -e "    VLESS TLS:          $(vless_tls_status_label)"
            echo -e "    VLESS XHTTP:        $(vless_xhttp_status_label)"
            if is_module_enabled "vless_xhttp"; then
                local m kind label
                for m in "${LOADED_TRANSPORT_MODULES[@]}"; do
                    kind="$(get_module_meta_field "$m" "kind" "transport")"
                    [[ "$kind" == "cdn" ]] || continue
                    label="$(get_module_meta_field "$m" "label" "$m")"
                    printf "      %-18s %s\n" "${label}:" "$(cdn_module_status_label "$m")"
                done
            fi
        elif [[ "$role" == "eu_hub" ]]; then
            echo -e "  Порт моста:           ${CYAN}443/tcp${NC}"
        elif [[ "$role" == "exit_node" ]]; then
            echo -e "  Anti-Abuse:           ${CYAN}$(get_state_val "abuse_protection" "disabled")${NC}"
        fi

        echo -e "\n  Службы:"
        systemctl is-active --quiet xray && echo -e "    Xray Core:            ${GREEN}● Активен${NC}" || echo -e "    Xray Core:            ${RED}○ Не работает${NC}"
        systemctl is-active --quiet xray-api && echo -e "    xray-api:             ${GREEN}● Активен${NC}" || echo -e "    xray-api:             ${RED}○ Не работает${NC}"
        systemctl is-active --quiet nginx && echo -e "    Nginx (8444/443):     ${GREEN}● Активен${NC}" || echo -e "    Nginx (8444/443):     ${RED}○ Не работает${NC}"
        if [[ -f "${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}/just1knode-apply.path" ]]; then
            systemctl is-active --quiet just1knode-apply.path && echo -e "    Apply Watcher:        ${GREEN}● Активен${NC}" || echo -e "    Apply Watcher:        ${YELLOW}○ Не активен${NC}"
        fi
    else
        echo -e "  Отображение:          $(role_display_name "$role")"
        echo -e "  Бот:                  $(get_bot_connection_label)"
        echo -e "\n  Службы:"
        systemctl is-active --quiet xray-api && echo -e "    xray-api (8444):      ${GREEN}● Активен${NC}" || echo -e "    xray-api (8444):      ${YELLOW}○ Не работает${NC}"
        systemctl is-active --quiet nginx && echo -e "    Nginx:                ${GREEN}● Активен${NC}" || echo -e "    Nginx:                ${YELLOW}○ Не работает${NC}"
    fi

    if [[ ${#BROKEN_MODULE_IDS[@]} -gt 0 ]]; then
        echo -e "\n  ${YELLOW}Изолированные модули (ошибки загрузки):${NC}"
        local idx
        for ((idx = 0; idx < ${#BROKEN_MODULE_IDS[@]}; idx++)); do
            echo -e "    ${RED}● ${BROKEN_MODULE_IDS[$idx]}${NC}: ${BROKEN_MODULE_REASONS[$idx]}"
        done
    fi

    if [[ "$role" != "unconfigured" ]] && declare -f show_traffic_limit_status >/dev/null 2>&1; then
        if [[ -f "${TRAFFIC_LIMIT_CONFIG:-${STATE_DIR:-/etc/just1knode}/traffic_limit.json}" ]] || command -v vnstat >/dev/null 2>&1; then
            show_traffic_limit_status
        fi
    fi
}

show_bot_credentials() {
    show_v2_connection_card
}

run_doctor() {
    title "КОМПЛЕКСНАЯ САМОДИАГНОСТИКА (DOCTOR)"
    local failed=0
    local warnings=0
    local role domain
    role="$(get_state_val "role" "unconfigured")"
    domain="$(get_state_val "domain")"

    log "0. Проверка целостности транспортных модулей..."
    if [[ ${#BROKEN_MODULE_IDS[@]} -eq 0 ]]; then
        echo -e "  ${GREEN}✔${NC} Все транспортные модули загружены (активно: ${#LOADED_TRANSPORT_MODULES[@]})"
    else
        local idx
        for ((idx = 0; idx < ${#BROKEN_MODULE_IDS[@]}; idx++)); do
            echo -e "  ${RED}✗${NC} Изолирован битый модуль '${BROKEN_MODULE_IDS[$idx]}': ${BROKEN_MODULE_REASONS[$idx]}"
            failed=$((failed + 1))
        done
    fi

    log "1. Проверка системных служб..."
    local services_to_check=("nginx" "xray-api")
    if [[ "$role" == "ru_hub" || "$role" == "eu_hub" || "$role" == "exit_node" ]]; then
        services_to_check=("xray" "nginx" "xray-api")
    fi
    for srv in "${services_to_check[@]}"; do
        if systemctl is-active --quiet "$srv" 2>/dev/null; then
            echo -e "  ${GREEN}✔${NC} Служба $srv активна"
        elif [[ ( "$srv" == "xray" || "$srv" == "xray-api" ) && -f "${STATE_DIR:-/etc/just1knode}/traffic_limit_exceeded" ]]; then
            echo -e "  ${YELLOW}!${NC} Служба $srv остановлена по превышению лимита трафика"
            warnings=$((warnings + 1))
        elif systemctl is-failed --quiet "$srv" 2>/dev/null; then
            echo -e "  ${RED}✗${NC} Служба $srv в состоянии FAILED (ошибка запуска или start-limit-hit)"
            failed=$((failed + 1))
        else
            echo -e "  ${RED}✗${NC} Служба $srv не активна"
            failed=$((failed + 1))
        fi
    done

    if [[ -f "${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}/just1knode-apply.path" ]]; then
        if systemctl is-active --quiet just1knode-apply.path 2>/dev/null; then
            echo -e "  ${GREEN}✔${NC} Триггер применения конфигурации just1knode-apply.path активен"
        else
            echo -e "  ${YELLOW}!${NC} Триггер just1knode-apply.path не активен"
            warnings=$((warnings + 1))
        fi
    fi

    # gRPC проверяется на всех настроенных v2-ролях
    if [[ "$role" == "ru_hub" || "$role" == "eu_hub" || "$role" == "exit_node" ]]; then
        log "2. Проверка gRPC порта Xray (127.0.0.1:10085)..."
        if is_traffic_limit_exceeded; then
            echo -e "  ${YELLOW}!${NC} gRPC сокет Xray не проверялся (Xray остановлен по лимиту трафика)"
            warnings=$((warnings + 1))
        else
            local grpc_ok=0
            for _ in 1 2 3; do
                if python3 -c "import socket; s = socket.create_connection(('127.0.0.1', 10085), timeout=2); s.close()" 2>/dev/null; then
                    grpc_ok=1
                    break
                fi
                sleep 0.5
            done
            if [[ $grpc_ok -eq 1 ]]; then
                echo -e "  ${GREEN}✔${NC} gRPC сокет Xray отвечает"
            else
                echo -e "  ${RED}✗${NC} gRPC сокет Xray недоступен (127.0.0.1:10085)"
                failed=$((failed + 1))
            fi
        fi
    fi

    if [[ "$role" == "ru_hub" || "$role" == "eu_hub" || "$role" == "exit_node" ]]; then
        log "3. Проверка конфигурации Xray..."
        if [[ -f "$XRAY_CONFIG" ]] && "$XRAY_BIN" run -test -format json -config "$XRAY_CONFIG" 2>/dev/null; then
            echo -e "  ${GREEN}✔${NC} Конфигурация Xray валидна"
        else
            echo -e "  ${RED}✗${NC} Ошибка конфигурации Xray"
            failed=$((failed + 1))
        fi
    fi

    if (command -v nginx >/dev/null 2>&1 && (systemctl is-active --quiet nginx 2>/dev/null || [[ -f /etc/nginx/nginx.conf ]])); then
        log "4. Проверка синтаксиса Nginx..."
        if nginx -t 2>/dev/null; then
            echo -e "  ${GREEN}✔${NC} Конфигурация Nginx корректна"
        else
            echo -e "  ${RED}✗${NC} Ошибка синтаксиса Nginx"
            failed=$((failed + 1))
        fi
    fi

    log "5. Проверка SSL сертификатов..."
    local check_domains=()
    local d_cand d_cand_lower already existing key d_item
    for key in "domain" "sni"; do
        d_cand="$(get_state_val "$key" "")"
        d_cand_lower="${d_cand,,}"
        if [[ -n "$d_cand" && "$d_cand" != "-" && "$d_cand_lower" != "none" && "$d_cand_lower" != "null" ]]; then
            already=0
            for existing in "${check_domains[@]}"; do
                if [[ "$existing" == "$d_cand" ]]; then
                    already=1
                    break
                fi
            done
            if [[ $already -eq 0 ]]; then
                check_domains+=("$d_cand")
            fi
        fi
    done

    if [[ ${#check_domains[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}i${NC} Персональный SSL домен не настроен (ожидается настройка роли или bootstrap SAN-сертификат)"
    else
        for d_item in "${check_domains[@]}"; do
            if [[ -f "/etc/letsencrypt/live/${d_item}/fullchain.pem" ]]; then
                local cert_file="/etc/letsencrypt/live/${d_item}/fullchain.pem"
                local exp_date
                exp_date="$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2 || echo "НЕИЗВЕСТНО")"

                # Проверка истечения срока действия (F21)
                if ! openssl x509 -checkend 0 -noout -in "$cert_file" 2>/dev/null; then
                    echo -e "  ${RED}✗${NC} SSL сертификат для $d_item истек ($exp_date)!"
                    failed=$((failed + 1))
                elif ! openssl x509 -checkend 2592000 -noout -in "$cert_file" 2>/dev/null; then
                    echo -e "  ${YELLOW}!${NC} SSL сертификат для $d_item истекает менее чем через 30 дней: $exp_date"
                else
                    echo -e "  ${GREEN}✔${NC} SSL сертификат для $d_item валиден до: $exp_date"
                fi

                # Проверка соответствия домена SAN / CN (F21)
                local cert_text
                cert_text="$(openssl x509 -noout -text -in "$cert_file" 2>/dev/null || true)"
                if echo "$cert_text" | grep -qE "DNS:${d_item}\b|DNS:\*\.${d_item#*.}\b|CN\s*=\s*${d_item}\b"; then
                    echo -e "  ${GREEN}✔${NC} Домен $d_item подтвержден в сертификате (SAN/CN)"
                else
                    echo -e "  ${RED}✗${NC} Домен $d_item не найден в SAN/CN сертификата!"
                    failed=$((failed + 1))
                fi
            else
                echo -e "  ${YELLOW}i${NC} SSL сертификат для домена $d_item не найден в /etc/letsencrypt/live"
            fi
        done
    fi

    log "6. Проверка UFW фаервола..."
    if LC_ALL=C ufw status 2>/dev/null | grep -qi "Status: active"; then
        echo -e "  ${GREEN}✔${NC} UFW фаервол активен"
        local ufw_out
        ufw_out="$(LC_ALL=C ufw status verbose 2>/dev/null || LC_ALL=C ufw status 2>/dev/null || true)"

        # Проверка политики входящего трафика по умолчанию
        if echo "$ufw_out" | grep -qi "Default: allow (incoming)"; then
            echo -e "  ${RED}✗${NC} КРИТИЧЕСКАЯ УЯЗВИМОСТЬ: Входящая политика UFW по умолчанию ALLOW (все порты открыты)!"
            echo -e "    ${DIM:-}Рекомендация: sudo ufw default deny incoming${NC}"
            warnings=$((warnings + 1))
        fi

        # Снимаем один снимок слушающих сокетов в системе
        local ss_tcp_listen ss_udp_listen
        ss_tcp_listen="$(ss -tlnp 2>/dev/null || true)"
        ss_udp_listen="$(ss -ulnp 2>/dev/null || true)"

        if [[ "$role" == "ru_hub" || "$role" == "eu_hub" || "$role" == "exit_node" || "$role" == "unconfigured" ]]; then
            local bot_ip
            bot_ip="$(get_state_val "bot_ip")"
            if echo "$ufw_out" | grep -E "8444(/tcp)?\s+ALLOW(\s+IN)?\s+(Anywhere|0\.0\.0\.0/0|::/0)" -q; then
                echo -e "  ${RED}✗${NC} УЯЗВИМОСТЬ: Порт 8444 открыт для всех (0.0.0.0/0)!"
                failed=$((failed + 1))
            elif [[ -n "$bot_ip" ]] && echo "$ufw_out" | grep -F "$bot_ip" | grep -q "8444"; then
                echo -e "  ${GREEN}✔${NC} Порт 8444 защищен и доступен только с BOT_IP ($bot_ip)"
            elif [[ -n "$bot_ip" ]]; then
                echo -e "  ${YELLOW}!${NC} Правило для BOT_IP ($bot_ip) на порт 8444 не найдено в UFW"
                failed=$((failed + 1))
            else
                echo -e "  ${YELLOW}!${NC} BOT_IP не настроен в state.json"
                warnings=$((warnings + 1))
            fi
            if [[ "$role" == "eu_hub" || "$role" == "exit_node" ]]; then
                if echo "$ufw_out" | grep -E "443(/tcp)?\s+ALLOW(\s+IN)?\s+(Anywhere|0\.0\.0\.0/0|::/0)" -q; then
                    echo -e "  ${RED}✗${NC} УЯЗВИМОСТЬ: Порт 443 (${role}) открыт для всего мира (0.0.0.0/0)!"
                    failed=$((failed + 1))
                else
                    echo -e "  ${GREEN}✔${NC} Порт 443 (${role}) закрыт от внешнего мира (Zero-Trust whitelist)"
                fi
            elif [[ "$role" == "ru_hub" ]] && (is_module_enabled "vless_tls" 2>/dev/null || is_module_enabled "vless_xhttp" 2>/dev/null); then
                if echo "$ufw_out" | grep -E "443(/tcp)?\s+ALLOW(\s+IN)?\s+(Anywhere|0\.0\.0\.0/0|::/0)" -q; then
                    echo -e "  ${GREEN}✔${NC} Порт 443 открыт для клиентских подключений"
                else
                    echo -e "  ${YELLOW}!${NC} Порт 443 не найден среди разрешенных в UFW"
                    warnings=$((warnings + 1))
                fi
            fi
        fi

        # 6b. Полный аудит периметра: поиск мёртвых правил и посторонних портов, открытых для всего мира
        local live_ssh_ports=()
        while read -r sp; do
            [[ -n "$sp" && "$sp" =~ ^[0-9]+$ ]] && live_ssh_ports+=("$sp")
        done < <(detect_active_sshd_ports 2>/dev/null || true)
        [[ ${#live_ssh_ports[@]} -eq 0 ]] && live_ssh_ports=("22")

        local ufw_rules_raw
        ufw_rules_raw="$(echo "$ufw_out" | grep -vE '^(Status:|Logging:|Default:|New profiles:|To[[:space:]]+Action|--+[[:space:]]+--+)' | grep -E '[[:space:]]ALLOW([[:space:]]|$)' || true)"

        if [[ -n "$ufw_rules_raw" ]]; then
            local warned_dead_targets=()
            local warned_public_targets=()
            while read -r rule_line; do
                [[ -z "$rule_line" ]] && continue
                # Очищаем (v6) и профили в скобках вида '(Nginx Full)'
                local clean_line
                clean_line=$(echo "$rule_line" | sed -E 's/\(v6\)//g' | sed -E 's/\([^\)]+\)//g')
                clean_line="$(echo "$clean_line" | xargs)"
                [[ -z "$clean_line" ]] && continue

                local raw_target action direction from_part
                raw_target=$(echo "$clean_line" | awk '{print $1}')
                action=$(echo "$clean_line" | awk '{print $2}')

                local token3
                token3=$(echo "$clean_line" | awk '{print $3}')
                if [[ "$token3" == "IN" || "$token3" == "OUT" || "$token3" == "FWD" ]]; then
                    direction="$token3"
                    from_part=$(echo "$clean_line" | awk '{$1=""; $2=""; $3=""; print $0}' | xargs)
                else
                    direction="IN"
                    from_part=$(echo "$clean_line" | awk '{$1=""; $2=""; print $0}' | xargs)
                fi

                [[ "$action" != "ALLOW" ]] && continue
                [[ "$direction" != "IN" ]] && continue

                local is_public=0
                if echo "$from_part" | grep -qiE "(Anywhere|Везде|0\.0\.0\.0/0|::/0)"; then
                    is_public=1
                fi

                # Нормализуем цель: порт/протокол или профиль приложения
                local norm_target proto ports_to_check=()
                norm_target="$raw_target"
                if [[ "$norm_target" == *"/"* ]]; then
                    proto="${norm_target#*/}"
                    local raw_ports="${norm_target%/*}"
                    local old_ifs="$IFS"
                    IFS=',' read -ra port_arr <<< "$raw_ports"
                    IFS="$old_ifs"
                    for p in "${port_arr[@]}"; do
                        [[ -n "$p" ]] && ports_to_check+=("$p")
                    done
                elif [[ "$norm_target" =~ ^[0-9]+$ ]]; then
                    proto="any"
                    ports_to_check+=("$norm_target")
                else
                    proto="tcp"
                    case "$norm_target" in
                        OpenSSH|openssh) ports_to_check+=("22") ;;
                        "Nginx HTTP") ports_to_check+=("80") ;;
                        "Nginx HTTPS") ports_to_check+=("443") ;;
                        "Nginx Full") ports_to_check+=("80" "443") ;;
                        *) ports_to_check+=("$norm_target") ;;
                    esac
                fi

                for r_port in "${ports_to_check[@]}"; do
                    local target_key="${r_port}/${proto}"

                    local matching_line=""
                    if [[ "$proto" == "tcp" ]]; then
                        matching_line=$(echo "$ss_tcp_listen" | grep -E "[:\s]${r_port}[[:space:]]" | head -n 1 || true)
                    elif [[ "$proto" == "udp" ]]; then
                        matching_line=$(echo "$ss_udp_listen" | grep -E "[:\s]${r_port}[[:space:]]" | head -n 1 || true)
                    else
                        matching_line=$(echo "$ss_tcp_listen" | grep -E "[:\s]${r_port}[[:space:]]" | head -n 1 || true)
                        [[ -z "$matching_line" ]] && matching_line=$(echo "$ss_udp_listen" | grep -E "[:\s]${r_port}[[:space:]]" | head -n 1 || true)
                    fi

                    if [[ -z "$matching_line" ]]; then
                        local already_warned=0
                        for dt in "${warned_dead_targets[@]}"; do
                            if [[ "$dt" == "$target_key" ]]; then
                                already_warned=1
                                break
                            fi
                        done
                        if [[ $already_warned -eq 0 ]]; then
                            warned_dead_targets+=("$target_key")
                            echo -e "  ${YELLOW}!${NC} «Мёртвое» правило: порт ${r_port}/${proto} разрешён в UFW, но служба не запущена"
                            echo -e "    ${DIM:-}Рекомендация: если порт не нужен, удалите: ufw delete allow ${norm_target}${NC}"
                            warnings=$((warnings + 1))
                        fi
                    elif [[ $is_public -eq 1 ]]; then
                        # Процесс есть, и порт открыт для всего мира (Anywhere).
                        # Проверяем, является ли он авторизованным публичным портом.
                        local is_authorized=0
                        # 1. Активный порт SSH
                        for sp in "${live_ssh_ports[@]}"; do
                            if [[ "$r_port" == "$sp" && ("$proto" == "tcp" || "$proto" == "any") ]]; then
                                is_authorized=1
                                break
                            fi
                        done
                        # 2. Легитимные веб-порты 80 и 443 (только для публичной роли RU ХАБ)
                        if [[ "$r_port" == "443" && ("$proto" == "tcp" || "$proto" == "any") && "$role" == "ru_hub" ]]; then
                            is_authorized=1
                        elif [[ "$r_port" == "80" && ("$proto" == "tcp" || "$proto" == "any") && "$role" == "ru_hub" && "${USE_WILDCARD_CERT:-1}" == "0" ]]; then
                            is_authorized=1
                        fi

                        if [[ $is_authorized -eq 0 ]]; then
                            local already_warned=0
                            for pt in "${warned_public_targets[@]}"; do
                                if [[ "$pt" == "$target_key" ]]; then
                                    already_warned=1
                                    break
                                fi
                            done
                            if [[ $already_warned -eq 0 ]]; then
                                warned_public_targets+=("$target_key")
                                local proc_name=""
                                proc_name=$(echo "$matching_line" | sed -E 's/.*users:\(\("([^"]+)".*/\1/' || true)
                                [[ -z "$proc_name" || "$proc_name" == "$matching_line" ]] && proc_name="не определен"
                                echo -e "  ${YELLOW}!${NC} ВНИМАНИЕ: Посторонний порт ${r_port}/${proto} (процесс: ${proc_name}) открыт для всех (Anywhere)!"
                                echo -e "    ${DIM:-}Если это сторонний сервис, убедитесь в его необходимости. Для закрытия: ufw delete allow ${norm_target}${NC}"
                                warnings=$((warnings + 1))
                            fi
                        fi
                    fi
                done
            done <<< "$ufw_rules_raw"
        fi
    else
        echo -e "  ${YELLOW}!${NC} UFW фаервол не активен"
        warnings=$((warnings + 1))
    fi

    if [[ "$role" == "ru_hub" ]] && is_module_enabled "vless_xhttp" 2>/dev/null && [[ -n "$(get_state_val "bot_domain" "")" && "$(get_state_val "bot_domain" "")" != "-" ]]; then
        local sub_prefix
        sub_prefix="$(get_state_val "sub_path_prefix" 2>/dev/null || true)"
        if [[ -z "$sub_prefix" ]]; then
            sub_prefix="${WHITE_INTERNET_SUB_PATH_PREFIX:-/sub/wl}"
        fi
        sub_prefix="${sub_prefix%/}"
        [[ ! "$sub_prefix" =~ ^/ ]] && sub_prefix="/$sub_prefix"

        log "8. Проверка Nginx-проксирования подписок (${sub_prefix})..."
        local check_target="${domain:-localhost}"
        local sub_code
        local sub_err=0
        sub_code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 --resolve "${check_target}:443:127.0.0.1" "https://${check_target}${sub_prefix}/ping" 2>/dev/null)" || sub_err=$?
        if [[ "$sub_code" == "200" && $sub_err -eq 0 ]]; then
            echo -e "  ${GREEN}✔${NC} Nginx прокси подписок (${sub_prefix}/ping) отвечает 200 OK (TLS валиден)"
        elif [[ $sub_err -eq 60 ]]; then
            echo -e "  ${RED}✗${NC} ОШИБКА TLS: Сертификат для https://${check_target} недействителен или просрочен (curl error 60)!"
            failed=$((failed + 1))
        elif [[ "$sub_code" == "502" ]]; then
            local current_bot_domain
            current_bot_domain="$(get_state_val "bot_domain" "<не задан>")"
            echo -e "  ${RED}✗${NC} ОШИБКА 502 Bad Gateway: Nginx не может связаться с ботом (bot_domain: '$current_bot_domain')!"
            echo -e "      ${YELLOW}→${NC} Проверьте цепочку SSL (proxy_ssl_verify_depth), DNS и логи: tail -n 10 /var/log/nginx/error.log"
            failed=$((failed + 1))
        elif [[ "$sub_code" == "504" ]]; then
            local current_bot_domain
            current_bot_domain="$(get_state_val "bot_domain" "<не задан>")"
            echo -e "  ${RED}✗${NC} ОШИБКА 504 Gateway Timeout: Nginx не дождался ответа от бота (bot_domain: '$current_bot_domain')!"
            echo -e "      ${YELLOW}→${NC} Возможные причины: IP бота блокируется ТСПУ (TCP SYN drop), бот перегружен/не отвечает или сбой DNS."
            echo -e "      ${YELLOW}→${NC} Проверьте логи: tail -n 10 /var/log/nginx/error.log и убедитесь, что домен бота проксируется через CDN/Cloudflare."
            failed=$((failed + 1))
        elif [[ "$sub_code" == "404" ]]; then
            echo -e "  ${RED}✗${NC} ОШИБКА 404 Not Found: Nginx прокси отвечает 404 (эндпоинт ${sub_prefix}/ping не найден на боте)!"
            failed=$((failed + 1))
        elif [[ $sub_err -eq 28 ]]; then
            echo -e "  ${RED}✗${NC} ТАЙМАУТ ПОДКЛЮЧЕНИЯ (curl error 28): Запрос к https://${check_target}${sub_prefix}/ping превысил лимит времени!"
            echo -e "      ${YELLOW}→${NC} Nginx или вышестоящий бот зависли при обработке. Проверьте: tail -n 10 /var/log/nginx/error.log"
            failed=$((failed + 1))
        elif [[ "$sub_code" == "000" || $sub_err -ne 0 ]]; then
            # Accepted risk: the -k probe below hits only the public /ping
            # endpoint with no secrets, to tell "TLS broken" apart from
            # "nginx down". Either outcome still fails this check.
            local insecure_code
            insecure_code="$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 10 --resolve "${check_target}:443:127.0.0.1" "https://${check_target}${sub_prefix}/ping" 2>/dev/null || echo "000")"
            if [[ "$insecure_code" == "200" ]]; then
                echo -e "  ${RED}✗${NC} TLS ОШИБКА: Nginx отвечает 200 OK только без проверки сертификата (curl -k). Проверьте Let's Encrypt / CA!"
                failed=$((failed + 1))
            else
                echo -e "  ${RED}✗${NC} Не удалось выполнить запрос к https://${check_target}${sub_prefix}/ping (Nginx недоступен, код: $sub_code, err: $sub_err)"
                failed=$((failed + 1))
            fi
        else
            echo -e "  ${RED}✗${NC} ОШИБКА: Nginx прокси вернул неожиданный HTTP код: $sub_code (ожидался 200 OK)!"
            failed=$((failed + 1))
        fi

        local cdn_domain
        cdn_domain="$(get_state_val "cdn_domain" "")"
        if [[ -n "$cdn_domain" && "$cdn_domain" != "$check_target" && "$cdn_domain" != "-" ]]; then
            log "9. Проверка доступности CDN подписок (${cdn_domain})..."
            local cdn_code
            local cdn_err=0
            cdn_code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://${cdn_domain}${sub_prefix}/ping" 2>/dev/null)" || cdn_err=$?
            if [[ "$cdn_code" == "200" && $cdn_err -eq 0 ]]; then
                echo -e "  ${GREEN}✔${NC} Публичный CDN прокси (${sub_prefix}/ping) отвечает 200 OK (TLS валиден)"
            elif [[ $cdn_err -eq 60 ]]; then
                echo -e "  ${RED}✗${NC} ОШИБКА TLS CDN: Сертификат для https://${cdn_domain} не прошел валидацию (curl error 60)!"
                failed=$((failed + 1))
            elif [[ "$cdn_code" == "502" ]]; then
                echo -e "  ${RED}✗${NC} CDN вернул 502 Bad Gateway (проверьте Origin и CDN кэш)!"
                failed=$((failed + 1))
            elif [[ "$cdn_code" == "504" ]]; then
                echo -e "  ${RED}✗${NC} CDN вернул 504 Gateway Timeout: Origin или вышестоящий бот не ответили вовремя!"
                echo -e "      ${YELLOW}→${NC} Проверьте доступность Origin и домена бота, а также логи /var/log/nginx/error.log на Origin."
                failed=$((failed + 1))
            elif [[ "$cdn_code" == "404" ]]; then
                echo -e "  ${RED}✗${NC} CDN вернул 404 Not Found (эндпоинт ${sub_prefix}/ping не найден на CDN/Origin)!"
                failed=$((failed + 1))
            elif [[ $cdn_err -eq 28 ]]; then
                echo -e "  ${RED}✗${NC} ТАЙМАУТ CDN (curl error 28): https://${cdn_domain}${sub_prefix}/ping не ответил вовремя!"
                echo -e "      ${YELLOW}→${NC} Проверьте статус сети CDN и доступность домена из РФ."
                failed=$((failed + 1))
            elif [[ "$cdn_code" == "000" || $cdn_err -ne 0 ]]; then
                local cdn_insecure
                cdn_insecure="$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 10 "https://${cdn_domain}${sub_prefix}/ping" 2>/dev/null || echo "000")"
                if [[ "$cdn_insecure" == "200" ]]; then
                    echo -e "  ${RED}✗${NC} TLS ОШИБКА CDN: ${cdn_domain} отвечает 200 OK только без проверки SSL (curl -k)!"
                    failed=$((failed + 1))
                else
                    echo -e "  ${RED}✗${NC} CDN ${cdn_domain} недоступен по сети с этого узла (код: $cdn_code, err: $cdn_err)"
                    failed=$((failed + 1))
                fi
            else
                echo -e "  ${RED}✗${NC} ОШИБКА: CDN вернул неожиданный HTTP код: $cdn_code (ожидался 200 OK)!"
                failed=$((failed + 1))
            fi
        fi
    fi

    if [[ "$role" == "ru_hub" || "$role" == "eu_hub" ]]; then
        log "7. Проверка доступности подключенных пиров и связей (${role})..."
        local peer_probe_res
        peer_probe_res=$(python3 - "${LINKS_FILE:-/etc/just1knode/links.json}" "${STATE_FILE:-/etc/just1knode/state.json}" <<'PYEOF' 2>/dev/null || true
import json, os, socket, sys, time
links_path, state_path = sys.argv[1], sys.argv[2]
targets = []
if os.path.exists(links_path):
    try:
        links = json.load(open(links_path, encoding="utf-8"))
        for bucket in ("standard_bridges", "bi_bridges", "exits"):
            for item in (links.get(bucket) or []):
                if isinstance(item, dict) and item.get("ip"):
                    targets.append((
                        item.get("name") or item.get("code") or bucket,
                        item.get("code") or bucket,
                        item["ip"],
                        int(item.get("port") or 443),
                    ))
    except Exception:
        pass
try:
    peers = json.load(open(state_path, encoding="utf-8")).get("peers", [])
except Exception:
    peers = []
seen = {(t[2], t[3]) for t in targets}
for p in (peers if isinstance(peers, list) else []):
    if not isinstance(p, dict) or not p.get("ip"): continue
    key = (p["ip"], int(p.get("port", 443)))
    if key in seen: continue
    seen.add(key)
    code = p.get("code", "-")
    targets.append((p.get("name", code), code, p["ip"], int(p.get("port", 443))))
for name, code, ip, port in targets:
    t0 = time.perf_counter()
    try:
        s = socket.create_connection((ip, port), timeout=5.0)
        rtt = round((time.perf_counter() - t0) * 1000, 1)
        s.close()
        print(f"OK\t{name}\t{code}\t{ip}\t{port}\t{rtt}")
    except Exception as e:
        print(f"FAIL\t{name}\t{code}\t{ip}\t{port}\t{e}")
PYEOF
        )
        if [[ -n "$peer_probe_res" ]]; then
            while IFS=$'\t' read -r p_stat p_name p_code p_ip p_port p_val; do
                if [[ "$p_stat" == "OK" ]]; then
                    echo -e "  ${GREEN}✔${NC} Пир '$p_name' ($p_code: $p_ip:$p_port) доступен (RTT: ${p_val}ms)"
                else
                    echo -e "  ${RED}✗${NC} Пир '$p_name' ($p_code: $p_ip:$p_port) НЕ ОТВЕЧАЕТ (${p_val:-timeout})!"
                    failed=$((failed + 1))
                fi
            done <<< "$peer_probe_res"
        else
            echo -e "  ${YELLOW}i${NC} Связи (мосты / ноды) для роли $role не настроены"
        fi
    fi

    if [[ "$role" == "exit_node" || "$role" == "ru_hub" || "$(get_state_val "abuse_protection" "disabled")" == "enabled" ]]; then
        log "10. Проверка правил сетевой защиты Anti-Abuse..."
        if check_antiabuse_rules; then
            echo -e "  ${GREEN}✔${NC} Сетевая защита Anti-Abuse активна (SMTP:25 + BitTorrent L7 TCP/UDP/DHT)"
        else
            echo -e "  ${YELLOW}!${NC} Сетевая защита Anti-Abuse неполная или отсутствует в iptables"
            warn "ВНИМАНИЕ: Сетевая защита Anti-Abuse не активна! Запуск автоматического восстановления (Auto-Heal)..."
            if apply_antiabuse_protection && check_antiabuse_rules; then
                echo -e "  ${GREEN}✔${NC} Правила сетевой защиты Anti-Abuse успешно восстановлены и активны."
            else
                echo -e "  ${RED}✗${NC} ОШИБКА: Не удалось восстановить правила Anti-Abuse (проверьте модуль ядра xt_string)!"
                failed=$((failed + 1))
            fi
        fi
    fi

    log "11. Проверка отключения IPv6 (защита от утечек трафика)..."
    local ipv6_val="0"
    local ipv6_supported=1
    if [[ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
        ipv6_val="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo "0")"
    else
        if ! command -v ip >/dev/null 2>&1 || ! ip -6 route show >/dev/null 2>&1; then
            ipv6_supported=0
        fi
        ipv6_val="1"
    fi
    local sysctl_conf="${JUST1KNODE_SYSCTL_IPV6_CONF:-/etc/sysctl.d/99-disable-ipv6.conf}"
    local ipv6_persisted=0
    if [[ -f "$sysctl_conf" ]] && grep -Eq '^[[:space:]]*net\.ipv6\.conf\.all\.disable_ipv6[[:space:]]*=[[:space:]]*1' "$sysctl_conf" 2>/dev/null; then
        ipv6_persisted=1
    fi

    if [[ $ipv6_supported -eq 0 ]]; then
        echo -e "  ${GREEN}✔${NC} IPv6 отключен на уровне ядра/гипервизора (стек IPv6 не поддерживается)"
    elif [[ "$ipv6_val" == "1" && "$ipv6_persisted" -eq 1 ]]; then
        echo -e "  ${GREEN}✔${NC} IPv6 отключен (защита активна в ядре и сохранена в drop-in)"
    elif [[ "$ipv6_val" == "1" ]]; then
        echo -e "  ${RED}✗${NC} IPv6 отключен в ядре, но не зафиксирован в $sysctl_conf (до перезагрузки, выполните: just1knode update)"
        failed=$((failed + 1))
    elif [[ "$ipv6_persisted" -eq 1 ]]; then
        echo -e "  ${RED}✗${NC} Рассинхронизация: IPv6 отключен в $sysctl_conf, но активен в ядре (выполните: just1knode update)"
        failed=$((failed + 1))
    else
        echo -e "  ${RED}✗${NC} IPv6 активен (защита от утечек трафика выключена, выполните: just1knode update)"
        failed=$((failed + 1))
    fi

    log "12. Проверка сетевого стелс-режима (ICMP Echo)..."
    local icmp_val="0"
    if [[ -f /proc/sys/net/ipv4/icmp_echo_ignore_all ]]; then
        icmp_val="$(cat /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null || echo "0")"
    fi
    local icmp_persisted=0
    if [[ -f "$sysctl_conf" ]] && grep -Eq '^[[:space:]]*net\.ipv4\.icmp_echo_ignore_all[[:space:]]*=[[:space:]]*1' "$sysctl_conf" 2>/dev/null; then
        icmp_persisted=1
    fi

    if [[ "$icmp_val" == "1" && "$icmp_persisted" -eq 1 ]]; then
        echo -e "  ${GREEN}✔${NC} ICMP Echo отключен (стелс-режим активен в ядре и сохранен в drop-in)"
    elif [[ "$icmp_val" == "1" ]]; then
        echo -e "  ${RED}✗${NC} ICMP Echo отключен в ядре, но не зафиксирован в $sysctl_conf (до перезагрузки, выполните: just1knode update)"
        failed=$((failed + 1))
    elif [[ "$icmp_persisted" -eq 1 ]]; then
        echo -e "  ${RED}✗${NC} Рассинхронизация: ICMP Echo отключен в $sysctl_conf, но активен в ядре (выполните: just1knode update)"
        failed=$((failed + 1))
    else
        echo -e "  ${RED}✗${NC} ICMP Echo активен (стелс-режим выключен, выполните: just1knode update)"
        failed=$((failed + 1))
    fi

    if [[ $failed -eq 0 && $warnings -eq 0 ]]; then
        echo -e "\n${BOLD}${GREEN}Все проверки пройдены успешно! Узел полностью здоров.${NC}\n"
        return 0
    elif [[ $failed -eq 0 ]]; then
        echo -e "\n${BOLD}${YELLOW}Проверки завершены с предупреждениями (предупреждений: ${warnings}).${NC}\n"
        return 0
    else
        echo -e "\n${BOLD}${RED}Обнаружено ошибок: ${failed}, предупреждений: ${warnings}. Требуется внимание администратора.${NC}\n"
        return 1
    fi
}

reset_node() {
    title "СБРОС И ПЕРЕУСТАНОВКА УЗЛА"
    check_root

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${YELLOW}⚠️  ВНИМАНИЕ: СБРОС И ПЕРЕУСТАНОВКА УЗЛА JUST1KNODE${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "Вы собираетесь сбросить конфигурацию узла в исходное состояние (Clean Slate)."
    echo ""
    echo -e "${BOLD}Что произойдет:${NC}"
    echo -e "  1. ${BOLD}Защитный бэкап:${NC} автоматическое сохранение текущего состояния в /var/backups/just1knode/"
    echo -e "  2. ${BOLD}Системные службы:${NC} остановка и отключение xray, xray-api"
    echo -e "  3. ${BOLD}Конфигурация узла:${NC} очистка /etc/just1knode (роль, релеи, state.json)"
    echo -e "  4. ${BOLD}Веб-сервер Nginx:${NC} удаление хостов just1knode, восстановление дефолтного сайта"
    echo -e "  5. ${BOLD}Сохранение системы:${NC} утилита just1knode, ядро Xray и системные пакеты НЕ удаляются"
    echo ""
    echo -e "${BOLD}${YELLOW}⚠️  СЕРВЕР ПЕРЕСТАНЕТ ПРИНИМАТЬ ТРАФИК ДО ПОВТОРНОЙ НАСТРОЙКИ РОЛИ!${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    local confirm=""
    read -rp "Вы уверены, что хотите сбросить узел? (введите 'yes' или 'СБРОСИТЬ' для подтверждения, Enter для отмены): " confirm
    if [[ "$confirm" != "yes" && "$confirm" != "СБРОСИТЬ" ]]; then
        info "Сброс отменен пользователем."
        return
    fi

    # Автоматическое создание аварийной резервной копии перед сбросом
    local bak_dir="${BACKUP_DIR:-/var/backups/just1knode}"
    local reset_bak="${bak_dir}/reset_$(date +%Y%m%d_%H%M%S).tar.gz"
    mkdir -p "$bak_dir" 2>/dev/null || true
    if [[ -d /etc/just1knode ]]; then
        if tar -czf "$reset_bak" -C /etc just1knode 2>/dev/null; then
            chmod 600 "$reset_bak" 2>/dev/null || true
            log "✔ Создана резервная копия узла перед сбросом: $reset_bak"
        fi
    fi

    systemctl stop just1knode-apply.path just1knode-apply.service xray xray-api 2>/dev/null || true
    systemctl disable just1knode-apply.path just1knode-apply.service xray xray-api 2>/dev/null || true
    cleanup_legacy_traffic_watchdog_residue
    remove_traffic_limit_timer
    remove_antiabuse_protection 2>/dev/null || true
    rm -f /etc/nginx/sites-enabled/just1k-origin.conf /etc/nginx/sites-available/just1k-origin.conf /etc/nginx/sites-enabled/just1k-vless-api.conf /etc/nginx/sites-available/just1k-vless-api.conf /etc/nginx/sites-enabled/just1k-fallback80.conf /etc/nginx/sites-available/just1k-fallback80.conf /etc/nginx/conf.d/just1k-origin.conf /etc/nginx/conf.d/just1k-bootstrap.conf /etc/nginx/conf.d/just1k-xhttp-upstreams.conf /etc/nginx/conf.d/xhttp-map.conf /etc/nginx/conf.d/just1k-stream443.conf /etc/nginx/streams-enabled/just1k-stream443.conf /etc/modules-load.d/just1knode.conf /etc/letsencrypt/renewal-hooks/deploy/20-just1knode-restart-xray.sh /etc/letsencrypt/renewal-hooks/deploy/restart-xray.sh /etc/letsencrypt/renewal-hooks/deploy/restart-xray-nginx.sh /etc/letsencrypt/renewal-hooks/pre/05-just1knode-nginx.sh /etc/letsencrypt/renewal-hooks/post/05-just1knode-nginx.sh /run/just1knode* 2>/dev/null || true
    if [[ -f /etc/nginx/nginx.conf ]]; then
        sed -i '/# JUST1KNODE STREAM443 START/,/# JUST1KNODE STREAM443 END/d' /etc/nginx/nginx.conf 2>/dev/null || true
    fi
    if [[ -d /etc/letsencrypt/renewal ]]; then
        for rconf in /etc/letsencrypt/renewal/*.conf; do
            [[ -f "$rconf" ]] || continue
            if grep -Eq "(/run/just1knode|20-just1knode)" "$rconf" 2>/dev/null; then
                sed -i -E '/^[[:space:]]*(pre_hook|post_hook)[[:space:]]*=.*(\/run\/just1knode|20-just1knode).*/d' "$rconf" 2>/dev/null || true
            fi
        done
    fi
    rm -rf /etc/nginx/fallback_ssl /etc/nginx/just1k_relays.d /etc/just1knode /etc/xray-api "${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}/xray.service.d" 2>/dev/null || true
    if [[ ! -e /etc/nginx/sites-enabled/default ]]; then
        if [[ -f /etc/nginx/sites-available/default.user.bak ]]; then
            cp -a /etc/nginx/sites-available/default.user.bak /etc/nginx/sites-available/default 2>/dev/null || true
            ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null || true
            rm -f /etc/nginx/sites-available/default.user.bak 2>/dev/null || true
        fi
    fi
    systemctl reload nginx 2>/dev/null || true
    log "Узел успешно сброшен в исходное состояние."
}

# =============================================================================
# ПОЛНОЕ БЕЗВОЗВРАТНОЕ УДАЛЕНИЕ JUST1KNODE (UNINSTALL)
# =============================================================================
uninstall_node() {
    title "ПОЛНОЕ БЕЗВОЗВРАТНОЕ УДАЛЕНИЕ JUST1KNODE (UNINSTALL)"
    check_root
    init_state_dir

    local force=false
    local confirm_code=""
    local purge_backups=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f)
                force=true
                shift
                ;;
            --confirm=*)
                confirm_code="${1#*=}"
                shift
                ;;
            --confirm)
                if [[ $# -ge 2 && "$2" != --* ]]; then
                    confirm_code="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --purge-backups)
                purge_backups=true
                shift
                ;;
            --uninstall)
                shift
                ;;
            --yes|-y)
                force=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    echo ""
    echo -e "${RED}════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${RED}🚨 ВНИМАНИЕ: ПОЛНОЕ И БЕЗВОЗВРАТНОЕ УДАЛЕНИЕ JUST1KNODE (UNINSTALL)${NC}"
    echo -e "${RED}════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "Вы собираетесь полностью удалить узел just1knode с данного сервера."
    echo ""
    echo -e "${BOLD}Что будет остановлено и удалено без остатка:${NC}"
    echo -e "  1. ${BOLD}Системные службы systemd:${NC} остановка и отключение xray.service, xray-api.service"
    echo -e "  2. ${BOLD}Юниты systemd:${NC} /etc/systemd/system/xray*.service (целевой reset-failed)"
    echo -e "  3. ${BOLD}Процессы:${NC} завершение всех активных фоновых процессов Xray и Uvicorn API"
    echo -e "  4. ${BOLD}Пользователь и группа:${NC} системная учетная запись 'xrayapi'"
    echo -e "  5. ${BOLD}Исполняемые файлы и базы:${NC} ${XRAY_BIN:-/usr/local/bin/xray}, ${XRAY_SHARE_DIR:-/usr/local/share/xray} (geoip/geosite)"
    echo -e "  6. ${BOLD}Конфигурации Xray:${NC} ${XRAY_CONFIG_DIR:-/usr/local/etc/xray}"
    echo -e "  7. ${BOLD}Агент Xray-API:${NC} ${XRAY_API_DIR:-/opt/xray-api}, ${XRAY_API_ETC:-/etc/xray-api}, ${XRAY_API_LIB:-/var/lib/xray-api}"
    echo -e "  8. ${BOLD}Веб-сервер Nginx:${NC} виртуальный хост just1k-origin.conf, conf.d/xhttp-map.conf, just1k_relays.d"
    echo -e "     (атомарное восстановление default сайта, если создавалась резервная копия default.user.bak)"
    echo -e "  9. ${BOLD}Let's Encrypt renewal hook:${NC} deploy-скрипт перезапуска служб"
    echo -e "  10. ${BOLD}Камуфляжный сайт:${NC} /var/www/html/index.html (если создан just1knode)"
    echo -e "  11. ${BOLD}Конфигурация ядра:${NC} ${JUST1KNODE_SYSCTL_IPV6_CONF:-/etc/sysctl.d/99-disable-ipv6.conf} (восстановление IPv6 в runtime)"
    echo -e "  12. ${BOLD}Фаервол UFW:${NC} удаление открытых портов (8444, Relay tunnel)"
    echo -e "  13. ${BOLD}Каталог состояния и бэкапов:${NC} ${STATE_DIR:-/etc/just1knode} (бэкапы в ${BACKUP_DIR:-/var/backups/just1knode} сохраняются без --purge-backups)"
    echo -e "  14. ${BOLD}Глобальная команда:${NC} /usr/local/bin/just1knode"
    echo -e "  15. ${BOLD}Директория утилиты:${NC} ${INSTALL_DIR:-/opt/just1knode}"
    echo ""
    echo -e "${BOLD}${RED}⚠️  ВНИМАНИЕ: СЕРВЕР ПЕРЕСТАНЕТ ПРИНИМАТЬ VPN-ТРАФИК И ОБСЛУЖИВАТЬ КЛИЕНТОВ!${NC}"
    echo -e "${RED}════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    if [[ "$confirm_code" == "DELETE" || "$confirm_code" == "УДАЛИТЬ" ]]; then
        info "Подтверждение удаления получено через аргумент командной строки (--confirm)."
    elif [[ "$force" == "true" ]]; then
        error "Для удаления с флагом --force / --yes требуется явное подтверждение: --confirm=DELETE (или --confirm=УДАЛИТЬ). Процедура прервана (Fail-Closed)."
        return 1
    else
        # Confirmation step 1
        local c1="n"
        if ! read -r -t 60 -p "Вы действительно хотите начать процедуру полного удаления just1knode? [y/N]: " c1; then
            echo ""
            error "В неинтерактивном режиме для удаления требуется явный флаг: --confirm=DELETE (или --confirm=УДАЛИТЬ). Процедура прервана (Fail-Closed)."
            return 1
        fi
        if [[ ! "$c1" =~ ^[Yy]$ ]]; then
            info "Удаление отменено пользователем."
            return 0
        fi

        # Confirmation step 2 (strict keyword match)
        echo ""
        echo -e "${BOLD}${RED}ФИНАЛЬНОЕ ПОДТВЕРЖДЕНИЕ! Это действие необратимо.${NC}"
        local c2=""
        if ! read -r -t 60 -p "Для подтверждения введите заглавными буквами слово 'УДАЛИТЬ' или 'DELETE': " c2; then
            echo ""
            c2=""
        fi
        if [[ "$c2" != "DELETE" && "$c2" != "УДАЛИТЬ" ]]; then
            warn "Подтверждение не совпало (введено: '$c2'). Удаление отменено!"
            return 0
        fi

        # Интерактивный запрос на удаление каталога бэкапов
        local bak_dir="${BACKUP_DIR:-/var/backups/just1knode}"
        if [[ "$purge_backups" != "true" && -d "$bak_dir" ]]; then
            local bak_count
            bak_count="$(find "$bak_dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
            if [[ "$bak_count" -gt 0 ]]; then
                local bak_size
                bak_size="$(du -sh "$bak_dir" 2>/dev/null | awk '{print $1}')"
                local c_purge="n"
                read -r -t 30 -p "Удалить архивные бэкапы предыдущих версий ($bak_dir, занято: ${bak_size:-0B})? [y/N]: " c_purge || true
                if [[ "$c_purge" =~ ^[Yy]$ ]]; then
                    purge_backups=true
                fi
            fi
        fi
    fi

    local node_cleanup_errors=()

    # Валидация системных путей (Defense-in-Depth защита от удаления критических каталогов ОС)
    local protected_node_paths=(
        "${XRAY_CONFIG_DIR:-/usr/local/etc/xray}"
        "${XRAY_SHARE_DIR:-/usr/local/share/xray}"
        "${XRAY_API_DIR:-/opt/xray-api}"
        "${XRAY_API_ETC:-/etc/xray-api}"
        "${XRAY_API_LIB:-/var/lib/xray-api}"
        "${STATE_DIR:-/etc/just1knode}"
        "${BACKUP_DIR:-/var/backups/just1knode}"
    )
    for p in "${protected_node_paths[@]}"; do
        local norm_p="${p%/}"
        if [[ -z "$norm_p" || "$norm_p" =~ ^(/|/etc|/var|/usr|/usr/local|/root|/home|/tmp|/opt)$ ]]; then
            error "Попытка удаления защищенного системного каталога ($p)! Процедура удаления прервана (Fail-Closed)."
            return 1
        fi
    done

    info "1/11. Остановка и отключение системных служб systemd..."
    cleanup_legacy_traffic_watchdog_residue
    remove_traffic_limit_timer
    systemctl stop just1knode-apply.path just1knode-apply.service xray xray-api 2>/dev/null || true
    systemctl disable just1knode-apply.path just1knode-apply.service xray xray-api 2>/dev/null || true
    rm -f "${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}/xray.service" \
          "${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}/xray-api.service" \
          "${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}/just1knode-apply.path" \
          "${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}/just1knode-apply.service" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed just1knode-apply.path just1knode-apply.service xray xray-api just1knode-traffic.service just1knode-traffic.timer just1knode-traffic-limit.service just1knode-traffic-limit.timer 2>/dev/null || true

    info "2/11. Завершение активных процессов ядра и API..."
    local xray_proc_name
    xray_proc_name="$(basename "${XRAY_BIN:-xray}")"
    pkill -9 -x "$xray_proc_name" 2>/dev/null || true
    pkill -9 -u xrayapi 2>/dev/null || true

    info "3/11. Удаление пользователя и группы xrayapi..."
    if id -u xrayapi >/dev/null 2>&1; then
        userdel -f xrayapi 2>/dev/null || userdel xrayapi 2>/dev/null || node_cleanup_errors+=("Не удалось удалить системного пользователя xrayapi")
    fi
    if getent group xrayapi >/dev/null 2>&1; then
        groupdel xrayapi 2>/dev/null || true
    fi

    info "4/11. Удаление бинарных файлов и конфигураций Xray..."
    rm -f "${XRAY_BIN:-/usr/local/bin/xray}" 2>/dev/null || true
    rm -rf "${XRAY_CONFIG_DIR:-/usr/local/etc/xray}" 2>/dev/null || true
    rm -rf "${XRAY_SHARE_DIR:-/usr/local/share/xray}" 2>/dev/null || true

    info "5/11. Удаление агентов API (Xray-API) и виртуальных окружений..."
    rm -rf "${XRAY_API_DIR:-/opt/xray-api}" 2>/dev/null || true
    rm -rf "${XRAY_API_ETC:-/etc/xray-api}" 2>/dev/null || true
    rm -rf "${XRAY_API_LIB:-/var/lib/xray-api}" 2>/dev/null || true

    info "6/11. Очистка конфигурации Nginx и сетевых правил..."
    local nginx_conf_dir="${NGINX_CONF_DIR:-/etc/nginx}"
    rm -f "${nginx_conf_dir}/sites-enabled/just1k-origin.conf" 2>/dev/null || true
    rm -f "${nginx_conf_dir}/sites-available/just1k-origin.conf" 2>/dev/null || true
    rm -f "${nginx_conf_dir}/sites-enabled/just1k-vless-api.conf" 2>/dev/null || true
    rm -f "${nginx_conf_dir}/sites-available/just1k-vless-api.conf" 2>/dev/null || true
    rm -f "${nginx_conf_dir}/sites-enabled/just1k-fallback80.conf" 2>/dev/null || true
    rm -f "${nginx_conf_dir}/sites-available/just1k-fallback80.conf" 2>/dev/null || true
    rm -f "${nginx_conf_dir}/conf.d/just1k-origin.conf" 2>/dev/null || true
    rm -f "${nginx_conf_dir}/conf.d/just1k-bootstrap.conf" 2>/dev/null || true
    rm -f "${nginx_conf_dir}/conf.d/just1k-xhttp-upstreams.conf" 2>/dev/null || true
    rm -f "${nginx_conf_dir}/conf.d/xhttp-map.conf" 2>/dev/null || true
    rm -f "${nginx_conf_dir}/conf.d/just1k-stream443.conf" "${nginx_conf_dir}/streams-enabled/just1k-stream443.conf" 2>/dev/null || true
    if [[ -f "${nginx_conf_dir}/nginx.conf" ]]; then
        sed -i '/# JUST1KNODE STREAM443 START/,/# JUST1KNODE STREAM443 END/d' "${nginx_conf_dir}/nginx.conf" 2>/dev/null || true
    fi
    rm -rf "${nginx_conf_dir}/fallback_ssl" 2>/dev/null || true
    rm -rf "${NGINX_RELAYS_DIR:-/etc/nginx/just1k_relays.d}" 2>/dev/null || true
    remove_antiabuse_protection 2>/dev/null || true

    if [[ -f "${nginx_conf_dir}/sites-available/default.user.bak" ]]; then
        info "Восстановление исходного default сайта в Nginx..."
        if cp -a "${nginx_conf_dir}/sites-available/default.user.bak" "${nginx_conf_dir}/sites-available/default" 2>/dev/null; then
            ln -sf "${nginx_conf_dir}/sites-available/default" "${nginx_conf_dir}/sites-enabled/default" 2>/dev/null || true
            rm -f "${nginx_conf_dir}/sites-available/default.user.bak" 2>/dev/null || true
        else
            node_cleanup_errors+=("Не удалось восстановить default.user.bak в Nginx")
        fi
    elif [[ -f "${nginx_conf_dir}/sites-available/default" && ! -e "${nginx_conf_dir}/sites-enabled/default" ]]; then
        info "Восстановление стандартного default сайта в Nginx..."
        ln -sf "${nginx_conf_dir}/sites-available/default" "${nginx_conf_dir}/sites-enabled/default" 2>/dev/null || true
    fi

    if command -v nginx >/dev/null 2>&1; then
        if systemctl is-active --quiet nginx 2>/dev/null; then
            if nginx -t >/dev/null 2>&1; then
                systemctl reload nginx 2>/dev/null || true
            fi
        fi
    fi

    info "7/11. Удаление веб-файлов и хуков Let's Encrypt..."
    local www_index="${WWW_HTML_DIR:-/var/www/html}/index.html"
    if [[ -f "$www_index" ]] && (grep -q "Cloud Ingress Network Node" "$www_index" 2>/dev/null || grep -q "SimpleCalc" "$www_index" 2>/dev/null || grep -q "Edge Gateway" "$www_index" 2>/dev/null); then
        rm -f "$www_index" 2>/dev/null || true
    fi
    local certbot_dir="${CERTBOT_DIR:-/var/www/certbot}"
    if [[ -d "$certbot_dir" ]] && [[ -z "$(ls -A "$certbot_dir" 2>/dev/null)" ]]; then
        rmdir "$certbot_dir" 2>/dev/null || true
    fi
    rm -f "${LETSENCRYPT_DIR:-/etc/letsencrypt}/renewal-hooks/deploy/20-just1knode-restart-xray.sh" \
          "${LETSENCRYPT_DIR:-/etc/letsencrypt}/renewal-hooks/deploy/restart-xray.sh" \
          "${LETSENCRYPT_DIR:-/etc/letsencrypt}/renewal-hooks/deploy/restart-xray-nginx.sh" \
          "${LETSENCRYPT_DIR:-/etc/letsencrypt}/renewal-hooks/pre/05-just1knode-nginx.sh" \
          "${LETSENCRYPT_DIR:-/etc/letsencrypt}/renewal-hooks/post/05-just1knode-nginx.sh" 2>/dev/null || true
    if [[ -d "${LETSENCRYPT_DIR:-/etc/letsencrypt}/renewal" ]]; then
        for rconf in "${LETSENCRYPT_DIR:-/etc/letsencrypt}/renewal"/*.conf; do
            [[ -f "$rconf" ]] || continue
            if grep -Eq "(/run/just1knode|20-just1knode)" "$rconf" 2>/dev/null; then
                sed -i -E '/^[[:space:]]*(pre_hook|post_hook)[[:space:]]*=.*(\/run\/just1knode|20-just1knode).*/d' "$rconf" 2>/dev/null || true
            fi
        done
    fi

    info "8/11. Удаление конфигурации ядра sysctl и восстановление параметров сети..."
    local sysctl_ipv6_conf="${JUST1KNODE_SYSCTL_IPV6_CONF:-/etc/sysctl.d/99-disable-ipv6.conf}"
    local sysctl_cleaned=0
    if [[ -f "$sysctl_ipv6_conf" ]]; then
        rm -f "$sysctl_ipv6_conf" 2>/dev/null || true
        sysctl_cleaned=1
    fi
    local modules_load_conf="${MODULES_LOAD_CONF:-/etc/modules-load.d/just1knode.conf}"
    if [[ -f "$modules_load_conf" ]]; then
        rm -f "$modules_load_conf" 2>/dev/null || true
    fi
    local ufw_conf="${JUST1KNODE_UFW_SYSCTL_CONF:-/etc/ufw/sysctl.conf}"
    if [[ -f "$ufw_conf" ]]; then
        sed -i -E '/^[#[:space:]]*net\/ipv4\/icmp_echo_ignore_all[[:space:]]*=/d' "$ufw_conf" 2>/dev/null || true
    fi
    if command -v sysctl >/dev/null 2>&1; then
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1 || true
        if [[ $sysctl_cleaned -eq 1 ]]; then
            sysctl --system >/dev/null 2>&1 || true
        fi
    fi

    info "9/11. Очистка правил фаервола (UFW)..."
    if command -v ufw >/dev/null 2>&1; then
        local st_relay_port st_origin_ip st_bot_ip
        st_relay_port="$(get_state_val "relay_port" 2>/dev/null || true)"
        st_origin_ip="$(get_state_val "origin_ip" 2>/dev/null || true)"
        st_bot_ip="$(get_state_val "bot_ip" 2>/dev/null || true)"

        if ufw status 2>/dev/null | grep -qi "Status: active"; then
            local ufw_num_out
            ufw_num_out="$(ufw status numbered 2>/dev/null || true)"
            local r_nums=()
            while IFS= read -r rule_line; do
                [[ -z "$rule_line" ]] && continue
                if [[ "$rule_line" =~ ^\[[[:space:]]*([0-9]+)\][[:space:]]+(.*)$ ]]; then
                    local r_n="${BASH_REMATCH[1]}"
                    local r_body="${BASH_REMATCH[2]}"

                    # Zero-Lockout: категорически пропускаем любые SSH-правила
                    if echo "$r_body" | grep -qiE '\bssh\b|ssh access'; then
                        continue
                    fi

                    local first_tok t_port
                    first_tok="$(echo "$r_body" | awk '{print $1}')"
                    t_port="${first_tok%/*}"
                    [[ "$t_port" =~ ^[0-9]+$ ]] || continue
                    if is_ssh_port "$t_port"; then
                        continue
                    fi

                    # Очистка строго собственных правил Just1kNode
                    local is_node_rule=0
                    if [[ "$t_port" == "8444" || "$t_port" == "8443" || "$t_port" == "443" ]]; then
                        if [[ "$t_port" == "443" ]] && echo "$r_body" | grep -qiE '\b(https web service|caddy)\b'; then
                            is_node_rule=0
                        else
                            is_node_rule=1
                        fi
                    elif [[ -n "$st_relay_port" && "$t_port" == "$st_relay_port" ]]; then
                        is_node_rule=1
                    elif echo "$r_body" | grep -qiE '(just1knode (origin api|relay tunnel|vless direct|xray-api bot_ip|certbot verification|hub ingress|eu_hub bridge))'; then
                        is_node_rule=1
                    fi

                    if [[ $is_node_rule -eq 1 ]]; then
                        r_nums+=("$r_n")
                    fi
                fi
            done <<< "$ufw_num_out"

            if [[ ${#r_nums[@]} -gt 0 ]]; then
                local sorted_nums
                sorted_nums="$(printf "%s\n" "${r_nums[@]}" | sort -rn -u)"
                for r_n in $sorted_nums; do
                    if [[ -n "$r_n" ]]; then
                        echo "y" | ufw delete "$r_n" >/dev/null 2>&1 || true
                    fi
                done
            fi
        fi

        if [[ -n "$st_relay_port" ]] && ! is_ssh_port "$st_relay_port"; then
            if [[ -n "$st_origin_ip" ]]; then
                ufw delete allow from "$st_origin_ip" to any port "$st_relay_port" proto tcp >/dev/null 2>&1 || true
            fi
            ufw delete allow "$st_relay_port"/tcp >/dev/null 2>&1 || true
            ufw delete allow "$st_relay_port" >/dev/null 2>&1 || true
        fi
        if ! is_ssh_port "8444"; then
            if [[ -n "$st_bot_ip" ]]; then
                ufw delete allow from "$st_bot_ip" to any port 8444 proto tcp >/dev/null 2>&1 || true
            fi
            ufw delete allow 8444/tcp >/dev/null 2>&1 || true
            ufw delete allow 8444 >/dev/null 2>&1 || true
        fi
        if ! is_ssh_port "8443"; then
            if [[ -n "$st_bot_ip" ]]; then
                ufw delete allow from "$st_bot_ip" to any port 8443 proto tcp >/dev/null 2>&1 || true
            fi
            ufw delete allow 8443/tcp >/dev/null 2>&1 || true
            ufw delete allow 8443 >/dev/null 2>&1 || true
        fi
        if ! is_ssh_port "443"; then
            if ! (command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^just1kbot_caddy\b"); then
                ufw delete allow 443/tcp >/dev/null 2>&1 || true
                ufw delete allow 443 >/dev/null 2>&1 || true
            fi
        fi
    fi

    info "10/11. Удаление состояния, бэкапов и блокировок..."
    rm -rf "${STATE_DIR:-/etc/just1knode}" 2>/dev/null || true
    if [[ "$purge_backups" == "true" ]]; then
        rm -rf "${BACKUP_DIR:-/var/backups/just1knode}" 2>/dev/null || true
        log "Каталог бэкапов ${BACKUP_DIR:-/var/backups/just1knode} удален (--purge-backups)."
    else
        log "Каталог бэкапов сохранен: ${BACKUP_DIR:-/var/backups/just1knode} (используйте --purge-backups для удаления)."
    fi
    rm -rf /run/lock/just1knode /run/just1knode* /tmp/just1knode* "${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}/xray.service.d" 2>/dev/null || true

    info "11/11. Удаление глобальной команды и каталога установки..."
    local global_bin="${JUST1KNODE_GLOBAL_BIN:-/usr/local/bin/just1knode}"
    rm -f "$global_bin" 2>/dev/null || true

    local install_dir="${INSTALL_DIR:-/opt/just1knode}"
    cd /tmp || cd /
    if [[ "$install_dir" == "/opt/just1knode" || -n "${JUST1KNODE_ALLOW_CUSTOM_INSTALL_RM:-}" ]]; then
        if [[ -d "$install_dir" ]]; then
            rm -rf "$install_dir" 2>/dev/null || true
        fi
    fi

    # Post-Uninstall Verification & Fail-Closed Reporting
    info "Верификация чистоты системы после удаления (Post-Verification)..."
    if [[ -d "$install_dir" && "$install_dir" == "/opt/just1knode" ]]; then
        node_cleanup_errors+=("Директория установки все еще существует: $install_dir")
    fi
    if [[ -e "$global_bin" || -L "$global_bin" ]]; then
        node_cleanup_errors+=("Глобальный исполняемый файл все еще существует: $global_bin")
    fi
    if [[ -f "$sysctl_ipv6_conf" ]]; then
        node_cleanup_errors+=("Файл sysctl $sysctl_ipv6_conf все еще существует")
    fi
    if [[ -f "$modules_load_conf" ]]; then
        node_cleanup_errors+=("Конфигурация модулей ядра $modules_load_conf все еще существует")
    fi
    if [[ -e "${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}/xray.service" ]]; then
        node_cleanup_errors+=("Служба systemd xray.service все еще существует")
    fi
    if [[ -e "${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}/xray-api.service" ]]; then
        node_cleanup_errors+=("Служба systemd xray-api.service все еще существует")
    fi
    if [[ -d "${nginx_conf_dir}/fallback_ssl" ]]; then
        node_cleanup_errors+=("Каталог fallback_ssl в Nginx все еще существует")
    fi
    if [[ -f "${nginx_conf_dir}/conf.d/just1k-xhttp-upstreams.conf" ]]; then
        node_cleanup_errors+=("Файл конфигурации upstreams все еще существует в Nginx")
    fi
    if [[ -d "${XRAY_API_DIR:-/opt/xray-api}" ]]; then
        node_cleanup_errors+=("Каталог xray-api все еще существует: ${XRAY_API_DIR:-/opt/xray-api}")
    fi
    if [[ -d "${STATE_DIR:-/etc/just1knode}" ]]; then
        node_cleanup_errors+=("Каталог состояния state все еще существует: ${STATE_DIR:-/etc/just1knode}")
    fi
    if [[ -d "${XRAY_CONFIG_DIR:-/usr/local/etc/xray}" ]]; then
        node_cleanup_errors+=("Каталог конфигурации xray все еще существует: ${XRAY_CONFIG_DIR:-/usr/local/etc/xray}")
    fi
    if [[ "$purge_backups" == "true" && -d "${BACKUP_DIR:-/var/backups/just1knode}" ]]; then
        node_cleanup_errors+=("Каталог бэкапов все еще существует при флаге --purge-backups: ${BACKUP_DIR:-/var/backups/just1knode}")
    fi
    if [[ -f "${nginx_conf_dir}/sites-available/just1k-vless-api.conf" || -L "${nginx_conf_dir}/sites-enabled/just1k-vless-api.conf" ]]; then
        node_cleanup_errors+=("Конфигурация just1k-vless-api.conf все еще существует в Nginx")
    fi
    if [[ -f "${nginx_conf_dir}/sites-available/just1k-origin.conf" || -L "${nginx_conf_dir}/sites-enabled/just1k-origin.conf" ]]; then
        node_cleanup_errors+=("Конфигурация just1k-origin.conf все еще существует в Nginx")
    fi
    if [[ -f "${nginx_conf_dir}/sites-available/just1k-fallback80.conf" || -L "${nginx_conf_dir}/sites-enabled/just1k-fallback80.conf" ]]; then
        node_cleanup_errors+=("Конфигурация just1k-fallback80.conf все еще существует в Nginx")
    fi
    if [[ -f "${nginx_conf_dir}/conf.d/xhttp-map.conf" ]]; then
        node_cleanup_errors+=("Конфигурация xhttp-map.conf все еще существует в Nginx")
    fi

    echo ""
    if [[ ${#node_cleanup_errors[@]} -gt 0 ]]; then
        warn "Внимание: удаление just1knode завершено с ошибками (обнаружены остаточные ресурсы)!"
        for err in "${node_cleanup_errors[@]}"; do
            echo -e "  ${RED}• $err${NC}"
        done
        error "Процедура удаления завершилась со статусом FAIL-CLOSED (код 1). Устраните указанные остатки вручную."
        return 1
    fi

    log "✨ just1knode успешно и полностью удален с сервера без остатков (верификация пройдена)."
    exit 0
}

# =============================================================================
# ДИНАМИЧЕСКОЕ КОНТЕКСТНОЕ МЕНЮ (UNIFIED HUB v2)
# =============================================================================
main_menu() {
    check_root
    init_state_dir
    migrate_legacy_state 2>/dev/null || true
    ensure_global_symlink

    local init_status
    init_status="$(get_node_status)"
    if [[ "$init_status" == "unconfigured" && -t 0 && ! -f "${XRAY_API_CONFIG_ENV:-/etc/xray-api/config.env}" ]]; then
        ensure_v2_base_stack_installed || { echo ""; info "Выход из мастера установки."; return 0; }
    fi

    # Однократная best-effort проверка обновлений при входе (не в цикле).
    local _node_update_notice
    _node_update_notice="$(check_node_update_on_entry || true)"

    while true; do
        clear
        echo -e "${BOLD}${BLUE}"
        echo "┌─────────────────────────────────────────────────────────────┐"
        echo "│                 🚀 JUST1KNODE CONTROL PANEL                 │"
        echo "│              Менеджер серверных узлов Just1kBot             │"
        print_node_version_box_line
        echo "└─────────────────────────────────────────────────────────────┘"
        echo -e "${NC}"
        if [[ -n "$_node_update_notice" ]]; then
            echo -e "${_node_update_notice}"
            echo ""
        fi

        local status
        status="$(get_node_status)"

        echo -e "  Роль:   $(role_display_name "$status")"
        echo -e "  Бот:    $(get_bot_connection_label)"
        echo -e "  SSL:    $(get_ssl_header_summary)"
        echo -e "  Трафик: $(get_traffic_limit_summary)"
        echo ""

        if [[ "$status" == "unconfigured" ]]; then
            echo -e "  ${BOLD}[1]${NC} ⚙️  Выберите роль (РУ ХАБ / Зарубежный ХАБ / Выходная НОДА)"
        else
            echo -e "  ${BOLD}[1]${NC} ⚙️  Управление ролью ($(role_display_name "$status"))"
        fi
        echo -e "  ${BOLD}[2]${NC} 🔑 Данные для подключения"
        echo -e "  ${BOLD}[3]${NC} 🤖 Изменить IP Telegram-бота (BOT_IP)"
        echo -e "  ${BOLD}[4]${NC} ⏱️  Лимит трафика хостинга"
        echo -e "  ${BOLD}[5]${NC} 🔄 Проверить обновления (Update & Auto-Heal)"
        echo -e "  ${BOLD}[6]${NC} 🩺 Статус и диагностика (Doctor)"
        echo -e "  ${BOLD}[7]${NC} 🗑️  Полное удаление без остатков (Uninstall)"
        echo -e "  ${BOLD}[R]${NC} ⚠️  Сбросить настройки узла (Reset)"
        echo -e "  ${BOLD}[0]${NC} ❌ Выход"
        echo ""
        local choice=""
        read -rp "Выберите действие: " choice || true

        case "$choice" in
            1)
                case "$status" in
                    ru_hub) ru_hub_menu || true ;;
                    eu_hub) eu_hub_menu || true ;;
                    exit_node) exit_node_menu || true ;;
                    *) select_role_wizard || true; read -rp "Нажмите Enter для продолжения..." || true ;;
                esac
                ;;
            2)
                show_v2_connection_card || true
                read -rp "Нажмите Enter для продолжения..." || true
                ;;
            3)
                set_origin_bot_ip || true
                read -rp "Нажмите Enter для продолжения..." || true
                ;;
            4)
                manage_traffic_limit_menu || true
                read -rp "Нажмите Enter для продолжения..." || true
                ;;
            5)
                update_node "all" "1" || true
                read -rp "Нажмите Enter для продолжения..." || true
                ;;
            6)
                show_status || true
                echo ""
                run_doctor || true
                read -rp "Нажмите Enter для продолжения..." || true
                ;;
            7)
                uninstall_node || true
                read -rp "Нажмите Enter для продолжения..." || true
                ;;
            r|R)
                reset_node || true
                read -rp "Нажмите Enter для продолжения..." || true
                ;;
            0)
                echo -e "\n${GREEN}До свидания!${NC}\n"
                exit 0
                ;;
            *)
                warn "Неверный выбор."
                sleep 1
                ;;
        esac
    done
}

heal_node_config() {
    cleanup_legacy_traffic_watchdog_residue
    migrate_legacy_state 2>/dev/null || true
    local role
    role="$(get_state_val "role")"
    if [[ "$role" == "ru_hub" || "$role" == "eu_hub" || "$role" == "exit_node" ]]; then
        heal_v2_role_config
    else
        error "Узел не настроен. Запустите 'just1knode role select' для выбора роли."
        return 1
    fi
}

# --- Точка входа CLI ---
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" || -z "${BASH_SOURCE[0]:-}" ]]; then
    if [[ $# -eq 0 ]]; then
        main_menu
    else
        case "$1" in
            base-install|bootstrap-v2)
                ensure_v2_base_stack_installed
                ;;
            role)
                case "${2:-}" in
                    select|choose|set) select_role_wizard ;;
                    change|reset) change_role_guarded ;;
                    *)
                        case "$(get_state_val "role" "unconfigured")" in
                            ru_hub) ru_hub_menu ;;
                            eu_hub) eu_hub_menu ;;
                            exit_node) exit_node_menu ;;
                            *) select_role_wizard ;;
                        esac
                        ;;
                esac
                ;;
            ru-hub|ru_hub) ru_hub_menu ;;
            eu-hub|eu_hub) eu_hub_menu ;;
            exit-node|exit_node) exit_node_menu ;;
            vless-tls)
                case "${2:-install}" in
                    install|setup) vless_tls_install "${3:-}" ;;
                    uninstall|remove|del) vless_tls_uninstall ;;
                    *) error "Использование: just1knode vless-tls [install|uninstall]" ;;
                esac
                ;;
            vless-xhttp)
                case "${2:-install}" in
                    install|setup) vless_xhttp_install "${3:-}" "${4:-}" ;;
                    uninstall|remove|del) vless_xhttp_uninstall ;;
                    *) error "Использование: just1knode vless-xhttp [install|uninstall]" ;;
                esac
                ;;
            yandex-cdn)
                case "${2:-install}" in
                    install|setup) cdn_module_install "cdn_yandex" ;;
                    uninstall|remove|del) cdn_module_uninstall "cdn_yandex" ;;
                    *) error "Использование: just1knode yandex-cdn [install|uninstall]" ;;
                esac
                ;;
            turboflare)
                case "${2:-install}" in
                    install|setup) cdn_module_install "cdn_turboflare" ;;
                    uninstall|remove|del) cdn_module_uninstall "cdn_turboflare" ;;
                    *) error "Использование: just1knode turboflare [install|uninstall]" ;;
                esac
                ;;
            module)
                _m_id="${2:-}"
                _m_act="${3:-install}"
                if [[ -z "$_m_id" ]]; then
                    error "Использование: just1knode module <id> [install|uninstall]"
                    exit 1
                fi
                if [[ "$_m_id" == cdn_* ]]; then
                    case "$_m_act" in
                        install|setup) cdn_module_install "$_m_id" ;;
                        uninstall|remove|del) cdn_module_uninstall "$_m_id" ;;
                        *) error "Использование: just1knode module $_m_id [install|uninstall]" ;;
                    esac
                else
                    case "$_m_act" in
                        install|setup)
                            declare -F "${_m_id}_install" >/dev/null 2>&1 && "${_m_id}_install" || { error "Модуль '$_m_id' не поддерживает установку."; exit 1; }
                            ;;
                        uninstall|remove|del)
                            declare -F "${_m_id}_uninstall" >/dev/null 2>&1 && "${_m_id}_uninstall" || { error "Модуль '$_m_id' не поддерживает удаление."; exit 1; }
                            ;;
                        *) error "Использование: just1knode module $_m_id [install|uninstall]" ;;
                    esac
                fi
                unset _m_id _m_act
                ;;
            creds|credentials)
                show_v2_connection_card
                ;;
            apply-pending|apply-links)
                check_root
                apply_pending_node_updates
                ;;
            backup)
                backup_node "${2:-}"
                ;;
            restore)
                restore_node "${2:-}"
                ;;
            limit|traffic)
                case "${2:-}" in
                    set|reset-day|day|disable|off|check|"") check_root; init_state_dir ;;
                esac
                case "${2:-}" in
                    set) set_traffic_limit "${3:-}" "${4:-}" ;;
                    reset-day|day) set_traffic_reset_day "${3:-1}" ;;
                    disable|off) disable_traffic_limit ;;
                    check) check_traffic_limit ;;
                    status|show) show_traffic_limit_status ;;
                    "") manage_traffic_limit_menu ;;
                    *) error "Использование: just1knode limit [set <GB> [day] | off | status]" ;;
                esac
                ;;
            status) show_status ;;
            doctor|test) run_doctor || exit 1 ;;
            heal) heal_node_config ;;
            set-bot-ip|bot-ip)
                set_origin_bot_ip "${2:-}"
                ;;
            anti-abuse|antiabuse|apply-abuse-protection)
                check_root
                apply_antiabuse_protection
                ;;
            remove-anti-abuse|remove-antiabuse|disable-anti-abuse)
                check_root
                remove_antiabuse_protection
                ;;
            update-post)
                check_root
                shift
                update_node_post "${1:-all}" "${2:-0}"
                ;;
            update)
                case "${2:-}" in
                    core|xray) shift 2; update_xray_core "$@" ;;
                    config|heal) heal_node_config ;;
                    *) update_node "${2:-all}" ;;
                esac
                ;;
            reset) reset_node ;;
            uninstall|remove|purge)
                shift
                uninstall_node "$@"
                ;;
            *) error "Неизвестная команда: $1. Запустите 'just1knode' без аргументов для входа в меню." ;;
        esac
    fi
fi
