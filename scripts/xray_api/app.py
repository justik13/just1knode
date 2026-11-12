import asyncio
import ipaddress
import json
import logging
import os
import re
import secrets
import shutil
import tempfile
import time
import uuid as uuid_lib
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Dict, List, Literal, Optional

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response, status
from pydantic import BaseModel, Field, model_validator

import sqlite3

from client_store import ClientStore, ClientStoreCorruptedError
from epoch_manager import EpochManager
from xray_grpc import XrayGrpcClient


class DurableIdempotencyStore:
    """Persistent SQLite-backed store for durable idempotent operations.

    Ensures idempotent operation records survive process restarts, crashes, and OOM kills.
    """

    def __init__(self, db_path: Path):
        self.db_path = db_path
        self._init_db()

    def _get_conn(self) -> sqlite3.Connection:
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(self.db_path), timeout=10.0)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        return conn

    def _init_db(self) -> None:
        try:
            with self._get_conn() as conn:
                conn.execute(
                    """
                    CREATE TABLE IF NOT EXISTS idempotent_ops (
                        idempotency_key TEXT PRIMARY KEY,
                        response_json TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        client_id TEXT
                    )
                    """
                )
                try:
                    conn.execute("ALTER TABLE idempotent_ops ADD COLUMN client_id TEXT")
                except sqlite3.OperationalError:
                    pass
                conn.execute(
                    "CREATE INDEX IF NOT EXISTS idx_idempotent_ops_created ON idempotent_ops(created_at)"
                )
                conn.execute(
                    "CREATE INDEX IF NOT EXISTS idx_idempotent_ops_client_id ON idempotent_ops(client_id)"
                )
            try:
                self.db_path.chmod(0o660)
            except Exception:
                pass
        except Exception as e:
            logging.getLogger("xray_api").warning(
                "Failed to initialize idempotency db at %s: %s", self.db_path, e
            )

    def get(self, key: str, default: Any = None) -> Any:
        try:
            with self._get_conn() as conn:
                cur = conn.execute(
                    "SELECT response_json FROM idempotent_ops WHERE idempotency_key = ?",
                    (key,),
                )
                row = cur.fetchone()
                if row:
                    return json.loads(row[0])
        except Exception as e:
            logging.getLogger("xray_api").warning("Failed to read idempotent op %s: %s", key, e)
        return default

    def set(self, key: str, response: Dict[str, Any]) -> None:
        try:
            now_ts = time.time()
            data_str = json.dumps(response)
            client_id_val = None
            if isinstance(response, dict):
                raw_cid = response.get("client_id")
                if raw_cid:
                    try:
                        client_id_val = str(uuid_lib.UUID(str(raw_cid).strip())).lower()
                    except Exception:
                        client_id_val = str(raw_cid).strip().lower()

            with self._get_conn() as conn:
                conn.execute(
                    """
                    INSERT INTO idempotent_ops (idempotency_key, response_json, created_at, client_id)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(idempotency_key) DO UPDATE SET
                        response_json=excluded.response_json,
                        created_at=excluded.created_at,
                        client_id=excluded.client_id
                    """,
                    (key, data_str, now_ts, client_id_val),
                )
                cur = conn.execute("SELECT COUNT(*) FROM idempotent_ops")
                count = cur.fetchone()[0]
                if count > 2000:
                    conn.execute(
                        """
                        DELETE FROM idempotent_ops WHERE idempotency_key IN (
                            SELECT idempotency_key FROM idempotent_ops
                            ORDER BY created_at ASC LIMIT 500
                        )
                        """
                    )
        except Exception as e:
            logging.getLogger("xray_api").warning("Failed to persist idempotent op %s: %s", key, e)

    def __contains__(self, key: str) -> bool:
        return self.get(key) is not None

    def __getitem__(self, key: str) -> Dict[str, Any]:
        val = self.get(key)
        if val is None:
            raise KeyError(key)
        return val

    def __setitem__(self, key: str, response: Dict[str, Any]) -> None:
        self.set(key, response)

    def __len__(self) -> int:
        try:
            with self._get_conn() as conn:
                cur = conn.execute("SELECT COUNT(*) FROM idempotent_ops")
                return cur.fetchone()[0]
        except Exception:
            return 0

    def keys(self) -> list[str]:
        try:
            with self._get_conn() as conn:
                cur = conn.execute("SELECT idempotency_key FROM idempotent_ops ORDER BY created_at ASC")
                return [row[0] for row in cur.fetchall()]
        except Exception:
            return []

    def items(self) -> list[tuple[str, Dict[str, Any]]]:
        try:
            with self._get_conn() as conn:
                cur = conn.execute("SELECT idempotency_key, response_json FROM idempotent_ops")
                res = []
                for k, v_str in cur.fetchall():
                    try:
                        res.append((k, json.loads(v_str)))
                    except Exception:
                        pass
                return res
        except Exception:
            return []

    def evict_by_client_id(self, client_id: str) -> None:
        try:
            norm_target = str(uuid_lib.UUID(client_id.strip())).lower()
        except Exception:
            norm_target = client_id.strip().lower()

        try:
            with self._get_conn() as conn:
                conn.execute(
                    "DELETE FROM idempotent_ops WHERE client_id = ?",
                    (norm_target,),
                )
                legacy_cur = conn.execute(
                    "SELECT idempotency_key, response_json FROM idempotent_ops WHERE client_id IS NULL"
                )
                keys = []
                for k, v_str in legacy_cur.fetchall():
                    try:
                        data = json.loads(v_str)
                        if isinstance(data, dict):
                            raw_cid = data.get("client_id")
                            if raw_cid:
                                try:
                                    norm_cid = str(uuid_lib.UUID(str(raw_cid).strip())).lower()
                                except Exception:
                                    norm_cid = str(raw_cid).strip().lower()
                                if norm_cid == norm_target:
                                    keys.append(k)
                    except Exception:
                        pass
                if keys:
                    conn.executemany("DELETE FROM idempotent_ops WHERE idempotency_key = ?", [(k,) for k in keys])
        except Exception as e:
            logging.getLogger("xray_api").warning("Failed to evict idempotent ops for client %s: %s", client_id, e)

    def pop(self, key: str, default: Any = None) -> Any:
        try:
            val = self.get(key)
            if val is not None:
                with self._get_conn() as conn:
                    conn.execute("DELETE FROM idempotent_ops WHERE idempotency_key = ?", (key,))
                return val
        except Exception:
            pass
        return default


def _resolve_idempotency_db_path() -> Path:
    env_path = os.getenv("IDEMPOTENCY_DB_PATH")
    if env_path:
        return Path(env_path)
    if os.getenv("CLIENTS_FILE_PATH"):
        return Path(os.getenv("CLIENTS_FILE_PATH")).parent / "idempotency.db"
    default_path = Path("/etc/just1knode/idempotency.db")
    try:
        default_path.parent.mkdir(parents=True, exist_ok=True)
        return default_path
    except (PermissionError, OSError):
        import tempfile
        return Path(tempfile.gettempdir()) / "xray_idempotency.db"


# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("xray_api")

# Configuration from environment / config file:
# Must be loaded BEFORE resolving paths or initializing stores
CONFIG_ENV_FILE = "/etc/xray-api/config.env"
if os.path.exists(CONFIG_ENV_FILE):
    try:
        with open(CONFIG_ENV_FILE, "r", encoding="utf-8") as f:
            for line in f:
                line_str = line.strip()
                if line_str and not line_str.startswith("#") and "=" in line_str:
                    k, v = line_str.split("=", 1)
                    k = k.strip()
                    v = v.strip().strip("'\"")
                    if k not in os.environ:
                        os.environ[k] = v
    except Exception as e:
        logger.warning("Failed to load %s: %s", CONFIG_ENV_FILE, e)

API_KEY = os.getenv("XRAY_API_KEY", "")
GRPC_HOST = os.getenv("XRAY_GRPC_HOST", "127.0.0.1")
GRPC_PORT = int(os.getenv("XRAY_GRPC_PORT", "10085"))
XRAY_CONFIG_PATH = Path(os.getenv("XRAY_CONFIG_PATH", "/usr/local/etc/xray/config.json"))
CLIENTS_FILE_PATH = Path(os.getenv("CLIENTS_FILE_PATH", "/etc/just1knode/clients.json"))
STATE_FILE_PATH = Path(os.getenv("STATE_FILE_PATH", "/etc/just1knode/state.json"))


def _links_file_path() -> Path:
    env_p = os.getenv("LINKS_FILE_PATH")
    if env_p:
        return Path(env_p)
    return STATE_FILE_PATH.parent / "links.json"


def _apply_pending_path() -> Path:
    env_p = os.getenv("APPLY_PENDING_PATH")
    if env_p:
        return Path(env_p)
    return STATE_FILE_PATH.parent / ".apply_pending"


def _module_errors_path() -> Path:
    env_p = os.getenv("MODULE_ERRORS_PATH")
    if env_p:
        return Path(env_p)
    return STATE_FILE_PATH.parent / "module_errors.json"


def _atomic_write_json(path: Path, payload: Any, mode: int = 0o660) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_str = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    tmp_path = Path(tmp_str)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fp:
            json.dump(payload, fp, indent=2, ensure_ascii=False)
            fp.write("\n")
            fp.flush()
        try:
            os.chmod(tmp_path, mode)
        except Exception:
            pass
        os.replace(tmp_path, path)
    except Exception:
        try:
            tmp_path.unlink(missing_ok=True)
        except Exception:
            pass
        raise


def _load_links_data() -> Dict[str, Any]:
    lp = _links_file_path()
    if lp.exists():
        try:
            data = json.loads(lp.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return data
        except Exception as e:
            logger.warning("Could not read links.json at %s: %s", lp, e)
    return {}


def _load_module_errors() -> Dict[str, str]:
    mp = _module_errors_path()
    if mp.exists():
        try:
            data = json.loads(mp.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return {str(k): str(v) for k, v in data.items()}
        except Exception as e:
            logger.debug("Could not read module_errors.json: %s", e)
    return {}


def _load_traffic_limit_summary() -> Optional[Dict[str, Any]]:
    tl_cfg = STATE_FILE_PATH.parent / "traffic_limit.json"
    if not tl_cfg.exists():
        return None
    try:
        data = json.loads(tl_cfg.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            return {
                "enabled": True,
                "limit_gb": data.get("limit_gb"),
                "reset_day": data.get("reset_day", 1),
                "exceeded": (STATE_FILE_PATH.parent / "traffic_limit_exceeded").exists(),
            }
    except Exception:
        pass
    return None


def _write_apply_pending(reason: str) -> bool:
    ap = _apply_pending_path()
    if not ap.parent.exists():
        return False
    try:
        _atomic_write_json(ap, {"reason": reason, "ts": int(time.time())}, mode=0o660)
        return True
    except Exception as e:
        logger.warning("Could not write apply pending trigger %s: %s", ap, e)
        return False

BOT_STATUS_WRITE_INTERVAL = 30.0
_last_bot_status_ts = 0.0
_last_bot_status_ip = ""


def _record_bot_activity(bot_ip: Optional[str] = None) -> None:
    """Persist throttled last-seen bot heartbeat in bot_status.json for root CLI UI."""
    global _last_bot_status_ts, _last_bot_status_ip
    now = time.time()
    clean_ip = (bot_ip or "").strip()
    if (
        (now - _last_bot_status_ts) < BOT_STATUS_WRITE_INTERVAL
        and clean_ip == _last_bot_status_ip
        and (STATE_FILE_PATH.parent / "bot_status.json").exists()
    ):
        return
    if not STATE_FILE_PATH.parent.exists():
        return
    status_path = STATE_FILE_PATH.parent / "bot_status.json"
    tmp_path = STATE_FILE_PATH.parent / "bot_status.json.tmp"
    payload = {
        "connected": True,
        "last_seen_at": int(now),
        "bot_ip": clean_ip,
    }
    try:
        tmp_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        try:
            tmp_path.chmod(0o640)
        except Exception:
            pass
        tmp_path.replace(status_path)
        _last_bot_status_ts = now
        _last_bot_status_ip = clean_ip
    except Exception:
        try:
            tmp_path.unlink(missing_ok=True)
        except Exception:
            pass


def get_bot_status() -> Dict[str, Any]:
    """Read persisted bot heartbeat status safely without raising."""
    status_path = STATE_FILE_PATH.parent / "bot_status.json"
    if status_path.exists():
        try:
            data = json.loads(status_path.read_text(encoding="utf-8"))
            if isinstance(data, dict) and data.get("last_seen_at"):
                return {
                    "connected": True,
                    "last_seen_at": data.get("last_seen_at"),
                    "bot_ip": data.get("bot_ip") or "",
                }
        except Exception:
            pass
    return {"connected": False, "last_seen_at": None, "bot_ip": ""}

completed_idempotent_ops = DurableIdempotencyStore(_resolve_idempotency_db_path())

# Concurrency locks for in-flight idempotent operations (prevents check-then-mutate races)
_inflight_op_locks: Dict[str, asyncio.Lock] = {}
_inflight_master_lock = asyncio.Lock()


async def _get_inflight_op_lock(key: str) -> asyncio.Lock:
    async with _inflight_master_lock:
        if key not in _inflight_op_locks:
            if len(_inflight_op_locks) > 1000:
                unlocked_keys = [k for k, v in _inflight_op_locks.items() if not v.locked()]
                for k in unlocked_keys:
                    _inflight_op_locks.pop(k, None)
            _inflight_op_locks[key] = asyncio.Lock()
        return _inflight_op_locks[key]


def _mask_uuid(val: str) -> str:
    if not val or len(val) < 8:
        return "***"
    return f"{val[:8]}...masked"


def get_secret_base_path() -> str:
    """Discovers canonical secret XHTTP base path configured for this RU hub node.

    Strictly matches managed tags ('just1k-wl-*').
    """
    if STATE_FILE_PATH.exists():
        try:
            with open(STATE_FILE_PATH, "r", encoding="utf-8") as f:
                st = json.load(f)
                if isinstance(st, dict) and st.get("secret_base_path"):
                    return st["secret_base_path"]
        except Exception as e:
            logger.warning("Could not read secret_base_path from %s: %s", STATE_FILE_PATH, e)

    # Fallback: check config.json inbounds path prioritizing managed namespaced tags
    if XRAY_CONFIG_PATH.exists():
        try:
            with open(XRAY_CONFIG_PATH, "r", encoding="utf-8") as f:
                cfg = json.load(f)
                inbounds = cfg.get("inbounds", [])
                # Priority 1: tags matching just1k-wl-default
                for ib in inbounds:
                    tag = ib.get("tag", "")
                    if tag == "just1k-wl-default":
                        path = ib.get("streamSettings", {}).get("xhttpSettings", {}).get("path", "")
                        if not path:
                            path = (
                                ib.get("streamSettings", {}).get("httpSettings", {}).get("path", "")
                            )
                        if path and path.startswith("/"):
                            parts = [p for p in path.strip("/").split("/") if p]
                            if parts:
                                return f"/{parts[0]}"
                # Priority 2: tags starting strictly with just1k-wl- (managed namespace)
                for ib in inbounds:
                    tag = ib.get("tag", "")
                    if tag.startswith("just1k-wl-"):
                        path = ib.get("streamSettings", {}).get("xhttpSettings", {}).get("path", "")
                        if not path:
                            path = (
                                ib.get("streamSettings", {}).get("httpSettings", {}).get("path", "")
                            )
                        if path and path.startswith("/"):
                            parts = [p for p in path.strip("/").split("/") if p]
                            if parts:
                                return f"/{parts[0]}"
        except Exception:
            pass

    return os.getenv("WHITE_INTERNET_PATH", "/assets/v1")


def get_cdn_domain() -> Optional[str]:
    """Resolves CDN domain configured for this Origin node.

    1. Checks CDN_DOMAIN environment variable.
    2. Reads cdn_domain from STATE_FILE_PATH (/etc/just1knode/state.json).
    3. Fallback to WHITE_INTERNET_CDN_DOMAIN environment variable.
    """
    env_cdn = os.getenv("CDN_DOMAIN")
    if env_cdn and env_cdn.strip():
        return env_cdn.strip()

    if STATE_FILE_PATH.exists():
        try:
            with open(STATE_FILE_PATH, "r", encoding="utf-8") as f:
                st = json.load(f)
                if isinstance(st, dict):
                    if st.get("cdn_domain"):
                        return str(st["cdn_domain"]).strip()
                    modules = st.get("modules")
                    if isinstance(modules, dict):
                        for m_key, m_cfg in modules.items():
                            if str(m_key).startswith("cdn_") and isinstance(m_cfg, dict) and m_cfg.get("enabled"):
                                cand = m_cfg.get("cdn_domain") or m_cfg.get("domain")
                                if cand:
                                    return str(cand).strip()
        except Exception as e:
            logger.warning("Could not read cdn_domain from %s: %s", STATE_FILE_PATH, e)

    fallback = os.getenv("WHITE_INTERNET_CDN_DOMAIN")
    if fallback and fallback.strip():
        return fallback.strip()

    return None


def get_sub_path_prefix() -> Optional[str]:
    """Resolves subscription path prefix configured for this Origin node.

    1. Checks WHITE_INTERNET_SUB_PATH_PREFIX environment variable.
    2. Reads sub_path_prefix from STATE_FILE_PATH (/etc/just1knode/state.json).
    3. Fallback to /sub/wl.
    """
    env_prefix = os.getenv("WHITE_INTERNET_SUB_PATH_PREFIX")
    if env_prefix and env_prefix.strip():
        val = env_prefix.strip().rstrip("/")
        return val if val.startswith("/") else f"/{val}"

    if STATE_FILE_PATH.exists():
        try:
            with open(STATE_FILE_PATH, "r", encoding="utf-8") as f:
                st = json.load(f)
                if isinstance(st, dict) and st.get("sub_path_prefix"):
                    val = str(st["sub_path_prefix"]).strip().rstrip("/")
                    return val if val.startswith("/") else f"/{val}"
        except Exception as e:
            logger.warning("Could not read sub_path_prefix from %s: %s", STATE_FILE_PATH, e)

    return "/sub/wl"


def get_all_managed_inbounds() -> List[str]:
    """Dynamically discover all configured Just1k user inbounds without mixing tunnel roles."""
    node_meta = get_node_state_metadata()
    node_role = str(node_meta.get("role") or "").strip().lower()
    if node_role in ("eu_hub", "exit_node"):
        return []

    discovered_tags: List[str] = []

    # 1. Read from Xray config.json if available
    config_tags: List[str] = []
    config_read_ok = False
    if XRAY_CONFIG_PATH.exists():
        try:
            with open(XRAY_CONFIG_PATH, "r", encoding="utf-8") as f:
                cfg = json.load(f)
                for ib in cfg.get("inbounds", []):
                    protocol = ib.get("protocol", "").lower()
                    tag = ib.get("tag", "")
                    # Match managed VLESS inbounds strictly by just1k-wl- and just1k-vless- namespaces
                    if protocol in ("vless", "vmess") and (
                        tag.startswith("just1k-wl-")
                        or tag.startswith("just1k-vless-")
                        or tag in ("just1k-wl-default", "just1k-vless-direct")
                    ):
                        config_tags.append(tag)
                config_read_ok = True
        except Exception as e:
            logger.warning("Could not load inbounds from %s: %s", XRAY_CONFIG_PATH, e)

    # Prioritize default tag if present
    for tag in config_tags:
        if tag == "just1k-wl-default" and tag not in discovered_tags:
            discovered_tags.insert(0, tag)
        elif tag not in discovered_tags:
            discovered_tags.append(tag)

    is_ru_xhttp_hub = False
    extra_cdn_tags: List[str] = []
    if STATE_FILE_PATH.exists():
        try:
            with open(STATE_FILE_PATH, "r", encoding="utf-8") as f:
                sdata = json.load(f)
                if isinstance(sdata, dict):
                    r_val = sdata.get("role")
                    modules = sdata.get("modules") if isinstance(sdata.get("modules"), dict) else {}
                    for m_key, m_cfg in modules.items():
                        if not (isinstance(m_cfg, dict) and m_cfg.get("enabled")):
                            continue
                        if m_key == "vless_xhttp" or str(m_key).startswith("cdn_"):
                            if r_val == "ru_hub":
                                is_ru_xhttp_hub = True
                            if str(m_key).startswith("cdn_") and m_cfg.get("tag"):
                                extra_cdn_tags.append(str(m_cfg["tag"]))
        except Exception:
            pass
    if is_ru_xhttp_hub and (not config_read_ok or not config_tags):
        if "just1k-wl-default" not in discovered_tags:
            discovered_tags.insert(0, "just1k-wl-default")
        for ct in extra_cdn_tags:
            if ct not in discovered_tags:
                discovered_tags.append(ct)

    # 2. Fallback to environment override
    if not discovered_tags:
        raw = os.getenv("XRAY_INBOUND_TAGS")
        if raw:
            tags = [t.strip() for t in raw.split(",") if t.strip()]
            if tags:
                discovered_tags = tags

    return discovered_tags


def _get_xhttp_location_routes() -> List[Dict[str, Any]]:
    """Return concrete active XHTTP inbound paths/ports for multi-CDN and multi-hub bot discovery."""
    routes: List[Dict[str, Any]] = []
    if not XRAY_CONFIG_PATH.exists():
        return routes

    node_meta = get_node_state_metadata()
    modules = node_meta.get("modules") if isinstance(node_meta.get("modules"), dict) else {}
    enabled_cdns = [
        k for k, v in modules.items()
        if str(k).startswith("cdn_") and isinstance(v, dict) and v.get("enabled") is True
    ]

    try:
        with open(XRAY_CONFIG_PATH, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception:
        return routes

    for ib in cfg.get("inbounds", []):
        if not isinstance(ib, dict):
            continue
        tag = str(ib.get("tag") or "")
        if not tag.startswith("just1k-wl-"):
            continue
        ss = ib.get("streamSettings") if isinstance(ib.get("streamSettings"), dict) else {}
        if ss.get("network") != "xhttp":
            continue
        xs = ss.get("xhttpSettings") if isinstance(ss.get("xhttpSettings"), dict) else {}
        path = str(xs.get("path") or "")
        if not path:
            continue
        loc_code = None
        cdn_hint = None
        if tag.startswith("just1k-wl-inbound-"):
            raw_suffix = tag[len("just1k-wl-inbound-"):]
            if "__" in raw_suffix:
                loc_code, cdn_hint = raw_suffix.split("__", 1)
            else:
                loc_code = raw_suffix
                cdn_hint = enabled_cdns[0] if enabled_cdns else None
        elif tag == "just1k-wl-default":
            cdn_hint = "cdn_yandex"
        elif tag == "just1k-wl-turboflare":
            cdn_hint = "cdn_turboflare"
        routes.append({
            "inbound_tag": tag,
            "port": ib.get("port"),
            "path": path,
            "location_code": loc_code,
            "cdn": cdn_hint,
            "uplink_http_method": xs.get("uplinkHTTPMethod"),
            "uplink_data_placement": xs.get("uplinkDataPlacement"),
        })
    return routes


def is_wl_inbound_tag(t: str) -> bool:
    """Check if tag belongs to white_internet, strictly excluding internal relay tunnels."""
    return t.startswith("just1k-wl-") or t == "just1k-wl-default"


def resolve_effective_service(service: Optional[str] = None) -> str:
    """Deterministically resolves the canonical service namespace ('vless' or 'white_internet')."""
    if service:
        s = str(service).strip().lower()
        if s in ("wl", "white_internet"):
            return "white_internet"
        if s in ("vless", "xray_vless"):
            return "vless"
        return s
    discovered = get_all_managed_inbounds()
    if any(is_wl_inbound_tag(t) for t in discovered):
        return "white_internet"
    return "vless"


def get_target_inbounds(service: Optional[str] = None) -> List[str]:
    """Dynamically discover configured Just1k inbounds strictly filtering by service."""
    discovered_tags = get_all_managed_inbounds()

    effective = resolve_effective_service(service) if service is not None else None
    if effective == "vless":
        return [t for t in discovered_tags if t.startswith("just1k-vless-") or t == "just1k-vless-direct"]
    if effective == "white_internet":
        return [t for t in discovered_tags if is_wl_inbound_tag(t)]

    # If service is unspecified, do not mix namespaces:
    # If white_internet inbounds exist, default to white_internet to prevent accidental leakage into vless-direct.
    wl_inbounds = [t for t in discovered_tags if is_wl_inbound_tag(t)]
    if wl_inbounds:
        return wl_inbounds

    vless_inbounds = [t for t in discovered_tags if t.startswith("just1k-vless-") or t == "just1k-vless-direct"]
    if vless_inbounds:
        return vless_inbounds

    return discovered_tags


grpc_client = XrayGrpcClient(host=GRPC_HOST, port=GRPC_PORT)
epoch_manager = EpochManager()
client_store = ClientStore(CLIENTS_FILE_PATH)

# Node synchronization state (Central DB is authoritative SSOT; local cache is ephemeral hint)
node_sync_state: Dict[str, Any] = {
    "status": "unsynchronized",
    "last_synced_at": None,
    "last_client_sync_at": None,
}


def get_inbound_flow(tag: str) -> str:
    """Returns protocol flow for given inbound tag. Direct VLESS TLS requires xtls-rprx-vision."""
    if tag.startswith("just1k-vless-") or tag == "just1k-vless-direct":
        return "xtls-rprx-vision"
    return ""


def restore_persisted_clients_to_xray() -> int:
    """Restores active persisted clients from disk into Xray RAM as temporary crash-recovery hint.

    The node remains in 'unsynchronized' state until Central DB reconciliation runs.
    """
    entries = client_store.load_client_entries()
    if not entries:
        logger.info("No active persisted clients to restore.")
        return 0

    restored_unique = 0
    restored_registrations = 0
    for client_uuid, meta in entries.items():
        if not isinstance(meta, dict):
            continue
        service_states = meta.get("service_states")
        if isinstance(service_states, dict) and service_states:
            active_services = [
                s for s, st in service_states.items()
                if isinstance(st, dict) and st.get("is_active") is True and not st.get("tombstone", False)
            ]
        else:
            if not meta.get("is_active", True) or meta.get("tombstone", False):
                continue
            active_services = meta.get("services") or ([meta.get("service")] if meta.get("service") else [None])

        if not active_services:
            continue

        target_inbounds: List[str] = []
        for s in active_services:
            for tag in get_target_inbounds(service=s):
                if tag not in target_inbounds:
                    target_inbounds.append(tag)

        user_restored = False
        for tag in target_inbounds:
            try:
                grpc_client.add_user(tag, client_uuid, flow=get_inbound_flow(tag))
                restored_registrations += 1
                user_restored = True
            except Exception as e:
                logger.warning(
                    "Failed to restore client %s on inbound %s: %s", _mask_uuid(client_uuid), tag, e
                )
        if user_restored or not target_inbounds:
            restored_unique += 1

    logger.info(
        "Restored %d active client registrations across services as ephemeral hints.",
        restored_registrations,
    )
    return restored_unique


def sync_active_users_with_epoch(current_epoch: Optional[str]) -> None:
    """Ensures in-memory active users set is aligned with current Xray epoch.

    If epoch changes (Xray restart), clears in-memory active users and restores
    valid persisted clients from client_store into Xray RAM once gRPC is healthy.
    """
    if not current_epoch:
        return
    if grpc_client._active_users_epoch != current_epoch:
        if grpc_client.is_healthy():
            logger.info(
                "Xray instance epoch changed (%s -> %s). Invalidating active users cache and restoring active persisted clients.",
                grpc_client._active_users_epoch,
                current_epoch,
            )
            grpc_client.clear_active_users()
            restore_persisted_clients_to_xray()
            grpc_client._active_users_epoch = current_epoch
        else:
            logger.debug(
                "Xray instance epoch changed to %s, but gRPC is not healthy yet. Deferring client restoration.",
                current_epoch,
            )


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup: restore clients to Xray strictly as ephemeral hints
    node_sync_state["status"] = "unsynchronized"
    node_sync_state["last_synced_at"] = None
    target_inbounds = get_target_inbounds()
    logger.info("Starting Just1kBot Xray API Agent on inbounds: %s", target_inbounds)
    try:
        retries = 5
        while retries > 0:
            if grpc_client.is_healthy():
                current_epoch = epoch_manager.get_current_running_epoch() if epoch_manager else None
                if not current_epoch and epoch_manager:
                    current_epoch = epoch_manager.load_state().get("node_epoch")
                sync_active_users_with_epoch(current_epoch)
                break
            retries -= 1
            if retries > 0:
                await asyncio.sleep(1)
        else:
            logger.warning(
                "Xray gRPC is not immediately available at startup. Clients will sync on demand."
            )
    except Exception as e:
        logger.error("Startup client restoration error: %s", e)
    yield
    # Shutdown
    grpc_client.close()


app = FastAPI(
    title="Just1kBot Xray API Agent",
    description="Autonomous server agent for Xray management and traffic stats",
    version="2.0.0",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
    lifespan=lifespan,
)


@app.middleware("http")
async def track_bot_activity_middleware(request: Request, call_next):
    if request.url.path.startswith("/v1/"):
        expected_key = os.getenv("XRAY_API_KEY") or API_KEY
        req_key = request.headers.get("X-API-Key")
        if expected_key and req_key and secrets.compare_digest(req_key, expected_key):
            try:
                _record_bot_activity(request.client.host if request.client else "")
            except Exception:
                pass
    return await call_next(request)


# Security dependency
def verify_api_key(x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    expected_key = os.getenv("XRAY_API_KEY") or API_KEY
    if not expected_key:
        logger.error("XRAY_API_KEY is not configured on the node")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Node API key is not configured",
        )
    if not x_api_key or not secrets.compare_digest(x_api_key, expected_key):
        logger.warning(
            "Unauthorized access attempt with X-API-Key: %s", "present" if x_api_key else "missing"
        )
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing X-API-Key",
        )
    return True


# Models
class ClientSyncRequest(BaseModel):
    client_id: Optional[str] = Field(None, description="Client UUID")
    uuid: Optional[str] = Field(None, description="Client UUID alias")
    desired_state: Optional[str] = Field(None, description="Target state: 'active' or 'disabled'")
    is_active: Optional[bool] = Field(None, description="Target state boolean alias")
    state: Optional[str] = Field(None, description="Target state alias")
    version: Optional[int] = Field(None, description="Monotonic desired version")
    email: Optional[str] = Field(None, description="Optional client email/identifier")
    expected_node_epoch: Optional[str] = Field(None, description="Optional node epoch fencing")
    idempotency_key: Optional[str] = Field(
        None, description="Optional idempotency key for durable retry"
    )
    service: Optional[Literal["vless", "white_internet", "wl"]] = Field(
        None, description="Optional service filter: 'vless' or 'white_internet'"
    )

    @property
    def effective_state(self) -> str:
        return self.desired_state or "active"

    @model_validator(mode="before")
    @classmethod
    def resolve_fields(cls, values: Any) -> Any:
        if isinstance(values, dict):
            cid = values.get("client_id") or values.get("uuid")
            if not cid:
                raise ValueError("client_id or uuid is required")
            try:
                parsed_uuid = uuid_lib.UUID(str(cid).strip())
                values["client_id"] = str(parsed_uuid).lower()
            except ValueError:
                raise ValueError(f"Invalid UUID format: {cid}") from None

            state = values.get("desired_state") or values.get("state")
            is_act = values.get("is_active")
            if state is not None:
                s = str(state).strip().lower()
                if s not in ("active", "disabled"):
                    raise ValueError("desired_state must be 'active' or 'disabled'")
                values["desired_state"] = s
                values["state"] = s
            elif is_act is not None:
                resolved = "active" if bool(is_act) else "disabled"
                values["desired_state"] = resolved
                values["state"] = resolved
            else:
                values["desired_state"] = "active"
                values["state"] = "active"

            srv = values.get("service")
            if srv is not None:
                s_str = str(srv).strip().lower()
                if s_str not in ("vless", "white_internet", "wl"):
                    raise ValueError(f"Invalid service '{srv}'. Must be 'vless' or 'white_internet'")
                values["service"] = s_str
        return values


def get_node_state_metadata() -> Dict[str, Any]:
    """Load node state.json metadata safely without locking."""
    if STATE_FILE_PATH.exists():
        try:
            with open(STATE_FILE_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    return data
        except Exception as e:
            logger.debug("Could not read node state metadata: %s", e)
    return {}


class InventoryRequest(BaseModel):
    client_ids: Optional[List[str]] = Field(
        None, description="Optional list of client UUIDs to probe"
    )
    service: Optional[Literal["vless", "white_internet", "wl"]] = Field(
        None, description="Optional service filter: 'vless' or 'white_internet'"
    )


# Endpoints
@app.get("/healthz")
@app.get("/health")
def healthcheck(response: Response) -> Dict[str, Any]:
    """
    Lightweight liveness and readiness probe for external monitoring (e.g. Uptime Kuma, Prometheus, Consul).
    Does not require an API key and does not expose confidential node metadata or client lists.
    Fail-closed: returns HTTP 200 when Xray core is running and gRPC responds, or HTTP 503 otherwise.
    """
    grpc_ok = grpc_client.is_healthy()
    pid, starttime, boot_id, running_epoch = (
        epoch_manager.get_process_and_epoch() if epoch_manager else (None, None, None, None)
    )
    is_running = bool(
        grpc_ok
        and running_epoch is not None
        and pid is not None
        and starttime is not None
        and boot_id is not None
    )
    if not is_running:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    return {
        "ok": is_running,
        "status": "ok" if is_running else "error",
        "service": "xray-api",
        "xray_running": is_running,
        "grpc_ok": bool(grpc_ok),
    }


@app.get("/v1/health")
def get_health(response: Response, _: bool = Depends(verify_api_key)) -> Dict[str, Any]:
    """
    Checks service health, Xray core gRPC connectivity, active inbounds, relays, and synchronization status.
    Fail-closed: returns HTTP 503 if Xray is not running, gRPC is down, or /proc process inspection fails.
    """
    grpc_ok = grpc_client.is_healthy()
    store_corrupted = False
    try:
        active_clients = client_store.load_clients()
    except ClientStoreCorruptedError as e:
        logger.critical("Health check detected client store corruption: %s", e)
        active_clients = set()
        store_corrupted = True

    target_inbounds = get_all_managed_inbounds()
    secret_path = get_secret_base_path()

    node_meta = get_node_state_metadata()
    domain = str(node_meta.get("domain") or "")
    role = str(node_meta.get("role") or "")
    modules = node_meta.get("modules") if isinstance(node_meta.get("modules"), dict) else {}
    has_wl_module = any(
        isinstance(modules.get(k), dict) and bool(modules[k].get("enabled"))
        for k in modules
        if k == "vless_xhttp" or str(k).startswith("cdn_")
    )
    has_vless_module = isinstance(modules.get("vless_tls"), dict) and bool(
        modules["vless_tls"].get("enabled")
    )
    detected_services: List[str] = []
    if (
        any(t.startswith("just1k-wl-") for t in target_inbounds)
        or (role == "ru_hub" and has_wl_module)
    ):
        detected_services.append("white_internet")
    if (
        any(t.startswith("just1k-vless-") or t == "just1k-vless-direct" for t in target_inbounds)
        or (role == "ru_hub" and has_vless_module)
    ):
        detected_services.append("vless")
    if role == "eu_hub":
        detected_services.append("bridge_hub")
    elif role == "exit_node":
        detected_services.append("exit_node")

    capabilities: List[str] = []
    if "vless" in detected_services:
        capabilities.extend(["vless", "xray_vless"])
    if "white_internet" in detected_services:
        capabilities.append("white_internet")

    pid, starttime, boot_id, running_epoch = (
        epoch_manager.get_process_and_epoch() if epoch_manager else (None, None, None, None)
    )

    is_running = bool(
        grpc_ok
        and not store_corrupted
        and running_epoch is not None
        and pid is not None
        and starttime is not None
        and boot_id is not None
    )

    if not is_running:
        running_epoch = None
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    elif running_epoch:
        sync_active_users_with_epoch(running_epoch)

    disk_usage_info: Dict[str, Any] = {}
    try:
        total, used, free = shutil.disk_usage("/")
        disk_usage_info = {
            "total_bytes": total,
            "used_bytes": used,
            "free_bytes": free,
            "used_percent": round((used / total) * 100, 1) if total > 0 else 0.0,
        }
    except Exception as e:
        logger.debug("Failed to read disk usage: %s", e)

    bot_status = get_bot_status()
    module_errors = _load_module_errors()
    links_data = _load_links_data()
    traffic_limit = _load_traffic_limit_summary()

    return {
        "status": "ok" if is_running else "error",
        "xray_running": is_running,
        "grpc_ok": bool(grpc_ok),
        "active_clients_count": len(active_clients),
        "inbounds": target_inbounds,
        "services": detected_services,
        "capabilities": capabilities,
        "role": role,
        "domain": domain,
        "bridge_uuid": str(node_meta.get("tunnel_uuid") or ""),
        "modules": modules,
        "module_errors": module_errors,
        "links": links_data,
        "xhttp_locations": _get_xhttp_location_routes(),
        "traffic_limit": traffic_limit,
        "bot_connected": bool(bot_status.get("connected")),
        "bot_last_seen_at": bot_status.get("last_seen_at"),
        "secret_base_path": secret_path,
        "cdn_domain": get_cdn_domain(),
        "sub_path_prefix": get_sub_path_prefix(),
        "node_epoch": running_epoch if is_running else None,
        "boot_id": boot_id if is_running else None,
        "starttime": starttime if is_running else None,
        "sync_status": node_sync_state.get("status", "unsynchronized"),
        "synchronized": node_sync_state.get("status") == "synchronized",
        "last_synced_at": node_sync_state.get("last_synced_at"),
        "disk_usage": disk_usage_info,
    }


def _validate_fqdn_strict(value: str) -> str:
    dom = str(value or "").strip().lower().rstrip(".")
    if not dom or len(dom) > 253:
        raise ValueError("SNI domain must be non-empty FQDN")
    try:
        ipaddress.IPv4Address(dom)
        raise ValueError("Bare IP address is forbidden as SNI (Zero-Signature requires FQDN)")
    except ValueError as e:
        if "forbidden as SNI" in str(e):
            raise
    if not re.fullmatch(r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}", dom):
        raise ValueError(f"Invalid FQDN format for SNI: {dom}")
    return dom


def _validate_ipv4_strict(value: str) -> str:
    raw = str(value or "").strip()
    ipaddress.IPv4Address(raw)
    return raw


def _validate_uuid_strict(value: str) -> str:
    return str(uuid_lib.UUID(str(value or "").strip())).lower()


class BridgePeerSpec(BaseModel):
    id: Optional[str] = Field(default=None, max_length=64)
    tag: Optional[str] = Field(default=None, max_length=64)
    code: str = Field(..., min_length=1, max_length=32, pattern=r"^[a-zA-Z0-9_-]+$")
    name: Optional[str] = None
    ip: str
    port: int = Field(default=443, ge=1, le=65535)
    sni: str
    uuid: str
    is_default: bool = False
    route_user: Optional[str] = None

    @model_validator(mode="after")
    def validate_peer(self) -> "BridgePeerSpec":
        self.ip = _validate_ipv4_strict(self.ip)
        self.sni = _validate_fqdn_strict(self.sni)
        self.uuid = _validate_uuid_strict(self.uuid)
        self.code = self.code.strip().lower()
        return self


class SniRouteSpec(BaseModel):
    sni: str
    bridge_code: str = Field(..., min_length=1, max_length=32, pattern=r"^[a-zA-Z0-9_-]+$")

    @model_validator(mode="after")
    def validate_route(self) -> "SniRouteSpec":
        self.sni = _validate_fqdn_strict(self.sni)
        self.bridge_code = self.bridge_code.strip().lower()
        return self


class IncomingPeerSpec(BaseModel):
    code: Optional[str] = Field(default=None, max_length=32)
    ip: Optional[str] = None
    uuid: Optional[str] = None
    route_user: Optional[str] = None

    @model_validator(mode="after")
    def validate_incoming(self) -> "IncomingPeerSpec":
        if self.ip is not None and self.ip.strip():
            self.ip = _validate_ipv4_strict(self.ip)
        if self.uuid is not None and self.uuid.strip():
            self.uuid = _validate_uuid_strict(self.uuid)
        return self


class HubRouteSpec(BaseModel):
    code: Optional[str] = Field(default=None, max_length=32)
    ingress_uuid: Optional[str] = None
    route_user: str = Field(..., min_length=1, max_length=128)
    exit_id: Optional[str] = Field(default=None, max_length=64)
    exit_code: str = Field(..., min_length=1, max_length=32, pattern=r"^[a-zA-Z0-9_-]+$")

    @model_validator(mode="after")
    def validate_hub_route(self) -> "HubRouteSpec":
        if self.ingress_uuid is not None and self.ingress_uuid.strip():
            self.ingress_uuid = _validate_uuid_strict(self.ingress_uuid)
        self.exit_code = self.exit_code.strip().lower()
        return self


class NodeLinksSectionSpec(BaseModel):
    bridges: List[BridgePeerSpec] = Field(default_factory=list)
    sni_routes: List[SniRouteSpec] = Field(default_factory=list)
    locations: List[Dict[str, Any]] = Field(default_factory=list)


class NodeLinksUpdateRequest(BaseModel):
    standard: Optional[NodeLinksSectionSpec] = None
    bi: Optional[NodeLinksSectionSpec] = None
    exit_nodes: Optional[List[BridgePeerSpec]] = None
    allowed_ru_ips: Optional[List[str]] = None
    allowed_hub_ips: Optional[List[str]] = None
    incoming_ru_hubs: Optional[List[IncomingPeerSpec]] = None
    incoming_hubs: Optional[List[IncomingPeerSpec]] = None
    routes: Optional[List[HubRouteSpec]] = None

    @model_validator(mode="after")
    def validate_ip_lists(self) -> "NodeLinksUpdateRequest":
        if self.allowed_ru_ips is not None:
            self.allowed_ru_ips = [_validate_ipv4_strict(x) for x in self.allowed_ru_ips]
        if self.allowed_hub_ips is not None:
            self.allowed_hub_ips = [_validate_ipv4_strict(x) for x in self.allowed_hub_ips]
        return self


@app.get("/v1/node/status")
def get_node_status_endpoint(_: bool = Depends(verify_api_key)) -> Dict[str, Any]:
    """Read-only v2 hub auto-discovery metadata (role, modules, errors, links, bot)."""
    node_meta = get_node_state_metadata()
    modules = node_meta.get("modules") if isinstance(node_meta.get("modules"), dict) else {}
    bot_status = get_bot_status()
    return {
        "status": "ok",
        "role": str(node_meta.get("role") or "unconfigured"),
        "country_code": str(node_meta.get("country_code") or ""),
        "domain": str(node_meta.get("domain") or ""),
        "cdn_domain": get_cdn_domain(),
        "sub_path_prefix": get_sub_path_prefix(),
        "secret_base_path": get_secret_base_path(),
        "bridge_uuid": str(node_meta.get("tunnel_uuid") or ""),
        "modules": modules,
        "module_errors": _load_module_errors(),
        "links": _load_links_data(),
        "xhttp_locations": _get_xhttp_location_routes(),
        "inbounds": get_all_managed_inbounds(),
        "traffic_limit": _load_traffic_limit_summary(),
        "bot_connected": bool(bot_status.get("connected")),
        "bot_last_seen_at": bot_status.get("last_seen_at"),
    }


@app.put("/v1/node/links")
def update_node_links(
    req: NodeLinksUpdateRequest,
    _: bool = Depends(verify_api_key),
) -> Dict[str, Any]:
    """Atomically saves Admin-defined node topology links and queues root config apply."""
    node_meta = get_node_state_metadata()
    role = str(node_meta.get("role") or "unconfigured")
    payload = req.model_dump(exclude_none=True)

    lp = _links_file_path()
    try:
        _atomic_write_json(lp, payload, mode=0o660)
    except Exception as exc:
        logger.error("Failed to write links.json at %s: %s", lp, exc)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to save links: {exc}",
        ) from exc

    queued = _write_apply_pending("links_updated")
    return {
        "status": "ok",
        "role": role,
        "apply_queued": queued,
        "links": payload,
    }


@app.get("/v1/clients/list")
def list_clients(_: bool = Depends(verify_api_key)) -> Dict[str, Any]:
    """Returns list of currently active clients persisted on the node."""
    clients = list(client_store.load_clients())
    return {
        "status": "ok",
        "count": len(clients),
        "clients": clients,
    }


def _get_host_net_bytes() -> tuple[int, int]:
    """Reads cumulative host interface traffic (tx, rx) excluding loopback and virtual interfaces."""
    tx_raw = 0
    rx_raw = 0
    proc_net = "/proc/net/dev"
    if os.path.exists(proc_net):
        try:
            with open(proc_net, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    if ":" not in line:
                        continue
                    name, stats = line.split(":", 1)
                    name = name.strip()
                    if name == "lo" or name.startswith(("docker", "veth", "br-", "wg", "tun", "tap")):
                        continue
                    cols = stats.split()
                    if len(cols) >= 9:
                        rx_raw += int(cols[0])
                        tx_raw += int(cols[8])
        except Exception:
            pass
    return tx_raw, rx_raw


@app.get("/v1/traffic/snapshot")
async def get_traffic_snapshot(_: bool = Depends(verify_api_key)) -> Dict[str, Any]:
    """
    Returns traffic stats aggregated by UUID/email with double-checked epoch atomicity.
    Fail-closed: requires genuine running process, valid starttime, boot_id, and matching epoch.
    """
    if not grpc_client.is_healthy():
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Xray gRPC is not available",
        )

    max_attempts = 3
    for attempt in range(max_attempts):
        pid1, starttime1, boot_id1, epoch1 = (
            epoch_manager.get_process_and_epoch() if epoch_manager else (None, None, None, None)
        )
        if pid1 is None or starttime1 is None or boot_id1 is None or epoch1 is None:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="Xray process or epoch is unavailable",
            )

        try:
            users_stats = grpc_client.get_users_stats(reset=False)
        except Exception as e:
            logger.error("Failed to fetch traffic stats from gRPC: %s", e)
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail=f"Xray gRPC stats failure: {str(e)}",
            ) from e

        pid2, starttime2, boot_id2, epoch2 = (
            epoch_manager.get_process_and_epoch() if epoch_manager else (None, None, None, None)
        )
        if pid2 is None or starttime2 is None or boot_id2 is None or epoch2 is None:
            logger.warning(
                "Xray stopped during traffic snapshot read (attempt %d/%d). Retrying...",
                attempt + 1,
                max_attempts,
            )
            await asyncio.sleep(0.05 * (2**attempt))
            continue

        if epoch1 == epoch2 and pid1 == pid2 and starttime1 == starttime2 and boot_id1 == boot_id2:
            tx_bytes, rx_bytes = _get_host_net_bytes()
            return {
                "node_epoch": epoch1,
                "boot_id": boot_id1,
                "starttime": starttime1,
                "timestamp": int(time.time()),
                "users": users_stats,
                "host_tx_bytes": tx_bytes,
                "host_rx_bytes": rx_bytes,
            }

        logger.warning(
            "Epoch drift detected during snapshot read (attempt %d/%d): %s -> %s. Retrying...",
            attempt + 1,
            max_attempts,
            epoch1,
            epoch2,
        )
        await asyncio.sleep(0.05 * (2**attempt))

    raise HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail="EpochMismatchError: Xray instance changed during stats read",
    )


@app.post("/v1/clients/sync")
@app.post("/v1/clients")
async def sync_client(req: ClientSyncRequest, _: bool = Depends(verify_api_key)) -> Dict[str, Any]:
    """
    Brings client's status across all inbounds to the desired state with two-phase epoch fencing,
    durable idempotency, and read-after-write postcondition verification.
    """
    client_uuid = req.client_id
    if not client_uuid:
        raise HTTPException(status_code=422, detail="client_id is required")

    desired_state = req.desired_state or "active"

    # Durable idempotency check with concurrency serialization
    if req.idempotency_key:
        op_lock = await _get_inflight_op_lock(req.idempotency_key)
        async with op_lock:
            if req.idempotency_key in completed_idempotent_ops:
                cached = completed_idempotent_ops[req.idempotency_key]
                cached_epoch = cached.get("verified_epoch")
                current_epoch = (
                    epoch_manager.get_current_running_epoch() if epoch_manager else None
                )
                if not current_epoch and epoch_manager:
                    current_epoch = epoch_manager.load_state().get("node_epoch")

                effective_svc = resolve_effective_service(req.service)
                client_id_matches = cached.get("client_id") == client_uuid
                state_matches = cached.get("state") == desired_state
                version_matches = (req.version is None) or (cached.get("version") == req.version)
                service_matches = cached.get("service") in (effective_svc, None) or req.service is None
                epoch_valid = (
                    client_id_matches
                    and state_matches
                    and version_matches
                    and service_matches
                    and bool(cached_epoch)
                    and (cached_epoch == current_epoch)
                    and (not req.expected_node_epoch or cached_epoch == req.expected_node_epoch)
                )

                if epoch_valid:
                    try:
                        entries = client_store.load_client_entries()
                        stored_entry = entries.get(client_uuid)
                        if stored_entry:
                            svc_states = stored_entry.get("service_states") or {}
                            svc_state = svc_states.get(effective_svc) if effective_svc else None
                            stored_tombstone = stored_entry.get("tombstone", False) or (
                                svc_state.get("tombstone", False) if svc_state else False
                            )
                            stored_ver = (
                                svc_state.get("version")
                                if (svc_state and svc_state.get("version") is not None)
                                else stored_entry.get("version")
                            )
                            if stored_tombstone or (
                                req.version is not None
                                and stored_ver is not None
                                and stored_ver > req.version
                            ):
                                logger.info(
                                    "Cached idempotent op for key %s invalidated by client_store (tombstone=%s, stored_ver=%s, req_ver=%s)",
                                    req.idempotency_key,
                                    stored_tombstone,
                                    stored_ver,
                                    req.version,
                                )
                                epoch_valid = False
                    except Exception as e:
                        logger.warning("Could not verify client_store for cached key %s: %s", req.idempotency_key, e)

                if epoch_valid:
                    logger.info("Returning cached durable operation for key %s", req.idempotency_key)
                    return {**cached, "idempotent": True}
                logger.info(
                    "Stale or mismatched cached operation for key %s (cached epoch %s, current %s, expected %s). Evicting and re-executing.",
                    req.idempotency_key,
                    cached_epoch,
                    current_epoch,
                    req.expected_node_epoch,
                )
                completed_idempotent_ops.pop(req.idempotency_key, None)
            return await _sync_client_internal(req, client_uuid, desired_state)

    return await _sync_client_internal(req, client_uuid, desired_state)


async def _sync_client_internal(
    req: ClientSyncRequest, client_uuid: str, desired_state: str
) -> Dict[str, Any]:
    effective_service = resolve_effective_service(req.service)
    target_inbounds = get_target_inbounds(service=effective_service)
    if not target_inbounds:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="No managed Xray inbounds configured on node",
        )

    # Phase 1: Pre-mutation Epoch Check
    epoch_before = epoch_manager.get_current_running_epoch() if epoch_manager else None
    if not epoch_before and epoch_manager:
        epoch_before = epoch_manager.load_state().get("node_epoch")
    if not epoch_before:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Node epoch is unavailable: Xray not running or persistent storage degraded",
        )
    sync_active_users_with_epoch(epoch_before)
    if req.expected_node_epoch and req.expected_node_epoch != epoch_before:
        logger.warning(
            "Epoch mismatch for client %s: expected %s != current %s",
            _mask_uuid(client_uuid),
            req.expected_node_epoch,
            epoch_before,
        )
        raise HTTPException(
            status_code=status.HTTP_412_PRECONDITION_FAILED,
            detail=f"Epoch fencing failed (pre-mutation): expected {req.expected_node_epoch} != current {epoch_before}",
        )

    # Monotonic version fencing check strictly scoped to target service
    curr_ver: Optional[int] = None
    if req.version is not None:
        try:
            entries = client_store.load_client_entries()
        except ClientStoreCorruptedError as e:
            logger.critical("Cannot sync client: client store corrupted: %s", e)
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail=f"Client store corrupted: {e}",
            ) from e

        curr_entry = entries.get(client_uuid)
        if curr_entry:
            service_states = curr_entry.get("service_states")
            if isinstance(service_states, dict):
                if effective_service in service_states:
                    svc_meta = service_states[effective_service]
                    curr_ver = svc_meta.get("version")
                    is_tombstone = svc_meta.get("tombstone", False)
                    curr_state = (
                        "disabled"
                        if is_tombstone
                        else ("active" if svc_meta.get("is_active") else "disabled")
                    )
                else:
                    curr_ver = None
                    is_tombstone = False
                    curr_state = "disabled"
            else:
                curr_ver = curr_entry.get("version")
                is_tombstone = curr_entry.get("tombstone", False)
                curr_state = (
                    "disabled"
                    if is_tombstone
                    else ("active" if curr_entry.get("is_active") else "disabled")
                )

            # Idempotent retry: exact same version and same desired_state already applied!
            if curr_ver is not None and req.version == curr_ver and curr_state == desired_state:
                inbounds_healthy = True
                for tag in target_inbounds:
                    try:
                        if desired_state == "active":
                            if not grpc_client.probe_user_presence(tag, client_uuid):
                                inbounds_healthy = False
                                break
                        else:
                            if not grpc_client.verify_user_absent(tag, client_uuid):
                                inbounds_healthy = False
                                break
                    except Exception:
                        inbounds_healthy = False
                        break

                if inbounds_healthy:
                    logger.info(
                        "Idempotent retry for %s (%s): version %d already in desired_state %s across all inbounds",
                        _mask_uuid(client_uuid),
                        effective_service,
                        req.version,
                        desired_state,
                    )
                    return {
                        "status": "ok",
                        "client_id": client_uuid,
                        "result": "applied",
                        "state": curr_state,
                        "version": curr_ver,
                        "service": effective_service,
                        "verified_epoch": epoch_before,
                        "verified_inbounds": target_inbounds,
                        "all_inbounds_verified": True,
                        "idempotent": True,
                        "inbounds": target_inbounds,
                    }
                logger.info(
                    "Idempotent retry for %s detected missing inbounds in Xray RAM. Re-applying to %s.",
                    _mask_uuid(client_uuid),
                    target_inbounds,
                )

            # Strict Monotonic Version Fencing (prevents delayed stale requests from reactivating revoked clients)
            if curr_ver is not None and (
                req.version < curr_ver
                or (req.version == curr_ver and desired_state != curr_state)
                or (is_tombstone and req.version <= curr_ver)
            ):
                logger.warning(
                    "Stale or conflicting sync request for %s (%s): incoming version %d <= stored version %d (curr_state=%s, desired_state=%s, tombstone=%s). Fencing.",
                    _mask_uuid(client_uuid),
                    effective_service,
                    req.version,
                    curr_ver,
                    curr_state,
                    desired_state,
                    is_tombstone,
                )
                verified_inbounds: List[str] = []
                for tag in target_inbounds:
                    try:
                        if curr_state == "active" and not is_tombstone:
                            if grpc_client.probe_user_presence(tag, client_uuid):
                                verified_inbounds.append(tag)
                        else:
                            if grpc_client.verify_user_absent(tag, client_uuid):
                                verified_inbounds.append(tag)
                    except Exception:
                        pass
                all_verified = (len(verified_inbounds) == len(target_inbounds)) and len(target_inbounds) > 0
                return {
                    "status": "ok",
                    "client_id": client_uuid,
                    "result": "already_newer",
                    "state": curr_state,
                    "version": curr_ver,
                    "service": effective_service,
                    "verified_epoch": epoch_before,
                    "verified_inbounds": verified_inbounds,
                    "all_inbounds_verified": all_verified,
                    "fenced": True,
                    "tombstone": is_tombstone,
                    "inbounds": target_inbounds,
                }

    # Capture initial runtime state before mutations for deterministic rollback
    initial_states: Dict[str, str] = {}
    for tag in target_inbounds:
        try:
            initial_states[tag] = "active" if grpc_client.probe_user_presence(tag, client_uuid) else "disabled"
        except Exception:
            initial_states[tag] = "disabled"

    # Execute mutation across all target inbounds
    succeeded_inbounds: List[str] = []
    failed_inbounds: List[str] = []
    for tag in target_inbounds:
        try:
            grpc_client.ensure_user_state(
                tag, client_uuid, desired_state=desired_state, flow=get_inbound_flow(tag)
            )
            succeeded_inbounds.append(tag)
        except Exception as e:
            logger.error(
                "Failed to sync user %s on inbound %s: %s", _mask_uuid(client_uuid), tag, e
            )
            failed_inbounds.append(tag)

    if failed_inbounds:
        # Rollback succeeded inbounds to their exact initial states
        for rb_tag in succeeded_inbounds:
            try:
                init_st = initial_states.get(rb_tag, "disabled")
                grpc_client.ensure_user_state(
                    rb_tag, client_uuid, desired_state=init_st, flow=get_inbound_flow(rb_tag)
                )
            except Exception as rb_exc:
                logger.error(
                    "Rollback failed for user %s on inbound %s: %s",
                    _mask_uuid(client_uuid),
                    rb_tag,
                    rb_exc,
                )
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to sync user on inbounds: {failed_inbounds}",
        )

    # Phase 2: Post-mutation Epoch Check (Atomic Epoch Fencing)
    epoch_after = epoch_manager.get_current_running_epoch() if epoch_manager else None
    if not epoch_after and epoch_manager:
        epoch_after = epoch_manager.load_state().get("node_epoch")
    if epoch_after != epoch_before or not epoch_after:
        logger.critical(
            "Epoch drift during mutation for %s: epoch_before=%s != epoch_after=%s. Xray restarted during sync!",
            _mask_uuid(client_uuid),
            epoch_before,
            epoch_after,
        )
        raise HTTPException(
            status_code=status.HTTP_412_PRECONDITION_FAILED,
            detail=f"epoch_drift_during_mutation: Xray instance changed during sync ({epoch_before} -> {epoch_after})",
        )

    # Read-After-Write Postcondition Verification
    verified_inbounds: List[str] = []
    unverified_inbounds: List[str] = []
    for tag in target_inbounds:
        try:
            if desired_state == "active":
                is_verified = grpc_client.probe_user_presence(tag, client_uuid)
            else:
                is_verified = grpc_client.verify_user_absent(tag, client_uuid)
            if is_verified:
                verified_inbounds.append(tag)
            else:
                unverified_inbounds.append(tag)
        except Exception as e:
            logger.error("Postcondition check failed for %s on inbound %s: %s", _mask_uuid(client_uuid), tag, e)
            unverified_inbounds.append(tag)

    if unverified_inbounds:
        logger.error(
            "Postcondition verification failed for user %s on inbounds %s",
            _mask_uuid(client_uuid),
            unverified_inbounds,
        )
        # Rollback all inbounds to exact initial states upon verification failure
        for rb_tag in succeeded_inbounds:
            try:
                init_st = initial_states.get(rb_tag, "disabled")
                grpc_client.ensure_user_state(
                    rb_tag, client_uuid, desired_state=init_st, flow=get_inbound_flow(rb_tag)
                )
            except Exception as rb_exc:
                logger.error(
                    "Rollback after unverified postcondition failed for %s on %s: %s",
                    _mask_uuid(client_uuid),
                    rb_tag,
                    rb_exc,
                )
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Postcondition verification failed: inbounds {unverified_inbounds} unverified for state {desired_state}",
        )

    # Update local persistent client store with monotonic version scoped to service
    effective_ver = (
        max(curr_ver or 0, req.version or 0)
        if curr_ver is not None and req.version is not None
        else req.version
    )
    try:
        if desired_state == "active":
            client_store.add_client(
                client_uuid, version=effective_ver, email=req.email, service=effective_service
            )
        else:
            client_store.remove_client(client_uuid, version=effective_ver, service=effective_service)
    except Exception as e:
        logger.error("Failed to persist client state to disk: %s", e)
        # Rollback Xray RAM state to exact initial states so RAM does not diverge from disk
        for rb_tag in succeeded_inbounds:
            try:
                init_st = initial_states.get(rb_tag, "disabled")
                grpc_client.ensure_user_state(
                    rb_tag, client_uuid, desired_state=init_st, flow=get_inbound_flow(rb_tag)
                )
            except Exception as rb_exc:
                logger.error(
                    "Rollback after persistence failure failed for %s on %s: %s",
                    _mask_uuid(client_uuid),
                    rb_tag,
                    rb_exc,
                )
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to persist client state: {str(e)}",
        ) from e

    # Update synchronization state
    node_sync_state["last_synced_at"] = time.time()
    node_sync_state["last_client_sync_at"] = time.time()

    resp = {
        "status": "ok",
        "client_id": client_uuid,
        "result": "applied",
        "state": desired_state,
        "version": req.version,
        "service": effective_service,
        "verified_epoch": epoch_after,
        "verified_inbounds": verified_inbounds,
        "all_inbounds_verified": (len(verified_inbounds) == len(target_inbounds)) and len(target_inbounds) > 0,
        "fenced": False,
        "inbounds": target_inbounds,
    }

    if req.idempotency_key:
        completed_idempotent_ops[req.idempotency_key] = resp
        if len(completed_idempotent_ops) > 2000:
            for k in list(completed_idempotent_ops.keys())[:500]:
                completed_idempotent_ops.pop(k, None)

    return resp


@app.delete("/v1/clients/{uuid}")
async def delete_client(
    uuid: str,
    version: Optional[int] = None,
    _: bool = Depends(verify_api_key),
) -> Dict[str, Any]:
    """
    Deletes client from all inbounds and records a tombstone in local persistent storage with version fencing.
    """
    try:
        clean_uuid = str(uuid_lib.UUID(uuid.strip())).lower()
    except ValueError:
        raise HTTPException(
            status_code=422,
            detail=f"Invalid UUID: {uuid}",
        ) from None

    target_inbounds = get_all_managed_inbounds()
    if not target_inbounds:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="No managed Xray inbounds configured on node",
        )

    current_epoch = epoch_manager.get_current_running_epoch() if epoch_manager else None
    if not current_epoch and epoch_manager:
        current_epoch = epoch_manager.load_state().get("node_epoch")
    if not current_epoch:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Node epoch is unavailable: Xray not running or persistent storage degraded",
        )

    # Monotonic version check
    if version is not None:
        entries = client_store.load_client_entries()
        curr_entry = entries.get(clean_uuid)
        if curr_entry:
            curr_ver = curr_entry.get("version")
            is_tombstone = curr_entry.get("tombstone", False)

            # Idempotent delete retry: already tombstoned with same version
            if curr_ver is not None and version == curr_ver and is_tombstone:
                logger.info(
                    "Idempotent delete retry for %s: version %d already tombstoned",
                    _mask_uuid(clean_uuid),
                    version,
                )
                return {
                    "status": "ok",
                    "client_id": clean_uuid,
                    "result": "applied",
                    "state": "disabled",
                    "version": curr_ver,
                    "idempotent": True,
                    "tombstone": True,
                    "inbounds": target_inbounds,
                }

            if curr_ver is not None and (
                version < curr_ver or (is_tombstone and version <= curr_ver)
            ):
                logger.warning(
                    "Stale delete request for %s: version %d <= stored %d (tombstone=%s). Fencing.",
                    _mask_uuid(clean_uuid),
                    version,
                    curr_ver,
                    is_tombstone,
                )
                return {
                    "status": "ok",
                    "client_id": clean_uuid,
                    "result": "already_newer",
                    "fenced": True,
                    "version": curr_ver,
                    "inbounds": target_inbounds,
                }

    failed_inbounds: List[str] = []
    for tag in target_inbounds:
        try:
            grpc_client.remove_user(tag, clean_uuid)
        except Exception as e:
            logger.error(
                "Failed to delete user %s from inbound %s: %s", _mask_uuid(clean_uuid), tag, e
            )
            failed_inbounds.append(tag)

    if failed_inbounds:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to remove user from inbounds: {failed_inbounds}",
        )

    try:
        client_store.delete_client(clean_uuid, version=version)
    except Exception as e:
        logger.error("Could not delete client tombstone from store: %s", e)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to persist client tombstone to disk",
        ) from e

    completed_idempotent_ops.evict_by_client_id(clean_uuid)

    return {
        "status": "ok",
        "client_id": clean_uuid,
        "result": "applied",
        "action": "deleted",
        "fenced": False,
        "version": version,
        "inbounds": target_inbounds,
    }


@app.post("/v1/clients/inventory")
@app.get("/v1/clients/inventory")
async def get_clients_inventory(
    req: Optional[InventoryRequest] = None,
    _: bool = Depends(verify_api_key),
) -> Dict[str, Any]:
    """
    Returns verified observed runtime inventory directly from Xray memory across all managed inbounds.
    """
    target_inbounds = (
        get_target_inbounds(service=req.service)
        if (req and req.service)
        else get_all_managed_inbounds()
    )
    running_epoch = epoch_manager.get_current_running_epoch() if epoch_manager else None
    if not running_epoch and epoch_manager:
        running_epoch = epoch_manager.load_state().get("node_epoch")
    sync_active_users_with_epoch(running_epoch)

    if not target_inbounds:
        return {
            "status": "ok",
            "node_epoch": running_epoch,
            "managed_inbounds": [],
            "inventory": {},
            "count": 0,
        }

    # Determine which clients to probe:
    client_ids = req.client_ids if req and req.client_ids else None
    if client_ids and len(client_ids) > 1000:
        client_ids = client_ids[:1000]
    if not client_ids:
        try:
            client_ids = list(client_store.load_client_entries().keys())
        except ClientStoreCorruptedError as e:
            logger.critical("Inventory cannot load entries from corrupt store: %s", e)
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail=f"Client store corrupted: {e}",
            ) from e

    inventory: Dict[str, Any] = {}
    for cid in client_ids:
        try:
            clean_cid = str(uuid_lib.UUID(str(cid).strip())).lower()
        except ValueError:
            continue

        inbound_presence: Dict[str, bool] = {}
        for tag in target_inbounds:
            try:
                present = grpc_client.probe_user_presence(tag, clean_cid)
                inbound_presence[tag] = present
            except Exception as e:
                logger.warning("Probe error for %s on %s: %s", _mask_uuid(clean_cid), tag, e)
                inbound_presence[tag] = False

        all_active = all(inbound_presence.values()) if inbound_presence else False
        all_disabled = not any(inbound_presence.values()) if inbound_presence else True

        if all_active:
            observed_state = "active"
        elif all_disabled:
            observed_state = "disabled"
        else:
            observed_state = "partial"

        inventory[clean_cid] = {
            "observed_state": observed_state,
            "inbounds": inbound_presence,
            "all_inbounds_matched": (all_active or all_disabled),
        }

    return {
        "status": "ok",
        "node_epoch": running_epoch,
        "managed_inbounds": target_inbounds,
        "inventory": inventory,
        "count": len(inventory),
    }


class CertificateDeployRequest(BaseModel):
    domain: str = Field(..., min_length=3, max_length=253)
    fullchain_pem: str = Field(..., min_length=50)
    privkey_pem: str = Field(..., min_length=50)

    @model_validator(mode="after")
    def validate_pems(self) -> "CertificateDeployRequest":
        dom = self.domain.strip().lower()
        if not re.match(
            r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$",
            dom,
        ) and not (
            dom.startswith("*.")
            and re.match(
                r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$",
                dom[2:],
            )
        ):
            raise ValueError("Invalid domain name format")

        if "-----BEGIN CERTIFICATE-----" not in self.fullchain_pem:
            raise ValueError("Invalid fullchain_pem: missing BEGIN CERTIFICATE marker")
        if not any(
            marker in self.privkey_pem
            for marker in (
                "-----BEGIN PRIVATE KEY-----",
                "-----BEGIN RSA PRIVATE KEY-----",
                "-----BEGIN EC PRIVATE KEY-----",
            )
        ):
            raise ValueError("Invalid privkey_pem: missing BEGIN PRIVATE KEY marker")
        return self


def _sync_write_certificates(
    clean_domain: str, fullchain_pem: str, privkey_pem: str
) -> None:
    cert_dir = Path("/etc/letsencrypt/live") / clean_domain
    cert_dir.mkdir(parents=True, exist_ok=True)

    fullchain_file = cert_dir / "fullchain.pem"
    privkey_file = cert_dir / "privkey.pem"

    tmp_fullchain = cert_dir / "fullchain.pem.tmp"
    tmp_privkey = cert_dir / "privkey.pem.tmp"

    try:
        tmp_fullchain.write_text(fullchain_pem.strip() + "\n", encoding="utf-8")
        tmp_privkey.write_text(privkey_pem.strip() + "\n", encoding="utf-8")
        try:
            tmp_fullchain.chmod(0o644)
            tmp_privkey.chmod(0o640)
        except Exception:
            pass

        tmp_fullchain.replace(fullchain_file)
        tmp_privkey.replace(privkey_file)
        try:
            fullchain_file.chmod(0o644)
            privkey_file.chmod(0o640)
        except Exception:
            pass
    except Exception:
        for f in (tmp_fullchain, tmp_privkey):
            try:
                f.unlink(missing_ok=True)
            except Exception:
                pass
        raise

    xray_tls_dir = Path("/usr/local/etc/xray/tls")
    if xray_tls_dir.exists():
        try:
            shutil.copy2(str(fullchain_file), str(xray_tls_dir / "fullchain.pem"))
            shutil.copy2(str(privkey_file), str(xray_tls_dir / "privkey.pem"))
            (xray_tls_dir / "fullchain.pem").chmod(0o644)
            (xray_tls_dir / "privkey.pem").chmod(0o640)
            if (xray_tls_dir / "vless_fullchain.pem").exists():
                shutil.copy2(str(fullchain_file), str(xray_tls_dir / "vless_fullchain.pem"))
                shutil.copy2(str(privkey_file), str(xray_tls_dir / "vless_privkey.pem"))
                (xray_tls_dir / "vless_fullchain.pem").chmod(0o644)
                (xray_tls_dir / "vless_privkey.pem").chmod(0o640)
        except Exception as e:
            logger.warning("Could not sync to %s: %s", xray_tls_dir, e)


@app.post("/v1/system/certificate")
async def deploy_certificate(
    req: CertificateDeployRequest,
    _: bool = Depends(verify_api_key),
) -> Dict[str, Any]:
    """Safely deploy or rotate TLS certificates (DNS-01 wildcard or SNI certs) from the centralized bot.

    Writes certs atomically with 0600 permissions, reloads Nginx, and restarts Xray if needed.
    """
    clean_domain = req.domain.strip().lower().lstrip("*.")
    try:
        await asyncio.to_thread(
            _sync_write_certificates,
            clean_domain,
            req.fullchain_pem,
            req.privkey_pem,
        )
    except Exception as exc:
        logger.error("Failed to write certificates for %s: %s", clean_domain, exc)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to write certificate files: {exc}",
        ) from exc

    actions = []
    if _write_apply_pending("certificate_updated"):
        actions.append("apply_queued")

    if shutil.which("nginx"):
        try:
            res = await asyncio.create_subprocess_exec(
                "systemctl",
                "reload",
                "nginx",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await res.communicate()
            if res.returncode == 0:
                actions.append("nginx_reloaded")
        except Exception as e:
            logger.debug("Direct nginx reload skipped (root apply_pending handles it): %s", e)

    if shutil.which("systemctl"):
        if (STATE_FILE_PATH.parent / "traffic_limit_exceeded").exists():
            logger.info("Skipping Xray restart on certificate deploy: traffic_limit_exceeded is active")
            actions.append("xray_restart_skipped_traffic_limit")
        else:
            try:
                res = await asyncio.create_subprocess_exec(
                    "systemctl",
                    "restart",
                    "xray",
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                await res.communicate()
                if res.returncode == 0:
                    actions.append("xray_restarted")
            except Exception as e:
                logger.debug("Direct xray restart skipped (root apply_pending handles it): %s", e)

    logger.info("TLS certificate updated for %s. Actions: %s", clean_domain, actions)
    return {
        "status": "ok",
        "domain": clean_domain,
        "actions": actions,
        "message": f"Certificate for {clean_domain} successfully deployed",
    }
