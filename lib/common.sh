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
        systemctl enable nginx 2>/dev/null || true
        systemctl restart nginx 2>/dev/null || true
    fi
}

ensure_nginx_stream_module() {
    install_nginx_if_missing
    command -v nginx >/dev/null 2>&1 || return 1
    if compgen -G "/etc/nginx/modules-enabled/*stream*.conf" >/dev/null 2>&1; then
        return 0
    fi
    if nginx -V 2>&1 | grep -qE -- '--with-stream([[:space:]]|$)'; then
        return 0
    fi
    if command -v apt-get >/dev/null 2>&1; then
        log "Доустановка модуля Nginx Stream (libnginx-mod-stream) для SNI-маршрутизации..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq libnginx-mod-stream >/dev/null 2>&1 || true
    fi
    compgen -G "/etc/nginx/modules-enabled/*stream*.conf" >/dev/null 2>&1
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

    # В v2 агент xray-api работает на всех управляемых узлах (при наличии установленного конфига/роли)
    local role
    role="$(get_state_val "role" "unconfigured")"
    if [[ "$force" != "1" && "$role" != "ru_hub" && "$role" != "eu_hub" && "$role" != "exit_node" && ! -f "${XRAY_API_CONFIG_ENV:-/etc/xray-api/config.env}" ]]; then
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

    # 4. Панель API узла (8444/tcp строго по BOT_IP — Fail-Closed)
    local origin_bot_ip
    origin_bot_ip="$(get_state_val "bot_ip" 2>/dev/null || true)"

    if ! is_ssh_port "8444"; then
        if ufw status 2>/dev/null | grep -E "8444(/tcp)?[[:space:]]+ALLOW[[:space:]]+(Anywhere|0\.0\.0\.0/0|::/0)" -q; then
            ufw delete allow 8444/tcp >/dev/null 2>&1 || true
            ufw delete allow 8444 >/dev/null 2>&1 || true
            warn "Фаервол UFW: устранена уязвимость — удалено глобальное правило на порт 8444."
        fi
    fi

    if [[ -n "$origin_bot_ip" && "$origin_bot_ip" != "any" && "$origin_bot_ip" != "-" ]] && (validate_ip "$origin_bot_ip" || validate_ipv4 "$origin_bot_ip"); then
        local bot_ip_re="${origin_bot_ip//./\\.}"
        if ! ufw status 2>/dev/null | grep -E "(^|[[:space:]])${bot_ip_re}(/32)?([[:space:]]|$)" | grep -q "8444"; then
            if ufw allow from "$origin_bot_ip" to any port 8444 proto tcp comment "just1knode origin api" >/dev/null 2>&1; then
                log "Фаервол UFW: подтвержден доступ к порту 8444 для BOT_IP (${origin_bot_ip})"
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
            if ufw status 2>/dev/null | grep -E "(^|[[:space:]])443(/tcp)?[[:space:]]+ALLOW" -q; then
                ufw delete allow 443/tcp >/dev/null 2>&1 || true
                ufw delete allow 443 >/dev/null 2>&1 || true
            fi
        fi
    elif [[ "$role" == "eu_hub" ]]; then
        local bridge_port
        bridge_port="$(get_state_val "relay_port" "443")"
        [[ "$bridge_port" =~ ^[0-9]+$ ]] || bridge_port="443"
        _ufw_sync_whitelist_port "$bridge_port" "just1knode eu_hub bridge" "eu_hub"
    elif [[ "$role" == "exit_node" ]]; then
        _ufw_sync_whitelist_port "443" "just1knode exit ingress" "exit_node"
    else
        # Не сконфигурирован: держим 443 закрытым (Fail-Closed Stealth)
        if ! is_ssh_port "443"; then
            if ufw status 2>/dev/null | grep -E "(^|[[:space:]])443(/tcp)?[[:space:]]+ALLOW" -q; then
                ufw delete allow 443/tcp >/dev/null 2>&1 || true
                ufw delete allow 443 >/dev/null 2>&1 || true
            fi
        fi
    fi

    # 6. Защита веб-периметра: закрытие публичного порта 80 (Zero-Signature)
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
}

sync_xhttp_upstreams_conf() {
    local conf_d="${NGINX_CONF_DIR:-/etc/nginx}/conf.d"
    local upstreams_file="${conf_d}/just1k-xhttp-upstreams.conf"
    local cfg_file="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"

    mkdir -p "$conf_d" 2>/dev/null || true
    manifest_track_file "$upstreams_file" 2>/dev/null || true
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
                lines.append(f'upstream xray_xhttp_relay_{c_tag} {{')
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
            if grep -Fq "# START JUST1KNODE ANTI-ABUSE HOOK" /etc/ufw/after.init 2>/dev/null && grep -Fq "# END JUST1KNODE ANTI-ABUSE HOOK" /etc/ufw/after.init 2>/dev/null; then
                sed -i '/# START JUST1KNODE ANTI-ABUSE HOOK/,/# END JUST1KNODE ANTI-ABUSE HOOK/d' /etc/ufw/after.init 2>/dev/null || true
            fi
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
        if grep -Fq "# START JUST1KNODE ANTI-ABUSE HOOK" /etc/ufw/after.init 2>/dev/null && grep -Fq "# END JUST1KNODE ANTI-ABUSE HOOK" /etc/ufw/after.init 2>/dev/null; then
            sed -i '/# START JUST1KNODE ANTI-ABUSE HOOK/,/# END JUST1KNODE ANTI-ABUSE HOOK/d' /etc/ufw/after.init 2>/dev/null || true
        fi
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

cleanup_legacy_traffic_watchdog_residue() {
    local systemd_dir="${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop just1knode-traffic.timer just1knode-traffic.service 2>/dev/null || true
        systemctl disable just1knode-traffic.timer just1knode-traffic.service 2>/dev/null || true
    fi
    rm -f "${systemd_dir}/just1knode-traffic.service" "${systemd_dir}/just1knode-traffic.timer" 2>/dev/null || true
    rm -f "${systemd_dir}/xray.service.d/traffic-cutoff.conf" 2>/dev/null || true
    rm -f "${STATE_DIR:-/etc/just1knode}/traffic_cutoff.active" /etc/just1knode/traffic_cutoff.active 2>/dev/null || true
    rm -f "${STATE_DIR:-/etc/just1knode}/traffic_monthly.json" /etc/just1knode/traffic_monthly.json 2>/dev/null || true
    rm -f /run/just1knode_traffic_cutoff "${RUN_DIR:-/run}/just1knode_traffic_cutoff" 2>/dev/null || true
    if [[ -d "${systemd_dir}/xray.service.d" ]] && [[ -z "$(ls -A "${systemd_dir}/xray.service.d" 2>/dev/null)" ]]; then
        rmdir "${systemd_dir}/xray.service.d" 2>/dev/null || true
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl reset-failed just1knode-traffic.service just1knode-traffic.timer 2>/dev/null || true
    fi
}

is_traffic_limit_exceeded() {
    local state_dir="${STATE_DIR:-/etc/just1knode}"
    [[ -f "${state_dir}/traffic_limit_exceeded" || -f "${state_dir}/traffic_cutoff.active" ]]
}

safe_restart_xray() {
    if is_traffic_limit_exceeded; then
        warn "Лимит трафика исчерпан (активен флаг traffic_limit_exceeded) — запуск Xray пропущен."
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart xray
    fi
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

validate_sub_prefix() {
    local prefix="${1:-}"
    [[ -z "$prefix" ]] && return 1
    if [[ "$prefix" =~ [[:space:]\;\"\'\$\`\{\}\\\<\>\?\&\*] || "$prefix" =~ \.\. ]]; then
        return 1
    fi
    if [[ ! "$prefix" =~ ^/[a-zA-Z0-9_/-]+$ ]]; then
        return 1
    fi
    return 0
}

set_origin_bot_ip() {
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


