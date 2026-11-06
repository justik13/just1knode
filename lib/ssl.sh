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
    local le_dir="${LETSENCRYPT_DIR:-/etc/letsencrypt}"

    # 1. Проверяем, существует ли УЖЕ действующий сертификат
    if [[ -f "${le_dir}/live/${domain}/fullchain.pem" && -f "${le_dir}/live/${domain}/privkey.pem" ]] && \
       openssl x509 -checkend 86400 -noout -in "${le_dir}/live/${domain}/fullchain.pem" 2>/dev/null && \
       openssl x509 -checkhost "$domain" -noout -in "${le_dir}/live/${domain}/fullchain.pem" 2>/dev/null; then
        log "✔ Обнаружен действующий TLS-сертификат для '${domain}'!"
        return 0
    fi

    for cand in "${le_dir}/live"/*/fullchain.pem; do
        if [[ -f "$cand" ]]; then
            local cand_dir cand_key
            cand_dir="$(dirname "$cand")"
            cand_key="${cand_dir}/privkey.pem"
            if [[ -f "$cand_key" ]] && \
               openssl x509 -checkend 86400 -noout -in "$cand" 2>/dev/null && \
               openssl x509 -checkhost "$domain" -noout -in "$cand" 2>/dev/null; then
                mkdir -p "${le_dir}/live/${domain}"
                cp -f "$cand" "${le_dir}/live/${domain}/fullchain.pem"
                cp -f "$cand_key" "${le_dir}/live/${domain}/privkey.pem"
                chmod 644 "${le_dir}/live/${domain}/fullchain.pem"
                chmod 600 "${le_dir}/live/${domain}/privkey.pem"
                log "✔ Обнаружен действующий Wildcard-сертификат в $(basename "$cand_dir"), покрывающий '${domain}'!"
                return 0
            fi
        fi
    done

    # 2. Режим Zero-Signature Bootstrap
    local use_wildcard="${USE_WILDCARD_CERT:-1}"
    if [[ "$use_wildcard" == "1" ]]; then
        log "🔒 Режим Zero-Signature: порт 80 не открывается, выпуск certbot пропущен."
        log "Генерация стартового bootstrap-сертификата для '${domain}' (ожидание боевого Wildcard от бота)..."
        mkdir -p "${le_dir}/live/${domain}"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "${le_dir}/live/${domain}/privkey.pem" \
            -out "${le_dir}/live/${domain}/fullchain.pem" \
            -subj "/CN=${domain}" >/dev/null 2>&1
        chmod 644 "${le_dir}/live/${domain}/fullchain.pem"
        chmod 600 "${le_dir}/live/${domain}/privkey.pem"
        log "✔ Стартовый bootstrap-сертификат создан для '${domain}'."
        return 0
    fi

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
if [[ ! -f /etc/just1knode/traffic_cutoff.active ]]; then
    systemctl restart xray 2>/dev/null || true
    if [[ -f /etc/systemd/system/xray-api.service ]]; then
        sleep 1
        if ! systemctl is-active --quiet xray-api 2>/dev/null; then
            systemctl reset-failed xray-api 2>/dev/null || true
            systemctl start xray-api 2>/dev/null || true
        fi
    fi
fi
EOF
    chmod +x "${LETSENCRYPT_DIR}/renewal-hooks/deploy/restart-xray-nginx.sh"
}
