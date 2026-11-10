#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE - Модуль контроля лимита сетевого трафика (lib/traffic_limit.sh)
# =============================================================================

TRAFFIC_LIMIT_CONFIG="${STATE_DIR:-/etc/just1knode}/traffic_limit.json"
TRAFFIC_EXCEEDED_FLAG="${STATE_DIR:-/etc/just1knode}/traffic_limit_exceeded"
TRAFFIC_LEGACY_CUTOFF_FLAG="${STATE_DIR:-/etc/just1knode}/traffic_cutoff.active"

ensure_vnstat() {
    if ! command -v vnstat >/dev/null 2>&1; then
        info "vnstat не обнаружен, выполняется автоматическая установка..."
        if command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null 2>&1 || true
            apt-get install -y vnstat >/dev/null 2>&1 || true
            if command -v systemctl >/dev/null 2>&1; then
                systemctl enable --now vnstat >/dev/null 2>&1 || true
            fi
        else
            warn "apt-get не найден, не удалось автоматически установить vnstat."
            return 1
        fi
    fi
    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl is-active --quiet vnstat 2>/dev/null; then
            systemctl enable --now vnstat 2>/dev/null || true
        fi
    fi
    return 0
}

apply_vnstat_reset_day() {
    local reset_day="${1:-1}"
    if [[ -f /etc/vnstat.conf ]]; then
        if grep -q "^[# ]*MonthRotate" /etc/vnstat.conf 2>/dev/null; then
            sed -i -E "s/^[# ]*MonthRotate .*/MonthRotate ${reset_day}/" /etc/vnstat.conf 2>/dev/null || true
        else
            echo "MonthRotate ${reset_day}" >> /etc/vnstat.conf 2>/dev/null || true
        fi
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart vnstat 2>/dev/null || true
        fi
    fi
}

get_traffic_limit_val() {
    local key="$1"
    local default_val="${2:-}"
    if [[ -f "$TRAFFIC_LIMIT_CONFIG" ]]; then
        python3 -c "
import json, sys
try:
    with open('$TRAFFIC_LIMIT_CONFIG', 'r', encoding='utf-8') as f:
        data = json.load(f)
        val = data.get('$key')
        print(val if val is not None else '$default_val')
except Exception:
    print('$default_val')
" 2>/dev/null || echo "$default_val"
    else
        echo "$default_val"
    fi
}

save_traffic_limit_config() {
    local limit_gb="$1"
    local reset_day="${2:-1}"
    python3 -c "
import json, os, sys, tempfile
cfg = '$TRAFFIC_LIMIT_CONFIG'
d = os.path.dirname(os.path.abspath(cfg))
os.makedirs(d, exist_ok=True)
data = {'limit_gb': int('$limit_gb'), 'reset_day': int('$reset_day')}
open_flags = os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0)
t_fd, t_path = tempfile.mkstemp(dir=d, suffix='.tmp')
try:
    if hasattr(os, 'fchmod'):
        os.fchmod(t_fd, 0o640)
    with os.fdopen(t_fd, 'w', encoding='utf-8') as fp:
        json.dump(data, fp, indent=2)
        fp.flush()
    os.replace(t_path, cfg)
except Exception:
    if os.path.exists(t_path):
        os.remove(t_path)
    raise
"
}

get_monthly_traffic_bytes() {
    # Uses vnstat --json m 1 for accurate persistent accounting across reboots
    ensure_vnstat >/dev/null 2>&1 || true
    python3 -c "
import json, subprocess, sys
total = 0
try:
    res = subprocess.run(['vnstat', '--json', 'm', '1'], capture_output=True, text=True, timeout=5)
    if res.returncode == 0 and res.stdout.strip():
        data = json.loads(res.stdout)
        for iface in data.get('interfaces', []):
            name = iface.get('name', '')
            if name == 'lo' or name.startswith(('docker', 'veth', 'br-', 'wg', 'tun', 'tap')):
                continue
            months = iface.get('traffic', {}).get('month', [])
            if months:
                # Chronologically latest month entry
                m = max(months, key=lambda x: (x.get('date', {}).get('year', 0), x.get('date', {}).get('month', 0), x.get('id', 0)))
                total += int(m.get('rx', 0)) + int(m.get('tx', 0))
except Exception:
    pass
print(total)
" 2>/dev/null || echo "0"
}

deploy_traffic_limit_timer() {
    local systemd_dir="${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
    mkdir -p "$systemd_dir"

    local bin_path="/usr/local/bin/just1knode"
    if [[ ! -x "$bin_path" ]]; then
        bin_path="${SCRIPT_DIR:-/opt/just1knode}/just1knode.sh"
    fi

    # CRITICAL: DO NOT create drop-in in xray.service.d!
    rm -f "${systemd_dir}/xray.service.d/traffic-cutoff.conf" 2>/dev/null || true

    cat > "${systemd_dir}/just1knode-traffic-limit.service" <<EOF
[Unit]
Description=Just1kNode Traffic Limit Watchdog Service
After=network.target

[Service]
Type=oneshot
ExecStart=${bin_path} limit check
StandardOutput=journal
StandardError=journal
EOF

    cat > "${systemd_dir}/just1knode-traffic-limit.timer" <<EOF
[Unit]
Description=Just1kNode Traffic Limit Watchdog Timer (every 15 min)

[Timer]
OnBootSec=3min
OnUnitActiveSec=15min
Unit=just1knode-traffic-limit.service

[Install]
WantedBy=timers.target
EOF

    # Clean up old timer name if present
    rm -f "${systemd_dir}/just1knode-traffic.service" "${systemd_dir}/just1knode-traffic.timer" 2>/dev/null || true

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable --now just1knode-traffic-limit.timer 2>/dev/null || true
        if ! systemctl is-active --quiet just1knode-traffic-limit.timer 2>/dev/null; then
            warn "Не удалось подтвердить активность just1knode-traffic-limit.timer через systemctl."
        fi
    fi
}

remove_traffic_limit_timer() {
    local systemd_dir="${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop just1knode-traffic-limit.timer just1knode-traffic-limit.service 2>/dev/null || true
        systemctl disable just1knode-traffic-limit.timer 2>/dev/null || true
        systemctl stop just1knode-traffic.timer just1knode-traffic.service 2>/dev/null || true
        systemctl disable just1knode-traffic.timer 2>/dev/null || true
    fi
    rm -f "${systemd_dir}/just1knode-traffic-limit.service" "${systemd_dir}/just1knode-traffic-limit.timer" 2>/dev/null || true
    rm -f "${systemd_dir}/just1knode-traffic.service" "${systemd_dir}/just1knode-traffic.timer" 2>/dev/null || true
    rm -f "${systemd_dir}/xray.service.d/traffic-cutoff.conf" 2>/dev/null || true
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
    fi
}

check_traffic_limit() {
    if [[ ! -f "$TRAFFIC_LIMIT_CONFIG" ]]; then
        return 0
    fi

    local limit_gb reset_day
    limit_gb="$(get_traffic_limit_val "limit_gb" "0")"
    reset_day="$(get_traffic_limit_val "reset_day" "1")"

    if [[ "$limit_gb" -le 0 ]]; then
        return 0
    fi

    local total_bytes
    total_bytes="$(get_monthly_traffic_bytes)"

    local limit_bytes
    limit_bytes="$(python3 -c "print(int('$limit_gb') * (1024 ** 3))")"

    local is_exceeded
    is_exceeded="$(python3 -c "print(1 if int('$total_bytes') >= int('$limit_bytes') else 0)")"

    if [[ "$is_exceeded" -eq 1 ]]; then
        warn "Лимит хостинга исчерпан (${limit_gb} ГБ). Остановка службы Xray..."
        touch "$TRAFFIC_EXCEEDED_FLAG" 2>/dev/null || true
        touch "$TRAFFIC_LEGACY_CUTOFF_FLAG" 2>/dev/null || true
        if command -v systemctl >/dev/null 2>&1; then
            systemctl stop xray 2>/dev/null || true
        fi
        set_state_val "traffic_cutoff_triggered" "true" 2>/dev/null || true
    else
        # Traffic is below limit
        if [[ -f "$TRAFFIC_EXCEEDED_FLAG" || -f "$TRAFFIC_LEGACY_CUTOFF_FLAG" ]]; then
            warn "Лимит трафика восстановлен / наступил новый биллинговый цикл. Запуск Xray..."
            rm -f "$TRAFFIC_EXCEEDED_FLAG" "$TRAFFIC_LEGACY_CUTOFF_FLAG" 2>/dev/null || true
            set_state_val "traffic_cutoff_triggered" "false" 2>/dev/null || true
            if command -v systemctl >/dev/null 2>&1; then
                systemctl start xray 2>/dev/null || true
            fi
            if declare -f ensure_xray_api_healthy >/dev/null 2>&1; then
                ensure_xray_api_healthy || true
            fi
        fi
    fi
    return 0
}

set_traffic_limit() {
    local limit_gb="${1:-}"
    local reset_day="${2:-}"

    if [[ -z "$limit_gb" || ! "$limit_gb" =~ ^[1-9][0-9]*$ ]]; then
        error "Укажите корректный лимит трафика в ГБ (целое положительное число, например: 3000)."
    fi

    if [[ -z "$reset_day" ]]; then
        reset_day="$(get_traffic_limit_val "reset_day" "")"
        reset_day="${reset_day:-$(get_state_val "traffic_reset_day" "1")}"
    fi

    if [[ ! "$reset_day" =~ ^[1-9][0-9]*$ ]] || (( reset_day < 1 || reset_day > 31 )); then
        warn "Некорректный день сброса: '$reset_day'. Установлено значение по умолчанию: 1-е число."
        reset_day=1
    fi

    ensure_vnstat >/dev/null 2>&1 || true
    apply_vnstat_reset_day "$reset_day"
    save_traffic_limit_config "$limit_gb" "$reset_day"

    set_state_val "traffic_limit_status" "enabled" 2>/dev/null || true
    set_state_val "traffic_limit_gb" "$limit_gb" 2>/dev/null || true
    set_state_val "traffic_reset_day" "$reset_day" 2>/dev/null || true

    deploy_traffic_limit_timer
    check_traffic_limit

    log "Лимит трафика успешно установлен: ${BOLD}${limit_gb} ГБ${NC} (сброс: ${reset_day}-го числа)."
    log "Фоновый таймер (just1knode-traffic-limit.timer) активен с интервалом 15 минут."
}

set_traffic_reset_day() {
    local reset_day="${1:-1}"
    if [[ ! "$reset_day" =~ ^[1-9][0-9]*$ ]] || (( reset_day < 1 || reset_day > 31 )); then
        error "Некорректный день сброса (укажите число от 1 до 31)."
    fi

    ensure_vnstat >/dev/null 2>&1 || true

    local limit_gb
    limit_gb="$(get_traffic_limit_val "limit_gb" "")"
    if [[ -z "$limit_gb" || "$limit_gb" -le 0 ]]; then
        limit_gb="$(get_state_val "traffic_limit_gb" "0")"
    fi

    if [[ -n "$limit_gb" && "$limit_gb" -gt 0 ]]; then
        save_traffic_limit_config "$limit_gb" "$reset_day"
    fi

    apply_vnstat_reset_day "$reset_day"
    set_state_val "traffic_reset_day" "$reset_day" 2>/dev/null || true

    log "День сброса биллинга изменен на: ${BOLD}${reset_day}-е число${NC}."
    check_traffic_limit
}

disable_traffic_limit() {
    rm -f "$TRAFFIC_LIMIT_CONFIG" 2>/dev/null || true
    set_state_val "traffic_limit_status" "disabled" 2>/dev/null || true

    remove_traffic_limit_timer

    local need_start=0
    if [[ -f "$TRAFFIC_EXCEEDED_FLAG" || -f "$TRAFFIC_LEGACY_CUTOFF_FLAG" || "$(get_state_val "traffic_cutoff_triggered" "false")" == "true" ]]; then
        need_start=1
    fi

    rm -f "$TRAFFIC_EXCEEDED_FLAG" "$TRAFFIC_LEGACY_CUTOFF_FLAG" 2>/dev/null || true
    set_state_val "traffic_cutoff_triggered" "false" 2>/dev/null || true

    if command -v systemctl >/dev/null 2>&1; then
        if [[ "$need_start" -eq 1 ]] || ! systemctl is-active --quiet xray 2>/dev/null; then
            systemctl start xray 2>/dev/null || true
            log "Служба Xray автоматически запущена после снятия лимита."
        fi
    fi

    log "Лимит трафика отключен. Сервер переведен в безлимитный режим."
}

show_traffic_limit_status() {
    local limit_gb reset_day is_configured=0
    if [[ -f "$TRAFFIC_LIMIT_CONFIG" ]]; then
        limit_gb="$(get_traffic_limit_val "limit_gb" "0")"
        reset_day="$(get_traffic_limit_val "reset_day" "1")"
        if [[ "$limit_gb" -gt 0 ]]; then
            is_configured=1
        fi
    fi

    local total_bytes
    total_bytes="$(get_monthly_traffic_bytes)"

    title "СТАТУС ЛИМИТА ТРАФИКА"

    if [[ "$is_configured" -eq 1 ]]; then
        local calc_info
        calc_info="$(python3 -c "
total = int('${total_bytes:-0}')
lim = int('$limit_gb') * (1024 ** 3)
acc_gb = float(total) / (1024 ** 3)
pct = (float(total) / float(lim) * 100) if lim > 0 else 0.0
print(f'{acc_gb:.1f}|{pct:.1f}')
" 2>/dev/null || echo "0.0|0.0")"
        IFS='|' read -r acc_gb pct <<< "$calc_info"

        local status_str="${GREEN}🟢 Включен${NC}"
        if [[ -f "$TRAFFIC_EXCEEDED_FLAG" || -f "$TRAFFIC_LEGACY_CUTOFF_FLAG" ]]; then
            status_str="${RED}🚨 ЛИМИТ ИСЧЕРПАН (Xray остановлен)${NC}"
        fi

        echo -e "  Статус:                ${BOLD}${status_str}"
        echo -e "  Расход за месяц:       ${BOLD}${CYAN}${acc_gb} / ${limit_gb} ГБ (${pct}%)${NC}"
        echo -e "  День сброса биллинга:  ${BOLD}${reset_day}-е число${NC}"
        local timer_status="не активен"
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet just1knode-traffic-limit.timer 2>/dev/null; then
            timer_status="активен (15 мин)"
        fi
        echo -e "  Фоновый таймер:        ${timer_status}"
    else
        local acc_gb
        acc_gb="$(python3 -c "print(f'{(float(\"${total_bytes:-0}\") / (1024 ** 3)):.1f}')" 2>/dev/null || echo "0.0")"
        local r_day
        r_day="$(get_traffic_limit_val "reset_day" "")"
        r_day="${r_day:-$(get_state_val "traffic_reset_day" "1")}"
        echo -e "  Статус:                ${BOLD}${YELLOW}⚪ Отключен (Безлимитный режим)${NC}"
        echo -e "  Расход за месяц:       ${BOLD}${acc_gb} ГБ (безлимитно)${NC}"
        echo -e "  День сброса биллинга:  ${BOLD}${r_day}-е число${NC}"
    fi
}

manage_traffic_limit_menu() {
    title "УПРАВЛЕНИЕ ЛИМИТОМ ТРАФИКА"
    check_root
    show_traffic_limit_status
    echo ""
    echo -e "  ${BOLD}[1]${NC} ⚙️  Установить / изменить лимит трафика"
    echo -e "  ${BOLD}[2]${NC} 📅 Изменить день сброса биллинга"
    echo -e "  ${BOLD}[3]${NC} ⚪ Отключить лимит трафика"
    echo -e "  ${BOLD}[0]${NC} ⬅️  Назад"
    echo ""
    read -rp "Выберите действие [0-3]: " t_act
    case "$t_act" in
        1)
            local cur_lim cur_day
            cur_lim="$(get_traffic_limit_val "limit_gb" "")"
            cur_lim="${cur_lim:-$(get_state_val "traffic_limit_gb" "")}"
            cur_day="$(get_traffic_limit_val "reset_day" "")"
            cur_day="${cur_day:-$(get_state_val "traffic_reset_day" "1")}"
            local def_lim="${cur_lim:-3000}"
            read -rp "Введите лимит трафика в ГБ (например: 3000) [по умолчанию: ${def_lim}]: " lim_in || true
            lim_in="${lim_in:-$def_lim}"
            lim_in="$(echo "$lim_in" | tr -d '[:space:]')"
            if [[ -z "$lim_in" || ! "$lim_in" =~ ^[1-9][0-9]*$ ]]; then
                warn "Некорректный лимит трафика."
                return
            fi
            read -rp "День месяца сброса биллинга (1-31) [по умолчанию: ${cur_day}]: " day_in || true
            day_in="${day_in:-$cur_day}"
            day_in="$(echo "$day_in" | tr -d '[:space:]')"
            set_traffic_limit "$lim_in" "$day_in"
            ;;
        2)
            local cur_day
            cur_day="$(get_traffic_limit_val "reset_day" "")"
            cur_day="${cur_day:-$(get_state_val "traffic_reset_day" "1")}"
            read -rp "День месяца сброса биллинга (1-31) [текущий: ${cur_day}]: " day_in || true
            day_in="${day_in:-$cur_day}"
            day_in="$(echo "$day_in" | tr -d '[:space:]')"
            if [[ ! "$day_in" =~ ^[1-9][0-9]*$ ]] || (( day_in < 1 || day_in > 31 )); then
                warn "День сброса должен быть от 1 до 31."
                return
            fi
            set_traffic_reset_day "$day_in"
            ;;
        3)
            disable_traffic_limit
            ;;
        0|*)
            return
            ;;
    esac
}

# Backward compatibility aliases
remove_traffic_watchdog_timer() {
    remove_traffic_limit_timer "$@"
}
deploy_traffic_watchdog_timer() {
    deploy_traffic_limit_timer "$@"
}
