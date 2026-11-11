#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE - Библиотека управления SSL и маскировкой (lib/ssl.sh)
# =============================================================================

CERTBOT_DIR="${CERTBOT_DIR:-/var/www/certbot}"
WWW_HTML_DIR="${WWW_HTML_DIR:-/var/www/html}"
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx}"

obtain_ssl_certificate() {
    local domain="$1"
    local email="$2"

    log "Получение SSL-сертификата Let's Encrypt для ${domain}..."
    mkdir -p "${CERTBOT_DIR}"

    if ! certbot certonly --webroot -w "${CERTBOT_DIR}" \
        -d "${domain}" \
        --email "${email}" \
        --agree-tos \
        --no-eff-email \
        --non-interactive \
        --keep-until-expiring; then
        error "Не удалось выпустить SSL-сертификат для ${domain}. Проверьте DNS A-запись и доступность порта 80."
    fi

    log "SSL-сертификат для ${domain} успешно получен!"
}

LETSENCRYPT_DIR="${LETSENCRYPT_DIR:-/etc/letsencrypt}"

deploy_camouflage_site() {
    # Zero-Signature Standard: удаление устаревших веб-заглушек для исключения детекции сканерами
    local www_index="${WWW_HTML_DIR:-/var/www/html}/index.html"
    if [[ -f "$www_index" ]] && (grep -q "Cloud Ingress Network Node" "$www_index" 2>/dev/null || grep -q "SimpleCalc" "$www_index" 2>/dev/null || grep -q "Edge Gateway" "$www_index" 2>/dev/null); then
        rm -f "$www_index" 2>/dev/null || true
    fi
}

deploy_certbot_renewal_hook() {
    mkdir -p "${LETSENCRYPT_DIR}/renewal-hooks/deploy"
    cat > "${LETSENCRYPT_DIR}/renewal-hooks/deploy/restart-xray-nginx.sh" <<'EOF'
#!/bin/bash
systemctl reload nginx 2>/dev/null || true
if [ -f /etc/just1knode/traffic_limit_exceeded ] || [ -f /etc/just1knode/traffic_cutoff.active ]; then
    exit 0
fi
systemctl restart xray 2>/dev/null || true
if [[ -f /etc/systemd/system/xray-api.service ]]; then
    sleep 1
    if ! systemctl is-active --quiet xray-api 2>/dev/null; then
        systemctl reset-failed xray-api 2>/dev/null || true
        systemctl start xray-api 2>/dev/null || true
    fi
fi
EOF
    chmod +x "${LETSENCRYPT_DIR}/renewal-hooks/deploy/restart-xray-nginx.sh"
}

sync_xray_tls_cert_files() {
    local domain="$1"
    local prefix="${2:-}"
    local le_live="${LETSENCRYPT_DIR:-/etc/letsencrypt}/live/${domain}"
    local xray_tls_dir="${XRAY_CONFIG_DIR:-/usr/local/etc/xray}/tls"
    [[ -f "${le_live}/fullchain.pem" && -f "${le_live}/privkey.pem" ]] || return 1

    mkdir -p "$xray_tls_dir"
    chmod 755 "$(dirname "$xray_tls_dir")" "$xray_tls_dir" 2>/dev/null || true

    local targets=("fullchain.pem" "privkey.pem")
    if [[ -n "$prefix" && "$prefix" != "default" ]]; then
        targets+=("${prefix}_fullchain.pem" "${prefix}_privkey.pem")
    fi

    local t src
    for t in "${targets[@]}"; do
        if [[ "$t" == *fullchain.pem ]]; then
            src="${le_live}/fullchain.pem"
        else
            src="${le_live}/privkey.pem"
        fi
        install -m 640 "$src" "${xray_tls_dir}/${t}" 2>/dev/null || cp -f "$src" "${xray_tls_dir}/${t}"
        if getent group xrayapi >/dev/null 2>&1; then
            chown root:xrayapi "${xray_tls_dir}/${t}" 2>/dev/null || true
            chmod 644 "${xray_tls_dir}/${t}" 2>/dev/null || chmod 640 "${xray_tls_dir}/${t}" 2>/dev/null || true
        else
            chown root:nogroup "${xray_tls_dir}/${t}" 2>/dev/null || true
        fi
    done
    return 0
}

get_ssl_cert_expiry() {
    local domain="$1"
    local cert_file="${LETSENCRYPT_DIR:-/etc/letsencrypt}/live/${domain}/fullchain.pem"
    if [[ -f "$cert_file" ]]; then
        openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2 || echo ""
    fi
}

# Автоматическое определение существующего или выпуск нового SSL Let's Encrypt без ручного ввода путей
ensure_domain_ssl_auto() {
    local domain="$1"
    local prefix="${2:-}"
    local email="${3:-admin@${domain}}"
    local le_dir="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
    local cert_file="${le_dir}/live/${domain}/fullchain.pem"
    local key_file="${le_dir}/live/${domain}/privkey.pem"

    deploy_certbot_renewal_hook

    if [[ -f "$cert_file" && -f "$key_file" ]]; then
        if openssl x509 -checkend 86400 -noout -in "$cert_file" 2>/dev/null; then
            log "✔ Обнаружен действующий SSL-сертификат Let's Encrypt для ${domain}."
            sync_xray_tls_cert_files "$domain" "$prefix" || return 1
            return 0
        fi
        warn "SSL-сертификат для ${domain} истекает или истек. Выполняется перевыпуск..."
    fi

    if ! command -v certbot >/dev/null 2>&1; then
        log "Установка certbot..."
        apt-get update -qq && apt-get install -y -qq certbot >/dev/null 2>&1 || return 1
    fi

    local ufw_opened_80=0
    local nginx_paused=0
    local port80_container=""
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        if ! ufw status 2>/dev/null | grep -E "(^|[[:space:]])80(/tcp)?[[:space:]]+ALLOW" -q; then
            ufw allow 80/tcp comment "just1knode certbot verification" >/dev/null 2>&1 && ufw_opened_80=1
        fi
    fi

    _cleanup_auto_ssl() {
        if [[ $nginx_paused -eq 1 ]]; then
            systemctl start nginx 2>/dev/null || true
        fi
        if [[ -n "$port80_container" ]] && command -v docker >/dev/null 2>&1; then
            docker start "$port80_container" >/dev/null 2>&1 || true
        fi
        if [[ $ufw_opened_80 -eq 1 ]]; then
            ufw delete allow 80/tcp >/dev/null 2>&1 || true
            ufw delete allow 80 >/dev/null 2>&1 || true
        fi
    }

    if systemctl is-active --quiet nginx 2>/dev/null; then
        if systemctl stop nginx 2>/dev/null; then
            nginx_paused=1
        fi
    fi
    if command -v detect_host_port80_container >/dev/null 2>&1; then
        port80_container="$(detect_host_port80_container 2>/dev/null || true)"
        if [[ -n "$port80_container" ]]; then
            docker stop "$port80_container" >/dev/null 2>&1 || port80_container=""
        fi
    fi

    log "Запрос SSL-сертификата Let's Encrypt для ${domain} (Standalone ACME)..."
    local cert_rc=0
    certbot certonly --standalone \
        --preferred-challenges http \
        --http-01-port 80 \
        -d "${domain}" \
        --email "${email}" \
        --agree-tos \
        --no-eff-email \
        --non-interactive \
        --keep-until-expiring >/dev/null 2>&1 || cert_rc=$?

    _cleanup_auto_ssl

    if [[ $cert_rc -ne 0 || ! -f "$cert_file" || ! -f "$key_file" ]]; then
        warn "Не удалось выпустить SSL-сертификат для ${domain}. Проверьте A-запись DNS и доступность порта 80."
        return 1
    fi

    sync_xray_tls_cert_files "$domain" "$prefix" || return 1
    log "✔ SSL-сертификат Let's Encrypt для ${domain} выпущен и подключен."
    return 0
}
