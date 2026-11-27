#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE v2 - Базовый жизненный цикл ролей и применение обновлений
# =============================================================================

ensure_xray_stub_config() {
    local cfg="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
    local cfg_dir
    cfg_dir="$(dirname "$cfg")"
    mkdir -p "$cfg_dir"
    if [[ ! -f "$cfg" || ! -s "$cfg" ]]; then
        cat > "$cfg" <<'EOF'
{
  "log": {
    "loglevel": "warning"
  },
  "stats": {},
  "api": {
    "tag": "api",
    "services": [
      "HandlerService",
      "StatsService"
    ]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true
    }
  },
  "inbounds": [
    {
      "tag": "just1k-wl-api-grpc",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "just1k-wl-block",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "just1k-wl-api-grpc"
        ],
        "outboundTag": "api"
      }
    ]
  }
}
EOF
    fi
    ensure_xray_config_permissions "$cfg"
}

ensure_api_ssl_cert() {
    local domain cert_path key_path
    domain="$(get_state_val "domain" "")"

    if [[ -n "$domain" && "$domain" != "-" ]]; then
        local le_cert="${LETSENCRYPT_DIR:-/etc/letsencrypt}/live/${domain}/fullchain.pem"
        local le_key="${LETSENCRYPT_DIR:-/etc/letsencrypt}/live/${domain}/privkey.pem"
        if [[ -f "$le_cert" && -f "$le_key" ]]; then
            echo "${le_cert}|${le_key}"
            return 0
        fi
    fi

    local ssl_dir="${NGINX_CONF_DIR:-/etc/nginx}/fallback_ssl"
    cert_path="${ssl_dir}/api_selfsigned.crt"
    key_path="${ssl_dir}/api_selfsigned.key"
    mkdir -p "$ssl_dir"
    if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -keyout "$key_path" -out "$cert_path" \
            -subj "/CN=just1knode-api" >/dev/null 2>&1 || return 1
        chmod 644 "$cert_path" 2>/dev/null || true
        chmod 600 "$key_path" 2>/dev/null || true
    fi
    echo "${cert_path}|${key_path}"
    return 0
}

setup_base_api_nginx() {
    install_nginx_if_missing
    local nginx_dir="${NGINX_CONF_DIR:-/etc/nginx}"
    local avail="${nginx_dir}/sites-available/just1k-vless-api.conf"
    local enabled="${nginx_dir}/sites-enabled/just1k-vless-api.conf"
    mkdir -p "${nginx_dir}/sites-available" "${nginx_dir}/sites-enabled"

    local ssl_pair cert_path key_path
    ssl_pair="$(ensure_api_ssl_cert)" || return 1
    cert_path="${ssl_pair%%|*}"
    key_path="${ssl_pair#*|}"

    local server_name="_"
    local domain
    domain="$(get_state_val "domain" "")"
    [[ -n "$domain" && "$domain" != "-" ]] && server_name="${domain} _"

    local tmp_conf
    tmp_conf="$(mktemp "${avail}.XXXXXX" 2>/dev/null || mktemp)"
    cat > "$tmp_conf" <<EOF
server {
    listen 8444 ssl;
    server_name ${server_name};

    ssl_certificate ${cert_path};
    ssl_certificate_key ${key_path};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    server_tokens off;

    location / {
        proxy_pass http://127.0.0.1:5001;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
    }
}
EOF
    chmod 644 "$tmp_conf" 2>/dev/null || true
    mv -f "$tmp_conf" "$avail"
    ln -sf "$avail" "$enabled"

    if ! nginx -t >/dev/null 2>&1; then
        warn "Nginx: синтаксическая ошибка при настройке API (порт 8444)."
        return 1
    fi
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    return 0
}

deploy_v2_fallback80_nginx() {
    install_nginx_if_missing
    local nginx_dir="${NGINX_CONF_DIR:-/etc/nginx}"
    local avail="${nginx_dir}/sites-available/just1k-fallback80.conf"
    local enabled="${nginx_dir}/sites-enabled/just1k-fallback80.conf"
    mkdir -p "${nginx_dir}/sites-available" "${nginx_dir}/sites-enabled"

    if [[ -L "${nginx_dir}/sites-enabled/default" || -f "${nginx_dir}/sites-enabled/default" ]]; then
        if [[ -f "${nginx_dir}/sites-available/default" && ! -f "${nginx_dir}/sites-available/default.user.bak" ]]; then
            cp -a "${nginx_dir}/sites-available/default" "${nginx_dir}/sites-available/default.user.bak" 2>/dev/null || true
        fi
        rm -f "${nginx_dir}/sites-enabled/default" 2>/dev/null || true
    fi

    cat > "$avail" <<'EOF'
server {
    listen 127.0.0.1:80 default_server;
    server_name _;
    server_tokens off;

    location / {
        return 404 "Not Found\n";
    }
}
EOF
    chmod 644 "$avail" 2>/dev/null || true
    ln -sf "$avail" "$enabled"
    return 0
}

_sync_all_role_certs() {
    local domain
    domain="$(get_state_val "domain" "")"
    if [[ -n "$domain" && "$domain" != "-" ]]; then
        sync_xray_tls_cert_files "$domain" 2>/dev/null || true
    fi
    deploy_certbot_renewal_hook 2>/dev/null || true
}

apply_v2_hub_configuration() {
    local role
    role="$(get_state_val "role" "unconfigured")"
    [[ "$role" == "ru_hub" || "$role" == "eu_hub" || "$role" == "exit_node" ]] || return 1

    local state_dir="${STATE_DIR:-/etc/just1knode}"
    local xray_cfg="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
    local applied_hash_file="${state_dir}/.applied_xray_hash"
    local applied_hash=""
    if [[ -f "$applied_hash_file" && ! -L "$applied_hash_file" ]]; then
        applied_hash="$(tr -d '[:space:]' < "$applied_hash_file" 2>/dev/null || true)"
    fi

    apply_node_sysctl_hardening
    _sync_all_role_certs
    if ! assemble_v2_hub_config; then
        return 1
    fi

    local xray_cfg_hash_after=""
    if [[ -f "$xray_cfg" ]]; then
        xray_cfg_hash_after="$(sha256sum "$xray_cfg" 2>/dev/null | awk '{print $1}')"
    fi

    if ! nginx -t >/dev/null 2>&1; then
        nginx -t || true
        warn "Ошибка синтаксиса Nginx при применении конфигурации роли ${role}."
        return 1
    fi

    if declare -F ensure_nginx_nofile_limits >/dev/null 2>&1; then
        ensure_nginx_nofile_limits
    fi
    if [[ "${NGINX_NEEDS_NOFILE_RESTART:-0}" == "1" ]]; then
        systemctl restart nginx 2>/dev/null || systemctl reload nginx 2>/dev/null || true
    else
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    fi
    deploy_xray_systemd_service

    if is_traffic_limit_exceeded; then
        warn "Лимит трафика исчерпан — запуск Xray пропущен (конфигурация обновлена)."
    elif [[ -n "$applied_hash" && -n "$xray_cfg_hash_after" && "$applied_hash" == "$xray_cfg_hash_after" ]] && systemctl is-active --quiet xray; then
        ensure_xray_api_healthy 1 || warn "Служба xray-api не ответила вовремя."
        ping_xray_api_health
    else
        if ! systemctl restart xray || ! systemctl is-active --quiet xray; then
            warn "Не удалось перезапустить службу Xray с новой конфигурацией!"
            return 1
        fi
        if [[ -n "$xray_cfg_hash_after" ]]; then
            if [[ -L "$applied_hash_file" ]]; then
                warn "Обнаружен неожиданный symlink ${applied_hash_file} — удаление."
                rm -f "$applied_hash_file" 2>/dev/null || true
            fi
            local tmp_hash
            tmp_hash="$(mktemp "${state_dir}/.applied_xray_hash.XXXXXX" 2>/dev/null || true)"
            if [[ -n "$tmp_hash" ]]; then
                printf '%s\n' "$xray_cfg_hash_after" > "$tmp_hash" 2>/dev/null || true
                chmod 644 "$tmp_hash" 2>/dev/null || true
                mv -f "$tmp_hash" "$applied_hash_file" 2>/dev/null || rm -f "$tmp_hash" 2>/dev/null || true
            fi
        fi
        ensure_xray_api_healthy 1 || warn "Служба xray-api не ответила вовремя."
        ping_xray_api_health
    fi

    if [[ "$role" == "exit_node" || "$role" == "ru_hub" || "$(get_state_val "abuse_protection" "disabled")" == "enabled" ]]; then
        apply_antiabuse_protection >/dev/null 2>&1 || true
    fi

    if declare -F deploy_geodata_update_timer >/dev/null 2>&1; then
        deploy_geodata_update_timer "$role" || true
    fi

    heal_node_firewall_and_stealth
    return 0
}

heal_v2_role_config() {
    local role
    role="$(get_state_val "role" "unconfigured")"
    if [[ "$role" != "ru_hub" && "$role" != "eu_hub" && "$role" != "exit_node" ]]; then
        return 0
    fi
    if ! apply_v2_hub_configuration; then
        warn "Авто-восстановление конфигурации для роли ${role} завершилось с предупреждением."
        return 1
    fi
    return 0
}

apply_pending_node_updates() {
    check_root
    init_state_dir
    if declare -F acquire_just1knode_lock >/dev/null 2>&1; then
        acquire_just1knode_lock
    fi

    local state_dir="${STATE_DIR:-/etc/just1knode}"
    local pending_file="${APPLY_PENDING_PATH:-${state_dir}/.apply_pending}"
    local running_file="${state_dir}/.apply_running"
    local result_file="${state_dir}/last_apply.json"

    local rc=0
    local role="unconfigured"
    local max_passes=3
    local pass=0

    while [[ $pass -lt $max_passes ]]; do
        pass=$((pass + 1))
        if [[ -f "$pending_file" ]]; then
            mv -f "$pending_file" "$running_file" 2>/dev/null || true
        fi

        rc=0
        role="$(get_state_val "role" "unconfigured")"
        if [[ "$role" == "ru_hub" || "$role" == "eu_hub" || "$role" == "exit_node" ]]; then
            apply_v2_hub_configuration || rc=$?
        else
            _sync_all_role_certs
            setup_base_api_nginx || rc=$?
            heal_node_firewall_and_stealth || true
        fi

        rm -f "$running_file" 2>/dev/null || true
        [[ "$rc" -eq 0 && -f "$pending_file" ]] || break
    done

    if declare -F release_just1knode_lock >/dev/null 2>&1; then
        release_just1knode_lock 2>/dev/null || true
    fi

    python3 - "$result_file" "$rc" "$role" <<'PYEOF' 2>/dev/null || true
import json, os, sys, tempfile, time
out_path, rc_str, role = sys.argv[1:4]
d = os.path.dirname(os.path.abspath(out_path))
os.makedirs(d, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump({"ok": rc_str == "0", "rc": int(rc_str), "role": role, "ts": int(time.time())}, f, indent=2)
    f.flush()
os.chmod(tmp, 0o644)
os.replace(tmp, out_path)
PYEOF
    return "$rc"
}

role_display_name() {
    local r="${1:-unconfigured}"
    case "$r" in
        ru_hub) echo "🇷🇺 РУ ХАБ" ;;
        eu_hub) echo "🌍 Зарубежный ХАБ" ;;
        exit_node) echo "🚀 Выходная НОДА" ;;
        *) echo "⚪ Не выбрана" ;;
    esac
}

change_role_guarded() {
    check_root
    init_state_dir
    local mod_cnt
    mod_cnt="$(count_enabled_modules)"
    if [[ "${mod_cnt:-0}" -gt 0 ]]; then
        warn "Смена роли запрещена: установлено модулей — ${mod_cnt}."
        echo -e "  ${YELLOW}Удалите все модули перед сменой роли.${NC}"
        return 1
    fi

    local cur_role
    cur_role="$(get_state_val "role" "unconfigured")"
    if [[ "$cur_role" == "unconfigured" ]]; then
        select_role_wizard
        return $?
    fi

    local confirm=""
    read -rp "Сбросить текущую роль '$(role_display_name "$cur_role")' и выбрать новую? [y/N]: " confirm || true
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Смена роли отменена."
        return 0
    fi

    set_state_val "role" "unconfigured"
    set_state_json_val "allowed_ru_ips" "[]"
    save_links_json "{}"
    rm -f "${NGINX_CONF_DIR:-/etc/nginx}/sites-enabled/just1k-ru-hub.conf" \
          "${NGINX_CONF_DIR:-/etc/nginx}/sites-available/just1k-ru-hub.conf" \
          "${NGINX_CONF_DIR:-/etc/nginx}/sites-enabled/just1k-origin.conf" \
          "${NGINX_CONF_DIR:-/etc/nginx}/sites-available/just1k-origin.conf" \
          "${NGINX_CONF_DIR:-/etc/nginx}/sites-enabled/just1k-fallback80.conf" \
          "${NGINX_CONF_DIR:-/etc/nginx}/conf.d/xhttp-map.conf" \
          "${NGINX_CONF_DIR:-/etc/nginx}/just1k-stream443.conf" 2>/dev/null || true
    rm -f "${XRAY_CONFIG:-/usr/local/etc/xray/config.json}" 2>/dev/null || true
    ensure_xray_stub_config
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || true
        if ! is_traffic_limit_exceeded; then
            systemctl restart xray 2>/dev/null || true
        fi
    fi
    heal_node_firewall_and_stealth
    log "✔ Роль сброшена. Выберите новую роль сервера."
    select_role_wizard
    return $?
}

select_role_wizard() {
    check_root
    init_state_dir

    local new_role="${JUST1KNODE_ROLE:-}"
    local input_dom="${JUST1KNODE_DOMAIN:-}"

    if [[ -n "$new_role" && -n "$input_dom" ]]; then
        case "$new_role" in
            ru_hub|eu_hub|exit_node) ;;
            *) warn "Недопустимая роль в JUST1KNODE_ROLE: '$new_role'. Допустимы: ru_hub, eu_hub, exit_node."; return 1 ;;
        esac
        input_dom="$(normalize_domain "$input_dom" 2>/dev/null || echo "$input_dom")"
        if ! validate_fqdn "$input_dom" 2>/dev/null; then
            warn "Некорректный домен в JUST1KNODE_DOMAIN: '$input_dom'."
            return 1
        fi
    else
        while true; do
            clear
            title "ВЫБОР РОЛИ СЕРВЕРА JUST1KNODE v2"
            echo -e "  ${BOLD}[1]${NC} 🇷🇺 ${BOLD}РУ ХАБ${NC}           — входной узел (VLESS TLS / VLESS XHTTP + CDN + мост в ЕС)"
            echo -e "  ${BOLD}[2]${NC} 🌍 ${BOLD}Зарубежный ХАБ${NC}  — чистый транзитный мост (443 от РУ ХАБов -> Выходные НОДЫ)"
            echo -e "  ${BOLD}[3]${NC} 🚀 ${BOLD}Выходная НОДА${NC}   — финальный выход (443 от хабов -> Freedom + Anti-Abuse)"
            echo ""

            local r_choice=""
            read -rp "Выберите роль [1-3]: " r_choice || true
            case "$r_choice" in
                1) new_role="ru_hub"; break ;;
                2) new_role="eu_hub"; break ;;
                3) new_role="exit_node"; break ;;
                *) warn "Выбор роли обязателен. Сервер не может функционировать без роли." ;;
            esac
        done

        local cur_dom
        cur_dom="$(get_state_val "domain" "")"
        [[ "$cur_dom" == "-" ]] && cur_dom=""
        while true; do
            if [[ -n "$cur_dom" ]]; then
                read -rp "Домен [Enter для '$cur_dom']: " input_dom || true
                input_dom="${input_dom:-$cur_dom}"
            else
                read -rp "Домен (FQDN): " input_dom || true
            fi
            input_dom="$(normalize_domain "$input_dom" 2>/dev/null || echo "$input_dom")"
            if [[ -n "$input_dom" ]] && validate_fqdn "$input_dom" 2>/dev/null; then
                break
            fi
            warn "Введите корректное доменное имя (например, assets.example.com)."
        done
    fi

    echo ""
    echo -e "  Роль:  ${CYAN}$(role_display_name "$new_role")${NC}"
    echo -e "  Домен: ${CYAN}${input_dom}${NC}"
    echo -e "  SSL:   ${DIM:-}Let's Encrypt (автоматический выпуск сертификата для домена)${NC}"
    echo ""
    local confirm=""
    read -rp "Подтвердите (y/n): " confirm || true
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Настройка роли отменена."
        return 1
    fi

    if ! ensure_domain_ssl_auto "$input_dom"; then
        warn "Не удалось подготовить TLS-сертификат для '${input_dom}'."
        return 1
    fi

    set_state_val "role" "$new_role"
    set_state_val "domain" "$input_dom"
    set_state_val "api_url" "https://${input_dom}:8444"
    set_state_json_val "modules" "{}"
    save_links_json "{}"

    if [[ "$new_role" == "eu_hub" || "$new_role" == "exit_node" ]]; then
        local t_uuid
        t_uuid="$(get_state_val "tunnel_uuid" "")"
        if [[ -z "$t_uuid" || "$t_uuid" == "-" ]]; then
            t_uuid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
            set_state_val "tunnel_uuid" "$t_uuid"
        fi
    fi

    if [[ "$new_role" == "ru_hub" ]]; then
        setup_base_api_nginx || true
        heal_node_firewall_and_stealth
        log "✔ Роль 'РУ ХАБ' активирована! Выберите транспортные модули."
        ru_hub_menu
    elif [[ "$new_role" == "eu_hub" ]]; then
        set_state_val "relay_port" "443"
        if ! apply_v2_hub_configuration; then
            warn "Ошибка активации Зарубежного ХАБа."
            return 1
        fi
        log "✔ Роль 'Зарубежный ХАБ' активирована!"
        eu_hub_menu
    elif [[ "$new_role" == "exit_node" ]]; then
        if ! apply_v2_hub_configuration; then
            warn "Ошибка активации Выходной НОДы."
            return 1
        fi
        log "✔ Роль 'Выходная НОДА' активирована!"
        exit_node_menu
    fi
    return 0
}
