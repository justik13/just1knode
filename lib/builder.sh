#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE v2 - Единый сборщик Xray, Nginx HTTP/Stream и UFW для ролей v2
# =============================================================================

_nginx_has_stream_module() {
    command -v nginx >/dev/null 2>&1 || return 1
    if compgen -G "/etc/nginx/modules-enabled/*stream*.conf" >/dev/null 2>&1; then
        return 0
    fi
    if nginx -V 2>&1 | grep -qE -- '--with-stream([[:space:]]|=dynamic|$)'; then
        if ! nginx -V 2>&1 | grep -q -- '--with-stream=dynamic'; then
            return 0
        fi
    fi
    return 1
}

_sync_nginx_main_stream_include() {
    local enable_stream="$1" # true | false
    local nginx_dir="${NGINX_CONF_DIR:-/etc/nginx}"
    local main_conf="${nginx_dir}/nginx.conf"
    local stream_conf="${nginx_dir}/just1k-stream443.conf"
    [[ -f "$main_conf" ]] || return 0

    create_backup "$main_conf" 2>/dev/null || true
    python3 - "$main_conf" "$stream_conf" "$enable_stream" <<'PYEOF'
import os, re, sys, tempfile

main_conf, stream_conf, enable_str = sys.argv[1:4]
enable = enable_str == "true"

with open(main_conf, "r", encoding="utf-8", errors="replace") as f:
    text = f.read()

start_mark = "# JUST1KNODE STREAM443 START"
end_mark = "# JUST1KNODE STREAM443 END"
cleaned = re.sub(
    r"\n?# JUST1KNODE STREAM443 START.*?# JUST1KNODE STREAM443 END\n?",
    "\n",
    text,
    flags=re.DOTALL,
)

if enable:
    block = (
        f"\n{start_mark}\n"
        "stream {\n"
        f"    include {stream_conf};\n"
        "}\n"
        f"{end_mark}\n"
    )
    new_text = cleaned.rstrip() + "\n" + block
else:
    new_text = cleaned.rstrip() + "\n"

if new_text != text:
    d = os.path.dirname(os.path.abspath(main_conf))
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(new_text)
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

    local nginx_stream_avail="false"
    if _nginx_has_stream_module 2>/dev/null; then
        nginx_stream_avail="true"
    fi

    local tmp_xray tmp_nginx tmp_map tmp_stream meta_tmp
    tmp_xray="$(mktemp "${cfg_file}.tmp.XXXXXX" 2>/dev/null || mktemp)"
    tmp_nginx="$(mktemp "/tmp/just1k-origin.tmp.XXXXXX" 2>/dev/null || mktemp)"
    tmp_map="$(mktemp "/tmp/just1k-map.tmp.XXXXXX" 2>/dev/null || mktemp)"
    tmp_stream="$(mktemp "/tmp/just1k-stream.tmp.XXXXXX" 2>/dev/null || mktemp)"
    meta_tmp="$(mktemp "/tmp/just1k-meta.tmp.XXXXXX" 2>/dev/null || mktemp)"

    if ! python3 - \
        "$state_file" "$clients_file" "$links_file" \
        "$cfg_file" "$tmp_xray" "$tmp_nginx" "$tmp_map" "$tmp_stream" \
        "$xray_tls_dir" "$le_dir" "$cdn_specs_json" \
        "$broken_csv" "$nginx_stream_avail" > "$meta_tmp" <<'PYEOF'
import ipaddress
import json
import os
import re
import secrets
import sys
import uuid as uuid_lib

(
    state_path,
    clients_path,
    links_path,
    cur_cfg_path,
    out_xray_path,
    out_nginx_path,
    out_map_path,
    out_stream_path,
    xray_tls_dir,
    le_dir,
    cdn_specs_raw,
    broken_csv,
    nginx_stream_avail_str,
) = sys.argv[1:14]

nginx_stream_avail = nginx_stream_avail_str == "true"
broken_modules = {x.strip() for x in broken_csv.split(",") if x.strip()}

try:
    CDN_PROVIDER_SPECS = json.loads(cdn_specs_raw)
    if not isinstance(CDN_PROVIDER_SPECS, dict):
        CDN_PROVIDER_SPECS = {}
except Exception:
    CDN_PROVIDER_SPECS = {}

def load_json(path, default):
    if path and os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fp:
                return json.load(fp)
        except Exception:
            pass
    return default

def is_valid_ipv4(val):
    try:
        ipaddress.IPv4Address(str(val).strip())
        return True
    except Exception:
        return False

def is_valid_fqdn(val):
    s = str(val or "").strip().lower().rstrip(".")
    if not s or len(s) > 253 or is_valid_ipv4(s):
        return False
    if not re.fullmatch(r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}", s):
        return False
    return True

def is_valid_uuid(val):
    try:
        uuid_lib.UUID(str(val or "").strip())
        return True
    except Exception:
        return False

def clean_code(val, fallback):
    c = re.sub(r"[^a-z0-9_-]", "", str(val or "").strip().lower())
    return c or fallback

state = load_json(state_path, {})
if not isinstance(state, dict):
    state = {}

links = load_json(links_path, {})
if not isinstance(links, dict):
    links = {}

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

def mod_on(name):
    if name in broken_modules:
        return False
    m = modules.get(name)
    return isinstance(m, dict) and m.get("enabled") is True

# Сохраняем действующих клиентов из clients.json и текущего config.json (только для ru_hub).
# ClientStore хранит структуру {"clients": {uuid: meta}, ...}; исключаем отозванных/disabled.
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
revoked_vless = set()
revoked_wl = set()

raw_clients_entries = {}
if isinstance(clients_db, dict):
    inner_clients = clients_db.get("clients")
    if isinstance(inner_clients, dict):
        raw_clients_entries = inner_clients
    elif isinstance(inner_clients, list):
        raw_clients_entries = {str(u): {"is_active": True} for u in inner_clients if isinstance(u, str)}
    elif "clients" not in clients_db:
        raw_clients_entries = clients_db
elif isinstance(clients_db, list):
    raw_clients_entries = {str(u): {"is_active": True} for u in clients_db if isinstance(u, str)}

for cid, meta in raw_clients_entries.items():
    if not isinstance(meta, dict):
        continue
    email = str(meta.get("email") or cid)
    top_tombstone = bool(meta.get("tombstone", False))
    ss = meta.get("service_states") if isinstance(meta.get("service_states"), dict) else {}
    if ss:
        st_v = ss.get("vless")
        if isinstance(st_v, dict):
            if st_v.get("is_active") and not st_v.get("tombstone") and not top_tombstone:
                vless_clients[cid] = {"id": cid, "email": email, "flow": "xtls-rprx-vision"}
            else:
                revoked_vless.add(cid)
        st_w = ss.get("white_internet")
        if isinstance(st_w, dict):
            if st_w.get("is_active") and not st_w.get("tombstone") and not top_tombstone:
                wl_clients[cid] = {"id": cid, "email": email}
            else:
                revoked_wl.add(cid)
    else:
        svcs = meta.get("services") or ([meta.get("service")] if meta.get("service") else [])
        is_ok = bool(meta.get("is_active", True)) and not top_tombstone
        if is_ok:
            if "vless" in svcs:
                vless_clients[cid] = {"id": cid, "email": email, "flow": "xtls-rprx-vision"}
            if "white_internet" in svcs:
                wl_clients[cid] = {"id": cid, "email": email}
        else:
            if not svcs or "vless" in svcs:
                revoked_vless.add(cid)
            if not svcs or "white_internet" in svcs:
                revoked_wl.add(cid)

def merged_clients(tag, primary_map, flow_val="", revoked_set=None):
    revoked = revoked_set or set()
    merged = {}
    for c in existing_clients_by_tag.get(tag, []):
        if isinstance(c, dict) and c.get("id") and c["id"] not in revoked:
            item = {"id": c["id"], "email": c.get("email") or c["id"]}
            if flow_val:
                item["flow"] = flow_val
            merged[c["id"]] = item
    for cid, c in primary_map.items():
        if cid in revoked:
            continue
        item = dict(c)
        if flow_val:
            item["flow"] = flow_val
        merged[cid] = item
    return list(merged.values())

def cert_pair(target_dom=None):
    t_dom = (target_dom or domain or "").strip().lower().lstrip("*.")
    candidates = []
    if t_dom:
        candidates.append(t_dom)
        parts = t_dom.split(".")
        for i in range(1, max(1, len(parts) - 1)):
            parent_zone = ".".join(parts[i:])
            if "." in parent_zone:
                candidates.append(parent_zone)
    for cand in candidates:
        le_pem = os.path.join(le_dir, "live", cand, "fullchain.pem")
        le_key = os.path.join(le_dir, "live", cand, "privkey.pem")
        if os.path.exists(le_pem) and os.path.exists(le_key):
            return le_pem, le_key
    pem = os.path.join(xray_tls_dir, "fullchain.pem")
    key = os.path.join(xray_tls_dir, "privkey.pem")
    return pem, key

def build_tls_settings(c_file, k_file, target_dom=None):
    certificates = [{"certificateFile": c_file, "keyFile": k_file}]
    if target_dom and target_dom != domain:
        dc, dk = cert_pair(domain)
        if (dc, dk) != (c_file, k_file) and os.path.exists(dc) and os.path.exists(dk):
            certificates.append({"certificateFile": dc, "keyFile": dk})
    return {
        "rejectUnknownSni": True,
        "minVersion": "1.2",
        "alpn": ["http/1.1"],
        "certificates": certificates,
    }

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
            "sockopt": {"trustedXForwardedFor": ["X-Forwarded-For"]},
            "xhttpSettings": xs,
        },
        "sniffing": {
            "enabled": True,
            "destOverride": ["tls", "http", "quic"],
            "routeOnly": False,
        },
    }

def build_bridge_outbound(ob_tag, peer):
    ip = str(peer.get("ip") or "").strip()
    uid = str(peer.get("uuid") or "").strip()
    sni = str(peer.get("sni") or "").strip()
    port = int(peer.get("port") or 443)
    if not is_valid_ipv4(ip) or not is_valid_uuid(uid) or not is_valid_fqdn(sni):
        return None
    return {
        "tag": ob_tag,
        "protocol": "vless",
        "settings": {
            "vnext": [{
                "address": ip,
                "port": port,
                "users": [{
                    "id": uid,
                    "encryption": "none",
                    "flow": "xtls-rprx-vision",
                }],
            }]
        },
        "streamSettings": {
            "network": "tcp",
            "security": "tls",
            "tlsSettings": {
                "serverName": sni,
                "fingerprint": "firefox",
                "alpn": ["http/1.1"],
                "allowInsecure": False,
            },
        },
    }

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
stream_needed = False

api_rule = {"type": "field", "inboundTag": ["just1k-wl-api-grpc"], "outboundTag": "just1k-wl-api"}

if role == "ru_hub":
    has_vless_tls = mod_on("vless_tls")
    has_xhttp = mod_on("vless_xhttp")
    active_cdns = [k for k in CDN_PROVIDER_SPECS if mod_on(k)] if has_xhttp else []

    # Раздельное извлечение мостов Стандарт vs БИ (links.json v2 + локальный резерв peers)
    std_cfg = links.get("standard") if isinstance(links.get("standard"), dict) else {}
    bi_cfg = links.get("bi") if isinstance(links.get("bi"), dict) else {}
    shared_bridges = [
        p for p in (links.get("bridges") if isinstance(links.get("bridges"), list) else peers)
        if isinstance(p, dict) and p.get("ip") and p.get("uuid")
    ]
    std_bridges_raw = std_cfg.get("bridges") if isinstance(std_cfg.get("bridges"), list) else []
    bi_bridges_raw = bi_cfg.get("bridges") if isinstance(bi_cfg.get("bridges"), list) else []
    if not std_bridges_raw and shared_bridges:
        std_bridges_raw = shared_bridges
    if not bi_bridges_raw and shared_bridges:
        bi_bridges_raw = shared_bridges

    sni_routes_raw = std_cfg.get("sni_routes") if isinstance(std_cfg.get("sni_routes"), list) else []
    valid_sni_routes = []
    if has_vless_tls and nginx_stream_avail:
        seen_sni = set()
        for r in sni_routes_raw:
            if not isinstance(r, dict):
                continue
            r_sni = str(r.get("sni") or "").strip().lower().rstrip(".")
            b_code = clean_code(r.get("bridge_code") or r.get("code"), "")
            if is_valid_fqdn(r_sni) and b_code and r_sni not in seen_sni:
                seen_sni.add(r_sni)
                valid_sni_routes.append({"sni": r_sni, "bridge_code": b_code})

    stream_needed = has_vless_tls and len(valid_sni_routes) > 0

    std_inbounds = []
    bi_inbounds = []

    if has_vless_tls:
        c_file, k_file = cert_pair(domain)
        fb_dest = "127.0.0.1:8080" if has_xhttp else "127.0.0.1:80"
        if not has_xhttp:
            fallback80_needed = True

        tls_listen = "127.0.0.1" if stream_needed else "0.0.0.0"
        tls_port = 8445 if stream_needed else 443
        ss_tls = {
            "network": "tcp",
            "security": "tls",
            "tlsSettings": build_tls_settings(c_file, k_file, domain),
        }
        if stream_needed:
            ss_tls["sockopt"] = {"acceptProxyProtocol": True}

        cfg["inbounds"].append({
            "tag": "just1k-vless-direct",
            "listen": tls_listen,
            "port": tls_port,
            "protocol": "vless",
            "settings": {
                "clients": merged_clients("just1k-vless-direct", vless_clients, "xtls-rprx-vision", revoked_vless),
                "decryption": "none",
                "fallbacks": [{"dest": fb_dest}],
            },
            "streamSettings": ss_tls,
            "sniffing": {"enabled": True, "destOverride": ["tls", "http", "quic"], "routeOnly": False},
        })
        std_inbounds.append("just1k-vless-direct")

    # CDN XHTTP инбаунды (БИ)
    for cdn_key in active_cdns:
        spec = CDN_PROVIDER_SPECS[cdn_key]
        mod_cfg = modules.get(cdn_key, {})
        c_port = int(mod_cfg.get("port") or spec["port"])
        c_tag = str(mod_cfg.get("tag") or spec["tag"])
        c_path = str(mod_cfg.get("path") or f"{secret_base}/{spec['subpath']}")
        spec_eff = dict(spec)
        if mod_cfg.get("xPaddingPlacement"):
            spec_eff["xPaddingPlacement"] = str(mod_cfg["xPaddingPlacement"])
        cfg["inbounds"].append(
            build_xhttp_inbound(c_tag, c_port, c_path, spec_eff, merged_clients(c_tag, wl_clients, "", revoked_wl))
        )
        bi_inbounds.append(c_tag)

    # Локационные XHTTP инбаунды (БИ per-location paths из links.json v2)
    seen_loc_codes = set()
    loc_sources = []
    if isinstance(bi_cfg.get("locations"), list):
        loc_sources.extend(bi_cfg["locations"])
    loc_sources.extend([p for p in bi_bridges_raw if isinstance(p, dict) and p.get("code")])

    base_cdn_spec = CDN_PROVIDER_SPECS[active_cdns[0]] if active_cdns else None
    used_ports = {ib.get("port") for ib in cfg["inbounds"] if ib.get("port")}
    next_port = 8005
    location_nginx_routes = []
    for loc in loc_sources:
        if not isinstance(loc, dict):
            continue
        code = clean_code(loc.get("code"), "")
        if not code or code in seen_loc_codes:
            continue
        seen_loc_codes.add(code)
        r_tag = f"just1k-wl-inbound-{code}"
        r_port = int(loc.get("inbound_port") or 0)
        if not r_port or r_port in used_ports:
            while next_port in used_ports:
                next_port += 1
            r_port = next_port
        used_ports.add(r_port)
        r_path = str(loc.get("path") or f"{secret_base}/{code}")
        if base_cdn_spec is not None:
            cfg["inbounds"].append(
                build_xhttp_inbound(r_tag, r_port, r_path, base_cdn_spec, merged_clients(r_tag, wl_clients, "", revoked_wl))
            )
            bi_inbounds.append(r_tag)
            location_nginx_routes.append((r_path, f"xray_xhttp_relay_{code}", base_cdn_spec))

    # DNS и выход в Рунет (ТОЛЬКО для RU-сегмента!)
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

    # Outbounds для Стандарта (std_bridges)
    std_outbounds = {}
    std_default_tag = None
    for idx, p in enumerate(std_bridges_raw):
        if not isinstance(p, dict):
            continue
        p_code = clean_code(p.get("code"), f"hub{idx+1}")
        ob_tag = f"bridge-std-{p_code}"
        if p_code in std_outbounds:
            continue
        ob = build_bridge_outbound(ob_tag, p)
        if ob is None:
            continue
        std_outbounds[p_code] = ob_tag
        cfg["outbounds"].append(ob)
        if not std_default_tag or p.get("is_default"):
            std_default_tag = ob_tag

    # Outbounds для БИ (bi_bridges)
    bi_outbounds = {}
    bi_default_tag = None
    for idx, p in enumerate(bi_bridges_raw):
        if not isinstance(p, dict):
            continue
        p_code = clean_code(p.get("code"), f"hub{idx+1}")
        ob_tag = f"bridge-bi-{p_code}"
        if p_code in bi_outbounds:
            continue
        ob = build_bridge_outbound(ob_tag, p)
        if ob is None:
            continue
        bi_outbounds[p_code] = ob_tag
        cfg["outbounds"].append(ob)
        if not bi_default_tag or p.get("is_default"):
            bi_default_tag = ob_tag

    cfg["outbounds"].extend([
        {"tag": "just1k-wl-block", "protocol": "blackhole", "settings": {}},
        {"tag": "just1k-wl-api", "protocol": "blackhole", "settings": {}},
    ])

    all_client_inbounds = list(dict.fromkeys(std_inbounds + bi_inbounds))
    ru_domains = [
        "geosite:category-ru", "geosite:tld-ru",
        "domain:ru", "domain:su", "domain:xn--p1ai", "domain:2ip.ru",
    ]
    rules = [api_rule] + antiabuse_rules()
    if all_client_inbounds:
        rules.extend([
            {"type": "field", "inboundTag": all_client_inbounds, "domain": ru_domains, "outboundTag": "just1k-wl-direct"},
            {"type": "field", "inboundTag": all_client_inbounds, "ip": ["geoip:ru"], "outboundTag": "just1k-wl-direct"},
        ])

    # Пер-SNI маршруты Стандарта (если включён nginx stream ssl_preread)
    stream_map_entries = []
    stream_upstream_blocks = []
    if stream_needed:
        route_port_base = 8450
        for r_idx, rt in enumerate(valid_sni_routes):
            b_code = rt["bridge_code"]
            if b_code not in std_outbounds:
                continue
            r_sni = rt["sni"]
            r_port = route_port_base + r_idx
            while r_port in used_ports:
                r_port += 1
            used_ports.add(r_port)
            r_tag = f"just1k-vless-route-{r_idx}-{b_code}"
            rc_file, rk_file = cert_pair(r_sni)
            cfg["inbounds"].append({
                "tag": r_tag,
                "listen": "127.0.0.1",
                "port": r_port,
                "protocol": "vless",
                "settings": {
                    "clients": merged_clients("just1k-vless-direct", vless_clients, "xtls-rprx-vision", revoked_vless),
                    "decryption": "none",
                    "fallbacks": [{"dest": "127.0.0.1:8080" if has_xhttp else "127.0.0.1:80"}],
                },
                "streamSettings": {
                    "network": "tcp",
                    "security": "tls",
                    "sockopt": {"acceptProxyProtocol": True},
                    "tlsSettings": build_tls_settings(rc_file, rk_file, r_sni),
                },
                "sniffing": {"enabled": True, "destOverride": ["tls", "http", "quic"], "routeOnly": False},
            })
            rules.append({"type": "field", "inboundTag": [r_tag], "outboundTag": std_outbounds[b_code]})
            stream_map_entries.append(f"    {r_sni} just1k_sni_route_{r_idx};")
            stream_upstream_blocks.append(
                f"upstream just1k_sni_route_{r_idx} {{\n    server 127.0.0.1:{r_port};\n}}"
            )

        stream_text = (
            "map $ssl_preread_server_name $just1k_sni_backend {\n"
            + "\n".join(stream_map_entries) + "\n"
            + "    default just1k_sni_default;\n"
            + "}\n\n"
            + "upstream just1k_sni_default {\n"
            + "    server 127.0.0.1:8445;\n"
            + "}\n\n"
            + "\n\n".join(stream_upstream_blocks) + "\n\n"
            + "server {\n"
            + "    listen 443 reuseport;\n"
            + "    ssl_preread on;\n"
            + "    proxy_protocol on;\n"
            + "    proxy_pass $just1k_sni_backend;\n"
            + "}\n"
        )
        with open(out_stream_path, "w", encoding="utf-8") as sfp:
            sfp.write(stream_text)

    # Локационные БИ-правила (inbound-<code> -> bridge-bi-<code>)
    existing_ib_tags = {ib.get("tag") for ib in cfg["inbounds"]}
    for b_code, ob_tag in bi_outbounds.items():
        loc_ib = f"just1k-wl-inbound-{b_code}"
        if loc_ib in existing_ib_tags:
            rules.append({"type": "field", "inboundTag": [loc_ib], "outboundTag": ob_tag})

    # Zero-Trust Fallback: иностранный трафик без моста ИДЁТ В BLACKHOLE, НИКОГДА НЕ В DIRECT!
    if std_inbounds:
        rules.append({
            "type": "field",
            "inboundTag": std_inbounds,
            "outboundTag": std_default_tag or "just1k-wl-block",
        })
    if bi_inbounds:
        rules.append({
            "type": "field",
            "inboundTag": bi_inbounds,
            "outboundTag": bi_default_tag or "just1k-wl-block",
        })

    cfg["routing"]["rules"] = rules

    # Nginx HTTP конфигурация для XHTTP / /sub/ на ru_hub
    if has_xhttp:
        nginx_needed = True
        c_file, k_file = cert_pair(domain)
        listen_block = (
            "    listen 127.0.0.1:8080 default_server;\n"
            if has_vless_tls else
            f"    listen 443 ssl http2 default_server;\n"
            f"    ssl_certificate {c_file};\n"
            f"    ssl_certificate_key {k_file};\n"
            "    ssl_protocols TLSv1.2 TLSv1.3;\n"
            "    ssl_ciphers HIGH:!aNULL:!MD5;\n"
        )
        cidr_lines = []
        seen_cidr = set()
        use_xff = False
        use_xri = False
        for ck in active_cdns:
            sp = CDN_PROVIDER_SPECS[ck]
            if sp.get("options_rewrite"):
                map_needed = True
            if sp.get("real_ip_header") == "X-Forwarded-For":
                use_xff = True
            else:
                use_xri = True
            for cidr in sp.get("cidrs", []):
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
        def make_xhttp_loc(c_path_raw, upstream_name, sp):
            cp = c_path_raw.rstrip("/")
            opt_line = "        proxy_method $xhttp_proxy_method;\n" if sp.get("options_rewrite") else ""
            return (
                f"    location ^~ {cp} {{\n"
                f"        rewrite ^{re.escape(cp)}/?$ {cp}/ break;\n"
                f"        proxy_pass http://{upstream_name};\n"
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
                '        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;\n'
                '        add_header X-Content-Type-Options "nosniff" always;\n'
                '        add_header Cache-Control "no-store, no-cache" always;\n'
                '        add_header CDN-Cache-Control "no-store" always;\n'
                '        add_header Pragma "no-cache" always;\n'
                '        add_header Expires "0" always;\n'
                '        add_header X-Accel-Buffering no always;\n'
                '        add_header Accept-Ranges none always;\n'
                "    }\n"
            )

        seen_loc_paths = set()
        for ck in active_cdns:
            sp = CDN_PROVIDER_SPECS[ck]
            m_cfg = modules.get(ck, {})
            c_path = str(m_cfg.get("path") or f"{secret_base}/{sp['subpath']}").rstrip("/")
            seen_loc_paths.add(c_path)
            loc_blocks.append(make_xhttp_loc(c_path, sp["upstream"], sp))
        for r_path, r_upstream, r_sp in location_nginx_routes:
            cp = str(r_path).rstrip("/")
            if cp and cp not in seen_loc_paths:
                seen_loc_paths.add(cp)
                loc_blocks.append(make_xhttp_loc(cp, r_upstream, r_sp))
        loc_blocks.append(
            "    location = /cdn-check {\n"
            "        add_header Content-Type text/plain;\n"
            "        return 204;\n"
            "    }\n"
        )
        cdn_doms = [str(state.get("cdn_domain") or "").strip()]
        for ck in active_cdns:
            m_cfg = modules.get(ck, {})
            if isinstance(m_cfg, dict):
                cdn_doms.append(str(m_cfg.get("cdn_domain") or m_cfg.get("domain") or "").strip())
        srv_names = " ".join([x for x in dict.fromkeys([domain] + cdn_doms + ["_"]) if x and x != "-"])
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
    c_file, k_file = cert_pair(domain)
    fallback80_needed = True
    t_uuid = str(state.get("tunnel_uuid") or "").strip()
    if not is_valid_uuid(t_uuid):
        t_uuid = str(uuid_lib.uuid4())
    relay_port = int(state.get("relay_port") or 443)

    in_clients_map = {}
    def add_hub_client(uid, email):
        if is_valid_uuid(uid) and uid not in in_clients_map:
            in_clients_map[uid] = {"id": uid, "email": email, "flow": "xtls-rprx-vision"}

    add_hub_client(t_uuid, "ru-hub@just1k")
    for item in (links.get("incoming_ru_hubs") or []):
        if isinstance(item, dict):
            u = str(item.get("uuid") or item.get("ingress_uuid") or "").strip()
            em = str(item.get("route_user") or item.get("email") or f"ingress-{clean_code(item.get('code'), 'ru')}@just1k")
            add_hub_client(u, em)
    for item in (links.get("routes") or []):
        if isinstance(item, dict) and item.get("ingress_uuid"):
            em = str(item.get("route_user") or f"ingress-{clean_code(item.get('code'), 'rt')}@just1k")
            add_hub_client(str(item["ingress_uuid"]).strip(), em)
    for p in peers:
        if isinstance(p, dict) and p.get("ingress_uuid"):
            c_code = clean_code(p.get("code"), "ru")
            add_hub_client(str(p["ingress_uuid"]).strip(), str(p.get("route_user") or f"ingress-{c_code}@just1k"))

    cfg["inbounds"].append({
        "tag": "inbound-tls",
        "listen": "0.0.0.0",
        "port": relay_port,
        "protocol": "vless",
        "settings": {
            "clients": list(in_clients_map.values()),
            "decryption": "none",
            "fallbacks": [{"dest": "127.0.0.1:80"}],
        },
        "streamSettings": {
            "network": "tcp",
            "security": "tls",
            "tlsSettings": build_tls_settings(c_file, k_file, domain),
        },
        "sniffing": {"enabled": True, "destOverride": ["tls", "http", "quic"], "routeOnly": False},
    })

    # СТРОГО без freedom: только выходы на Выходные НОДЫ + blackhole
    exit_sources = links.get("exit_nodes") if isinstance(links.get("exit_nodes"), list) else []
    if peers:
        exit_sources = list(exit_sources) + [p for p in peers if isinstance(p, dict) and p.get("ip") and p.get("uuid")]

    primary_exit_tag = None
    route_rules = [api_rule] + antiabuse_rules()
    seen_exits = {}
    for idx, p in enumerate(exit_sources):
        if not isinstance(p, dict):
            continue
        p_code = clean_code(p.get("code"), f"exit{idx+1}")
        ob_tag = f"exit-{p_code}"
        if ob_tag in seen_exits:
            ob_tag = f"exit-{p_code}-{idx+1}"
        ob = build_bridge_outbound(ob_tag, p)
        if ob is None:
            continue
        seen_exits[ob_tag] = ob
        cfg["outbounds"].append(ob)
        if not primary_exit_tag or p.get("is_default"):
            primary_exit_tag = ob_tag
        if p.get("route_user"):
            route_rules.append({
                "type": "field",
                "user": [str(p["route_user"])],
                "outboundTag": ob_tag,
            })

    for rt in (links.get("routes") or []):
        if isinstance(rt, dict) and rt.get("route_user") and rt.get("exit_code"):
            target_tag = f"exit-{clean_code(rt['exit_code'], '')}"
            if target_tag in seen_exits:
                route_rules.append({
                    "type": "field",
                    "user": [str(rt["route_user"])],
                    "outboundTag": target_tag,
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
    c_file, k_file = cert_pair(domain)
    fallback80_needed = True
    t_uuid = str(state.get("tunnel_uuid") or "").strip()
    if not is_valid_uuid(t_uuid):
        t_uuid = str(uuid_lib.uuid4())

    # СТРОГО ТОЛЬКО bridge UUID от хабов — НИКАКИХ пользовательских vless_clients на выходной ноде!
    bridge_clients = {}
    def add_exit_bridge(uid, email):
        if is_valid_uuid(uid) and uid not in bridge_clients:
            bridge_clients[uid] = {"id": uid, "email": email, "flow": "xtls-rprx-vision"}

    add_exit_bridge(t_uuid, "hub-bridge@just1k")
    for arr_k in ("incoming_hubs", "incoming_eu_hubs", "allowed_hubs"):
        for item in (links.get(arr_k) or []):
            if isinstance(item, dict):
                uid = str(item.get("uuid") or item.get("bridge_uuid") or "").strip()
                em = str(item.get("email") or f"hub-{clean_code(item.get('code'), 'eu')}@just1k")
                add_exit_bridge(uid, em)
            elif isinstance(item, str):
                add_exit_bridge(item.strip(), f"hub-{item.strip()[:8]}@just1k")

    cfg["inbounds"].append({
        "tag": "just1k-vless-direct",
        "listen": "0.0.0.0",
        "port": 443,
        "protocol": "vless",
        "settings": {
            "clients": list(bridge_clients.values()),
            "decryption": "none",
            "fallbacks": [{"dest": "127.0.0.1:80"}],
        },
        "streamSettings": {
            "network": "tcp",
            "security": "tls",
            "tlsSettings": build_tls_settings(c_file, k_file, domain),
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

print(json.dumps({
    "nginx_needed": nginx_needed,
    "fallback80_needed": fallback80_needed,
    "map_needed": map_needed,
    "stream_needed": stream_needed,
    "secret_base_path": secret_base,
}))
PYEOF
    then
        rm -f "$tmp_xray" "$tmp_nginx" "$tmp_map" "$tmp_stream" "$meta_tmp" 2>/dev/null || true
        return 1
    fi

    local nginx_needed="false" fallback80_needed="false" map_needed="false" stream_needed="false" resolved_secret=""
    read -r nginx_needed fallback80_needed map_needed stream_needed resolved_secret < <(python3 -c "
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    m = json.load(f)
print(
    'true' if m.get('nginx_needed') else 'false',
    'true' if m.get('fallback80_needed') else 'false',
    'true' if m.get('map_needed') else 'false',
    'true' if m.get('stream_needed') else 'false',
    m.get('secret_base_path', '')
)
" "$meta_tmp" 2>/dev/null || echo "false false false false ")
    rm -f "$meta_tmp" 2>/dev/null || true

    if [[ -n "$resolved_secret" ]]; then
        set_state_val "secret_base_path" "$resolved_secret" 2>/dev/null || true
    fi

    ensure_xray_config_permissions "$tmp_xray"
    if ! "$XRAY_BIN" run -test -format json -config "$tmp_xray" >/dev/null 2>&1; then
        "$XRAY_BIN" run -test -format json -config "$tmp_xray" || true
        rm -f "$tmp_xray" "$tmp_nginx" "$tmp_map" "$tmp_stream" 2>/dev/null || true
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

    if [[ "$stream_needed" == "true" ]]; then
        cp -f "$tmp_stream" "${nginx_dir}/just1k-stream443.conf"
        chmod 644 "${nginx_dir}/just1k-stream443.conf" 2>/dev/null || true
        _sync_nginx_main_stream_include "true"
    else
        _sync_nginx_main_stream_include "false"
        rm -f "${nginx_dir}/just1k-stream443.conf" 2>/dev/null || true
    fi
    rm -f "$tmp_nginx" "$tmp_map" "$tmp_stream" 2>/dev/null || true

    setup_base_api_nginx || return 1
    return 0
}
