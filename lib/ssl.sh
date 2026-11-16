#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE - Библиотека управления SSL и маскировкой (lib/ssl.sh)
# =============================================================================

CERTBOT_DIR="${CERTBOT_DIR:-/var/www/certbot}"
WWW_HTML_DIR="${WWW_HTML_DIR:-/var/www/html}"
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx}"

_cleanup_self_signed_live_dir() {
    local domain="$1"
    local le_dir="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
    local live_dir="${le_dir}/live/${domain}"
    local cert_file="${live_dir}/fullchain.pem"

    if [[ -d "$live_dir" && ! -f "${le_dir}/renewal/${domain}.conf" && -f "$cert_file" && ! -L "$cert_file" ]] && \
       _is_self_signed_cert "$cert_file"; then
        rm -f "${live_dir}/fullchain.pem" "${live_dir}/privkey.pem" 2>/dev/null || true
        rmdir "$live_dir" 2>/dev/null || true
    fi
}

_is_self_signed_cert() {
    local cert_path="$1"
    [[ -f "$cert_path" ]] || return 1
    local issuer subject
    issuer="$(openssl x509 -noout -issuer -in "$cert_path" 2>/dev/null | sed -e 's/^issuer=//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)"
    subject="$(openssl x509 -noout -subject -in "$cert_path" 2>/dev/null | sed -e 's/^subject=//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)"
    [[ -n "$issuer" && -n "$subject" && "$issuer" == "$subject" ]]
}

_has_valid_domain_cert() {
    local domain="$1"
    local le_dir="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
    local direct_cert="${le_dir}/live/${domain}/fullchain.pem"
    local direct_key="${le_dir}/live/${domain}/privkey.pem"

    if [[ -f "$direct_cert" && -f "$direct_key" ]] && \
       openssl x509 -checkend 86400 -noout -in "$direct_cert" 2>/dev/null && \
       (openssl x509 -checkhost "$domain" -noout -in "$direct_cert" 2>/dev/null || \
        openssl x509 -subject -noout -in "$direct_cert" 2>/dev/null | grep -Fq "CN = ${domain}" || \
        openssl x509 -subject -noout -in "$direct_cert" 2>/dev/null | grep -Fq "CN=${domain}") && \
       ! _is_self_signed_cert "$direct_cert"; then
        return 0
    fi

    return 1
}

LETSENCRYPT_DIR="${LETSENCRYPT_DIR:-/etc/letsencrypt}"

deploy_certbot_renewal_hook() {
    mkdir -p "${LETSENCRYPT_DIR}/renewal-hooks/deploy"
    cat > "${LETSENCRYPT_DIR}/renewal-hooks/deploy/restart-xray-nginx.sh" <<'EOF'
#!/bin/bash
systemctl reload nginx 2>/dev/null || true
if [ -f /etc/just1knode/traffic_limit_exceeded ]; then
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
            if [[ "$t" == *fullchain.pem ]]; then
                chmod 644 "${xray_tls_dir}/${t}" 2>/dev/null || true
            else
                chmod 640 "${xray_tls_dir}/${t}" 2>/dev/null || true
            fi
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

# Автоматическая проверка или выпуск индивидуального TLS-сертификата Let's Encrypt
ensure_domain_ssl_auto() {
    local domain="$1"
    local prefix="${2:-}"
    local email="${3:-admin@${domain}}"
    local le_dir="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
    local cert_file="${le_dir}/live/${domain}/fullchain.pem"
    local key_file="${le_dir}/live/${domain}/privkey.pem"

    deploy_certbot_renewal_hook

    if _has_valid_domain_cert "$domain"; then
        log "✔ Обнаружен действующий TLS-сертификат для '${domain}'!"
        sync_xray_tls_cert_files "$domain" "$prefix" || return 1
        return 0
    fi

    if [[ -f "$cert_file" && -f "$key_file" ]]; then
        warn "SSL-сертификат для ${domain} истекает или не подходит. Выполняется перевыпуск ACME..."
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
    _cleanup_self_signed_live_dir "$domain"
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
