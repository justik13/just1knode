#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE v2 - Роль 3: 🚀 Выходная НОДА (443 строго от хабов -> Freedom)
# =============================================================================

exit_node_show_credentials() {
    title "ДАННЫЕ ПОДКЛЮЧЕНИЯ (ВЫХОДНАЯ НОДА)"
    local my_ip domain t_uuid api_url api_key
    my_ip="$(get_public_ipv4 2>/dev/null || echo "-")"
    domain="$(get_state_val "domain" "-")"
    t_uuid="$(get_state_val "tunnel_uuid" "-")"
    api_url="$(get_state_val "api_url" "https://${my_ip}:8444")"
    api_key="$(get_state_val "api_key" "-")"

    echo -e "  ${BOLD}Для добавления на Зарубежном ХАБе / в админке:${NC}"
    echo -e "    IP:          ${CYAN}${my_ip}${NC}"
    echo -e "    Порт:        ${CYAN}443 (закрыт от мира, только для ХАБов)${NC}"
    echo -e "    Домен (SNI): ${CYAN}${domain}${NC}"
    echo -e "    Bridge UUID: ${YELLOW}${t_uuid}${NC}"
    echo ""
    echo -e "  ${BOLD}Для Telegram-бота (/admin):${NC}"
    echo -e "    URL API:     ${CYAN}${api_url}${NC}"
    echo -e "    Токен:       ${YELLOW}${api_key}${NC}"
    echo ""
}

_exit_node_manage_hub_whitelist() {
    while true; do
        clear
        title "БЕЛЫЙ СПИСОК ХАБОВ ДЛЯ ВЫХОДНОЙ НОДЫ (UFW 443)"
        echo -e "  ${DIM:-}Порт 443 на Выходной НОДе закрыт от внешнего мира (Zero-Trust).${NC}"
        echo -e "  ${DIM:-}Разрешённые IP управляются админкой (links.json) или локально ниже:${NC}\n"

        python3 - "${STATE_FILE:-/etc/just1knode/state.json}" "${LINKS_FILE:-${STATE_DIR:-/etc/just1knode}/links.json}" <<'PYEOF'
import json, sys
def ld(p):
    try: return json.load(open(p, encoding="utf-8"))
    except Exception: return {}
st = ld(sys.argv[1])
lk = ld(sys.argv[2])
ips = []
for src in (lk, st):
    for k in ("allowed_hub_ips", "allowed_ru_ips", "eu_hub_ips"):
        for x in (src.get(k) or []):
            s = x.get("ip") if isinstance(x, dict) else x
            s = str(s or "").strip()
            if s and s not in ips:
                ips.append(s)
for arr_k in ("incoming_hubs", "incoming_eu_hubs"):
    for item in (lk.get(arr_k) or []):
        if isinstance(item, dict) and item.get("ip") and item["ip"] not in ips:
            ips.append(item["ip"])
if not ips:
    print("    ⚪ Нет добавленных IP хабов (порт 443 закрыт от всех — Fail-Closed).")
else:
    for i, ip in enumerate(ips, 1):
        print(f"    {i}. {ip}")
PYEOF
        echo ""
        echo -e "  ${BOLD}[1]${NC} ➕ Добавить IP хаба в белый список 443 (локально)"
        echo -e "  ${BOLD}[2]${NC} 🗑️  Удалить IP хаба из локального списка"
        echo -e "  ${BOLD}[0]${NC} ⬅️  Назад"
        echo ""
        local w_choice=""
        read -rp "Выберите действие [0-2]: " w_choice || true
        case "$w_choice" in
            1)
                local hub_ip=""
                read -rp "IPv4 адрес Зарубежного/РУ ХАБа: " hub_ip || true
                hub_ip="$(echo "$hub_ip" | tr -d '[:space:]')"
                if ! validate_ipv4 "$hub_ip" 2>/dev/null; then
                    warn "Некорректный IPv4 адрес."
                    read -rp "Нажмите Enter..." || true
                    continue
                fi
                local updated_json
                updated_json="$(python3 -c 'import json,sys
try:
    cur = json.load(open(sys.argv[1], encoding="utf-8")).get("allowed_hub_ips", [])
except Exception:
    cur = []
if not isinstance(cur, list): cur = []
ip = sys.argv[2]
if ip not in cur: cur.append(ip)
print(json.dumps(cur))' "${STATE_FILE:-/etc/just1knode/state.json}" "$hub_ip")"
                set_state_json_val "allowed_hub_ips" "$updated_json"
                heal_node_firewall_and_stealth
                log "✔ IP хаба ${hub_ip} разрешен на порту 443/tcp."
                read -rp "Нажмите Enter..." || true
                ;;
            2)
                local del_ip=""
                read -rp "Введите IP хаба для удаления: " del_ip || true
                del_ip="$(echo "$del_ip" | tr -d '[:space:]')"
                [[ -n "$del_ip" ]] || continue
                local updated_json
                updated_json="$(python3 -c 'import json,sys
try:
    cur = json.load(open(sys.argv[1], encoding="utf-8")).get("allowed_hub_ips", [])
except Exception:
    cur = []
print(json.dumps([x for x in (cur if isinstance(cur, list) else []) if x != sys.argv[2]]))' "${STATE_FILE:-/etc/just1knode/state.json}" "$del_ip")"
                set_state_json_val "allowed_hub_ips" "$updated_json"
                heal_node_firewall_and_stealth
                log "✔ Доступ для IP ${del_ip} отозван."
                read -rp "Нажмите Enter..." || true
                ;;
            0|"") return 0 ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

exit_node_menu() {
    check_root
    init_state_dir
    while true; do
        clear
        local domain abuse mod_cnt hubs_cnt
        domain="$(get_state_val "domain" "-")"
        abuse="$(get_state_val "abuse_protection" "disabled")"
        mod_cnt="$(count_enabled_modules)"
        hubs_cnt="$(python3 - "${STATE_FILE:-/etc/just1knode/state.json}" "${LINKS_FILE:-${STATE_DIR:-/etc/just1knode}/links.json}" <<'PYEOF' 2>/dev/null || echo "0"
import json, sys
def ld(p):
    try: return json.load(open(p, encoding="utf-8"))
    except Exception: return {}
st = ld(sys.argv[1])
lk = ld(sys.argv[2])
ips = set()
for src in (lk, st):
    for k in ("allowed_hub_ips", "allowed_ru_ips", "eu_hub_ips"):
        for x in (src.get(k) or []):
            s = x.get("ip") if isinstance(x, dict) else x
            if s: ips.add(str(s).strip())
for arr_k in ("incoming_hubs", "incoming_eu_hubs"):
    for item in (lk.get(arr_k) or []):
        if isinstance(item, dict) and item.get("ip"): ips.add(item["ip"])
print(len(ips))
PYEOF
)"

        echo -e "${BOLD}${BLUE}═════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}  🚀 УПРАВЛЕНИЕ РОЛЬЮ: ВЫХОДНАЯ НОДА${NC}"
        echo -e "${BOLD}${BLUE}═════════════════════════════════════════════════════════════${NC}"
        echo -e "  Домен (SNI):  ${CYAN}${domain}${NC}   |   Порт 443: ${CYAN}Zero-Trust (${hubs_cnt} хаб(ов))${NC}"
        echo -e "  Anti-Abuse:   ${CYAN}${abuse}${NC}\n"

        echo -e "  ${BOLD}[1]${NC} Показать данные подключения (Bridge UUID + API для бота)"
        echo -e "  ${BOLD}[2]${NC} Белый список хабов для порта 443 (${hubs_cnt} шт.)"
        echo -e "  ${BOLD}[3]${NC} Переприменить SSL, Xray, UFW и Anti-Abuse"
        echo -e "  ${BOLD}[B]${NC} Сменить роль$([[ "${mod_cnt:-0}" -gt 0 ]] && echo " ${DIM:-}(сначала удалите модули)${NC}" || true)"
        echo -e "  ${BOLD}[0]${NC} Назад в главное меню"
        echo ""

        local choice=""
        read -rp "Выберите пункт: " choice || true
        case "$choice" in
            1) exit_node_show_credentials; read -rp "Нажмите Enter..." || true ;;
            2) _exit_node_manage_hub_whitelist ;;
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
