#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE v2 - Транспортный модуль VLESS TLS (Vision, порт 443)
# =============================================================================

vless_tls_status_label() {
    if is_module_enabled "vless_tls"; then
        echo -e "${GREEN}🟢 Установлен (порт 443)${NC}"
    else
        echo -e "${YELLOW}⚪ Не установлен${NC}"
    fi
}

vless_tls_install() {
    check_root
    init_state_dir
    local role domain
    role="$(get_state_val "role" "unconfigured")"
    if [[ "$role" != "ru_hub" && "$role" != "exit_node" ]]; then
        warn "Модуль VLESS TLS доступен только для ролей 'РУ ХАБ' и 'Выходная НОДА'."
        return 1
    fi

    domain="$(get_state_val "domain" "")"
    if [[ -z "$domain" || "$domain" == "-" ]]; then
        warn "Домен сервера не задан. Настройте роль и домен повторно."
        return 1
    fi

    if ! ensure_domain_ssl_auto "$domain" "vless"; then
        return 1
    fi

    local prev_has_v prev_vdom prev_had_mod
    prev_has_v="$(get_state_val "has_vless" "0")"
    prev_vdom="$(get_state_val "vless_domain" "")"
    prev_had_mod="0"
    is_module_enabled "vless_tls" && prev_had_mod="1"

    local mod_json
    mod_json="$(python3 -c 'import json,sys; print(json.dumps({"enabled": True, "port": 443, "tag": "just1k-vless-direct", "domain": sys.argv[1]}))' "$domain")"
    set_module_config "vless_tls" "$mod_json"
    set_state_val "has_vless" "1"
    set_state_val "vless_domain" "$domain"
    set_state_val "vless_port" "443"

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        ufw allow 443/tcp comment "just1knode vless direct" >/dev/null 2>&1 || true
    fi

    if ! apply_v2_hub_configuration; then
        if [[ "$prev_had_mod" == "0" ]]; then
            remove_module_config "vless_tls"
        fi
        set_state_val "has_vless" "$prev_has_v"
        set_state_val "vless_domain" "$prev_vdom"
        warn "Не удалось применить конфигурацию VLESS TLS. Изменения откатаны."
        return 1
    fi

    log "✔ Модуль VLESS TLS (443) успешно установлен и активирован."
    return 0
}

vless_tls_uninstall() {
    check_root
    init_state_dir
    if ! is_module_enabled "vless_tls"; then
        info "Модуль VLESS TLS не установлен."
        return 0
    fi

    local prev_json
    prev_json="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        print(json.dumps(json.load(f).get("modules", {}).get("vless_tls", {})))
except Exception:
    print("{}")
' "$STATE_FILE" 2>/dev/null || echo "{}")"

    remove_module_config "vless_tls"
    set_state_val "has_vless" "0"

    if ! apply_v2_hub_configuration; then
        set_module_config "vless_tls" "$prev_json"
        set_state_val "has_vless" "1"
        warn "Ошибка пересборки конфигурации после отключения VLESS TLS. Откат."
        return 1
    fi

    if ! is_module_enabled "vless_xhttp"; then
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
            if ! is_ssh_port "443"; then
                ufw delete allow 443/tcp >/dev/null 2>&1 || true
                ufw delete allow 443 >/dev/null 2>&1 || true
            fi
        fi
    fi

    log "✔ Модуль VLESS TLS удален (клиенты в clients.json сохранены)."
    return 0
}
