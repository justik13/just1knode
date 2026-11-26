import asyncio
import importlib
import json
import os
import socket
import sys
import tempfile
import threading
import types
from pathlib import Path

import pytest
from pydantic import ValidationError

REPO_ROOT = Path(__file__).resolve().parent.parent
XRAY_API_DIR = REPO_ROOT / "scripts" / "xray_api"
SCRIPTS_DIR = REPO_ROOT / "scripts"


def _load_modules():
    tmp_root = Path(tempfile.gettempdir()) / "just1knode_test_state"
    tmp_root.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("IDEMPOTENCY_DB_PATH", str(tmp_root / "idempotency.db"))
    os.environ.setdefault("STATE_FILE_PATH", str(tmp_root / "state.json"))
    os.environ.setdefault("CLIENTS_FILE_PATH", str(tmp_root / "clients.json"))
    os.environ.setdefault("XRAY_CONFIG_PATH", str(tmp_root / "config.json"))

    if "fcntl" not in sys.modules:
        try:
            import fcntl  # noqa: F401
        except ImportError:
            fake_fcntl = types.ModuleType("fcntl")
            fake_fcntl.LOCK_EX = 2
            fake_fcntl.LOCK_SH = 1
            fake_fcntl.LOCK_UN = 8
            fake_fcntl.flock = lambda *_args, **_kwargs: None
            sys.modules["fcntl"] = fake_fcntl

    if "grpc" not in sys.modules:
        try:
            import grpc  # noqa: F401
        except ImportError:
            fake_grpc = types.ModuleType("grpc")
            fake_grpc.Channel = object
            fake_grpc.RpcError = Exception
            fake_grpc.StatusCode = types.SimpleNamespace(
                ALREADY_EXISTS="ALREADY_EXISTS",
                NOT_FOUND="NOT_FOUND",
            )
            fake_grpc.insecure_channel = lambda *_args, **_kwargs: None
            sys.modules["grpc"] = fake_grpc

    for p in (str(XRAY_API_DIR), str(SCRIPTS_DIR)):
        if p not in sys.path:
            sys.path.insert(0, p)

    app_mod = importlib.import_module("app")
    schemas_mod = importlib.import_module("schemas")
    builder_mod = importlib.import_module("config_builder")
    return app_mod, schemas_mod, builder_mod


def _start_mock_socks5_http_server(response_bytes: bytes, hold_open: threading.Event | None = None):
    """Start a local SOCKS5 (user/pass) -> plain HTTP responder on 127.0.0.1."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(4)
    port = srv.getsockname()[1]

    def _serve():
        try:
            conn, _ = srv.accept()
        except OSError:
            return
        with conn:
            try:
                # 1. Greeting
                greeting = conn.recv(16)
                if not greeting.startswith(b"\x05"):
                    return
                conn.sendall(b"\x05\x02")
                # 2. User/pass
                auth = conn.recv(512)
                if not auth.startswith(b"\x01"):
                    return
                conn.sendall(b"\x01\x00")
                # 3. CONNECT request
                conn.recv(512)
                conn.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x50")
                # 4. Read HTTP request and send HTTP response
                conn.recv(4096)
                conn.sendall(response_bytes)
                if hold_open is not None:
                    hold_open.wait(timeout=3.0)
            except OSError:
                pass

    t = threading.Thread(target=_serve, daemon=True)
    t.start()
    return srv, port, t


def test_bridge_spec_allows_long_location_plus_eu_suffix():
    _, schemas_mod, _ = _load_modules()
    long_code = f"{'a' * 32}-eu123"
    spec = schemas_mod.BridgeSpec(
        code=long_code,
        location_code="a" * 32,
        ip="1.2.3.4",
        port=443,
        sni="eu.example.com",
        uuid="11111111-1111-4111-8111-111111111111",
    )
    assert spec.code == long_code

    with pytest.raises(ValidationError):
        schemas_mod.BridgeSpec(
            code="a" * 49,
            ip="1.2.3.4",
            port=443,
            sni="eu.example.com",
            uuid="11111111-1111-4111-8111-111111111111",
        )


def test_collect_ru_hub_probe_targets_multi_exit_tags():
    app_mod, _, _ = _load_modules()
    links = {
        "standard": {
            "bridges": [
                {"ip": "10.0.0.1", "sni": "eu1.example.com", "code": "de-eu1", "location_code": "de"},
                {"ip": "10.0.0.1", "sni": "eu1.example.com", "code": "nl-eu1", "location_code": "nl"},
                {"ip": "10.0.0.1", "sni": "eu1.example.com", "code": "fi-eu1", "location_code": "fi"},
                {"ip": "10.0.0.2", "sni": "eu2.example.com", "code": "de-eu2", "location_code": "de"},
            ]
        },
        "bi": {
            "bridges": [
                {"ip": "10.0.0.2", "sni": "eu2.example.com", "code": "de-eu2", "location_code": "de"},
                {"ip": "10.0.0.2", "sni": "eu2.example.com", "code": "uk-eu2", "location_code": "uk"},
            ]
        },
        "probe_bridges": [
            {"ip": "10.0.0.3", "sni": "eu3.example.com", "code": "de-eu3", "location_code": "de"},
            {"ip": "10.0.0.3", "sni": "eu3.example.com", "code": "nl-eu3", "location_code": "nl"},
        ],
    }
    configured = {
        "bridge-std-de-eu1",
        "bridge-std-nl-eu1",
        "bridge-std-fi-eu1",
        "bridge-std-de-eu2",
        "bridge-bi-de-eu2",
        "bridge-bi-uk-eu2",
        "bridge-probe-de-eu3",
        "bridge-probe-nl-eu3",
    }

    targets = {t["ip"]: t for t in app_mod._collect_ru_hub_probe_targets(links, configured)}
    assert targets["10.0.0.1"]["tags"] == ["bridge-std-de-eu1", "bridge-std-nl-eu1"]
    assert targets["10.0.0.1"]["tag"] == "bridge-std-de-eu1"
    # Same exit 'de' in bi is skipped in favor of distinct exit 'uk'
    assert targets["10.0.0.2"]["tags"] == ["bridge-std-de-eu2", "bridge-bi-uk-eu2"]
    assert targets["10.0.0.3"]["tags"] == ["bridge-probe-de-eu3", "bridge-probe-nl-eu3"]


def test_probe_via_socks5_sync_rejects_3xx_and_breaks_early_on_first_chunk():
    app_mod, _, _ = _load_modules()

    hold_302 = threading.Event()
    resp_302 = b"HTTP/1.1 302 Found\r\nLocation: https://other.example/\r\n\r\n"
    srv1, port1, t1 = _start_mock_socks5_http_server(resp_302, hold_open=hold_302)
    try:
        ok, _, _, err = app_mod._probe_via_socks5_sync(
            port1, "bridge-std-de-eu1", "http://probe.example/test", min_bytes=64, timeout=1.5
        )
        assert ok is False
        assert err == "HTTP 302"
    finally:
        hold_302.set()
        srv1.close()
        t1.join(timeout=1.0)

    hold_200 = threading.Event()
    payload = b"X" * 128
    resp_200 = f"HTTP/1.1 200 OK\r\nContent-Length: {len(payload)}\r\n\r\n".encode("ascii") + payload
    srv2, port2, t2 = _start_mock_socks5_http_server(resp_200, hold_open=hold_200)
    try:
        ok, nbytes, _, err = app_mod._probe_via_socks5_sync(
            port2, "bridge-std-de-eu1", "http://probe.example/test", min_bytes=64, timeout=1.5
        )
        assert ok is True
        assert nbytes >= 64
        assert err is None
    finally:
        hold_200.set()
        srv2.close()
        t2.join(timeout=1.0)


def test_run_bridge_probe_cycle_second_exit_and_apply_guards(tmp_path, monkeypatch):
    app_mod, _, _ = _load_modules()

    state_file = tmp_path / "state.json"
    links_file = tmp_path / "links.json"
    xray_cfg = tmp_path / "config.json"
    pending_file = tmp_path / ".apply_pending"

    state_file.write_text(json.dumps({"role": "ru_hub"}), encoding="utf-8")
    links_file.write_text(
        json.dumps({
            "standard": {
                "bridges": [
                    {"ip": "10.1.0.1", "sni": "eu1.example.com", "code": "de-eu1", "location_code": "de"},
                    {"ip": "10.1.0.1", "sni": "eu1.example.com", "code": "nl-eu1", "location_code": "nl"},
                ]
            }
        }),
        encoding="utf-8",
    )
    xray_cfg.write_text(
        json.dumps({
            "inbounds": [{"tag": "just1k-probe-socks", "port": 10809}],
            "outbounds": [
                {"tag": "bridge-std-de-eu1"},
                {"tag": "bridge-std-nl-eu1"},
            ],
        }),
        encoding="utf-8",
    )

    monkeypatch.setattr(app_mod, "STATE_FILE_PATH", state_file)
    monkeypatch.setattr(app_mod, "XRAY_CONFIG_PATH", xray_cfg)
    monkeypatch.setenv("LINKS_FILE_PATH", str(links_file))
    monkeypatch.setenv("APPLY_PENDING_PATH", str(pending_file))
    monkeypatch.setattr(app_mod, "BRIDGE_PROBE_URLS", ["https://probe.example/1"])

    async def _no_sleep(_sec):
        return None

    monkeypatch.setattr(app_mod.asyncio, "sleep", _no_sleep)

    with app_mod._bridge_health_lock:
        app_mod._bridge_health_state.clear()
        app_mod._bridge_health_state["10.1.0.1"] = {"ip": "10.1.0.1", "ok": True}
        app_mod._bridge_health_state["10.9.9.9"] = {"ip": "10.9.9.9", "ok": True}

    running_file = tmp_path / ".apply_running"

    # Pending/running apply must skip without mutating or pruning _bridge_health_state
    pending_file.write_text("1", encoding="utf-8")
    asyncio.run(app_mod._run_bridge_probe_cycle())
    snap = app_mod._get_bridge_health_snapshot()
    assert "10.9.9.9" in snap
    assert snap["10.1.0.1"] == {"ip": "10.1.0.1", "ok": True}
    pending_file.unlink()

    running_file.write_text("1", encoding="utf-8")
    asyncio.run(app_mod._run_bridge_probe_cycle())
    snap = app_mod._get_bridge_health_snapshot()
    assert "10.9.9.9" in snap
    running_file.unlink()

    # Keep IP present in links.json even if config.json has no matching bridge tags yet
    xray_cfg.write_text(
        json.dumps({
            "inbounds": [{"tag": "just1k-probe-socks", "port": 10809}],
            "outbounds": [{"tag": "just1k-wl-block"}],
        }),
        encoding="utf-8",
    )
    asyncio.run(app_mod._run_bridge_probe_cycle())
    snap = app_mod._get_bridge_health_snapshot()
    assert "10.1.0.1" in snap
    assert "10.9.9.9" not in snap

    # Restore configured tags; 1st exit fails, 2nd exit succeeds
    xray_cfg.write_text(
        json.dumps({
            "inbounds": [{"tag": "just1k-probe-socks", "port": 10809}],
            "outbounds": [{"tag": "bridge-std-de-eu1"}, {"tag": "bridge-std-nl-eu1"}],
        }),
        encoding="utf-8",
    )
    calls = []

    def _fake_probe(_port, tag, _url, _min_bytes, _timeout):
        calls.append(tag)
        if tag == "bridge-std-de-eu1":
            return False, 0, None, "Timeout"
        return True, 65536, 120, None

    monkeypatch.setattr(app_mod, "_probe_via_socks5_sync", _fake_probe)
    asyncio.run(app_mod._run_bridge_probe_cycle())
    assert calls == ["bridge-std-de-eu1", "bridge-std-nl-eu1"]
    snap = app_mod._get_bridge_health_snapshot()
    assert snap["10.1.0.1"]["ok"] is True
    assert snap["10.1.0.1"]["tag"] == "bridge-std-nl-eu1"
    assert snap["10.1.0.1"]["consecutive_fails"] == 0


def test_load_last_apply(tmp_path, monkeypatch):
    app_mod, _, _ = _load_modules()
    state_file = tmp_path / "state.json"
    monkeypatch.setattr(app_mod, "STATE_FILE_PATH", state_file)

    assert app_mod._load_last_apply() is None

    last_apply = tmp_path / "last_apply.json"
    last_apply.write_text(
        json.dumps({"ok": False, "rc": 2, "role": "ru_hub", "ts": 1700000100, "error": "boom"}),
        encoding="utf-8",
    )
    assert app_mod._load_last_apply() == {
        "ok": False,
        "rc": 2,
        "role": "ru_hub",
        "ts": 1700000100,
        "error": "boom",
    }

    last_apply.write_text("{broken json", encoding="utf-8")
    assert app_mod._load_last_apply() is None


def test_config_builder_probe_socks_and_probe_bridges(tmp_path, monkeypatch):
    _, _, builder_mod = _load_modules()

    state_file = tmp_path / "state.json"
    clients_file = tmp_path / "clients.json"
    links_file = tmp_path / "links.json"
    cur_cfg = tmp_path / "cur.json"
    out_xray = tmp_path / "xray.json"
    out_nginx = tmp_path / "nginx.conf"

    state_file.write_text(
        json.dumps({
            "role": "ru_hub",
            "domain": "ru.example.com",
            "modules": {"vless_tls": {"enabled": True}},
        }),
        encoding="utf-8",
    )
    clients_file.write_text(json.dumps({"clients": {}}), encoding="utf-8")
    links_file.write_text(
        json.dumps({
            "standard": {
                "bridges": [
                    {
                        "code": "de-eu1",
                        "location_code": "de",
                        "ip": "10.0.0.1",
                        "port": 443,
                        "sni": "eu1.example.com",
                        "uuid": "11111111-1111-4111-8111-111111111111",
                        "is_default": True,
                    }
                ]
            },
            "probe_bridges": [
                {
                    "code": "de-eu2",
                    "location_code": "de",
                    "ip": "10.0.0.2",
                    "port": 443,
                    "sni": "eu2.example.com",
                    "uuid": "22222222-2222-4222-8222-222222222222",
                    "is_default": False,
                }
            ],
        }),
        encoding="utf-8",
    )

    monkeypatch.setattr(
        sys,
        "argv",
        [
            "config_builder.py",
            str(state_file),
            str(clients_file),
            "-",
            str(links_file),
            str(cur_cfg),
            str(out_xray),
            str(out_nginx),
            str(tmp_path / "tls"),
            str(tmp_path / "le"),
            "{}",
            "",
            "false",
        ],
    )
    builder_mod.main()

    cfg = json.loads(out_xray.read_text(encoding="utf-8"))
    outbound_tags = [ob["tag"] for ob in cfg["outbounds"]]
    assert "bridge-std-de-eu1" in outbound_tags
    assert "bridge-probe-de-eu2" in outbound_tags

    probe_ib = next(ib for ib in cfg["inbounds"] if ib["tag"] == "just1k-probe-socks")
    assert probe_ib["protocol"] == "socks"
    acct_users = [a["user"] for a in probe_ib["settings"]["accounts"]]
    assert acct_users == ["bridge-std-de-eu1", "bridge-probe-de-eu2"]

    probe_rules = [
        r for r in cfg["routing"]["rules"] if r.get("inboundTag") == ["just1k-probe-socks"]
    ]
    assert {r["outboundTag"] for r in probe_rules} == {
        "bridge-std-de-eu1",
        "bridge-probe-de-eu2",
    }
