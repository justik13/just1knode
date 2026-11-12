#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE v2 - Базовый транспортный модуль VLESS XHTTP
# =============================================================================

vless_xhttp_meta() {
    cat <<'EOF'
{
  "id": "vless_xhttp",
  "kind": "transport",
  "parent": "",
  "label": "VLESS XHTTP (Базовый)",
  "roles": ["ru_hub"],
  "order": 20
}
EOF
}

vless_xhttp_status_label() {
    if is_module_broken "vless_xhttp"; then
        echo -e "${RED}🔴 Ошибка модуля (изолирован)${NC}"
    elif is_module_enabled "vless_xhttp"; then
        echo -e "${GREEN}🟢 Установлен (Nginx + /sub/ + 404)${NC}"
    else
        echo -e "${YELLOW}⚪ Не установлен${NC}"
    fi
}

vless_xhttp_has_child_cdns() {
    is_any_child_module_enabled "vless_xhttp"
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
        secret_path="/assets_$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
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

    local prev_json prev_had_mod
    prev_had_mod="0"
    is_module_enabled "vless_xhttp" && prev_had_mod="1"
    prev_json="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        print(json.dumps(json.load(f).get("modules", {}).get("vless_xhttp", {})))
except Exception:
    print("{}")
' "$STATE_FILE" 2>/dev/null || echo "{}")"

    local mod_json
    mod_json="$(python3 -c 'import json,sys; print(json.dumps({"enabled": True, "bot_domain": sys.argv[1], "sub_path_prefix": sys.argv[2]}))' "$input_bot_dom" "$sub_prefix")"
    set_module_config "vless_xhttp" "$mod_json"
    [[ -n "$input_bot_dom" ]] && set_state_val "bot_domain" "$input_bot_dom"
    set_state_val "sub_path_prefix" "$sub_prefix"

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        ufw allow 443/tcp comment "just1knode hub ingress" >/dev/null 2>&1 || true
    fi

    if ! apply_v2_hub_configuration; then
        if [[ "$prev_had_mod" == "1" ]]; then
            set_module_config "vless_xhttp" "$prev_json"
        else
            remove_module_config "vless_xhttp"
        fi
        warn "Не удалось применить базовый модуль VLESS XHTTP. Выполнен откат."
        return 1
    fi

    log "✔ Базовый модуль VLESS XHTTP установлен! Теперь доступны дочерние CDN-модули."
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
        warn "Невозможно удалить VLESS XHTTP (Базовый), пока активны дочерние CDN-модули!"
        echo -e "  ${YELLOW}Сначала удалите активные дочерние CDN-модули.${NC}"
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

    if ! apply_v2_hub_configuration; then
        set_module_config "vless_xhttp" "$prev_json"
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
