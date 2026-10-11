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
        self.lock_path = self.file_path.with_suffix(".lock")

    def _ensure_dir(self) -> None:
        try:
            self.file_path.parent.mkdir(parents=True, exist_ok=True)
            self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        except Exception as e:
            logger.warning("Could not create directory %s: %s", self.file_path.parent, e)

    def load_client_entries(self) -> Dict[str, Dict[str, Any]]:
        """Loads all client metadata entries {uuid: {is_active: bool, version: int, updated_at: float}}."""
        if not self.file_path.exists() or self.file_path.stat().st_size == 0:
            return {}
        try:
            with open(self.file_path, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    if len(data) == 0:
                        return {}
                    if "clients" in data:
                        clients_val = data["clients"]
                        if isinstance(clients_val, dict):
                            return clients_val
                        if isinstance(clients_val, list):
                            return {
                                u: {"is_active": True, "version": 1, "updated_at": time.time()}
                                for u in clients_val
                            }
                        raise ClientStoreCorruptedError(
                            f"Unexpected clients field in {self.file_path}: {type(clients_val)}"
                        )
                    if all(isinstance(v, dict) for v in data.values()):
                        return data
                elif isinstance(data, list):
                    return {
                        u: {"is_active": True, "version": 1, "updated_at": time.time()}
                        for u in data
                    }
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
        data = {
            "clients": entries,
            "updated_at": time.time(),
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

    def save_clients(self, clients: Set[str]) -> bool:
        """Backward-compatible save using set of active UUIDs."""
        entries = {u: {"is_active": True, "version": 1, "updated_at": time.time()} for u in clients}
        return self.save_client_entries(entries)

    def _acquire_lock(self):
        if fcntl is None:
            return None
        try:
            lock_fd = open(self.lock_path, "a")
            try:
                os.chmod(self.lock_path, 0o660)
            except Exception:
                pass
            fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX)
            return lock_fd
        except Exception as e:
            logger.debug("Could not acquire client store lock: %s", e)
            return None

    def _release_lock(self, lock_fd):
        if fcntl is not None and lock_fd is not None:
            try:
                fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)
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
            existing_entry = entries.get(client_uuid, {})
            curr_service_states = existing_entry.get("service_states")
            if not isinstance(curr_service_states, dict):
                curr_service_states = {}
                # Migrate legacy entry
                legacy_services = existing_entry.get("services") or []
                if not isinstance(legacy_services, list):
                    legacy_services = [legacy_services] if legacy_services else []
                if "service" in existing_entry and existing_entry["service"] not in legacy_services:
                    legacy_services.append(existing_entry["service"])
                legacy_act = bool(existing_entry.get("is_active", True)) and not bool(existing_entry.get("tombstone", False))
                legacy_ver = existing_entry.get("version", 0)
                legacy_tomb = bool(existing_entry.get("tombstone", False))
                for s in legacy_services:
                    canon_s = self.canonicalize_service(s) or s
                    curr_service_states[canon_s] = {
                        "is_active": legacy_act,
                        "version": legacy_ver,
                        "tombstone": legacy_tomb,
                    }

            svc_name = self.canonicalize_service(service) or "vless"
            svc_curr_ver = curr_service_states.get(svc_name, {}).get("version", 0)
            new_svc_ver = version if version is not None else max(svc_curr_ver + 1, 1)

            curr_service_states[svc_name] = {
                "is_active": True,
                "version": new_svc_ver,
                "tombstone": False,
                "updated_at": time.time(),
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
                "updated_at": time.time(),
            }
            if email or existing_entry.get("email"):
                entry["email"] = email or existing_entry.get("email")
            entries[client_uuid] = entry
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
            existing_entry = entries.get(client_uuid, {})
            curr_service_states = existing_entry.get("service_states")
            if not isinstance(curr_service_states, dict):
                curr_service_states = {}
                legacy_services = existing_entry.get("services") or []
                if not isinstance(legacy_services, list):
                    legacy_services = [legacy_services] if legacy_services else []
                if "service" in existing_entry and existing_entry["service"] not in legacy_services:
                    legacy_services.append(existing_entry["service"])
                legacy_act = bool(existing_entry.get("is_active", True)) and not bool(existing_entry.get("tombstone", False))
                legacy_ver = existing_entry.get("version", 0)
                legacy_tomb = bool(existing_entry.get("tombstone", False))
                for s in legacy_services:
                    canon_s = self.canonicalize_service(s) or s
                    curr_service_states[canon_s] = {
                        "is_active": legacy_act,
                        "version": legacy_ver,
                        "tombstone": legacy_tomb,
                    }

            svc_name = self.canonicalize_service(service)
            if svc_name:
                svc_curr_ver = curr_service_states.get(svc_name, {}).get("version", 0)
                new_svc_ver = version if version is not None else max(svc_curr_ver + 1, 1)
                curr_service_states[svc_name] = {
                    "is_active": False,
                    "version": new_svc_ver,
                    "tombstone": False,
                    "updated_at": time.time(),
                }
            else:
                # Deactivate all known services on unspecified service removal
                for s in list(curr_service_states.keys()):
                    svc_curr_ver = curr_service_states[s].get("version", 0)
                    new_svc_ver = version if version is not None else max(svc_curr_ver + 1, 1)
                    curr_service_states[s] = {
                        "is_active": False,
                        "version": new_svc_ver,
                        "tombstone": False,
                        "updated_at": time.time(),
                    }

            active_services = [
                s for s, st in curr_service_states.items() if st.get("is_active") is True and not st.get("tombstone", False)
            ]
            global_ver = max(
                (st.get("version", 0) for st in curr_service_states.values() if isinstance(st, dict)),
                default=(version or 1),
            )

            entry: Dict[str, Any] = {
                "is_active": bool(active_services),
                "version": global_ver,
                "services": active_services,
                "service_states": curr_service_states,
                "updated_at": time.time(),
            }
            if active_services:
                entry["service"] = active_services[-1]
            elif existing_entry.get("service"):
                entry["service"] = existing_entry["service"]
            if existing_entry.get("email"):
                entry["email"] = existing_entry["email"]
            entries[client_uuid] = entry
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
            curr_service_states = existing_entry.get("service_states")
            if not isinstance(curr_service_states, dict):
                curr_service_states = {}
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
                for s in list(curr_service_states.keys()):
                    svc_curr_ver = curr_service_states[s].get("version", 0)
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
