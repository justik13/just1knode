#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE - Библиотека базовых утилит и функций окружения (lib/common.sh)
# =============================================================================

# Цвета терминала
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Принудительная UTF-8 локаль и режим UTF-8 в Python (PEP 540)
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

if ! declare -f get_state_val >/dev/null 2>&1; then
    _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    if [[ -f "${_lib_dir}/state.sh" ]]; then
        # shellcheck source=lib/state.sh
        source "${_lib_dir}/state.sh"
    fi
    unset _lib_dir
fi


log() {
    echo -e "${GREEN}[+]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[!] ВНИМАНИЕ:${NC} $1"
}

error() {
    echo -e "${RED}[✗] ОШИБКА:${NC} $1" >&2
    exit 1
}

info() {
    echo -e "${CYAN}[i]${NC} $1"
}

title() {
    echo -e "\n${BOLD}${BLUE}=== $1 ===${NC}\n"
}

JUST1KNODE_LOCK_FD=200
acquire_just1knode_lock() {
    local lock_dir="/run/lock/just1knode"
    mkdir -p "$lock_dir" 2>/dev/null || lock_dir="/tmp/just1knode_locks"
    mkdir -p "$lock_dir" 2>/dev/null || true
    local lock_file="${lock_dir}/just1knode.lock"
    eval "exec ${JUST1KNODE_LOCK_FD}>\"${lock_file}\""
    if command -v flock >/dev/null 2>&1; then
        if ! flock -n "$JUST1KNODE_LOCK_FD"; then
            warn "Другой процесс just1knode уже выполняется. Ожидание снятия блокировки..."
            flock "$JUST1KNODE_LOCK_FD"
        fi
    fi
}

release_just1knode_lock() {
    if command -v flock >/dev/null 2>&1; then
        flock -u "$JUST1KNODE_LOCK_FD" 2>/dev/null || true
    fi
    eval "exec ${JUST1KNODE_LOCK_FD}>&-" 2>/dev/null || true
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Скрипт должен быть запущен с правами root (используйте: sudo just1knode)"
    fi
}

get_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        *) error "Неподдерживаемая архитектура: $arch" ;;
    esac
}

install_base_deps() {
    log "Проверка и установка системных пакетов..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl wget unzip jq python3 python3-pip python3-venv python3-full ufw openssl ca-certificates 2>/dev/null || \
        apt-get install -y -qq curl wget unzip jq python3 python3-pip python3-venv ufw openssl ca-certificates
}

install_nginx_if_missing() {
    if ! command -v nginx >/dev/null 2>&1; then
        log "Установка Nginx и Certbot..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq nginx certbot python3-certbot-nginx ca-certificates
        # Отключаем дефолтный сайт сразу после установки пакета для предотвращения конфликта портов
        local def_site="${NGINX_CONF_DIR:-/etc/nginx}/sites-enabled/default"
        if [[ -f "$def_site" || -L "$def_site" ]]; then
            cp -L "$def_site" "${NGINX_CONF_DIR:-/etc/nginx}/sites-available/default.user.bak" 2>/dev/null || true
            rm -f "$def_site" 2>/dev/null || true
        fi
        systemctl enable nginx 2>/dev/null || true
        systemctl restart nginx 2>/dev/null || true
    fi
}

# Обнаружение Docker-контейнера, слушающего хостовый TCP-порт 80
detect_host_port80_container() {
    command -v docker >/dev/null 2>&1 || return 0
    local matched
    matched="$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -E '(^|[[:space:],])([0-9\.:]+|\[::\]|:::):80->[0-9]+/tcp' | head -n 1 || true)"
    if [[ -n "$matched" ]]; then
        echo "$matched" | awk -F'\t' '{print $1}'
    fi
}

# Безопасная настройка UFW с детекцией SSH
configure_safe_ufw() {
    local ports=("$@")
    if ! command -v ufw >/dev/null 2>&1; then
        apt-get install -y -qq ufw
    fi

    # Детектируем порт SSH (Zero-Lockout гарантия: живые сокеты ядра ss -> sshd -T -> sshd_config)
    local ssh_port=22
    local detected
    if command -v ss >/dev/null 2>&1; then
        detected="$(ss -tlnp 2>/dev/null | grep -E 'users:.*"sshd"' | awk '{print $4}' | rev | cut -d: -f1 | rev | grep -E '^[0-9]+$' | head -n 1 || true)"
    fi
    if [[ -z "$detected" ]] && command -v sshd >/dev/null 2>&1; then
        detected="$(sshd -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n 1 || true)"
    fi
    if [[ -z "$detected" ]]; then
        detected="$(grep -E -h "^Port " /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}' | head -n 1 || true)"
    fi
    if [[ -n "$detected" ]]; then
        ssh_port="$detected"
    fi

    if ! ufw allow "$ssh_port/tcp" >/dev/null 2>&1; then
        error "КРИТИЧЕСКАЯ ОШИБКА: Не удалось открыть SSH-порт $ssh_port/tcp в UFW! Активация фаервола отменена во избежание потери доступа."
        return 1
    fi

    # Дополнительно гарантируем открытие всех портов, на которых слушает sshd
    if command -v ss >/dev/null 2>&1; then
        while read -r extra_p; do
            if [[ -n "$extra_p" && "$extra_p" =~ ^[0-9]+$ && "$extra_p" != "$ssh_port" ]]; then
                ufw allow "$extra_p/tcp" >/dev/null 2>&1 || true
            fi
        done < <(ss -tlnp 2>/dev/null | grep -E 'users:.*"sshd"' | awk '{print $4}' | rev | cut -d: -f1 | rev | sort -u)
    fi

    for p in "${ports[@]}"; do
        ufw allow "$p" >/dev/null 2>&1 || true
    done

    # Автодетекция веб-портов 80 и 443 (защита Caddy бота и вебхуков эквайринга при ко-локации)
    local has_port80=0
    local has_port443=0
    if [[ -n "$(detect_host_port80_container 2>/dev/null || true)" ]] || (command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "just1kbot_caddy"); then
        has_port80=1
    fi
    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Ports}} {{.Names}}' 2>/dev/null | grep -qE '(:443->|just1kbot_caddy)'; then
        has_port443=1
    fi

    if [[ $has_port80 -eq 1 ]]; then
        if ! ufw status 2>/dev/null | grep -qE "(^|[[:space:]])80/tcp[[:space:]]+ALLOW"; then
            if ufw allow 80/tcp comment "http web service" >/dev/null 2>&1; then
                log "Фаервол UFW: автоматически разрешен порт 80/tcp для активного веб-сервиса (Caddy)."
            else
                warn "Предупреждение: Не удалось добавить правило UFW для порта 80/tcp."
            fi
        fi
    fi
    if [[ $has_port443 -eq 1 ]]; then
        if ! ufw status 2>/dev/null | grep -qE "(^|[[:space:]])443/tcp[[:space:]]+ALLOW"; then
            if ufw allow 443/tcp comment "https web service" >/dev/null 2>&1; then
                log "Фаервол UFW: автоматически разрешен порт 443/tcp для активного веб-сервиса (Caddy)."
            else
                warn "Предупреждение: Не удалось добавить правило UFW для порта 443/tcp."
            fi
        fi
    fi

    # Включаем UFW, если он отключен
    if ! ufw status | grep -q "Status: active"; then
        if echo "y" | ufw enable >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
            log "Фаервол UFW успешно активирован (SSH порт ${ssh_port} защищен от блокировки)."
        else
            warn "Внимание: не удалось активировать фаервол UFW."
        fi
    fi
}

# Обнаружение активных пользовательских сайтов в Nginx (для предотвращения случайного даунтайма)
detect_existing_nginx_sites() {
    local base_dir="${1:-/etc/nginx}"
    local sites_found=()
    local conf_dirs=("$base_dir/sites-enabled" "$base_dir/conf.d")

    for cdir in "${conf_dirs[@]}"; do
        [[ ! -d "$cdir" ]] && continue
        while IFS= read -r -d '' f; do
            local fname
            fname="$(basename "$f")"
            [[ "$fname" =~ ^(just1k|sub-wl|xhttp).* ]] && continue
            [[ "$fname" =~ .*\.(bak|old|tmp|disabled)$ ]] && continue

            if [[ "$fname" == "default" ]]; then
                if grep -Eq '(^|[[:space:]])server_name[[:space:]]+[^_;]' "$f" 2>/dev/null; then
                    local sname
                    sname="$(grep -E '(^|[[:space:]])server_name[[:space:]]+' "$f" 2>/dev/null | head -n1 | sed -E 's/.*server_name[[:space:]]+//; s/;.*//')"
                    sites_found+=("$fname ($sname)")
                fi
                continue
            fi

            if grep -Eq '(server_name|listen|proxy_pass)[[:space:]]+' "$f" 2>/dev/null; then
                local sname
                sname="$(grep -E '(^|[[:space:]])server_name[[:space:]]+' "$f" 2>/dev/null | head -n1 | sed -E 's/.*server_name[[:space:]]+//; s/;.*//' || echo "")"
                if [[ -n "$sname" && "$sname" != "_" ]]; then
                    sites_found+=("$fname ($sname)")
                else
                    sites_found+=("$fname")
                fi
            fi
        done < <(find "$cdir" -maxdepth 1 \( -type f -o -type l \) -print0 2>/dev/null)
    done

    if [[ ${#sites_found[@]} -gt 0 ]]; then
        printf '%s\n' "${sites_found[@]}"
        return 0
    fi
    return 1
}

validate_ipv4() {
    local ip="${1:-}"
    [[ -z "$ip" ]] && return 1
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import ipaddress, sys; ip = sys.argv[1]; addr = ipaddress.IPv4Address(ip); sys.exit(0 if not addr.is_multicast and not addr.is_unspecified and not addr.is_reserved else 1)" "$ip" 2>/dev/null
    else
        [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
        for oct in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
            (( oct < 0 || oct > 255 )) && return 1
            [[ ${#oct} -gt 1 && "$oct" =~ ^0 ]] && return 1
        done
        [[ "$ip" == "0.0.0.0" || "$ip" == "255.255.255.255" ]] && return 1
        return 0
    fi
}

check_domain_syntax() {
    local domain="${1:-}"
    [[ -z "$domain" ]] && { echo "EMPTY"; return 0; }
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import sys, re
d = sys.argv[1].strip()
if re.search(r'[\u0400-\u04FF]', d):
    print('CYRILLIC')
elif not re.match(r'^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$', d):
    print('INVALID_FQDN')
else:
    print('OK')
" "$domain" 2>/dev/null || echo "OK"
    else
        if [[ "$domain" =~ [а-яА-ЯёЁ] ]]; then
            echo "CYRILLIC"
        elif [[ ! "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
            echo "INVALID_FQDN"
        else
            echo "OK"
        fi
    fi
}

validate_ip() {
    local ip="${1:-}"
    [[ -z "$ip" ]] && return 1
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import ipaddress, sys; ip = sys.argv[1]; addr = ipaddress.ip_address(ip); sys.exit(0 if not addr.is_multicast and not addr.is_unspecified and not addr.is_reserved else 1)" "$ip" 2>/dev/null
    else
        validate_ipv4 "$ip"
    fi
}

validate_public_ipv4() {
    local ip="${1:-}"
    [[ -z "$ip" ]] && return 1
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import ipaddress, sys; ip = sys.argv[1]; addr = ipaddress.IPv4Address(ip); sys.exit(0 if addr.is_global and not addr.is_multicast and not addr.is_reserved and not addr.is_unspecified else 1)" "$ip" 2>/dev/null
    else
        [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
        local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}" o3="${BASH_REMATCH[3]}" o4="${BASH_REMATCH[4]}"
        for oct in "$o1" "$o2" "$o3" "$o4"; do
            [[ ${#oct} -gt 1 && "$oct" =~ ^0 ]] && return 1
            (( 10#$oct < 0 || 10#$oct > 255 )) && return 1
        done
        # 0.0.0.0/8 (текущая сеть)
        (( o1 == 0 )) && return 1
        # 10.0.0.0/8 (частная сеть RFC 1918)
        (( o1 == 10 )) && return 1
        # 100.64.0.0/10 (CGNAT RFC 6598)
        (( o1 == 100 && o2 >= 64 && o2 <= 127 )) && return 1
        # 127.0.0.0/8 (loopback RFC 1122)
        (( o1 == 127 )) && return 1
        # 169.254.0.0/16 (link-local RFC 3927)
        (( o1 == 169 && o2 == 254 )) && return 1
        # 172.16.0.0/12 (частная сеть RFC 1918)
        (( o1 == 172 && o2 >= 16 && o2 <= 31 )) && return 1
        # 192.0.0.0/24 (IETF RFC 6890)
        (( o1 == 192 && o2 == 0 && o3 == 0 )) && return 1
        # 192.0.2.0/24 (TEST-NET-1 RFC 5737)
        (( o1 == 192 && o2 == 0 && o3 == 2 )) && return 1
        # 192.168.0.0/16 (частная сеть RFC 1918)
        (( o1 == 192 && o2 == 168 )) && return 1
        # 198.18.0.0/15 (бенчмаркинг RFC 2544)
        (( o1 == 198 && (o2 == 18 || o2 == 19) )) && return 1
        # 198.51.100.0/24 (TEST-NET-2 RFC 5737)
        (( o1 == 198 && o2 == 51 && o3 == 100 )) && return 1
        # 203.0.113.0/24 (TEST-NET-3 RFC 5737)
        (( o1 == 203 && o2 == 0 && o3 == 113 )) && return 1
        # 224.0.0.0/4 (мультикаст) и >= 240.0.0.0/4 (резерв/broadcast)
        (( o1 >= 224 )) && return 1
        return 0
    fi
}

get_public_ipv4() {
    local ip=""
    # 1. Внешние сервисы строго по IPv4 (-4)
    ip="$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null || \
          curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null || \
          curl -4 -s --max-time 5 https://icanhazip.com 2>/dev/null || true)"
    ip="$(echo "$ip" | tr -d '[:space:]')"

    if validate_public_ipv4 "$ip"; then
        echo "$ip"
        return 0
    fi

    # 2. Локальный fallback через сетевой стек ядра (строго публичный IPv4 маршрут)
    if command -v ip >/dev/null 2>&1; then
        ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)"
        ip="$(echo "$ip" | tr -d '[:space:]')"
        if validate_public_ipv4 "$ip"; then
            echo "$ip"
            return 0
        fi
    fi

    # 3. Fallback через hostname -I (фильтрация только глобальных публичных IPv4 адресов)
    for cand in $(hostname -I 2>/dev/null); do
        cand="$(echo "$cand" | tr -d '[:space:]')"
        if validate_public_ipv4 "$cand"; then
            echo "$cand"
            return 0
        fi
    done

    return 1
}

ensure_xray_api_healthy() {
    local force="${1:-0}"
    # Функция вызывается на узлах, где установлен агент xray-api (Origin / модульный узел с VLESS).
    if [[ ! -f /etc/systemd/system/xray-api.service && ! -f /lib/systemd/system/xray-api.service ]]; then
        return 0
    fi

    # На узлах Relay без VLESS служба xray-api не используется и не должна запускаться
    local role cur_has_v
    role="$(get_state_val "role" "")"
    cur_has_v="$(get_state_val "has_vless" "0")"
    if [[ "$force" != "1" && "$role" != "origin" && "$cur_has_v" != "1" ]]; then
        return 0
    fi

    # 1. Если служба уже активна (systemd автоматически перезапустил её через PartOf=xray.service),
    # повторный restart категорически не вызываем, чтобы не провоцировать start-limit-hit.
    if systemctl is-active --quiet xray-api 2>/dev/null; then
        return 0
    fi

    # 2. Если служба в процессе запуска (activating), даем до 2.5 секунд на завершение
    local attempts=5
    while [[ $attempts -gt 0 ]]; do
        if systemctl is-active --quiet xray-api 2>/dev/null; then
            return 0
        fi
        local state
        state="$(systemctl is-active xray-api 2>/dev/null || true)"
        if [[ "$state" != "activating" ]]; then
            break
        fi
        sleep 0.5
        attempts=$((attempts - 1))
    done

    # 3. Если служба в статусе failed (например start-limit-hit) — сбрасываем лимит ошибок
    if systemctl is-failed --quiet xray-api 2>/dev/null; then
        systemctl reset-failed xray-api 2>/dev/null || true
    fi

    # 4. Выполняем контролируемый старт службы
    systemctl start xray-api 2>/dev/null || true
    sleep 0.5

    # 5. Проверяем финальный статус: функция возвращает 0 только при реальной активности службы
    if systemctl is-active --quiet xray-api 2>/dev/null; then
        return 0
    fi
    return 1
}

apply_node_sysctl_hardening() {
    local conf_path="${JUST1KNODE_SYSCTL_IPV6_CONF:-/etc/sysctl.d/99-disable-ipv6.conf}"
    mkdir -p "$(dirname "$conf_path")" 2>/dev/null || true
    cat > "$conf_path" <<EOF 2>/dev/null || true
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv4.icmp_echo_ignore_all = 1
net.mptcp.enabled = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.core.somaxconn = 65535
net.ipv4.ip_local_port_range = 32768 65535
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 16384
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 120
EOF
    chmod 644 "$conf_path" 2>/dev/null || true

    local ufw_conf="${JUST1KNODE_UFW_SYSCTL_CONF:-/etc/ufw/sysctl.conf}"
    if [[ -f "$ufw_conf" ]]; then
        if grep -Eq '^[#[:space:]]*net/ipv4/icmp_echo_ignore_all[[:space:]]*=' "$ufw_conf" 2>/dev/null; then
            sed -i -E '/^[#[:space:]]*net\/ipv4\/icmp_echo_ignore_all[[:space:]]*=/d' "$ufw_conf" 2>/dev/null || true
        fi
        echo "net/ipv4/icmp_echo_ignore_all=1" >> "$ufw_conf" 2>/dev/null || true
    fi

    if command -v sysctl >/dev/null 2>&1; then
        modprobe tcp_bbr 2>/dev/null || true
        modprobe sch_fq 2>/dev/null || true
        modprobe nf_conntrack 2>/dev/null || true
        mkdir -p /etc/modules-load.d 2>/dev/null || true
        if [[ -d /etc/modules-load.d ]] && ! grep -q "^nf_conntrack" /etc/modules-load.d/just1knode.conf 2>/dev/null; then
            echo "nf_conntrack" >> /etc/modules-load.d/just1knode.conf 2>/dev/null || true
        fi
        sysctl -p "$conf_path" >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1 || true
        sysctl -w net.ipv4.icmp_echo_ignore_all=1 >/dev/null 2>&1 || true
        sysctl -w net.mptcp.enabled=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_fin_timeout=15 >/dev/null 2>&1 || true
        sysctl -w net.core.somaxconn=65535 >/dev/null 2>&1 || true
        sysctl -w net.ipv4.ip_local_port_range="32768 65535" >/dev/null 2>&1 || true
        sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
    fi
    local ipv6_curr
    ipv6_curr="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo "0")"
    if [[ "$ipv6_curr" != "1" ]]; then
        warn "Параметр net.ipv6.conf.all.disable_ipv6 не применился в ядре ноды (проверьте права или ограничения контейнера)."
    fi
    local icmp_curr
    icmp_curr="$(cat /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null || echo "0")"
    if [[ "$icmp_curr" != "1" ]]; then
        warn "Параметр net.ipv4.icmp_echo_ignore_all не применился в ядре ноды (проверьте права или ограничения контейнера)."
    fi
    local bbr_curr
    bbr_curr="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "")"
    if [[ -n "$bbr_curr" && "$bbr_curr" != "bbr" ]]; then
        warn "Контроль перегрузки BBR не активирован в ядре (текущий: $bbr_curr). Проверьте поддержку BBR хостинг-провайдером."
    fi
}

# Определение всех активных портов демона SSH (Zero-Lockout стандарт)
# Игнорирует сокеты, слушающие исключительно loopback (127.0.0.1 или ::1)
detect_active_sshd_ports() {
    local ports=()
    local p
    if command -v ss >/dev/null 2>&1; then
        while read -r line; do
            # Строка вида: 0.0.0.0:22 или [::]:22
            local laddr lport
            laddr="$(echo "$line" | awk '{print $4}')"
            lport="$(echo "$laddr" | rev | cut -d: -f1 | rev)"
            if [[ -n "$lport" && "$lport" =~ ^[0-9]+$ ]]; then
                # Пропускаем loopback-only сокеты (127.x.x.x или [::1])
                if [[ "$laddr" =~ ^127\. || "$laddr" =~ ^\[::1\] || "$laddr" =~ ^::1 ]]; then
                    continue
                fi
                ports+=("$lport")
            fi
        done < <(ss -tlnp 2>/dev/null | grep -E 'users:.*"sshd"')
    fi

    if [[ ${#ports[@]} -eq 0 ]] && command -v sshd >/dev/null 2>&1; then
        p="$(sshd -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n 1 || true)"
        [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] && ports+=("$p")
    fi

    if [[ ${#ports[@]} -eq 0 ]]; then
        p="$(grep -E -h "^Port " /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}' | head -n 1 || true)"
        [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] && ports+=("$p")
    fi

    [[ ${#ports[@]} -eq 0 ]] && ports+=("22")

    printf "%s\n" "${ports[@]}" | sort -u
}

# Проверка: слушает ли демон SSH на указанном порту
is_ssh_port() {
    local check_p="$1"
    [[ -z "$check_p" ]] && return 1
    while read -r active_sp; do
        [[ "$active_sp" == "$check_p" ]] && return 0
    done < <(detect_active_sshd_ports 2>/dev/null || true)
    return 1
}

# Автоматическое приведение периметра UFW и системных настроек к эталонному закрытому состоянию (Stealth)
heal_node_firewall_and_stealth() {
    # 1. Применяем системное скрытие (IPv6 leak protection + ICMP stealth)
    apply_node_sysctl_hardening

    if ! command -v ufw >/dev/null 2>&1 || ! ufw status 2>/dev/null | grep -qi "Status: active"; then
        return 0
    fi

    migrate_legacy_state
    local role
    role="$(get_state_val "role" "")"

    # 1. Гарантия защиты SSH (Zero-Lockout стандарт: подтверждаем все активные публичные сокеты SSH ДО изменения политики)
    # Важно: не расширяем уже существующие restricted-правила (с привязкой к IP) до Anywhere!
    local ssh_live_ports=()
    while read -r sp; do
        [[ -n "$sp" ]] && ssh_live_ports+=("$sp")
    done < <(detect_active_sshd_ports)

    for sp in "${ssh_live_ports[@]}"; do
        # Если порт SSH уже разрешён в UFW (хоть с конкретного IP, хоть отовсюду) — НЕ создаём дублирующее Anywhere-правило!
        if ! ufw status 2>/dev/null | grep -E "(^|[[:space:]])${sp}(/tcp)?[[:space:]]+ALLOW" -q; then
            if ! ufw allow "$sp/tcp" comment "just1knode ssh access" >/dev/null 2>&1; then
                error "КРИТИЧЕСКАЯ ОШИБКА: Не удалось открыть SSH-порт $sp/tcp в UFW! Зачистка фаервола отменена во избежание потери доступа."
                return 1
            fi
            log "Фаервол UFW: гарантирован доступ к порту SSH ($sp/tcp)."
        fi
    done

    # 2. Гарантия базовой политики фаервола: запрет входящих по умолчанию (только после подтверждения SSH)
    if ! ufw status verbose 2>/dev/null | grep -qi "Default: deny (incoming)"; then
        ufw default deny incoming >/dev/null 2>&1 || true
    fi
    ufw default allow outgoing >/dev/null 2>&1 || true

    # 3. Очистка устаревшего порта 8443 (Amnezia) во всех ролях при условии, что на нем не слушает SSH
    if ! is_ssh_port "8443"; then
        if ufw status 2>/dev/null | grep -E "8443(/tcp)?[[:space:]]+ALLOW" -q; then
            ufw delete allow 8443/tcp >/dev/null 2>&1 || true
            ufw delete allow 8443 >/dev/null 2>&1 || true
            warn "Фаервол UFW: устранена уязвимость — удалено устаревшее правило на порт 8443."
        fi
    fi

    # 4. Origin API (роль origin)
    if [[ "$role" == "origin" ]]; then
        local origin_bot_ip
        origin_bot_ip="$(get_state_val "bot_ip" 2>/dev/null || true)"

        # Zero-Lockout: не удаляем 8444, если на нем слушает SSH
        if ! is_ssh_port "8444"; then
            if ufw status 2>/dev/null | grep -E "8444(/tcp)?[[:space:]]+ALLOW[[:space:]]+(Anywhere|0\.0\.0\.0/0|::/0)" -q; then
                ufw delete allow 8444/tcp >/dev/null 2>&1 || true
                ufw delete allow 8444 >/dev/null 2>&1 || true
                warn "Фаервол UFW: устранена уязвимость — удалено глобальное правило на порт 8444."
            fi
        fi

        # Проверка доверенного BOT_IP из state.json (Fail-Closed)
        if [[ -n "$origin_bot_ip" && "$origin_bot_ip" != "any" && "$origin_bot_ip" != "-" ]] && (validate_ip "$origin_bot_ip" || validate_ipv4 "$origin_bot_ip"); then
            if ! ufw status 2>/dev/null | grep -F "$origin_bot_ip" | grep -q "8444"; then
                if ufw allow from "$origin_bot_ip" to any port 8444 proto tcp comment "just1knode origin api" >/dev/null 2>&1; then
                    log "Фаервол UFW: подтвержден доступ к порту 8444 для BOT_IP (${origin_bot_ip})"
                fi
            fi
        else
            warn "BOT_IP не задан в state.json. Порт Origin API (8444) закрыт от мира (Fail-Closed)."
        fi
    fi

    # 5. Relay туннель (роль relay либо has_relay)
    local cur_has_relay
    cur_has_relay="$(get_state_val "has_relay" "0")"
    if [[ "$role" == "relay" || "$cur_has_relay" == "1" ]]; then
        local relay_port origin_ip
        relay_port="$(get_state_val "relay_port" 2>/dev/null || true)"
        origin_ip="$(get_state_val "origin_ip" 2>/dev/null || true)"

        if [[ -n "$relay_port" && "$relay_port" =~ ^[0-9]+$ ]]; then
            # Zero-Lockout: не удаляем правило, если на нем слушает SSH
            if ! is_ssh_port "$relay_port"; then
                if ufw status 2>/dev/null | grep -E "${relay_port}(/tcp)?[[:space:]]+ALLOW[[:space:]]+(Anywhere|0\.0\.0\.0/0|::/0)" -q; then
                    ufw delete allow "${relay_port}/tcp" >/dev/null 2>&1 || true
                    ufw delete allow "${relay_port}" >/dev/null 2>&1 || true
                    warn "Фаервол UFW: устранена уязвимость — удалено публичное правило на порт Relay туннеля (${relay_port})."
                fi
            fi

            if [[ -n "$origin_ip" ]] && validate_ipv4 "$origin_ip"; then
                if ! ufw status 2>/dev/null | grep -F "$origin_ip" | grep -q "$relay_port"; then
                    if ufw allow from "$origin_ip" to any port "$relay_port" proto tcp comment "just1knode relay tunnel" >/dev/null 2>&1; then
                        log "Фаервол UFW: подтвержден доступ к Relay порту ${relay_port} строго для ORIGIN_IP (${origin_ip})"
                    fi
                fi
            fi
        fi
    fi

    # 6. VLESS Direct и API (роль vless либо has_vless)
    local cur_has_vless
    cur_has_vless="$(get_state_val "has_vless" "0")"
    if [[ "$role" == "vless" || "$cur_has_vless" == "1" || -f "/etc/nginx/sites-enabled/just1k-vless-api.conf" ]]; then
        # Клиентский вход VLESS TLS на порту 443
        if ! ufw status 2>/dev/null | grep -E "443(/tcp)?[[:space:]]+ALLOW" -q; then
            ufw allow 443/tcp comment "just1knode vless direct" >/dev/null 2>&1 || true
        fi

        # Защита xray-api (порт 8444)
        if ! is_ssh_port "8444"; then
            if ufw status 2>/dev/null | grep -E "8444(/tcp)?[[:space:]]+ALLOW[[:space:]]+(Anywhere|0\.0\.0\.0/0|::/0)" -q; then
                ufw delete allow 8444/tcp >/dev/null 2>&1 || true
                ufw delete allow 8444 >/dev/null 2>&1 || true
                warn "Фаервол UFW: устранена уязвимость — удалено публичное правило на порт 8444."
            fi
        fi

        local v_bot_ip
        v_bot_ip="$(get_state_val "bot_ip" 2>/dev/null || true)"
        if [[ -f "/etc/nginx/sites-enabled/just1k-vless-api.conf" || "$cur_has_vless" == "1" || "$role" == "vless" ]]; then
            if [[ -n "$v_bot_ip" && "$v_bot_ip" != "any" && "$v_bot_ip" != "0.0.0.0/0" && "$v_bot_ip" != "-" ]] && (validate_ip "$v_bot_ip" || validate_ipv4 "$v_bot_ip"); then
                if ! ufw status 2>/dev/null | grep -F "$v_bot_ip" | grep -q "8444"; then
                    ufw allow from "$v_bot_ip" to any port 8444 proto tcp comment "just1knode xray-api bot_ip" >/dev/null 2>&1 || true
                fi
            fi
        fi
    fi

    # 7. Защита веб-периметра: закрытие порта 80 на узлах без внешних веб-сервисов
    # На нодах без роли Origin и без локального контейнера (Caddy) порт 80 не должен быть открыт наружу.
    # Фолбэк Nginx слушает строго на 127.0.0.1:80 (локальный fallback ядра Xray).
    if [[ "$role" != "origin" ]]; then
        local has_external_sites=0
        if command -v nginx >/dev/null 2>&1; then
            if [[ -n "$(detect_existing_nginx_sites 2>/dev/null || true)" ]]; then
                has_external_sites=1
            fi
        fi
        if [[ "$has_external_sites" == "0" ]] && \
           [[ ! -f /run/just1knode_ufw_opened_80 ]] && \
           [[ -z "$(detect_host_port80_container 2>/dev/null || true)" ]] && \
           ! (command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "just1kbot_caddy"); then
            if ! is_ssh_port "80"; then
                if ufw status 2>/dev/null | grep -E "(^|[[:space:]])80(/tcp)?[[:space:]]+ALLOW" -q; then
                    ufw delete allow 80/tcp >/dev/null 2>&1 || true
                    ufw delete allow 80 >/dev/null 2>&1 || true
                    log "Фаервол UFW: закрыт неиспользуемый публичный порт 80 (маскировка Zero-Signature)."
                fi
            fi
        fi
    fi
}

sync_xhttp_upstreams_conf() {
    local conf_d="${NGINX_CONF_DIR:-/etc/nginx}/conf.d"
    local upstreams_file="${conf_d}/just1k-xhttp-upstreams.conf"
    local cfg_file="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
    local relays_file="${RELAYS_FILE:-${STATE_DIR:-/etc/just1knode}/relays.json}"

    mkdir -p "$conf_d" 2>/dev/null || true
    manifest_track_file "$upstreams_file" 2>/dev/null || true
    create_backup "$upstreams_file" 2>/dev/null || true

    if ! python3 -c "
import json, os, tempfile, sys, re

upstreams_file = sys.argv[1]
cfg_file = sys.argv[2]
relays_file = sys.argv[3]

xray_inbound_ports = {}
if os.path.exists(cfg_file):
    try:
        with open(cfg_file, 'r', encoding='utf-8') as f:
            cfg = json.load(f)
            for ib in cfg.get('inbounds', []):
                t = ib.get('tag')
                p = ib.get('port')
                if t and p:
                    xray_inbound_ports[t] = int(p)
    except Exception as e:
        sys.stderr.write('Error parsing Xray config: ' + str(e) + '\\n')
        sys.exit(1)

relays = []
if os.path.exists(relays_file):
    try:
        with open(relays_file, 'r', encoding='utf-8') as f:
            relays = json.load(f)
            if not isinstance(relays, list):
                relays = []
    except Exception:
        relays = []

def_port = xray_inbound_ports.get('just1k-wl-default', 8003)
lines = [
    '# =============================================================================',
    '# Persistent Keepalive Upstream Pools for Xray XHTTP (Zero TIME_WAIT)',
    '# =============================================================================',
    'upstream xray_xhttp_default {',
    f'    server 127.0.0.1:{def_port};',
    '    keepalive 128;',
    '    keepalive_requests 100000;',
    '    keepalive_timeout 300s;',
    '}',
    ''
]

seen_codes = set()
for r in relays:
    if not isinstance(r, dict):
        continue
    code = r.get('code')
    if not code:
        continue
    code_lower = str(code).strip().lower()
    if not code_lower or not re.fullmatch(r'^[a-z0-9_-]+$', code_lower) or code_lower in seen_codes:
        continue
    in_tag = r.get('inbound_tag') or f'just1k-wl-inbound-{code_lower}'
    port = xray_inbound_ports.get(in_tag)
    if not port:
        for t, p in xray_inbound_ports.items():
            if t.lower() == f'just1k-wl-inbound-{code_lower}':
                port = p
                break
    # Источник истины — секция inbounds в config.json (Desired-State).
    # Релеи, отсутствующие в Xray, не получают upstream (защита от устаревших записей в relays.json).
    if not port and not os.path.exists(cfg_file):
        port = r.get('inbound_port')
    if port:
        seen_codes.add(code_lower)
        try:
            port_num = int(port)
            lines.append(f'upstream xray_xhttp_relay_{code_lower} {{')
            lines.append(f'    server 127.0.0.1:{port_num};')
            lines.append('    keepalive 128;')
            lines.append('    keepalive_requests 100000;')
            lines.append('    keepalive_timeout 300s;')
            lines.append('}')
            lines.append('')
        except Exception:
            continue

# Защита в глубину: если релеи есть в Xray inbounds, но relays.json временно пуст
for t, p in xray_inbound_ports.items():
    if t.startswith('just1k-wl-inbound-'):
        c_tag = t[len('just1k-wl-inbound-'):].strip().lower()
        if c_tag and re.fullmatch(r'^[a-z0-9_-]+$', c_tag) and c_tag not in seen_codes:
            try:
                port_num = int(p)
                seen_codes.add(c_tag)
                lines.append(f'upstream xray_xhttp_relay_{c_tag} {{')
                lines.append(f'    server 127.0.0.1:{port_num};')
                lines.append('    keepalive 128;')
                lines.append('    keepalive_requests 100000;')
                lines.append('    keepalive_timeout 300s;')
                lines.append('}')
                lines.append('')
            except Exception:
                continue

content = '\\n'.join(lines) + '\\n'
d = os.path.dirname(os.path.abspath(upstreams_file))
os.makedirs(d, exist_ok=True)
t_fd, t_path = tempfile.mkstemp(dir=d, suffix='.tmp')
with os.fdopen(t_fd, 'w', encoding='utf-8') as f:
    f.write(content)
    f.flush()
    os.fsync(f.fileno())
os.replace(t_path, upstreams_file)
try:
    os.chmod(upstreams_file, 0o644)
except Exception:
    pass
" "$upstreams_file" "$cfg_file" "$relays_file"; then
        warn "Не удалось сгенерировать Nginx upstreams для XHTTP ($upstreams_file)"
        return 1
    fi
    return 0
}

detect_node_country_code() {
    local ip="${1:-}"
    if [[ -z "$ip" ]]; then
        return 1
    fi

    local c_code=""
    c_code="$(python3 -c "
import urllib.request, json, sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed

ip = sys.argv[1]

def fetch_ip_api():
    try:
        req = urllib.request.Request(f'http://ip-api.com/json/{ip}?fields=status,countryCode', headers={'User-Agent': 'curl/7.88.1'})
        with urllib.request.urlopen(req, timeout=2.5) as r:
            d = json.loads(r.read().decode('utf-8'))
            if d.get('status') == 'success':
                return d.get('countryCode', '').lower()
    except Exception:
        pass
    return None

def fetch_ipwho():
    try:
        req = urllib.request.Request(f'https://ipwho.is/{ip}', headers={'User-Agent': 'curl/7.88.1'})
        with urllib.request.urlopen(req, timeout=2.5) as r:
            d = json.loads(r.read().decode('utf-8'))
            if d.get('success'):
                return d.get('country_code', '').lower()
    except Exception:
        pass
    return None

def fetch_ipinfo():
    try:
        req = urllib.request.Request(f'https://ipinfo.io/{ip}/json', headers={'User-Agent': 'curl/7.88.1'})
        with urllib.request.urlopen(req, timeout=2.5) as r:
            d = json.loads(r.read().decode('utf-8'))
            return d.get('country', '').lower()
    except Exception:
        pass
    return None

results = []
with ThreadPoolExecutor(max_workers=3) as ex:
    futures = [ex.submit(fetch_ip_api), ex.submit(fetch_ipwho), ex.submit(fetch_ipinfo)]
    for f in as_completed(futures):
        res = f.result()
        if res and len(res) == 2 and res != 'ru':
            results.append(res)

if results:
    counts = Counter(results)
    most_common, _ = counts.most_common(1)[0]
    print(most_common)
" "$ip" 2>/dev/null || true)"

    if [[ -n "$c_code" && "$c_code" != "ru" && "${#c_code}" -eq 2 ]]; then
        echo "$c_code"
        return 0
    fi

    return 1
}

normalize_country_code() {
    local raw="${1:-}"
    if [[ "$raw" == *"/"* || "$raw" == *"\\"* || "$raw" == *".."* ]]; then
        echo ""
        return 1
    fi
    local val="${raw,,}"
    val="$(echo "$val" | tr -d '[:punct:]' | xargs)"
    case "$val" in
        de|germany|германия|"de germany"|"de германия") echo "de" ;;
        nl|netherlands|нидерланды|"nl netherlands"|"nl нидерланды") echo "nl" ;;
        fi|finland|финляндия|"fi finland"|"fi финляндия") echo "fi" ;;
        se|sweden|швеция|"se sweden"|"se швеция") echo "se" ;;
        us|usa|сша|"us usa"|"us сша") echo "us" ;;
        gb|uk|britain|великобритания|"gb britain"|"gb великобритания") echo "gb" ;;
        fr|france|франция|"fr france"|"fr франция") echo "fr" ;;
        tr|turkey|турция|"tr turkey"|"tr турция") echo "tr" ;;
        kz|kazakhstan|казахстан|"kz kazakhstan"|"kz казахстан") echo "kz" ;;
        pl|poland|польша|"pl poland"|"pl польша") echo "pl" ;;
        at|austria|австрия|"at austria"|"at австрия") echo "at" ;;
        ch|switzerland|швейцария|"ch switzerland"|"ch швейцария") echo "ch" ;;
        ee|estonia|эстония|"ee estonia"|"ee эстония") echo "ee" ;;
        es|spain|испания|"es spain"|"es испания") echo "es" ;;
        it|italy|италия|"it italy"|"it италия") echo "it" ;;
        cz|czechia|чехия|"cz czechia"|"cz чехия") echo "cz" ;;
        no|norway|норвегия|"no norway"|"no норвегия") echo "no" ;;
        dk|denmark|дания|"dk denmark"|"dk дания") echo "dk" ;;
        is|iceland|исландия|"is iceland"|"is исландия") echo "is" ;;
        lt|lithuania|литва|"lt lithuania"|"lt литва") echo "lt" ;;
        lv|latvia|латвия|"lv latvia"|"lv латвия") echo "lv" ;;
        ro|romania|румыния|"ro romania"|"ro румыния") echo "ro" ;;
        bg|bulgaria|болгария|"bg bulgaria"|"bg болгария") echo "bg" ;;
        gr|greece|греция|"gr greece"|"gr греция") echo "gr" ;;
        hu|hungary|венгрия|"hu hungary"|"hu венгрия") echo "hu" ;;
        sk|slovakia|словакия|"sk slovakia"|"sk словакия") echo "sk" ;;
        ie|ireland|ирландия|"ie ireland"|"ie ирландия") echo "ie" ;;
        pt|portugal|португалия|"pt portugal"|"pt португалия") echo "pt" ;;
        jp|japan|япония|"jp japan"|"jp япония") echo "jp" ;;
        sg|singapore|сингапур|"sg singapore"|"sg сингапур") echo "sg" ;;
        ae|uae|оаэ|"ae uae"|"ae оаэ") echo "ae" ;;
        ge|georgia|грузия|"ge georgia"|"ge грузия") echo "ge" ;;
        am|armenia|армения|"am armenia"|"am армения") echo "am" ;;
        *)
            if [[ "$val" =~ ^[a-z]{2}$ ]]; then
                echo "$val"
            else
                local clean
                clean="$(echo "$val" | tr -cd '[:alnum:]')"
                echo "${clean:0:2}"
            fi
            ;;
    esac
}

get_country_display_name() {
    local raw="${1:-}"
    local val="${raw,,}"
    val="$(echo "$val" | tr -d '[:punct:]' | xargs)"
    case "$val" in
        de|germany|германия|"de germany"|"de германия") echo "🇩🇪 Германия" ;;
        nl|netherlands|нидерланды|"nl netherlands"|"nl нидерланды") echo "🇳🇱 Нидерланды" ;;
        fi|finland|финляндия|"fi finland"|"fi финляндия") echo "🇫🇮 Финляндия" ;;
        se|sweden|швеция|"se sweden"|"se швеция") echo "🇸🇪 Швеция" ;;
        us|usa|сша|"us usa"|"us сша") echo "🇺🇸 США" ;;
        gb|uk|britain|великобритания|"gb britain"|"gb великобритания") echo "🇬🇧 Великобритания" ;;
        fr|france|франция|"fr france"|"fr франция") echo "🇫🇷 Франция" ;;
        tr|turkey|турция|"tr turkey"|"tr турция") echo "🇹🇷 Турция" ;;
        kz|kazakhstan|казахстан|"kz kazakhstan"|"kz казахстан") echo "🇰🇿 Казахстан" ;;
        pl|poland|польша|"pl poland"|"pl польша") echo "🇵🇱 Польша" ;;
        at|austria|австрия|"at austria"|"at австрия") echo "🇦🇹 Австрия" ;;
        ch|switzerland|швейцария|"ch switzerland"|"ch швейцария") echo "🇨🇭 Швейцария" ;;
        ee|estonia|эстония|"ee estonia"|"ee эстония") echo "🇪🇪 Эстония" ;;
        es|spain|испания|"es spain"|"es испания") echo "🇪🇸 Испания" ;;
        it|italy|италия|"it italy"|"it италия") echo "🇮🇹 Италия" ;;
        cz|czechia|чехия|"cz czechia"|"cz чехия") echo "🇨🇿 Чехия" ;;
        no|norway|норвегия|"no norway"|"no норвегия") echo "🇳🇴 Норвегия" ;;
        dk|denmark|дания|"dk denmark"|"dk дания") echo "🇩🇰 Дания" ;;
        is|iceland|исландия|"is iceland"|"is исландия") echo "🇮🇸 Исландия" ;;
        lt|lithuania|литва|"lt lithuania"|"lt литва") echo "🇱🇹 Литва" ;;
        lv|latvia|латвия|"lv latvia"|"lv латвия") echo "🇱🇻 Латвия" ;;
        ro|romania|румыния|"ro romania"|"ro румыния") echo "🇷🇴 Румыния" ;;
        bg|bulgaria|болгария|"bg bulgaria"|"bg болгария") echo "🇧🇬 Болгария" ;;
        gr|greece|греция|"gr greece"|"gr греция") echo "🇬🇷 Греция" ;;
        hu|hungary|венгрия|"hu hungary"|"hu венгрия") echo "🇭🇺 Венгрия" ;;
        sk|slovakia|словакия|"sk slovakia"|"sk словакия") echo "🇸🇰 Словакия" ;;
        ie|ireland|ирландия|"ie ireland"|"ie ирландия") echo "🇮🇪 Ирландия" ;;
        pt|portugal|португалия|"pt portugal"|"pt португалия") echo "🇵🇹 Португалия" ;;
        jp|japan|япония|"jp japan"|"jp япония") echo "🇯🇵 Япония" ;;
        sg|singapore|сингапур|"sg singapore"|"sg сингапур") echo "🇸🇬 Сингапур" ;;
        ae|uae|оаэ|"ae uae"|"ae оаэ") echo "🇦🇪 ОАЭ" ;;
        ge|georgia|грузия|"ge georgia"|"ge грузия") echo "🇬🇪 Грузия" ;;
        am|armenia|армения|"am armenia"|"am армения") echo "🇦🇲 Армения" ;;
        *)
            local norm
            norm="$(normalize_country_code "$raw")"
            if [[ -n "$norm" && "$norm" != "$val" && "$norm" != "$raw" ]]; then
                get_country_display_name "$norm"
            elif [[ -n "$raw" ]]; then
                echo "$raw"
            else
                echo "Зарубежный шлюз"
            fi
            ;;
    esac
}

resolve_relay_geo_interactive() {
    local ip="${1:-}"
    local fallback="${2:-exit}"
    local code=""
    local country=""

    if [[ -n "$ip" ]]; then
        code="$(detect_node_country_code "$ip" 2>/dev/null || true)"
    fi
    if [[ -z "$code" ]]; then
        code="$fallback"
    fi

    code="$(normalize_country_code "$code")"
    country="$(get_country_display_name "$code")"

    if [[ -t 0 ]]; then
        info "Определена геолокация Relay: ${BOLD}${country}${NC} (код: ${CYAN}${code}${NC})" >&2
        local confirm=""
        read -rp "Использовать эту локацию? [Y/n]: " confirm >&2 || true
        if [[ "$confirm" =~ ^[NnНн]$ ]]; then
            local custom_code=""
            read -rp "Введите двухбуквенный код или название страны (например: se, fi, de): " custom_code >&2 || true
            if [[ -n "$custom_code" ]]; then
                code="$(normalize_country_code "$custom_code")"
                country="$(get_country_display_name "$code")"
            fi
        fi
    fi

    echo "${code}|${country}"
}

# =============================================================================
# СИСТЕМА ЗАЩИТЫ ОТ АБУЗА (ANTI-ABUSE: NETFILTER / IPTABLES / UFW)
# 1. Блокировка исходящего SMTP (порт 25) с tcp-reset
# 2. Блокировка BitTorrent L7 хэндшейка и DHT пакетов через xt_string
# =============================================================================

sync_ufw_before_rules_antiabuse() {
    local before_rules="/etc/ufw/before.rules"
    if [[ -f "$before_rules" ]]; then
        local has_xt_string=0
        if iptables -m string --help 2>&1 | grep -q "\-\-algo"; then
            has_xt_string=1
        fi
        python3 -c "
import os, re, sys, tempfile
bf = sys.argv[1]
has_xt_string = sys.argv[2] == '1'
with open(bf, 'r', encoding='utf-8') as f:
    content = f.read()

content = re.sub(r'# START JUST1KNODE ANTI-ABUSE.*?# END JUST1KNODE ANTI-ABUSE\n?', '', content, flags=re.DOTALL)

rules = [
    '-A ufw-before-forward -p tcp --dport 25 -j REJECT --reject-with tcp-reset',
    '-A ufw-before-output -p tcp --dport 25 -j REJECT --reject-with tcp-reset',
    '-A ufw-before-forward -p tcp --dport 6881:6889 -j DROP',
    '-A ufw-before-forward -p udp --dport 6881:6889 -j DROP',
    '-A ufw-before-output -p tcp --dport 6881:6889 -j DROP',
    '-A ufw-before-output -p udp --dport 6881:6889 -j DROP',
]
if has_xt_string:
    rules.extend([
        '-A ufw-before-forward -p tcp -m string --string \"BitTorrent protocol\" --algo bm -j DROP',
        '-A ufw-before-forward -p udp -m string --string \"BitTorrent protocol\" --algo bm -j DROP',
        '-A ufw-before-forward -p udp -m string --string \"d1:ad2:id20:\" --algo bm -j DROP',
        '-A ufw-before-output -p tcp -m string --string \"BitTorrent protocol\" --algo bm -j DROP',
        '-A ufw-before-output -p udp -m string --string \"BitTorrent protocol\" --algo bm -j DROP',
        '-A ufw-before-output -p udp -m string --string \"d1:ad2:id20:\" --algo bm -j DROP',
        '-A ufw-before-output -p udp -m string --string \"d1:rd2:id20:\" --algo bm -j DROP',
        '-A ufw-before-output -p udp -m string --hex-string \"|0000041727101980|\" --algo bm -j DROP',
        '-A ufw-before-output -p tcp -m string --string \"/announce?info_hash=\" --algo bm -j DROP',
    ])

block = '# START JUST1KNODE ANTI-ABUSE\n' + '\n'.join(rules) + '\n# END JUST1KNODE ANTI-ABUSE\n'

if ':ufw-before-forward' in content:
    content = re.sub(r'(:\s*ufw-before-forward\s+-\s+\[0:0\]\n)', r'\1' + block, content, count=1)
elif '*filter' in content:
    content = content.replace('*filter\n', '*filter\n' + block, 1)
else:
    sys.exit(1)

d = os.path.dirname(os.path.abspath(bf))
t_fd, t_path = tempfile.mkstemp(dir=d, suffix='.tmp')
with os.fdopen(t_fd, 'w', encoding='utf-8') as f:
    f.write(content)
    f.flush()
    os.fsync(f.fileno())
os.replace(t_path, bf)
" "$before_rules" "$has_xt_string" 2>/dev/null || return 1
    else
        if command -v ufw >/dev/null 2>&1; then
            return 1
        fi
    fi
    return 0
}

remove_ufw_before_rules_antiabuse() {
    local before_rules="/etc/ufw/before.rules"
    if [[ -f "$before_rules" ]]; then
        python3 -c "
import os, re, sys, tempfile
bf = sys.argv[1]
try:
    with open(bf, 'r', encoding='utf-8') as f:
        content = f.read()
    new_content = re.sub(r'# START JUST1KNODE ANTI-ABUSE.*?# END JUST1KNODE ANTI-ABUSE\n?', '', content, flags=re.DOTALL)
    if new_content != content:
        d = os.path.dirname(os.path.abspath(bf))
        t_fd, t_path = tempfile.mkstemp(dir=d, suffix='.tmp')
        with os.fdopen(t_fd, 'w', encoding='utf-8') as f:
            f.write(new_content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(t_path, bf)
except Exception:
    pass
" "$before_rules" 2>/dev/null || true
    fi
}

check_antiabuse_rules() {
    # Проверка обязательных инвариантов сетевой защиты:
    # 1. SMTP:25 REJECT (FORWARD + OUTPUT)
    # 2. BitTorrent:6881-6889 DROP (FORWARD + OUTPUT)
    # 3. BitTorrent L7 TCP/UDP DROP (FORWARD + OUTPUT при поддержке xt_string)
    # 4. BitTorrent L7 UDP DHT DROP (FORWARD + OUTPUT при поддержке xt_string)
    # 5. BitTorrent UDP-трекеры & HTTP-анонсы DROP (OUTPUT при поддержке xt_string)
    local missing=0

    # 1. SMTP:25 FORWARD & OUTPUT
    if ! iptables -C FORWARD -p tcp --dport 25 -j REJECT --reject-with tcp-reset 2>/dev/null && \
       ! (iptables -L ufw-before-forward >/dev/null 2>&1 && iptables -C ufw-before-forward -p tcp --dport 25 -j REJECT --reject-with tcp-reset 2>/dev/null); then
        missing=$((missing + 1))
    fi
    if ! iptables -C OUTPUT -p tcp --dport 25 -j REJECT --reject-with tcp-reset 2>/dev/null && \
       ! (iptables -L ufw-before-output >/dev/null 2>&1 && iptables -C ufw-before-output -p tcp --dport 25 -j REJECT --reject-with tcp-reset 2>/dev/null); then
        missing=$((missing + 1))
    fi

    # 2. BitTorrent порты 6881:6889 (FORWARD + OUTPUT)
    if ! iptables -C FORWARD -p tcp --dport 6881:6889 -j DROP 2>/dev/null && \
       ! (iptables -L ufw-before-forward >/dev/null 2>&1 && iptables -C ufw-before-forward -p tcp --dport 6881:6889 -j DROP 2>/dev/null); then
        missing=$((missing + 1))
    fi
    if ! iptables -C FORWARD -p udp --dport 6881:6889 -j DROP 2>/dev/null && \
       ! (iptables -L ufw-before-forward >/dev/null 2>&1 && iptables -C ufw-before-forward -p udp --dport 6881:6889 -j DROP 2>/dev/null); then
        missing=$((missing + 1))
    fi
    if ! iptables -C OUTPUT -p tcp --dport 6881:6889 -j DROP 2>/dev/null && \
       ! (iptables -L ufw-before-output >/dev/null 2>&1 && iptables -C ufw-before-output -p tcp --dport 6881:6889 -j DROP 2>/dev/null); then
        missing=$((missing + 1))
    fi
    if ! iptables -C OUTPUT -p udp --dport 6881:6889 -j DROP 2>/dev/null && \
       ! (iptables -L ufw-before-output >/dev/null 2>&1 && iptables -C ufw-before-output -p udp --dport 6881:6889 -j DROP 2>/dev/null); then
        missing=$((missing + 1))
    fi

    # 3. BitTorrent L7 (FORWARD + OUTPUT)
    if iptables -m string --help 2>&1 | grep -q "\-\-algo"; then
        if ! iptables -C FORWARD -p tcp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null && \
           ! (iptables -L ufw-before-forward >/dev/null 2>&1 && iptables -C ufw-before-forward -p tcp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null); then
            missing=$((missing + 1))
        fi
        if ! iptables -C FORWARD -p udp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null && \
           ! (iptables -L ufw-before-forward >/dev/null 2>&1 && iptables -C ufw-before-forward -p udp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null); then
            missing=$((missing + 1))
        fi
        if ! iptables -C FORWARD -p udp -m string --string "d1:ad2:id20:" --algo bm -j DROP 2>/dev/null && \
           ! (iptables -L ufw-before-forward >/dev/null 2>&1 && iptables -C ufw-before-forward -p udp -m string --string "d1:ad2:id20:" --algo bm -j DROP 2>/dev/null); then
            missing=$((missing + 1))
        fi

        # OUTPUT chain (для трафика локального процесса Xray)
        if ! iptables -C OUTPUT -p tcp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null && \
           ! (iptables -L ufw-before-output >/dev/null 2>&1 && iptables -C ufw-before-output -p tcp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null); then
            missing=$((missing + 1))
        fi
        if ! iptables -C OUTPUT -p udp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null && \
           ! (iptables -L ufw-before-output >/dev/null 2>&1 && iptables -C ufw-before-output -p udp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null); then
            missing=$((missing + 1))
        fi
        if ! iptables -C OUTPUT -p udp -m string --string "d1:ad2:id20:" --algo bm -j DROP 2>/dev/null && \
           ! (iptables -L ufw-before-output >/dev/null 2>&1 && iptables -C ufw-before-output -p udp -m string --string "d1:ad2:id20:" --algo bm -j DROP 2>/dev/null); then
            missing=$((missing + 1))
        fi
        if ! iptables -C OUTPUT -p udp -m string --string "d1:rd2:id20:" --algo bm -j DROP 2>/dev/null && \
           ! (iptables -L ufw-before-output >/dev/null 2>&1 && iptables -C ufw-before-output -p udp -m string --string "d1:rd2:id20:" --algo bm -j DROP 2>/dev/null); then
            missing=$((missing + 1))
        fi
        if ! iptables -C OUTPUT -p udp -m string --hex-string "|0000041727101980|" --algo bm -j DROP 2>/dev/null && \
           ! (iptables -L ufw-before-output >/dev/null 2>&1 && iptables -C ufw-before-output -p udp -m string --hex-string "|0000041727101980|" --algo bm -j DROP 2>/dev/null); then
            missing=$((missing + 1))
        fi
        if ! iptables -C OUTPUT -p tcp -m string --string "/announce?info_hash=" --algo bm -j DROP 2>/dev/null && \
           ! (iptables -L ufw-before-output >/dev/null 2>&1 && iptables -C ufw-before-output -p tcp -m string --string "/announce?info_hash=" --algo bm -j DROP 2>/dev/null); then
            missing=$((missing + 1))
        fi
    fi

    # Проверка сохранения правил в /etc/ufw/before.rules (при наличии UFW)
    local before_rules="/etc/ufw/before.rules"
    if [[ -f "$before_rules" ]]; then
        if ! grep -q -- "-A ufw-before-forward -p tcp --dport 25 -j REJECT --reject-with tcp-reset" "$before_rules" 2>/dev/null || \
           ! grep -q -- "-A ufw-before-output -p tcp --dport 25 -j REJECT --reject-with tcp-reset" "$before_rules" 2>/dev/null || \
           ! grep -q -- "-A ufw-before-forward -p tcp --dport 6881:6889 -j DROP" "$before_rules" 2>/dev/null || \
           ! grep -q -- "-A ufw-before-forward -p udp --dport 6881:6889 -j DROP" "$before_rules" 2>/dev/null || \
           ! grep -q -- "-A ufw-before-output -p tcp --dport 6881:6889 -j DROP" "$before_rules" 2>/dev/null || \
           ! grep -q -- "-A ufw-before-output -p udp --dport 6881:6889 -j DROP" "$before_rules" 2>/dev/null; then
            missing=$((missing + 1))
        fi
        if iptables -m string --help 2>&1 | grep -q "\-\-algo"; then
            if ! grep -q -- "-A ufw-before-forward -p tcp -m string --string \"BitTorrent protocol\" --algo bm -j DROP" "$before_rules" 2>/dev/null || \
               ! grep -q -- "-A ufw-before-forward -p udp -m string --string \"BitTorrent protocol\" --algo bm -j DROP" "$before_rules" 2>/dev/null || \
               ! grep -q -- "-A ufw-before-forward -p udp -m string --string \"d1:ad2:id20:\" --algo bm -j DROP" "$before_rules" 2>/dev/null || \
               ! grep -q -- "-A ufw-before-output -p tcp -m string --string \"BitTorrent protocol\" --algo bm -j DROP" "$before_rules" 2>/dev/null || \
               ! grep -q -- "-A ufw-before-output -p udp -m string --string \"BitTorrent protocol\" --algo bm -j DROP" "$before_rules" 2>/dev/null || \
               ! grep -q -- "-A ufw-before-output -p udp -m string --string \"d1:ad2:id20:\" --algo bm -j DROP" "$before_rules" 2>/dev/null || \
               ! grep -q -- "-A ufw-before-output -p udp -m string --string \"d1:rd2:id20:\" --algo bm -j DROP" "$before_rules" 2>/dev/null || \
               ! grep -q -- "-A ufw-before-output -p udp -m string --hex-string \"|0000041727101980|\" --algo bm -j DROP" "$before_rules" 2>/dev/null || \
               ! grep -q -- "-A ufw-before-output -p tcp -m string --string \"/announce?info_hash=\" --algo bm -j DROP" "$before_rules" 2>/dev/null; then
                missing=$((missing + 1))
            fi
        fi
    elif command -v ufw >/dev/null 2>&1; then
        missing=$((missing + 1))
    fi

    if [[ $missing -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

apply_antiabuse_protection() {
    log "Настройка сетевой защиты (Anti-Abuse: SMTP 25 + BitTorrent L7/Ports)..."
    apply_node_sysctl_hardening

    # 1. Автозагрузка модуля ядра xt_string для L7 фильтрации (если поддерживается)
    modprobe xt_string 2>/dev/null || true
    if iptables -m string --help 2>&1 | grep -q "\-\-algo"; then
        mkdir -p /etc/modules-load.d 2>/dev/null || true
        if ! grep -q "^xt_string" /etc/modules-load.d/just1knode.conf 2>/dev/null; then
            echo "xt_string" >> /etc/modules-load.d/just1knode.conf 2>/dev/null || true
        fi
    fi

    # 2. Персистентность в UFW (переживает ufw reload и перезагрузку ОС)
    if ! sync_ufw_before_rules_antiabuse; then
        warn "Сбой сохранения правил в /etc/ufw/before.rules!"
        return 1
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        if ! ufw reload >/dev/null 2>&1; then
            warn "Сбой перезагрузки конфигурации UFW (ufw reload)!"
            return 1
        fi
    fi

    # 3. Применение правил в активный FORWARD, OUTPUT и DOCKER-USER (немедленная защита без ожидания перезагрузки)
    # SMTP:25 reject (FORWARD + OUTPUT)
    if ! iptables -C FORWARD -p tcp --dport 25 -j REJECT --reject-with tcp-reset 2>/dev/null; then
        iptables -I FORWARD 1 -p tcp --dport 25 -j REJECT --reject-with tcp-reset 2>/dev/null || true
    fi
    if ! iptables -C OUTPUT -p tcp --dport 25 -j REJECT --reject-with tcp-reset 2>/dev/null; then
        iptables -I OUTPUT 1 -p tcp --dport 25 -j REJECT --reject-with tcp-reset 2>/dev/null || true
    fi
    if iptables -L DOCKER-USER >/dev/null 2>&1; then
        if ! iptables -C DOCKER-USER -p tcp --dport 25 -j REJECT --reject-with tcp-reset 2>/dev/null; then
            iptables -I DOCKER-USER 1 -p tcp --dport 25 -j REJECT --reject-with tcp-reset 2>/dev/null || true
        fi
    fi

    # BitTorrent Standard Ports (6881-6889) (FORWARD + OUTPUT)
    if ! iptables -C FORWARD -p tcp --dport 6881:6889 -j DROP 2>/dev/null; then
        iptables -I FORWARD 2 -p tcp --dport 6881:6889 -j DROP 2>/dev/null || true
    fi
    if ! iptables -C FORWARD -p udp --dport 6881:6889 -j DROP 2>/dev/null; then
        iptables -I FORWARD 3 -p udp --dport 6881:6889 -j DROP 2>/dev/null || true
    fi
    if ! iptables -C OUTPUT -p tcp --dport 6881:6889 -j DROP 2>/dev/null; then
        iptables -I OUTPUT 2 -p tcp --dport 6881:6889 -j DROP 2>/dev/null || true
    fi
    if ! iptables -C OUTPUT -p udp --dport 6881:6889 -j DROP 2>/dev/null; then
        iptables -I OUTPUT 3 -p udp --dport 6881:6889 -j DROP 2>/dev/null || true
    fi

    # BitTorrent L7
    if iptables -m string --help 2>&1 | grep -q "\-\-algo"; then
        if ! iptables -C FORWARD -p tcp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null; then
            iptables -I FORWARD 4 -p tcp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null || true
        fi
        if ! iptables -C FORWARD -p udp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null; then
            iptables -I FORWARD 5 -p udp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null || true
        fi
        if ! iptables -C FORWARD -p udp -m string --string "d1:ad2:id20:" --algo bm -j DROP 2>/dev/null; then
            iptables -I FORWARD 6 -p udp -m string --string "d1:ad2:id20:" --algo bm -j DROP 2>/dev/null || true
        fi

        # OUTPUT chain (для трафика локального процесса Xray)
        if ! iptables -C OUTPUT -p tcp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null; then
            iptables -I OUTPUT 4 -p tcp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null || true
        fi
        if ! iptables -C OUTPUT -p udp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null; then
            iptables -I OUTPUT 5 -p udp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null || true
        fi
        if ! iptables -C OUTPUT -p udp -m string --string "d1:ad2:id20:" --algo bm -j DROP 2>/dev/null; then
            iptables -I OUTPUT 6 -p udp -m string --string "d1:ad2:id20:" --algo bm -j DROP 2>/dev/null || true
        fi
        if ! iptables -C OUTPUT -p udp -m string --string "d1:rd2:id20:" --algo bm -j DROP 2>/dev/null; then
            iptables -I OUTPUT 7 -p udp -m string --string "d1:rd2:id20:" --algo bm -j DROP 2>/dev/null || true
        fi
        if ! iptables -C OUTPUT -p udp -m string --hex-string "|0000041727101980|" --algo bm -j DROP 2>/dev/null; then
            iptables -I OUTPUT 8 -p udp -m string --hex-string "|0000041727101980|" --algo bm -j DROP 2>/dev/null || true
        fi
        if ! iptables -C OUTPUT -p tcp -m string --string "/announce?info_hash=" --algo bm -j DROP 2>/dev/null; then
            iptables -I OUTPUT 9 -p tcp -m string --string "/announce?info_hash=" --algo bm -j DROP 2>/dev/null || true
        fi

        if iptables -L DOCKER-USER >/dev/null 2>&1; then
            if ! iptables -C DOCKER-USER -p tcp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null; then
                iptables -I DOCKER-USER 2 -p tcp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null || true
            fi
            if ! iptables -C DOCKER-USER -p udp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null; then
                iptables -I DOCKER-USER 3 -p udp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null || true
            fi
            if ! iptables -C DOCKER-USER -p udp -m string --string "d1:ad2:id20:" --algo bm -j DROP 2>/dev/null; then
                iptables -I DOCKER-USER 4 -p udp -m string --string "d1:ad2:id20:" --algo bm -j DROP 2>/dev/null || true
            fi
        fi
    fi

    # 4. Итоговая проверка соблюдения инвариантов (Fail-Closed)
    if check_antiabuse_rules; then
        if [[ -f /etc/ufw/after.init ]]; then
            sed -i '/# START JUST1KNODE ANTI-ABUSE HOOK/,/# END JUST1KNODE ANTI-ABUSE HOOK/d' /etc/ufw/after.init 2>/dev/null || true
        fi
        if [[ -f /etc/systemd/system/just1knode-antiabuse.service ]]; then
            rm -f /etc/systemd/system/just1knode-antiabuse.service 2>/dev/null || true
            systemctl daemon-reload 2>/dev/null || true
        fi

        log "✔ Правила сетевой защиты Anti-Abuse (SMTP:25 + BitTorrent L7/Ports) успешно активированы."
        set_state_val "abuse_protection" "enabled"
        return 0
    else
        warn "Не удалось активировать полный набор правил Anti-Abuse!"
        return 1
    fi
}

remove_antiabuse_protection() {
    log "Очистка правил сетевой защиты Anti-Abuse..."
    iptables -D FORWARD -p tcp --dport 25 -j REJECT --reject-with tcp-reset 2>/dev/null || true
    iptables -D OUTPUT -p tcp --dport 25 -j REJECT --reject-with tcp-reset 2>/dev/null || true
    iptables -D DOCKER-USER -p tcp --dport 25 -j REJECT --reject-with tcp-reset 2>/dev/null || true

    iptables -D FORWARD -p tcp --dport 6881:6889 -j DROP 2>/dev/null || true
    iptables -D FORWARD -p udp --dport 6881:6889 -j DROP 2>/dev/null || true
    iptables -D OUTPUT -p tcp --dport 6881:6889 -j DROP 2>/dev/null || true
    iptables -D OUTPUT -p udp --dport 6881:6889 -j DROP 2>/dev/null || true

    iptables -D FORWARD -p tcp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null || true
    iptables -D FORWARD -p udp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null || true
    iptables -D FORWARD -p udp -m string --string "d1:ad2:id20:" --algo bm -j DROP 2>/dev/null || true

    iptables -D OUTPUT -p tcp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null || true
    iptables -D OUTPUT -p udp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null || true
    iptables -D OUTPUT -p udp -m string --string "d1:ad2:id20:" --algo bm -j DROP 2>/dev/null || true
    iptables -D OUTPUT -p udp -m string --string "d1:rd2:id20:" --algo bm -j DROP 2>/dev/null || true
    iptables -D OUTPUT -p udp -m string --hex-string "|0000041727101980|" --algo bm -j DROP 2>/dev/null || true
    iptables -D OUTPUT -p tcp -m string --string "/announce?info_hash=" --algo bm -j DROP 2>/dev/null || true

    if iptables -L DOCKER-USER >/dev/null 2>&1; then
        iptables -D DOCKER-USER -p tcp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null || true
        iptables -D DOCKER-USER -p udp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null || true
        iptables -D DOCKER-USER -p udp -m string --string "d1:ad2:id20:" --algo bm -j DROP 2>/dev/null || true
    fi

    # Удаление из /etc/ufw/before.rules
    remove_ufw_before_rules_antiabuse
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        ufw reload >/dev/null 2>&1 || true
    fi

    # Очистка legacy хуков и сервисов
    if [[ -f /etc/ufw/after.init ]]; then
        sed -i '/# START JUST1KNODE ANTI-ABUSE HOOK/,/# END JUST1KNODE ANTI-ABUSE HOOK/d' /etc/ufw/after.init 2>/dev/null || true
    fi
    if [[ -f /etc/systemd/system/just1knode-antiabuse.service ]]; then
        rm -f /etc/systemd/system/just1knode-antiabuse.service 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
    fi

    # Удаление xt_string из автозагрузки при удалении
    if [[ -f /etc/modules-load.d/just1knode.conf ]]; then
        sed -i '/^xt_string$/d' /etc/modules-load.d/just1knode.conf 2>/dev/null || true
        if [[ ! -s /etc/modules-load.d/just1knode.conf ]] || ! grep -q '[^[:space:]]' /etc/modules-load.d/just1knode.conf 2>/dev/null; then
            rm -f /etc/modules-load.d/just1knode.conf 2>/dev/null || true
        fi
    fi

    set_state_val "abuse_protection" "disabled"
    log "✔ Правила сетевой защиты Anti-Abuse успешно очищены."
}

