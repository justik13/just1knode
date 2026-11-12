#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE v2 - Роль 1: 🇷🇺 РУ ХАБ (входной шлюз + транспорты + мост в ЕС)
# =============================================================================

_ru_hub_manage_bridges() {
    while true; do
        clear
        title "МОСТЫ НА ЗАРУБЕЖНЫЕ ХАБЫ (EU_HUB)"
        local my_ip
        my_ip="$(get_public_ipv4 2>/dev/null || echo "<IP_РУ_ХАБА>")"
        echo -e "  ${DIM:-}На Зарубежном ХАБе обязательно разрешите входящий доступ от IP этого РУ ХАБа:${NC} ${CYAN}${my_ip}${NC}\n"

        python3 - "${STATE_FILE:-/etc/just1knode/state.json}" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        peers = json.load(f).get("peers", [])
except Exception:
    peers = []
if not peers:
    print("  ⚪ Зарубежные ХАБы (мосты) еще не добавлены (зарубежный трафик идет напрямую).")
else:
    for i, p in enumerate(peers, 1):
        code = p.get("code", "-")
        name = p.get("name", code)
        ip = p.get("ip", "-")
        port = p.get("port", 443)
        sni = p.get("sni", ip)
        mark = " ★ основной" if p.get("is_default") else ""
        print(f"  {i}. [{code}] {name} -> {ip}:{port} (SNI: {sni}){mark}")
PYEOF
        echo ""
        echo -e "  ${BOLD}[1]${NC} ➕ Добавить Зарубежный ХАБ (мост)"
        echo -e "  ${BOLD}[2]${NC} 🗑️  Удалить мост"
        echo -e "  ${BOLD}[0]${NC} ⬅️  Назад"
        echo ""
        local b_choice=""
        read -rp "Выберите действие [0-2]: " b_choice || true
        case "$b_choice" in
            1)
                local p_code p_name p_ip p_port p_uuid p_sni p_def
                read -rp "Код локации/моста (латиницей, например eu / nl / de) [eu]: " p_code || true
                p_code="${p_code:-eu}"
                p_code="$(echo "$p_code" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
                [[ -n "$p_code" ]] || { warn "Некорректный код."; sleep 1; continue; }

                read -rp "Название (например: Нидерланды) [${p_code^^}]: " p_name || true
                p_name="${p_name:-${p_code^^}}"

                read -rp "IPv4 адрес Зарубежного ХАБа: " p_ip || true
                p_ip="$(echo "$p_ip" | tr -d '[:space:]')"
                if ! validate_ipv4 "$p_ip" 2>/dev/null; then
                    warn "Некорректный IPv4 адрес."
                    read -rp "Нажмите Enter..." || true
                    continue
                fi

                read -rp "Порт моста на Зарубежном ХАБе [443]: " p_port || true
                p_port="${p_port:-443}"
                [[ "$p_port" =~ ^[0-9]+$ ]] || { warn "Некорректный порт."; sleep 1; continue; }

                read -rp "SNI домен Зарубежного ХАБа: " p_sni || true
                p_sni="$(normalize_domain "$p_sni" 2>/dev/null || echo "$p_sni")"
                [[ -n "$p_sni" ]] || p_sni="$p_ip"

                read -rp "Tunnel UUID (с Зарубежного ХАБа): " p_uuid || true
                p_uuid="$(echo "$p_uuid" | tr -d '[:space:]')"
                if ! python3 -c "import uuid,sys; uuid.UUID(sys.argv[1])" "$p_uuid" 2>/dev/null; then
                    warn "Некорректный UUID."
                    read -rp "Нажмите Enter..." || true
                    continue
                fi

                read -rp "Использовать как основной мост по умолчанию? [Y/n]: " p_def || true
                local is_def="true"
                [[ "$p_def" =~ ^[Nn]$ ]] && is_def="false"

                local peer_json
                peer_json="$(python3 -c 'import json,sys; print(json.dumps({"code": sys.argv[1], "name": sys.argv[2], "ip": sys.argv[3], "port": int(sys.argv[4]), "sni": sys.argv[5], "uuid": sys.argv[6], "is_default": sys.argv[7] == "true", "kind": "location"}))' "$p_code" "$p_name" "$p_ip" "$p_port" "$p_sni" "$p_uuid" "$is_def")"
                upsert_peer_json "$peer_json"

                # Синхронизация relays.json для совместимости с ботом (список локаций)
                python3 - "${STATE_FILE:-/etc/just1knode/state.json}" "${RELAYS_FILE:-/etc/just1knode/relays.json}" <<'PYEOF'
import json, os, sys, tempfile
with open(sys.argv[1], "r", encoding="utf-8") as f:
    st = json.load(f)
secret = str(st.get("secret_base_path") or "/assets_wl").rstrip("/")
relays = []
next_port = 8005
for p in (st.get("peers") or []):
    if not isinstance(p, dict) or not p.get("code"):
        continue
    c = p["code"]
    relays.append({
        "code": c,
        "name": p.get("name", c),
        "ip": p.get("ip"),
        "port": int(p.get("port") or 443),
        "uuid": p.get("uuid"),
        "sni": p.get("sni"),
        "inbound_tag": f"just1k-wl-inbound-{c}",
        "inbound_port": next_port,
        "path": f"{secret}/{c}",
    })
    next_port += 1
d = os.path.dirname(os.path.abspath(sys.argv[2]))
os.makedirs(d, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as rf:
    json.dump(relays, rf, indent=2, ensure_ascii=False)
os.replace(tmp, sys.argv[2])
PYEOF
                if apply_v2_hub_configuration; then
                    log "✔ Мост '$p_code' ($p_ip:$p_port) добавлен и применен!"
                else
                    remove_peer_json "$p_code"
                    warn "Ошибка сборки конфигурации с мостом '$p_code'. Откат."
                fi
                read -rp "Нажмите Enter..." || true
                ;;
            2)
                local del_code=""
                read -rp "Введите код моста для удаления: " del_code || true
                del_code="$(echo "$del_code" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
                [[ -n "$del_code" ]] || continue
                remove_peer_json "$del_code"
                apply_v2_hub_configuration || true
                log "✔ Мост '${del_code}' удален."
                read -rp "Нажмите Enter..." || true
                ;;
            0|"") return 0 ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

ru_hub_show_connection_details() {
    title "ДАННЫЕ ПОДКЛЮЧЕНИЯ (РУ ХАБ)"
    local my_ip domain cdn_dom secret_path api_url api_key
    my_ip="$(get_public_ipv4 2>/dev/null || echo "-")"
    domain="$(get_state_val "domain" "-")"
    cdn_dom="$(get_state_val "cdn_domain" "-")"
    secret_path="$(get_state_val "secret_base_path" "-")"
    api_url="$(get_state_val "api_url" "https://${my_ip}:8444")"
    api_key="$(get_state_val "api_key" "-")"

    echo -e "  🌐 IP / Домен:        ${CYAN}${my_ip} / ${domain}${NC}"
    echo -e "  🔗 API URL для бота:  ${CYAN}${api_url}${NC}"
    echo -e "  🔑 API Токен:         ${YELLOW}${api_key}${NC}"
    echo -e "  ☁️  CDN Домен:        ${CYAN}${cdn_dom}${NC}"
    echo -e "  🛡️  Секретный префикс: ${MAGENTA}${secret_path}${NC}"
    echo ""
}

ru_hub_menu() {
    check_root
    init_state_dir
    while true; do
        clear
        local domain bot_dom peers_count mod_cnt
        domain="$(get_state_val "domain" "-")"
        bot_dom="$(get_state_val "bot_domain" "-")"
        peers_count="$(python3 -c 'import json,sys
try:
    print(len(json.load(open(sys.argv[1], encoding="utf-8")).get("peers", [])))
except Exception:
    print(0)' "${STATE_FILE:-/etc/just1knode/state.json}" 2>/dev/null || echo "0")"
        mod_cnt="$(count_enabled_modules)"

        echo -e "${BOLD}${BLUE}═════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}  🇷🇺 УПРАВЛЕНИЕ РОЛЬЮ: РУ ХАБ${NC}"
        echo -e "${BOLD}${BLUE}═════════════════════════════════════════════════════════════${NC}"
        echo -e "  Домен:         ${CYAN}${domain}${NC}   |   Бота /sub/: ${CYAN}${bot_dom}${NC}"
        echo -e "  Модули:        ${CYAN}${mod_cnt}${NC}   |   Зарубежные ХАБы: ${CYAN}${peers_count}${NC}\n"

        echo -e "  ${BOLD}[1]${NC} VLESS TLS              $(vless_tls_status_label)"
        echo -e "  ${BOLD}[2]${NC} VLESS XHTTP (Базовый)  $(vless_xhttp_status_label)"
        if is_module_enabled "vless_xhttp"; then
            echo -e "      ${BOLD}[2.1]${NC} Yandex CDN       $(cdn_module_status_label "cdn_yandex")"
            echo -e "      ${BOLD}[2.2]${NC} TurboFlare       $(cdn_module_status_label "cdn_turboflare")"
        fi
        echo -e "  ${BOLD}[3]${NC} Мост на Зарубежный ХАБ (${peers_count} шт.)"
        echo -e "  ${BOLD}[4]${NC} Данные для подключения и CDN"
        echo -e "  ${BOLD}[B]${NC} Сменить роль$([[ "${mod_cnt:-0}" -gt 0 ]] && echo " ${DIM:-}(сначала удалите модули)${NC}" || true)"
        echo -e "  ${BOLD}[0]${NC} Назад в главное меню"
        echo ""

        local choice=""
        read -rp "Выберите пункт: " choice || true
        case "$choice" in
            1)
                if is_module_enabled "vless_tls"; then
                    echo ""
                    echo "  [1] Удалить модуль VLESS TLS"
                    echo "  [0] Отмена"
                    local sub=""
                    read -rp "Выбор [0-1]: " sub || true
                    [[ "$sub" == "1" ]] && { vless_tls_uninstall || true; read -rp "Нажмите Enter..." || true; }
                else
                    vless_tls_install || true
                    read -rp "Нажмите Enter..." || true
                fi
                ;;
            2)
                if is_module_enabled "vless_xhttp"; then
                    echo ""
                    echo "  [1] Пересобрать / обновить домен бота (/sub/)"
                    echo "  [2] Удалить модуль VLESS XHTTP (Базовый)"
                    echo "  [0] Отмена"
                    local sub=""
                    read -rp "Выбор [0-2]: " sub || true
                    case "$sub" in
                        1) vless_xhttp_install || true; read -rp "Нажмите Enter..." || true ;;
                        2) vless_xhttp_uninstall || true; read -rp "Нажмите Enter..." || true ;;
                    esac
                else
                    vless_xhttp_install || true
                    read -rp "Нажмите Enter..." || true
                fi
                ;;
            2.1)
                if ! is_module_enabled "vless_xhttp"; then
                    warn "Сначала установите [2] VLESS XHTTP (Базовый)."
                    sleep 1
                elif is_module_enabled "cdn_yandex"; then
                    echo ""
                    echo "  [1] Изменить CDN-домен Yandex CDN"
                    echo "  [2] Удалить субмодуль Yandex CDN"
                    echo "  [0] Отмена"
                    local sub=""
                    read -rp "Выбор [0-2]: " sub || true
                    case "$sub" in
                        1) cdn_provider_install "cdn_yandex" || true; read -rp "Нажмите Enter..." || true ;;
                        2) cdn_provider_uninstall "cdn_yandex" || true; read -rp "Нажмите Enter..." || true ;;
                    esac
                else
                    cdn_provider_install "cdn_yandex" || true
                    read -rp "Нажмите Enter..." || true
                fi
                ;;
            2.2)
                if ! is_module_enabled "vless_xhttp"; then
                    warn "Сначала установите [2] VLESS XHTTP (Базовый)."
                    sleep 1
                elif is_module_enabled "cdn_turboflare"; then
                    echo ""
                    echo "  [1] Изменить CDN-домен TurboFlare"
                    echo "  [2] Удалить субмодуль TurboFlare"
                    echo "  [0] Отмена"
                    local sub=""
                    read -rp "Выбор [0-2]: " sub || true
                    case "$sub" in
                        1) cdn_provider_install "cdn_turboflare" || true; read -rp "Нажмите Enter..." || true ;;
                        2) cdn_provider_uninstall "cdn_turboflare" || true; read -rp "Нажмите Enter..." || true ;;
                    esac
                else
                    cdn_provider_install "cdn_turboflare" || true
                    read -rp "Нажмите Enter..." || true
                fi
                ;;
            3) _ru_hub_manage_bridges ;;
            4) ru_hub_show_connection_details; read -rp "Нажмите Enter..." || true ;;
            b|B)
                if change_role_guarded; then
                    return 0
                fi
                read -rp "Нажмите Enter..." || true
                ;;
            0|"") return 0 ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}
