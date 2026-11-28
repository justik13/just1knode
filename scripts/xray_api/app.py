import asyncio
import copy
from datetime import datetime, timezone
import fcntl
import json
import logging
import os
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import uuid as uuid_lib
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Dict, List, Optional
from urllib.parse import urlsplit

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response, status

from client_store import ClientStore, ClientStoreCorruptedError
from epoch_manager import EpochManager
from idempotency_store import DurableIdempotencyStore, _resolve_idempotency_db_path
from schemas import (
    ClientBatchSyncRequest,
    ClientSyncRequest,
    InventoryRequest,
    NodeLinksUpdateRequest,
)
from xray_grpc import XrayGrpcClient


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


APPLY_RUNNING_STALE_SEC = 150


def _get_boot_time_epoch() -> Optional[float]:
    """Return Linux system boot time as Unix epoch from /proc/stat, or None."""
    try:
        with open("/proc/stat", "r", encoding="ascii", errors="replace") as f:
            for line in f:
                if line.startswith("btime "):
                    parts = line.split()
                    if len(parts) >= 2:
                        return float(parts[1])
    except Exception:
        pass
    return None


def _apply_running_path() -> Path:
    return STATE_FILE_PATH.parent / ".apply_running"


def _is_apply_in_progress() -> bool:
    if _apply_pending_path().exists():
        return True
    running_path = _apply_running_path()
    try:
        st_mtime = running_path.stat().st_mtime
    except FileNotFoundError:
        return False
    except OSError:
        return running_path.exists()
    boot_time = _get_boot_time_epoch()
    if (boot_time is not None and st_mtime < boot_time) or (
        time.time() - st_mtime > APPLY_RUNNING_STALE_SEC
    ):
        logger.warning(
            "Stale .apply_running detected at %s (mtime=%.0f, boot_time=%s); clearing",
            running_path,
            st_mtime,
            f"{boot_time:.0f}" if boot_time is not None else "unknown",
        )
        try:
            running_path.unlink(missing_ok=True)
        except Exception as exc:
            logger.debug("Could not unlink stale %s: %s", running_path, exc)
        return False
    return True


def _module_errors_path() -> Path:
    env_p = os.getenv("MODULE_ERRORS_PATH")
    if env_p:
        return Path(env_p)
    return STATE_FILE_PATH.parent / "module_errors.json"


def _atomic_write_json(path: Path, payload: Any, mode: int = 0o660) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = Path(f"{path}.lock")
    lock_flags = os.O_CREAT | os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0)
    lock_fd = os.open(str(lock_path), lock_flags, 0o660)
    with os.fdopen(lock_fd, "a", encoding="utf-8") as lock_fp:
        fcntl.flock(lock_fp.fileno(), fcntl.LOCK_EX)
        try:
            fd, tmp_str = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
            tmp_path = Path(tmp_str)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as fp:
                    json.dump(payload, fp, indent=2, ensure_ascii=False)
                    fp.write("\n")
                    fp.flush()
                    os.fsync(fp.fileno())
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
        finally:
            fcntl.flock(lock_fp.fileno(), fcntl.LOCK_UN)


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


def _get_sni_routes(links_data: Optional[Dict[str, Any]] = None) -> List[Dict[str, str]]:
    data = links_data if isinstance(links_data, dict) else _load_links_data()
    standard = data.get("standard") if isinstance(data, dict) else None
    if not isinstance(standard, dict):
        return []
    raw_routes = standard.get("sni_routes")
    if not isinstance(raw_routes, list):
        return []
    routes: List[Dict[str, str]] = []
    for item in raw_routes:
        if not isinstance(item, dict):
            continue
        sni = str(item.get("sni") or "").strip().lower()
        bridge_code = str(item.get("bridge_code") or "").strip().lower()
        if sni and bridge_code:
            routes.append({"sni": sni, "bridge_code": bridge_code})
    return routes


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


def _load_last_apply() -> Optional[Dict[str, Any]]:
    """Read last_apply.json safely; return parsed status dict or None."""
    lp = STATE_FILE_PATH.parent / "last_apply.json"
    if not lp.exists():
        return None
    try:
        data = json.loads(lp.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            return None
        res: Dict[str, Any] = {
            "ok": bool(data.get("ok")),
            "rc": int(data["rc"]) if data.get("rc") is not None else None,
            "role": str(data.get("role") or ""),
            "ts": int(data["ts"]) if data.get("ts") is not None else None,
        }
        err_val = data.get("error") or data.get("rollback_error")
        if err_val:
            res["error"] = str(err_val)[:500]
        return res
    except Exception as e:
        logger.debug("Could not read last_apply.json at %s: %s", lp, e)
    return None


_SSL_CERT_CACHE_TTL = 300.0
_SSL_CERT_NEG_CACHE_TTL = 15.0
_ssl_cert_cache_lock = threading.Lock()
_ssl_cert_cache: Dict[str, Any] = {
    "key": None,
    "checked_at": 0.0,
    "expires_dt": None,
}


def _find_node_cert_path(domain: str) -> Optional[Path]:
    env_cert = (os.getenv("SSL_CERT_PATH") or "").strip()
    candidates: List[Path] = []
    if env_cert:
        candidates.append(Path(env_cert))
    xray_tls_dir = Path(os.getenv("XRAY_TLS_DIR") or str(XRAY_CONFIG_PATH.parent / "tls"))
    le_dir = Path(os.getenv("LETSENCRYPT_DIR", "/etc/letsencrypt"))
    clean_dom = (domain or "").strip()
    if clean_dom and clean_dom != "-":
        candidates.append(xray_tls_dir / f"{clean_dom}_fullchain.pem")
        candidates.append(le_dir / "live" / clean_dom / "fullchain.pem")
    candidates.append(xray_tls_dir / "fullchain.pem")
    for cand in candidates:
        try:
            if cand.is_file() and os.access(cand, os.R_OK):
                return cand
        except OSError:
            continue
    return None


def _parse_cert_not_after(cert_path: Path) -> Optional[datetime]:
    not_after_raw: Optional[str] = None
    try:
        proc = subprocess.run(
            ["openssl", "x509", "-enddate", "-noout", "-in", str(cert_path)],
            capture_output=True,
            text=True,
            timeout=3.0,
            check=False,
        )
        if proc.returncode == 0 and "=" in proc.stdout:
            not_after_raw = proc.stdout.split("=", 1)[1].strip()
    except Exception:
        not_after_raw = None
    if not not_after_raw:
        return None
    for fmt in ("%b %d %H:%M:%S %Y %Z", "%b  %d %H:%M:%S %Y %Z"):
        try:
            return datetime.strptime(not_after_raw, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def _load_ssl_cert_info(domain: str) -> Optional[Dict[str, Any]]:
    """Return cached {expires_at, days_left} for the node TLS cert, or None."""
    cert_path = _find_node_cert_path(domain)
    if cert_path is None:
        return None
    try:
        mtime_ns = cert_path.stat().st_mtime_ns
    except OSError:
        return None

    cache_key = (str(cert_path), mtime_ns)
    now_mono = time.monotonic()
    exp_dt: Optional[datetime] = None
    with _ssl_cert_cache_lock:
        ttl = (
            _SSL_CERT_CACHE_TTL
            if _ssl_cert_cache["expires_dt"] is not None
            else _SSL_CERT_NEG_CACHE_TTL
        )
        if (
            _ssl_cert_cache["key"] == cache_key
            and (now_mono - float(_ssl_cert_cache["checked_at"])) < ttl
        ):
            exp_dt = _ssl_cert_cache["expires_dt"]
        else:
            exp_dt = _parse_cert_not_after(cert_path)
            _ssl_cert_cache["key"] = cache_key
            _ssl_cert_cache["checked_at"] = now_mono
            _ssl_cert_cache["expires_dt"] = exp_dt

    if exp_dt is None:
        return None
    days_left = int((exp_dt - datetime.now(timezone.utc)).total_seconds() // 86400)
    return {
        "expires_at": exp_dt.isoformat(),
        "days_left": days_left,
    }


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
    tmp_path = STATE_FILE_PATH.parent / f"bot_status.{uuid_lib.uuid4().hex[:8]}.tmp"
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
        pass
    finally:
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
_inflight_op_refcounts: Dict[str, int] = {}
_inflight_master_lock = asyncio.Lock()


class _InflightLock:
    def __init__(self, key: str, lock: asyncio.Lock):
        self.key = key
        self.lock = lock

    async def _release_ref(self) -> None:
        async with _inflight_master_lock:
            remaining = _inflight_op_refcounts.get(self.key, 1) - 1
            if remaining <= 0:
                _inflight_op_refcounts.pop(self.key, None)
                if not self.lock.locked():
                    _inflight_op_locks.pop(self.key, None)
            else:
                _inflight_op_refcounts[self.key] = remaining

    async def __aenter__(self):
        try:
            await self.lock.acquire()
        except BaseException:
            await self._release_ref()
            raise
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        try:
            self.lock.release()
        finally:
            await self._release_ref()


async def _get_inflight_op_lock(key: str) -> _InflightLock:
    async with _inflight_master_lock:
        if key not in _inflight_op_locks:
            _inflight_op_locks[key] = asyncio.Lock()
        _inflight_op_refcounts[key] = _inflight_op_refcounts.get(key, 0) + 1
        return _InflightLock(key, _inflight_op_locks[key])


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
                        if path and path.startswith("/"):
                            parts = [p for p in path.strip("/").split("/") if p]
                            if parts:
                                return f"/{parts[0]}"
                # Priority 2: tags starting strictly with just1k-wl- (managed namespace)
                for ib in inbounds:
                    tag = ib.get("tag", "")
                    if tag.startswith("just1k-wl-"):
                        path = ib.get("streamSettings", {}).get("xhttpSettings", {}).get("path", "")
                        if path and path.startswith("/"):
                            parts = [p for p in path.strip("/").split("/") if p]
                            if parts:
                                return f"/{parts[0]}"
        except Exception:
            pass

    return os.getenv("WHITE_INTERNET_PATH", "/assets/v1")


def get_cdn_domain() -> Optional[str]:
    """Resolves CDN domain configured for this ru_hub node.

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


def get_cdn_domains() -> Dict[str, str]:
    """Resolves all active CDN domains keyed by module id (e.g. cdn_yandex, cdn_turboflare)."""
    domains: Dict[str, str] = {}
    if STATE_FILE_PATH.exists():
        try:
            with open(STATE_FILE_PATH, "r", encoding="utf-8") as f:
                st = json.load(f)
                if isinstance(st, dict):
                    modules = st.get("modules")
                    if isinstance(modules, dict):
                        for m_key, m_cfg in modules.items():
                            if str(m_key).startswith("cdn_") and isinstance(m_cfg, dict) and m_cfg.get("enabled"):
                                cand = m_cfg.get("cdn_domain") or m_cfg.get("domain")
                                if cand and str(cand).strip():
                                    domains[str(m_key)] = str(cand).strip()
        except Exception as e:
            logger.warning("Could not read cdn_domains from %s: %s", STATE_FILE_PATH, e)
    return domains


def get_sub_path_prefix() -> Optional[str]:
    """Resolves subscription path prefix configured for this ru_hub node.

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
                loc_code, cdn_hint = raw_suffix.rsplit("__", 1)
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
    """Check if tag belongs to white_internet, strictly excluding internal bridge tunnels."""
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
    if tag == "just1k-vless-direct":
        return "xtls-rprx-vision"
    return ""


def _xray_email_for_inbound(
    client_uuid: str,
    tag: str,
    service: Optional[str] = None,
    explicit_email: Optional[str] = None,
    stored_entry: Optional[Dict[str, Any]] = None,
) -> str:
    """Return service-scoped Xray user email so QueryStats never mixes Standard and WI traffic."""
    if is_wl_inbound_tag(tag):
        inbound_svc: Optional[str] = "white_internet"
    elif tag.startswith("just1k-vless-") or tag == "just1k-vless-direct":
        inbound_svc = "vless"
    else:
        inbound_svc = resolve_effective_service(service) if service else None

    return ClientStore.resolve_service_email(
        client_uuid,
        inbound_svc,
        explicit_email=explicit_email,
        existing_entry=stored_entry,
    )


_epoch_sync_lock = threading.RLock()
_last_restore_attempt_ts = 0.0
_last_restore_attempt_epoch: Optional[str] = None
_RESTORE_FAILURE_COOLDOWN_SEC = 60.0


def _active_services_for_entry(meta: Dict[str, Any]) -> List[Optional[str]]:
    """Return active service namespaces for a stored client entry."""
    service_states = meta.get("service_states")
    if isinstance(service_states, dict) and service_states:
        return [
            s
            for s, st in service_states.items()
            if isinstance(st, dict) and st.get("is_active") is True and not st.get("tombstone", False)
        ]
    if not meta.get("is_active", True) or meta.get("tombstone", False):
        return []
    return meta.get("services") or ([meta.get("service")] if meta.get("service") else [None])


def _is_entry_active_for_service(meta: Dict[str, Any], eff_service: Optional[str]) -> bool:
    """Return True if stored entry is active for eff_service (or any service when None)."""
    active_services = _active_services_for_entry(meta)
    if not active_services:
        return False
    if eff_service is None:
        return True
    return eff_service in active_services or None in active_services


def restore_persisted_clients_to_xray() -> tuple[int, bool]:
    """Restores active persisted clients from disk into Xray RAM as temporary crash-recovery hint.

    Returns (restored_unique_count, had_failures).
    """
    entries = client_store.load_client_entries()
    if not entries:
        logger.info("No active persisted clients to restore.")
        return 0, False

    restored_unique = 0
    restored_registrations = 0
    had_failures = False
    has_restorable_entries = False
    for client_uuid, meta in entries.items():
        if not isinstance(meta, dict):
            continue
        active_services = _active_services_for_entry(meta)
        if not active_services:
            continue

        user_restored = False
        for s in active_services:
            tags = get_target_inbounds(service=s)
            if tags:
                has_restorable_entries = True
            for tag in tags:
                try:
                    grpc_client.add_user(
                        tag,
                        client_uuid,
                        flow=get_inbound_flow(tag),
                        email=_xray_email_for_inbound(
                            client_uuid,
                            tag,
                            s,
                            stored_entry=meta,
                        ),
                    )
                    restored_registrations += 1
                    user_restored = True
                except Exception as e:
                    had_failures = True
                    logger.warning(
                        "Failed to restore client %s on inbound %s: %s", _mask_uuid(client_uuid), tag, e
                    )
        if user_restored:
            restored_unique += 1

    if has_restorable_entries and restored_registrations == 0:
        had_failures = True

    logger.info(
        "Restored %d active client registrations across services as ephemeral hints (had_failures=%s).",
        restored_registrations,
        had_failures,
    )
    return restored_unique, had_failures


def sync_active_users_with_epoch(current_epoch: Optional[str], *, blocking: bool = True) -> None:
    """Ensures in-memory active users set is aligned with current Xray epoch."""
    global _last_restore_attempt_ts, _last_restore_attempt_epoch
    if not current_epoch:
        return
    if not _epoch_sync_lock.acquire(blocking=blocking):
        return
    try:
        if grpc_client._active_users_epoch != current_epoch:
            now = time.time()
            if (
                _last_restore_attempt_epoch == current_epoch
                and (now - _last_restore_attempt_ts) < _RESTORE_FAILURE_COOLDOWN_SEC
            ):
                logger.debug(
                    "Skipping client restoration for epoch %s due to recent failure cooldown (%.1fs remaining)",
                    current_epoch,
                    _RESTORE_FAILURE_COOLDOWN_SEC - (now - _last_restore_attempt_ts),
                )
                return
            if grpc_client.is_healthy():
                logger.info(
                    "Xray instance epoch changed (%s -> %s). Invalidating active users cache and restoring active persisted clients.",
                    grpc_client._active_users_epoch,
                    current_epoch,
                )
                grpc_client.clear_active_users()
                _restored, had_failures = restore_persisted_clients_to_xray()
                if not had_failures:
                    grpc_client._active_users_epoch = current_epoch
                    _last_restore_attempt_ts = 0.0
                    _last_restore_attempt_epoch = None
                else:
                    _last_restore_attempt_ts = now
                    _last_restore_attempt_epoch = current_epoch
            else:
                logger.debug(
                    "Xray instance epoch changed to %s, but gRPC is not healthy yet. Deferring client restoration.",
                    current_epoch,
                )
    finally:
        _epoch_sync_lock.release()


_BRIDGE_CODE_CLEAN_RE = re.compile(r"[^a-z0-9_-]+")
BRIDGE_PROBE_INTERVAL = float(os.getenv("BRIDGE_PROBE_INTERVAL", "60.0"))
BRIDGE_PROBE_TIMEOUT = float(os.getenv("BRIDGE_PROBE_TIMEOUT", "8.0"))
BRIDGE_PROBE_MIN_BYTES = int(os.getenv("BRIDGE_PROBE_MIN_BYTES", "36864"))
BRIDGE_PROBE_URLS = [
    u.strip()
    for u in os.getenv(
        "BRIDGE_PROBE_URLS",
        "https://speed.cloudflare.com/__down?bytes=65536,https://ajax.googleapis.com/ajax/libs/jquery/3.7.1/jquery.min.js",
    ).split(",")
    if u.strip()
]

_bridge_health_lock = threading.Lock()
_bridge_health_state: Dict[str, Dict[str, Any]] = {}


def _clean_bridge_code(raw: Any, fallback: str) -> str:
    val = _BRIDGE_CODE_CLEAN_RE.sub("", str(raw or "").strip().lower())
    return val[:48] if val else fallback


def _collect_links_bridge_ips(links: Dict[str, Any]) -> set[str]:
    """Return all bridge IPs declared in links.json across standard, bi, and probe_bridges."""
    ips: set[str] = set()
    std_cfg = links.get("standard") if isinstance(links.get("standard"), dict) else {}
    bi_cfg = links.get("bi") if isinstance(links.get("bi"), dict) else {}
    for items in (std_cfg.get("bridges"), bi_cfg.get("bridges"), links.get("probe_bridges")):
        if not isinstance(items, list):
            continue
        for item in items:
            if not isinstance(item, dict):
                continue
            ip = str(item.get("ip") or "").strip()
            if ip:
                ips.add(ip)
    return ips


def _get_probe_socks_config() -> tuple[int | None, set[str]]:
    """Return (socks_port, configured_outbound_tags) from XRAY_CONFIG_PATH."""
    if not XRAY_CONFIG_PATH.exists():
        return None, set()
    try:
        cfg = json.loads(XRAY_CONFIG_PATH.read_text(encoding="utf-8"))
        if not isinstance(cfg, dict):
            return None, set()
        socks_port = None
        for ib in cfg.get("inbounds") or []:
            if isinstance(ib, dict) and ib.get("tag") == "just1k-probe-socks":
                socks_port = int(ib.get("port") or 0) or None
                break
        outbound_tags = {
            str(ob.get("tag"))
            for ob in (cfg.get("outbounds") or [])
            if isinstance(ob, dict) and ob.get("tag")
        }
        return socks_port, outbound_tags
    except Exception:
        return None, set()


def _collect_ru_hub_probe_targets(links: Dict[str, Any], configured_tags: set[str]) -> list[Dict[str, Any]]:
    """Pick up to 2 distinct exit-node probe tags per eu_hub IP active in Xray config."""
    targets_by_ip: Dict[str, Dict[str, Any]] = {}

    def _consider(items: Any, prefix: str, fb_prefix: str) -> None:
        if not isinstance(items, list):
            return
        for idx, item in enumerate(items):
            if not isinstance(item, dict):
                continue
            ip = str(item.get("ip") or "").strip()
            sni = str(item.get("sni") or "").strip()
            if not ip:
                continue
            code = _clean_bridge_code(item.get("code"), f"{fb_prefix}{idx + 1}")
            tag = f"{prefix}{code}"
            if tag not in configured_tags:
                continue
            exit_key = _clean_bridge_code(item.get("location_code") or item.get("code"), code)
            entry = targets_by_ip.get(ip)
            if entry is None:
                targets_by_ip[ip] = {
                    "ip": ip,
                    "sni": sni,
                    "tag": tag,
                    "tags": [tag],
                    "_exit_keys": {exit_key},
                }
            elif len(entry["tags"]) < 2 and tag not in entry["tags"]:
                if exit_key not in entry["_exit_keys"]:
                    entry["tags"].append(tag)
                    entry["_exit_keys"].add(exit_key)

    std_cfg = links.get("standard") if isinstance(links.get("standard"), dict) else {}
    bi_cfg = links.get("bi") if isinstance(links.get("bi"), dict) else {}
    _consider(std_cfg.get("bridges"), "bridge-std-", "hub")
    _consider(bi_cfg.get("bridges"), "bridge-bi-", "hub")
    _consider(links.get("probe_bridges"), "bridge-probe-", "probe")
    targets: list[Dict[str, Any]] = []
    for entry in targets_by_ip.values():
        entry.pop("_exit_keys", None)
        targets.append(entry)
    return targets


def _recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("Unexpected EOF during SOCKS5 handshake")
        buf.extend(chunk)
    return bytes(buf)


def _probe_via_socks5_sync(
    socks_port: int,
    bridge_tag: str,
    probe_url: str,
    min_bytes: int,
    timeout: float,
) -> tuple[bool, int, int | None, str | None]:
    """Perform a SOCKS5 HTTP(S) GET via Xray's local probe inbound and read >= min_bytes."""
    parsed = urlsplit(probe_url)
    host = parsed.hostname
    if not host:
        return False, 0, None, "Invalid probe URL"
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    path = parsed.path or "/"
    if parsed.query:
        path = f"{path}?{parsed.query}"

    started = time.monotonic()
    deadline = started + timeout

    def _remaining() -> float:
        rem = deadline - time.monotonic()
        if rem <= 0:
            raise TimeoutError("Timeout (possible TSPU silent stall)")
        return rem

    raw_sock = None
    tls_sock = None
    total_bytes = 0
    try:
        raw_sock = socket.create_connection(("127.0.0.1", socks_port), timeout=_remaining())
        raw_sock.settimeout(_remaining())

        # 1. SOCKS5 greeting (username/password auth = 0x02)
        raw_sock.sendall(b"\x05\x01\x02")
        ver_method = _recv_exact(raw_sock, 2)
        if ver_method != b"\x05\x02":
            return False, 0, None, f"SOCKS5 auth method rejected: {ver_method!r}"

        # 2. RFC 1929 username/password
        raw_sock.settimeout(_remaining())
        user_b = bridge_tag.encode("utf-8")[:255]
        pass_b = b"just1k-probe"
        raw_sock.sendall(b"\x01" + bytes([len(user_b)]) + user_b + bytes([len(pass_b)]) + pass_b)
        auth_resp = _recv_exact(raw_sock, 2)
        if auth_resp != b"\x01\x00":
            return False, 0, None, "SOCKS5 auth failed"

        # 3. SOCKS5 CONNECT (ATYP=0x03 domain)
        raw_sock.settimeout(_remaining())
        host_b = host.encode("idna")
        raw_sock.sendall(
            b"\x05\x01\x00\x03" + bytes([len(host_b)]) + host_b + port.to_bytes(2, "big")
        )
        hdr = _recv_exact(raw_sock, 4)
        if hdr[1] != 0:
            return False, 0, None, f"SOCKS5 connect error code {hdr[1]}"
        atyp = hdr[3]
        if atyp == 1:
            _recv_exact(raw_sock, 4)
        elif atyp == 3:
            alen = _recv_exact(raw_sock, 1)[0]
            _recv_exact(raw_sock, alen)
        elif atyp == 4:
            _recv_exact(raw_sock, 16)
        _recv_exact(raw_sock, 2)

        io_sock: socket.socket = raw_sock
        if parsed.scheme == "https":
            raw_sock.settimeout(_remaining())
            ctx = ssl.create_default_context()
            tls_sock = ctx.wrap_socket(raw_sock, server_hostname=host)
            tls_sock.settimeout(_remaining())
            io_sock = tls_sock

        req = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host_b.decode('ascii')}\r\n"
            f"User-Agent: just1k-bridge-probe/1.0\r\n"
            f"Accept: */*\r\n"
            f"Accept-Encoding: identity\r\n"
            f"Connection: close\r\n\r\n"
        ).encode("ascii")
        io_sock.settimeout(_remaining())
        io_sock.sendall(req)

        header_buf = bytearray()
        headers_parsed = False
        status_code = 0
        expected_content_len: Optional[int] = None
        while total_bytes < min_bytes + 4096:
            io_sock.settimeout(_remaining())
            chunk = io_sock.recv(16384)
            if not chunk:
                break
            if not headers_parsed:
                header_buf.extend(chunk)
                sep_idx = header_buf.find(b"\r\n\r\n")
                if sep_idx != -1:
                    headers_parsed = True
                    raw_head = header_buf[:sep_idx].decode("latin-1", errors="replace")
                    head_lines = raw_head.split("\r\n")
                    parts = head_lines[0].split()
                    if len(parts) >= 2 and parts[1].isdigit():
                        status_code = int(parts[1])
                    for hline in head_lines[1:]:
                        if ":" in hline:
                            hk, hv = hline.split(":", 1)
                            hv_s = hv.strip()
                            if hk.strip().lower() == "content-length" and hv_s.isascii() and hv_s.isdigit():
                                expected_content_len = int(hv_s)
                                break
                    body_part = header_buf[sep_idx + 4 :]
                    total_bytes += len(body_part)
                    if status_code < 200 or status_code >= 300 or status_code == 204:
                        return False, total_bytes, None, f"HTTP {status_code}"
                    if expected_content_len is not None and expected_content_len < min_bytes and total_bytes >= expected_content_len:
                        break
                    if total_bytes >= min_bytes:
                        break
                elif len(header_buf) > 16384:
                    return False, 0, None, "HTTP header too large"
            else:
                total_bytes += len(chunk)
                if expected_content_len is not None and expected_content_len < min_bytes and total_bytes >= expected_content_len:
                    break
                if total_bytes >= min_bytes:
                    break

        elapsed_ms = int((time.monotonic() - started) * 1000)
        if not headers_parsed:
            return False, total_bytes, elapsed_ms, "No HTTP response"
        if total_bytes < min_bytes:
            return False, total_bytes, elapsed_ms, f"Short payload ({total_bytes}/{min_bytes} bytes)"
        return True, total_bytes, elapsed_ms, None
    except socket.timeout:
        return False, total_bytes, None, "Timeout (possible TSPU silent stall)"
    except Exception as exc:
        return False, total_bytes, None, str(exc) or type(exc).__name__
    finally:
        for s in (tls_sock, raw_sock):
            if s is not None:
                try:
                    s.close()
                except Exception:
                    pass


async def _run_bridge_probe_cycle() -> None:
    if _is_apply_in_progress():
        return
    node_meta = get_node_state_metadata()
    if str(node_meta.get("role") or "") != "ru_hub":
        return
    socks_port, configured_tags = _get_probe_socks_config()
    if not socks_port or not configured_tags:
        return
    links = _load_links_data()
    if _is_apply_in_progress():
        return
    links_ips = _collect_links_bridge_ips(links)
    targets = _collect_ru_hub_probe_targets(links, configured_tags)
    if not targets:
        with _bridge_health_lock:
            for stale_ip in list(_bridge_health_state.keys()):
                if stale_ip not in links_ips:
                    _bridge_health_state.pop(stale_ip, None)
        return

    keep_ips = {t["ip"] for t in targets} | links_ips
    with _bridge_health_lock:
        for stale_ip in list(_bridge_health_state.keys()):
            if stale_ip not in keep_ips:
                _bridge_health_state.pop(stale_ip, None)

    for idx, target in enumerate(targets):
        if idx > 0:
            # Strict sequential spacing to avoid triggering TSPU TLS concurrency policing
            await asyncio.sleep(1.5)
        if _is_apply_in_progress():
            return
        ip = target["ip"]
        sni = target["sni"]
        tags = list(target.get("tags") or ([target["tag"]] if target.get("tag") else []))
        used_tag = tags[0] if tags else ""

        ok = False
        bytes_read = 0
        latency_ms = None
        err_msg = "No probe URL configured"
        for tag_idx, tag in enumerate(tags):
            if tag_idx > 0:
                await asyncio.sleep(0.5)
                if _is_apply_in_progress():
                    return
            used_tag = tag
            for url_idx, probe_url in enumerate(BRIDGE_PROBE_URLS):
                if url_idx > 0:
                    await asyncio.sleep(0.5)
                    if _is_apply_in_progress():
                        return
                ok, bytes_read, latency_ms, err_msg = await asyncio.to_thread(
                    _probe_via_socks5_sync,
                    socks_port,
                    tag,
                    probe_url,
                    BRIDGE_PROBE_MIN_BYTES,
                    BRIDGE_PROBE_TIMEOUT,
                )
                if _is_apply_in_progress():
                    return
                if ok:
                    break
            if ok:
                break

        if _is_apply_in_progress():
            return
        now_ts = time.time()
        with _bridge_health_lock:
            prev = _bridge_health_state.get(ip, {})
            if ok:
                fails = 0
                succs = int(prev.get("consecutive_successes", 0)) + 1
            else:
                fails = int(prev.get("consecutive_fails", 0)) + 1
                succs = 0
            _bridge_health_state[ip] = {
                "ip": ip,
                "sni": sni,
                "tag": used_tag,
                "ok": ok,
                "bytes_read": bytes_read,
                "latency_ms": latency_ms,
                "error": err_msg,
                "consecutive_fails": fails,
                "consecutive_successes": succs,
                "checked_at": now_ts,
            }


def _get_bridge_health_snapshot() -> Dict[str, Dict[str, Any]]:
    with _bridge_health_lock:
        return copy.deepcopy(_bridge_health_state)


async def _bridge_probe_loop() -> None:
    await asyncio.sleep(5.0)
    while True:
        cycle_started = time.monotonic()
        try:
            await _run_bridge_probe_cycle()
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.debug("Bridge probe cycle error: %s", exc)
        elapsed = time.monotonic() - cycle_started
        await asyncio.sleep(max(5.0, float(BRIDGE_PROBE_INTERVAL) - elapsed))


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup: restore clients to Xray strictly as ephemeral hints
    node_sync_state["status"] = "unsynchronized"
    node_sync_state["last_synced_at"] = None
    target_inbounds = get_target_inbounds()
    logger.info("Starting Just1kBot Xray API Agent on inbounds: %s", target_inbounds)
    bg_task = None
    bridge_probe_task = None
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
                "Xray gRPC is not immediately available at startup. Spawning background retry task."
            )

            async def _background_retry_sync():
                while True:
                    await asyncio.sleep(5)
                    try:
                        if grpc_client.is_healthy():
                            curr_epoch = epoch_manager.get_current_running_epoch() if epoch_manager else None
                            if not curr_epoch and epoch_manager:
                                curr_epoch = epoch_manager.load_state().get("node_epoch")
                            sync_active_users_with_epoch(curr_epoch)
                            if grpc_client._active_users_epoch == curr_epoch:
                                logger.info("Background startup client restoration succeeded.")
                                break
                    except Exception as exc:
                        logger.debug("Background startup retry attempt failed: %s", exc)

            bg_task = asyncio.create_task(_background_retry_sync())
    except Exception as e:
        logger.error("Startup client restoration error: %s", e)
    if str(get_node_state_metadata().get("role") or "") == "ru_hub":
        bridge_probe_task = asyncio.create_task(_bridge_probe_loop())
    yield
    # Shutdown
    tasks_to_await = []
    for t in (bridge_probe_task, bg_task):
        if t is not None and not t.done():
            t.cancel()
            tasks_to_await.append(t)
    if tasks_to_await:
        await asyncio.gather(*tasks_to_await, return_exceptions=True)
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
                client_ip = request.client.host if request.client else ""
                if client_ip in ("", "127.0.0.1", "::1"):
                    xff = (request.headers.get("X-Forwarded-For") or "").split(",")[0].strip()
                    xri = (request.headers.get("X-Real-IP") or "").strip()
                    client_ip = xri or xff
                if client_ip and client_ip not in ("127.0.0.1", "::1"):
                    _record_bot_activity(client_ip)
            except Exception:
                pass
    return await call_next(request)


_FAILED_AUTH_WINDOW_SECONDS = 60.0
_FAILED_AUTH_MAX_ATTEMPTS = 15
_FAILED_AUTH_LOCKOUT_SECONDS = 120.0
_FAILED_AUTH_MAX_ENTRIES = 4096
_failed_auth_lock = threading.Lock()
_failed_auth_attempts: Dict[str, List[float]] = {}
_failed_auth_blocked_until: Dict[str, float] = {}


def _check_auth_rate_limit(client_ip: str) -> Optional[int]:
    """Return remaining block seconds if IP exceeded failed auth attempts, else None."""
    now = time.monotonic()
    with _failed_auth_lock:
        blocked_until = _failed_auth_blocked_until.get(client_ip, 0.0)
        if blocked_until > now:
            return max(1, int(blocked_until - now))
        if blocked_until:
            _failed_auth_blocked_until.pop(client_ip, None)
    return None


def _record_auth_failure(client_ip: str) -> None:
    """Record a failed X-API-Key attempt and temporarily block abusive IPs."""
    now = time.monotonic()
    with _failed_auth_lock:
        recent = [
            ts for ts in _failed_auth_attempts.pop(client_ip, [])
            if now - ts <= _FAILED_AUTH_WINDOW_SECONDS
        ]
        recent.append(now)
        if len(recent) >= _FAILED_AUTH_MAX_ATTEMPTS:
            _failed_auth_blocked_until.pop(client_ip, None)
            if len(_failed_auth_blocked_until) >= _FAILED_AUTH_MAX_ENTRIES:
                expired_blocked = [
                    ip for ip, until in _failed_auth_blocked_until.items()
                    if until <= now
                ]
                for ip in expired_blocked:
                    _failed_auth_blocked_until.pop(ip, None)
                while len(_failed_auth_blocked_until) >= _FAILED_AUTH_MAX_ENTRIES:
                    _failed_auth_blocked_until.pop(next(iter(_failed_auth_blocked_until)))
            _failed_auth_blocked_until[client_ip] = now + _FAILED_AUTH_LOCKOUT_SECONDS
            logger.warning("Temporarily blocked %s after %d failed X-API-Key attempts", client_ip, len(recent))
        else:
            if len(_failed_auth_attempts) >= _FAILED_AUTH_MAX_ENTRIES:
                expired_ips: List[str] = []
                for ip, attempts in _failed_auth_attempts.items():
                    active = [ts for ts in attempts if now - ts <= _FAILED_AUTH_WINDOW_SECONDS]
                    if active:
                        _failed_auth_attempts[ip] = active
                    else:
                        expired_ips.append(ip)
                for ip in expired_ips:
                    _failed_auth_attempts.pop(ip, None)
                while len(_failed_auth_attempts) >= _FAILED_AUTH_MAX_ENTRIES:
                    _failed_auth_attempts.pop(next(iter(_failed_auth_attempts)))
            _failed_auth_attempts[client_ip] = recent


# Security dependency
def verify_api_key(
    request: Request,
    x_api_key: Optional[str] = Header(None, alias="X-API-Key"),
):
    client_ip = request.client.host if request.client else "unknown"
    retry_after = _check_auth_rate_limit(client_ip)
    if retry_after is not None:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Too many failed authentication attempts",
            headers={"Retry-After": str(retry_after)},
        )

    expected_key = os.getenv("XRAY_API_KEY") or API_KEY
    if not expected_key:
        logger.error("XRAY_API_KEY is not configured on the node")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Node API key is not configured",
        )
    if not x_api_key or not secrets.compare_digest(x_api_key, expected_key):
        _record_auth_failure(client_ip)
        logger.warning(
            "Unauthorized access attempt from %s with X-API-Key: %s",
            client_ip,
            "present" if x_api_key else "missing",
        )
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing X-API-Key",
        )
    return True


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


# Endpoints
@app.get("/healthz")
@app.get("/health")
def healthcheck(response: Response) -> Dict[str, Any]:
    """
    Lightweight liveness and readiness probe for external monitoring (e.g. Uptime Kuma, Prometheus, Consul).
    Does not require an API key and does not expose confidential node metadata or client lists.
    Fail-closed: returns HTTP 200 when Xray core is running, gRPC responds, and active users epoch matches, or HTTP 503 otherwise.
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
    if is_running and running_epoch and grpc_client._active_users_epoch != running_epoch:
        try:
            sync_active_users_with_epoch(running_epoch, blocking=False)
        except Exception as e:
            logger.error("Healthcheck epoch sync failed: %s", e)
    epoch_synced = True
    if running_epoch and grpc_client._active_users_epoch != running_epoch:
        epoch_synced = False

    if not is_running or not epoch_synced:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE

    return {
        "ok": is_running and epoch_synced,
        "status": "ok" if (is_running and epoch_synced) else "error",
        "service": "xray-api",
        "xray_running": is_running,
        "grpc_ok": bool(grpc_ok),
        "epoch_synced": epoch_synced,
    }


def _get_system_load_info(disk_usage_info: Dict[str, Any] | None = None) -> Dict[str, Any]:
    """Lightweight host load telemetry (CPU, RAM, Disk) with zero external dependencies."""
    load_1m = 0.0
    cpu_cores = os.cpu_count() or 1
    try:
        if hasattr(os, "getloadavg"):
            load_1m = round(float(os.getloadavg()[0]), 2)
        elif os.path.exists("/proc/loadavg"):
            with open("/proc/loadavg", "r", encoding="ascii", errors="replace") as f:
                load_1m = round(float(f.read().split()[0]), 2)
    except Exception:
        load_1m = 0.0

    cpu_percent = round(min(100.0, max(0.0, (load_1m / cpu_cores) * 100.0)), 1)

    ram_used_percent = 0.0
    try:
        proc_mem = "/proc/meminfo"
        if os.path.exists(proc_mem):
            mem: Dict[str, int] = {}
            with open(proc_mem, "r", encoding="ascii", errors="replace") as f:
                for line in f:
                    if ":" in line:
                        k, v = line.split(":", 1)
                        parts = v.strip().split()
                        if parts:
                            mem[k.strip()] = int(parts[0])
            total_kb = mem.get("MemTotal", 0)
            avail_kb = mem.get("MemAvailable", 0)
            if total_kb > 0:
                ram_used_percent = round(max(0.0, min(100.0, ((total_kb - avail_kb) / total_kb) * 100.0)), 1)
    except Exception:
        ram_used_percent = 0.0

    disk_pct = 0.0
    if isinstance(disk_usage_info, dict):
        try:
            disk_pct = float(disk_usage_info.get("used_percent") or 0.0)
        except (ValueError, TypeError):
            disk_pct = 0.0
    else:
        try:
            total, used, _ = shutil.disk_usage("/")
            disk_pct = round((used / total) * 100, 1) if total > 0 else 0.0
        except Exception:
            disk_pct = 0.0

    return {
        "cpu_percent": cpu_percent,
        "ram_percent": ram_used_percent,
        "disk_percent": disk_pct,
        "load_1m": load_1m,
        "cpu_cores": cpu_cores,
    }


def _build_node_status_payload(
    *,
    is_running: bool = True,
    grpc_ok: bool = True,
    active_clients_count: Optional[int] = None,
    services: Optional[List[str]] = None,
    capabilities: Optional[List[str]] = None,
    running_epoch: Optional[str] = None,
    boot_id: Optional[str] = None,
    starttime: Optional[int] = None,
    disk_usage_info: Optional[Dict[str, Any]] = None,
    system_load_info: Optional[Dict[str, Any]] = None,
    include_health_fields: bool = False,
) -> Dict[str, Any]:
    node_meta = get_node_state_metadata()
    modules = node_meta.get("modules") if isinstance(node_meta.get("modules"), dict) else {}
    bot_status = get_bot_status()
    links_data = _load_links_data()
    load_info = system_load_info if system_load_info is not None else _get_system_load_info(disk_usage_info)

    domain_str = str(node_meta.get("domain") or "")
    payload: Dict[str, Any] = {
        "status": "ok" if is_running else "error",
        "role": str(node_meta.get("role") or ""),
        "country_code": str(node_meta.get("country_code") or ""),
        "domain": domain_str,
        "cdn_domain": get_cdn_domain(),
        "cdn_domains": get_cdn_domains(),
        "sub_path_prefix": get_sub_path_prefix(),
        "secret_base_path": get_secret_base_path(),
        "bridge_uuid": str(node_meta.get("tunnel_uuid") or ""),
        "modules": modules,
        "module_errors": _load_module_errors(),
        "last_apply": _load_last_apply(),
        "ssl_cert": _load_ssl_cert_info(domain_str),
        "links": links_data,
        "sni_routes": _get_sni_routes(links_data),
        "xhttp_locations": _get_xhttp_location_routes(),
        "inbounds": get_all_managed_inbounds(),
        "traffic_limit": _load_traffic_limit_summary(),
        "bot_connected": bool(bot_status.get("connected")),
        "bot_last_seen_at": bot_status.get("last_seen_at"),
        "system_load": load_info,
    }

    if include_health_fields:
        payload.update({
            "xray_running": is_running,
            "grpc_ok": bool(grpc_ok),
            "active_clients_count": active_clients_count if active_clients_count is not None else 0,
            "services": services or [],
            "capabilities": capabilities or [],
            "node_epoch": running_epoch if is_running else None,
            "boot_id": boot_id if is_running else None,
            "starttime": starttime if is_running else None,
            "sync_status": node_sync_state.get("status", "unsynchronized"),
            "synchronized": node_sync_state.get("status") == "synchronized",
            "last_synced_at": node_sync_state.get("last_synced_at"),
            "disk_usage": disk_usage_info or {},
        })
        if str(node_meta.get("role") or "") == "ru_hub":
            payload["bridge_health"] = _get_bridge_health_snapshot()

    return payload


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

    node_meta = get_node_state_metadata()
    role = str(node_meta.get("role") or "")
    modules = node_meta.get("modules") if isinstance(node_meta.get("modules"), dict) else {}
    has_cdn_module = any(
        isinstance(modules.get(k), dict) and bool(modules[k].get("enabled"))
        for k in modules
        if str(k).startswith("cdn_")
    )
    has_wl_module = (
        isinstance(modules.get("vless_xhttp"), dict)
        and bool(modules["vless_xhttp"].get("enabled"))
        and has_cdn_module
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
    if "bridge_hub" in detected_services:
        capabilities.append("bridge_hub")
    if "exit_node" in detected_services:
        capabilities.append("exit_node")

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
        if grpc_client._active_users_epoch != running_epoch:
            response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE

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

    system_load_info = _get_system_load_info(disk_usage_info)

    return _build_node_status_payload(
        is_running=is_running,
        grpc_ok=grpc_ok,
        active_clients_count=len(active_clients),
        services=detected_services,
        capabilities=capabilities,
        running_epoch=running_epoch if is_running else None,
        boot_id=boot_id if is_running else None,
        starttime=starttime if is_running else None,
        disk_usage_info=disk_usage_info,
        system_load_info=system_load_info,
        include_health_fields=True,
    )


@app.get("/v1/node/status")
def get_node_status_endpoint(_: bool = Depends(verify_api_key)) -> Dict[str, Any]:
    """Read-only v2 hub auto-discovery metadata (role, modules, errors, links, bot)."""
    return _build_node_status_payload(include_health_fields=False)


@app.put("/v1/node/links")
def update_node_links(
    req: NodeLinksUpdateRequest,
    _: bool = Depends(verify_api_key),
) -> Dict[str, Any]:
    """Atomically saves Admin-defined node topology links and queues root config apply."""
    node_meta = get_node_state_metadata()
    role = str(node_meta.get("role") or "")
    payload = req.model_dump(exclude_none=True)

    lp = _links_file_path()
    existing_matches = False
    if lp.exists():
        try:
            existing_raw = json.loads(lp.read_text(encoding="utf-8"))
            if isinstance(existing_raw, dict) and existing_raw == payload:
                existing_matches = True
        except Exception:
            existing_matches = False

    if existing_matches:
        if _is_apply_in_progress():
            return {
                "status": "ok",
                "role": role,
                "apply_queued": True,
                "unchanged": True,
                "links": payload,
            }
        last_apply_ok = False
        last_apply_path = STATE_FILE_PATH.parent / "last_apply.json"
        if last_apply_path.exists():
            try:
                last_apply_data = json.loads(last_apply_path.read_text(encoding="utf-8"))
                last_apply_ok = isinstance(last_apply_data, dict) and last_apply_data.get("ok") is True
            except Exception:
                last_apply_ok = False
        if last_apply_ok:
            return {
                "status": "ok",
                "role": role,
                "apply_queued": False,
                "unchanged": True,
                "links": payload,
            }
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
                    if name == "lo" or name.startswith(("docker", "veth", "br-", "tun", "tap")):
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
    On transit roles (eu_hub, exit_node), skips user gRPC stats and returns host network counters.
    Fail-closed: requires genuine running process, valid starttime, boot_id, and matching epoch.
    """
    node_meta = get_node_state_metadata()
    node_role = str(node_meta.get("role") or "").strip().lower()
    if node_role in ("eu_hub", "exit_node"):
        tx_bytes, rx_bytes = _get_host_net_bytes()
        pid, starttime, boot_id, epoch = (
            epoch_manager.get_process_and_epoch() if epoch_manager else (None, None, None, None)
        )
        return {
            "node_epoch": epoch or "",
            "boot_id": boot_id or "",
            "starttime": starttime or 0,
            "timestamp": int(time.time()),
            "users": {},
            "host_tx_bytes": tx_bytes,
            "host_rx_bytes": rx_bytes,
        }

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
            users_stats = await asyncio.to_thread(grpc_client.get_users_stats, reset=False)
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
            users_by_service: Dict[str, Dict[str, Dict[str, int]]] = {
                "vless": {},
                "white_internet": {},
            }
            merged_users: Dict[str, Dict[str, int]] = {}
            for raw_email, st_vals in users_stats.items():
                up_v = int((st_vals or {}).get("uplink", 0) or 0)
                dn_v = int((st_vals or {}).get("downlink", 0) or 0)
                if raw_email.endswith(":std"):
                    base_uid = raw_email.split(":")[0]
                    svc_bucket = users_by_service["vless"].setdefault(base_uid, {"uplink": 0, "downlink": 0})
                    svc_bucket["uplink"] += up_v
                    svc_bucket["downlink"] += dn_v
                elif raw_email.endswith(":wi"):
                    base_uid = raw_email.split(":")[0]
                    svc_bucket = users_by_service["white_internet"].setdefault(base_uid, {"uplink": 0, "downlink": 0})
                    svc_bucket["uplink"] += up_v
                    svc_bucket["downlink"] += dn_v
                else:
                    base_uid = raw_email
                m_bucket = merged_users.setdefault(base_uid, {"uplink": 0, "downlink": 0})
                m_bucket["uplink"] += up_v
                m_bucket["downlink"] += dn_v

            return {
                "node_epoch": epoch1,
                "boot_id": boot_id1,
                "starttime": starttime1,
                "timestamp": int(time.time()),
                "users": merged_users,
                "users_by_service": users_by_service,
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


def _sync_client_cached_lookup_sync(
    req: ClientSyncRequest, client_uuid: str, desired_state: str
) -> Optional[Dict[str, Any]]:
    cached = completed_idempotent_ops.get(req.idempotency_key)
    if cached is None:
        return None
    cached_epoch = cached.get("verified_epoch")
    current_epoch = epoch_manager.get_current_running_epoch() if epoch_manager else None
    if not current_epoch and epoch_manager:
        current_epoch = epoch_manager.load_state().get("node_epoch")

    effective_svc = resolve_effective_service(req.service)
    client_id_matches = cached.get("client_id") == client_uuid
    state_matches = cached.get("state") == desired_state
    if not client_id_matches or not state_matches:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Idempotency key '{req.idempotency_key}' was previously used with different parameters",
        )

    version_matches = (req.version is None) or (cached.get("version") == req.version)
    service_matches = cached.get("service") in (effective_svc, None) or req.service is None
    epoch_valid = (
        version_matches
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
                stored_active = (
                    svc_state.get("is_active")
                    if (svc_state and svc_state.get("is_active") is not None)
                    else stored_entry.get("is_active")
                )
                want_active = desired_state == "active"
                if (
                    stored_tombstone
                    or (
                        req.version is not None
                        and stored_ver is not None
                        and stored_ver > req.version
                    )
                    or (stored_active is not None and bool(stored_active) != want_active)
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
    return None


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
            cached_resp = await asyncio.to_thread(
                _sync_client_cached_lookup_sync, req, client_uuid, desired_state
            )
            if cached_resp is not None:
                return cached_resp
            async with _state_mutation_lock:
                return await _sync_client_internal(req, client_uuid, desired_state)

    async with _state_mutation_lock:
        return await _sync_client_internal(req, client_uuid, desired_state)


_state_mutation_lock = asyncio.Lock()
_batch_sync_lock = _state_mutation_lock


def _batch_sync_clients_sync(req: ClientBatchSyncRequest) -> Dict[str, Any]:
    node_meta = get_node_state_metadata()
    node_role = str(node_meta.get("role") or "").strip().lower()
    if node_role in ("eu_hub", "exit_node"):
        curr_ep = (epoch_manager.get_current_running_epoch() if epoch_manager else "") or ""
        return {
            "status": "ok",
            "message": f"Client synchronization is a no-op on {node_role} node",
            "running_epoch": curr_ep,
            "succeeded": [item.uuid for item in req.clients],
            "failed": {},
        }

    succeeded: List[str] = []
    failed: Dict[str, str] = {}
    pending_mutations: List[tuple[str, bool, Optional[int], Optional[str], str, Dict[str, str]]] = []
    pending_idempotency: List[tuple[str, Dict[str, Any]]] = []
    try:
        preloaded_entries = client_store.load_client_entries()
    except Exception as exc:
        logger.error("Failed to load client_store before batch-sync: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to load persisted client state: {exc}",
        ) from exc

    working_entries = copy.deepcopy(preloaded_entries)
    try:
        for item in req.clients:
            try:
                clean_uuid = str(uuid_lib.UUID((item.uuid or "").strip())).lower()
                desired_state = (
                    "active"
                    if (
                        item.desired_state == "active"
                        or (item.desired_state is None and item.is_active is True)
                    )
                    else "disabled"
                )
                sync_res = _sync_client_unlocked_sync(
                    item,
                    clean_uuid,
                    desired_state,
                    persist_to_store=False,
                    preloaded_entries=working_entries,
                )
                eff_svc = resolve_effective_service(item.service)
                if isinstance(sync_res, dict) and sync_res.get("result") == "already_newer":
                    node_tombstone = bool(sync_res.get("tombstone", False))
                    node_state = sync_res.get("state")
                    if (node_tombstone and desired_state == "active") or (node_state != desired_state):
                        failed[clean_uuid] = (
                            f"already_newer: node state={node_state} tombstone={node_tombstone} "
                            f"version={sync_res.get('version')}"
                        )
                    else:
                        succeeded.append(clean_uuid)
                else:
                    init_states = (
                        sync_res.pop("initial_states", {})
                        if isinstance(sync_res, dict)
                        else {}
                    )
                    client_store._mutate_entry(
                        working_entries,
                        clean_uuid,
                        active=(desired_state == "active"),
                        version=item.version,
                        email=item.email,
                        service=eff_svc,
                    )
                    pending_mutations.append(
                        (
                            clean_uuid,
                            desired_state == "active",
                            item.version,
                            item.email,
                            eff_svc,
                            init_states if isinstance(init_states, dict) else {},
                        )
                    )
                    if getattr(item, "idempotency_key", None) and isinstance(sync_res, dict):
                        pending_idempotency.append((item.idempotency_key, sync_res))
                    succeeded.append(clean_uuid)
            except HTTPException as exc:
                failed[str(item.uuid)] = str(exc.detail)
            except Exception as exc:
                failed[str(item.uuid)] = str(exc)
    finally:
        if pending_mutations:
            lock_fd = None
            persist_error: Optional[Exception] = None
            try:
                client_store._ensure_dir()
                lock_fd = client_store._acquire_lock()
                entries = client_store.load_client_entries()
                for c_uid, is_act, ver, em, svc, _init_st in pending_mutations:
                    disk_entry = entries.get(c_uid)
                    if isinstance(disk_entry, dict):
                        svc_key = client_store.canonicalize_service(svc)
                        svc_states = disk_entry.get("service_states") or {}
                        disk_svc = svc_states.get(svc_key) if svc_key else None
                        disk_tomb = (
                            disk_svc.get("tombstone", False)
                            if isinstance(disk_svc, dict)
                            else disk_entry.get("tombstone", False)
                        )
                        disk_ver = (
                            disk_svc.get("version")
                            if isinstance(disk_svc, dict)
                            else disk_entry.get("version")
                        )
                        if disk_tomb or (ver is not None and disk_ver is not None and disk_ver > ver):
                            continue
                    client_store._mutate_entry(
                        entries, c_uid, active=is_act, version=ver, email=em, service=svc
                    )
                if not client_store.save_client_entries(entries):
                    raise RuntimeError("save_client_entries returned False")
            except Exception as exc:
                persist_error = exc
            finally:
                if lock_fd is not None:
                    client_store._release_lock(lock_fd)

            if persist_error is not None:
                logger.error("Batch client_store persist failed: %s", persist_error)
                for c_uid, _is_act, _ver, em, svc, init_states in reversed(pending_mutations):
                    orig_entry = preloaded_entries.get(c_uid)
                    for tag in get_target_inbounds(service=svc):
                        try:
                            mail = _xray_email_for_inbound(
                                c_uid,
                                tag,
                                svc,
                                explicit_email=em,
                                stored_entry=orig_entry,
                            )
                            init_st = init_states.get(tag, "disabled")
                            grpc_client.ensure_user_state(
                                tag, c_uid, desired_state=init_st, flow=get_inbound_flow(tag), email=mail
                            )
                        except Exception:
                            pass
                raise HTTPException(
                    status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                    detail=f"Failed to persist batch client state: {persist_error}",
                ) from persist_error

            for idem_key, idem_resp in pending_idempotency:
                completed_idempotent_ops[idem_key] = idem_resp

    if not failed:
        node_sync_state["status"] = "synchronized"
        node_sync_state["last_synced_at"] = time.time()

    return {
        "status": "ok" if not failed else "partial",
        "succeeded": succeeded,
        "failed": failed,
    }


@app.post("/v1/clients/batch-sync")
async def batch_sync_clients(
    req: ClientBatchSyncRequest,
    _: bool = Depends(verify_api_key),
) -> Dict[str, Any]:
    """Batch-synchronizes a list of clients with per-UUID result tracking."""
    async with _state_mutation_lock:
        return await asyncio.to_thread(_batch_sync_clients_sync, req)


async def _sync_client_internal(
    req: ClientSyncRequest,
    client_uuid: str,
    desired_state: str,
    *,
    persist_to_store: bool = True,
    preloaded_entries: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    uuid_lock = await _get_inflight_op_lock(f"uuid:{client_uuid}")
    async with uuid_lock:
        return await asyncio.to_thread(
            _sync_client_unlocked_sync,
            req,
            client_uuid,
            desired_state,
            persist_to_store=persist_to_store,
            preloaded_entries=preloaded_entries,
        )


def _sync_client_unlocked_sync(
    req: ClientSyncRequest,
    client_uuid: str,
    desired_state: str,
    *,
    persist_to_store: bool = True,
    preloaded_entries: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    node_meta = get_node_state_metadata()
    node_role = str(node_meta.get("role") or "").strip().lower()
    if node_role in ("eu_hub", "exit_node"):
        curr_ep = (epoch_manager.get_current_running_epoch() if epoch_manager else "") or ""
        return {
            "status": "success",
            "message": f"Client synchronization is a no-op on {node_role} node",
            "inbounds": [],
            "running_epoch": curr_ep,
        }

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
    curr_entry: Optional[Dict[str, Any]] = None
    if preloaded_entries is not None:
        curr_entry = preloaded_entries.get(client_uuid)
    else:
        try:
            entries = client_store.load_client_entries()
            curr_entry = entries.get(client_uuid)
        except ClientStoreCorruptedError as e:
            if req.version is not None:
                logger.critical("Cannot sync client: client store corrupted: %s", e)
                raise HTTPException(
                    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                    detail=f"Client store corrupted: {e}",
                ) from e
            logger.warning("Client store corrupted during unversioned sync lookup: %s", e)

    if req.version is not None:
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
                        em = _xray_email_for_inbound(
                            client_uuid,
                            tag,
                            effective_service,
                            explicit_email=getattr(req, "email", None),
                            stored_entry=curr_entry,
                        )
                        if desired_state == "active":
                            if not grpc_client.probe_user_presence(tag, client_uuid, email=em):
                                inbounds_healthy = False
                                break
                        else:
                            if not grpc_client.verify_user_absent(tag, client_uuid, email=em):
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
                    idem_resp: Dict[str, Any] = {
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
                    if not persist_to_store:
                        idem_resp["initial_states"] = {t: curr_state for t in target_inbounds}
                    return idem_resp
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
                        em = _xray_email_for_inbound(
                            client_uuid,
                            tag,
                            effective_service,
                            explicit_email=req.email,
                            stored_entry=curr_entry,
                        )
                        if curr_state == "active" and not is_tombstone:
                            if grpc_client.probe_user_presence(tag, client_uuid, email=em):
                                verified_inbounds.append(tag)
                        else:
                            if grpc_client.verify_user_absent(tag, client_uuid, email=em):
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

    req_email = getattr(req, "email", None)
    # Capture initial runtime state before mutations for deterministic rollback
    initial_states: Dict[str, str] = {}
    for tag in target_inbounds:
        try:
            em = _xray_email_for_inbound(
                client_uuid, tag, effective_service, explicit_email=req_email, stored_entry=curr_entry
            )
            initial_states[tag] = "active" if grpc_client.probe_user_presence(tag, client_uuid, email=em) else "disabled"
        except Exception:
            initial_states[tag] = "disabled"

    # Execute mutation across all target inbounds
    succeeded_inbounds: List[str] = []
    failed_inbounds: List[str] = []
    for tag in target_inbounds:
        try:
            em = _xray_email_for_inbound(
                client_uuid, tag, effective_service, explicit_email=req_email, stored_entry=curr_entry
            )
            grpc_client.ensure_user_state(
                tag, client_uuid, desired_state=desired_state, flow=get_inbound_flow(tag), email=em
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
                em = _xray_email_for_inbound(
                    client_uuid, rb_tag, effective_service, explicit_email=req_email, stored_entry=curr_entry
                )
                grpc_client.ensure_user_state(
                    rb_tag, client_uuid, desired_state=init_st, flow=get_inbound_flow(rb_tag), email=em
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
            em = _xray_email_for_inbound(
                client_uuid, tag, effective_service, explicit_email=req_email, stored_entry=curr_entry
            )
            if desired_state == "active":
                is_verified = grpc_client.probe_user_presence(tag, client_uuid, email=em)
            else:
                is_verified = grpc_client.verify_user_absent(tag, client_uuid, email=em)
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
                em = _xray_email_for_inbound(
                    client_uuid, rb_tag, effective_service, explicit_email=req_email, stored_entry=curr_entry
                )
                grpc_client.ensure_user_state(
                    rb_tag, client_uuid, desired_state=init_st, flow=get_inbound_flow(rb_tag), email=em
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
    if persist_to_store:
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
                    em = _xray_email_for_inbound(
                        client_uuid, rb_tag, effective_service, explicit_email=req_email, stored_entry=curr_entry
                    )
                    grpc_client.ensure_user_state(
                        rb_tag, client_uuid, desired_state=init_st, flow=get_inbound_flow(rb_tag), email=em
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
    node_sync_state["status"] = "synchronized"
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

    if not persist_to_store:
        resp["initial_states"] = initial_states
    elif req.idempotency_key:
        completed_idempotent_ops[req.idempotency_key] = resp

    return resp


def _delete_client_sync(
    clean_uuid: str,
    version: Optional[int],
    service: Optional[str],
) -> Dict[str, Any]:
    node_meta = get_node_state_metadata()
    node_role = str(node_meta.get("role") or "").strip().lower()
    if node_role in ("eu_hub", "exit_node"):
        curr_ep = (epoch_manager.get_current_running_epoch() if epoch_manager else "") or ""
        return {
            "status": "success",
            "message": f"Client deprovision is a no-op on {node_role} node",
            "inbounds": [],
            "running_epoch": curr_ep,
        }

    eff_service = resolve_effective_service(service) if service else None
    target_inbounds = get_target_inbounds(service=eff_service) if eff_service else get_all_managed_inbounds()
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
    sync_active_users_with_epoch(current_epoch)

    # Monotonic version check
    if version is not None:
        entries = client_store.load_client_entries()
        curr_entry = entries.get(clean_uuid)
        if curr_entry:
            service_states = (
                curr_entry.get("service_states")
                if isinstance(curr_entry.get("service_states"), dict)
                else {}
            )
            if eff_service:
                curr_svc_state = (
                    service_states.get(eff_service, {})
                    if isinstance(service_states.get(eff_service), dict)
                    else {}
                )
                curr_ver = curr_svc_state.get("version")
                is_tombstone = curr_svc_state.get("tombstone", False)
            else:
                curr_ver = curr_entry.get("version")
                is_tombstone = curr_entry.get("tombstone", False)

            if curr_ver is not None and version == curr_ver and is_tombstone:
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
                return {
                    "status": "ok",
                    "client_id": clean_uuid,
                    "result": "already_newer",
                    "fenced": True,
                    "version": curr_ver,
                    "inbounds": target_inbounds,
                }

    entries_for_del = client_store.load_client_entries()
    stored_del_entry = (
        entries_for_del.get(clean_uuid) if isinstance(entries_for_del, dict) else None
    )
    failed_inbounds: List[str] = []
    for tag in target_inbounds:
        try:
            em = _xray_email_for_inbound(
                clean_uuid,
                tag,
                eff_service,
                stored_entry=stored_del_entry,
            )
            grpc_client.remove_user(tag, clean_uuid, email=em)
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

    epoch_after = epoch_manager.get_current_running_epoch() if epoch_manager else current_epoch
    if epoch_after != current_epoch:
        raise HTTPException(
            status_code=status.HTTP_412_PRECONDITION_FAILED,
            detail="epoch_drift_during_mutation: Xray instance changed during delete",
        )

    try:
        client_store.delete_client(clean_uuid, version=version, service=eff_service)
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
        "service": eff_service,
        "inbounds": target_inbounds,
    }


@app.delete("/v1/clients/{uuid}")
async def delete_client(
    uuid: str,
    version: Optional[int] = None,
    service: Optional[str] = None,
    _: bool = Depends(verify_api_key),
) -> Dict[str, Any]:
    """
    Deletes client from managed inbounds (optionally scoped by service) with lock & epoch fencing.
    """
    try:
        clean_uuid = str(uuid_lib.UUID(uuid.strip())).lower()
    except ValueError:
        raise HTTPException(
            status_code=422,
            detail=f"Invalid UUID: {uuid}",
        ) from None

    uuid_lock = await _get_inflight_op_lock(f"uuid:{clean_uuid}")
    async with _state_mutation_lock, uuid_lock:
        return await asyncio.to_thread(_delete_client_sync, clean_uuid, version, service)


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

    stored_entries = {}
    try:
        stored_entries = await asyncio.to_thread(client_store.load_client_entries)
    except ClientStoreCorruptedError as e:
        logger.critical("Inventory cannot load entries from corrupt store: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Client store corrupted: {e}",
        ) from e
    except Exception as e:
        logger.warning("Could not load stored client entries for inventory: %s", e)

    eff_req_svc = resolve_effective_service(req.service) if (req and req.service) else None
    if not client_ids:
        client_ids = [
            cid
            for cid, meta in stored_entries.items()
            if isinstance(meta, dict) and _is_entry_active_for_service(meta, eff_req_svc)
        ]

    inventory: Dict[str, Any] = {}
    for cid in client_ids:
        try:
            clean_cid = str(uuid_lib.UUID(str(cid).strip())).lower()
        except ValueError:
            continue

        inbound_presence: Dict[str, bool] = {}
        stored_cid_entry = (
            stored_entries.get(clean_cid) if isinstance(stored_entries, dict) else None
        )
        for tag in target_inbounds:
            try:
                em = _xray_email_for_inbound(
                    clean_cid,
                    tag,
                    eff_req_svc,
                    stored_entry=stored_cid_entry,
                )
                present = grpc_client.probe_user_presence(tag, clean_cid, email=em)
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





