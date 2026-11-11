#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE v2 - Единый движок сборки Xray, Nginx и UFW для ролей хаба/ноды
# =============================================================================

# Создаёт минимальный валидный config.json со встроенным gRPC API (10085),
# чтобы Xray и xray-api запускались сразу после базовой установки узла.
ensure_xray_stub_config() {
    local cfg="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
    local cfg_dir
    cfg_dir="$(dirname "$cfg")"
    mkdir -p "$cfg_dir"
    if [[ ! -f "$cfg" || ! -s "$cfg" ]]; then
        cat > "$cfg" <<'EOF'
{
  "log": {
    "loglevel": "warning"
  },
  "stats": {},
  "api": {
    "tag": "api",
    "services": [
      "HandlerService",
      "StatsService"
    ]
  },
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
      "tag": "just1k-wl-api-grpc",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "just1k-wl-api",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "just1k-wl-api-grpc"
        ],
        "outboundTag": "just1k-wl-api"
      }
    ]
  }
}
EOF
    fi
    ensure_xray_config_permissions "$cfg"
}

# Подготавливает SSL-сертификат для панели API на порту 8444 (Let's Encrypt при наличии или self-signed)
ensure_api_ssl_cert() {
    local domain cert_path key_path
    domain="$(get_state_val "domain" "")"
    [[ -z "$domain" || "$domain" == "-" ]] && domain="$(get_state_val "vless_domain" "")"

    if [[ -n "$domain" && "$domain" != "-" ]]; then
        local le_cert="${LETSENCRYPT_DIR:-/etc/letsencrypt}/live/${domain}/fullchain.pem"
        local le_key="${LETSENCRYPT_DIR:-/etc/letsencrypt}/live/${domain}/privkey.pem"
        if [[ -f "$le_cert" && -f "$le_key" ]]; then
            echo "${le_cert}|${le_key}"
            return 0
        fi
    fi

    local ssl_dir="${NGINX_CONF_DIR:-/etc/nginx}/fallback_ssl"
    cert_path="${ssl_dir}/api_selfsigned.crt"
    key_path="${ssl_dir}/api_selfsigned.key"
    mkdir -p "$ssl_dir"
    if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -keyout "$key_path" -out "$cert_path" \
            -subj "/CN=just1knode-api" >/dev/null 2>&1 || return 1
        chmod 644 "$cert_path" 2>/dev/null || true
        chmod 600 "$key_path" 2>/dev/null || true
    fi
    echo "${cert_path}|${key_path}"
    return 0
}

# Настраивает Nginx reverse proxy на порту 8444 -> 127.0.0.1:5001 (xray-api)
setup_base_api_nginx() {
    install_nginx_if_missing
    local nginx_dir="${NGINX_CONF_DIR:-/etc/nginx}"
    local avail="${nginx_dir}/sites-available/just1k-vless-api.conf"
    local enabled="${nginx_dir}/sites-enabled/just1k-vless-api.conf"
    mkdir -p "${nginx_dir}/sites-available" "${nginx_dir}/sites-enabled"

    local ssl_pair cert_path key_path
    ssl_pair="$(ensure_api_ssl_cert)" || return 1
    cert_path="${ssl_pair%%|*}"
    key_path="${ssl_pair#*|}"

    local server_name="_"
    local domain
    domain="$(get_state_val "domain" "")"
    [[ -n "$domain" && "$domain" != "-" ]] && server_name="${domain} _"

    local tmp_conf
    tmp_conf="$(mktemp "${avail}.XXXXXX" 2>/dev/null || mktemp)"
    cat > "$tmp_conf" <<EOF
server {
    listen 8444 ssl http2;
    listen [::]:8444 ssl http2;
    server_name ${server_name};

    ssl_certificate ${cert_path};
    ssl_certificate_key ${key_path};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    server_tokens off;

    location / {
        proxy_pass http://127.0.0.1:5001;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
    }
}
EOF
    chmod 644 "$tmp_conf" 2>/dev/null || true
    mv -f "$tmp_conf" "$avail"
    ln -sf "$avail" "$enabled"

    if ! nginx -t >/dev/null 2>&1; then
        warn "Nginx: синтаксическая ошибка при настройке API (порт 8444)."
        return 1
    fi
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    return 0
}

# Разворачивает локальный fallback Nginx на 127.0.0.1:80 -> 404 (защита от активного пробинга TLS)
deploy_v2_fallback80_nginx() {
    install_nginx_if_missing
    local nginx_dir="${NGINX_CONF_DIR:-/etc/nginx}"
    local avail="${nginx_dir}/sites-available/just1k-fallback80.conf"
    local enabled="${nginx_dir}/sites-enabled/just1k-fallback80.conf"
    mkdir -p "${nginx_dir}/sites-available" "${nginx_dir}/sites-enabled"

    if [[ -L "${nginx_dir}/sites-enabled/default" || -f "${nginx_dir}/sites-enabled/default" ]]; then
        if [[ -f "${nginx_dir}/sites-available/default" && ! -f "${nginx_dir}/sites-available/default.user.bak" ]]; then
            cp -a "${nginx_dir}/sites-available/default" "${nginx_dir}/sites-available/default.user.bak" 2>/dev/null || true
        fi
        rm -f "${nginx_dir}/sites-enabled/default" 2>/dev/null || true
    fi

    cat > "$avail" <<'EOF'
server {
    listen 127.0.0.1:80 default_server;
    server_name _;
    server_tokens off;

    location / {
        return 404 "Not Found\n";
    }
}
EOF
    chmod 644 "$avail" 2>/dev/null || true
    ln -sf "$avail" "$enabled"
    return 0
}

# Универсальный сборщик Xray-конфига и Nginx маршрутизации для ролей v2 (ru_hub / eu_hub / exit_node)
assemble_v2_hub_config() {
    local cfg_file="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
    local state_file="${STATE_FILE:-/etc/just1knode/state.json}"
    local clients_file="${CLIENTS_FILE:-/etc/just1knode/clients.json}"
    local relays_file="${RELAYS_FILE:-${STATE_DIR:-/etc/just1knode}/relays.json}"
    local nginx_dir="${NGINX_CONF_DIR:-/etc/nginx}"
    local relays_d="${NGINX_RELAYS_DIR:-/etc/nginx/just1k_relays.d}"
    local le_dir="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
    local xray_tls_dir="${XRAY_CONFIG_DIR:-/usr/local/etc/xray}/tls"

    local tmp_xray tmp_nginx tmp_map meta_tmp
    tmp_xray="$(mktemp "${cfg_file}.tmp.XXXXXX" 2>/dev/null || mktemp)"
    tmp_nginx="$(mktemp "/tmp/just1k-origin.tmp.XXXXXX" 2>/dev/null || mktemp)"
    tmp_map="$(mktemp "/tmp/just1k-map.tmp.XXXXXX" 2>/dev/null || mktemp)"
    meta_tmp="$(mktemp "/tmp/just1k-meta.tmp.XXXXXX" 2>/dev/null || mktemp)"

    if ! python3 - "$state_file" "$clients_file" "$relays_file" "$cfg_file" "$tmp_xray" "$tmp_nginx" "$tmp_map" "$xray_tls_dir" "$le_dir" "$relays_d" > "$meta_tmp" <<'PYEOF'
import json
import os
import re
import secrets
import sys
import uuid as uuid_lib

(
    state_path,
    clients_path,
    relays_path,
    cur_cfg_path,
    out_xray_path,
    out_nginx_path,
    out_map_path,
    xray_tls_dir,
    le_dir,
    relays_d,
) = sys.argv[1:11]

# Единая таблица спецификаций CDN-провайдеров (без ветвления и дублирования логики)
CDN_PROVIDER_SPECS = {
    "cdn_yandex": {
        "label": "Yandex CDN",
        "port": 8003,
        "tag": "just1k-wl-default",
        "subpath": "default",
        "upstream": "xray_xhttp_default",
        "uplinkHTTPMethod": "GET",
        "uplinkDataPlacement": "header",
        "uplinkDataKey": "data",
        "xPaddingPlacement": "queryInHeader",
        "real_ip_header": "X-Real-IP",
        "options_rewrite": True,
        "cidrs": [
            "127.0.0.1/32", "::1/128",
            "5.63.111.80/28", "5.187.84.32/28", "31.135.225.72/29", "37.17.118.240/28",
            "37.128.241.248/29", "45.143.89.64/28", "45.157.212.160/28", "46.245.128.32/28",
            "77.41.157.164/31", "79.135.243.112/28", "79.135.243.160/28", "81.211.99.100/31",
            "83.172.51.192/28", "83.172.51.208/28", "83.172.51.224/28", "83.172.51.240/28",
            "83.172.52.64/28", "83.234.162.72/29", "83.234.162.88/29", "83.234.162.104/29",
            "85.26.163.216/31", "85.26.238.214/31", "85.249.252.76/31", "87.248.243.128/28",
            "87.248.243.144/28", "89.38.165.176/28", "89.113.99.112/31", "91.149.176.192/28",
            "92.119.185.48/28", "93.157.160.64/28", "93.190.19.192/28", "94.41.41.16/28",
            "94.41.133.48/28", "94.247.111.208/28", "95.167.77.24/29", "95.167.131.248/29",
            "95.167.135.8/29", "95.167.135.24/29", "109.200.119.104/29", "146.158.117.104/29",
            "146.185.212.64/28", "146.185.212.128/28", "176.59.94.112/28", "176.59.126.240/28",
            "176.59.158.128/28", "176.59.223.240/28", "176.211.111.64/28", "176.211.149.144/28",
            "178.19.241.152/29", "178.34.88.200/29", "178.176.143.66/31", "178.176.151.222/31",
            "178.176.191.78/31", "178.185.206.168/29", "178.185.206.184/29", "185.11.76.160/28",
            "185.154.74.192/28", "185.205.130.40/29", "185.205.130.56/29", "185.205.130.72/29",
            "185.205.130.232/29", "185.205.130.248/29", "185.211.231.0/28", "185.221.46.128/28",
            "188.43.54.136/29", "188.43.55.184/29", "188.43.58.40/29", "188.72.103.0/24",
            "188.72.104.0/24", "188.72.105.0/24", "188.72.105.0/27", "188.72.110.0/28",
            "188.72.110.16/28", "188.72.110.32/28", "188.72.110.48/28", "188.72.111.0/28",
            "188.72.111.16/28", "188.72.111.32/28", "188.72.111.48/28", "188.72.113.0/27",
            "188.190.99.16/28", "194.158.197.176/28", "194.186.130.20/31", "194.186.177.68/31",
            "195.3.244.16/28", "195.16.37.146/31", "195.46.167.172/31", "195.218.143.90/31",
            "195.239.83.64/31", "195.239.101.206/31", "195.239.105.200/31", "195.239.179.56/31",
            "195.239.193.160/31", "212.44.128.188/31", "212.46.212.192/31", "212.49.97.0/28",
            "212.96.95.184/29", "212.119.207.200/31", "212.188.77.224/28", "212.192.230.48/28",
            "212.192.232.48/28", "212.192.234.16/28", "212.192.236.0/28", "213.33.132.240/31",
            "213.33.150.46/31", "217.13.209.0/28", "217.76.71.80/29",
            "2a0d:d6c7:14::/64", "2a0d:d6c7:14:1::/64", "2a0d:d6c7:14:2::/64", "2a0d:d6c7:14:3::/64",
            "2a0d:d6c7:15::/64", "2a0d:d6c7:15:1::/64", "2a0d:d6c7:15:2::/64", "2a0d:d6c7:15:3::/64",
        ],
    },
    "cdn_turboflare": {
        "label": "TurboFlare",
        "port": 8004,
        "tag": "just1k-wl-turboflare",
        "subpath": "turboflare",
        "upstream": "xray_xhttp_turboflare",
        "uplinkHTTPMethod": "POST",
        "uplinkDataPlacement": "body",
        "uplinkDataKey": "",
        "xPaddingPlacement": "header",
        "real_ip_header": "X-Real-IP",
        "options_rewrite": False,
        "cidrs": [
            "127.0.0.1/32", "::1/128",
            "151.236.64.0/18", "62.152.61.0/24", "185.31.112.0/22", "185.141.225.0/24",
            "91.231.232.0/21", "91.238.108.0/22", "91.240.168.0/22", "78.159.248.0/21",
            "81.222.126.0/23", "46.42.184.0/21", "128.75.231.0/24", "195.211.0.0/16",
            "2a02:aec0::/32",
        ],
    },
}

def load_json(path, default):
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as fp:
                return json.load(fp)
        except Exception:
            pass
    return default

state = load_json(state_path, {})
if not isinstance(state, dict):
    state = {}

role = str(state.get("role", "unconfigured")).strip().lower()
domain = str(state.get("domain", "")).strip()
bot_domain = str(state.get("bot_domain", "")).strip()
sub_prefix = str(state.get("sub_path_prefix") or "/sub/wl").strip().rstrip("/") or "/sub/wl"
if not sub_prefix.startswith("/"):
    sub_prefix = "/" + sub_prefix

secret_base = str(state.get("secret_base_path") or "").strip().rstrip("/")
if not secret_base or secret_base in ("/", "/none"):
    secret_base = "/assets_" + secrets.token_hex(4)
elif not secret_base.startswith("/"):
    secret_base = "/" + secret_base

modules = state.get("modules") if isinstance(state.get("modules"), dict) else {}
peers = state.get("peers") if isinstance(state.get("peers"), list) else []
relays_disk = load_json(relays_path, [])
if not isinstance(relays_disk, list):
    relays_disk = []

def mod_on(name):
    m = modules.get(name)
    return isinstance(m, dict) and m.get("enabled") is True

# Извлекаем существующих клиентов из clients.json и текущего config.json (zero-drop при ребилде)
cur_cfg = load_json(cur_cfg_path, {})
existing_clients_by_tag = {}
if isinstance(cur_cfg, dict):
    for ib in cur_cfg.get("inbounds", []):
        tag = ib.get("tag")
        cls = ib.get("settings", {}).get("clients", [])
        if tag and isinstance(cls, list):
            existing_clients_by_tag[tag] = cls

clients_db = load_json(clients_path, {})
vless_clients = {}
wl_clients = {}

if isinstance(clients_db, dict):
    for cid, meta in clients_db.items():
        if not isinstance(meta, dict):
            continue
        email = str(meta.get("email") or cid)
        ss = meta.get("service_states") if isinstance(meta.get("service_states"), dict) else {}
        if ss:
            if isinstance(ss.get("vless"), dict) and ss["vless"].get("is_active") and not ss["vless"].get("tombstone"):
                vless_clients[cid] = {"id": cid, "email": email, "flow": "xtls-rprx-vision"}
            if isinstance(ss.get("white_internet"), dict) and ss["white_internet"].get("is_active") and not ss["white_internet"].get("tombstone"):
                wl_clients[cid] = {"id": cid, "email": email}
        elif meta.get("is_active", True) and not meta.get("tombstone", False):
            svcs = meta.get("services") or ([meta.get("service")] if meta.get("service") else [])
            if "vless" in svcs:
                vless_clients[cid] = {"id": cid, "email": email, "flow": "xtls-rprx-vision"}
            if "white_internet" in svcs:
                wl_clients[cid] = {"id": cid, "email": email}

def merged_clients(tag, primary_map, flow_val="", extra_list=None):
    merged = {}
    for c in existing_clients_by_tag.get(tag, []):
        if isinstance(c, dict) and c.get("id"):
            item = {"id": c["id"], "email": c.get("email") or c["id"]}
            if flow_val:
                item["flow"] = flow_val
            merged[c["id"]] = item
    for cid, c in primary_map.items():
        item = dict(c)
        if flow_val:
            item["flow"] = flow_val
        merged[cid] = item
    if extra_list:
        for c in extra_list:
            if isinstance(c, dict) and c.get("id"):
                item = dict(c)
                if flow_val:
                    item["flow"] = flow_val
                merged[c["id"]] = item
    return list(merged.values())

def build_xhttp_inbound(tag, port, path, spec, clients_list):
    xs = {
        "mode": "packet-up",
        "path": path,
        "uplinkHTTPMethod": spec["uplinkHTTPMethod"],
        "uplinkDataPlacement": spec["uplinkDataPlacement"],
        "scMaxEachPostBytes": 1000000,
        "scMaxConcurrentPosts": 1,
        "scMinPostsIntervalMs": 30,
        "serverMaxHeaderBytes": 65536,
        "xPaddingObfsMode": True,
        "xPaddingKey": "dc",
        "xPaddingHeader": "X-Cache",
        "xPaddingMethod": "tokenish",
        "xPaddingPlacement": spec["xPaddingPlacement"],
    }
    if spec.get("uplinkDataKey"):
        xs["uplinkDataKey"] = spec["uplinkDataKey"]
    return {
        "tag": tag,
        "listen": "127.0.0.1",
        "port": int(port),
        "protocol": "vless",
        "settings": {
            "clients": clients_list,
            "decryption": "none",
        },
        "streamSettings": {
            "network": "xhttp",
            "sockopt": {
                "trustedXForwardedFor": ["X-Forwarded-For"]
            },
            "xhttpSettings": xs,
        },
        "sniffing": {
            "enabled": True,
            "destOverride": ["tls", "http", "quic"],
            "routeOnly": False,
        },
    }

def cert_pair():
    pem = os.path.join(xray_tls_dir, "fullchain.pem")
    key = os.path.join(xray_tls_dir, "privkey.pem")
    if domain:
        le_pem = os.path.join(le_dir, "live", domain, "fullchain.pem")
        le_key = os.path.join(le_dir, "live", domain, "privkey.pem")
        if os.path.exists(pem) and os.path.exists(key):
            return pem, key
        if os.path.exists(le_pem) and os.path.exists(le_key):
            return le_pem, le_key
    return pem, key

def antiabuse_rules():
    return [
        {"type": "field", "ip": ["geoip:private"], "outboundTag": "just1k-wl-block"},
        {"type": "field", "protocol": ["bittorrent"], "outboundTag": "just1k-wl-block"},
        {"type": "field", "port": "25", "outboundTag": "just1k-wl-block"},
        {"type": "field", "port": "6881-6889", "outboundTag": "just1k-wl-block"},
        {"type": "field", "port": "443", "network": "udp", "outboundTag": "just1k-wl-block"},
    ]

cfg = {
    "log": {"loglevel": "warning"},
    "stats": {},
    "api": {"tag": "api", "services": ["HandlerService", "StatsService"]},
    "policy": {
        "levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True}},
        "system": {"statsInboundUplink": True, "statsInboundDownlink": True},
    },
    "inbounds": [
        {
            "tag": "just1k-wl-api-grpc",
            "listen": "127.0.0.1",
            "port": 10085,
            "protocol": "dokodemo-door",
            "settings": {"address": "127.0.0.1"},
        }
    ],
    "outbounds": [],
    "routing": {"domainStrategy": "IPIfNonMatch", "rules": []},
}

nginx_needed = False
fallback80_needed = False
map_needed = False

api_rule = {"type": "field", "inboundTag": ["just1k-wl-api-grpc"], "outboundTag": "just1k-wl-api"}

if role == "ru_hub":
    has_vless_tls = mod_on("vless_tls")
    has_xhttp = mod_on("vless_xhttp")
    active_cdns = [k for k in CDN_PROVIDER_SPECS if mod_on(k)]

    client_inbounds = []
    if has_vless_tls:
        c_file, k_file = cert_pair()
        fb_dest = "127.0.0.1:8080" if has_xhttp else "127.0.0.1:80"
        if not has_xhttp:
            fallback80_needed = True
        cfg["inbounds"].append({
            "tag": "just1k-vless-direct",
            "listen": "0.0.0.0",
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": merged_clients("just1k-vless-direct", vless_clients, "xtls-rprx-vision"),
                "decryption": "none",
                "fallbacks": [{"dest": fb_dest}],
            },
            "streamSettings": {
                "network": "tcp",
                "security": "tls",
                "tlsSettings": {
                    "alpn": ["http/1.1"],
                    "certificates": [{"certificateFile": c_file, "keyFile": k_file}],
                },
            },
            "sniffing": {"enabled": True, "destOverride": ["tls", "http", "quic"], "routeOnly": False},
        })
        client_inbounds.append("just1k-vless-direct")

    for cdn_key in active_cdns:
        spec = CDN_PROVIDER_SPECS[cdn_key]
        mod_cfg = modules.get(cdn_key, {})
        c_port = int(mod_cfg.get("port") or spec["port"])
        c_tag = str(mod_cfg.get("tag") or spec["tag"])
        c_path = str(mod_cfg.get("path") or f"{secret_base}/{spec['subpath']}")
        # Позволяет переопределять placement на уровне модуля без правок бэкенда
        spec_eff = dict(spec)
        if mod_cfg.get("xPaddingPlacement"):
            spec_eff["xPaddingPlacement"] = str(mod_cfg["xPaddingPlacement"])
        cfg["inbounds"].append(
            build_xhttp_inbound(c_tag, c_port, c_path, spec_eff, merged_clients(c_tag, wl_clients))
        )
        client_inbounds.append(c_tag)

    # Локационные XHTTP-инбаунды (при наличии релеев в relays.json / peers)
    seen_relay_codes = set()
    relay_peers = [p for p in peers if isinstance(p, dict) and p.get("kind") == "location"] + relays_disk
    base_cdn_spec = CDN_PROVIDER_SPECS[active_cdns[0]] if active_cdns else CDN_PROVIDER_SPECS["cdn_yandex"]
    next_port = 8005
    used_ports = {ib.get("port") for ib in cfg["inbounds"] if ib.get("port")}

    for r in relay_peers:
        if not isinstance(r, dict):
            continue
        code = str(r.get("code") or "").strip().lower()
        if not code or not re.fullmatch(r"[a-z0-9_-]+", code) or code in seen_relay_codes:
            continue
        seen_relay_codes.add(code)
        r_tag = r.get("inbound_tag") or f"just1k-wl-inbound-{code}"
        r_port = int(r.get("inbound_port") or 0)
        if not r_port or r_port in used_ports:
            while next_port in used_ports:
                next_port += 1
            r_port = next_port
        used_ports.add(r_port)
        r_path = r.get("path") or f"{secret_base}/{code}"
        if active_cdns:
            cfg["inbounds"].append(
                build_xhttp_inbound(r_tag, r_port, r_path, base_cdn_spec, merged_clients(r_tag, wl_clients))
            )

    # Исходящие маршруты (РУ прямой доступ + Зарубежные ХАБы)
    cfg["dns"] = {
        "servers": [
            {
                "address": "77.88.8.8",
                "port": 53,
                "domains": [
                    "geosite:category-ru", "geosite:tld-ru",
                    "domain:ru", "domain:su", "domain:xn--p1ai", "domain:2ip.ru",
                ],
                "skipFallback": True,
            },
            "77.88.8.1",
            "195.208.4.1",
        ],
        "queryStrategy": "UseIPv4",
    }

    cfg["outbounds"].append({
        "tag": "just1k-wl-direct",
        "protocol": "freedom",
        "streamSettings": {"sockopt": {"domainStrategy": "UseIPv4"}},
    })

    bridge_peers = [p for p in peers if isinstance(p, dict) and p.get("ip") and p.get("uuid")]
    default_bridge_tag = None
    for idx, p in enumerate(bridge_peers):
        p_code = re.sub(r"[^a-z0-9_-]", "", str(p.get("code") or f"hub{idx+1}").lower()) or f"hub{idx+1}"
        ob_tag = f"relay-{p_code}"
        if not default_bridge_tag or p.get("is_default"):
            default_bridge_tag = ob_tag
        cfg["outbounds"].append({
            "tag": ob_tag,
            "protocol": "vless",
            "settings": {
                "vnext": [{
                    "address": str(p["ip"]).strip(),
                    "port": int(p.get("port") or 443),
                    "users": [{
                        "id": str(p["uuid"]).strip(),
                        "encryption": "none",
                        "flow": "xtls-rprx-vision",
                    }],
                }]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "tls",
                "tlsSettings": {
                    "serverName": str(p.get("sni") or p["ip"]).strip(),
                    "fingerprint": "firefox",
                    "alpn": ["http/1.1"],
                    "allowInsecure": False,
                },
            },
        })
        if f"just1k-wl-inbound-{p_code}" in [ib.get("tag") for ib in cfg["inbounds"]]:
            cfg["routing"]["rules"].append({
                "type": "field",
                "inboundTag": [f"just1k-wl-inbound-{p_code}"],
                "outboundTag": ob_tag,
            })

    cfg["outbounds"].extend([
        {"tag": "just1k-wl-block", "protocol": "blackhole", "settings": {}},
        {"tag": "just1k-wl-api", "protocol": "blackhole", "settings": {}},
    ])

    ru_domains = [
        "geosite:category-ru", "geosite:tld-ru",
        "domain:ru", "domain:su", "domain:xn--p1ai", "domain:2ip.ru",
    ]
    direct_and_bridge_rules = [api_rule] + antiabuse_rules()
    if client_inbounds:
        direct_and_bridge_rules.extend([
            {"type": "field", "inboundTag": client_inbounds, "domain": ru_domains, "outboundTag": "just1k-wl-direct"},
            {"type": "field", "inboundTag": client_inbounds, "ip": ["geoip:ru"], "outboundTag": "just1k-wl-direct"},
        ])
    # Локационные правила идут перед catch-all моста
    location_rules = list(cfg["routing"]["rules"])
    catch_all_tag = default_bridge_tag or "just1k-wl-direct"
    catch_all_rules = []
    if client_inbounds:
        catch_all_rules.append({
            "type": "field",
            "inboundTag": client_inbounds,
            "outboundTag": catch_all_tag,
        })
    cfg["routing"]["rules"] = direct_and_bridge_rules + location_rules + catch_all_rules

    # Nginx конфигурация для ru_hub
    if has_xhttp:
        nginx_needed = True
        listen_block = (
            "    listen 127.0.0.1:8080 default_server;\n"
            if has_vless_tls else
            f"    listen 443 ssl http2 default_server;\n"
            f"    listen [::]:443 ssl http2 default_server;\n"
            f"    ssl_certificate {os.path.join(le_dir, 'live', domain, 'fullchain.pem')};\n"
            f"    ssl_certificate_key {os.path.join(le_dir, 'live', domain, 'privkey.pem')};\n"
            "    ssl_protocols TLSv1.2 TLSv1.3;\n"
            "    ssl_ciphers HIGH:!aNULL:!MD5;\n"
        )
        cidr_lines = []
        seen_cidr = set()
        use_xff = False
        use_xri = False
        for ck in active_cdns:
            sp = CDN_PROVIDER_SPECS[ck]
            if sp["options_rewrite"]:
                map_needed = True
            if sp["real_ip_header"] == "X-Forwarded-For":
                use_xff = True
            else:
                use_xri = True
            for cidr in sp["cidrs"]:
                if cidr not in seen_cidr:
                    seen_cidr.add(cidr)
                    cidr_lines.append(f"    set_real_ip_from {cidr};")
        real_ip_hdr = "X-Forwarded-For" if use_xff or not use_xri else "X-Real-IP"
        loc_blocks = []
        if bot_domain:
            loc_blocks.append(
                f"    location ^~ {sub_prefix}/ {{\n"
                f"        proxy_pass https://{bot_domain}{sub_prefix}/;\n"
                f"        proxy_ssl_server_name on;\n"
                f"        proxy_set_header Host {bot_domain};\n"
                "        proxy_set_header X-Real-IP $remote_addr;\n"
                "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n"
                "    }\n"
            )
        for ck in active_cdns:
            sp = CDN_PROVIDER_SPECS[ck]
            m_cfg = modules.get(ck, {})
            c_path = str(m_cfg.get("path") or f"{secret_base}/{sp['subpath']}").rstrip("/")
            opt_line = "        proxy_method $xhttp_proxy_method;\n" if sp["options_rewrite"] else ""
            loc_blocks.append(
                f"    location ^~ {c_path} {{\n"
                f"        rewrite ^{re.escape(c_path)}/?$ {c_path}/ break;\n"
                f"        proxy_pass http://{sp['upstream']};\n"
                + opt_line
                + "        proxy_http_version 1.1;\n"
                '        proxy_set_header Connection "";\n'
                "        proxy_pass_request_headers on;\n"
                "        proxy_set_header Host $host;\n"
                "        proxy_set_header X-Real-IP $remote_addr;\n"
                "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n"
                "        proxy_buffering off;\n"
                "        proxy_request_buffering off;\n"
                "        proxy_max_temp_file_size 0;\n"
                "        proxy_read_timeout 86400s;\n"
                "        proxy_send_timeout 86400s;\n"
                "        proxy_next_upstream off;\n"
                '        add_header Cache-Control "no-store, no-cache" always;\n'
                '        add_header CDN-Cache-Control "no-store" always;\n'
                '        add_header Pragma "no-cache" always;\n'
                '        add_header Expires "0" always;\n'
                '        add_header X-Accel-Buffering no always;\n'
                '        add_header Accept-Ranges none always;\n'
                "    }\n"
            )
        # Check CDN health endpoint
        loc_blocks.append(
            "    location = /cdn-check {\n"
            "        add_header Content-Type text/plain;\n"
            '        return 204;\n'
            "    }\n"
        )
        if os.path.isdir(relays_d):
            loc_blocks.append(f"    include {relays_d}/*.conf;")
        cdn_dom = str(state.get("cdn_domain") or "").strip()
        srv_names = " ".join([x for x in dict.fromkeys([domain, cdn_dom, "_"]) if x])
        nginx_text = (
            "server {\n"
            + listen_block
            + f"    server_name {srv_names};\n"
            + "    server_tokens off;\n"
            + "    client_max_body_size 0;\n"
            + "    large_client_header_buffers 16 64k;\n"
            + "    client_header_buffer_size 16k;\n"
            + "    tcp_nodelay on;\n"
            + "\n".join(cidr_lines) + "\n"
            + f"    real_ip_header {real_ip_hdr};\n"
            + "    real_ip_recursive on;\n\n"
            + "\n".join(loc_blocks) + "\n"
            + "    location / {\n"
            '        return 404 "Not Found\\n";\n'
            "    }\n"
            "}\n"
        )
        with open(out_nginx_path, "w", encoding="utf-8") as nfp:
            nfp.write(nginx_text)
        if map_needed:
            with open(out_map_path, "w", encoding="utf-8") as mfp:
                mfp.write("map $request_method $xhttp_proxy_method {\n    OPTIONS POST;\n    default $request_method;\n}\n")

elif role == "eu_hub":
    c_file, k_file = cert_pair()
    fallback80_needed = True
    t_uuid = str(state.get("tunnel_uuid") or "").strip()
    if not t_uuid:
        t_uuid = str(uuid_lib.uuid4())
    relay_port = int(state.get("relay_port") or 443)
    in_clients = [{"id": t_uuid, "email": "ru-hub@just1k", "flow": "xtls-rprx-vision"}]
    for p in peers:
        if isinstance(p, dict) and p.get("ingress_uuid"):
            c_code = re.sub(r"[^a-z0-9_-]", "", str(p.get("code") or "").lower()) or "ru"
            in_clients.append({
                "id": str(p["ingress_uuid"]).strip(),
                "email": f"ingress-{c_code}@just1k",
                "flow": "xtls-rprx-vision",
            })

    cfg["inbounds"].append({
        "tag": "inbound-tls",
        "listen": "0.0.0.0",
        "port": relay_port,
        "protocol": "vless",
        "settings": {
            "clients": in_clients,
            "decryption": "none",
            "fallbacks": [{"dest": "127.0.0.1:80"}],
        },
        "streamSettings": {
            "network": "tcp",
            "security": "tls",
            "tlsSettings": {
                "alpn": ["http/1.1"],
                "certificates": [{"certificateFile": c_file, "keyFile": k_file}],
            },
        },
        "sniffing": {"enabled": True, "destOverride": ["tls", "http", "quic"], "routeOnly": False},
    })

    # СТРОГО без freedom: только транзитные выходы на Выходные НОДЫ + blackhole
    exit_peers = [p for p in peers if isinstance(p, dict) and p.get("ip") and p.get("uuid")]
    primary_exit_tag = None
    route_rules = [api_rule] + antiabuse_rules()
    for idx, p in enumerate(exit_peers):
        p_code = re.sub(r"[^a-z0-9_-]", "", str(p.get("code") or f"exit{idx+1}").lower()) or f"exit{idx+1}"
        ob_tag = f"exit-{p_code}"
        if not primary_exit_tag or p.get("is_default"):
            primary_exit_tag = ob_tag
        cfg["outbounds"].append({
            "tag": ob_tag,
            "protocol": "vless",
            "settings": {
                "vnext": [{
                    "address": str(p["ip"]).strip(),
                    "port": int(p.get("port") or 443),
                    "users": [{
                        "id": str(p["uuid"]).strip(),
                        "encryption": "none",
                        "flow": "xtls-rprx-vision",
                    }],
                }]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "tls",
                "tlsSettings": {
                    "serverName": str(p.get("sni") or p["ip"]).strip(),
                    "fingerprint": "firefox",
                    "alpn": ["http/1.1"],
                    "allowInsecure": False,
                },
            },
        })
        if p.get("route_user"):
            route_rules.append({
                "type": "field",
                "user": [str(p["route_user"])],
                "outboundTag": ob_tag,
            })

    cfg["outbounds"].extend([
        {"tag": "just1k-wl-block", "protocol": "blackhole", "settings": {}},
        {"tag": "just1k-wl-api", "protocol": "blackhole", "settings": {}},
    ])
    route_rules.append({
        "type": "field",
        "inboundTag": ["inbound-tls"],
        "outboundTag": primary_exit_tag or "just1k-wl-block",
    })
    cfg["routing"]["rules"] = route_rules

elif role == "exit_node":
    c_file, k_file = cert_pair()
    fallback80_needed = True
    t_uuid = str(state.get("tunnel_uuid") or "").strip()
    if not t_uuid:
        t_uuid = str(uuid_lib.uuid4())
    extra_bridge = [{"id": t_uuid, "email": "eu-hub-bridge@just1k", "flow": "xtls-rprx-vision"}]
    cfg["inbounds"].append({
        "tag": "just1k-vless-direct",
        "listen": "0.0.0.0",
        "port": 443,
        "protocol": "vless",
        "settings": {
            "clients": merged_clients("just1k-vless-direct", vless_clients, "xtls-rprx-vision", extra_bridge),
            "decryption": "none",
            "fallbacks": [{"dest": "127.0.0.1:80"}],
        },
        "streamSettings": {
            "network": "tcp",
            "security": "tls",
            "tlsSettings": {
                "alpn": ["http/1.1"],
                "certificates": [{"certificateFile": c_file, "keyFile": k_file}],
            },
        },
        "sniffing": {"enabled": True, "destOverride": ["tls", "http", "quic"], "routeOnly": False},
    })
    cfg["outbounds"] = [
        {"tag": "direct", "protocol": "freedom", "streamSettings": {"sockopt": {"domainStrategy": "UseIPv4"}}},
        {"tag": "just1k-wl-block", "protocol": "blackhole", "settings": {}},
        {"tag": "just1k-wl-api", "protocol": "blackhole", "settings": {}},
    ]
    cfg["routing"]["rules"] = [api_rule] + antiabuse_rules() + [
        {"type": "field", "inboundTag": ["just1k-vless-direct"], "outboundTag": "direct"}
    ]

with open(out_xray_path, "w", encoding="utf-8") as xfp:
    json.dump(cfg, xfp, indent=2, ensure_ascii=False)

meta_out = {
    "nginx_needed": nginx_needed,
    "fallback80_needed": fallback80_needed,
    "map_needed": map_needed,
    "secret_base_path": secret_base,
}
print(json.dumps(meta_out))
PYEOF
    then
        rm -f "$tmp_xray" "$tmp_nginx" "$tmp_map" "$meta_tmp" 2>/dev/null || true
        return 1
    fi

    local nginx_needed="false" fallback80_needed="false" map_needed="false" resolved_secret=""
    read -r nginx_needed fallback80_needed map_needed resolved_secret < <(python3 -c "
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    m = json.load(f)
print(
    'true' if m.get('nginx_needed') else 'false',
    'true' if m.get('fallback80_needed') else 'false',
    'true' if m.get('map_needed') else 'false',
    m.get('secret_base_path', '')
)
" "$meta_tmp" 2>/dev/null || echo "false false false ")
    rm -f "$meta_tmp" 2>/dev/null || true

    if [[ -n "$resolved_secret" ]]; then
        set_state_val "secret_base_path" "$resolved_secret" 2>/dev/null || true
    fi

    ensure_xray_config_permissions "$tmp_xray"
    if ! "$XRAY_BIN" run -test -format json -config "$tmp_xray" >/dev/null 2>&1; then
        "$XRAY_BIN" run -test -format json -config "$tmp_xray" || true
        rm -f "$tmp_xray" "$tmp_nginx" "$tmp_map" 2>/dev/null || true
        warn "Ошибка валидации сгенерированной конфигурации Xray."
        return 1
    fi

    mv -f "$tmp_xray" "$cfg_file"
    ensure_xray_config_permissions "$cfg_file"

    install_nginx_if_missing
    mkdir -p "${nginx_dir}/sites-available" "${nginx_dir}/sites-enabled" "${nginx_dir}/conf.d"
    if [[ "$nginx_needed" == "true" ]]; then
        cp -f "$tmp_nginx" "${nginx_dir}/sites-available/just1k-origin.conf"
        chmod 644 "${nginx_dir}/sites-available/just1k-origin.conf" 2>/dev/null || true
        ln -sf "${nginx_dir}/sites-available/just1k-origin.conf" "${nginx_dir}/sites-enabled/just1k-origin.conf"
        rm -f "${nginx_dir}/sites-enabled/default" "${nginx_dir}/sites-enabled/just1k-fallback80.conf" 2>/dev/null || true
        if [[ "$map_needed" == "true" ]]; then
            cp -f "$tmp_map" "${nginx_dir}/conf.d/xhttp-map.conf"
            chmod 644 "${nginx_dir}/conf.d/xhttp-map.conf" 2>/dev/null || true
        else
            rm -f "${nginx_dir}/conf.d/xhttp-map.conf" 2>/dev/null || true
        fi
        sync_xhttp_upstreams_conf || true
    else
        rm -f "${nginx_dir}/sites-enabled/just1k-origin.conf" "${nginx_dir}/conf.d/xhttp-map.conf" "${nginx_dir}/conf.d/just1k-xhttp-upstreams.conf" 2>/dev/null || true
        if [[ "$fallback80_needed" == "true" ]]; then
            deploy_v2_fallback80_nginx
        else
            rm -f "${nginx_dir}/sites-enabled/just1k-fallback80.conf" 2>/dev/null || true
        fi
    fi
    rm -f "$tmp_nginx" "$tmp_map" 2>/dev/null || true

    # Обновление API Nginx (8444) на боевой сертификат домена
    setup_base_api_nginx || return 1
    return 0
}

# Применяет полную реконфигурацию роли v2 (Xray + Nginx + UFW + Anti-Abuse) с откатом при сбое
apply_v2_hub_configuration() {
    local role
    role="$(get_state_val "role" "unconfigured")"
    [[ "$role" == "ru_hub" || "$role" == "eu_hub" || "$role" == "exit_node" ]] || return 1

    apply_node_sysctl_hardening
    if ! assemble_v2_hub_config; then
        return 1
    fi

    if ! nginx -t >/dev/null 2>&1; then
        nginx -t || true
        warn "Ошибка синтаксиса Nginx при применении конфигурации роли ${role}."
        return 1
    fi

    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    deploy_xray_systemd_service

    if is_traffic_limit_exceeded; then
        warn "Лимит трафика исчерпан — запуск Xray пропущен (конфигурация обновлена)."
    else
        if ! systemctl restart xray || ! systemctl is-active --quiet xray; then
            warn "Не удалось перезапустить службу Xray с новой конфигурацией!"
            return 1
        fi
        ensure_xray_api_healthy 1 || warn "Служба xray-api не ответила вовремя."
    fi

    if [[ "$role" == "exit_node" || "$role" == "ru_hub" ]]; then
        apply_antiabuse_protection >/dev/null 2>&1 || true
    fi

    heal_node_firewall_and_stealth
    return 0
}

heal_v2_role_config() {
    local role
    role="$(get_state_val "role" "unconfigured")"
    if [[ "$role" != "ru_hub" && "$role" != "eu_hub" && "$role" != "exit_node" ]]; then
        return 0
    fi
    if ! apply_v2_hub_configuration; then
        warn "Авто-восстановление конфигурации для роли ${role} завершилось с предупреждением."
        return 1
    fi
    return 0
}

role_display_name() {
    local r="${1:-unconfigured}"
    case "$r" in
        ru_hub) echo "🇷🇺 РУ ХАБ" ;;
        eu_hub) echo "🌍 Зарубежный ХАБ" ;;
        exit_node) echo "🚀 Выходная НОДА" ;;
        origin) echo "🇷🇺 Origin (Legacy)" ;;
        node) echo "🌐 Модульный узел (Legacy)" ;;
        *) echo "⚪ Не выбрана" ;;
    esac
}

change_role_guarded() {
    check_root
    init_state_dir
    local mod_cnt
    mod_cnt="$(count_enabled_modules)"
    if [[ "${mod_cnt:-0}" -gt 0 ]]; then
        warn "Смена роли запрещена: установлено модулей — ${mod_cnt}."
        echo -e "  ${YELLOW}Удалите все модули перед сменой роли.${NC}"
        return 1
    fi

    local cur_role
    cur_role="$(get_state_val "role" "unconfigured")"
    if [[ "$cur_role" == "unconfigured" ]]; then
        select_role_wizard
        return $?
    fi

    local confirm=""
    read -rp "Сбросить текущую роль '$(role_display_name "$cur_role")' и выбрать новую? [y/N]: " confirm || true
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Смена роли отменена."
        return 0
    fi

    set_state_val "role" "unconfigured"
    set_state_val "has_vless" "0"
    set_state_val "has_relay" "0"
    set_state_val "has_wl" "0"
    set_state_json_val "peers" "[]"
    set_state_json_val "allowed_ru_ips" "[]"
    rm -f "${NGINX_CONF_DIR:-/etc/nginx}/sites-enabled/just1k-origin.conf" \
          "${NGINX_CONF_DIR:-/etc/nginx}/sites-enabled/just1k-fallback80.conf" \
          "${NGINX_CONF_DIR:-/etc/nginx}/conf.d/xhttp-map.conf" 2>/dev/null || true
    rm -f "${XRAY_CONFIG:-/usr/local/etc/xray/config.json}" 2>/dev/null || true
    ensure_xray_stub_config
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || true
        if ! is_traffic_limit_exceeded; then
            systemctl restart xray 2>/dev/null || true
        fi
    fi
    heal_node_firewall_and_stealth
    log "✔ Роль сброшена. Выберите новую роль сервера."
    select_role_wizard
    return $?
}

select_role_wizard() {
    check_root
    init_state_dir
    clear
    title "ВЫБОР РОЛИ СЕРВЕРА JUST1KNODE v2"
    echo -e "  ${BOLD}[1]${NC} 🇷🇺 ${BOLD}РУ ХАБ${NC}           — входной узел (VLESS TLS / VLESS XHTTP + CDN + мост на Зарубежный ХАБ)"
    echo -e "  ${BOLD}[2]${NC} 🌍 ${BOLD}Зарубежный ХАБ${NC}  — чистый транзитный мост (443 строго от РУ ХАБов -> Выходные НОДЫ)"
    echo -e "  ${BOLD}[3]${NC} 🚀 ${BOLD}Выходная НОДА${NC}   — финальный выход (443 -> Freedom + Anti-Abuse)"
    echo -e "  ${BOLD}[0]${NC} ⬅️  Назад"
    echo ""

    local r_choice new_role=""
    read -rp "Выберите роль [0-3]: " r_choice || true
    case "$r_choice" in
        1) new_role="ru_hub" ;;
        2) new_role="eu_hub" ;;
        3) new_role="exit_node" ;;
        0|"") return 0 ;;
        *) warn "Неверный выбор."; return 1 ;;
    esac

    local cur_dom input_dom=""
    cur_dom="$(get_state_val "domain" "")"
    [[ "$cur_dom" == "-" ]] && cur_dom=""
    while true; do
        if [[ -n "$cur_dom" ]]; then
            read -rp "Домен [Enter для '$cur_dom']: " input_dom || true
            input_dom="${input_dom:-$cur_dom}"
        else
            read -rp "Домен: " input_dom || true
        fi
        input_dom="$(normalize_domain "$input_dom" 2>/dev/null || echo "$input_dom")"
        if [[ -n "$input_dom" ]] && validate_fqdn "$input_dom" 2>/dev/null; then
            break
        fi
        warn "Введите корректное доменное имя (например, node1.example.com)."
    done

    echo ""
    echo -e "  Роль:  ${CYAN}$(role_display_name "$new_role")${NC}"
    echo -e "  Домен: ${CYAN}${input_dom}${NC}"
    echo -e "  SSL:   ${DIM:-}Автоматическое определение существующего сертификата или выпуск Let's Encrypt${NC}"
    echo ""
    local confirm=""
    read -rp "Подтвердите (y/n): " confirm || true
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Настройка роли отменена."
        return 0
    fi

    if ! ensure_domain_ssl_auto "$input_dom"; then
        warn "Не удалось автоматически получить SSL-сертификат для '${input_dom}'. Проверьте DNS и порт 80."
        return 1
    fi

    set_state_val "role" "$new_role"
    set_state_val "domain" "$input_dom"
    set_state_val "api_url" "https://${input_dom}:8444"
    set_state_json_val "modules" "{}"
    set_state_json_val "peers" "[]"

    if [[ "$new_role" == "eu_hub" || "$new_role" == "exit_node" ]]; then
        local t_uuid
        t_uuid="$(get_state_val "tunnel_uuid" "")"
        if [[ -z "$t_uuid" || "$t_uuid" == "-" ]]; then
            t_uuid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
            set_state_val "tunnel_uuid" "$t_uuid"
        fi
    fi

    if [[ "$new_role" == "ru_hub" ]]; then
        # На РУ ХАБе переходим сразу в меню установки транспортов ([1] VLESS TLS / [2] VLESS XHTTP)
        setup_base_api_nginx || true
        heal_node_firewall_and_stealth
        log "✔ Роль 'РУ ХАБ' активирована! Выберите транспортные модули."
        ru_hub_menu
    elif [[ "$new_role" == "eu_hub" ]]; then
        set_state_val "relay_port" "443"
        set_state_val "has_relay" "1"
        if ! apply_v2_hub_configuration; then
            warn "Ошибка активации Зарубежного ХАБа."
            return 1
        fi
        log "✔ Роль 'Зарубежный ХАБ' активирована!"
        eu_hub_menu
    elif [[ "$new_role" == "exit_node" ]]; then
        set_state_val "has_vless" "1"
        set_state_val "vless_domain" "$input_dom"
        if ! apply_v2_hub_configuration; then
            warn "Ошибка активации Выходной НОДы."
            return 1
        fi
        log "✔ Роль 'Выходная НОДА' активирована!"
        exit_node_menu
    fi
    return 0
}
