#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE v2 - Роль 3: 🚀 Выходная НОДА (терминация 443 -> Freedom + Anti-Abuse)
# =============================================================================

exit_node_show_credentials() {
    title "ДАННЫЕ ПОДКЛЮЧЕНИЯ (ВЫХОДНАЯ НОДА)"
    local my_ip domain t_uuid api_url api_key
    my_ip="$(get_public_ipv4 2>/dev/null || echo "-")"
    domain="$(get_state_val "domain" "-")"
    t_uuid="$(get_state_val "tunnel_uuid" "-")"
    api_url="$(get_state_val "api_url" "https://${my_ip}:8444")"
    api_key="$(get_state_val "api_key" "-")"

    echo -e "  ${BOLD}Для добавления на Зарубежном ХАБе (или напрямую в бота):${NC}"
    echo -e "    IP:          ${CYAN}${my_ip}${NC}"
    echo -e "    Порт:        ${CYAN}443${NC}"
    echo -e "    Домен (SNI): ${CYAN}${domain}${NC}"
    echo -e "    Bridge UUID: ${YELLOW}${t_uuid}${NC}"
    echo ""
    echo -e "  ${BOLD}Для Telegram-бота (/admin):${NC}"
    echo -e "    URL API:     ${CYAN}${api_url}${NC}"
    echo -e "    Токен:       ${YELLOW}${api_key}${NC}"
    echo ""
}

exit_node_menu() {
    check_root
    init_state_dir
    while true; do
        clear
        local domain abuse mod_cnt
        domain="$(get_state_val "domain" "-")"
        abuse="$(get_state_val "abuse_protection" "disabled")"
        mod_cnt="$(count_enabled_modules)"

        echo -e "${BOLD}${BLUE}═════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}  🚀 УПРАВЛЕНИЕ РОЛЬЮ: ВЫХОДНАЯ НОДА${NC}"
        echo -e "${BOLD}${BLUE}═════════════════════════════════════════════════════════════${NC}"
        echo -e "  Домен (SNI):  ${CYAN}${domain}${NC}   |   Порт: ${CYAN}443 (VLESS TLS)${NC}"
        echo -e "  Anti-Abuse:   ${CYAN}${abuse}${NC}\n"

        echo -e "  ${BOLD}[1]${NC} Показать данные подключения (для Зарубежного ХАБа / бота)"
        echo -e "  ${BOLD}[2]${NC} Переприменить SSL, Xray и Anti-Abuse"
        echo -e "  ${BOLD}[B]${NC} Сменить роль$([[ "${mod_cnt:-0}" -gt 0 ]] && echo " ${DIM:-}(сначала удалите модули)${NC}" || true)"
        echo -e "  ${BOLD}[0]${NC} Назад в главное меню"
        echo ""

        local choice=""
        read -rp "Выберите пункт: " choice || true
        case "$choice" in
            1) exit_node_show_credentials; read -rp "Нажмите Enter..." || true ;;
            2) apply_v2_hub_configuration || true; read -rp "Нажмите Enter..." || true ;;
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
