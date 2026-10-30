#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE - Установка и настройка Relay Узла (modules/xray/relay.sh)
# =============================================================================

validate_relay_dns() {
    local domain="${1:-}"
    local expected_ip="${2:-}"

    if [[ -z "$domain" ]]; then
        error "Домен Relay не может быть пустым."
        return 1
    fi

    while true; do
        log "Проверка DNS A-записи домена $domain (ожидается IP: ${expected_ip:-текущий хост})..."
        local dns_res
        dns_res=$(python3 -c "
import socket, sys, re
domain = sys.argv[1].strip()
expected = sys.argv[2].strip() if len(sys.argv) > 2 else ''

if re.search(r'[\u0400-\u04FF]', domain):
    print('CYRILLIC')
    sys.exit(0)

if not re.match(r'^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$', domain):
    print('INVALID_FQDN')
    sys.exit(0)

if expected and (':' in expected or not re.match(r'^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$', expected)):
    print(f'INVALID_EXPECTED|{expected}')
    sys.exit(0)

try:
    addr_info = socket.getaddrinfo(domain, None, socket.AF_INET, socket.SOCK_STREAM)
    ips = list(dict.fromkeys([ai[4][0] for ai in addr_info if ai[4]]))
    if not ips:
        print('NO_RECORDS')
    elif not expected:
        print(f'NO_EXPECTED|{ips[0]}')
    elif expected not in ips:
        print('MISMATCH|' + ','.join(ips))
    else:
        print(f'OK|{ips[0]}')
except Exception as e:
    print(f'ERROR|{e}')
" "$domain" "$expected_ip" 2>/dev/null || true)

        if [[ "$dns_res" == "CYRILLIC" ]]; then
            error "Домен '$domain' содержит русские (кириллические) буквы! Проверьте раскладку клавиатуры и введите латинский домен."
            return 1
        elif [[ "$dns_res" == "INVALID_FQDN" ]]; then
            error "Некорректный формат домена: '$domain'. Ожидается валидное имя FQDN (например: your-relay.yourdomain.com)."
            return 1
        elif echo "$dns_res" | grep -q "^INVALID_EXPECTED|"; then
            local bad_exp="${dns_res#INVALID_EXPECTED|}"
            warn "Ожидаемый IP сервера '$bad_exp' не является валидным IPv4 адресом. Сверка DNS A-записи невозможна."
        elif echo "$dns_res" | grep -q "^OK|"; then
            local resolved_ip="${dns_res#OK|}"
            log "✔ DNS A-запись подтверждена: $domain ➔ $resolved_ip"
            return 0
        elif echo "$dns_res" | grep -q "^MISMATCH|"; then
            local mismatch_ip="${dns_res#MISMATCH|}"
            warn "DNS A-запись для '$domain' указывает на IP $mismatch_ip, а ожидаемый IP этого сервера: $expected_ip."
            warn "Возможные причины: в Cloudflare включен Proxy (оранжевое облако вместо серого) или не обновился кэш DNS."
        elif echo "$dns_res" | grep -q "^NO_EXPECTED|"; then
            local resolved_ip="${dns_res#NO_EXPECTED|}"
            warn "DNS A-запись для '$domain' указывает на IP $resolved_ip, но публичный IPv4 этого сервера не определен."
            warn "Невозможно автоматически подтвердить соответствие IP серверу."
        else
            local err_msg="${dns_res#ERROR|}"
            warn "DNS-запись для '$domain' пока не найдена ($err_msg)."
        fi

        # Интерактивный диалог при задержке DNS-репликации
        if [[ -t 0 ]]; then
            echo -e "\n${YELLOW}Действие:${NC}"
            echo -e "  [1] Повторить проверку DNS через 5 секунд (подождать обновление)"
            echo -e "  [2] Игнорировать и продолжить (если вы уверены, что A-запись верна)"
            echo -e "  [0] Отмена"
            local retry_choice=""
            read -rp "Выберите вариант [1/2/0, по умолчанию 1]: " retry_choice || return 1
            case "${retry_choice:-1}" in
                1) sleep 5; continue ;;
                2) log "Проверка DNS пропущена по выбору пользователя."; return 0 ;;
                *) error "Настройка отменена."; return 1 ;;
            esac
        else
            if [[ -n "$expected_ip" ]]; then
                error "DNS-валидация не пройдена в неинтерактивном режиме для '$domain' (ожидался $expected_ip)."
            else
                error "DNS-валидация не пройдена в неинтерактивном режиме для '$domain' (публичный IPv4 сервера не определён)."
            fi
            return 1
        fi
    done
}

issue_relay_tls_cert() {
    local domain="$1"
    local target_prefix="${2:-}"
    if [[ -z "$domain" ]]; then
        error "Домен обязателен для выпуска сертификата."
        return 1
    fi

    local le_dir="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
    local xray_tls_dir="${XRAY_TLS_DIR:-/usr/local/etc/xray/tls}"
    install -d -m 750 "$xray_tls_dir" 2>/dev/null || mkdir -p "$xray_tls_dir"
    chown root:nogroup "$xray_tls_dir" 2>/dev/null || true

    # Очистка устаревших глобальных pre/post хуков во избежание остановки веб-серверов сторонних доменов
    rm -f "${le_dir}/renewal-hooks/pre/05-just1knode-nginx.sh" \
          "${le_dir}/renewal-hooks/post/05-just1knode-nginx.sh" \
          "${le_dir}/renewal-hooks/deploy/restart-xray.sh" 2>/dev/null || true

    # Постоянный deploy-хук для Certbot: копирование ключей и перезапуск Xray при автообновлении сертификата Relay
    install -d -m 755 "${le_dir}/renewal-hooks/deploy"

    cat > "${le_dir}/renewal-hooks/deploy/20-just1knode-restart-xray.sh" <<'EOF'
#!/bin/sh
set -eu
STATE_FILE="/etc/just1knode/state.json"
RELAY_SNI=""
VLESS_DOMAIN=""
HAS_VLESS="0"
if [ -f "$STATE_FILE" ]; then
    RELAY_SNI=$(grep -o '"sni": *"[^"]*"' "$STATE_FILE" 2>/dev/null | head -n1 | cut -d'"' -f4 || true)
    VLESS_DOMAIN=$(grep -o '"vless_domain": *"[^"]*"' "$STATE_FILE" 2>/dev/null | head -n1 | cut -d'"' -f4 || true)
    HAS_VLESS=$(grep -o '"has_vless": *"[^"]*"' "$STATE_FILE" 2>/dev/null | head -n1 | cut -d'"' -f4 || true)
fi

TARGET_DIR="/usr/local/etc/xray/tls"
install -d -m 750 -o root -g nogroup "$TARGET_DIR"

restarted=0
if [ -n "${RENEWED_LINEAGE:-}" ]; then
    if [ -n "$RELAY_SNI" ] && [ "$(basename "$RENEWED_LINEAGE")" = "$RELAY_SNI" ]; then
        if [ -f "${RENEWED_LINEAGE}/fullchain.pem" ] && [ -f "${RENEWED_LINEAGE}/privkey.pem" ]; then
            install -m 640 -o root -g nogroup "${RENEWED_LINEAGE}/fullchain.pem" "${TARGET_DIR}/fullchain.pem"
            install -m 640 -o root -g nogroup "${RENEWED_LINEAGE}/privkey.pem" "${TARGET_DIR}/privkey.pem"
            restarted=1
        fi
    fi
    if [ "$HAS_VLESS" = "1" ] && [ -n "$VLESS_DOMAIN" ] && [ "$(basename "$RENEWED_LINEAGE")" = "$VLESS_DOMAIN" ]; then
        if [ -f "${RENEWED_LINEAGE}/fullchain.pem" ] && [ -f "${RENEWED_LINEAGE}/privkey.pem" ]; then
            install -m 640 -o root -g nogroup "${RENEWED_LINEAGE}/fullchain.pem" "${TARGET_DIR}/vless_fullchain.pem"
            install -m 640 -o root -g nogroup "${RENEWED_LINEAGE}/privkey.pem" "${TARGET_DIR}/vless_privkey.pem"
            restarted=1
        fi
    fi
fi

if [ "$restarted" = "1" ]; then
    if [ -x /usr/local/bin/xray ] && [ -f /usr/local/etc/xray/config.json ]; then
        if /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1; then
            systemctl restart xray 2>/dev/null || true
        fi
    else
        systemctl restart xray 2>/dev/null || true
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || true
    fi
fi
EOF
    chmod 755 "${le_dir}/renewal-hooks/deploy/20-just1knode-restart-xray.sh"

    local pre_hook_cmd="sh -c 'if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then touch /run/just1knode_nginx_was_active && systemctl stop nginx 2>/dev/null || true; fi; if command -v docker >/dev/null 2>&1; then if docker ps --format \"{{.Names}}\t{{.Ports}}\" 2>/dev/null | grep -E \"(^|[[:space:],])([0-9\.:]+|\[::\]|:::):80->[0-9]+/tcp\" | grep -q \"^just1kbot_caddy\b\"; then if docker stop just1kbot_caddy >/dev/null 2>&1; then echo \"just1kbot_caddy\" > /run/just1knode_caddy_was_paused; fi; fi; fi; if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi \"Status: active\"; then if ! ufw status 2>/dev/null | grep -E \"(^|[[:space:]])80(/tcp)?[[:space:]]+ALLOW\" -q; then touch /run/just1knode_ufw_opened_80 && ufw allow 80/tcp comment \"just1knode certbot verification\" >/dev/null 2>&1 || true; fi; fi'"
    local post_hook_cmd="sh -c 'if [ -f /run/just1knode_nginx_was_active ]; then rm -f /run/just1knode_nginx_was_active; command -v systemctl >/dev/null 2>&1 && systemctl start nginx 2>/dev/null || true; fi; if [ -f /run/just1knode_caddy_was_paused ]; then c80=\$(cat /run/just1knode_caddy_was_paused 2>/dev/null || true); if [ -n \"\$c80\" ] && command -v docker >/dev/null 2>&1; then docker start \"\$c80\" >/dev/null 2>&1 && rm -f /run/just1knode_caddy_was_paused; else rm -f /run/just1knode_caddy_was_paused; fi; fi; if [ -f /run/just1knode_ufw_opened_80 ]; then rm -f /run/just1knode_ufw_opened_80; if ! (command -v docker >/dev/null 2>&1 && docker ps --format \"{{.Ports}} {{.Names}}\" 2>/dev/null | grep -qE \"(:80->|just1kbot_caddy)\"); then ufw delete allow 80/tcp >/dev/null 2>&1 || true; ufw delete allow 80 >/dev/null 2>&1 || true; fi; fi'"

    # 2. Если действующий сертификат для этого домена УЖЕ существует на хосте — используем его!
    if [[ -f "${le_dir}/live/${domain}/fullchain.pem" && -f "${le_dir}/live/${domain}/privkey.pem" ]]; then
        if openssl x509 -checkend 86400 -noout -in "${le_dir}/live/${domain}/fullchain.pem" 2>/dev/null; then
            log "✔ Обнаружен действующий сертификат Let's Encrypt для '$domain'!"
            if [[ -n "$target_prefix" ]]; then
                install -m 640 "${le_dir}/live/${domain}/fullchain.pem" "${xray_tls_dir}/${target_prefix}_fullchain.pem" 2>/dev/null || cp -f "${le_dir}/live/${domain}/fullchain.pem" "${xray_tls_dir}/${target_prefix}_fullchain.pem"
                install -m 640 "${le_dir}/live/${domain}/privkey.pem" "${xray_tls_dir}/${target_prefix}_privkey.pem" 2>/dev/null || cp -f "${le_dir}/live/${domain}/privkey.pem" "${xray_tls_dir}/${target_prefix}_privkey.pem"
                chown root:nogroup "${xray_tls_dir}/${target_prefix}_fullchain.pem" "${xray_tls_dir}/${target_prefix}_privkey.pem" 2>/dev/null || true
            fi
            if [[ "$target_prefix" != "vless" ]]; then
                install -m 640 "${le_dir}/live/${domain}/fullchain.pem" "${xray_tls_dir}/fullchain.pem" 2>/dev/null || cp -f "${le_dir}/live/${domain}/fullchain.pem" "${xray_tls_dir}/fullchain.pem"
                install -m 640 "${le_dir}/live/${domain}/privkey.pem" "${xray_tls_dir}/privkey.pem" 2>/dev/null || cp -f "${le_dir}/live/${domain}/privkey.pem" "${xray_tls_dir}/privkey.pem"
                chown root:nogroup "${xray_tls_dir}/fullchain.pem" "${xray_tls_dir}/privkey.pem" 2>/dev/null || true
            elif [[ ! -f "${xray_tls_dir}/fullchain.pem" ]]; then
                install -m 640 "${le_dir}/live/${domain}/fullchain.pem" "${xray_tls_dir}/fullchain.pem" 2>/dev/null || cp -f "${le_dir}/live/${domain}/fullchain.pem" "${xray_tls_dir}/fullchain.pem"
                install -m 640 "${le_dir}/live/${domain}/privkey.pem" "${xray_tls_dir}/privkey.pem" 2>/dev/null || cp -f "${le_dir}/live/${domain}/privkey.pem" "${xray_tls_dir}/privkey.pem"
                chown root:nogroup "${xray_tls_dir}/fullchain.pem" "${xray_tls_dir}/privkey.pem" 2>/dev/null || true
            fi
            local ren_conf="${le_dir}/renewal/${domain}.conf"
            if [[ -f "$ren_conf" ]]; then
                python3 -c "
import sys
cf, pre_c, post_c = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(cf, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    new_lines = []
    has_pre = False
    has_post = False
    for l in lines:
        if l.strip().startswith('pre_hook'):
            new_lines.append(f'pre_hook = {pre_c}\n')
            has_pre = True
        elif l.strip().startswith('post_hook'):
            new_lines.append(f'post_hook = {post_c}\n')
            has_post = True
        else:
            new_lines.append(l)
    if not has_pre:
        new_lines.append(f'pre_hook = {pre_c}\n')
    if not has_post:
        new_lines.append(f'post_hook = {post_c}\n')
    with open(cf, 'w', encoding='utf-8') as f:
        f.writelines(new_lines)
except Exception:
    pass
" "$ren_conf" "$pre_hook_cmd" "$post_hook_cmd"
            fi
            log "✔ Сертификат успешно привязан к Xray (без повторного обращения к Certbot)."
            return 0
        else
            warn "Сертификат для '$domain' истек или истекает в течение 24 часов. Выполняется перевыпуск..."
        fi
    fi

    log "Проверка наличия Certbot для выпуска SSL Let's Encrypt..."
    if ! command -v certbot >/dev/null 2>&1; then
        log "Установка certbot..."
        apt-get update -qq && apt-get install -y certbot
    fi

    log "Запрос сертификата Let's Encrypt для $domain (Standalone ACME)..."
    log "Zero-Signature: порт 80 открывается только на время проверки и сразу закрывается."

    local ufw_active=0
    local port80_was_open=0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        ufw_active=1
        if ufw status 2>/dev/null | grep -E "(^|[[:space:]])80(/tcp)?[[:space:]]+ALLOW" -q; then
            port80_was_open=1
        else
            ufw allow 80/tcp comment "just1knode certbot verification" >/dev/null 2>&1 || true
            touch /run/just1knode_ufw_opened_80
        fi
    fi

    # Обнаружение Docker-контейнера на порту 80 (например, Caddy бота)
    local port80_container=""
    local stopped_container=""
    port80_container="$(detect_host_port80_container || true)"

    if [[ -n "$port80_container" ]]; then
        warn "Хостовый порт 80/tcp занят Docker-контейнером '${port80_container}'."
        local pause_ans="N"
        if [[ -t 0 ]]; then
            read -rp "Временно приостановить контейнер '${port80_container}' на 10 сек для выпуска SSL? [y/N]: " pause_ans || true
        else
            if [[ "$port80_container" == "just1kbot_caddy" ]]; then
                log "Скрипт запущен в неинтерактивном режиме: автоматическая временная приостановка 'just1kbot_caddy' на время ACME-челленджа."
                pause_ans="Y"
            else
                warn "Скрипт запущен в неинтерактивном режиме: обнаружен сторонний контейнер '${port80_container}' на порту 80. Автоматическая остановка пропущена во избежание сбоя сервисов."
                pause_ans="N"
            fi
        fi
        if [[ "$pause_ans" =~ ^[Yy] ]]; then
            log "Временная приостановка контейнера '${port80_container}'..."
            if docker stop "$port80_container" >/dev/null 2>&1; then
                stopped_container="$port80_container"
                # Транзакционный trap для гарантированного запуска контейнера при сбое/прерывании
                trap 'if [[ -n "'"$stopped_container"'" ]]; then docker start "'"$stopped_container"'" >/dev/null 2>&1 || true; fi' EXIT INT TERM
            else
                warn "Не удалось остановить контейнер '${port80_container}'. Standalone выпуск может завершиться ошибкой."
            fi
        else
            warn "Остановка контейнера пропущена. Standalone выпуск может завершиться ошибкой."
        fi
    fi

    local was_nginx_active=0
    if systemctl is-active --quiet nginx 2>/dev/null; then
        was_nginx_active=1
        systemctl stop nginx 2>/dev/null || true
    fi

    local cert_rc=0
    certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email \
        --pre-hook "$pre_hook_cmd" \
        --post-hook "$post_hook_cmd" \
        -d "$domain" || cert_rc=$?

    if [[ $was_nginx_active -eq 1 ]]; then
        systemctl start nginx 2>/dev/null || true
    fi

    # Гарантированное возобновление работы контейнера сразу после попытки Certbot
    if [[ -n "$stopped_container" ]]; then
        log "Возобновление работы контейнера '${stopped_container}'..."
        if ! docker start "$stopped_container" >/dev/null 2>&1; then
            error "КРИТИЧЕСКИЙ СБОЙ: Не удалось запустить Docker-контейнер '${stopped_container}'. Запустите его вручную: docker start ${stopped_container}"
        fi
        trap - EXIT INT TERM
    fi

    if [[ -f /run/just1knode_ufw_opened_80 ]]; then
        rm -f /run/just1knode_ufw_opened_80
        # Не удаляем правило 80/tcp, если на сервере работает веб-контейнер (например, Caddy бота)
        if [[ -z "$(detect_host_port80_container 2>/dev/null || true)" ]] && ! (command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "just1kbot_caddy"); then
            ufw delete allow 80/tcp >/dev/null 2>&1 || true
            ufw delete allow 80 >/dev/null 2>&1 || true
        fi
    fi

    if [[ $cert_rc -ne 0 || ! -f "${le_dir}/live/${domain}/fullchain.pem" ]]; then
        error "Сбой выпуска SSL-сертификата Let's Encrypt для $domain. Убедитесь, что порт 80 свободен и DNS указывает на этот сервер."
        return 1
    fi

    if [[ -n "$target_prefix" ]]; then
        install -m 640 "${le_dir}/live/${domain}/fullchain.pem" "${xray_tls_dir}/${target_prefix}_fullchain.pem" 2>/dev/null || cp -f "${le_dir}/live/${domain}/fullchain.pem" "${xray_tls_dir}/${target_prefix}_fullchain.pem"
        install -m 640 "${le_dir}/live/${domain}/privkey.pem" "${xray_tls_dir}/${target_prefix}_privkey.pem" 2>/dev/null || cp -f "${le_dir}/live/${domain}/privkey.pem" "${xray_tls_dir}/${target_prefix}_privkey.pem"
        chown root:nogroup "${xray_tls_dir}/${target_prefix}_fullchain.pem" "${xray_tls_dir}/${target_prefix}_privkey.pem" 2>/dev/null || true
    fi

    if [[ "$target_prefix" != "vless" ]]; then
        install -m 640 "${le_dir}/live/${domain}/fullchain.pem" "${xray_tls_dir}/fullchain.pem" 2>/dev/null || cp -f "${le_dir}/live/${domain}/fullchain.pem" "${xray_tls_dir}/fullchain.pem"
        install -m 640 "${le_dir}/live/${domain}/privkey.pem" "${xray_tls_dir}/privkey.pem" 2>/dev/null || cp -f "${le_dir}/live/${domain}/privkey.pem" "${xray_tls_dir}/privkey.pem"
        chown root:nogroup "${xray_tls_dir}/fullchain.pem" "${xray_tls_dir}/privkey.pem" 2>/dev/null || true
    elif [[ ! -f "${xray_tls_dir}/fullchain.pem" ]]; then
        install -m 640 "${le_dir}/live/${domain}/fullchain.pem" "${xray_tls_dir}/fullchain.pem" 2>/dev/null || cp -f "${le_dir}/live/${domain}/fullchain.pem" "${xray_tls_dir}/fullchain.pem"
        install -m 640 "${le_dir}/live/${domain}/privkey.pem" "${xray_tls_dir}/privkey.pem" 2>/dev/null || cp -f "${le_dir}/live/${domain}/privkey.pem" "${xray_tls_dir}/privkey.pem"
        chown root:nogroup "${xray_tls_dir}/fullchain.pem" "${xray_tls_dir}/privkey.pem" 2>/dev/null || true
    fi

    log "SSL-сертификат Let's Encrypt успешно получен и привязан к Xray (автообновление настроено)."
    return 0
}

deploy_vless_fallback_nginx() {
    if ! command -v nginx >/dev/null 2>&1; then
        return 0
    fi
    local fb_conf="/etc/nginx/sites-available/just1k-fallback80.conf"
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /var/www/html
    if [[ ! -f /var/www/html/index.html ]] || grep -qi "welcome to nginx" /var/www/html/index.html 2>/dev/null; then
        cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Network Operations & System Status</title>
    <style>
        :root {
            --bg-color: #0f172a;
            --card-bg: #1e293b;
            --border-color: #334155;
            --text-main: #f8fafc;
            --text-muted: #94a3b8;
            --accent: #38bdf8;
            --success: #34d399;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background-color: var(--bg-color);
            color: var(--text-main);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 24px 16px;
        }
        .container {
            width: 100%;
            max-width: 680px;
            background-color: var(--card-bg);
            border: 1px solid var(--border-color);
            border-radius: 16px;
            padding: 36px 32px;
            box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.4);
        }
        .header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            margin-bottom: 24px;
            padding-bottom: 20px;
            border-bottom: 1px solid var(--border-color);
        }
        .title-block h1 {
            font-size: 20px;
            font-weight: 600;
            color: var(--text-main);
            letter-spacing: -0.01em;
        }
        .title-block p {
            font-size: 13px;
            color: var(--text-muted);
            margin-top: 4px;
        }
        .status-badge {
            display: inline-flex;
            align-items: center;
            gap: 8px;
            background: rgba(52, 211, 153, 0.1);
            border: 1px solid rgba(52, 211, 153, 0.25);
            color: var(--success);
            padding: 6px 14px;
            border-radius: 999px;
            font-size: 12px;
            font-weight: 600;
            letter-spacing: 0.02em;
        }
        .status-dot {
            width: 8px;
            height: 8px;
            background-color: var(--success);
            border-radius: 50%;
            box-shadow: 0 0 8px var(--success);
        }
        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
            gap: 16px;
            margin-bottom: 28px;
        }
        .card {
            background-color: rgba(15, 23, 42, 0.6);
            border: 1px solid var(--border-color);
            border-radius: 12px;
            padding: 16px;
        }
        .card-label {
            font-size: 11px;
            text-transform: uppercase;
            letter-spacing: 0.06em;
            color: var(--text-muted);
            margin-bottom: 8px;
        }
        .card-value {
            font-size: 16px;
            font-weight: 600;
            color: var(--accent);
        }
        .info-section {
            font-size: 13px;
            color: var(--text-muted);
            line-height: 1.6;
        }
        .footer {
            margin-top: 28px;
            padding-top: 16px;
            border-top: 1px solid var(--border-color);
            display: flex;
            align-items: center;
            justify-content: space-between;
            font-size: 12px;
            color: var(--text-muted);
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="title-block">
                <h1>Edge Gateway Infrastructure</h1>
                <p>Distributed Cluster Node & Service Telemetry</p>
            </div>
            <div class="status-badge">
                <span class="status-dot"></span>
                <span>Operational</span>
            </div>
        </div>
        <div class="grid">
            <div class="card">
                <div class="card-label">Network Edge</div>
                <div class="card-value">Active Core</div>
            </div>
            <div class="card">
                <div class="card-label">HTTP Engine</div>
                <div class="card-value">Reverse Proxy</div>
            </div>
            <div class="card">
                <div class="card-label">Service Health</div>
                <div class="card-value">Optimal</div>
            </div>
        </div>
        <div class="info-section">
            This node serves dedicated application traffic, automated load balancing, and network edge termination. Direct unmapped endpoint requests are logged in accordance with system telemetry policies.
        </div>
        <div class="footer">
            <span>Platform Telemetry Engine</span>
            <span>All Systems Normal</span>
        </div>
    </div>
</body>
</html>
EOF
    fi
    cat > "$fb_conf" <<'EOF'
server {
    listen 127.0.0.1:80 default_server;
    server_name _;
    server_tokens off;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    root /var/www/html;
    index index.html index.nginx-debian.html;
    location / {
        try_files $uri $uri/ =404;
    }
}
EOF
    local def_site="/etc/nginx/sites-enabled/default"
    if [[ -f "$def_site" || -L "$def_site" ]]; then
        if ! cp -L "$def_site" "/etc/nginx/sites-available/default.user.bak" 2>/dev/null; then
            warn "Nginx: не удалось создать резервную копию default сайта перед отключением."
            return 1
        fi
        rm -f "$def_site" 2>/dev/null || true
    fi
    ln -sf "$fb_conf" /etc/nginx/sites-enabled/just1k-fallback80.conf 2>/dev/null || true
    if ! nginx -t >/dev/null 2>&1; then
        warn "Nginx: ошибка синтаксиса при подключении just1k-fallback80.conf. Откат fallback хоста..."
        rm -f /etc/nginx/sites-enabled/just1k-fallback80.conf /etc/nginx/sites-available/just1k-fallback80.conf 2>/dev/null || true
        if [[ -f "/etc/nginx/sites-available/default.user.bak" && ! -e "$def_site" ]]; then
            cp -a "/etc/nginx/sites-available/default.user.bak" "/etc/nginx/sites-available/default" 2>/dev/null || true
            ln -sf "/etc/nginx/sites-available/default" "$def_site" 2>/dev/null || true
            rm -f "/etc/nginx/sites-available/default.user.bak" 2>/dev/null || true
        fi
        return 1
    fi
    if ! systemctl reload nginx 2>/dev/null && ! systemctl restart nginx 2>/dev/null; then
        warn "Nginx: не удалось применить конфигурацию службы для just1k-fallback80.conf."
        rm -f /etc/nginx/sites-enabled/just1k-fallback80.conf /etc/nginx/sites-available/just1k-fallback80.conf 2>/dev/null || true
        if [[ -f "/etc/nginx/sites-available/default.user.bak" && ! -e "$def_site" ]]; then
            cp -a "/etc/nginx/sites-available/default.user.bak" "/etc/nginx/sites-available/default" 2>/dev/null || true
            ln -sf "/etc/nginx/sites-available/default" "$def_site" 2>/dev/null || true
            rm -f "/etc/nginx/sites-available/default.user.bak" 2>/dev/null || true
        fi
        return 1
    fi
    return 0
}

setup_xray_api_proxy() {
    local target_domain="${1:-}"
    local x_api_key
    x_api_key="$(get_state_val "xray_api_key" "")"
    if [[ -z "$x_api_key" ]]; then
        x_api_key="$(get_state_val "awg_api_key" "")"
    fi
    if [[ -z "$x_api_key" ]]; then
        x_api_key="$(openssl rand -hex 16 2>/dev/null || date +%s%N)"
    fi
    set_state_val "xray_api_key" "$x_api_key"
    if ! deploy_xray_api_service "$x_api_key" ""; then
        warn "Служба xray-api не смогла быть развернута."
        return 1
    fi
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now xray-api 2>/dev/null || true
    if ! ensure_xray_api_healthy 1; then
        warn "Служба xray-api не смогла запуститься или не прошла проверку работоспособности."
        return 1
    fi

    # Интеграция обратного прокси xray-api (/v1/) в существующий Nginx Amnezia
    local amnezia_nginx="/etc/nginx/sites-available/just1k-amnezia.conf"
    local amnezia_enabled="/etc/nginx/sites-enabled/just1k-amnezia.conf"
    if [[ -f "$amnezia_nginx" || -f "$amnezia_enabled" ]]; then
        if [[ ! -f "$amnezia_nginx" && -f "$amnezia_enabled" ]]; then
            cp -a "$amnezia_enabled" "$amnezia_nginx" 2>/dev/null || true
        fi
        local amnezia_bak="${amnezia_nginx}.user.bak"
        local needs_v1_injection=0
        if python3 -c "
import re, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        content = f.read()
    parts = re.split(r'(\bserver\s*\{)', content)
    missing = any(i % 2 == 0 and i > 0 and 'location / {' in p and 'location /v1/' not in p for i, p in enumerate(parts))
    sys.exit(0 if missing else 1)
except Exception:
    sys.exit(1)
" "$amnezia_nginx" 2>/dev/null; then
            needs_v1_injection=1
        fi

        if [[ $needs_v1_injection -eq 1 ]]; then
            cp -p "$amnezia_nginx" "$amnezia_bak" 2>/dev/null || true
            mkdir -p /etc/nginx/conf.d
            if [[ ! -f "/etc/nginx/conf.d/amnezia-ratelimit.conf" ]]; then
                cat > "/etc/nginx/conf.d/amnezia-ratelimit.conf" <<'EOF'
# JUST1KNODE: AmneziaWG API Rate Limiting Zone
limit_req_zone $binary_remote_addr zone=just1k_amnezia_api:10m rate=30r/s;
EOF
            fi
            python3 -c "
import re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()
v1_block = '''    location /v1/ {
        limit_req zone=just1k_amnezia_api burst=50 nodelay;
        limit_req_status 429;

        proxy_pass http://127.0.0.1:5001;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 10s;
        proxy_read_timeout 30s;
        proxy_send_timeout 30s;
    }

'''

parts = re.split(r'(\bserver\s*\{)', content)
new_parts = []
for i, part in enumerate(parts):
    if i % 2 == 0 and i > 0:
        if 'location / {' in part and 'location /v1/' not in part:
            part = part.replace('location / {', v1_block + '    location / {', 1)
    new_parts.append(part)

new_content = ''.join(new_parts)
with open(path, 'w', encoding='utf-8') as f:
    f.write(new_content)
" "$amnezia_nginx" 2>/dev/null || true

            if python3 -c "
import re, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        content = f.read()
    parts = re.split(r'(\bserver\s*\{)', content)
    missing = any(i % 2 == 0 and i > 0 and 'location / {' in p and 'location /v1/' not in p for i, p in enumerate(parts))
    sys.exit(0 if missing else 1)
except Exception:
    sys.exit(0)
" "$amnezia_nginx" 2>/dev/null; then
                warn "Nginx: не удалось внедрить маршрут /v1/ во все блоки server в $amnezia_nginx"
                if [[ -f "$amnezia_bak" ]]; then
                    cp -f "$amnezia_bak" "$amnezia_nginx" 2>/dev/null || true
                    rm -f "$amnezia_bak" 2>/dev/null || true
                fi
                return 1
            fi
        fi

        ln -sf "$amnezia_nginx" "$amnezia_enabled" 2>/dev/null || true
        if ! nginx -t >/dev/null 2>&1; then
            warn "Nginx: синтаксическая ошибка конфигурации при настройке обратного прокси xray-api (/v1/)."
            if [[ -f "$amnezia_bak" ]]; then
                cp -f "$amnezia_bak" "$amnezia_nginx" 2>/dev/null || true
                rm -f "$amnezia_bak" 2>/dev/null || true
            fi
            return 1
        fi

        if ! systemctl reload nginx 2>/dev/null && ! systemctl restart nginx 2>/dev/null; then
            warn "Nginx: не удалось применить конфигурацию для Amnezia Nginx."
            if [[ -f "$amnezia_bak" ]]; then
                cp -f "$amnezia_bak" "$amnezia_nginx" 2>/dev/null || true
                rm -f "$amnezia_bak" 2>/dev/null || true
            fi
            return 1
        fi
        rm -f "$amnezia_bak" 2>/dev/null || true
        log "Nginx: подключен обратный прокси для xray-api (/v1/ ➔ 127.0.0.1:5001) в Amnezia Nginx."
    fi

    # 2. Автономный виртуальный хост VLESS API на порту 8444
    local v_dom
    v_dom="${target_domain:-$(get_state_val "vless_domain" "$(get_state_val "sni" "")")}"
    local le_dir="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
    local cert_file="${le_dir}/live/${v_dom}/fullchain.pem"
    local key_file="${le_dir}/live/${v_dom}/privkey.pem"
    if [[ ! -f "$cert_file" ]]; then
        cert_file="${XRAY_TLS_DIR:-/usr/local/etc/xray/tls}/vless_fullchain.pem"
        key_file="${XRAY_TLS_DIR:-/usr/local/etc/xray/tls}/vless_privkey.pem"
    fi
    if [[ ! -f "$cert_file" ]]; then
        cert_file="${XRAY_TLS_DIR:-/usr/local/etc/xray/tls}/fullchain.pem"
        key_file="${XRAY_TLS_DIR:-/usr/local/etc/xray/tls}/privkey.pem"
    fi
    if [[ ! -f "$cert_file" && -f "$amnezia_nginx" ]]; then
        local amnezia_cert amnezia_key
        amnezia_cert="$(grep -E "ssl_certificate\s+" "$amnezia_nginx" | head -n1 | awk '{print $2}' | tr -d ';')"
        amnezia_key="$(grep -E "ssl_certificate_key\s+" "$amnezia_nginx" | head -n1 | awk '{print $2}' | tr -d ';')"
        if [[ -f "$amnezia_cert" && -f "$amnezia_key" ]]; then
            cert_file="$amnezia_cert"
            key_file="$amnezia_key"
        fi
    fi

    local vless_api_nginx="/etc/nginx/sites-available/just1k-vless-api.conf"
    if [[ -f "$cert_file" && -f "$key_file" && -n "$v_dom" ]]; then
        mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
        cat > "$vless_api_nginx" <<EOF
server {
    listen 8444 ssl http2;
    listen [::]:8444 ssl http2;
    server_name ${v_dom};
    server_tokens off;

    ssl_certificate ${cert_file};
    ssl_certificate_key ${key_file};

    location / {
        proxy_pass http://127.0.0.1:5001;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 10s;
        proxy_read_timeout 30s;
        proxy_send_timeout 30s;
    }
}
EOF
        ln -sf "$vless_api_nginx" /etc/nginx/sites-enabled/just1k-vless-api.conf 2>/dev/null || true
        if ! nginx -t >/dev/null 2>&1; then
            warn "Nginx: синтаксическая ошибка конфигурации при настройке VLESS API ($vless_api_nginx)."
            rm -f /etc/nginx/sites-enabled/just1k-vless-api.conf /etc/nginx/sites-available/just1k-vless-api.conf 2>/dev/null || true
            return 1
        fi
        if ! systemctl reload nginx 2>/dev/null && ! systemctl restart nginx 2>/dev/null; then
            warn "Nginx: не удалось применить конфигурацию для VLESS API ($vless_api_nginx)."
            rm -f /etc/nginx/sites-enabled/just1k-vless-api.conf /etc/nginx/sites-available/just1k-vless-api.conf 2>/dev/null || true
            return 1
        fi
        log "Nginx: развернут автономный виртуальный хост VLESS API на порту 8444 (➔ 127.0.0.1:5001)."
    else
        warn "Nginx: не найдены SSL сертификаты или домен для автономного VLESS API ($v_dom)."
        return 1
    fi

    local cur_awg_port
    cur_awg_port="$(get_state_val "awg_port" "8443")"
    [[ -z "$cur_awg_port" || "$cur_awg_port" == "-" ]] && cur_awg_port="8443"

    local bot_ip
    bot_ip="$(get_state_val "bot_ip" "")"
    if ! is_ssh_port "8444" && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        ufw delete allow 8444/tcp >/dev/null 2>&1 || true
        ufw delete allow 8444 >/dev/null 2>&1 || true
        if [[ -n "$bot_ip" && "$bot_ip" != "any" && "$bot_ip" != "0.0.0.0/0" ]] && validate_ipv4 "$bot_ip"; then
            ufw allow from "$bot_ip" to any port 8444 proto tcp comment "just1knode xray-api bot_ip" >/dev/null 2>&1 || true
        else
            warn "BOT_IP не задан в state.json. Порт VLESS API (8444) закрыт от внешнего мира (Fail-Closed)."
        fi
    fi
}

setup_dual_xray_api() {
    setup_xray_api_proxy "$@"
}

install_xray_relay_node() {
    title "УСТАНОВКА RELAY УЗЛА (Белый Интернет — Выход VLESS)"
    check_root
    init_state_dir

    local prev_role
    prev_role="$(get_node_status)"
    if [[ "$prev_role" == "origin" ]]; then
        error "Узел уже настроен как Origin. Установка Relay на Origin запрещена (контуры строго изолированы)."
        return 1
    fi

    install_base_deps
    apply_node_sysctl_hardening

    local relay_port="${1:-}"
    local origin_ip="${2:-}"
    local dest_server="${3:-}"
    local sec_mode="${4:-}"

    # Интерактивный опросник, если аргументы не переданы
    if [[ -z "$relay_port" ]]; then
        read -rp "Порт туннеля Relay [по умолчанию: 10443]: " relay_port_in || true
        relay_port="${relay_port_in:-10443}"
    fi
    if ! [[ "$relay_port" =~ ^[0-9]+$ ]] || (( relay_port < 1 || relay_port > 65535 )); then
        error "Порт туннеля Relay должен быть целым числом в диапазоне 1..65535 (задано: '${relay_port}')."
        return 1
    fi
    if [[ "$relay_port" == "443" ]]; then
        error "Порт 443 зарезервирован для клиентского входа VLESS Direct. Порт туннеля Relay должен отличаться (например: 10443)."
        return 1
    fi
    if is_ssh_port "$relay_port"; then
        error "Порт ${relay_port} занят службой SSH. Запрещено использовать порт SSH для Relay туннеля."
        return 1
    fi

    if [[ -z "$origin_ip" ]]; then
        read -rp "Введите IP-адрес Origin-сервера в РФ (для защиты UFW): " origin_ip || true
    fi
    if [[ -z "$origin_ip" ]] || ! validate_ipv4 "$origin_ip"; then
        error "IP-адрес Origin ('${origin_ip}') некорректен или пуст. Требуется валидный IPv4-адрес для настройки фаервола."
        return 1
    fi

    local my_ip
    my_ip="$(get_public_ipv4 || true)"

    local sec_mode="tls"

    if [[ -z "$dest_server" ]]; then
        local auto_domain=""
        local le_dir="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
        if [[ -n "$my_ip" ]]; then
            auto_domain="$(detect_relay_domain_candidates "$my_ip" | head -n 1 || true)"
        fi
        if [[ -z "$auto_domain" && -d "${le_dir}/live" ]]; then
            auto_domain="$(python3 -c "
import os, glob, sys
le_dir = sys.argv[1]
cands = []
for d in glob.glob(os.path.join(le_dir, 'live', '*')):
    if not os.path.isdir(d): continue
    dom = os.path.basename(d)
    if dom in ('README', '*'): continue
    fc = os.path.join(d, 'fullchain.pem')
    pk = os.path.join(d, 'privkey.pem')
    if os.path.isfile(fc) and os.path.isfile(pk):
        try:
            cands.append((os.path.getmtime(fc), dom))
        except Exception:
            pass
cands.sort(key=lambda x: x[0], reverse=True)
if cands:
    print(cands[0][1])
" "$le_dir" 2>/dev/null || true)"
        fi

        echo -e "\n${BOLD}=== НАСТРОЙКА ДОМЕНА ДЛЯ СВЯЗИ ORIGIN ➔ RELAY (VLESS TLS) ===${NC}"
        echo -e "Для исключения блокировок ТСПУ по сверке SNI ➔ DNS (nDPI NDPI_UNRESOLVED_HOSTNAME)"
        echo -e "релей настраивается на вашем собственном домене с чистым сертификатом Let's Encrypt."
        if [[ -n "$auto_domain" ]]; then
            echo -e "${GREEN}✔ Обнаружен готовый сертификат Let's Encrypt для домена:${NC} ${BOLD}${auto_domain}${NC}"
            read -rp "Использовать этот домен [Enter = ${auto_domain}]: " dest_in || true
            dest_server="${dest_in:-$auto_domain}"
        else
            echo -e "Создайте DNS A-запись у вашего регистратора: ${CYAN}your-relay.yourdomain.com ➔ ${my_ip}${NC}\n"
            read -rp "Введите домен Relay (например: your-relay.yourdomain.com): " dest_in || true
            dest_server="${dest_in:-}"
        fi
    fi
    if [[ -z "$dest_server" ]]; then
        error "Домен Relay обязателен для режима VLESS TLS. Использование сторонних SNI запрещено."
        return 1
    fi

    # Валидация DNS A-записи домена (строго только для TLS)
    if ! validate_relay_dns "$dest_server" "$my_ip"; then
        return 1
    fi

    # Выпуск SSL сертификата (Zero-Signature: порт 80 открывается только на время ACME-челленджа)
    if ! issue_relay_tls_cert "$dest_server"; then
        return 1
    fi

    # Проверка на наличие AmneziaWG (Zero-Collateral-Damage принцип)
    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Ports}}' 2>/dev/null | grep -q "51820"; then
        info "Обнаружен работающий AmneziaWG (Docker: 51820/udp)."
        log "Zero-Collateral: порт 51820/udp и Amnezia-контейнеры НЕ затрагиваются!"
    fi

    # Проверка доступности порта туннеля Relay
    if ss -tlnp 2>/dev/null | grep -q ":${relay_port} " || netstat -tlnp 2>/dev/null | grep -q ":${relay_port} "; then
        local conflict_proc
        conflict_proc=$(ss -tlnp 2>/dev/null | grep ":${relay_port} " || true)
        if ! echo "$conflict_proc" | grep -q "xray"; then
            error "Порт Relay ${relay_port}/tcp уже занят другим процессом на хосте:\n$conflict_proc\nВыберите свободный порт для Relay (например: 10443)."
            return 1
        fi
    fi

    install_xray_binaries
    create_backup "$XRAY_CONFIG"

    local tunnel_uuid
    tunnel_uuid="$($XRAY_BIN uuid)"

    local stream_settings_json="{
    \"network\": \"tcp\",
    \"security\": \"tls\",
    \"tlsSettings\": {
      \"alpn\": [\"h2\", \"http/1.1\"],
      \"certificates\": [
        {
          \"certificateFile\": \"/usr/local/etc/xray/tls/fullchain.pem\",
          \"keyFile\": \"/usr/local/etc/xray/tls/privkey.pem\"
        }
      ]
    }
  }"

    local existing_vless_clients_json="[]"
    if [[ -f "$XRAY_CONFIG" ]]; then
        existing_vless_clients_json="$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    for ib in cfg.get('inbounds', []):
        if ib.get('tag') == 'just1k-vless-direct':
            clients = ib.get('settings', {}).get('clients', [])
            print(json.dumps(clients))
            sys.exit(0)
except Exception:
    pass
print('[]')
" "$XRAY_CONFIG" 2>/dev/null || echo "[]")"
    fi

    local vless_stream_settings_json="$stream_settings_json"
    if [[ -f "/usr/local/etc/xray/tls/vless_fullchain.pem" ]]; then
        vless_stream_settings_json="{
    \"network\": \"tcp\",
    \"security\": \"tls\",
    \"tlsSettings\": {
      \"minVersion\": \"1.2\",
      \"alpn\": [\"http/1.1\"],
      \"certificates\": [
        {
          \"certificateFile\": \"/usr/local/etc/xray/tls/vless_fullchain.pem\",
          \"keyFile\": \"/usr/local/etc/xray/tls/vless_privkey.pem\"
        }
      ]
    }
  }"
    fi

    local direct_inbound_json=""
    local cur_has_vless
    cur_has_vless="$(get_state_val "has_vless" "0")"
    if [[ "$cur_has_vless" == "1" && "$sec_mode" == "tls" ]]; then
        direct_inbound_json=",
    {
      \"tag\": \"just1k-vless-direct\",
      \"port\": 443,
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": ${existing_vless_clients_json},
        \"decryption\": \"none\",
        \"fallbacks\": [
          {
            \"dest\": 80
          }
        ]
      },
      \"streamSettings\": ${vless_stream_settings_json},
      \"sniffing\": {
        \"enabled\": true,
        \"destOverride\": [\"tls\", \"http\", \"quic\"],
        \"metadataOnly\": false
      }
    }"
    fi

    log "Формирование конфигурации Relay ноды (VLESS ${sec_mode^^})..."
    local tmp_xray_config="${XRAY_CONFIG}.tmp.json"
    cat > "$tmp_xray_config" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "api": {
    "tag": "api",
    "services": [
      "HandlerService",
      "LoggerService",
      "StatsService"
    ]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true
    }
  },
  "inbounds": [
    {
      "tag": "inbound-${sec_mode}",
      "port": ${relay_port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${tunnel_uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": ${stream_settings_json},
      "sniffing": {
        "enabled": true,
        "destOverride": ["tls", "http", "quic"],
        "metadataOnly": false
      }
    }${direct_inbound_json},
    {
      "tag": "just1k-wl-api-grpc",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "just1k-wl-api-grpc"
        ],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "port": "25",
        "outboundTag": "block"
      }
    ]
  },
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    },
    {
      "tag": "api",
      "protocol": "blackhole"
    }
  ],
  "dns": {
    "servers": [
      "1.1.1.1",
      "1.0.0.1",
      "8.8.8.8",
      "localhost"
    ],
    "queryStrategy": "UseIPv4"
  }
}
EOF

    ensure_xray_config_permissions "$tmp_xray_config"

    apply_node_sysctl_hardening

    if ! "$XRAY_BIN" run -test -format json -config "$tmp_xray_config"; then
        rm -f "$tmp_xray_config"
        error "Ошибка тестирования сгенерированной конфигурации Xray на Relay узле. Изменения не применены."
        return 1
    fi

    mv -f "$tmp_xray_config" "$XRAY_CONFIG"
    ensure_xray_config_permissions "$XRAY_CONFIG"

    if [[ "$cur_has_vless" == "1" && "$sec_mode" == "tls" ]]; then
        if ! deploy_vless_fallback_nginx; then
            warn "Nginx: не удалось настроить fallback для VLESS при переконфигурации Relay."
        fi
    fi

    # Защита портов через UFW (строго без открытия Amnezia API всему миру)
    local extra_ufw_ports=()
    if [[ "$cur_has_vless" == "1" && "$sec_mode" == "tls" ]]; then
        extra_ufw_ports+=("443/tcp")
    fi
    configure_safe_ufw "${extra_ufw_ports[@]}"
    heal_node_firewall_and_stealth
    if ufw allow from "$origin_ip" to any port "$relay_port" proto tcp >/dev/null 2>&1; then
        log "Порт туннеля ${relay_port}/tcp открыт строго для ${origin_ip}."
    else
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
            error "КРИТИЧЕСКАЯ ОШИБКА: Не удалось открыть порт туннеля ${relay_port}/tcp для ${origin_ip} в активном фаерволе UFW!"
            return 1
        else
            warn "Предупреждение: Не удалось добавить правило UFW для порта туннеля ${relay_port}/tcp от ${origin_ip}."
        fi
    fi
    if [[ "$cur_has_vless" == "1" && "$sec_mode" == "tls" ]]; then
        if ufw allow 443/tcp comment "just1knode vless direct" >/dev/null 2>&1; then
            log "Фаервол UFW: разрешен публичный доступ к VLESS Direct (443/tcp)."
        fi
    fi

    deploy_xray_systemd_service
    systemctl restart xray

    set_state_val "has_relay" "1"
    set_state_val "relay_port" "$relay_port"
    set_state_val "origin_ip" "$origin_ip"
    set_state_val "tunnel_uuid" "$tunnel_uuid"
    set_state_val "security" "tls"
    set_state_val "sni" "$dest_server"

    set_state_val "has_relay" "1"
    set_state_val "role" "node"
    if [[ "$prev_role" == "awg" || "$cur_has_vless" == "1" ]]; then
        log "Компоненты узла актуализированы (Relay активен)."
        apply_amnezia_abuse_protection
        if [[ "$cur_has_vless" == "1" ]]; then
            setup_xray_api_proxy "$dest_server"
        fi
    fi

    local geo_resolved
    geo_resolved="$(resolve_relay_geo_interactive "$my_ip" "exit")"
    local detected_code="${geo_resolved%%|*}"
    local detected_country="${geo_resolved#*|}"
    case "$detected_code" in
        ee) detected_country="🇪🇪 Эстония" ;;
    esac

    title "УСТАНОВКА RELAY УЗЛА УСПЕШНО ЗАВЕРШЕНА!"
    echo -e "${BOLD}Команда для добавления этого Relay на вашем Origin-сервере:${NC}"
    echo -e "${GREEN}just1knode relay add \"${detected_country}\" ${my_ip} ${relay_port} \"${tunnel_uuid}\" \"${detected_code}\" \"tls\" \"-\" \"-\" \"${dest_server}\"${NC}\n"
    echo -e "${YELLOW}Примечание: вы можете заменить название \"${detected_country}\" на любое удобное вам.${NC}\n"
}

# =============================================================================
# Определение и интерактивный выбор доменов Let's Encrypt для Relay
# =============================================================================
detect_relay_domain_candidates() {
    local my_ip="${1:-}"
    local le_dir="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
    [[ -d "${le_dir}/live" ]] || return 0
    [[ -n "$my_ip" ]] || return 0

    python3 -c "
import os, glob, socket, subprocess, sys
le_dir = sys.argv[1]
my_ip = sys.argv[2]

candidates = []
for d in glob.glob(os.path.join(le_dir, 'live', '*')):
    if not os.path.isdir(d): continue
    domain = os.path.basename(d)
    if domain in ('README', '*'): continue
    fc = os.path.join(d, 'fullchain.pem')
    pk = os.path.join(d, 'privkey.pem')
    if not (os.path.isfile(fc) and os.path.isfile(pk)): continue
    try:
        rc = subprocess.run(['openssl', 'x509', '-checkend', '86400', '-noout', '-in', fc],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
        if rc != 0:
            continue
    except Exception:
        continue
    try:
        mtime = os.path.getmtime(fc)
    except Exception:
        mtime = 0
    try:
        ai = socket.getaddrinfo(domain, None, socket.AF_INET)
        ips = {x[4][0] for x in ai if x[4]}
        if my_ip not in ips:
            continue
    except Exception:
        continue
    candidates.append((mtime, domain))

candidates.sort(key=lambda x: x[0], reverse=True)
for _, c in candidates:
    print(c)
" "$le_dir" "$my_ip" 2>/dev/null || true
}

select_relay_domain_interactive() {
    local my_ip="${1:-}"
    local cur_sni="${2:-}"

    local candidates=()
    while IFS= read -r c; do
        [[ -n "$c" ]] && candidates+=("$c")
    done < <(detect_relay_domain_candidates "$my_ip")

    local has_cur_sni=0
    local cur_sni_idx=-1
    if [[ -n "$cur_sni" ]]; then
        for idx in "${!candidates[@]}"; do
            if [[ "${candidates[$idx]}" == "$cur_sni" ]]; then
                has_cur_sni=1
                cur_sni_idx=$idx
                break
            fi
        done
    fi

    # СЦЕНАРИЙ 1: Неинтерактивный режим (скрипты / unattended cron / JUST1KNODE_NON_INTERACTIVE)
    if [[ ! -t 0 || "${JUST1KNODE_NON_INTERACTIVE:-0}" == "1" || "${DEBIAN_FRONTEND:-}" == "noninteractive" ]]; then
        if [[ $has_cur_sni -eq 1 ]]; then
            # Если текущий SNI валиден — сохраняем его без изменений
            echo "$cur_sni"
            return 0
        elif [[ ${#candidates[@]} -gt 0 ]]; then
            # Текущий SNI невалиден/отсутствует — берем наиболее актуальный валидный
            log "✔ Неинтерактивный режим: текущий домен не валиден, выбран кандидат '${candidates[0]}'." >&2
            echo "${candidates[0]}"
            return 0
        else
            echo ""
            return 0
        fi
    fi

    # СЦЕНАРИЙ 2: Интерактивный режим (оператор в терминале)

    # 2.1 Кандидатов нет вообще
    if [[ ${#candidates[@]} -eq 0 ]]; then
        echo ""
        return 0
    fi

    # 2.2 Ровно 1 кандидат
    if [[ ${#candidates[@]} -eq 1 ]]; then
        if [[ -z "$cur_sni" || "$cur_sni" == "${candidates[0]}" ]]; then
            echo "${candidates[0]}"
            return 0
        fi
        # Нестыковка: текущий SNI отличается от единственного валидного кандидата
        if [[ ! -t 0 || "${JUST1KNODE_NON_INTERACTIVE:-0}" == "1" || "${DEBIAN_FRONTEND:-}" == "noninteractive" ]]; then
            echo "${candidates[0]}"
            return 0
        fi
        warn "ВНИМАНИЕ: Текущий домен '$cur_sni' отличается от найденного валидного сертификата '${candidates[0]}'." >&2
        local ans=""
        read -rp "Использовать '${candidates[0]}' для Relay? [Y/n]: " ans
        if [[ -z "$ans" || "$ans" =~ ^[YyДд] ]]; then
            echo "${candidates[0]}"
            return 0
        fi
        # Оператор отказался переключаться — запрашиваем ручной ввод
        while true; do
            local manual_domain=""
            read -rp "Введите домен вручную (или Enter для сохранения '$cur_sni'): " manual_domain
            manual_domain="$(echo "$manual_domain" | tr -d '[:space:]')"
            if [[ -z "$manual_domain" ]]; then
                echo "$cur_sni"
                return 0
            fi
            if validate_relay_dns "$manual_domain" "$my_ip"; then
                echo "$manual_domain"
                return 0
            else
                warn "Введённый домен '$manual_domain' не резолвится на IP '$my_ip'. Попробуйте снова." >&2
            fi
        done
    fi

    # 2.3 Несколько кандидатов (> 1)
    # Если текущий SNI уже является самым свежим — коллизий нет
    if [[ $has_cur_sni -eq 1 && "$cur_sni" == "${candidates[0]}" ]]; then
        echo "$cur_sni"
        return 0
    fi

    # Обнаружена нестыковка: несколько доменов, и текущий отличается от самого свежего
    warn "ВНИМАНИЕ: На сервере обнаружено несколько SSL-сертификатов, привязанных к IP ($my_ip):" >&2
    for idx in "${!candidates[@]}"; do
        local num=$((idx + 1))
        local cand="${candidates[$idx]}"
        local tag=""
        [[ $idx -eq 0 ]] && tag=" (самый свежий)"
        [[ "$cand" == "$cur_sni" ]] && tag="${tag} [текущий в конфигурации]"
        echo -e "  [${num}] ${CYAN}${cand}${NC}${tag}" >&2
    done
    echo -e "  [0] Ввести другой домен вручную" >&2

    local default_idx=1
    local default_domain="${candidates[0]}"
    if [[ $has_cur_sni -eq 1 ]]; then
        default_idx=$((cur_sni_idx + 1))
        default_domain="$cur_sni"
    fi

    if [[ ! -t 0 || "${JUST1KNODE_NON_INTERACTIVE:-0}" == "1" || "${DEBIAN_FRONTEND:-}" == "noninteractive" ]]; then
        echo "$default_domain"
        return 0
    fi

    local chosen_domain=""
    while true; do
        local choice=""
        read -rp "Какой домен использовать для Relay? [Enter = ${default_idx} (${default_domain})]: " choice
        if [[ -z "$choice" ]]; then
            chosen_domain="$default_domain"
            break
        elif [[ "$choice" == "$default_idx" ]]; then
            chosen_domain="$default_domain"
            break
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#candidates[@]} )); then
            chosen_domain="${candidates[$((choice - 1))]}"
            break
        elif [[ "$choice" == "0" ]]; then
            local manual_domain=""
            read -rp "Введите домен вручную: " manual_domain
            manual_domain="$(echo "$manual_domain" | tr -d '[:space:]')"
            if [[ -n "$manual_domain" ]]; then
                if validate_relay_dns "$manual_domain" "$my_ip"; then
                    chosen_domain="$manual_domain"
                    break
                else
                    warn "Введённый домен '$manual_domain' не резолвится на IP '$my_ip'. Попробуйте снова." >&2
                fi
            fi
        else
            warn "Неверный выбор '$choice'. Введите число от 0 до ${#candidates[@]}." >&2
        fi
    done
    echo "$chosen_domain"
}

setup_relay_domain() {
    title "НАСТРОЙКА ЛИЧНОГО ДОМЕНА ДЛЯ RELAY-УЗЛА (VLESS TLS)"
    check_root
    init_state_dir
    acquire_just1knode_lock

    local role cur_has_r
    role="$(get_state_val "role")"
    cur_has_r="$(get_state_val "has_relay" "0")"
    if [[ "$role" != "relay" && ( "$role" != "node" || "$cur_has_r" != "1" ) ]]; then
        error "Команда 'setup-domain' предназначена для Relay узлов (текущая роль: ${role:-не настроен})."
        return 1
    fi

    local relay_port
    relay_port="$(get_state_val "relay_port")"
    [[ -z "$relay_port" ]] && relay_port="10443"

    local tunnel_uuid
    tunnel_uuid="$(get_state_val "tunnel_uuid")"

    # Если UUID не сохранен в state, считываем из config.json
    if [[ -z "$tunnel_uuid" && -f "$XRAY_CONFIG" ]]; then
        tunnel_uuid=$(python3 -c "
import json, sys
try:
    with open('$XRAY_CONFIG') as f:
        c = json.load(f)
    relay_p = int('$relay_port') if '$relay_port'.isdigit() else 10443
    for ib in c.get('inbounds', []):
        if ib.get('tag') in ('inbound-reality', 'inbound-tls', 'from-origin') or ib.get('port') in (10443, relay_p):
            clients = ib.get('settings', {}).get('clients', [])
            if clients and clients[0].get('id'):
                print(clients[0]['id'])
                sys.exit(0)
except Exception: pass
print('')
" 2>/dev/null || true)
    fi

    if [[ -z "$tunnel_uuid" ]]; then
        tunnel_uuid="$($XRAY_BIN uuid 2>/dev/null || true)"
        [[ -z "$tunnel_uuid" ]] && tunnel_uuid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
        set_state_val "tunnel_uuid" "$tunnel_uuid"
    fi

    local my_ip
    my_ip="$(get_public_ipv4 || true)"

    local cur_sni
    cur_sni="$(get_state_val "sni" "")"

    local domain="${1:-}"
    if [[ -z "$domain" ]]; then
        local auto_domain
        auto_domain="$(select_relay_domain_interactive "$my_ip" "$cur_sni")"
        if [[ -n "$auto_domain" ]]; then
            domain="$auto_domain"
        else
            echo -e "\n${BOLD}=== НАСТРОЙКА ДОМЕНА RELAY ДЛЯ ЗАЩИТЫ ОТ ТСПУ ===${NC}"
            echo -e "Для устранения сигнатуры nDPI NDPI_UNRESOLVED_HOSTNAME (сверка SNI ➔ DNS)"
            echo -e "релей настраивается на вашем персональном домене с чистым сертификатом Let's Encrypt."
            echo -e "Создайте DNS A-запись (DNS-Only / без Cloudflare Proxy):"
            echo -e "  ${CYAN}your-relay.yourdomain.com ➔ ${my_ip}${NC}\n"
            read -rp "Введите персональный домен для этого Relay (например: your-relay.yourdomain.com): " domain_in
            domain="${domain_in:-}"
        fi
    fi

    if [[ -z "$domain" ]]; then
        error "Домен Relay обязателен."
        return 1
    fi

    if ! validate_relay_dns "$domain" "$my_ip"; then
        return 1
    fi

    if ! issue_relay_tls_cert "$domain"; then
        return 1
    fi

    create_backup "$XRAY_CONFIG"
    manifest_begin

    log "Обновление конфигурации Xray на VLESS + TLS..."
    if ! python3 -c "
import json, sys, os, tempfile

cfg_file = sys.argv[1]
port = int(sys.argv[2])
uuid = sys.argv[3]
domain = sys.argv[4]

with open(cfg_file, 'r', encoding='utf-8') as f:
    cfg = json.load(f)

# Ищем входящий inbound туннеля (по порту или тегу)
ib = None
for i in cfg.get('inbounds', []):
    if i.get('port') == port or i.get('tag') in ('inbound-reality', 'inbound-tls', 'from-origin'):
        ib = i
        break

if not ib:
    ib = {
        'tag': 'inbound-tls',
        'port': port,
        'protocol': 'vless',
        'settings': {
            'clients': [{'id': uuid, 'flow': 'xtls-rprx-vision'}],
            'decryption': 'none'
        }
    }
    cfg.setdefault('inbounds', []).append(ib)

# Сохраняем существующих клиентов (UUID/flow), если они уже есть в inbound
existing_clients = ib.get('settings', {}).get('clients', [])
if not existing_clients:
    existing_clients = [{'id': uuid, 'flow': 'xtls-rprx-vision'}]

ib['tag'] = 'inbound-tls'
ib['port'] = port
ib['protocol'] = 'vless'
ib['settings'] = {
    'clients': existing_clients,
    'decryption': 'none'
}
ib['streamSettings'] = {
    'network': 'tcp',
    'security': 'tls',
    'tlsSettings': {
        'alpn': ['h2', 'http/1.1'],
        'certificates': [
            {
                'certificateFile': '/usr/local/etc/xray/tls/fullchain.pem',
                'keyFile': '/usr/local/etc/xray/tls/privkey.pem'
            }
        ]
    }
}
ib.setdefault('sniffing', {
    'enabled': True,
    'destOverride': ['tls', 'http', 'quic'],
    'metadataOnly': False
})

d = os.path.dirname(os.path.abspath(cfg_file))
t_fd, t_path = tempfile.mkstemp(dir=d, suffix='.tmp')
with os.fdopen(t_fd, 'w', encoding='utf-8') as fp:
    json.dump(cfg, fp, indent=2)
    fp.flush()
    os.fsync(fp.fileno())
os.replace(t_path, cfg_file)
try:
    os.chmod(cfg_file, 0o640)
except Exception:
    pass
" "$XRAY_CONFIG" "$relay_port" "$tunnel_uuid" "$domain"; then
        manifest_rollback
        error "Ошибка обновления конфигурации Xray Relay."
        return 1
    fi

    if ! "$XRAY_BIN" run -test -config "$XRAY_CONFIG"; then
        manifest_rollback
        error "Ошибка тестирования сгенерированной конфигурации Xray! Изменения отменены."
        return 1
    fi

    set +e
    systemctl restart xray
    local xray_rc=$?
    set -e
    if [[ $xray_rc -ne 0 ]] || ! systemctl is-active --quiet xray; then
        manifest_rollback
        error "Xray не смог запуститься с новым сертификатом. Выполнен полный откат."
        return 1
    fi

    set_state_val "security" "tls"
    set_state_val "sni" "$domain"

    manifest_commit

    local geo_resolved
    geo_resolved="$(resolve_relay_geo_interactive "$my_ip" "relay-01")"
    local detected_code="${geo_resolved%%|*}"
    local detected_country="${geo_resolved#*|}"
    case "$detected_code" in
        ee) detected_country="🇪🇪 Эстония" ;;
    esac

    title "НАСТРОЙКА ДОМЕНА RELAY УСПЕШНО ЗАВЕРШЕНА!"
    echo -e "${BOLD}1. Команда для переключения этого релея на вашем Origin-сервере:${NC}"
    echo -e "${GREEN}just1knode relay sni ${detected_code} ${domain} tls${NC}\n"
    echo -e "${BOLD}2. Если вы настраиваете этот релей на Origin впервые, используйте команду:${NC}"
    echo -e "${CYAN}just1knode relay add \"${detected_country}\" ${my_ip} ${relay_port} \"${tunnel_uuid}\" \"${detected_code}\" \"tls\" \"-\" \"-\" \"${domain}\"${NC}\n"
}

heal_and_update_relay_config() {
    title "АВТОМАТИЧЕСКАЯ ОПТИМИЗАЦИЯ И ОБНОВЛЕНИЕ КОНФИГУРАЦИИ RELAY"
    check_root
    init_state_dir
    acquire_just1knode_lock

    local role cur_has_r cur_has_v
    role="$(get_state_val "role")"
    cur_has_r="$(get_state_val "has_relay" "0")"
    cur_has_v="$(get_state_val "has_vless" "0")"
    if [[ "$role" != "relay" && "$role" != "vless" && ( "$role" != "node" || ( "$cur_has_r" != "1" && "$cur_has_v" != "1" ) ) ]]; then
        error "Функция доступна только на узле с компонентами Relay или VLESS (текущая роль: ${role:-не установлена})."
    fi

    log "Проверка и исправление параметров ядра Xray Relay..."
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        error "Файл конфигурации Xray не найден: $XRAY_CONFIG"
    fi

    create_backup "$XRAY_CONFIG"
    manifest_begin

    # 1. Автоматический перевод Relay на VLESS+TLS, если на хосте уже есть сертификат Let's Encrypt
    local my_ip
    my_ip="$(get_public_ipv4 || true)"
    local cur_sni
    cur_sni="$(get_state_val "sni" "")"
    local le_dir="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
    local xray_tls_dir="${XRAY_TLS_DIR:-/usr/local/etc/xray/tls}"
    local le_domain=""

    le_domain="$(select_relay_domain_interactive "$my_ip" "$cur_sni")"

    # Если le_domain пустой (кандидатов нет), но cur_sni задан и его DNS указывает на my_ip:
    if [[ -z "$le_domain" && -n "$cur_sni" && "$cur_sni" != *"google.com"* ]]; then
        if validate_relay_dns "$cur_sni" "$my_ip" 2>/dev/null; then
            log "✔ Текущий домен '$cur_sni' подтверждён через DNS (требуется выпуск/продление сертификата)..."
            le_domain="$cur_sni"
        fi
    fi

    local cert_issued=0
    if [[ -n "$le_domain" ]]; then
        local cur_sec
        cur_sec="$(get_state_val "security" "")"
        if [[ "$cur_sec" != "tls" || "$cur_sni" != "$le_domain" || ! -f "${xray_tls_dir}/fullchain.pem" ]] || ! openssl x509 -checkend 86400 -noout -in "${xray_tls_dir}/fullchain.pem" 2>/dev/null; then
            log "✔ Обнаружен действующий сертификат Let's Encrypt для '$le_domain'."
            log "Автоматический перевод входящего туннеля Relay на VLESS + TLS (Zero-Manual-Commands)..."
            if issue_relay_tls_cert "$le_domain"; then
                cert_issued=1
            fi
        else
            cert_issued=1
        fi
    fi

    local current_sec
    if [[ $cert_issued -eq 1 ]]; then
        current_sec="tls"
    else
        current_sec="$(get_state_val "security" "")"
    fi

    local cur_has_vless cur_has_relay cur_relay_port cur_tunnel_uuid
    cur_has_vless="$(get_state_val "has_vless" "0")"
    cur_has_relay="$(get_state_val "has_relay" "0")"
    cur_relay_port="$(get_state_val "relay_port" "10443")"
    cur_tunnel_uuid="$(get_state_val "tunnel_uuid" "")"

    if ! python3 -c "
import json, os, sys, tempfile
cfg_file = sys.argv[1]
sec_mode = sys.argv[2] if len(sys.argv) > 2 else ''
with open(cfg_file, 'r', encoding='utf-8') as f:
    cfg = json.load(f)

# Если узел переведен на TLS и сертификаты присутствуют, гарантируем, что входящий инбаунд настроен на VLESS+TLS
tls_cert_dir = os.environ.get('XRAY_TLS_DIR', '/usr/local/etc/xray/tls')
tls_cert_file = os.path.join(tls_cert_dir, 'fullchain.pem')
tls_key_file = os.path.join(tls_cert_dir, 'privkey.pem')
if sec_mode == 'tls' and os.path.exists(tls_cert_file) and os.path.exists(tls_key_file):
    has_relay_flag = sys.argv[4] if len(sys.argv) > 4 else '0'
    relay_port = int(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5].isdigit() else 10443
    tunnel_uuid = sys.argv[6] if len(sys.argv) > 6 else ''

    inbounds = cfg.setdefault('inbounds', [])
    relay_ib = next((ib for ib in inbounds if ib.get('tag') in ('inbound-reality', 'inbound-tls', 'from-origin') or ib.get('port') in (10443, relay_port)), None)

    if has_relay_flag == '1' and not relay_ib and tunnel_uuid:
        relay_ib = {
            'tag': 'inbound-tls',
            'port': relay_port,
            'protocol': 'vless',
            'settings': {
                'clients': [{'id': tunnel_uuid, 'flow': 'xtls-rprx-vision'}],
                'decryption': 'none'
            },
            'streamSettings': {
                'network': 'tcp',
                'security': 'tls',
                'tlsSettings': {
                    'alpn': ['h2', 'http/1.1'],
                    'certificates': [{'certificateFile': tls_cert_file, 'keyFile': tls_key_file}]
                }
            }
        }
        inbounds.insert(0, relay_ib)
    elif relay_ib:
        relay_ib['tag'] = 'inbound-tls'
        clients = relay_ib.setdefault('settings', {}).setdefault('clients', [])
        if not isinstance(clients, list):
            clients = []
            relay_ib['settings']['clients'] = clients
        if not clients and tunnel_uuid:
            clients.append({'id': tunnel_uuid, 'flow': 'xtls-rprx-vision'})
        else:
            for c in clients:
                if isinstance(c, dict):
                    c['flow'] = 'xtls-rprx-vision'
        st = relay_ib.setdefault('streamSettings', {})
        st['network'] = 'tcp'
        st['security'] = 'tls'
        st.pop('realitySettings', None)
        st['tlsSettings'] = {
            'alpn': ['h2', 'http/1.1'],
            'certificates': [
                {
                    'certificateFile': tls_cert_file,
                    'keyFile': tls_key_file
                }
            ]
        }

    has_vless_flag = sys.argv[3] if len(sys.argv) > 3 else '0'
    direct_ib = next((ib for ib in inbounds if ib.get('tag') == 'just1k-vless-direct'), None)
    if has_vless_flag == '1':
        vless_cert_cand = os.path.join(tls_cert_dir, 'vless_fullchain.pem')
        vless_key_cand = os.path.join(tls_cert_dir, 'vless_privkey.pem')
        target_vless_cert = vless_cert_cand if (os.path.exists(vless_cert_cand) and os.path.exists(vless_key_cand)) else tls_cert_file
        target_vless_key = vless_key_cand if (os.path.exists(vless_cert_cand) and os.path.exists(vless_key_cand)) else tls_key_file

        if not direct_ib:
            direct_ib = {
                'tag': 'just1k-vless-direct',
                'port': 443,
                'protocol': 'vless',
                'settings': {
                    'clients': [],
                    'decryption': 'none',
                    'fallbacks': [{'dest': 80}]
                },
                'streamSettings': {
                    'network': 'tcp',
                    'security': 'tls',
                    'tlsSettings': {
                        'minVersion': '1.2',
                        'alpn': ['http/1.1'],
                        'certificates': [
                            {
                                'certificateFile': target_vless_cert,
                                'keyFile': target_vless_key
                            }
                        ]
                    }
                },
                'sniffing': {
                    'enabled': True,
                    'destOverride': ['tls', 'http', 'quic'],
                    'metadataOnly': False
                }
            }
            inbounds.append(direct_ib)
        else:
            settings = direct_ib.setdefault('settings', {})
            settings.setdefault('clients', [])
            settings['decryption'] = 'none'
            settings['fallbacks'] = [{'dest': 80}]
            if 'fallbacks' in direct_ib:
                del direct_ib['fallbacks']
            st = direct_ib.setdefault('streamSettings', {})
            st['network'] = 'tcp'
            st['security'] = 'tls'
            st['tlsSettings'] = {
                'minVersion': '1.2',
                'alpn': ['http/1.1'],
                'certificates': [
                    {
                        'certificateFile': target_vless_cert,
                        'keyFile': target_vless_key
                    }
                ]
            }
    else:
        if direct_ib:
            inbounds.remove(direct_ib)

    grpc_ib = next((ib for ib in inbounds if ib.get('tag') == 'just1k-wl-api-grpc'), None)
    if not grpc_ib:
        inbounds.insert(0, {
            'tag': 'just1k-wl-api-grpc',
            'listen': '127.0.0.1',
            'port': 10085,
            'protocol': 'dokodemo-door',
            'settings': {'address': '127.0.0.1'}
        })

    cfg['api'] = {
        'tag': 'api',
        'services': ['HandlerService', 'LoggerService', 'StatsService']
    }
    cfg.setdefault('stats', {})
    policy_conf = cfg.setdefault('policy', {})
    policy_levels = policy_conf.setdefault('levels', {})
    level_0 = policy_levels.setdefault('0', {})
    level_0['statsUserUplink'] = True
    level_0['statsUserDownlink'] = True

    if not any(ob.get('tag') == 'api' for ob in cfg.get('outbounds', [])):
        cfg.setdefault('outbounds', []).append({
            'tag': 'api',
            'protocol': 'blackhole'
        })

    rules = cfg.setdefault('routing', {}).setdefault('rules', [])
    if not any(r.get('outboundTag') == 'api' for r in rules):
        rules.insert(0, {
            'type': 'field',
            'inboundTag': ['just1k-wl-api-grpc'],
            'outboundTag': 'api'
        })

for ob in cfg.get('outbounds', []):
    if ob.get('tag') == 'direct' or ob.get('protocol') == 'freedom':
        ob.setdefault('settings', {})['domainStrategy'] = 'UseIPv4'

has_block = any(ob.get('tag') == 'block' for ob in cfg.get('outbounds', []))
if not has_block:
    cfg.setdefault('outbounds', []).append({
        'tag': 'block',
        'protocol': 'blackhole'
    })

routing = cfg.setdefault('routing', {})
routing.setdefault('domainStrategy', 'IPIfNonMatch')
rules = routing.setdefault('rules', [])
insert_pos = 1 if (rules and rules[0].get('outboundTag') in ('api', 'just1k-wl-api')) else 0
has_geoip_private = any(r.get('type') == 'field' and 'geoip:private' in r.get('ip', []) and r.get('outboundTag') == 'block' for r in rules)
if not has_geoip_private:
    rules.insert(insert_pos, {
        'type': 'field',
        'ip': ['geoip:private'],
        'outboundTag': 'block'
    })
has_bt_proto = any(r.get('type') == 'field' and 'bittorrent' in r.get('protocol', []) for r in rules)
if not has_bt_proto:
    rules.insert(insert_pos, {
        'type': 'field',
        'protocol': ['bittorrent'],
        'outboundTag': 'block'
    })
has_smtp_port = any(r.get('type') == 'field' and (r.get('port') == '25' or r.get('port') == 25) for r in rules)
if not has_smtp_port:
    rules.insert(insert_pos, {
        'type': 'field',
        'port': '25',
        'outboundTag': 'block'
    })

for ib in cfg.get('inbounds', []):
    tag = str(ib.get('tag', '')).strip().lower()
    if tag in ('api-in', 'just1k-wl-api-grpc'):
        ib.pop('sniffing', None)
        continue
    sniff = ib.setdefault('sniffing', {})
    sniff['enabled'] = True
    sniff.setdefault('destOverride', ['tls', 'http', 'quic'])
    sniff.setdefault('metadataOnly', False)

cfg['dns'] = {
    'servers': ['1.1.1.1', '1.0.0.1', '8.8.8.8', 'localhost'],
    'queryStrategy': 'UseIPv4'
}

d = os.path.dirname(os.path.abspath(cfg_file))
t_fd, t_path = tempfile.mkstemp(dir=d, suffix='.tmp.json')
with os.fdopen(t_fd, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2)
    f.flush()
    os.fsync(f.fileno())
os.replace(t_path, cfg_file)
try:
    os.chmod(cfg_file, 0o640)
except Exception:
    pass

print('[+] Xray Relay config successfully optimized (UseIPv4 + Independent DNS + VLESS TLS)')
" "$XRAY_CONFIG" "$current_sec" "$cur_has_vless" "$cur_has_relay" "$cur_relay_port" "$cur_tunnel_uuid"; then
        manifest_rollback
        error "Ошибка выполнения Python-скрипта реконсиляции Relay."
    fi

    chmod 640 "$XRAY_CONFIG" 2>/dev/null || true

    apply_node_sysctl_hardening

    if ! "$XRAY_BIN" run -test -format json -config "$XRAY_CONFIG"; then
        manifest_rollback
        error "Ошибка валидации Xray Relay после оптимизации! Выполнен полный откат."
    fi

    set +e
    systemctl restart xray
    local xray_rc=$?
    set -e
    if [[ $xray_rc -ne 0 ]] || ! systemctl is-active --quiet xray; then
        warn "Служба Xray Relay не запустилась. Выполняется полный откат..."
        manifest_rollback
        error "Откат выполнен: служба Xray Relay не смогла запуститься с новой конфигурацией."
    fi

    manifest_commit

    # Синхронизируем state.json строго ПОСЛЕ успешного теста и запуска Xray:
    if [[ $cert_issued -eq 1 && "$current_sec" == "tls" ]]; then
        set_state_val "security" "tls"
        set_state_val "sni" "$le_domain"
        set_state_val "public_key" "-"
        set_state_val "short_id" "-"
    fi

    heal_node_firewall_and_stealth

    if [[ "$cur_has_vless" == "1" ]]; then
        deploy_vless_fallback_nginx
        ufw allow 443/tcp comment "just1knode vless direct" >/dev/null 2>&1 || true
        setup_xray_api_proxy
    fi

    log "Оптимизация и обновление конфигурации Relay завершены успешно!"
}

# =============================================================================
# МОДУЛЬНАЯ УСТАНОВКА И УПРАВЛЕНИЕ VLESS TLS (ДЛЯ ОБЫЧНОЙ SUB-ССЫЛКИ)
# =============================================================================

install_vless_direct_node() {
    title "НАСТРОЙКА VLESS TLS УЗЛА (ДЛЯ SUB-ССЫЛКИ)"
    check_root
    init_state_dir

    local prev_role
    prev_role="$(get_node_status)"
    if [[ "$prev_role" == "origin" ]]; then
        error "Узел уже настроен как Origin. Установка VLESS на Origin запрещена (Origin строго изолирован под Белый Интернет)."
        return 1
    fi

    install_base_deps
    install_nginx_if_missing
    apply_node_sysctl_hardening

    local dest_server="${1:-}"
    local bot_ip="${2:-${BOT_IP:-}}"
    local my_ip
    my_ip="$(get_public_ipv4 || true)"

    if [[ -z "$dest_server" ]]; then
        local auto_domain=""
        local le_dir="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
        if [[ -n "$my_ip" ]]; then
            auto_domain="$(detect_relay_domain_candidates "$my_ip" | head -n 1 || true)"
        fi
        if [[ -z "$auto_domain" && -d "${le_dir}/live" ]]; then
            auto_domain="$(python3 -c "
import os, glob, sys
le_dir = sys.argv[1]
cands = []
for d in glob.glob(os.path.join(le_dir, 'live', '*')):
    if not os.path.isdir(d): continue
    dom = os.path.basename(d)
    if dom in ('README', '*'): continue
    fc = os.path.join(d, 'fullchain.pem')
    pk = os.path.join(d, 'privkey.pem')
    if os.path.isfile(fc) and os.path.isfile(pk):
        try:
            cands.append((os.path.getmtime(fc), dom))
        except Exception:
            pass
cands.sort(key=lambda x: x[0], reverse=True)
if cands:
    print(cands[0][1])
" "$le_dir" 2>/dev/null || true)"
        fi

        echo -e "\n${BOLD}=== НАСТРОЙКА ДОМЕНА ДЛЯ VLESS TLS (ПОРТ 443) ===${NC}"
        echo -e "Для клиентских подключений VLESS TLS требуется персональный домен."
        if [[ -n "$auto_domain" ]]; then
            echo -e "${GREEN}✔ Обнаружен готовый сертификат Let's Encrypt для домена:${NC} ${BOLD}${auto_domain}${NC}"
            read -rp "Использовать этот домен [Enter = ${auto_domain}]: " dest_in || true
            dest_server="${dest_in:-$auto_domain}"
        else
            echo -e "Создайте DNS A-запись у вашего регистратора: ${CYAN}your-vless.yourdomain.com ➔ ${my_ip}${NC}\n"
            read -rp "Введите домен VLESS (например: your-vless.yourdomain.com): " dest_in || true
            dest_server="${dest_in:-}"
        fi
    fi

    if [[ -z "$dest_server" ]]; then
        error "Домен обязателен для настройки VLESS TLS."
        return 1
    fi

    if [[ -z "$bot_ip" ]]; then
        local saved_bip
        saved_bip="$(get_state_val "bot_ip" "")"
        if [[ -n "$saved_bip" && "$saved_bip" != "-" && "$saved_bip" != "any" ]]; then
            bot_ip="$saved_bip"
        fi
    fi
    if [[ -z "$bot_ip" && -t 0 ]]; then
        echo -e "\n${BOLD}=== НАСТРОЙКА IP БОТА ДЛЯ ЗАЩИТЫ API (ПОРТ 8444) ===${NC}"
        read -rp "Введите IP-адрес Telegram-бота (для ограничения доступа к API): " input_bip || true
        bot_ip="$(echo "$input_bip" | tr -d '[:space:]')"
    fi
    if [[ -n "$bot_ip" && "$bot_ip" != "any" && "$bot_ip" != "0.0.0.0/0" ]] && validate_ipv4 "$bot_ip"; then
        set_state_val "bot_ip" "$bot_ip"
        local amnezia_check_p
        amnezia_check_p="$(get_state_val "awg_port" "8443")"
        [[ -z "$amnezia_check_p" || "$amnezia_check_p" == "-" ]] && amnezia_check_p="8443"
        if [[ -f "/etc/nginx/sites-available/just1k-amnezia.conf" || -f "/etc/nginx/sites-enabled/just1k-amnezia.conf" ]]; then
            log "Фаервол UFW: API 8444 будет разрешен строго для BOT_IP: ${bot_ip} (AmneziaWG API на порту ${amnezia_check_p})"
        else
            log "Фаервол UFW: API 8444 будет разрешен строго для BOT_IP: ${bot_ip}"
        fi
    else
        warn "BOT_IP не указан или невалиден. API будет закрыт от внешнего мира в UFW (Fail-Closed)."
    fi

    if ! validate_relay_dns "$dest_server" "$my_ip"; then
        return 1
    fi

    if ! issue_relay_tls_cert "$dest_server" "vless"; then
        return 1
    fi

    install_xray_binaries
    local orig_xray_exists=0
    local orig_bkp_cfg=""
    if [[ -f "$XRAY_CONFIG" ]]; then
        orig_xray_exists=1
        create_backup "$XRAY_CONFIG"
        orig_bkp_cfg="${LAST_BACKUP_PATH:-}"
    fi
    local orig_has_vless
    orig_has_vless="$(get_state_val "has_vless" "0")"
    local orig_vless_domain
    orig_vless_domain="$(get_state_val "vless_domain" "")"
    local orig_role
    orig_role="$(get_state_val "role" "")"
    local orig_had_fallback80=0
    if [[ -f "/etc/nginx/sites-available/just1k-fallback80.conf" || -L "/etc/nginx/sites-enabled/just1k-fallback80.conf" ]]; then
        orig_had_fallback80=1
    fi
    local orig_had_vless_api=0
    if [[ -f "/etc/nginx/sites-available/just1k-vless-api.conf" || -L "/etc/nginx/sites-enabled/just1k-vless-api.conf" ]]; then
        orig_had_vless_api=1
    fi

    local tls_cert_dir="${XRAY_TLS_DIR:-/usr/local/etc/xray/tls}"
    local tls_cert_file="${tls_cert_dir}/vless_fullchain.pem"
    local tls_key_file="${tls_cert_dir}/vless_privkey.pem"
    if [[ ! -f "$tls_cert_file" ]]; then
        tls_cert_file="${tls_cert_dir}/fullchain.pem"
        tls_key_file="${tls_cert_dir}/privkey.pem"
    fi

    local tmp_cfg="${XRAY_CONFIG}.tmp.json"
    if ! python3 -c "
import json, os, sys
cfg_file, cert_f, key_f, out_f = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
cfg = {}
if os.path.exists(cfg_file) and os.path.getsize(cfg_file) > 0:
    try:
        with open(cfg_file, 'r', encoding='utf-8') as f:
            cfg = json.load(f)
    except Exception as e:
        print(f'ERROR: Ошибка чтения существующего {cfg_file}: {e}', file=sys.stderr)
        sys.exit(1)

if not cfg:
    cfg = {
        'log': {'loglevel': 'warning'},
        'api': {'tag': 'api', 'services': ['HandlerService', 'LoggerService', 'StatsService']},
        'stats': {},
        'policy': {
            'levels': {'0': {'statsUserUplink': True, 'statsUserDownlink': True}},
            'system': {'statsInboundUplink': True, 'statsInboundDownlink': True}
        },
        'inbounds': [],
        'outbounds': [
            {'tag': 'direct', 'protocol': 'freedom', 'settings': {'domainStrategy': 'UseIPv4'}},
            {'tag': 'block', 'protocol': 'blackhole'},
            {'tag': 'api', 'protocol': 'blackhole'}
        ],
        'routing': {
            'domainStrategy': 'IPIfNonMatch',
            'rules': [
                {'type': 'field', 'inboundTag': ['just1k-wl-api-grpc'], 'outboundTag': 'api'},
                {'type': 'field', 'ip': ['geoip:private'], 'outboundTag': 'block'},
                {'type': 'field', 'protocol': ['bittorrent'], 'outboundTag': 'block'},
                {'type': 'field', 'port': '25', 'outboundTag': 'block'}
            ]
        },
        'dns': {'servers': ['1.1.1.1', '1.0.0.1', '8.8.8.8', 'localhost'], 'queryStrategy': 'UseIPv4'}
    }

inbounds = cfg.setdefault('inbounds', [])
if not any(ib.get('tag') == 'just1k-wl-api-grpc' for ib in inbounds):
    inbounds.insert(0, {
        'tag': 'just1k-wl-api-grpc',
        'listen': '127.0.0.1',
        'port': 10085,
        'protocol': 'dokodemo-door',
        'settings': {'address': '127.0.0.1'}
    })

stream_settings = {
    'network': 'tcp',
    'security': 'tls',
    'tlsSettings': {
        'minVersion': '1.2',
        'alpn': ['http/1.1'],
        'certificates': [{'certificateFile': cert_f, 'keyFile': key_f}]
    }
}

direct_ib = next((ib for ib in inbounds if ib.get('tag') == 'just1k-vless-direct'), None)
if not direct_ib:
    inbounds.append({
        'tag': 'just1k-vless-direct',
        'port': 443,
        'protocol': 'vless',
        'settings': {
            'clients': [],
            'decryption': 'none',
            'fallbacks': [{'dest': 80}]
        },
        'streamSettings': stream_settings,
        'sniffing': {'enabled': True, 'destOverride': ['tls', 'http', 'quic'], 'metadataOnly': False}
    })
else:
    direct_ib['streamSettings'] = stream_settings
    st = direct_ib.setdefault('settings', {})
    st.setdefault('fallbacks', [{'dest': 80}])
    direct_ib.pop('fallbacks', None)

with open(out_f, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
" "$XRAY_CONFIG" "$tls_cert_file" "$tls_key_file" "$tmp_cfg"; then
        rm -f "$tmp_cfg" 2>/dev/null || true
        error "Ошибка генерации конфигурации Xray для VLESS. Исходный файл не изменен."
        return 1
    fi

    ensure_xray_config_permissions "$tmp_cfg"

    local rollback_vless_installation
    rollback_vless_installation() {
        warn "Выполняется откат конфигурации и служб VLESS к исходному состоянию..."
        if [[ "$orig_xray_exists" -eq 1 && -n "$orig_bkp_cfg" && -f "$orig_bkp_cfg" ]]; then
            cp -f "$orig_bkp_cfg" "$XRAY_CONFIG"
            ensure_xray_config_permissions "$XRAY_CONFIG"
            if ! systemctl restart xray 2>/dev/null; then
                warn "Критическая ошибка: не удалось перезапустить Xray при откате к предыдущей конфигурации!"
            fi
        elif [[ "$orig_xray_exists" -eq 0 ]]; then
            systemctl stop xray 2>/dev/null || true
            rm -f "$XRAY_CONFIG" 2>/dev/null || true
        fi

        # Откат правила UFW для 443 (если 443 не использовался ранее для VLESS или Relay)
        if [[ "$orig_has_vless" != "1" && "$(get_state_val "relay_port" "")" != "443" ]]; then
            ufw delete allow 443/tcp >/dev/null 2>&1 || true
        fi

        # Откат fallback хоста Nginx (только если его не было до текущей установки)
        if [[ "$orig_had_fallback80" -eq 0 ]]; then
            rm -f /etc/nginx/sites-enabled/just1k-fallback80.conf /etc/nginx/sites-available/just1k-fallback80.conf 2>/dev/null || true
            if [[ -f "/etc/nginx/sites-available/default.user.bak" && ! -e "/etc/nginx/sites-enabled/default" ]]; then
                cp -a "/etc/nginx/sites-available/default.user.bak" "/etc/nginx/sites-available/default" 2>/dev/null || true
                ln -sf "/etc/nginx/sites-available/default" "/etc/nginx/sites-enabled/default" 2>/dev/null || true
                rm -f "/etc/nginx/sites-available/default.user.bak" 2>/dev/null || true
                if nginx -t >/dev/null 2>&1; then
                    systemctl reload nginx 2>/dev/null || true
                fi
            fi
        fi

        # Откат автономного виртуального хоста VLESS API Nginx (только если его не было до текущей установки)
        if [[ "$orig_had_vless_api" -eq 0 ]]; then
            rm -f /etc/nginx/sites-enabled/just1k-vless-api.conf /etc/nginx/sites-available/just1k-vless-api.conf 2>/dev/null || true
        fi

        # Остановка xray-api, если на сервере ранее не было VLESS и не настроен Relay
        if [[ "$orig_has_vless" != "1" && "$(get_state_val "has_relay" "0")" != "1" ]]; then
            systemctl stop xray-api 2>/dev/null || true
            systemctl disable xray-api 2>/dev/null || true
        fi

        # Восстановление состояния state.json
        set_state_val "has_vless" "$orig_has_vless"
        set_state_val "vless_domain" "$orig_vless_domain"
        if [[ -n "$orig_role" ]]; then
            set_state_val "role" "$orig_role"
        fi
    }

    if ! "$XRAY_BIN" run -test -format json -config "$tmp_cfg"; then
        rm -f "$tmp_cfg" 2>/dev/null || true
        error "Ошибка валидации сгенерированной конфигурации Xray для VLESS. Исходная конфигурация не изменена."
        return 1
    fi

    mv -f "$tmp_cfg" "$XRAY_CONFIG"
    ensure_xray_config_permissions "$XRAY_CONFIG"

    ufw allow 443/tcp comment "just1knode vless direct" >/dev/null 2>&1 || true

    deploy_xray_systemd_service
    if ! systemctl restart xray; then
        warn "Служба Xray не смогла перезапуститься с новой конфигурацией VLESS."
        rollback_vless_installation
        error "Ошибка запуска Xray с конфигурацией VLESS. Выполнен откат к исходному состоянию."
        return 1
    fi

    if ! deploy_vless_fallback_nginx; then
        warn "Сбой настройки маскировочного Nginx Fallback."
        rollback_vless_installation
        error "Ошибка настройки Nginx Fallback. Выполнен откат к исходному состоянию."
        return 1
    fi

    if ! setup_xray_api_proxy "$dest_server"; then
        warn "Ошибка настройки прокси/службы xray-api."
        rollback_vless_installation
        error "Ошибка настройки xray-api. Выполнен откат к исходному состоянию."
        return 1
    fi

    # Фиксация состояния только при гарантированном успехе (Commit-on-Success)
    if ! set_state_val "has_vless" "1" || ! set_state_val "vless_domain" "$dest_server" || ! set_state_val "role" "node"; then
        warn "Ошибка сохранения состояния VLESS в state.json."
        rollback_vless_installation
        error "Ошибка фиксации состояния VLESS. Выполнен откат к исходному состоянию."
        return 1
    fi

    log "✔ VLESS TLS узел успешно настроен и запущен на порту 443!"
    echo ""
    show_vless_bot_credentials
}

show_vless_bot_credentials() {
    title "ДАННЫЕ VLESS TLS ДЛЯ TELEGRAM-БОТА (/admin)"
    check_root
    init_state_dir

    local v_dom x_key
    v_dom="$(get_state_val "vless_domain" "$(get_state_val "sni" "")")"
    x_key="$(get_state_val "xray_api_key" "$(get_state_val "awg_api_key" "")")"

    local api_endpoint
    if [[ -n "$v_dom" ]]; then
        api_endpoint="https://${v_dom}:8444"
    else
        local my_ip
        my_ip="$(get_public_ipv4 || true)"
        api_endpoint="https://${my_ip}:8444"
    fi

    echo -e "  Домен VLESS:     ${BOLD}${CYAN}${v_dom:-не настроен}${NC}"
    echo -e "  Клиентский порт: ${BOLD}${GREEN}443 (TLS XTLS-Vision)${NC}"
    echo -e "  API URL (бот):   ${BOLD}${CYAN}${api_endpoint}${NC}"
    echo -e "  API Key / Токен: ${BOLD}${YELLOW}${x_key:-не сгенерирован}${NC}"
    echo ""
    echo -e "Для добавления в бот перейдите в: ${BOLD}/admin ➔ Серверы ➔ Добавить сервер${NC}"
}

setup_vless_domain() {
    title "НАСТРОЙКА / СМЕНА ДОМЕНА VLESS TLS"
    check_root
    init_state_dir

    local new_domain="${1:-}"
    local my_ip
    my_ip="$(get_public_ipv4 || true)"

    if [[ -z "$new_domain" ]]; then
        local auto_domain=""
        if [[ -n "$my_ip" ]]; then
            auto_domain="$(detect_relay_domain_candidates "$my_ip" | head -n 1 || true)"
        fi
        echo -e "\n${BOLD}=== ВЫБОР ДОМЕНА ДЛЯ VLESS TLS ===${NC}"
        local cur_dom
        cur_dom="$(get_state_val "vless_domain" "")"
        if [[ -n "$cur_dom" ]]; then
            echo -e "Текущий настроенный домен: ${BOLD}${CYAN}${cur_dom}${NC}"
        fi
        if [[ -n "$auto_domain" && "$auto_domain" != "$cur_dom" ]]; then
            echo -e "${GREEN}✔ Обнаружен готовый сертификат Let's Encrypt для домена:${NC} ${BOLD}${auto_domain}${NC}"
            read -rp "Использовать этот домен [Enter = ${auto_domain}]: " dest_in || true
            new_domain="${dest_in:-$auto_domain}"
        else
            read -rp "Введите новый домен VLESS (например: your-vless.domain.com): " dest_in || true
            new_domain="${dest_in:-}"
        fi
    fi

    if [[ -z "$new_domain" ]]; then
        error "Домен обязателен для настройки VLESS TLS."
        return 1
    fi

    install_vless_direct_node "$new_domain"
}

uninstall_vless_component() {
    title "УДАЛЕНИЕ КОМПОНЕНТА VLESS TLS"
    check_root
    init_state_dir

    local confirm_del=""
    if [[ "${1:-}" == "--yes" || "${1:-}" == "-y" || "${FORCE:-}" == "1" ]]; then
        confirm_del="y"
    else
        read -rp "Вы действительно хотите удалить службу VLESS TLS с этого сервера? [y/N]: " confirm_del || true
    fi
    if [[ "$confirm_del" != [yY] && "$confirm_del" != [yY][eE][sS] && "$confirm_del" != "да" && "$confirm_del" != "Да" ]]; then
        log "Удаление отменено."
        return 0
    fi

    local cur_has_r_init
    cur_has_r_init="$(get_state_val "has_relay" "0")"

    if [[ "$cur_has_r_init" != "1" ]]; then
        systemctl stop xray-api 2>/dev/null || true
        systemctl disable xray-api 2>/dev/null || true
        rm -f /etc/systemd/system/xray-api.service 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
    fi

    rm -f /etc/nginx/sites-enabled/just1k-vless-api.conf /etc/nginx/sites-available/just1k-vless-api.conf /etc/nginx/sites-enabled/just1k-fallback80.conf /etc/nginx/sites-available/just1k-fallback80.conf 2>/dev/null || true
    if [[ -f "/etc/nginx/sites-available/default.user.bak" && ! -e "/etc/nginx/sites-enabled/default" ]]; then
        if [[ ! -f /etc/nginx/sites-enabled/just1k-origin.conf ]]; then
            cp -a "/etc/nginx/sites-available/default.user.bak" "/etc/nginx/sites-available/default" 2>/dev/null || true
            ln -sf "/etc/nginx/sites-available/default" "/etc/nginx/sites-enabled/default" 2>/dev/null || true
            rm -f "/etc/nginx/sites-available/default.user.bak" 2>/dev/null || true
            log "Nginx: восстановлен исходный сайт default из default.user.bak"
        fi
    fi
    local amnezia_nginx="/etc/nginx/sites-available/just1k-amnezia.conf"
    if [[ "$cur_has_r_init" != "1" && -f "$amnezia_nginx" ]] && grep -q "location /v1/" "$amnezia_nginx"; then
        python3 -c "
import re, sys
p = sys.argv[1]
try:
    with open(p, 'r', encoding='utf-8') as f:
        c = f.read()
    c = re.sub(r'[ \t]*location\s+/v1/\s*\{[^}]*\}\n?', '', c)
    with open(p, 'w', encoding='utf-8') as f:
        f.write(c)
except Exception:
    pass
" "$amnezia_nginx" 2>/dev/null || true
    fi
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || true
    fi

    if [[ -f "$XRAY_CONFIG" ]]; then
        if ! python3 -c "
import json, os, sys, tempfile
cfg_file = sys.argv[1]
if not os.path.exists(cfg_file):
    sys.exit(0)
with open(cfg_file, 'r', encoding='utf-8') as f:
    cfg = json.load(f)
cfg['inbounds'] = [ib for ib in cfg.get('inbounds', []) if ib.get('tag') != 'just1k-vless-direct']
dir_name = os.path.dirname(cfg_file)
with tempfile.NamedTemporaryFile('w', dir=dir_name, delete=False, encoding='utf-8') as tf:
    json.dump(cfg, tf, indent=2, ensure_ascii=False)
    tf.flush()
    os.fsync(tf.fileno())
    tmp_path = tf.name
os.replace(tmp_path, cfg_file)
" "$XRAY_CONFIG"; then
            error "Не удалось удалить inbound VLESS из конфигурации Xray ($XRAY_CONFIG)."
            return 1
        fi
        ensure_xray_config_permissions "$XRAY_CONFIG"
        if ! python3 -c "
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    cfg = json.load(f)
if any(ib.get('tag') == 'just1k-vless-direct' for ib in cfg.get('inbounds', [])):
    sys.exit(1)
" "$XRAY_CONFIG" 2>/dev/null; then
            error "Ошибка верификации: inbound just1k-vless-direct остался в $XRAY_CONFIG."
            return 1
        fi
    fi

    ufw delete allow 443/tcp >/dev/null 2>&1 || true
    if [[ "$cur_has_r_init" != "1" ]]; then
        ufw delete allow 8444/tcp >/dev/null 2>&1 || true
    fi

    set_state_val "has_vless" "0"
    set_state_val "vless_domain" ""

    migrate_legacy_state
    local cur_has_a cur_has_r
    cur_has_a="$(get_state_val "has_awg" "0")"
    cur_has_r="$(get_state_val "has_relay" "0")"
    if [[ "$cur_has_a" == "0" && "$cur_has_r" == "0" ]]; then
        set_state_val "role" "unconfigured"
    else
        set_state_val "role" "node"
    fi

    if [[ "$cur_has_r" == "1" ]]; then
        if "$XRAY_BIN" run -test -config "$XRAY_CONFIG" 2>/dev/null; then
            systemctl restart xray 2>/dev/null || true
        fi
    else
        systemctl stop xray 2>/dev/null || true
        systemctl disable xray 2>/dev/null || true
    fi

    log "✔ Компонент VLESS TLS успешно удален с сервера."
}

uninstall_relay_component() {
    title "УДАЛЕНИЕ КОМПОНЕНТА RELAY (БЕЛЫЙ ИНТЕРНЕТ)"
    check_root
    init_state_dir

    local confirm_del=""
    if [[ "${1:-}" == "--yes" || "${1:-}" == "-y" || "${FORCE:-}" == "1" ]]; then
        confirm_del="y"
    else
        read -rp "Вы действительно хотите удалить службу Relay с этого сервера? [y/N]: " confirm_del || true
    fi
    if [[ "$confirm_del" != [yY] && "$confirm_del" != [yY][eE][sS] && "$confirm_del" != "да" && "$confirm_del" != "Да" ]]; then
        log "Удаление отменено."
        return 0
    fi

    local relay_port
    relay_port="$(get_state_val "relay_port" "10443")"

    if [[ -f "$XRAY_CONFIG" ]]; then
        python3 -c "
import json, os, sys
cfg_file = sys.argv[1]
if os.path.exists(cfg_file):
    try:
        with open(cfg_file, 'r', encoding='utf-8') as f:
            cfg = json.load(f)
        cfg['inbounds'] = [ib for ib in cfg.get('inbounds', []) if ib.get('tag') not in ('inbound-tls', 'inbound-reality', 'from-origin')]
        with open(cfg_file, 'w', encoding='utf-8') as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
    except Exception:
        pass
" "$XRAY_CONFIG" 2>/dev/null || true
    fi

    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -qi "Status: active"; then
            # Удаляем только правила TCP с действием ALLOW IN для точного relay_port
            local r_nums
            r_nums="$(ufw status numbered 2>/dev/null | grep -E "\[\s*[0-9]+\]\s+${relay_port}/tcp\s+ALLOW IN\b" | awk -F'[][]' '{print $2}' | sort -rn)"
            for r_n in $r_nums; do
                if [[ -n "$r_n" ]]; then
                    echo "y" | ufw delete "$r_n" >/dev/null 2>&1 || true
                fi
            done
        fi
        # Очищаем спецификацию правила TCP даже если UFW временно неактивен
        ufw delete allow "${relay_port}/tcp" >/dev/null 2>&1 || true
    fi

    set_state_val "has_relay" "0"

    local cur_has_a cur_has_v
    cur_has_a="$(get_state_val "has_awg" "0")"
    cur_has_v="$(get_state_val "has_vless" "0")"
    if [[ "$cur_has_a" == "0" && "$cur_has_v" == "0" ]]; then
        set_state_val "role" "unconfigured"
    else
        set_state_val "role" "node"
    fi

    if [[ "$cur_has_v" == "1" ]]; then
        if "$XRAY_BIN" run -test -config "$XRAY_CONFIG" 2>/dev/null; then
            systemctl restart xray 2>/dev/null || true
        fi
    else
        systemctl stop xray 2>/dev/null || true
        systemctl disable xray 2>/dev/null || true
    fi

    log "✔ Компонент Relay успешно удален с сервера."
}
