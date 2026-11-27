#!/usr/bin/env python3
"""Unified Xray & Nginx configuration builder for Just1kNode v2.

Extracted from lib/builder.sh for modularity, clean error reporting, and testability.
"""

import ipaddress
import json
import os
import re
import secrets
import sys
import uuid as uuid_lib

try:
    import fcntl
except ImportError:
    fcntl = None


def load_json(path, default, fail_closed=False):
    if not path or not os.path.exists(path):
        return default
    lock_file = path + ".lock"
    lock_fd = None
    try:
        if fcntl is not None:
            flags = os.O_CREAT | os.O_WRONLY | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0)
            fd = os.open(lock_file, flags, 0o600)
            lock_fd = os.fdopen(fd, "a", encoding="utf-8")
            fcntl.flock(lock_fd.fileno(), fcntl.LOCK_SH)
        with open(path, "r", encoding="utf-8", errors="replace") as fp:
            return json.load(fp)
    except Exception as exc:
        if fail_closed:
            sys.stderr.write(f"ERROR: failed to read {path}: {exc}\n")
            sys.exit(1)
        return default
    finally:
        if lock_fd:
            try:
                fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)
            except Exception:
                pass
            finally:
                try:
                    lock_fd.close()
                except Exception:
                    pass


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


_SAFE_NGINX_PATH_RE = re.compile(r"^/[A-Za-z0-9._/~-]+$")


def is_valid_nginx_path(val):
    if not isinstance(val, str) or not val or len(val) > 256:
        return False
    if not val.startswith("/") or ".." in val:
        return False
    if not _SAFE_NGINX_PATH_RE.fullmatch(val):
        return False
    if not val.rstrip("/"):
        return False
    return True


def main():
    if len(sys.argv) < 13:
        sys.stderr.write(
            "Usage: config_builder.py <state_path> <clients_path> <unused> <links_path> "
            "<cur_cfg_path> <out_xray_path> <out_nginx_path> <xray_tls_dir> <le_dir> "
            "<cdn_specs_raw> <broken_csv> <ssl_reject_avail>\n"
        )
        sys.exit(1)

    (
        state_path,
        clients_path,
        _unused_arg,
        links_path,
        _cur_cfg_path,
        out_xray_path,
        out_nginx_path,
        xray_tls_dir,
        le_dir,
        cdn_specs_raw,
        broken_csv,
        ssl_reject_avail_str,
    ) = sys.argv[1:13]

    ssl_reject_avail = ssl_reject_avail_str == "true"
    broken_modules = {x.strip() for x in broken_csv.split(",") if x.strip()}

    try:
        cdn_provider_specs = json.loads(cdn_specs_raw)
        if not isinstance(cdn_provider_specs, dict):
            cdn_provider_specs = {}
    except Exception:
        cdn_provider_specs = {}

    state = load_json(state_path, {}, fail_closed=True)
    if not isinstance(state, dict):
        state = {}

    links = load_json(links_path, {}, fail_closed=True)
    if not isinstance(links, dict):
        links = {}

    role = str(state.get("role", "unconfigured")).strip().lower()
    domain = str(state.get("domain", "")).strip()
    raw_bot_domain = str(state.get("bot_domain", "")).strip()
    bot_domain = raw_bot_domain if raw_bot_domain and raw_bot_domain != "-" and is_valid_fqdn(raw_bot_domain) else ""
    sub_prefix = str(state.get("sub_path_prefix") or "/sub/wl").strip().rstrip("/") or "/sub/wl"
    if not sub_prefix.startswith("/"):
        sub_prefix = "/" + sub_prefix

    secret_base = str(state.get("secret_base_path") or "").strip().rstrip("/")
    if not secret_base or secret_base in ("/", "/none"):
        secret_base = "/assets_" + secrets.token_hex(4)
    elif not secret_base.startswith("/"):
        secret_base = "/" + secret_base

    modules = state.get("modules") if isinstance(state.get("modules"), dict) else {}

    def mod_on(name):
        if name in broken_modules:
            return False
        m = modules.get(name)
        return isinstance(m, dict) and m.get("enabled") is True

    # Единственный локальный источник клиентов — clients.json (без воскрешения удалённых из cur_cfg).
    # ClientStore хранит структуру {"clients": {uuid: meta}, ...}; исключаем отозванных/disabled.
    clients_db = load_json(clients_path, {}, fail_closed=True)
    vless_clients = {}
    wl_clients = {}
    revoked_vless = set()
    revoked_wl = set()

    raw_clients_entries = {}
    if isinstance(clients_db, dict) and isinstance(clients_db.get("clients"), dict):
        raw_clients_entries = clients_db["clients"]

    for cid, meta in raw_clients_entries.items():
        if not isinstance(meta, dict):
            continue
        top_tombstone = bool(meta.get("tombstone", False))
        ss = meta.get("service_states") if isinstance(meta.get("service_states"), dict) else {}
        svc_emails = meta.get("service_emails") if isinstance(meta.get("service_emails"), dict) else {}
        st_v = ss.get("vless")
        if isinstance(st_v, dict):
            if st_v.get("is_active") and not st_v.get("tombstone") and not top_tombstone:
                cand_v = st_v.get("email") or svc_emails.get("vless") or meta.get("email")
                cand_v_str = str(cand_v).strip() if cand_v else ""
                if (
                    cand_v_str
                    and (":" in cand_v_str or "@" in cand_v_str)
                    and not cand_v_str.endswith(":wi")
                ):
                    email_val = cand_v_str
                else:
                    email_val = f"{cid}:std"
                vless_clients[cid] = {"id": cid, "email": email_val, "flow": "xtls-rprx-vision"}
            else:
                revoked_vless.add(cid)
        st_w = ss.get("white_internet")
        if isinstance(st_w, dict):
            if st_w.get("is_active") and not st_w.get("tombstone") and not top_tombstone:
                cand_w = st_w.get("email") or svc_emails.get("white_internet") or meta.get("email")
                cand_w_str = str(cand_w).strip() if cand_w else ""
                if (
                    cand_w_str
                    and (":" in cand_w_str or "@" in cand_w_str)
                    and not cand_w_str.endswith(":std")
                ):
                    w_email_val = cand_w_str
                else:
                    w_email_val = f"{cid}:wi"
                wl_clients[cid] = {"id": cid, "email": w_email_val}
            else:
                revoked_wl.add(cid)

    def active_clients_list(primary_map, flow_val=None, revoked_set=None):
        revoked = revoked_set or set()
        result = []
        for cid, c in primary_map.items():
            if cid in revoked:
                continue
            item = dict(c)
            if flow_val is not None:
                if flow_val:
                    item["flow"] = flow_val
                else:
                    item.pop("flow", None)
            result.append(item)
        return result

    def cert_pair(target_dom=None):
        t_dom = (target_dom or domain or "").strip().lower().lstrip("*.")
        if t_dom:
            le_pem = os.path.join(le_dir, "live", t_dom, "fullchain.pem")
            le_key = os.path.join(le_dir, "live", t_dom, "privkey.pem")
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
            "rejectUnknownSni": False,
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
                "routeOnly": True,
            },
        }

    def build_bridge_outbound(ob_tag, peer, flow="xtls-rprx-vision", use_utls=True):
        ip = str(peer.get("ip") or "").strip()
        uid = str(peer.get("uuid") or "").strip()
        sni = str(peer.get("sni") or "").strip()
        port = int(peer.get("port") or 443)
        if not is_valid_ipv4(ip) or not is_valid_uuid(uid) or not is_valid_fqdn(sni):
            return None
        user_cfg = {
            "id": uid,
            "encryption": "none",
        }
        tls_cfg = {
            "serverName": sni,
            "allowInsecure": False,
            "alpn": ["http/1.1"],
        }
        if flow:
            user_cfg["flow"] = flow
        if use_utls:
            tls_cfg["fingerprint"] = "firefox"
        else:
            tls_cfg["fingerprint"] = "unsafe"
        for ca_path in ("/usr/local/share/ca-certificates/just1k-internal-ca.crt", "/etc/just1knode/ca.crt"):
            if os.path.isfile(ca_path):
                tls_cfg["certificates"] = [{
                    "certificateFile": ca_path,
                    "usage": "verify",
                }]
                break
        ob = {
            "tag": ob_tag,
            "protocol": "vless",
            "settings": {
                "vnext": [{
                    "address": ip,
                    "port": port,
                    "users": [user_cfg],
                }]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "tls",
                "tlsSettings": tls_cfg,
                "sockopt": {
                    "tcpKeepAliveIdle": 60,
                    "tcpKeepAliveInterval": 15,
                },
            },
        }
        return ob

    def antiabuse_rules():
        return [
            {"type": "field", "ip": ["geoip:private"], "outboundTag": "just1k-wl-block"},
            {"type": "field", "protocol": ["bittorrent"], "outboundTag": "just1k-wl-block"},
            {"type": "field", "port": "25", "outboundTag": "just1k-wl-block"},
            {"type": "field", "port": "6881-6889", "outboundTag": "just1k-wl-block"},
            {"type": "field", "port": "443", "network": "udp", "outboundTag": "just1k-wl-block"},
        ]

    cfg = {
        "log": {"access": "none", "loglevel": "warning"},
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
    resolved_tunnel_uuid = ""

    api_rule = {"type": "field", "inboundTag": ["just1k-wl-api-grpc"], "outboundTag": "api"}

    if role == "ru_hub":
        cfg["routing"]["domainStrategy"] = "AsIs"
        has_vless_tls = mod_on("vless_tls")
        has_xhttp = mod_on("vless_xhttp")
        active_cdns = [k for k in cdn_provider_specs if mod_on(k)] if has_xhttp else []

        # Строго раздельное извлечение мостов Стандарт vs БИ (чистый v2 links.json без peers/shared_bridges)
        std_cfg = links.get("standard") if isinstance(links.get("standard"), dict) else {}
        bi_cfg = links.get("bi") if isinstance(links.get("bi"), dict) else {}
        std_bridges_raw = std_cfg.get("bridges") if isinstance(std_cfg.get("bridges"), list) else []
        bi_bridges_raw = bi_cfg.get("bridges") if isinstance(bi_cfg.get("bridges"), list) else []

        std_inbounds = []
        bi_inbounds = []
        used_ports = set()
        used_ports.update({ib.get("port") for ib in cfg["inbounds"] if ib.get("port")})

        std_loc_codes = []
        seen_std_locs = set()
        for p in std_bridges_raw:
            if not isinstance(p, dict):
                continue
            lc = clean_code(p.get("location_code") or p.get("code"), "")
            if lc and lc not in seen_std_locs:
                seen_std_locs.add(lc)
                std_loc_codes.append(lc)

        std_location_routes = []
        std_location_rules = []
        if has_vless_tls:
            c_file, k_file = cert_pair(domain)
            will_need_nginx = has_xhttp or len(std_loc_codes) > 0
            fb_dest = "127.0.0.1:8080" if will_need_nginx else "127.0.0.1:80"
            if not will_need_nginx:
                fallback80_needed = True

            ss_tls = {
                "network": "tcp",
                "security": "tls",
                "tlsSettings": build_tls_settings(c_file, k_file, domain),
            }

            fb_obj = {"dest": fb_dest}
            if will_need_nginx:
                fb_obj["xver"] = 1
            cfg["inbounds"].append({
                "tag": "just1k-vless-direct",
                "listen": "0.0.0.0",
                "port": 443,
                "protocol": "vless",
                "settings": {
                    "clients": active_clients_list(vless_clients, "xtls-rprx-vision", revoked_vless),
                    "decryption": "none",
                    "fallbacks": [fb_obj],
                },
                "streamSettings": ss_tls,
                "sniffing": {"enabled": True, "destOverride": ["tls", "http", "quic"], "routeOnly": True},
            })
            std_inbounds.append("just1k-vless-direct")

            std_next_port = 8105
            std_xhttp_spec = {
                "uplinkHTTPMethod": "POST",
                "uplinkDataPlacement": "body",
                "xPaddingPlacement": "header",
            }
            std_active_clients = active_clients_list(vless_clients, "", revoked_vless)
            for lc in std_loc_codes:
                while std_next_port in used_ports:
                    std_next_port += 1
                s_port = std_next_port
                used_ports.add(s_port)
                s_tag = f"just1k-vless-loc-{lc}"
                s_path = f"/std/{lc}"
                cfg["inbounds"].append(
                    build_xhttp_inbound(s_tag, s_port, s_path, std_xhttp_spec, std_active_clients)
                )
                std_inbounds.append(s_tag)
                std_location_routes.append((s_path, f"xray_std_loc_{lc}", s_port))
                std_location_rules.append((lc, s_tag))

        # CDN XHTTP инбаунды (БИ)
        for cdn_key in active_cdns:
            spec = cdn_provider_specs[cdn_key]
            mod_cfg = modules.get(cdn_key, {})
            c_port = int(mod_cfg.get("port") or spec["port"])
            while c_port in used_ports:
                c_port += 1
            used_ports.add(c_port)
            c_tag = str(mod_cfg.get("tag") or spec["tag"])
            c_path = str(mod_cfg.get("path") or f"{secret_base}/{spec['subpath']}")
            spec_eff = dict(spec)
            if mod_cfg.get("xPaddingPlacement"):
                spec_eff["xPaddingPlacement"] = str(mod_cfg["xPaddingPlacement"])
            cfg["inbounds"].append(
                build_xhttp_inbound(c_tag, c_port, c_path, spec_eff, active_clients_list(wl_clients, "", revoked_wl))
            )
            bi_inbounds.append(c_tag)

        # Локационные XHTTP инбаунды: автоматическая матрица (каждая локация x каждый активный CDN)
        seen_loc_codes = set()
        loc_sources = []
        if isinstance(bi_cfg.get("locations"), list) and bi_cfg["locations"]:
            loc_sources.extend(bi_cfg["locations"])
        else:
            loc_sources.extend([p for p in bi_bridges_raw if isinstance(p, dict) and p.get("code")])

        next_port = 8005
        location_nginx_routes = []
        bi_loc_inbounds_by_target = {}
        for loc in loc_sources:
            if not isinstance(loc, dict):
                continue
            code = clean_code(loc.get("code"), "")
            if not code or code in seen_loc_codes:
                continue
            seen_loc_codes.add(code)
            target_bridge = clean_code(loc.get("bridge_code") or code, code)

            # По умолчанию каждая локация поднимается сразу на всех активных CDN-модулях узла
            loc_cdns = list(active_cdns)
            explicit_cdns = loc.get("cdns") if isinstance(loc.get("cdns"), list) else (
                [loc.get("cdn")] if loc.get("cdn") else None
            )
            if explicit_cdns:
                filtered = [str(c).strip() for c in explicit_cdns if str(c).strip() in active_cdns]
                if filtered:
                    loc_cdns = filtered

            cdn_paths = loc.get("paths") if isinstance(loc.get("paths"), dict) else {}
            for cdn_idx, cdn_key in enumerate(loc_cdns):
                sp = cdn_provider_specs[cdn_key]
                m_cfg = modules.get(cdn_key, {})
                spec_eff = dict(sp)
                if isinstance(m_cfg, dict) and m_cfg.get("xPaddingPlacement"):
                    spec_eff["xPaddingPlacement"] = str(m_cfg["xPaddingPlacement"])

                # Единый канонический формат тега и пути независимо от числа активных CDN,
                # чтобы добавление/отключение второго CDN не ломало существующие подписки.
                loc_slug = f"{code}__{clean_code(cdn_key, f'cdn{cdn_idx + 1}')}"
                r_tag = f"just1k-wl-inbound-{loc_slug}"

                while next_port in used_ports:
                    next_port += 1
                r_port = next_port
                used_ports.add(r_port)

                raw_cdn_path = cdn_paths.get(cdn_key)
                if raw_cdn_path is not None and raw_cdn_path != "":
                    if not isinstance(raw_cdn_path, str):
                        sys.stderr.write(f"ERROR: invalid location path type for {code}/{cdn_key}\n")
                        sys.exit(1)
                    r_path = raw_cdn_path
                    if not is_valid_nginx_path(r_path):
                        sys.stderr.write(f"ERROR: unsafe location path for {code}/{cdn_key}: {raw_cdn_path!r}\n")
                        sys.exit(1)
                else:
                    r_path = f"{secret_base}/{sp['subpath']}/{code}"
                    if not r_path.startswith("/"):
                        r_path = "/" + r_path

                cfg["inbounds"].append(
                    build_xhttp_inbound(r_tag, r_port, r_path, spec_eff, active_clients_list(wl_clients, "", revoked_wl))
                )
                bi_inbounds.append(r_tag)
                bi_loc_inbounds_by_target.setdefault(target_bridge, []).append(r_tag)
                location_nginx_routes.append((r_path, f"xray_xhttp_loc_{loc_slug}", spec_eff))

        # Выход в Рунет (ТОЛЬКО для RU-сегмента и строго по российским доменам; резолв строго IPv4 через sockopt.domainStrategy)
        ru_domains = [
            "geosite:category-ru", "geosite:tld-ru",
            "domain:ru", "domain:su", "domain:xn--p1ai",
        ]
        # outbounds[0] MUST be blackhole: guarantees zero-leak fallback if balancers or bridges are unreachable
        cfg["outbounds"].append({
            "tag": "just1k-wl-block",
            "protocol": "blackhole",
            "settings": {},
        })
        cfg["outbounds"].append({
            "tag": "just1k-wl-direct",
            "protocol": "freedom",
            "settings": {},
            "streamSettings": {"sockopt": {"domainStrategy": "UseIPv4", "mark": 255}},
        })

        # Outbounds для Стандарта (std_bridges)
        std_outbounds = {}
        std_tags_by_loc = {}
        std_all_tags = []
        std_default_tag = None
        for idx, p in enumerate(std_bridges_raw):
            if not isinstance(p, dict):
                continue
            p_code = clean_code(p.get("code"), f"hub{idx+1}")
            loc_key = clean_code(p.get("location_code") or p.get("code"), p_code)
            ob_tag = f"bridge-std-{p_code}"
            if p_code in std_outbounds:
                continue
            ob = build_bridge_outbound(ob_tag, p)
            if ob is None:
                continue
            std_outbounds[p_code] = ob_tag
            std_tags_by_loc.setdefault(loc_key, []).append(ob_tag)
            std_all_tags.append(ob_tag)
            cfg["outbounds"].append(ob)
            if not std_default_tag or p.get("is_default"):
                std_default_tag = ob_tag

        # Outbounds для БИ (bi_bridges)
        bi_outbounds = {}
        bi_tags_by_loc = {}
        bi_all_tags = []
        bi_default_tag = None
        for idx, p in enumerate(bi_bridges_raw):
            if not isinstance(p, dict):
                continue
            p_code = clean_code(p.get("code"), f"hub{idx+1}")
            loc_key = clean_code(p.get("location_code") or p.get("code"), p_code)
            ob_tag = f"bridge-bi-{p_code}"
            if p_code in bi_outbounds:
                continue
            ob = build_bridge_outbound(ob_tag, p)
            if ob is None:
                continue
            bi_outbounds[p_code] = ob_tag
            bi_tags_by_loc.setdefault(loc_key, []).append(ob_tag)
            bi_all_tags.append(ob_tag)
            cfg["outbounds"].append(ob)
            if not bi_default_tag or p.get("is_default"):
                bi_default_tag = ob_tag

        # Outbounds для фонового зондирования временно исключённых eu_hub (probe_bridges)
        probe_bridges_raw = links.get("probe_bridges") if isinstance(links.get("probe_bridges"), list) else []
        probe_only_tags = []
        for idx, p in enumerate(probe_bridges_raw):
            if not isinstance(p, dict):
                continue
            p_code = clean_code(p.get("code"), f"probe{idx+1}")
            ob_tag = f"bridge-probe-{p_code}"
            if ob_tag in probe_only_tags:
                continue
            ob = build_bridge_outbound(ob_tag, p)
            if ob is None:
                continue
            probe_only_tags.append(ob_tag)
            cfg["outbounds"].append(ob)

        all_probe_tags = list(dict.fromkeys(list(std_outbounds.values()) + list(bi_outbounds.values()) + probe_only_tags))
        probe_rules = []
        if all_probe_tags:
            probe_socks_port = 10809
            while probe_socks_port in used_ports:
                probe_socks_port += 1
            used_ports.add(probe_socks_port)
            cfg["inbounds"].append({
                "tag": "just1k-probe-socks",
                "listen": "127.0.0.1",
                "port": probe_socks_port,
                "protocol": "socks",
                "settings": {
                    "auth": "password",
                    "accounts": [{"user": t, "pass": "just1k-probe"} for t in all_probe_tags],
                    "udp": False,
                    "userLevel": 1,
                },
                "sniffing": {"enabled": False},
            })
            for t in all_probe_tags:
                probe_rules.append({
                    "type": "field",
                    "inboundTag": ["just1k-probe-socks"],
                    "user": [t],
                    "outboundTag": t,
                })

        balancers = []
        observed_tags = set()

        def _route_target_for_tags(bal_tag, tags, fallback_tag):
            if len(tags) >= 2:
                if not any(b["tag"] == bal_tag for b in balancers):
                    balancers.append({
                        "tag": bal_tag,
                        "selector": list(tags),
                        "strategy": {"type": "leastPing"},
                    })
                    observed_tags.update(tags)
                return {"balancerTag": bal_tag}
            if len(tags) == 1:
                return {"outboundTag": tags[0]}
            return {"outboundTag": fallback_tag}

        std_loc_rules = []
        # 1. Локационные XHTTP-правила (по инбаундам /std/{lc})
        for lc, s_tag in std_location_rules:
            loc_tags = std_tags_by_loc.get(lc) or ([std_outbounds[lc]] if lc in std_outbounds else [])
            if loc_tags:
                target_kw = _route_target_for_tags(f"bal-std-{lc}", loc_tags, "just1k-wl-block")
                std_loc_rules.append({"type": "field", "inboundTag": [s_tag], **target_kw})

        # 2. Локационные правила прямого VLESS TLS (443): строгая маршрутизация по user regex
        for lc, loc_tags in std_tags_by_loc.items():
            if loc_tags:
                target_kw = _route_target_for_tags(f"bal-std-{lc}", loc_tags, "just1k-wl-block")
                std_loc_rules.append({
                    "type": "field",
                    "inboundTag": ["just1k-vless-direct"],
                    "user": [f"regexp::{lc}:std$", f"regexp::{lc}$"],
                    **target_kw,
                })

        all_client_inbounds = list(dict.fromkeys(std_inbounds + bi_inbounds))
        rules = [api_rule] + antiabuse_rules() + probe_rules
        if all_client_inbounds:
            # Строго прямой выход для РФ-трафика (домены РФ + GeoIP RU)
            rules.append(
                {"type": "field", "inboundTag": all_client_inbounds, "domain": ru_domains, "outboundTag": "just1k-wl-direct"}
            )
            rules.append(
                {"type": "field", "inboundTag": all_client_inbounds, "ip": ["geoip:ru"], "outboundTag": "just1k-wl-direct"}
            )
        rules.extend(std_loc_rules)

        # Локационные БИ-правила (все CDN-инбаунды локации -> балансировщик или мост bridge-bi-<code>)
        for b_code, loc_tags in bi_loc_inbounds_by_target.items():
            if not loc_tags:
                continue
            target_tags = bi_tags_by_loc.get(b_code) or ([bi_outbounds[b_code]] if b_code in bi_outbounds else [])
            if target_tags:
                target_kw = _route_target_for_tags(f"bal-bi-{b_code}", target_tags, "just1k-wl-block")
                rules.append({"type": "field", "inboundTag": loc_tags, **target_kw})

        # Zero-Trust Fallback: иностранный трафик без моста ИДЁТ В BLACKHOLE, НИКОГДА НЕ В DIRECT!
        if std_inbounds:
            std_fb_kw = _route_target_for_tags("bal-std-default", std_all_tags, std_default_tag or "just1k-wl-block")
            rules.append({
                "type": "field",
                "inboundTag": std_inbounds,
                **std_fb_kw,
            })
        if bi_inbounds:
            bi_fb_kw = _route_target_for_tags("bal-bi-default", bi_all_tags, bi_default_tag or "just1k-wl-block")
            rules.append({
                "type": "field",
                "inboundTag": bi_inbounds,
                **bi_fb_kw,
            })

        if balancers:
            cfg["routing"]["balancers"] = balancers
            cfg["observatory"] = {
                "subjectSelector": sorted(observed_tags),
                "probeURL": "https://www.google.com/generate_204",
                "probeInterval": "30s",
                "enableConcurrency": False,
            }

        cfg["routing"]["rules"] = rules

        # Nginx HTTP конфигурация для XHTTP (Стандарт + БИ) / /sub/ на ru_hub
        if has_xhttp or std_location_routes:
            nginx_needed = True
            c_file, k_file = cert_pair(domain)
            listen_block = (
                "    listen 127.0.0.1:8080 proxy_protocol;\n"
                if has_vless_tls else
                "    listen 443 ssl;\n"
                f"    ssl_certificate {c_file};\n"
                f"    ssl_certificate_key {k_file};\n"
                "    ssl_protocols TLSv1.2 TLSv1.3;\n"
                "    ssl_ciphers HIGH:!aNULL:!MD5;\n"
            )
            if has_vless_tls:
                catchall_block = (
                    "server {\n"
                    "    listen 127.0.0.1:8080 default_server proxy_protocol;\n"
                    "    server_name _;\n"
                    "    server_tokens off;\n"
                    "    return 444;\n"
                    "}\n\n"
                )
            elif ssl_reject_avail:
                catchall_block = (
                    "server {\n"
                    "    listen 443 ssl default_server;\n"
                    "    server_name _;\n"
                    "    server_tokens off;\n"
                    "    ssl_reject_handshake on;\n"
                    "}\n\n"
                )
            else:
                catchall_block = (
                    "server {\n"
                    "    listen 443 ssl default_server;\n"
                    "    server_name _;\n"
                    "    server_tokens off;\n"
                    f"    ssl_certificate {c_file};\n"
                    f"    ssl_certificate_key {k_file};\n"
                    "    return 444;\n"
                    "}\n\n"
                )
            cidr_lines = []
            seen_cidr = set()
            cdn_only_cidrs = []
            if has_vless_tls and will_need_nginx:
                seen_cidr.add("127.0.0.1")
                cidr_lines.append("    set_real_ip_from 127.0.0.1;")
            use_xff = False
            use_xri = False
            for ck in active_cdns:
                sp = cdn_provider_specs[ck]
                if sp.get("real_ip_header") == "X-Forwarded-For":
                    use_xff = True
                else:
                    use_xri = True
                for cidr in sp.get("cidrs", []):
                    if cidr not in seen_cidr:
                        seen_cidr.add(cidr)
                        cdn_only_cidrs.append(cidr)
                        cidr_lines.append(f"    set_real_ip_from {cidr};")
            real_ip_hdr = "X-Forwarded-For" if use_xff or not use_xri else "X-Real-IP"
            loc_blocks = []
            sub_map_block = ""
            if bot_domain:
                geo_peer_var = "$proxy_protocol_addr" if has_vless_tls else "$realip_remote_addr"
                geo_entries = ["    default 0;"]
                for cidr in cdn_only_cidrs:
                    geo_entries.append(f"    {cidr} 1;")
                sub_map_block = (
                    f"geo {geo_peer_var} $just1k_is_trusted_cdn_peer {{\n"
                    + "\n".join(geo_entries) + "\n"
                    "}\n\n"
                    "map $http_x_forwarded_for_y $just1k_yff_ip {\n"
                    '    "~(?:^|[,\\s])([0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+|[0-9a-fA-F:]*:[0-9a-fA-F:]*:[0-9a-fA-F:.]*)\\s*$" $1;\n'
                    '    default "";\n'
                    "}\n\n"
                    'map "${just1k_is_trusted_cdn_peer}:${just1k_yff_ip}" $just1k_sub_client_ip {\n'
                    '    "~^1:(.+)$" $1;\n'
                    '    "~^1:$"     $remote_addr;\n'
                    f"    default     {geo_peer_var};\n"
                    "}\n\n"
                    'map "${just1k_is_trusted_cdn_peer}:${just1k_yff_ip}" $just1k_sub_xff {\n'
                    f'    "~^1:(.+)$" "$1, {geo_peer_var}";\n'
                    f'    "~^1:$"     "$remote_addr, {geo_peer_var}";\n'
                    f"    default     {geo_peer_var};\n"
                    "}\n\n"
                )
                def _make_sub_proxy_loc(loc_prefix):
                    clean_p = loc_prefix.rstrip("/") or "/sub"
                    return (
                        f"    location ^~ {clean_p}/ {{\n"
                        f"        proxy_pass https://{bot_domain}{clean_p}/;\n"
                        "        proxy_http_version 1.1;\n"
                        "        proxy_ssl_server_name on;\n"
                        f"        proxy_set_header Host {bot_domain};\n"
                        "        proxy_set_header X-Real-IP $just1k_sub_client_ip;\n"
                        "        proxy_set_header X-Forwarded-For $just1k_sub_xff;\n"
                        "        proxy_buffering off;\n"
                        "        proxy_request_buffering off;\n"
                        "    }\n"
                    )
                loc_blocks.append(_make_sub_proxy_loc("/sub"))
                if sub_prefix != "/sub" and not sub_prefix.startswith("/sub/") and is_valid_nginx_path(sub_prefix):
                    loc_blocks.append(_make_sub_proxy_loc(sub_prefix))

            def make_xhttp_loc(c_path_raw, upstream_name, sp):
                cp = str(c_path_raw or "").rstrip("/")
                if not is_valid_nginx_path(cp):
                    sys.stderr.write(f"ERROR: unsafe nginx location path rejected: {c_path_raw!r}\n")
                    sys.exit(1)
                return (
                    f"    location ^~ {cp} {{\n"
                    f"        rewrite ^{re.escape(cp)}/?$ {cp}/ break;\n"
                    f"        proxy_pass http://{upstream_name};\n"
                    "        proxy_http_version 1.1;\n"
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
                sp = cdn_provider_specs[ck]
                m_cfg = modules.get(ck, {})
                c_path = str(m_cfg.get("path") or f"{secret_base}/{sp['subpath']}").rstrip("/")
                seen_loc_paths.add(c_path)
                loc_blocks.append(make_xhttp_loc(c_path, sp["upstream"], sp))
            for r_path, r_upstream, r_sp in location_nginx_routes:
                cp = str(r_path).rstrip("/")
                if cp and cp not in seen_loc_paths:
                    seen_loc_paths.add(cp)
                    loc_blocks.append(make_xhttp_loc(cp, r_upstream, r_sp))
            std_upstream_blocks = []
            for s_path, s_upstream, s_port in std_location_routes:
                cp = str(s_path).rstrip("/")
                std_upstream_blocks.append(
                    f"upstream {s_upstream} {{\n    server 127.0.0.1:{s_port};\n    keepalive 32;\n}}\n"
                )
                if cp and cp not in seen_loc_paths:
                    seen_loc_paths.add(cp)
                    loc_blocks.append(make_xhttp_loc(cp, s_upstream, {}))
            cdn_doms = [str(state.get("cdn_domain") or "").strip()]
            for ck in active_cdns:
                m_cfg = modules.get(ck, {})
                if isinstance(m_cfg, dict):
                    cdn_doms.append(str(m_cfg.get("cdn_domain") or m_cfg.get("domain") or "").strip())
            srv_names = " ".join([x for x in dict.fromkeys([domain] + cdn_doms) if x and x != "-"]) or (domain or "localhost")
            nginx_text = (
                sub_map_block
                + "\n".join(std_upstream_blocks)
                + catchall_block
                + "server {\n"
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

    elif role == "eu_hub":
        c_file, k_file = cert_pair(domain)
        fallback80_needed = True
        t_uuid = str(state.get("tunnel_uuid") or "").strip()
        if not is_valid_uuid(t_uuid):
            t_uuid = str(uuid_lib.uuid4())
            resolved_tunnel_uuid = t_uuid
        relay_port = int(state.get("relay_port") or 443)

        in_clients_map = {}

        def add_hub_client(uid, email, override=False):
            if not is_valid_uuid(uid):
                return
            if uid not in in_clients_map or override:
                in_clients_map[uid] = {"id": uid, "email": email, "flow": "xtls-rprx-vision"}

        add_hub_client(t_uuid, "ru-hub@just1k")
        for item in (links.get("incoming_ru_hubs") or []):
            if isinstance(item, dict):
                u = str(item.get("uuid") or item.get("ingress_uuid") or "").strip()
                em = str(item.get("route_user") or item.get("email") or f"ingress-{clean_code(item.get('code'), 'ru')}@just1k")
                add_hub_client(u, em, override=bool(item.get("route_user") or item.get("email")))
        for item in (links.get("routes") or []):
            if isinstance(item, dict) and item.get("ingress_uuid"):
                em = str(item.get("route_user") or f"ingress-{clean_code(item.get('code'), 'rt')}@just1k")
                add_hub_client(str(item["ingress_uuid"]).strip(), em, override=bool(item.get("route_user")))

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
            "sniffing": {"enabled": False},
        })

        # СТРОГО без freedom: только выходы на Выходные НОДЫ (links.json v2) + blackhole
        exit_sources = links.get("exit_nodes") if isinstance(links.get("exit_nodes"), list) else []

        primary_exit_tag = None
        route_rules = [api_rule] + antiabuse_rules()
        seen_exits = {}
        exit_by_id = {}
        exit_by_uuid = {}
        exit_by_code = {}
        for idx, p in enumerate(exit_sources):
            if not isinstance(p, dict):
                continue
            p_code = clean_code(p.get("code"), f"exit{idx+1}")
            explicit_tag = str(p.get("tag") or "").strip()
            ob_tag = explicit_tag if (explicit_tag and re.fullmatch(r"[a-zA-Z0-9_-]+", explicit_tag)) else f"exit-{p_code}"
            if ob_tag in seen_exits:
                ob_tag = f"exit-{p_code}-{idx+1}"
            ob = build_bridge_outbound(ob_tag, p, flow="xtls-rprx-vision", use_utls=False)
            if ob is None:
                continue
            seen_exits[ob_tag] = ob
            cfg["outbounds"].append(ob)
            if p.get("id"):
                exit_by_id[str(p["id"]).strip()] = ob_tag
            p_uid = str(p.get("uuid") or "").strip().lower()
            if p_uid:
                exit_by_uuid[p_uid] = ob_tag
            exit_by_code.setdefault(p_code, ob_tag)
            if not primary_exit_tag or p.get("is_default"):
                primary_exit_tag = ob_tag
            if p.get("route_user"):
                route_rules.append({
                    "type": "field",
                    "user": [str(p["route_user"])],
                    "outboundTag": ob_tag,
                })

        for rt in (links.get("routes") or []):
            if not isinstance(rt, dict):
                continue
            r_users = []
            if rt.get("route_user"):
                r_users.append(str(rt["route_user"]))
            if isinstance(rt.get("route_users"), list):
                r_users.extend([str(u) for u in rt["route_users"] if u])
            if not r_users:
                continue
            target_tag = None
            if rt.get("exit_id") and str(rt["exit_id"]).strip() in exit_by_id:
                target_tag = exit_by_id[str(rt["exit_id"]).strip()]
            elif rt.get("exit_tag") and str(rt["exit_tag"]).strip() in seen_exits:
                target_tag = str(rt["exit_tag"]).strip()
            elif rt.get("exit_uuid") and str(rt["exit_uuid"]).strip().lower() in exit_by_uuid:
                target_tag = exit_by_uuid[str(rt["exit_uuid"]).strip().lower()]
            elif rt.get("exit_code"):
                cand_code = clean_code(rt["exit_code"], "")
                cand_tag = f"exit-{cand_code}"
                target_tag = cand_tag if cand_tag in seen_exits else exit_by_code.get(cand_code)
            if target_tag and target_tag in seen_exits:
                route_rules.append({
                    "type": "field",
                    "user": list(dict.fromkeys(r_users)),
                    "outboundTag": target_tag,
                })

        cfg["outbounds"].extend([
            {"tag": "just1k-wl-block", "protocol": "blackhole", "settings": {}},
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
            resolved_tunnel_uuid = t_uuid

        # СТРОГО ТОЛЬКО bridge UUID от хабов — VLESS TLS + xtls-rprx-vision (zero-copy splicing без mux; нет ТСПУ в ЕС)
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
            },
            "streamSettings": {
                "network": "tcp",
                "security": "tls",
                "tlsSettings": build_tls_settings(c_file, k_file, domain),
            },
        })
        cfg["routing"]["domainStrategy"] = "IPOnDemand"
        cfg["outbounds"] = [
            {"tag": "direct", "protocol": "freedom", "settings": {}, "streamSettings": {"sockopt": {"domainStrategy": "UseIPv4", "mark": 255}}},
            {"tag": "just1k-wl-block", "protocol": "blackhole", "settings": {}},
        ]
        cfg["routing"]["rules"] = [api_rule] + antiabuse_rules() + [
            {"type": "field", "inboundTag": ["just1k-vless-direct"], "outboundTag": "direct"}
        ]

    with open(out_xray_path, "w", encoding="utf-8") as xfp:
        json.dump(cfg, xfp, indent=2, ensure_ascii=False)

    print(json.dumps({
        "nginx_needed": nginx_needed,
        "fallback80_needed": fallback80_needed,
        "secret_base_path": secret_base,
        "tunnel_uuid": resolved_tunnel_uuid,
    }))


if __name__ == "__main__":
    main()
