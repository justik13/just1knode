#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE - Модуль сетевой фильтрации и защиты Shield (lib/shield.sh)
# L4 защита VLESS/узлов от сканеров РКН (INPUT DROP) и утечек VK/Max (OUTPUT/FORWARD REJECT)
# =============================================================================

SHIELD_RULES_REPO_RAW="${SHIELD_RULES_REPO_RAW:-https://raw.githubusercontent.com/justik13/shield-rules/main}"
SHIELD_DIR="${STATE_DIR:-/etc/just1knode}/shield"
SHIELD_RKN_CACHE="${SHIELD_DIR}/rkn.txt"
SHIELD_VK_CACHE="${SHIELD_DIR}/vk.txt"
SHIELD_SYSTEMD_SERVICE="/etc/systemd/system/just1knode-shield.service"
SHIELD_SYSTEMD_UPDATE_SERVICE="/etc/systemd/system/just1knode-shield-update.service"
SHIELD_SYSTEMD_TIMER="/etc/systemd/system/just1knode-shield.timer"
SHIELD_UFW_AFTER_INIT="/etc/ufw/after.init"

# Проверка, является ли узел Origin-сервером (РФ)
is_shield_origin_node() {
    local role is_orig
    role="$(get_state_val "role" "unconfigured" 2>/dev/null || echo "unconfigured")"
    is_orig="$(get_state_val "is_origin" "0" 2>/dev/null || echo "0")"
    if [[ "$role" == "origin" || "$is_orig" == "1" ]]; then
        return 0
    fi
    return 1
}

# Установка системных зависимостей для Shield (ipset, iptables)
install_shield_deps() {
    local need_install=0
    if ! command -v ipset >/dev/null 2>&1; then
        need_install=1
    fi
    if ! command -v iptables >/dev/null 2>&1; then
        need_install=1
    fi

    if [[ $need_install -eq 1 ]]; then
        log "Установка ipset и iptables для фильтрации L4..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq ipset iptables
    fi

    # Автозагрузка модулей ядра ipset при старте ОС
    modprobe ip_set 2>/dev/null || true
    modprobe ip_set_hash_net 2>/dev/null || true
    modprobe xt_set 2>/dev/null || true

    mkdir -p /etc/modules-load.d 2>/dev/null || true
    if [[ ! -f /etc/modules-load.d/just1knode-shield.conf ]]; then
        printf "ip_set\nip_set_hash_net\nxt_set\n" > /etc/modules-load.d/just1knode-shield.conf 2>/dev/null || true
    fi
}

# Валидация и санитизация списка CIDR с защитой от самоблокировки (Fail-Safe)
sanitize_shield_list() {
    local in_file="$1"
    local out_file="$2"
    local my_ip bot_ip origin_ip

    my_ip="$(get_public_ipv4 2>/dev/null || echo "")"
    bot_ip="$(get_state_val "bot_ip" "" 2>/dev/null || echo "")"
    origin_ip="$(get_state_val "origin_ip" "" 2>/dev/null || echo "")"

    python3 -c "
import ipaddress, sys

in_path = sys.argv[1]
out_path = sys.argv[2]
raw_excludes = [x.strip() for x in sys.argv[3:] if x.strip() and x.strip() not in ('-', 'any', 'none')]

excluded_networks = [
    ipaddress.ip_network('10.0.0.0/8'),
    ipaddress.ip_network('172.16.0.0/12'),
    ipaddress.ip_network('192.168.0.0/16'),
    ipaddress.ip_network('127.0.0.0/8'),
    ipaddress.ip_network('169.254.0.0/16'),
    ipaddress.ip_network('224.0.0.0/4'),
    ipaddress.ip_network('0.0.0.0/8'),
]

for excl in raw_excludes:
    try:
        if '/' in excl:
            excluded_networks.append(ipaddress.ip_network(excl, strict=False))
        else:
            excluded_networks.append(ipaddress.ip_network(f'{excl}/32'))
    except Exception:
        pass

valid_cidrs = []
with open(in_path, 'r', encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        try:
            net = ipaddress.ip_network(line, strict=False)
            if net.version != 4:
                continue
            is_overlap = False
            for ex in excluded_networks:
                if net.overlaps(ex) or net.subnet_of(ex) or ex.subnet_of(net):
                    is_overlap = True
                    break
            if not is_overlap:
                valid_cidrs.append(str(net))
        except Exception:
            continue

if len(valid_cidrs) < 10:
    sys.exit(1)

with open(out_path, 'w', encoding='utf-8') as f:
    for cidr in valid_cidrs:
        f.write(f'{cidr}\n')
" "$in_file" "$out_file" "$my_ip" "$bot_ip" "$origin_ip"
}

# Загрузка и обновление списков правил Shield из репозитория
shield_update() {
    if is_shield_origin_node; then
        log "Shield: Узел настроен как Origin (РФ). Фильтрация Shield не применяется на Origin сервере."
        return 0
    fi

    log "Загрузка и обновление списков сетевой фильтрации Shield..."
    install_shield_deps
    if ! command -v ipset >/dev/null 2>&1 || ! command -v iptables >/dev/null 2>&1; then
        error "Ошибка: ipset или iptables не установлены в системе."
        return 1
    fi
    mkdir -p "$SHIELD_DIR"

    local tmp_rkn_raw tmp_vk_raw tmp_rkn_clean tmp_vk_clean
    tmp_rkn_raw="$(mktemp /tmp/shield_rkn_raw.XXXXXX 2>/dev/null || mktemp)"
    tmp_vk_raw="$(mktemp /tmp/shield_vk_raw.XXXXXX 2>/dev/null || mktemp)"
    tmp_rkn_clean="$(mktemp /tmp/shield_rkn_clean.XXXXXX 2>/dev/null || mktemp)"
    tmp_vk_clean="$(mktemp /tmp/shield_vk_clean.XXXXXX 2>/dev/null || mktemp)"

    local rkn_url="${SHIELD_RULES_REPO_RAW}/rkn.txt"
    local vk_url="${SHIELD_RULES_REPO_RAW}/vk.txt"
    local dl_err=0

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 30 "$rkn_url" -o "$tmp_rkn_raw" || dl_err=$((dl_err + 1))
        curl -fsSL --connect-timeout 10 --max-time 30 "$vk_url" -o "$tmp_vk_raw" || dl_err=$((dl_err + 2))
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=30 --tries=2 -O "$tmp_rkn_raw" "$rkn_url" || dl_err=$((dl_err + 1))
        wget -q --timeout=30 --tries=2 -O "$tmp_vk_raw" "$vk_url" || dl_err=$((dl_err + 2))
    else
        dl_err=3
    fi

    if [[ $dl_err -ne 0 ]]; then
        rm -f "$tmp_rkn_raw" "$tmp_vk_raw" "$tmp_rkn_clean" "$tmp_vk_clean"
        if [[ -f "$SHIELD_RKN_CACHE" && -f "$SHIELD_VK_CACHE" ]]; then
            warn "Не удалось загрузить списки Shield с GitHub (ошибка сети/таймаут). Используется локальный кэш правил."
            shield_apply_ipsets_and_rules
            return 0
        else
            error "Ошибка: Не удалось загрузить списки Shield и локальный кэш отсутствует."
            return 1
        fi
    fi

    # Валидация и санитизация
    if ! sanitize_shield_list "$tmp_rkn_raw" "$tmp_rkn_clean"; then
        rm -f "$tmp_rkn_raw" "$tmp_vk_raw" "$tmp_rkn_clean" "$tmp_vk_clean"
        error "Ошибка валидации списка RKN (файл поврежден или содержит менее 10 валидных CIDR)."
        return 1
    fi

    if ! sanitize_shield_list "$tmp_vk_raw" "$tmp_vk_clean"; then
        rm -f "$tmp_rkn_raw" "$tmp_vk_raw" "$tmp_rkn_clean" "$tmp_vk_clean"
        error "Ошибка валидации списка VK (файл поврежден или содержит менее 10 валидных CIDR)."
        return 1
    fi

    mv -f "$tmp_rkn_clean" "$SHIELD_RKN_CACHE"
    mv -f "$tmp_vk_clean" "$SHIELD_VK_CACHE"
    rm -f "$tmp_rkn_raw" "$tmp_vk_raw"

    shield_apply_ipsets_and_rules
    set_state_val "shield_updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    log "✔ Списки сетевой фильтрации Shield успешно обновлены и применены в ядре."
    return 0
}

# Применение ipset наборов и правил iptables (INPUT DROP и OUTPUT/FORWARD REJECT)
shield_apply_ipsets_and_rules() {
    if is_shield_origin_node; then
        return 0
    fi

    install_shield_deps
    if ! command -v ipset >/dev/null 2>&1 || ! command -v iptables >/dev/null 2>&1; then
        error "Ошибка: ipset или iptables не установлены в системе."
        return 1
    fi

    if [[ ! -f "$SHIELD_RKN_CACHE" || ! -f "$SHIELD_VK_CACHE" ]]; then
        shield_update
        return $?
    fi

    # 1. Атомарное обновление ipset just1k_rkn_in через временный набор (Zero-Downtime)
    ipset create just1k_rkn_tmp hash:net family inet hashsize 1024 maxelem 65536 -exist
    ipset flush just1k_rkn_tmp
    {
        echo "create just1k_rkn_tmp hash:net family inet hashsize 1024 maxelem 65536 -exist"
        echo "flush just1k_rkn_tmp"
        sed -E '/^[[:space:]]*(#|$)/d; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^/add just1k_rkn_tmp /; s/$/ -exist/' "$SHIELD_RKN_CACHE"
    } | ipset restore 2>/dev/null || true

    ipset create just1k_rkn_in hash:net family inet hashsize 1024 maxelem 65536 -exist
    ipset swap just1k_rkn_tmp just1k_rkn_in 2>/dev/null || true
    ipset destroy just1k_rkn_tmp 2>/dev/null || true

    # 2. Атомарное обновление ipset just1k_vk_out через временный набор
    ipset create just1k_vk_tmp hash:net family inet hashsize 1024 maxelem 65536 -exist
    ipset flush just1k_vk_tmp
    {
        echo "create just1k_vk_tmp hash:net family inet hashsize 1024 maxelem 65536 -exist"
        echo "flush just1k_vk_tmp"
        sed -E '/^[[:space:]]*(#|$)/d; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^/add just1k_vk_tmp /; s/$/ -exist/' "$SHIELD_VK_CACHE"
    } | ipset restore 2>/dev/null || true

    ipset create just1k_vk_out hash:net family inet hashsize 1024 maxelem 65536 -exist
    ipset swap just1k_vk_tmp just1k_vk_out 2>/dev/null || true
    ipset destroy just1k_vk_tmp 2>/dev/null || true

    # 3. Применение правил в INPUT (блокировка сканеров РКН со стадии TCP SYN)
    # Гарантия разрешения loopback и установленных соединений до дропа
    if ! iptables -C INPUT -i lo -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 1 -i lo -j ACCEPT 2>/dev/null || true
    fi
    if ! iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 2 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    fi
    if ! iptables -C INPUT -m set --match-set just1k_rkn_in src -j DROP 2>/dev/null; then
        iptables -I INPUT 3 -m set --match-set just1k_rkn_in src -j DROP 2>/dev/null || true
    fi

    # 4. Применение правил в OUTPUT (блокировка утечек трафика с хоста)
    if ! iptables -C OUTPUT -m set --match-set just1k_vk_out dst -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null; then
        iptables -I OUTPUT 1 -m set --match-set just1k_vk_out dst -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null || true
    fi
    if ! iptables -C OUTPUT -m set --match-set just1k_vk_out dst -p udp -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; then
        iptables -I OUTPUT 2 -m set --match-set just1k_vk_out dst -p udp -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
    fi

    # 5. Применение правил в FORWARD (блокировка утечек клиентского трафика туннелей)
    if ! iptables -C FORWARD -m set --match-set just1k_vk_out dst -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null; then
        iptables -I FORWARD 1 -m set --match-set just1k_vk_out dst -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null || true
    fi
    if ! iptables -C FORWARD -m set --match-set just1k_vk_out dst -p udp -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; then
        iptables -I FORWARD 2 -m set --match-set just1k_vk_out dst -p udp -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
    fi

    # 6. Применение правил в DOCKER-USER при наличии Docker
    if iptables -L DOCKER-USER >/dev/null 2>&1; then
        if ! iptables -C DOCKER-USER -m set --match-set just1k_vk_out dst -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null; then
            iptables -I DOCKER-USER 1 -m set --match-set just1k_vk_out dst -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null || true
        fi
        if ! iptables -C DOCKER-USER -m set --match-set just1k_vk_out dst -p udp -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; then
            iptables -I DOCKER-USER 2 -m set --match-set just1k_vk_out dst -p udp -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
        fi
    fi

    set_state_val "shield_status" "active"
    return 0
}

# Быстрое восстановление правил (при старте системы или перезапуске фаервола)
shield_restore() {
    if is_shield_origin_node; then
        return 0
    fi

    if [[ -f "$SHIELD_RKN_CACHE" && -f "$SHIELD_VK_CACHE" ]]; then
        shield_apply_ipsets_and_rules
    else
        shield_update
    fi
}

# Развертывание systemd службы и таймера для автозапуска и ежедневного обновления правил
deploy_shield_systemd_timer() {
    local bin_path="${INSTALL_DIR:-/opt/just1knode}/just1knode.sh"
    if [[ ! -f "$bin_path" ]]; then
        bin_path="/usr/local/bin/just1knode"
    fi

    # 1. Служба восстановления правил из кэша при старте ОС
    cat << EOF > "$SHIELD_SYSTEMD_SERVICE"
[Unit]
Description=Just1kNode Shield Protection (L4 RKN filter and leak prevention)
DefaultDependencies=no
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${bin_path} shield restore

[Install]
WantedBy=multi-user.target
EOF

    # 2. Служба обновления правил из сети (вызывается таймером)
    cat << EOF > "$SHIELD_SYSTEMD_UPDATE_SERVICE"
[Unit]
Description=Just1kNode Shield Rules Daily Update Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${bin_path} shield update
EOF

    # 3. Таймер ежедневного обновления (в 04:30 со случайной задержкой до 30 мин)
    cat << EOF > "$SHIELD_SYSTEMD_TIMER"
[Unit]
Description=Just1kNode Shield Rules Daily Update Timer

[Timer]
Unit=just1knode-shield-update.service
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now just1knode-shield.service 2>/dev/null || true
    systemctl enable --now just1knode-shield.timer 2>/dev/null || true
}

# Интеграция вызова Shield в /etc/ufw/after.init при перезагрузке UFW
sync_ufw_after_init_shield() {
    local after_init="$SHIELD_UFW_AFTER_INIT"
    local bin_path="${INSTALL_DIR:-/opt/just1knode}/just1knode.sh"
    if [[ ! -f "$bin_path" ]]; then
        bin_path="/usr/local/bin/just1knode"
    fi

    if [[ ! -f "$after_init" ]]; then
        cat << 'EOF' > "$after_init"
#!/bin/sh
# /etc/ufw/after.init
EOF
    fi

    sed -i '/# START JUST1KNODE SHIELD HOOK/,/# END JUST1KNODE SHIELD HOOK/d' "$after_init" 2>/dev/null || true

    cat << EOF >> "$after_init"
# START JUST1KNODE SHIELD HOOK
case "\$1" in
start)
    $bin_path shield restore >/dev/null 2>&1 || true
    ;;
stop)
    ;;
status)
    ;;
esac
# END JUST1KNODE SHIELD HOOK
EOF
    chmod +x "$after_init" 2>/dev/null || true
}

# Полная установка и активация Shield
shield_install() {
    title "НАСТРОЙКА СЕТЕВОЙ ЗАЩИТЫ SHIELD (L4 DROP & ANTI-LEAK)"
    check_root
    init_state_dir

    if is_shield_origin_node; then
        warn "Shield: Данный узел является Origin (РФ). Фильтрация Shield предназначена строго для зарубежных узлов."
        return 0
    fi

    install_shield_deps
    if ! command -v ipset >/dev/null 2>&1 || ! command -v iptables >/dev/null 2>&1; then
        error "Ошибка: ipset или iptables не установлены в системе."
        return 1
    fi
    shield_update || return 1
    deploy_shield_systemd_timer
    sync_ufw_after_init_shield

    log "✔ Сетевая защита Shield успешно установлена, активирована и зарегистрирована в автозапуске."
    return 0
}

# Проверка активности и целостности правил Shield (для doctor)
check_shield_rules() {
    command -v ipset >/dev/null 2>&1 || return 1
    command -v iptables >/dev/null 2>&1 || return 1

    ipset list just1k_rkn_in >/dev/null 2>&1 || return 1
    ipset list just1k_vk_out >/dev/null 2>&1 || return 1

    iptables -C INPUT -m set --match-set just1k_rkn_in src -j DROP 2>/dev/null || return 1
    iptables -C OUTPUT -m set --match-set just1k_vk_out dst -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null || return 1
    iptables -C FORWARD -m set --match-set just1k_vk_out dst -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null || return 1

    return 0
}

# Удаление сетевой защиты Shield
shield_remove() {
    title "ОТКЛЮЧЕНИЕ СЕТЕВОЙ ЗАЩИТЫ SHIELD"
    check_root

    log "Удаление правил Shield из цепочек iptables..."
    while iptables -D INPUT -m set --match-set just1k_rkn_in src -j DROP 2>/dev/null; do :; done
    while iptables -D OUTPUT -m set --match-set just1k_vk_out dst -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null; do :; done
    while iptables -D OUTPUT -m set --match-set just1k_vk_out dst -p udp -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; do :; done
    while iptables -D FORWARD -m set --match-set just1k_vk_out dst -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null; do :; done
    while iptables -D FORWARD -m set --match-set just1k_vk_out dst -p udp -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; do :; done
    if iptables -L DOCKER-USER >/dev/null 2>&1; then
        while iptables -D DOCKER-USER -m set --match-set just1k_vk_out dst -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null; do :; done
        while iptables -D DOCKER-USER -m set --match-set just1k_vk_out dst -p udp -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; do :; done
    fi

    log "Удаление наборов ipset..."
    ipset destroy just1k_rkn_in 2>/dev/null || true
    ipset destroy just1k_vk_out 2>/dev/null || true
    ipset destroy just1k_rkn_tmp 2>/dev/null || true
    ipset destroy just1k_vk_tmp 2>/dev/null || true

    log "Отключение системных служб и хуков Shield..."
    systemctl disable --now just1knode-shield.timer 2>/dev/null || true
    systemctl disable --now just1knode-shield.service 2>/dev/null || true
    systemctl disable --now just1knode-shield-update.service 2>/dev/null || true
    rm -f "$SHIELD_SYSTEMD_SERVICE" "$SHIELD_SYSTEMD_UPDATE_SERVICE" "$SHIELD_SYSTEMD_TIMER" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    if [[ -f "$SHIELD_UFW_AFTER_INIT" ]]; then
        sed -i '/# START JUST1KNODE SHIELD HOOK/,/# END JUST1KNODE SHIELD HOOK/d' "$SHIELD_UFW_AFTER_INIT" 2>/dev/null || true
    fi

    rm -f /etc/modules-load.d/just1knode-shield.conf 2>/dev/null || true

    set_state_val "shield_status" "disabled"
    log "✔ Сетевая защита Shield успешно отключена."
    return 0
}

# Вывод подробного статуса Shield
shield_status() {
    title "СТАТУС СЕТЕВОЙ ЗАЩИТЫ SHIELD"
    init_state_dir

    if is_shield_origin_node; then
        info "Данный узел настроен как Origin (РФ). Shield отключен (применяется только на зарубежных узлах)."
        return 0
    fi

    local st_status st_updated
    st_status="$(get_state_val "shield_status" "disabled")"
    st_updated="$(get_state_val "shield_updated_at" "не обновлялся")"

    echo -e "  Статус Shield в state:  ${BOLD}${CYAN}${st_status}${NC}"
    echo -e "  Последнее обновление:   ${BOLD}${CYAN}${st_updated}${NC}"

    if check_shield_rules; then
        echo -e "  Целостность правил:     ${BOLD}${GREEN}✔ Активны в ядре${NC}"
    else
        echo -e "  Целостность правил:     ${BOLD}${RED}✗ Не активны или повреждены${NC}"
    fi

    if command -v ipset >/dev/null 2>&1; then
        local rkn_count vk_count
        rkn_count="$(ipset list just1k_rkn_in 2>/dev/null | grep -cE '^[0-9]' || echo "0")"
        vk_count="$(ipset list just1k_vk_out 2>/dev/null | grep -cE '^[0-9]' || echo "0")"
        echo -e "  Префиксов РКН (DROP):   ${BOLD}${YELLOW}${rkn_count}${NC}"
        echo -e "  Префиксов VK (REJECT):  ${BOLD}${YELLOW}${vk_count}${NC}"
    else
        echo -e "  Утилита ipset:          ${RED}Не установлена${NC}"
    fi

    if systemctl is-active --quiet just1knode-shield.timer 2>/dev/null; then
        echo -e "  Автообновление (timer): ${BOLD}${GREEN}● Активен${NC} (ежедневно в 04:30)"
    else
        echo -e "  Автообновление (timer): ${BOLD}${YELLOW}○ Не активен${NC}"
    fi
    echo ""
}
