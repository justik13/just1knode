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

    @staticmethod
    def _is_valid_email_for_service(email_val: Optional[str], svc_name: Optional[str]) -> bool:
        if not email_val or not isinstance(email_val, str):
            return False
        cleaned = email_val.strip()
        if not cleaned or (":" not in cleaned and "@" not in cleaned):
            return False
        if svc_name == "white_internet" and cleaned.endswith(":std"):
            return False
        if svc_name == "vless" and cleaned.endswith(":wi"):
            return False
        return True

    @classmethod
    def resolve_service_email(
        cls,
        client_uuid: str,
        service: Optional[str],
        explicit_email: Optional[str] = None,
        existing_entry: Optional[Dict[str, Any]] = None,
    ) -> str:
        """Resolves service-specific Xray email, preventing cross-service (:std vs :wi) pollution."""
        svc_name = cls.canonicalize_service(service)
        if cls._is_valid_email_for_service(explicit_email, svc_name):
            return str(explicit_email).strip()

        if isinstance(existing_entry, dict):
            if svc_name:
                ss = existing_entry.get("service_states")
                if isinstance(ss, dict) and isinstance(ss.get(svc_name), dict):
                    st_email = ss[svc_name].get("email")
                    if cls._is_valid_email_for_service(st_email, svc_name):
                        return str(st_email).strip()
                se = existing_entry.get("service_emails")
                if isinstance(se, dict):
                    se_email = se.get(svc_name)
                    if cls._is_valid_email_for_service(se_email, svc_name):
                        return str(se_email).strip()
            top_email = existing_entry.get("email")
            if cls._is_valid_email_for_service(top_email, svc_name):
                return str(top_email).strip()

        if svc_name == "white_internet":
            return f"{client_uuid}:wi"
        if svc_name == "vless":
            return f"{client_uuid}:std"
        if explicit_email and str(explicit_email).strip():
            return str(explicit_email).strip()
        return client_uuid

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

    def _extract_service_emails(
        self, existing_entry: Dict[str, Any], curr_service_states: Dict[str, Any]
    ) -> Dict[str, str]:
        """Extract and sanitize per-service email mapping from existing client entry."""
        service_emails: Dict[str, str] = {}
        raw_se = existing_entry.get("service_emails")
        if isinstance(raw_se, dict):
            for k, v in raw_se.items():
                ck = self.canonicalize_service(k)
                if ck and self._is_valid_email_for_service(v, ck):
                    service_emails[ck] = str(v).strip()
        for s_key, st_val in curr_service_states.items():
            ck = self.canonicalize_service(s_key) or s_key
            if isinstance(st_val, dict) and self._is_valid_email_for_service(st_val.get("email"), ck):
                service_emails[ck] = str(st_val["email"]).strip()
        top_email = existing_entry.get("email")
        if isinstance(top_email, str) and top_email.strip():
            for ck in ("vless", "white_internet"):
                if ck not in service_emails and self._is_valid_email_for_service(top_email, ck):
                    service_emails[ck] = top_email.strip()
        return service_emails

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
        curr_service_emails = self._extract_service_emails(existing_entry, curr_service_states)
        now_ts = time.time()

        if active:
            svc_name = (
                self.canonicalize_service(service)
                or existing_entry.get("service")
                or self._detect_default_service(service)
            )
            svc_email = self.resolve_service_email(
                client_uuid, svc_name, explicit_email=email, existing_entry=existing_entry
            )
            curr_service_emails[svc_name] = svc_email
            svc_curr_ver = curr_service_states.get(svc_name, {}).get("version", 0)
            new_svc_ver = version if version is not None else max(svc_curr_ver + 1, 1)
            curr_service_states[svc_name] = {
                "is_active": True,
                "version": new_svc_ver,
                "tombstone": False,
                "updated_at": now_ts,
                "email": svc_email,
            }
            for other_s, other_st in curr_service_states.items():
                if other_s != svc_name and isinstance(other_st, dict):
                    other_em = self.resolve_service_email(
                        client_uuid, other_s, existing_entry=existing_entry
                    )
                    other_st["email"] = other_em
                    curr_service_emails[other_s] = other_em
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
                "service_emails": curr_service_emails,
                "tombstone": False,
                "updated_at": now_ts,
                "email": svc_email,
            }
        else:
            svc_name = self.canonicalize_service(service)
            targets = (
                [svc_name]
                if svc_name
                else (list(curr_service_states.keys()) or ["vless", "white_internet"])
            )
            for s in targets:
                s_email = self.resolve_service_email(
                    client_uuid,
                    s,
                    explicit_email=email if s == svc_name else None,
                    existing_entry=existing_entry,
                )
                curr_service_emails[s] = s_email
                svc_curr_ver = curr_service_states.get(s, {}).get("version", 0)
                new_svc_ver = version if version is not None else max(svc_curr_ver + 1, 1)
                curr_service_states[s] = {
                    "is_active": False,
                    "version": new_svc_ver,
                    "tombstone": False,
                    "updated_at": now_ts,
                    "email": s_email,
                }
            for other_s, other_st in curr_service_states.items():
                if other_s not in targets and isinstance(other_st, dict):
                    other_em = self.resolve_service_email(
                        client_uuid, other_s, existing_entry=existing_entry
                    )
                    other_st["email"] = other_em
                    curr_service_emails[other_s] = other_em
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
                "service_emails": curr_service_emails,
                "updated_at": now_ts,
            }
            if active_services:
                active_svc = active_services[-1]
                entry["service"] = active_svc
                entry["email"] = curr_service_emails.get(active_svc) or self.resolve_service_email(
                    client_uuid, active_svc, existing_entry=existing_entry
                )
            else:
                if existing_entry.get("service"):
                    entry["service"] = existing_entry["service"]
                if existing_entry.get("email"):
                    entry["email"] = existing_entry["email"]
                elif svc_name and curr_service_emails.get(svc_name):
                    entry["email"] = curr_service_emails[svc_name]

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
            curr_service_emails = self._extract_service_emails(existing_entry, curr_service_states)
            svc_name = self.canonicalize_service(service)
            if svc_name:
                s_email = self.resolve_service_email(
                    client_uuid, svc_name, existing_entry=existing_entry
                )
                curr_service_emails[svc_name] = s_email
                svc_curr_ver = curr_service_states.get(svc_name, {}).get("version", 0)
                new_svc_ver = version if version is not None else max(svc_curr_ver + 1, 1)
                curr_service_states[svc_name] = {
                    "is_active": False,
                    "version": new_svc_ver,
                    "tombstone": True,
                    "updated_at": time.time(),
                    "email": s_email,
                }
            else:
                services_to_tombstone = (
                    list(curr_service_states.keys())
                    if curr_service_states
                    else ["vless", "white_internet"]
                )
                for s in services_to_tombstone:
                    s_email = self.resolve_service_email(
                        client_uuid, s, existing_entry=existing_entry
                    )
                    curr_service_emails[s] = s_email
                    svc_curr_ver = curr_service_states.get(s, {}).get("version", 0)
                    new_svc_ver = version if version is not None else max(svc_curr_ver + 1, 1)
                    curr_service_states[s] = {
                        "is_active": False,
                        "version": new_svc_ver,
                        "tombstone": True,
                        "updated_at": time.time(),
                        "email": s_email,
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

            entry_del: Dict[str, Any] = {
                "is_active": bool(active_services),
                "version": global_ver,
                "services": active_services,
                "service_states": curr_service_states,
                "service_emails": curr_service_emails,
                "tombstone": is_global_tombstone,
                "updated_at": time.time(),
            }
            if active_services:
                active_svc = active_services[-1]
                entry_del["service"] = active_svc
                entry_del["email"] = curr_service_emails.get(active_svc) or self.resolve_service_email(
                    client_uuid, active_svc, existing_entry=existing_entry
                )
            elif existing_entry.get("email"):
                entry_del["email"] = existing_entry["email"]
            entries[client_uuid] = entry_del
            if not self.save_client_entries(entries):
                raise IOError(f"Failed to persist client deletion tombstone to disk: {client_uuid}")
        finally:
            self._release_lock(lock_fd)
