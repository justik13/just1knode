import json
import subprocess
import sys
import uuid
from pathlib import Path

CONFIG_BUILDER = Path(__file__).resolve().parents[1] / "scripts" / "config_builder.py"


def _run_builder(
    tmp_path: Path,
    state: dict,
    links: dict,
    clients: dict | None = None,
    cdn_specs: dict | None = None,
) -> tuple[dict, str, dict]:
    state_path = tmp_path / "state.json"
    clients_path = tmp_path / "clients.json"
    links_path = tmp_path / "links.json"
    cur_cfg_path = tmp_path / "current_config.json"
    out_xray_path = tmp_path / "xray_config.json"
    out_nginx_path = tmp_path / "nginx.conf"

    state_path.write_text(json.dumps(state), encoding="utf-8")
    clients_path.write_text(json.dumps(clients or {"clients": {}}), encoding="utf-8")
    links_path.write_text(json.dumps(links), encoding="utf-8")

    proc = subprocess.run(
        [
            sys.executable,
            str(CONFIG_BUILDER),
            str(state_path),
            str(clients_path),
            "_",
            str(links_path),
            str(cur_cfg_path),
            str(out_xray_path),
            str(out_nginx_path),
            str(tmp_path / "tls"),
            str(tmp_path / "le"),
            json.dumps(cdn_specs or {}),
            "",
            "true",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    xray_cfg = json.loads(out_xray_path.read_text(encoding="utf-8"))
    nginx_conf = out_nginx_path.read_text(encoding="utf-8") if out_nginx_path.exists() else ""
    meta = json.loads(proc.stdout.strip())
    return xray_cfg, nginx_conf, meta


def test_ru_hub_uses_sockopt_domain_strategy_and_valid_invariants(tmp_path: Path) -> None:
    c_std = str(uuid.uuid4())
    c_wi = str(uuid.uuid4())
    state = {
        "role": "ru_hub",
        "domain": "origin.example.net",
        "bot_domain": "bot.example.net",
        "secret_base_path": "/assets_abcd1234",
        "modules": {
            "vless_tls": {"enabled": True},
            "vless_xhttp": {"enabled": True},
            "cdn_turboflare": {"enabled": True},
        },
    }
    cdn_specs = {
        "cdn_turboflare": {
            "port": 8001,
            "tag": "just1k-wl-inbound-tf",
            "subpath": "tf",
            "upstream": "xray_xhttp_tf",
            "uplinkHTTPMethod": "POST",
            "uplinkDataPlacement": "body",
            "xPaddingPlacement": "header",
            "real_ip_header": "X-Forwarded-For",
            "cidrs": ["192.0.2.0/24"],
        }
    }
    links = {
        "standard": {
            "bridges": [
                {
                    "code": "de1",
                    "location_code": "de",
                    "ip": "198.51.100.10",
                    "port": 443,
                    "uuid": str(uuid.uuid4()),
                    "sni": "eu-de1.example.net",
                    "is_default": True,
                }
            ]
        },
        "bi": {
            "bridges": [
                {
                    "code": "nl1",
                    "location_code": "nl",
                    "ip": "198.51.100.20",
                    "port": 443,
                    "uuid": str(uuid.uuid4()),
                    "sni": "eu-nl1.example.net",
                    "is_default": True,
                }
            ]
        },
    }
    clients = {
        "clients": {
            c_std: {
                "service_states": {"vless": {"is_active": True, "tombstone": False}},
            },
            c_wi: {
                "service_states": {"white_internet": {"is_active": True, "tombstone": False}},
            },
        }
    }

    cfg, nginx_conf, meta = _run_builder(tmp_path, state, links, clients, cdn_specs)

    assert meta["nginx_needed"] is True
    assert cfg["routing"]["domainStrategy"] == "AsIs"
    assert cfg["outbounds"][0]["tag"] == "just1k-wl-block"
    assert cfg["outbounds"][0]["protocol"] == "blackhole"

    freedom_outs = [ob for ob in cfg["outbounds"] if ob.get("protocol") == "freedom"]
    assert len(freedom_outs) == 1
    direct = freedom_outs[0]
    assert direct["tag"] == "just1k-wl-direct"
    assert direct.get("settings", {}) == {}
    assert direct["streamSettings"]["sockopt"] == {"domainStrategy": "UseIPv4", "mark": 255}

    bridge_outs = [ob for ob in cfg["outbounds"] if ob.get("tag", "").startswith("bridge-")]
    assert len(bridge_outs) == 2
    for ob in bridge_outs:
        assert ob["streamSettings"]["tlsSettings"]["fingerprint"] == "firefox"

    ports = [ib["port"] for ib in cfg["inbounds"] if "port" in ib]
    assert len(ports) == len(set(ports))
    assert "location ^~ /sub/" in nginx_conf


def test_eu_hub_has_no_freedom_and_disables_utls_to_exit(tmp_path: Path) -> None:
    state = {
        "role": "eu_hub",
        "domain": "eu.example.net",
        "tunnel_uuid": str(uuid.uuid4()),
    }
    links = {
        "incoming_ru_hubs": [
            {"code": "ru1", "uuid": str(uuid.uuid4()), "route_user": "ru1@just1k"}
        ],
        "exit_nodes": [
            {
                "code": "fi1",
                "ip": "203.0.113.10",
                "port": 443,
                "uuid": str(uuid.uuid4()),
                "sni": "fi1.example.net",
                "is_default": True,
            }
        ],
    }

    cfg, _, _ = _run_builder(tmp_path, state, links)

    assert all(ob.get("protocol") != "freedom" for ob in cfg["outbounds"])
    assert any(ob.get("protocol") == "blackhole" for ob in cfg["outbounds"])
    exit_ob = next(ob for ob in cfg["outbounds"] if ob.get("tag") == "exit-fi1")
    assert exit_ob["streamSettings"]["tlsSettings"]["fingerprint"] == "unsafe"


def test_exit_node_uses_sockopt_domain_strategy_without_legacy_settings(tmp_path: Path) -> None:
    state = {
        "role": "exit_node",
        "domain": "exit.example.net",
        "tunnel_uuid": str(uuid.uuid4()),
    }
    links = {
        "incoming_hubs": [{"code": "eu1", "uuid": str(uuid.uuid4())}],
    }

    cfg, _, _ = _run_builder(tmp_path, state, links)

    assert cfg["routing"]["domainStrategy"] == "IPOnDemand"
    freedom_outs = [ob for ob in cfg["outbounds"] if ob.get("protocol") == "freedom"]
    assert len(freedom_outs) == 1
    direct = freedom_outs[0]
    assert direct["tag"] == "direct"
    assert direct.get("settings", {}) == {}
    assert direct["streamSettings"]["sockopt"] == {"domainStrategy": "UseIPv4", "mark": 255}

    vless_in = next(ib for ib in cfg["inbounds"] if ib.get("tag") == "just1k-vless-direct")
    assert "sniffing" not in vless_in
