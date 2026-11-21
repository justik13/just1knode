import json
import logging
import os
import secrets
import time
from pathlib import Path
from typing import Any, Dict, Optional, Set

try:
    import fcntl
except ImportError:
    fcntl = None  # type: ignore

logger = logging.getLogger("xray_api.client_store")


class ClientStoreCorruptedError(RuntimeError):
    """Raised when clients.json exists but is unparseable or corrupted."""

    pass


class ClientStore:
    """Manages persistent active client UUIDs and versions in a local JSON file (Zero-Loss State) with file locking.

    Note: Local clients.json is strictly an ephemeral crash-recovery hint, NEVER the authoritative SSOT.
    Authoritative state is managed by the Central Database.
    """

    def __init__(self, file_path: Path):
        self.file_path = Path(file_path)
        self.lock_path = Path(f"{self.file_path}.lock")

    def _ensure_dir(self) -> None:
        try:
            self.file_path.parent.mkdir(parents=True, exist_ok=True)
            self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        except Exception as e:
            logger.warning("Could not create directory %s: %s", self.file_path.parent, e)

    def load_client_entries(self) -> Dict[str, Dict[str, Any]]:
        """Loads all client metadata entries {uuid: {is_active: bool, version: int, updated_at: float}}."""
        if not self.file_path.exists():
            return {}
        if self.file_path.stat().st_size == 0:
            raise ClientStoreCorruptedError(
                f"Client store file exists but is empty (0 bytes): {self.file_path}"
            )
        try:
            with open(self.file_path, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    if len(data) == 0:
                        return {}
                    clients_val = data.get("clients")
                    if isinstance(clients_val, dict):
                        return clients_val
                    raise ClientStoreCorruptedError(
                        f"Unexpected clients field in {self.file_path}: {type(clients_val)}"
                    )
                raise ClientStoreCorruptedError(
                    f"Unexpected JSON structure in {self.file_path}: {type(data)}"
                )
        except json.JSONDecodeError as jde:
            logger.critical("Corruption detected in %s: %s", self.file_path, jde)
            raise ClientStoreCorruptedError(f"Corrupted JSON in {self.file_path}: {jde}") from jde
        except ClientStoreCorruptedError:
            raise
        except Exception as e:
            logger.error("Failed to read %s: %s", self.file_path, e)
            raise ClientStoreCorruptedError(f"Failed to read {self.file_path}: {e}") from e

    def load_clients(self) -> Set[str]:
        """Returns set of currently active client UUIDs, excluding tombstones."""
        entries = self.load_client_entries()
        return {
            u
            for u, meta in entries.items()
            if meta.get("is_active", True) is True and not meta.get("tombstone", False)
        }

    def save_client_entries(self, entries: Dict[str, Dict[str, Any]]) -> bool:
        self._ensure_dir()
        temp_path = self.file_path.with_name(
            f"{self.file_path.name}.{os.getpid()}.{secrets.token_hex(6)}.tmp"
        )
        now_ts = time.time()
        tombstone_cutoff = now_ts - (14 * 86400.0)
        pruned_entries = {
            u: m
            for u, m in entries.items()
            if not (m.get("tombstone") is True and float(m.get("updated_at", 0)) < tombstone_cutoff)
        }
        if len(pruned_entries) < len(entries):
            entries.clear()
            entries.update(pruned_entries)

        data = {
            "clients": entries,
            "updated_at": now_ts,
            "count": len(
                [
                    u
                    for u, m in entries.items()
                    if m.get("is_active", True) is True and not m.get("tombstone", False)
                ]
            ),
        }
        try:
            with open(temp_path, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
                f.flush()
                os.fsync(f.fileno())
            temp_path.replace(self.file_path)
            try:
                os.chmod(self.file_path, 0o660)
            except Exception:
                pass
            try:
                dir_fd = os.open(
                    str(self.file_path.parent), getattr(os, "O_DIRECTORY", 0) | os.O_RDONLY
                )
                try:
                    os.fsync(dir_fd)
                finally:
                    os.close(dir_fd)
            except Exception:
                pass
            return True
        except Exception as e:
            logger.error("Failed to save clients to %s: %s", self.file_path, e)
            return False
        finally:
            try:
                temp_path.unlink(missing_ok=True)
            except Exception:
                pass

    def _acquire_lock(self):
        if fcntl is None:
            return None
        lock_fd = None
        try:
            lock_fd = open(self.lock_path, "a")
            try:
                os.chmod(self.lock_path, 0o660)
            except Exception:
                pass
            fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX)
            return lock_fd
        except Exception as e:
            if lock_fd is not None:
                try:
                    lock_fd.close()
                except Exception:
                    pass
            logger.debug("Could not acquire client store lock: %s", e)
            return None

    def _release_lock(self, lock_fd):
        if fcntl is not None and lock_fd is not None:
            try:
                fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)
            except Exception:
                pass
            finally:
                try:
                    lock_fd.close()
                except Exception:
                    pass

    @staticmethod
    def canonicalize_service(service: Optional[str]) -> Optional[str]:
        if not service:
            return None
        s = str(service).strip().lower()
        if s in ("wl", "white_internet"):
            return "white_internet"
        if s in ("vless", "xray_vless"):
            return "vless"
        return s

    def _detect_default_service(self, service: Optional[str] = None) -> str:
        """Detects default service namespace ('white_internet' or 'vless') based on node configuration."""
        if service:
            canon = self.canonicalize_service(service)
            if canon:
                return canon
        raw_env = os.getenv("XRAY_INBOUND_TAGS")
        if raw_env:
            tags = [t.strip().lower() for t in raw_env.split(",") if t.strip()]
            has_wl = any(
                t.startswith("just1k-wl-") or t == "just1k-wl-default"
                for t in tags
            )
            has_vless = any(
                t.startswith("just1k-vless-") or t == "just1k-vless-direct"
                for t in tags
            )
            if has_wl and not has_vless:
                return "white_internet"
            if has_vless and not has_wl:
                return "vless"

        state_candidates = [
            os.getenv("STATE_FILE_PATH"),
            os.getenv("JUST1K_STATE_PATH"),
            "/etc/just1knode/state.json",
        ]
        for sc in state_candidates:
            if not sc:
                continue
            state_path = Path(sc)
            if state_path.exists():
                try:
                    with open(state_path, "r", encoding="utf-8") as f:
                        sdata = json.load(f)
                        if isinstance(sdata, dict):
                            role = sdata.get("role")
                            modules = sdata.get("modules") if isinstance(sdata.get("modules"), dict) else {}
                            has_xhttp_mod = any(
                                isinstance(modules.get(k), dict) and bool(modules[k].get("enabled"))
                                for k in ("vless_xhttp", "cdn_yandex", "cdn_turboflare")
                            )
                            has_tls_mod = (
                                isinstance(modules.get("vless_tls"), dict)
                                and bool(modules["vless_tls"].get("enabled"))
                            )
                            has_vless = has_tls_mod or role == "exit_node"
                            has_wl = role == "eu_hub" or has_xhttp_mod
                            if has_wl and not has_vless:
                                return "white_internet"
                            if has_vless and not has_wl:
                                return "vless"
                    break
                except Exception:
                    pass

        config_candidates = [
            os.getenv("XRAY_CONFIG_PATH"),
            "/usr/local/etc/xray/config.json",
            "/etc/xray/config.json",
        ]
        for cc in config_candidates:
            if not cc:
                continue
            config_path = Path(cc)
            if config_path.exists():
                try:
                    with open(config_path, "r", encoding="utf-8") as f:
                        cdata = json.load(f)
                        inbounds = cdata.get("inbounds", [])
                        tags = [ib.get("tag", "").lower() for ib in inbounds if isinstance(ib, dict)]
                        has_wl = any(
                            t.startswith("just1k-wl-") or t == "just1k-wl-default"
                            for t in tags
                        )
                        has_vless = any(
                            t.startswith("just1k-vless-") or t == "just1k-vless-direct"
                            for t in tags
                        )
                        if has_wl:
                            return "white_internet"
                        if has_vless:
                            return "vless"
                    break
                except Exception:
                    pass

        return "vless"

    def _extract_service_states(self, existing_entry: Dict[str, Any]) -> Dict[str, Any]:
        """Extract service_states dict from v2 client entry."""
        curr = existing_entry.get("service_states")
        return dict(curr) if isinstance(curr, dict) else {}

    def _mutate_entry(
        self,
        entries: Dict[str, Any],
        client_uuid: str,
        *,
        active: bool,
        version: Optional[int] = None,
        email: Optional[str] = None,
        service: Optional[str] = None,
    ) -> None:
        existing_entry = entries.get(client_uuid, {})
        curr_service_states = self._extract_service_states(existing_entry)
        now_ts = time.time()

        if active:
            svc_name = (
                self.canonicalize_service(service)
                or existing_entry.get("service")
                or self._detect_default_service(service)
            )
            svc_curr_ver = curr_service_states.get(svc_name, {}).get("version", 0)
            new_svc_ver = version if version is not None else max(svc_curr_ver + 1, 1)
            curr_service_states[svc_name] = {
                "is_active": True,
                "version": new_svc_ver,
                "tombstone": False,
                "updated_at": now_ts,
            }
            active_services = [
                s for s, st in curr_service_states.items() if st.get("is_active") is True and not st.get("tombstone", False)
            ]
            global_ver = max(
                (st.get("version", 0) for st in curr_service_states.values() if isinstance(st, dict)),
                default=new_svc_ver,
            )
            entry: Dict[str, Any] = {
                "is_active": bool(active_services),
                "version": global_ver,
                "services": active_services,
                "service": svc_name,
                "service_states": curr_service_states,
                "tombstone": False,
                "updated_at": now_ts,
            }
            if email or existing_entry.get("email"):
                entry["email"] = email or existing_entry.get("email")
        else:
            svc_name = self.canonicalize_service(service)
            targets = [svc_name] if svc_name else list(curr_service_states.keys())
            for s in targets:
                svc_curr_ver = curr_service_states.get(s, {}).get("version", 0)
                new_svc_ver = version if version is not None else max(svc_curr_ver + 1, 1)
                curr_service_states[s] = {
                    "is_active": False,
                    "version": new_svc_ver,
                    "tombstone": False,
                    "updated_at": now_ts,
                }
            active_services = [
                s for s, st in curr_service_states.items() if st.get("is_active") is True and not st.get("tombstone", False)
            ]
            global_ver = max(
                (st.get("version", 0) for st in curr_service_states.values() if isinstance(st, dict)),
                default=(version or 1),
            )
            entry = {
                "is_active": bool(active_services),
                "version": global_ver,
                "services": active_services,
                "service_states": curr_service_states,
                "updated_at": now_ts,
            }
            if active_services:
                entry["service"] = active_services[-1]
            elif existing_entry.get("service"):
                entry["service"] = existing_entry["service"]
            if existing_entry.get("email"):
                entry["email"] = existing_entry["email"]

        entries[client_uuid] = entry

    def add_client(
        self,
        client_uuid: str,
        version: Optional[int] = None,
        email: Optional[str] = None,
        service: Optional[str] = None,
    ) -> None:
        self._ensure_dir()
        lock_fd = self._acquire_lock()
        try:
            entries = self.load_client_entries()
            self._mutate_entry(
                entries, client_uuid, active=True, version=version, email=email, service=service
            )
            if not self.save_client_entries(entries):
                raise IOError(f"Failed to persist client addition to disk: {client_uuid}")
        finally:
            self._release_lock(lock_fd)

    def remove_client(
        self, client_uuid: str, version: Optional[int] = None, service: Optional[str] = None
    ) -> None:
        self._ensure_dir()
        lock_fd = self._acquire_lock()
        try:
            entries = self.load_client_entries()
            self._mutate_entry(
                entries, client_uuid, active=False, version=version, service=service
            )
            if not self.save_client_entries(entries):
                raise IOError(f"Failed to persist client deactivation to disk: {client_uuid}")
        finally:
            self._release_lock(lock_fd)

    def delete_client(
        self, client_uuid: str, version: Optional[int] = None, service: Optional[str] = None
    ) -> None:
        self._ensure_dir()
        lock_fd = self._acquire_lock()
        try:
            entries = self.load_client_entries()
            existing_entry = entries.get(client_uuid, {})
            curr_service_states = self._extract_service_states(existing_entry)
            svc_name = self.canonicalize_service(service)
            if svc_name:
                svc_curr_ver = curr_service_states.get(svc_name, {}).get("version", 0)
                new_svc_ver = version if version is not None else max(svc_curr_ver + 1, 1)
                curr_service_states[svc_name] = {
                    "is_active": False,
                    "version": new_svc_ver,
                    "tombstone": True,
                    "updated_at": time.time(),
                }
            else:
                services_to_tombstone = (
                    list(curr_service_states.keys())
                    if curr_service_states
                    else ["vless", "white_internet"]
                )
                for s in services_to_tombstone:
                    svc_curr_ver = curr_service_states.get(s, {}).get("version", 0)
                    new_svc_ver = version if version is not None else max(svc_curr_ver + 1, 1)
                    curr_service_states[s] = {
                        "is_active": False,
                        "version": new_svc_ver,
                        "tombstone": True,
                        "updated_at": time.time(),
                    }

            active_services = [
                s for s, st in curr_service_states.items() if st.get("is_active") is True and not st.get("tombstone", False)
            ]
            global_ver = max(
                (st.get("version", 0) for st in curr_service_states.values() if isinstance(st, dict)),
                default=(version or 1),
            )
            is_global_tombstone = not bool(active_services) and (
                all(st.get("tombstone") for st in curr_service_states.values())
                if curr_service_states
                else True
            )

            entries[client_uuid] = {
                "is_active": bool(active_services),
                "version": global_ver,
                "services": active_services,
                "service_states": curr_service_states,
                "tombstone": is_global_tombstone,
                "updated_at": time.time(),
            }
            if not self.save_client_entries(entries):
                raise IOError(f"Failed to persist client deletion tombstone to disk: {client_uuid}")
        finally:
            self._release_lock(lock_fd)
