#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE v2 - Транспортный модуль VLESS XHTTP и реестр CDN-провайдеров
# =============================================================================

vless_xhttp_status_label() {
    if is_module_enabled "vless_xhttp"; then
        echo -e "${GREEN}🟢 Установлен (Nginx + /sub/ + 404)${NC}"
    else
        echo -e "${YELLOW}⚪ Не установлен${NC}"
    fi
}

cdn_module_status_label() {
    local mod_key="$1"
    if is_module_enabled "$mod_key"; then
        local c_dom
        c_dom="$(get_module_val "$mod_key" "cdn_domain" "")"
        [[ -n "$c_dom" ]] && echo -e "${GREEN}🟢 Активен (${c_dom})${NC}" || echo -e "${GREEN}🟢 Активен${NC}"
    else
        echo -e "${YELLOW}⚪ Не установлен${NC}"
    fi
}

vless_xhttp_has_child_cdns() {
    if is_module_enabled "cdn_yandex" || is_module_enabled "cdn_turboflare"; then
        return 0
    fi
    return 1
}

vless_xhttp_install() {
    check_root
    init_state_dir
    local role domain
    role="$(get_state_val "role" "unconfigured")"
    if [[ "$role" != "ru_hub" ]]; then
        warn "Модуль VLESS XHTTP доступен только для роли 'РУ ХАБ'."
        return 1
    fi

    domain="$(get_state_val "domain" "")"
    if [[ -z "$domain" || "$domain" == "-" ]]; then
        warn "Домен сервера не задан."
        return 1
    fi

    if ! ensure_domain_ssl_auto "$domain"; then
        return 1
    fi

    local secret_path
    secret_path="$(get_state_val "secret_base_path" "")"
    if [[ -z "$secret_path" || "$secret_path" == "-" ]]; then
        secret_path="/w_$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
        set_state_val "secret_base_path" "$secret_path"
    fi

    local cur_bot_dom input_bot_dom=""
    cur_bot_dom="$(get_state_val "bot_domain" "")"
    [[ "$cur_bot_dom" == "-" ]] && cur_bot_dom=""
    if [[ -t 0 ]]; then
        echo -e "${DIM:-}Опционально: домен Telegram-бота для проксирования /sub/ (Enter чтобы пропустить):${NC}"
        read -rp "Домен бота [${cur_bot_dom:-нет}]: " input_bot_dom || true
        input_bot_dom="${input_bot_dom:-$cur_bot_dom}"
        input_bot_dom="$(normalize_domain "$input_bot_dom" 2>/dev/null || echo "$input_bot_dom")"
    else
        input_bot_dom="$cur_bot_dom"
    fi

    if [[ -n "$input_bot_dom" ]]; then
        if ! validate_fqdn "$input_bot_dom" 2>/dev/null; then
            warn "Некорректный формат домена бота '$input_bot_dom'. Проксирование /sub/ пропущено."
            input_bot_dom=""
        fi
    fi

    local sub_prefix
    sub_prefix="$(get_state_val "sub_path_prefix" "/sub/wl")"
    [[ -z "$sub_prefix" || "$sub_prefix" == "-" ]] && sub_prefix="/sub/wl"

    local mod_json
    mod_json="$(python3 -c 'import json,sys; print(json.dumps({"enabled": True, "bot_domain": sys.argv[1], "sub_path_prefix": sys.argv[2]}))' "$input_bot_dom" "$sub_prefix")"
    set_module_config "vless_xhttp" "$mod_json"
    set_state_val "has_wl" "1"
    [[ -n "$input_bot_dom" ]] && set_state_val "bot_domain" "$input_bot_dom"
    set_state_val "sub_path_prefix" "$sub_prefix"

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        ufw allow 443/tcp comment "just1knode hub ingress" >/dev/null 2>&1 || true
    fi

    if ! apply_v2_hub_configuration; then
        remove_module_config "vless_xhttp"
        set_state_val "has_wl" "0"
        warn "Не удалось применить базовый модуль VLESS XHTTP. Выполнен откат."
        return 1
    fi

    log "✔ Базовый модуль VLESS XHTTP установлен! Теперь доступны субмодули [2.1] и [2.2]."
    return 0
}

vless_xhttp_uninstall() {
    check_root
    init_state_dir
    if ! is_module_enabled "vless_xhttp"; then
        info "Базовый модуль VLESS XHTTP не установлен."
        return 0
    fi

    if vless_xhttp_has_child_cdns; then
        warn "Невозможно удалить VLESS XHTTP (Базовый), пока активны дочерние CDN-модули (Yandex CDN / TurboFlare)!"
        echo -e "  ${YELLOW}Сначала удалите [2.1] Yandex CDN и/или [2.2] TurboFlare.${NC}"
        return 1
    fi

    local prev_json
    prev_json="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        print(json.dumps(json.load(f).get("modules", {}).get("vless_xhttp", {})))
except Exception:
    print("{}")
' "$STATE_FILE" 2>/dev/null || echo "{}")"

    remove_module_config "vless_xhttp"
    set_state_val "has_wl" "0"

    if ! apply_v2_hub_configuration; then
        set_module_config "vless_xhttp" "$prev_json"
        set_state_val "has_wl" "1"
        warn "Ошибка пересборки после удаления VLESS XHTTP. Откат."
        return 1
    fi

    if ! is_module_enabled "vless_tls"; then
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
            if ! is_ssh_port "443"; then
                ufw delete allow 443/tcp >/dev/null 2>&1 || true
                ufw delete allow 443 >/dev/null 2>&1 || true
            fi
        fi
    fi

    log "✔ Базовый модуль VLESS XHTTP удален."
    return 0
}

# Единый обработчик установки CDN-субмодулей (без дублирования по провайдерам)
cdn_provider_install() {
    local mod_key="$1"
    check_root
    init_state_dir

    if ! is_module_enabled "vless_xhttp"; then
        warn "Сначала установите [2] VLESS XHTTP (Базовый)!"
        return 1
    fi

    local label port tag def_cdn_dom input_cdn_dom=""
    case "$mod_key" in
        cdn_yandex)
            label="Yandex CDN"
            port="8003"
            tag="just1k-wl-default"
            ;;
        cdn_turboflare)
            label="TurboFlare"
            port="8004"
            tag="just1k-wl-turboflare"
            ;;
        *)
            warn "Неизвестный CDN-модуль: $mod_key"
            return 1
            ;;
    esac

    def_cdn_dom="$(get_module_val "$mod_key" "cdn_domain" "")"
    [[ -z "$def_cdn_dom" ]] && def_cdn_dom="$(get_state_val "cdn_domain" "")"
    [[ -z "$def_cdn_dom" || "$def_cdn_dom" == "-" ]] && def_cdn_dom="$(get_state_val "domain" "")"

    if [[ -t 0 ]]; then
        read -rp "CDN-домен для ${label} [по умолчанию: ${def_cdn_dom}]: " input_cdn_dom || true
        input_cdn_dom="${input_cdn_dom:-$def_cdn_dom}"
        input_cdn_dom="$(normalize_domain "$input_cdn_dom" 2>/dev/null || echo "$input_cdn_dom")"
    else
        input_cdn_dom="$def_cdn_dom"
    fi

    if [[ -z "$input_cdn_dom" ]] || ! validate_fqdn "$input_cdn_dom" 2>/dev/null; then
        warn "Укажите корректный FQDN домен для ${label}."
        return 1
    fi

    local mod_json
    mod_json="$(python3 -c 'import json,sys; print(json.dumps({"enabled": True, "provider": sys.argv[1], "port": int(sys.argv[2]), "tag": sys.argv[3], "cdn_domain": sys.argv[4]}))' "$mod_key" "$port" "$tag" "$input_cdn_dom")"
    set_module_config "$mod_key" "$mod_json"

    # Обновляем корневой cdn_domain, если это Yandex CDN или cdn_domain еще не был задан
    local cur_root_cdn
    cur_root_cdn="$(get_state_val "cdn_domain" "")"
    if [[ "$mod_key" == "cdn_yandex" || -z "$cur_root_cdn" || "$cur_root_cdn" == "-" ]]; then
        set_state_val "cdn_domain" "$input_cdn_dom"
    fi

    if ! apply_v2_hub_configuration; then
        remove_module_config "$mod_key"
        warn "Не удалось применить конфигурацию ${label}. Откат выполнен."
        return 1
    fi

    log "✔ Субмодуль ${label} (порт ${port}) успешно активирован."
    return 0
}

cdn_provider_uninstall() {
    local mod_key="$1"
    check_root
    init_state_dir
    if ! is_module_enabled "$mod_key"; then
        info "Субмодуль ${mod_key} не установлен."
        return 0
    fi

    local prev_json
    prev_json="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        print(json.dumps(json.load(f).get("modules", {}).get(sys.argv[2], {})))
except Exception:
    print("{}")
' "$STATE_FILE" "$mod_key" 2>/dev/null || echo "{}")"

    remove_module_config "$mod_key"

    if ! apply_v2_hub_configuration; then
        set_module_config "$mod_key" "$prev_json"
        warn "Ошибка пересборки после удаления ${mod_key}. Откат."
        return 1
    fi

    log "✔ Субмодуль ${mod_key} успешно удален."
    return 0
}
