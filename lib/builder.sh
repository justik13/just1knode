#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE v2 - Единый сборщик Xray, Nginx HTTP/Stream и UFW для ролей v2
# =============================================================================

_cleanup_legacy_stream443() {
    local nginx_dir="${NGINX_CONF_DIR:-/etc/nginx}"
    local main_conf="${nginx_dir}/nginx.conf"
    local stream_conf="${nginx_dir}/just1k-stream443.conf"
    rm -f "$stream_conf" "${nginx_dir}/conf.d/just1k-stream443.conf" "${nginx_dir}/streams-enabled/just1k-stream443.conf" 2>/dev/null || true
    [[ -f "$main_conf" ]] || return 0
    python3 - "$main_conf" <<'PYEOF'
import os, re, sys, tempfile
main_conf = sys.argv[1]
with open(main_conf, "r", encoding="utf-8", errors="replace") as f:
    text = f.read()
cleaned = re.sub(
    r"\n?# JUST1KNODE STREAM443 START.*?# JUST1KNODE STREAM443 END\n?",
    "\n",
    text,
    flags=re.DOTALL,
)
cleaned = re.sub(
    r"(events\s*\{[^}]*?worker_connections\s+)\d+(\s*;)",
    r"\g<1>4096\g<2>",
    cleaned,
    count=1,
    flags=re.DOTALL,
)
if re.search(r"^\s*worker_rlimit_nofile\s+\d+\s*;", cleaned, flags=re.MULTILINE):
    cleaned = re.sub(
        r"^(\s*worker_rlimit_nofile\s+)\d+(\s*;)",
        r"\g<1>65535\g<2>",
        cleaned,
        count=1,
        flags=re.MULTILINE,
    )
elif re.search(r"^\s*events\s*\{", cleaned, flags=re.MULTILINE):
    cleaned = re.sub(
        r"^(\s*events\s*\{)",
        "worker_rlimit_nofile 65535;\n\\1",
        cleaned,
        count=1,
        flags=re.MULTILINE,
    )
if cleaned != text:
    d = os.path.dirname(os.path.abspath(main_conf))
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(cleaned)
        f.flush()
    os.chmod(tmp, 0o644)
    os.replace(tmp, main_conf)
PYEOF
}

assemble_v2_hub_config() {
    local cfg_file="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
    local state_file="${STATE_FILE:-/etc/just1knode/state.json}"
    local clients_file="${CLIENTS_FILE:-/etc/just1knode/clients.json}"
    local links_file="${LINKS_FILE:-${STATE_DIR:-/etc/just1knode}/links.json}"
    local nginx_dir="${NGINX_CONF_DIR:-/etc/nginx}"
    local le_dir="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
    local xray_tls_dir="${XRAY_CONFIG_DIR:-/usr/local/etc/xray}/tls"

    local cdn_specs_json="{}"
    if declare -F export_loaded_cdn_specs_json >/dev/null 2>&1; then
        cdn_specs_json="$(export_loaded_cdn_specs_json 2>/dev/null || echo "{}")"
    fi

    local broken_csv=""
    if [[ ${#BROKEN_MODULE_IDS[@]} -gt 0 ]]; then
        broken_csv="$(IFS=,; echo "${BROKEN_MODULE_IDS[*]}")"
    fi

    local ssl_reject_avail="false"
    if command -v nginx >/dev/null 2>&1; then
        local ngx_ver=""
        ngx_ver="$(nginx -v 2>&1 | sed -nE 's/.*nginx\/([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n1 || true)"
        if [[ -n "$ngx_ver" ]] && python3 -c 'import sys; p=[int(x) for x in sys.argv[1].split(".")]; sys.exit(0 if tuple(p[:3]) >= (1, 19, 4) else 1)' "$ngx_ver" 2>/dev/null; then
            ssl_reject_avail="true"
        fi
    fi

    local tmp_xray tmp_nginx meta_tmp
    tmp_xray="$(mktemp "${cfg_file}.tmp.XXXXXX.json" 2>/dev/null || mktemp --suffix=.json "${cfg_file}.tmp.XXXXXX" 2>/dev/null || mktemp)"
    if [[ "$tmp_xray" != *.json ]]; then
        mv "$tmp_xray" "${tmp_xray}.json" 2>/dev/null || true
        tmp_xray="${tmp_xray}.json"
    fi
    tmp_nginx="$(mktemp "/tmp/just1k-ru-hub.tmp.XXXXXX" 2>/dev/null || mktemp)"
    meta_tmp="$(mktemp "/tmp/just1k-meta.tmp.XXXXXX" 2>/dev/null || mktemp)"

    local script_root="${SCRIPT_DIR:-}"
    if [[ -z "$script_root" || ! -f "${script_root}/scripts/config_builder.py" ]]; then
        script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || true)"
    fi
    local builder_py="${script_root}/scripts/config_builder.py"
    if [[ ! -f "$builder_py" ]]; then
        builder_py="/opt/just1knode/scripts/config_builder.py"
    fi

    if ! python3 "$builder_py" \
        "$state_file" "$clients_file" "${links_path_dummy:-_}" "$links_file" \
        "$cfg_file" "$tmp_xray" "$tmp_nginx" \
        "$xray_tls_dir" "$le_dir" "$cdn_specs_json" \
        "$broken_csv" "$ssl_reject_avail" > "$meta_tmp"
    then
        rm -f "$tmp_xray" "$tmp_nginx" "$meta_tmp" 2>/dev/null || true
        return 1
    fi

    local nginx_needed="false" fallback80_needed="false" resolved_secret="" resolved_tunnel_uuid=""
    read -r nginx_needed fallback80_needed resolved_secret resolved_tunnel_uuid < <(python3 -c "
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    m = json.load(f)
print(
    'true' if m.get('nginx_needed') else 'false',
    'true' if m.get('fallback80_needed') else 'false',
    m.get('secret_base_path') or '-',
    m.get('tunnel_uuid') or '-',
)
" "$meta_tmp" 2>/dev/null || echo "false false - -")
    rm -f "$meta_tmp" 2>/dev/null || true

    if [[ -n "$resolved_secret" && "$resolved_secret" != "-" ]]; then
        set_state_val "secret_base_path" "$resolved_secret" 2>/dev/null || true
    fi
    if [[ -n "$resolved_tunnel_uuid" && "$resolved_tunnel_uuid" != "-" ]]; then
        set_state_val "tunnel_uuid" "$resolved_tunnel_uuid" 2>/dev/null || true
    fi

    ensure_xray_config_permissions "$tmp_xray"
    if ! "${XRAY_BIN:-/usr/local/bin/xray}" run -test -format json -config "$tmp_xray" >/dev/null 2>&1; then
        "${XRAY_BIN:-/usr/local/bin/xray}" run -test -format json -config "$tmp_xray" || true
        rm -f "$tmp_xray" "$tmp_nginx" 2>/dev/null || true
        warn "Ошибка валидации сгенерированной конфигурации Xray."
        return 1
    fi

    local prev_xray_bak=""
    if [[ -f "$cfg_file" ]]; then
        prev_xray_bak="$(mktemp "${cfg_file}.bak.XXXXXX" 2>/dev/null || mktemp)"
        cp -f "$cfg_file" "$prev_xray_bak" 2>/dev/null || true
    fi
    mv -f "$tmp_xray" "$cfg_file"
    ensure_xray_config_permissions "$cfg_file"

    install_nginx_if_missing
    mkdir -p "${nginx_dir}/sites-available" "${nginx_dir}/sites-enabled" "${nginx_dir}/conf.d"
    local prev_ngx_bak=""
    if [[ -f "${nginx_dir}/sites-available/just1k-ru-hub.conf" ]]; then
        prev_ngx_bak="$(mktemp "/tmp/just1k-ru-hub.bak.XXXXXX" 2>/dev/null || mktemp)"
        cp -f "${nginx_dir}/sites-available/just1k-ru-hub.conf" "$prev_ngx_bak" 2>/dev/null || true
    fi
    local prev_upstreams_bak=""
    if [[ -f "${nginx_dir}/conf.d/just1k-xhttp-upstreams.conf" ]]; then
        prev_upstreams_bak="$(mktemp "/tmp/just1k-xhttp-up.bak.XXXXXX" 2>/dev/null || mktemp)"
        cp -f "${nginx_dir}/conf.d/just1k-xhttp-upstreams.conf" "$prev_upstreams_bak" 2>/dev/null || true
    fi
    local had_default_enabled="false"
    [[ -e "${nginx_dir}/sites-enabled/default" || -L "${nginx_dir}/sites-enabled/default" ]] && had_default_enabled="true"
    local had_fb_enabled="false"
    [[ -e "${nginx_dir}/sites-enabled/just1k-fallback80.conf" || -L "${nginx_dir}/sites-enabled/just1k-fallback80.conf" ]] && had_fb_enabled="true"
    local had_hub_enabled="false"
    [[ -e "${nginx_dir}/sites-enabled/just1k-ru-hub.conf" || -L "${nginx_dir}/sites-enabled/just1k-ru-hub.conf" ]] && had_hub_enabled="true"
    local had_upstreams_conf="false"
    [[ -e "${nginx_dir}/conf.d/just1k-xhttp-upstreams.conf" || -L "${nginx_dir}/conf.d/just1k-xhttp-upstreams.conf" ]] && had_upstreams_conf="true"
    if [[ "$nginx_needed" == "true" ]]; then
        # Atomically retire legacy origin.conf if present
        rm -f "${nginx_dir}/sites-enabled/just1k-origin.conf" "${nginx_dir}/sites-available/just1k-origin.conf" 2>/dev/null || true
        cp -f "$tmp_nginx" "${nginx_dir}/sites-available/just1k-ru-hub.conf"
        chmod 644 "${nginx_dir}/sites-available/just1k-ru-hub.conf" 2>/dev/null || true
        ln -sf "${nginx_dir}/sites-available/just1k-ru-hub.conf" "${nginx_dir}/sites-enabled/just1k-ru-hub.conf"
        if [[ -e "${nginx_dir}/sites-enabled/default" && ! -f "${nginx_dir}/sites-available/default.user.bak" ]]; then
            cp -L "${nginx_dir}/sites-enabled/default" "${nginx_dir}/sites-available/default.user.bak" 2>/dev/null || true
        fi
        rm -f "${nginx_dir}/sites-enabled/default" "${nginx_dir}/sites-enabled/just1k-fallback80.conf" "${nginx_dir}/conf.d/xhttp-map.conf" 2>/dev/null || true
        sync_xhttp_upstreams_conf || true
    else
        rm -f "${nginx_dir}/sites-enabled/just1k-ru-hub.conf" "${nginx_dir}/sites-enabled/just1k-origin.conf" "${nginx_dir}/conf.d/xhttp-map.conf" "${nginx_dir}/conf.d/just1k-xhttp-upstreams.conf" 2>/dev/null || true
        if [[ "$fallback80_needed" == "true" ]]; then
            deploy_v2_fallback80_nginx
        else
            rm -f "${nginx_dir}/sites-enabled/just1k-fallback80.conf" 2>/dev/null || true
        fi
    fi
    _cleanup_legacy_stream443
    rm -f "$tmp_nginx" 2>/dev/null || true

    if ! nginx -t >/dev/null 2>&1; then
        nginx -t || true
        if [[ -n "$prev_ngx_bak" && -f "$prev_ngx_bak" ]]; then
            cp -f "$prev_ngx_bak" "${nginx_dir}/sites-available/just1k-ru-hub.conf" 2>/dev/null || true
        fi
        if [[ "$had_hub_enabled" == "true" && -f "${nginx_dir}/sites-available/just1k-ru-hub.conf" ]]; then
            ln -sf "${nginx_dir}/sites-available/just1k-ru-hub.conf" "${nginx_dir}/sites-enabled/just1k-ru-hub.conf" 2>/dev/null || true
        elif [[ "$had_hub_enabled" == "false" ]]; then
            rm -f "${nginx_dir}/sites-enabled/just1k-ru-hub.conf" 2>/dev/null || true
        fi
        if [[ -n "$prev_upstreams_bak" && -f "$prev_upstreams_bak" ]]; then
            cp -f "$prev_upstreams_bak" "${nginx_dir}/conf.d/just1k-xhttp-upstreams.conf" 2>/dev/null || true
        elif [[ "$had_upstreams_conf" == "false" ]]; then
            rm -f "${nginx_dir}/conf.d/just1k-xhttp-upstreams.conf" 2>/dev/null || true
        fi
        if [[ "$had_fb_enabled" == "true" && -f "${nginx_dir}/sites-available/just1k-fallback80.conf" ]]; then
            ln -sf "${nginx_dir}/sites-available/just1k-fallback80.conf" "${nginx_dir}/sites-enabled/just1k-fallback80.conf" 2>/dev/null || true
        elif [[ "$had_fb_enabled" == "false" ]]; then
            rm -f "${nginx_dir}/sites-enabled/just1k-fallback80.conf" 2>/dev/null || true
        fi
        if [[ "$had_default_enabled" == "true" && -f "${nginx_dir}/sites-available/default" ]]; then
            ln -sf "${nginx_dir}/sites-available/default" "${nginx_dir}/sites-enabled/default" 2>/dev/null || true
        fi
        if [[ -n "$prev_xray_bak" && -f "$prev_xray_bak" ]]; then
            cp -f "$prev_xray_bak" "$cfg_file" 2>/dev/null || true
            ensure_xray_config_permissions "$cfg_file"
        fi
        rm -f "$prev_ngx_bak" "$prev_upstreams_bak" "$prev_xray_bak" 2>/dev/null || true
        warn "Ошибка валидации Nginx (nginx -t); конфигурация откатана."
        return 1
    fi
    rm -f "$prev_ngx_bak" "$prev_upstreams_bak" "$prev_xray_bak" 2>/dev/null || true

    setup_base_api_nginx || return 1
    return 0
}
