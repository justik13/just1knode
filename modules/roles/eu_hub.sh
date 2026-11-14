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

        echo -e "  ${BOLD}Параметры этого Зарубежного ХАБа для админки / РУ ХАБа:${NC}"
        echo -e "    IP:          ${CYAN}${my_ip}${NC}"
        echo -e "    Порт:        ${CYAN}443${NC}"
        echo -e "    SNI (FQDN):  ${CYAN}${domain}${NC}"
        echo -e "    Bridge UUID: ${YELLOW}${t_uuid}${NC}\n"

        echo -e "  ${BOLD}Разрешённые IP РУ ХАБов (state.json + links.json):${NC}"
        python3 - "${STATE_FILE:-/etc/just1knode/state.json}" "${LINKS_FILE:-${STATE_DIR:-/etc/just1knode}/links.json}" <<'PYEOF'
import json, sys
def ld(p):
    try: return json.load(open(p, encoding="utf-8"))
    except Exception: return {}
st = ld(sys.argv[1])
lk = ld(sys.argv[2])
ips = []
for src in (lk, st):
    for ip in (src.get("allowed_ru_ips") or []):
        if isinstance(ip, str) and ip.strip() and ip.strip() not in ips:
            ips.append(ip.strip())
for item in (lk.get("incoming_ru_hubs") or []):
    if isinstance(item, dict) and item.get("ip") and item["ip"] not in ips:
        ips.append(item["ip"])
if not ips:
    print("    ⚪ Нет добавленных IP РУ ХАБов (порт 443 закрыт от мира — Fail-Closed).")
else:
    for i, ip in enumerate(ips, 1):
        print(f"    {i}. {ip}")
PYEOF
        echo ""
        echo -e "  ${BOLD}[1]${NC} ➕ Добавить IP РУ ХАБа (локально)"
        echo -e "  ${BOLD}[2]${NC} 🗑️  Удалить IP РУ ХАБа (локально)"
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
                heal_node_firewall_and_stealth
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
        title "ВЫХОДНЫЕ НОДЫ (links.json)"
        python3 - "${LINKS_FILE:-${STATE_DIR:-/etc/just1knode}/links.json}" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fp:
        lk = json.load(fp)
except Exception:
    lk = {}
ex_api = (lk.get("exit_nodes") or []) if isinstance(lk, dict) else []

print("  [Админка links.json — Выходные НОДЫ]:")
if ex_api:
    for i, p in enumerate(ex_api, 1):
        mark = " ★ default" if p.get("is_default") else ""
        print(f"    {i}. [{p.get('code', '-')}] {p.get('name', p.get('code', '-'))} -> {p.get('ip', '-')}:{p.get('port', 443)} (SNI: {p.get('sni', '-')}){mark}")
else:
    print("    ⚪ Выходные НОДЫ еще не привязаны (Freedom на Зарубежном ХАБе запрещён!).")
PYEOF
        echo ""
        echo -e "  ${BOLD}[1]${NC} 🔄 Сбросить links.json и переприменить"
        echo -e "  ${BOLD}[0]${NC} ⬅️  Назад"
        echo ""
        local e_choice=""
        read -rp "Выберите действие [0-1]: " e_choice || true
        case "$e_choice" in
            1)
                save_links_json "{}"
                apply_v2_hub_configuration || true
                log "✔ Связи сброшены и переприменены."
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
        local domain counts exits_cnt ru_cnt mod_cnt
        domain="$(get_state_val "domain" "-")"
        counts="$(python3 - "${STATE_FILE:-/etc/just1knode/state.json}" "${LINKS_FILE:-${STATE_DIR:-/etc/just1knode}/links.json}" <<'PYEOF' 2>/dev/null || echo "0|0"
import json, sys
def ld(p):
    try: return json.load(open(p, encoding="utf-8"))
    except Exception: return {}
st = ld(sys.argv[1])
lk = ld(sys.argv[2])
ru = set(st.get("allowed_ru_ips") or []) | set(lk.get("allowed_ru_ips") or [])
for item in (lk.get("incoming_ru_hubs") or []):
    if isinstance(item, dict) and item.get("ip"): ru.add(item["ip"])
ex = len(lk.get("exit_nodes") or [])
print(f"{len(ru)}|{ex}")
PYEOF
)"
        ru_cnt="${counts%%|*}"
        exits_cnt="${counts#*|}"
        mod_cnt="$(count_enabled_modules)"

        echo -e "${BOLD}${BLUE}═════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}  🌍 УПРАВЛЕНИЕ РОЛЬЮ: ЗАРУБЕЖНЫЙ ХАБ (ТРАНЗИТНЫЙ МОСТ)${NC}"
        echo -e "${BOLD}${BLUE}═════════════════════════════════════════════════════════════${NC}"
        echo -e "  Домен (SNI):   ${CYAN}${domain}${NC}   |   Порт: ${CYAN}443 (TLS без freedom)${NC}"
        echo -e "  РУ ХАБы (UFW): ${CYAN}${ru_cnt}${NC}      |   Выходные НОДЫ: ${CYAN}${exits_cnt}${NC}\n"

        echo -e "  ${BOLD}[1]${NC} Доступ от РУ ХАБов (Белый список UFW + данные подключения)"
        echo -e "  ${BOLD}[2]${NC} Связи с Выходными НОДАми (${exits_cnt} шт.)"
        echo -e "  ${BOLD}[3]${NC} Переприменить конфигурацию моста, SSL и UFW"
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
