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
    if [[ "${JUST1KNODE_INTERACTIVE:-0}" == "1" ]]; then
        return 1
    fi
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

ensure_nginx_nofile_limits() {
    local systemd_dir="${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
    local dropin_dir="${systemd_dir}/nginx.service.d"
    local dropin_file="${dropin_dir}/limits.conf"
    local desired="[Service]
LimitNOFILE=65535"
    local changed=0

    mkdir -p "$dropin_dir" 2>/dev/null || return 0
    if [[ ! -f "$dropin_file" ]] || [[ "$(cat "$dropin_file" 2>/dev/null || true)" != "$desired" ]]; then
        printf '%s\n' "$desired" > "$dropin_file" 2>/dev/null || true
        chmod 644 "$dropin_file" 2>/dev/null || true
        changed=1
        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload 2>/dev/null || true
        fi
    fi

    NGINX_NEEDS_NOFILE_RESTART=0
    if [[ $changed -eq 1 ]]; then
        NGINX_NEEDS_NOFILE_RESTART=1
    elif command -v pgrep >/dev/null 2>&1; then
        local ngx_pid max_fd
        ngx_pid="$(pgrep -x nginx 2>/dev/null | head -n1 || true)"
        if [[ -n "$ngx_pid" && -r "/proc/${ngx_pid}/limits" ]]; then
            max_fd="$(awk '/Max open files/{print $4}' "/proc/${ngx_pid}/limits" 2>/dev/null | head -n1 || true)"
            if [[ "$max_fd" =~ ^[0-9]+$ && "$max_fd" -lt 65535 ]]; then
                NGINX_NEEDS_NOFILE_RESTART=1
            fi
        fi
    fi
    return 0
}

install_nginx_if_missing() {
    if ! command -v nginx >/dev/null 2>&1; then
        log "Установка Nginx, mod-stream и Certbot..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq nginx libnginx-mod-stream certbot python3-certbot-nginx ca-certificates || \
            apt-get install -y -qq nginx certbot python3-certbot-nginx ca-certificates
        # Отключаем дефолтный сайт сразу после установки пакета для предотвращения конфликта портов
        local def_site="${NGINX_CONF_DIR:-/etc/nginx}/sites-enabled/default"
        if [[ -f "$def_site" || -L "$def_site" ]]; then
            cp -L "$def_site" "${NGINX_CONF_DIR:-/etc/nginx}/sites-available/default.user.bak" 2>/dev/null || true
            rm -f "$def_site" 2>/dev/null || true
        fi
        ensure_nginx_nofile_limits
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
# shellcheck disable=SC2120
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

ping_xray_api_health() {
    local api_key=""
    if [[ -f "${XRAY_API_CONFIG_ENV:-/etc/xray-api/config.env}" ]]; then
        api_key="$(grep -m1 '^XRAY_API_KEY=' "${XRAY_API_CONFIG_ENV:-/etc/xray-api/config.env}" 2>/dev/null | cut -d= -f2- || true)"
    fi
    if [[ -n "$api_key" ]]; then
        curl -sf -H "X-API-Key: ${api_key}" http://127.0.0.1:5001/v1/health >/dev/null 2>&1 || true
    fi
}

ensure_xray_api_healthy() {
    local force="${1:-0}"
    # Функция вызывается на узлах, где установлен агент xray-api (ru_hub / модульный узел с VLESS).
    if [[ ! -f /etc/systemd/system/xray-api.service && ! -f /lib/systemd/system/xray-api.service ]]; then
        return 0
    fi

    # В v2 агент xray-api работает на всех управляемых узлах (при наличии установленного конфига/роли)
    local role
    role="$(get_state_val "role" "unconfigured")"
    if [[ "$force" != "1" && "$role" != "ru_hub" && "$role" != "eu_hub" && "$role" != "exit_node" && ! -f "${XRAY_API_CONFIG_ENV:-/etc/xray-api/config.env}" ]]; then
        return 0
    fi

    # 1. Если служба уже активна (systemd автоматически перезапустил её через PartOf=xray.service),
    # повторный restart категорически не вызываем, чтобы не провоцировать start-limit-hit.
    if systemctl is-active --quiet xray-api 2>/dev/null; then
        ping_xray_api_health
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
        ping_xray_api_health
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
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
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
_ufw_delete_rules_by_comment() {
    local match_comment="$1"
    [[ -n "$match_comment" ]] || return 0
    command -v ufw >/dev/null 2>&1 || return 0
    ufw status 2>/dev/null | grep -qi "Status: active" || return 0

    local stale_nums=()
    local rule_line r_n r_body
    while IFS= read -r rule_line; do
        [[ -z "$rule_line" ]] && continue
        if [[ "$rule_line" =~ ^\[[[:space:]]*([0-9]+)\][[:space:]]+(.*)$ ]]; then
            r_n="${BASH_REMATCH[1]}"
            r_body="${BASH_REMATCH[2]}"
            if echo "$r_body" | grep -Fqi "$match_comment"; then
                stale_nums+=("$r_n")
            fi
        fi
    done < <(ufw status numbered 2>/dev/null || true)

    if [[ ${#stale_nums[@]} -gt 0 ]]; then
        local rn_s
        for rn_s in $(printf "%s\n" "${stale_nums[@]}" | sort -rn -u); do
            [[ -n "$rn_s" ]] && (ufw --force delete "$rn_s" >/dev/null 2>&1 || echo "y" | ufw delete "$rn_s" >/dev/null 2>&1 || true)
        done
    fi
}

heal_node_firewall_and_stealth() {
    # 1. Применяем системное скрытие (IPv6 leak protection + ICMP stealth)
    apply_node_sysctl_hardening

    # 2. Авто-активация UFW при необходимости (Zero-Lockout стандарт)
    if ! command -v ufw >/dev/null 2>&1; then
        apt-get install -y -qq ufw >/dev/null 2>&1 || true
    fi

    if ! command -v ufw >/dev/null 2>&1; then
        warn "Фаервол UFW недоступен в системе. Пропуск настройки правил фаервола."
        return 0
    fi

    if ! ufw status 2>/dev/null | grep -qi "Status: active"; then
        # shellcheck disable=SC2119
        configure_safe_ufw || {
            error "КРИТИЧЕСКАЯ ОШИБКА: Не удалось безопасно инициализировать UFW во избежание потери SSH."
            return 1
        }
    fi

    if ! ufw status 2>/dev/null | grep -qi "Status: active"; then
        warn "Фаервол UFW не в состоянии active. Пропуск настройки правил."
        return 0
    fi

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

    # 3. Панель API узла (8444/tcp строго по BOT_IP — Fail-Closed)
    local cur_bot_ip
    cur_bot_ip="$(get_state_val "bot_ip" 2>/dev/null || true)"

    if ! is_ssh_port "8444"; then
        if ufw status 2>/dev/null | grep -E "8444(/tcp)?[[:space:]]+ALLOW[[:space:]]+(Anywhere|0\.0\.0\.0/0|::/0)" -q; then
            ufw delete allow 8444/tcp >/dev/null 2>&1 || true
            ufw delete allow 8444 >/dev/null 2>&1 || true
            warn "Фаервол UFW: устранена уязвимость — удалено глобальное правило на порт 8444."
        fi
    fi

    if [[ -n "$cur_bot_ip" && "$cur_bot_ip" != "any" && "$cur_bot_ip" != "-" ]] && (validate_ip "$cur_bot_ip" || validate_ipv4 "$cur_bot_ip"); then
        local bot_ip_re="${cur_bot_ip//./\\.}"
        if ! ufw status 2>/dev/null | grep -E "(^|[[:space:]])${bot_ip_re}(/32)?([[:space:]]|$)" | grep -q "8444"; then
            if ufw allow from "$cur_bot_ip" to any port 8444 proto tcp comment "just1knode api" >/dev/null 2>&1; then
                log "Фаервол UFW: подтвержден доступ к порту 8444 для BOT_IP (${cur_bot_ip})"
            fi
        fi
    else
        warn "BOT_IP не задан в state.json. Порт API (8444) закрыт от мира (Fail-Closed)."
    fi

    # 5. Роли v2 периметра (Zero-Trust: 443 для мира открыт ТОЛЬКО на ru_hub с включённым транспортом)
    local links_file="${LINKS_FILE:-${STATE_DIR:-/etc/just1knode}/links.json}"
    local state_file="${STATE_FILE:-/etc/just1knode/state.json}"

    _ufw_sync_whitelist_port() {
        local wl_port="$1"
        local wl_comment="$2"
        local mode="$3" # eu_hub | exit_node
        if ! is_ssh_port "$wl_port"; then
            if ufw status 2>/dev/null | grep -E "(^|[[:space:]])${wl_port}(/tcp)?[[:space:]]+ALLOW[[:space:]]+(Anywhere|0\.0\.0\.0/0|::/0)" -q; then
                ufw delete allow "${wl_port}/tcp" >/dev/null 2>&1 || true
                ufw delete allow "${wl_port}" >/dev/null 2>&1 || true
                warn "Фаервол UFW: устранена уязвимость — удалён публичный доступ к порту ${wl_port} (${mode})."
            fi
        fi

        local allowed_ips=()
        local ip_cand
        while IFS= read -r ip_cand; do
            [[ -n "$ip_cand" ]] && allowed_ips+=("$ip_cand")
        done < <(python3 -c '
import json, sys

state_path, links_path, mode = sys.argv[1:4]
def load_d(p):
    try:
        with open(p, "r", encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}

st = load_d(state_path)
lk = load_d(links_path)
seen = []

def add_ip(v):
    s = str(v or "").strip()
    if s and s != "-" and s not in seen:
        seen.append(s)

keys = ("allowed_ru_ips",) if mode == "eu_hub" else ("allowed_hub_ips", "allowed_ru_ips", "eu_hub_ips")
for src in (lk, st):
    for k in keys:
        vals = src.get(k)
        if isinstance(vals, list):
            for x in vals:
                if isinstance(x, dict):
                    add_ip(x.get("ip"))
                else:
                    add_ip(x)

if mode == "eu_hub":
    for arr_k in ("incoming_ru_hubs", "incoming_hubs"):
        for item in (lk.get(arr_k) or []):
            if isinstance(item, dict):
                add_ip(item.get("ip"))
else:
    for arr_k in ("incoming_hubs", "incoming_eu_hubs"):
        for item in (lk.get(arr_k) or []):
            if isinstance(item, dict):
                add_ip(item.get("ip"))

for ip in seen:
    print(ip)
' "$state_file" "$links_file" "$mode" 2>/dev/null || true)

        # Отзыв устаревших правил UFW этого типа, которых больше нет в белом списке
        local stale_nums=()
        local rule_line r_n r_body
        while IFS= read -r rule_line; do
            [[ -z "$rule_line" ]] && continue
            if [[ "$rule_line" =~ ^\[[[:space:]]*([0-9]+)\][[:space:]]+(.*)$ ]]; then
                r_n="${BASH_REMATCH[1]}"
                r_body="${BASH_REMATCH[2]}"
                if echo "$r_body" | grep -Fq "$wl_comment"; then
                    local keep=0 a_ip
                    for a_ip in "${allowed_ips[@]}"; do
                        local a_ip_re="${a_ip//./\\.}"
                        if echo "$r_body" | grep -Eq "(^|[[:space:]])${a_ip_re}(/32)?([[:space:]]|$)"; then
                            keep=1
                            break
                        fi
                    done
                    [[ "$keep" -eq 0 ]] && stale_nums+=("$r_n")
                fi
            fi
        done < <(ufw status numbered 2>/dev/null || true)

        if [[ ${#stale_nums[@]} -gt 0 ]]; then
            local rn_s
            for rn_s in $(printf "%s\n" "${stale_nums[@]}" | sort -rn -u); do
                [[ -n "$rn_s" ]] && echo "y" | ufw delete "$rn_s" >/dev/null 2>&1 || true
            done
        fi

        local aip aip_re
        for aip in "${allowed_ips[@]}"; do
            if validate_ipv4 "$aip" || validate_ip "$aip"; then
                aip_re="${aip//./\\.}"
                if ! ufw status 2>/dev/null | grep -E "(^|[[:space:]])${aip_re}(/32)?([[:space:]]|$)" | grep -q "$wl_port"; then
                    ufw allow from "$aip" to any port "$wl_port" proto tcp comment "$wl_comment" >/dev/null 2>&1 || true
                fi
            fi
        done
    }

    if [[ "$role" == "ru_hub" ]]; then
        if is_module_enabled "vless_tls" 2>/dev/null || is_module_enabled "vless_xhttp" 2>/dev/null; then
            if ! ufw status 2>/dev/null | grep -E "443(/tcp)?[[:space:]]+ALLOW[[:space:]]+(Anywhere|0\.0\.0\.0/0|::/0)" -q; then
                ufw allow 443/tcp comment "just1knode hub ingress" >/dev/null 2>&1 || true
            fi
        elif ! is_ssh_port "443"; then
            _ufw_delete_rules_by_comment "just1knode hub ingress"
        fi
    elif [[ "$role" == "eu_hub" ]]; then
        local bridge_port
        bridge_port="$(get_state_val "relay_port" "443")"
        [[ "$bridge_port" =~ ^[0-9]+$ ]] || bridge_port="443"
        _ufw_sync_whitelist_port "$bridge_port" "just1knode eu_hub bridge" "eu_hub"
    elif [[ "$role" == "exit_node" ]]; then
        _ufw_sync_whitelist_port "443" "just1knode exit ingress" "exit_node"
    else
        # Не сконфигурирован: удаляем правила ingress/bridge Just1kNode, если остались
        if ! is_ssh_port "443"; then
            _ufw_delete_rules_by_comment "just1knode hub ingress"
            _ufw_delete_rules_by_comment "just1knode eu_hub bridge"
            _ufw_delete_rules_by_comment "just1knode exit ingress"
        fi
    fi

    # 6. Защита веб-периметра: удаление временных правил certbot для Just1kNode
    if ! command -v certbot >/dev/null 2>&1 || [[ ! -f /run/just1knode_certbot_active ]]; then
        _ufw_delete_rules_by_comment "just1knode certbot verification"
    fi
}

sync_xhttp_upstreams_conf() {
    local conf_d="${NGINX_CONF_DIR:-/etc/nginx}/conf.d"
    local upstreams_file="${conf_d}/just1k-xhttp-upstreams.conf"
    local cfg_file="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"

    mkdir -p "$conf_d" 2>/dev/null || true
    create_backup "$upstreams_file" 2>/dev/null || true

    if ! python3 -c "
import json, os, tempfile, sys, re

upstreams_file = sys.argv[1]
cfg_file = sys.argv[2]

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
for t, p in xray_inbound_ports.items():
    if t.startswith('just1k-wl-inbound-'):
        c_tag = t[len('just1k-wl-inbound-'):].strip().lower()
        if c_tag and re.fullmatch(r'^[a-z0-9_-]+$', c_tag) and c_tag not in seen_codes:
            try:
                port_num = int(p)
                seen_codes.add(c_tag)
                lines.append(f'upstream xray_xhttp_loc_{c_tag} {{')
                lines.append(f'    server 127.0.0.1:{port_num};')
                lines.append('    keepalive 128;')
                lines.append('    keepalive_requests 100000;')
                lines.append('    keepalive_timeout 300s;')
                lines.append('}')
                lines.append('')
            except Exception:
                continue
    elif t.startswith('just1k-wl-') and t not in ('just1k-wl-default', 'just1k-wl-api-grpc'):
        m_tag = t[len('just1k-wl-'):].strip().lower()
        if m_tag and re.fullmatch(r'^[a-z0-9_-]+$', m_tag):
            try:
                port_num = int(p)
                lines.append(f'upstream xray_xhttp_{m_tag} {{')
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
" "$upstreams_file" "$cfg_file"; then
        warn "Не удалось сгенерировать Nginx upstreams для XHTTP ($upstreams_file)"
        return 1
    fi
    return 0
}

detect_node_country_code() {
    local ip="${1:-}"
    if [[ -z "$ip" || "$ip" == "127.0.0.1" ]]; then
        return 1
    fi

    # Если задано в переменной окружения
    if [[ -n "${JUST1KNODE_COUNTRY:-}" && "${#JUST1KNODE_COUNTRY}" -eq 2 ]]; then
        echo "${JUST1KNODE_COUNTRY,,}"
        return 0
    fi

    # Последовательный запрос без зависаний
    local c_code=""
    c_code="$(python3 -c "
import urllib.request, json, sys
ip = sys.argv[1]
urls = [f'https://ipwho.is/{ip}', f'https://ipinfo.io/{ip}/json']
for u in urls:
    try:
        req = urllib.request.Request(u, headers={'User-Agent': 'curl/7.88.1'})
        with urllib.request.urlopen(req, timeout=3.0) as r:
            d = json.loads(r.read().decode('utf-8'))
            c = d.get('country_code') or d.get('country')
            if c and len(c) == 2:
                print(c.lower())
                sys.exit(0)
    except Exception:
        continue
" "$ip" 2>/dev/null || true)"

    if [[ -n "$c_code" && "${#c_code}" -eq 2 ]]; then
        echo "$c_code"
        return 0
    fi

    return 1
}

# =============================================================================
# СИСТЕМА ЗАЩИТЫ ОТ АБУЗА (ANTI-ABUSE: NETFILTER / IPTABLES / UFW)
# 1. Блокировка исходящего SMTP (порт 25) с tcp-reset
# 2. Блокировка BitTorrent L7 хэндшейка, DHT пакетов и трекеров через xt_string
# =============================================================================

_ensure_iptables_jump_first() {
    local chain="$1"
    local target="$2"
    local top_rule=""
    top_rule="$(iptables -S "$chain" 2>/dev/null | sed -n '2p' || true)"
    if [[ "$top_rule" == "-A ${chain} -j ${target}" ]]; then
        return 0
    fi
    while iptables -C "$chain" -j "$target" 2>/dev/null; do
        iptables -D "$chain" -j "$target" 2>/dev/null || break
    done
    iptables -I "$chain" 1 -j "$target"
}

_cleanup_legacy_ufw_before_rules_antiabuse() {
    local before_rules="/etc/ufw/before.rules"
    if [[ -f "$before_rules" ]] && grep -Fq "# START JUST1KNODE ANTI-ABUSE" "$before_rules" 2>/dev/null; then
        python3 -c "
import os, re, tempfile, sys
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
    local missing=0
    iptables -L JUST1KNODE-ANTIABUSE >/dev/null 2>&1 || return 1

    iptables -C FORWARD -j JUST1KNODE-ANTIABUSE 2>/dev/null || missing=$((missing + 1))
    [[ "$(iptables -S OUTPUT 2>/dev/null | sed -n '2p' || true)" == "-A OUTPUT -j JUST1KNODE-ANTIABUSE" ]] || missing=$((missing + 1))
    if iptables -L DOCKER-USER >/dev/null 2>&1; then
        iptables -C DOCKER-USER -j JUST1KNODE-ANTIABUSE 2>/dev/null || missing=$((missing + 1))
    fi

    if iptables -m mark --help >/dev/null 2>&1; then
        local _priv_cidr
        for _priv_cidr in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10 0.0.0.0/8; do
            iptables -C JUST1KNODE-ANTIABUSE -m mark --mark 255 -d "$_priv_cidr" -j DROP 2>/dev/null || missing=$((missing + 1))
        done
    fi

    iptables -C JUST1KNODE-ANTIABUSE -p tcp --dport 25 -j REJECT --reject-with tcp-reset 2>/dev/null || missing=$((missing + 1))
    iptables -C JUST1KNODE-ANTIABUSE -p tcp --dport 6881:6889 -j DROP 2>/dev/null || missing=$((missing + 1))
    iptables -C JUST1KNODE-ANTIABUSE -p udp --dport 6881:6889 -j DROP 2>/dev/null || missing=$((missing + 1))

    if iptables -m string --help 2>&1 | grep -q "\-\-algo"; then
        iptables -C JUST1KNODE-ANTIABUSE -p tcp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null || missing=$((missing + 1))
        iptables -C JUST1KNODE-ANTIABUSE -p udp -m string --string "BitTorrent protocol" --algo bm -j DROP 2>/dev/null || missing=$((missing + 1))
        iptables -C JUST1KNODE-ANTIABUSE -p udp -m string --string "d1:ad2:id20:" --algo bm -j DROP 2>/dev/null || missing=$((missing + 1))
        iptables -C JUST1KNODE-ANTIABUSE -p udp -m string --string "d1:rd2:id20:" --algo bm -j DROP 2>/dev/null || missing=$((missing + 1))
        iptables -C JUST1KNODE-ANTIABUSE -p udp -m string --hex-string "|0000041727101980|" --algo bm -j DROP 2>/dev/null || missing=$((missing + 1))
        iptables -C JUST1KNODE-ANTIABUSE -p tcp -m string --string "/announce?info_hash=" --algo bm -j DROP 2>/dev/null || missing=$((missing + 1))
    fi

    [[ $missing -eq 0 ]]
}

apply_antiabuse_protection() {
    log "Настройка сетевой защиты (Anti-Abuse: цепочка JUST1KNODE-ANTIABUSE)..."
    apply_node_sysctl_hardening

    modprobe xt_string 2>/dev/null || true
    if iptables -m string --help 2>&1 | grep -q "\-\-algo"; then
        mkdir -p /etc/modules-load.d 2>/dev/null || true
        if ! grep -q "^xt_string" /etc/modules-load.d/just1knode.conf 2>/dev/null; then
            echo "xt_string" >> /etc/modules-load.d/just1knode.conf 2>/dev/null || true
        fi
    fi

    # Очистка устаревших правок в /etc/ufw/before.rules (при переходе со старой схемы)
    _cleanup_legacy_ufw_before_rules_antiabuse

    iptables -N JUST1KNODE-ANTIABUSE 2>/dev/null || true
    iptables -F JUST1KNODE-ANTIABUSE

    # Защита от SSRF/loopback- и LAN-пивота через Xray freedom outbound (sockopt.mark=255)
    if iptables -m mark --help >/dev/null 2>&1; then
        local _priv_cidr
        for _priv_cidr in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10 0.0.0.0/8; do
            iptables -A JUST1KNODE-ANTIABUSE -m mark --mark 255 -d "$_priv_cidr" -j DROP
        done
    fi

    iptables -A JUST1KNODE-ANTIABUSE -p tcp --dport 25 -j REJECT --reject-with tcp-reset
    iptables -A JUST1KNODE-ANTIABUSE -p tcp --dport 6881:6889 -j DROP
    iptables -A JUST1KNODE-ANTIABUSE -p udp --dport 6881:6889 -j DROP

    if iptables -m string --help 2>&1 | grep -q "\-\-algo"; then
        iptables -A JUST1KNODE-ANTIABUSE -p tcp -m string --string "BitTorrent protocol" --algo bm -j DROP
        iptables -A JUST1KNODE-ANTIABUSE -p udp -m string --string "BitTorrent protocol" --algo bm -j DROP
        iptables -A JUST1KNODE-ANTIABUSE -p udp -m string --string "d1:ad2:id20:" --algo bm -j DROP
        iptables -A JUST1KNODE-ANTIABUSE -p udp -m string --string "d1:rd2:id20:" --algo bm -j DROP
        iptables -A JUST1KNODE-ANTIABUSE -p udp -m string --hex-string "|0000041727101980|" --algo bm -j DROP
        iptables -A JUST1KNODE-ANTIABUSE -p tcp -m string --string "/announce?info_hash=" --algo bm -j DROP
    fi

    _ensure_iptables_jump_first FORWARD JUST1KNODE-ANTIABUSE
    _ensure_iptables_jump_first OUTPUT JUST1KNODE-ANTIABUSE
    if iptables -L DOCKER-USER >/dev/null 2>&1; then
        _ensure_iptables_jump_first DOCKER-USER JUST1KNODE-ANTIABUSE
    fi

    if check_antiabuse_rules; then
        if [[ -f /etc/ufw/after.init ]] && grep -Fq "# START JUST1KNODE ANTI-ABUSE HOOK" /etc/ufw/after.init 2>/dev/null; then
            sed -i '/# START JUST1KNODE ANTI-ABUSE HOOK/,/# END JUST1KNODE ANTI-ABUSE HOOK/d' /etc/ufw/after.init 2>/dev/null || true
        fi
        local unit_file="${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}/just1knode-antiabuse.service"
        local bin_path="${JUST1KNODE_GLOBAL_BIN:-/usr/local/bin/just1knode}"
        if [[ -d "$(dirname "$unit_file")" && -x "$bin_path" ]]; then
            cat > "$unit_file" <<EOF
[Unit]
Description=Just1kNode Anti-Abuse iptables Rules
After=network-pre.target ufw.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${bin_path} --apply-antiabuse

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload 2>/dev/null || true
            systemctl enable just1knode-antiabuse.service 2>/dev/null || true
        fi
        log "✔ Цепочка JUST1KNODE-ANTIABUSE успешно активирована."
        set_state_val "abuse_protection" "enabled"
        return 0
    else
        warn "Не удалось активировать полный набор правил в JUST1KNODE-ANTIABUSE!"
        return 1
    fi
}

_iptables_delete_all() {
    while iptables -C "$@" 2>/dev/null; do
        iptables -D "$@" 2>/dev/null || break
    done
}

remove_antiabuse_protection() {
    log "Очистка правил сетевой защиты Anti-Abuse..."
    _iptables_delete_all FORWARD -j JUST1KNODE-ANTIABUSE
    _iptables_delete_all OUTPUT -j JUST1KNODE-ANTIABUSE
    if iptables -L DOCKER-USER >/dev/null 2>&1; then
        _iptables_delete_all DOCKER-USER -j JUST1KNODE-ANTIABUSE
    fi

    if iptables -L JUST1KNODE-ANTIABUSE >/dev/null 2>&1; then
        iptables -F JUST1KNODE-ANTIABUSE 2>/dev/null || true
        iptables -X JUST1KNODE-ANTIABUSE 2>/dev/null || true
    fi

    # Очистка возможных legacy-правил в /etc/ufw/before.rules
    _cleanup_legacy_ufw_before_rules_antiabuse

    if [[ -f /etc/ufw/after.init ]] && grep -Fq "# START JUST1KNODE ANTI-ABUSE HOOK" /etc/ufw/after.init 2>/dev/null; then
        sed -i '/# START JUST1KNODE ANTI-ABUSE HOOK/,/# END JUST1KNODE ANTI-ABUSE HOOK/d' /etc/ufw/after.init 2>/dev/null || true
    fi
    if [[ -f /etc/systemd/system/just1knode-antiabuse.service ]]; then
        rm -f /etc/systemd/system/just1knode-antiabuse.service 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
    fi

    if [[ -f /etc/modules-load.d/just1knode.conf ]]; then
        sed -i '/^xt_string$/d' /etc/modules-load.d/just1knode.conf 2>/dev/null || true
        if [[ ! -s /etc/modules-load.d/just1knode.conf ]] || ! grep -q '[^[:space:]]' /etc/modules-load.d/just1knode.conf 2>/dev/null; then
            rm -f /etc/modules-load.d/just1knode.conf 2>/dev/null || true
        fi
    fi

    set_state_val "abuse_protection" "disabled"
    log "✔ Правила сетевой защиты Anti-Abuse успешно очищены."
}

is_traffic_limit_exceeded() {
    local state_dir="${STATE_DIR:-/etc/just1knode}"
    [[ -f "${state_dir}/traffic_limit_exceeded" ]]
}

normalize_domain() {
    local raw="${1:-}"
    raw="$(echo "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's|^https\?://||' -e 's|/.*$||')"
    echo "$raw"
}

validate_fqdn() {
    local host="${1:-}"
    [[ -z "$host" ]] && return 1
    if [[ "$host" =~ [[:space:]\;\"\'\$\`\{\}\\\<\>\?\&\*\/] ]]; then
        return 1
    fi
    if [[ "$host" == "localhost" || "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 1
    fi
    if [[ ! "$host" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

set_bot_ip() {
    title "ОБНОВЛЕНИЕ IP-АДРЕСА TELEGRAM-БОТА (BOT_IP ДЛЯ ЗАЩИТЫ API)"
    check_root
    init_state_dir
    acquire_just1knode_lock

    local role
    role="$(get_state_val "role" "unconfigured")"
    local target_port="8444"
    local role_descr="Control API (порт 8444)"

    if [[ "$role" != "ru_hub" && "$role" != "eu_hub" && "$role" != "exit_node" && ! -f "${XRAY_API_CONFIG_ENV:-/etc/xray-api/config.env}" ]]; then
        release_just1knode_lock
        error "Функция доступна только при установленном xray-api или настроенной роли узла."
        return 1
    fi

    local new_bot_ip="${1:-}"
    if [[ -z "$new_bot_ip" && -t 0 ]]; then
        while true; do
            local input_bip=""
            if ! read -rp "Введите новый IP-адрес Telegram-бота (для защиты ${role_descr}, или 0 для отмены): " input_bip; then
                release_just1knode_lock
                warn "Ввод прерван."
                return 0
            fi
            input_bip="$(echo "$input_bip" | tr -d '[:space:]')"
            if [[ "$input_bip" == "0" || "$input_bip" == "q" || "$input_bip" == "Q" ]]; then
                release_just1knode_lock
                warn "Настройка IP-адреса Telegram-бота отменена."
                return 0
            fi
            if [[ -z "$input_bip" ]]; then
                warn "IP-адрес не может быть пустым. Попробуйте еще раз (или введите 0 для отмены)."
                continue
            fi
            if ! validate_ipv4 "$input_bip"; then
                warn "Недопустимый формат IP-адреса: '$input_bip' (ожидается валидный IPv4 адрес). Попробуйте еще раз."
                continue
            fi
            new_bot_ip="$input_bip"
            break
        done
    fi

    new_bot_ip="$(echo "$new_bot_ip" | tr -d '[:space:]')"
    if [[ -z "$new_bot_ip" ]]; then
        release_just1knode_lock
        error "IP-адрес не может быть пустым."
        return 1
    fi

    if ! validate_ipv4 "$new_bot_ip"; then
        release_just1knode_lock
        error "Недопустимый формат IP-адреса: '$new_bot_ip' (ожидается валидный IPv4 адрес)."
        return 1
    fi

    if ! command -v ufw >/dev/null 2>&1; then
        release_just1knode_lock
        error "Утилита UFW не найдена в системе. Настройка фаервола невозможна."
        return 1
    fi
    if ! ufw status 2>/dev/null | grep -qi "Status: active"; then
        release_just1knode_lock
        error "Фаервол UFW не активен (Status: inactive). Для безопасного обновления порта ${target_port} UFW должен быть включен."
        return 1
    fi

    local old_bot_ip new_bot_ip_re
    old_bot_ip="$(get_state_val "bot_ip" 2>/dev/null || true)"
    new_bot_ip_re="${new_bot_ip//./\\.}"

    if [[ "$new_bot_ip" == "$old_bot_ip" ]] && ufw status 2>/dev/null | grep -E "(^|[[:space:]])${new_bot_ip_re}(/32)?([[:space:]]|$)" | grep -E -q "(^|[[:space:]])${target_port}(/tcp)?([[:space:]]|$)"; then
        if ! is_ssh_port "${target_port}"; then
            ufw delete allow "${target_port}/tcp" >/dev/null 2>&1 || true
            ufw delete allow "${target_port}" >/dev/null 2>&1 || true
        fi
        log "BOT_IP ($new_bot_ip) уже установлен и подтвержден в UFW. Изменений не требуется."
        release_just1knode_lock
        return 0
    fi

    log "Применение нового правила фаервола UFW для ${role_descr} ($new_bot_ip)..."
    if ! ufw allow from "$new_bot_ip" to any port "$target_port" proto tcp comment "just1knode api"; then
        release_just1knode_lock
        error "Сбой выполнения команды 'ufw allow' для IP $new_bot_ip. Предыдущие правила сохранены."
        return 1
    fi

    if ! ufw status 2>/dev/null | grep -E "(^|[[:space:]])${new_bot_ip_re}(/32)?([[:space:]]|$)" | grep -E -q "(^|[[:space:]])${target_port}(/tcp)?([[:space:]]|$)"; then
        ufw delete allow from "$new_bot_ip" to any port "$target_port" proto tcp >/dev/null 2>&1 || true
        release_just1knode_lock
        error "Верификация не пройдена: правило для $new_bot_ip на порт $target_port отсутствует в UFW. Изменение откатано."
        return 1
    fi

    if ! set_state_val "bot_ip" "$new_bot_ip"; then
        ufw delete allow from "$new_bot_ip" to any port "$target_port" proto tcp >/dev/null 2>&1 || true
        release_just1knode_lock
        error "Сбой сохранения bot_ip в state.json. Новое правило для $new_bot_ip откатано, старый доступ сохранен."
        return 1
    fi

    if ! is_ssh_port "${target_port}"; then
        if [[ -n "$old_bot_ip" && "$old_bot_ip" != "$new_bot_ip" && "$old_bot_ip" != "any" && "$old_bot_ip" != "-" ]]; then
            ufw delete allow from "$old_bot_ip" to any port "$target_port" proto tcp >/dev/null 2>&1 || true
        fi
        ufw delete allow "${target_port}/tcp" >/dev/null 2>&1 || true
        ufw delete allow "${target_port}" >/dev/null 2>&1 || true
    fi

    log "BOT_IP успешно обновлен и зафиксирован в state.json: ${old_bot_ip:-не был задан} -> ${new_bot_ip}"
    release_just1knode_lock
}


