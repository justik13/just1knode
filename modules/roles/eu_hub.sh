#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE v2 - Роль 2: 🌍 Зарубежный ХАБ (чистый транзитный мост 443)
# =============================================================================

_eu_hub_manage_ru_whitelist() {
    while true; do
        clear
        title "БЕЛЫЙ СПИСОК РУ ХАБОВ (UFW 443)"
        local my_ip domain t_uuid
        my_ip="$(get_public_ipv4 2>/dev/null || echo "-")"
        domain="$(get_state_val "domain" "-")"
        t_uuid="$(get_state_val "tunnel_uuid" "-")"

        echo -e "  ${BOLD}Параметры этого Зарубежного ХАБа для ввода на РУ ХАБе:${NC}"
        echo -e "    IP:          ${CYAN}${my_ip}${NC}"
        echo -e "    Порт:        ${CYAN}443${NC}"
        echo -e "    SNI:         ${CYAN}${domain}${NC}"
        echo -e "    Tunnel UUID: ${YELLOW}${t_uuid}${NC}\n"

        echo -e "  ${BOLD}Разрешённые IP РУ ХАБов:${NC}"
        python3 - "${STATE_FILE:-/etc/just1knode/state.json}" <<'PYEOF'
import json, sys
try:
    ips = json.load(open(sys.argv[1], encoding="utf-8")).get("allowed_ru_ips", [])
except Exception:
    ips = []
if not ips:
    print("    ⚪ Нет добавленных IP РУ ХАБов (порт 443 закрыт от мира).")
else:
    for i, ip in enumerate(ips, 1):
        print(f"    {i}. {ip}")
PYEOF
        echo ""
        echo -e "  ${BOLD}[1]${NC} ➕ Добавить IP РУ ХАБа"
        echo -e "  ${BOLD}[2]${NC} 🗑️  Удалить IP РУ ХАБа"
        echo -e "  ${BOLD}[0]${NC} ⬅️  Назад"
        echo ""
        local w_choice=""
        read -rp "Выберите действие [0-2]: " w_choice || true
        case "$w_choice" in
            1)
                local ru_ip=""
                read -rp "IPv4 адрес РУ ХАБа: " ru_ip || true
                ru_ip="$(echo "$ru_ip" | tr -d '[:space:]')"
                if ! validate_ipv4 "$ru_ip" 2>/dev/null; then
                    warn "Некорректный IPv4 адрес."
                    read -rp "Нажмите Enter..." || true
                    continue
                fi
                local updated_json
                updated_json="$(python3 -c 'import json,sys
try:
    cur = json.load(open(sys.argv[1], encoding="utf-8")).get("allowed_ru_ips", [])
except Exception:
    cur = []
if not isinstance(cur, list): cur = []
ip = sys.argv[2]
if ip not in cur: cur.append(ip)
print(json.dumps(cur))' "${STATE_FILE:-/etc/just1knode/state.json}" "$ru_ip")"
                set_state_json_val "allowed_ru_ips" "$updated_json"
                heal_node_firewall_and_stealth
                log "✔ IP ${ru_ip} разрешен для моста (порт 443/tcp)."
                read -rp "Нажмите Enter..." || true
                ;;
            2)
                local del_ip=""
                read -rp "Введите IP для удаления: " del_ip || true
                del_ip="$(echo "$del_ip" | tr -d '[:space:]')"
                [[ -n "$del_ip" ]] || continue
                local updated_json
                updated_json="$(python3 -c 'import json,sys
try:
    cur = json.load(open(sys.argv[1], encoding="utf-8")).get("allowed_ru_ips", [])
except Exception:
    cur = []
print(json.dumps([x for x in (cur if isinstance(cur, list) else []) if x != sys.argv[2]]))' "${STATE_FILE:-/etc/just1knode/state.json}" "$del_ip")"
                set_state_json_val "allowed_ru_ips" "$updated_json"
                if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
                    ufw delete allow from "$del_ip" to any port 443 proto tcp >/dev/null 2>&1 || true
                fi
                log "✔ Доступ для IP ${del_ip} отозван."
                read -rp "Нажмите Enter..." || true
                ;;
            0|"") return 0 ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

_eu_hub_manage_exits() {
    while true; do
        clear
        title "ВЫХОДНЫЕ НОДЫ (EXIT NODES)"
        python3 - "${STATE_FILE:-/etc/just1knode/state.json}" <<'PYEOF'
import json, sys
try:
    peers = json.load(open(sys.argv[1], encoding="utf-8")).get("peers", [])
except Exception:
    peers = []
if not peers:
    print("  ⚪ Выходные НОДЫ еще не привязаны (Freedom на Зарубежном ХАБе запрещен!).")
else:
    for i, p in enumerate(peers, 1):
        mark = " ★ по умолчанию" if p.get("is_default") else ""
        print(f"  {i}. [{p.get('code')}] {p.get('name')} -> {p.get('ip')}:{p.get('port', 443)} (SNI: {p.get('sni')}){mark}")
PYEOF
        echo ""
        echo -e "  ${BOLD}[1]${NC} ➕ Добавить Выходную НОДУ"
        echo -e "  ${BOLD}[2]${NC} 🗑️  Удалить Выходную НОДУ"
        echo -e "  ${BOLD}[0]${NC} ⬅️  Назад"
        echo ""
        local e_choice=""
        read -rp "Выберите действие [0-2]: " e_choice || true
        case "$e_choice" in
            1)
                local e_code e_name e_ip e_port e_sni e_uuid e_def
                read -rp "Код локации Выходной НОДы (например nl / de / us): " e_code || true
                e_code="$(echo "$e_code" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
                [[ -n "$e_code" ]] || { warn "Некорректный код."; sleep 1; continue; }

                read -rp "Название [${e_code^^}]: " e_name || true
                e_name="${e_name:-${e_code^^}}"

                read -rp "IPv4 адрес Выходной НОДы: " e_ip || true
                e_ip="$(echo "$e_ip" | tr -d '[:space:]')"
                if ! validate_ipv4 "$e_ip" 2>/dev/null; then
                    warn "Некорректный IPv4."
                    read -rp "Нажмите Enter..." || true
                    continue
                fi

                read -rp "Порт [443]: " e_port || true
                e_port="${e_port:-443}"
                [[ "$e_port" =~ ^[0-9]+$ ]] || { warn "Некорректный порт."; sleep 1; continue; }

                read -rp "Домен (SNI) Выходной НОДы: " e_sni || true
                e_sni="$(normalize_domain "$e_sni" 2>/dev/null || echo "$e_sni")"
                [[ -n "$e_sni" ]] || e_sni="$e_ip"

                read -rp "UUID Выходной НОДы: " e_uuid || true
                e_uuid="$(echo "$e_uuid" | tr -d '[:space:]')"
                if ! python3 -c "import uuid,sys; uuid.UUID(sys.argv[1])" "$e_uuid" 2>/dev/null; then
                    warn "Некорректный UUID."
                    read -rp "Нажмите Enter..." || true
                    continue
                fi

                read -rp "Сделать основным выходом по умолчанию? [Y/n]: " e_def || true
                local is_def="true"
                [[ "$e_def" =~ ^[Nn]$ ]] && is_def="false"

                local peer_json
                peer_json="$(python3 -c 'import json,sys; print(json.dumps({"code": sys.argv[1], "name": sys.argv[2], "ip": sys.argv[3], "port": int(sys.argv[4]), "sni": sys.argv[5], "uuid": sys.argv[6], "is_default": sys.argv[7] == "true", "kind": "exit"}))' "$e_code" "$e_name" "$e_ip" "$e_port" "$e_sni" "$e_uuid" "$is_def")"
                upsert_peer_json "$peer_json"

                if apply_v2_hub_configuration; then
                    log "✔ Выходная НОДА '$e_code' ($e_ip:$e_port) подключена!"
                else
                    remove_peer_json "$e_code"
                    warn "Ошибка сборки конфигурации для '$e_code'. Откат."
                fi
                read -rp "Нажмите Enter..." || true
                ;;
            2)
                local del_code=""
                read -rp "Код Выходной НОДы для удаления: " del_code || true
                del_code="$(echo "$del_code" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
                [[ -n "$del_code" ]] || continue
                remove_peer_json "$del_code"
                apply_v2_hub_configuration || true
                log "✔ Выходная НОДА '${del_code}' удалена."
                read -rp "Нажмите Enter..." || true
                ;;
            0|"") return 0 ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

eu_hub_menu() {
    check_root
    init_state_dir
    while true; do
        clear
        local domain exits_cnt ru_cnt mod_cnt
        domain="$(get_state_val "domain" "-")"
        exits_cnt="$(python3 -c 'import json,sys
try: print(len(json.load(open(sys.argv[1], encoding="utf-8")).get("peers", [])))
except Exception: print(0)' "${STATE_FILE:-/etc/just1knode/state.json}" 2>/dev/null || echo "0")"
        ru_cnt="$(python3 -c 'import json,sys
try: print(len(json.load(open(sys.argv[1], encoding="utf-8")).get("allowed_ru_ips", [])))
except Exception: print(0)' "${STATE_FILE:-/etc/just1knode/state.json}" 2>/dev/null || echo "0")"
        mod_cnt="$(count_enabled_modules)"

        echo -e "${BOLD}${BLUE}═════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}  🌍 УПРАВЛЕНИЕ РОЛЬЮ: ЗАРУБЕЖНЫЙ ХАБ (ТРАНЗИТНЫЙ МОСТ)${NC}"
        echo -e "${BOLD}${BLUE}═════════════════════════════════════════════════════════════${NC}"
        echo -e "  Домен (SNI):   ${CYAN}${domain}${NC}   |   Порт: ${CYAN}443 (TLS без freedom)${NC}"
        echo -e "  РУ ХАБы (UFW): ${CYAN}${ru_cnt}${NC}      |   Выходные НОДЫ: ${CYAN}${exits_cnt}${NC}\n"

        echo -e "  ${BOLD}[1]${NC} Доступ от РУ ХАБов (Белый список UFW + данные подключения)"
        echo -e "  ${BOLD}[2]${NC} Управление Выходными НОДАми (${exits_cnt} шт.)"
        echo -e "  ${BOLD}[3]${NC} Переприменить конфигурацию моста и SSL"
        echo -e "  ${BOLD}[B]${NC} Сменить роль$([[ "${mod_cnt:-0}" -gt 0 ]] && echo " ${DIM:-}(сначала удалите модули)${NC}" || true)"
        echo -e "  ${BOLD}[0]${NC} Назад в главное меню"
        echo ""

        local choice=""
        read -rp "Выберите пункт: " choice || true
        case "$choice" in
            1) _eu_hub_manage_ru_whitelist ;;
            2) _eu_hub_manage_exits ;;
            3) apply_v2_hub_configuration || true; read -rp "Нажмите Enter..." || true ;;
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
