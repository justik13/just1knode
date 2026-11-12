#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE v2 - Роль 1: 🇷🇺 РУ ХАБ (входной шлюз + независимые модули)
# =============================================================================

_ru_hub_manage_bridges() {
    while true; do
        clear
        title "СВЯЗИ С ЗАРУБЕЖНЫМИ ХАБАМИ (links.json / резерв CLI)"
        local my_ip
        my_ip="$(get_public_ipv4 2>/dev/null || echo "<IP_РУ_ХАБА>")"
        echo -e "  ${DIM:-}Обычно связи настраиваются автоматически через админку бота (PUT /v1/node/links).${NC}"
        echo -e "  ${DIM:-}IP этого РУ ХАБа для белого списка на Зарубежном ХАБе:${NC} ${CYAN}${my_ip}${NC}\n"

        python3 - "${LINKS_FILE:-${STATE_DIR:-/etc/just1knode}/links.json}" "${STATE_FILE:-/etc/just1knode/state.json}" <<'PYEOF'
import json, sys

def load_d(p):
    try:
        with open(p, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}

lk = load_d(sys.argv[1])
st = load_d(sys.argv[2])
if not isinstance(lk, dict): lk = {}
if not isinstance(st, dict): st = {}

std = (lk.get("standard") or {}).get("bridges") or lk.get("standard_bridges") or []
bi = (lk.get("bi") or {}).get("bridges") or lk.get("bi_bridges") or []
sni_routes = (lk.get("standard") or {}).get("sni_routes") or lk.get("sni_routes") or []
peers = st.get("peers") or []

print("  [Админка links.json — Стандарт (VLESS TLS)]:")
if std:
    for i, p in enumerate(std, 1):
        mark = " ★ default" if p.get("is_default") else ""
        print(f"    {i}. [{p.get('code', '-')}] {p.get('ip', '-')}:{p.get('port', 443)} (SNI: {p.get('sni', '-')}){mark}")
else:
    print("    ⚪ Не задано")

if sni_routes:
    print("  [SNI-маршруты Стандарта]:")
    for rt in sni_routes:
        print(f"    • {rt.get('sni', '-')} -> мост [{rt.get('bridge_code', '-')}]")

print("  [Админка links.json — Белый Интернет (XHTTP + CDN)]:")
if bi:
    for i, p in enumerate(bi, 1):
        mark = " ★ default" if p.get("is_default") else ""
        print(f"    {i}. [{p.get('code', '-')}] {p.get('ip', '-')}:{p.get('port', 443)} (SNI: {p.get('sni', '-')}){mark}")
else:
    print("    ⚪ Не задано")

if peers:
    print("  [Локальные резервные мосты (CLI peers)]:")
    for i, p in enumerate(peers, 1):
        mark = " ★ default" if p.get("is_default") else ""
        print(f"    {i}. [{p.get('code', '-')}] {p.get('name', p.get('code', '-'))} -> {p.get('ip', '-')}:{p.get('port', 443)} (SNI: {p.get('sni', '-')}){mark}")

if not std and not bi and not peers:
    print("\n  ⚠ Активных мостов нет: зарубежный трафик блокируется (blackhole), работает только Рунет (direct).")
PYEOF
        echo ""
        echo -e "  ${BOLD}[1]${NC} ➕ Добавить локальный резервный мост (для обеих схем)"
        echo -e "  ${BOLD}[2]${NC} 🗑️  Удалить локальный резервный мост"
        echo -e "  ${BOLD}[3]${NC} 🔄 Сбросить связи links.json и переприменить"
        echo -e "  ${BOLD}[0]${NC} ⬅️  Назад"
        echo ""
        local b_choice=""
        read -rp "Выберите действие [0-3]: " b_choice || true
        case "$b_choice" in
            1)
                local p_code p_name p_ip p_port p_uuid p_sni p_def
                read -rp "Код локации/моста (латиницей, например eu / nl / de) [eu]: " p_code || true
                p_code="${p_code:-eu}"
                p_code="$(echo "$p_code" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
                [[ -n "$p_code" ]] || { warn "Некорректный код."; sleep 1; continue; }

                read -rp "Название (например: Польша Хаб) [${p_code^^}]: " p_name || true
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

                read -rp "FQDN домен (SNI) Зарубежного ХАБа: " p_sni || true
                p_sni="$(normalize_domain "$p_sni" 2>/dev/null || echo "$p_sni")"
                if [[ -z "$p_sni" ]] || ! validate_fqdn "$p_sni" 2>/dev/null; then
                    warn "Zero-Signature: SNI обязан быть корректным FQDN-доменом (голый IP запрещён)."
                    read -rp "Нажмите Enter..." || true
                    continue
                fi

                read -rp "Bridge UUID Зарубежного ХАБа: " p_uuid || true
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
                read -rp "Введите код локального моста для удаления: " del_code || true
                del_code="$(echo "$del_code" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
                [[ -n "$del_code" ]] || continue
                remove_peer_json "$del_code"
                apply_v2_hub_configuration || true
                log "✔ Локальный мост '${del_code}' удален."
                read -rp "Нажмите Enter..." || true
                ;;
            3)
                save_links_json "{}"
                set_state_json_val "peers" "[]"
                apply_v2_hub_configuration || true
                log "✔ Локальные и синхронизированные связи очищены."
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

_ru_hub_toggle_module() {
    local mod_id="$1"
    if is_module_broken "$mod_id"; then
        local reason
        reason="$(get_broken_module_reason "$mod_id" 2>/dev/null || echo "ошибка синтаксиса/контракта")"
        warn "Модуль '${mod_id}' изолирован из-за ошибки: ${reason}"
        read -rp "Нажмите Enter..." || true
        return 1
    fi
    local label
    label="$(get_module_meta_field "$mod_id" "label" "$mod_id")"
    local parent
    parent="$(get_module_meta_field "$mod_id" "parent" "")"
    if [[ -n "$parent" ]] && ! is_module_enabled "$parent"; then
        warn "Сначала установите родительский модуль '${parent}'!"
        sleep 1
        return 1
    fi

    if is_module_enabled "$mod_id"; then
        echo ""
        echo "  [1] Пересобрать / обновить настройки '${label}'"
        echo "  [2] Удалить модуль '${label}'"
        echo "  [0] Отмена"
        local sub=""
        read -rp "Выбор [0-2]: " sub || true
        case "$sub" in
            1) "${mod_id}_install" || true; read -rp "Нажмите Enter..." || true ;;
            2) "${mod_id}_uninstall" || true; read -rp "Нажмите Enter..." || true ;;
        esac
    else
        "${mod_id}_install" || true
        read -rp "Нажмите Enter..." || true
    fi
}

ru_hub_menu() {
    check_root
    init_state_dir
    while true; do
        clear
        local domain bot_dom links_info mod_cnt
        domain="$(get_state_val "domain" "-")"
        bot_dom="$(get_state_val "bot_domain" "-")"
        mod_cnt="$(count_enabled_modules)"
        links_info="$(python3 - "${LINKS_FILE:-${STATE_DIR:-/etc/just1knode}/links.json}" "${STATE_FILE:-/etc/just1knode/state.json}" <<'PYEOF' 2>/dev/null || echo "0|0"
import json, sys
def ld(p):
    try:
        return json.load(open(p, encoding="utf-8"))
    except Exception:
        return {}
lk = ld(sys.argv[1])
st = ld(sys.argv[2])
peers = st.get("peers") or []
std_cnt = len(((lk.get("standard") or {}).get("bridges") or lk.get("standard_bridges") or []) or peers)
bi_cnt = len(((lk.get("bi") or {}).get("bridges") or lk.get("bi_bridges") or []) or peers)
print(f"{std_cnt}|{bi_cnt}")
PYEOF
)"
        local std_cnt="${links_info%%|*}"
        local bi_cnt="${links_info#*|}"

        echo -e "${BOLD}${BLUE}═════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}  🇷🇺 УПРАВЛЕНИЕ РОЛЬЮ: РУ ХАБ${NC}"
        echo -e "${BOLD}${BLUE}═════════════════════════════════════════════════════════════${NC}"
        echo -e "  Домен:    ${CYAN}${domain}${NC}   |   Бота /sub/: ${CYAN}${bot_dom}${NC}"
        echo -e "  Модули:   ${CYAN}${mod_cnt}${NC}   |   Мосты: Стандарт=${CYAN}${std_cnt}${NC}, БИ=${CYAN}${bi_cnt}${NC}"
        if [[ ${#BROKEN_MODULE_IDS[@]} -gt 0 ]]; then
            echo -e "  ${RED}⚠ Изолированы битые модули:${NC} ${BROKEN_MODULE_IDS[*]}"
        fi
        echo ""

        local tls_lbl xhttp_lbl
        tls_lbl="$(declare -F vless_tls_status_label >/dev/null && vless_tls_status_label || echo -e "${RED}🔴 Изолирован / не загружен${NC}")"
        xhttp_lbl="$(declare -F vless_xhttp_status_label >/dev/null && vless_xhttp_status_label || echo -e "${RED}🔴 Изолирован / не загружен${NC}")"
        echo -e "  ${BOLD}[1]${NC} VLESS TLS              ${tls_lbl}"
        echo -e "  ${BOLD}[2]${NC} VLESS XHTTP (Базовый)  ${xhttp_lbl}"

        local child_ids=()
        local c_id c_idx=1
        if is_module_enabled "vless_xhttp" && ! is_module_broken "vless_xhttp"; then
            while IFS= read -r c_id; do
                [[ -z "$c_id" ]] && continue
                child_ids+=("$c_id")
                local c_lbl c_st
                c_lbl="$(get_module_meta_field "$c_id" "label" "$c_id")"
                c_st="$("${c_id}_status_label" 2>/dev/null || echo -e "${RED}🔴 Ошибка${NC}")"
                printf "      \033[1m[2.%d]\033[0m %-16s %b\n" "$c_idx" "$c_lbl" "$c_st"
                c_idx=$((c_idx + 1))
            done < <(get_child_modules_for "vless_xhttp")
        fi

        echo -e "  ${BOLD}[3]${NC} Связи на Зарубежные ХАБы (Стандарт=${std_cnt}, БИ=${bi_cnt})"
        echo -e "  ${BOLD}[4]${NC} Данные для подключения и CDN"
        echo -e "  ${BOLD}[5]${NC} Переприменить конфигурацию роли"
        echo -e "  ${BOLD}[B]${NC} Сменить роль$([[ "${mod_cnt:-0}" -gt 0 ]] && echo " ${DIM:-}(сначала удалите модули)${NC}" || true)"
        echo -e "  ${BOLD}[0]${NC} Назад в главное меню"
        echo ""

        local choice=""
        read -rp "Выберите пункт: " choice || true
        case "$choice" in
            1) _ru_hub_toggle_module "vless_tls" ;;
            2) _ru_hub_toggle_module "vless_xhttp" ;;
            2.*)
                if ! is_module_enabled "vless_xhttp"; then
                    warn "Сначала установите [2] VLESS XHTTP (Базовый)."
                    sleep 1
                else
                    local sub_n="${choice#2.}"
                    if [[ "$sub_n" =~ ^[0-9]+$ ]] && [[ "$sub_n" -ge 1 && "$sub_n" -le ${#child_ids[@]} ]]; then
                        _ru_hub_toggle_module "${child_ids[$((sub_n - 1))]}"
                    else
                        warn "Неверный номер субмодуля."
                        sleep 1
                    fi
                fi
                ;;
            3) _ru_hub_manage_bridges ;;
            4) ru_hub_show_connection_details; read -rp "Нажмите Enter..." || true ;;
            5) apply_v2_hub_configuration || true; read -rp "Нажмите Enter..." || true ;;
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
