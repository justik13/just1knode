import ipaddress
import re
import uuid as uuid_lib
from typing import Any, Dict, List, Literal, Optional

from pydantic import BaseModel, Field, field_validator, model_validator


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


_SAFE_NGINX_PATH_RE = re.compile(r"^/[A-Za-z0-9._/~-]+$")


def _validate_nginx_path_strict(value: Any) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError("Location path must be a non-empty string")
    if len(value) > 256:
        raise ValueError("Location path exceeds maximum length of 256 characters")
    if not value.startswith("/") or ".." in value:
        raise ValueError(f"Invalid location path: {value!r}")
    if not _SAFE_NGINX_PATH_RE.fullmatch(value) or not value.rstrip("/"):
        raise ValueError(f"Location path contains forbidden characters: {value!r}")
    return value


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

    @field_validator("email")
    @classmethod
    def validate_email_safety(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return None
        cleaned = v.strip()
        if not cleaned:
            return None
        if ">>>" in cleaned:
            raise ValueError("Email must not contain '>>>' delimiter sequence")
        if any(c.isspace() or ord(c) < 32 or ord(c) > 126 for c in cleaned):
            raise ValueError("Email contains invalid whitespace or non-printable ASCII characters")
        if len(cleaned) > 254:
            raise ValueError("Email exceeds maximum allowed length of 254 characters")
        return cleaned

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


class InventoryRequest(BaseModel):
    client_ids: Optional[List[str]] = Field(
        None, description="Optional list of client UUIDs to probe"
    )
    service: Optional[Literal["vless", "white_internet", "wl"]] = Field(
        None, description="Optional service filter: 'vless' or 'white_internet'"
    )


class BridgeSpec(BaseModel):
    id: Optional[str] = Field(default=None, max_length=64)
    tag: Optional[str] = Field(default=None, max_length=64)
    code: str = Field(..., min_length=1, max_length=48, pattern=r"^[a-zA-Z0-9_-]+$")
    location_code: Optional[str] = None
    name: Optional[str] = None
    ip: str
    port: int = Field(default=443, ge=1, le=65535)
    sni: str
    uuid: str
    is_default: bool = False
    route_user: Optional[str] = None

    @model_validator(mode="after")
    def validate_bridge(self) -> "BridgeSpec":
        self.ip = _validate_ipv4_strict(self.ip)
        self.sni = _validate_fqdn_strict(self.sni)
        self.uuid = _validate_uuid_strict(self.uuid)
        self.code = self.code.strip().lower()
        if self.location_code is not None:
            self.location_code = self.location_code.strip().lower() or None
        return self


class SniRouteSpec(BaseModel):
    sni: str
    bridge_code: str = Field(..., min_length=1, max_length=48, pattern=r"^[a-zA-Z0-9_-]+$")

    @model_validator(mode="after")
    def validate_route(self) -> "SniRouteSpec":
        self.sni = _validate_fqdn_strict(self.sni)
        self.bridge_code = self.bridge_code.strip().lower()
        return self


class IncomingHubSpec(BaseModel):
    code: Optional[str] = Field(default=None, max_length=48)
    ip: Optional[str] = None
    uuid: Optional[str] = None
    route_user: Optional[str] = None

    @model_validator(mode="after")
    def validate_incoming(self) -> "IncomingHubSpec":
        if self.ip is not None and self.ip.strip():
            self.ip = _validate_ipv4_strict(self.ip)
        if self.uuid is not None and self.uuid.strip():
            self.uuid = _validate_uuid_strict(self.uuid)
        return self


class HubRouteSpec(BaseModel):
    code: Optional[str] = Field(default=None, max_length=48)
    ingress_uuid: Optional[str] = None
    route_user: str = Field(..., min_length=1, max_length=128)
    exit_id: Optional[str] = Field(default=None, max_length=64)
    exit_code: str = Field(..., min_length=1, max_length=48, pattern=r"^[a-zA-Z0-9_-]+$")

    @model_validator(mode="after")
    def validate_hub_route(self) -> "HubRouteSpec":
        if self.ingress_uuid is not None and self.ingress_uuid.strip():
            self.ingress_uuid = _validate_uuid_strict(self.ingress_uuid)
        self.exit_code = self.exit_code.strip().lower()
        return self


class NodeLinksSectionSpec(BaseModel):
    bridges: List[BridgeSpec] = Field(default_factory=list)
    sni_routes: List[SniRouteSpec] = Field(default_factory=list)
    locations: List[Dict[str, Any]] = Field(default_factory=list)
    secret_base_path: Optional[str] = Field(default=None, max_length=128)

    @field_validator("secret_base_path")
    @classmethod
    def validate_secret_base_path(cls, value: Optional[str]) -> Optional[str]:
        if value is None:
            return None
        cleaned = value.strip().rstrip("/")
        if not cleaned:
            return None
        validated = _validate_nginx_path_strict(cleaned)
        if (
            len(validated) < 3
            or "//" in validated
            or validated in ("/.", "/sub", "/std", "/none")
            or "/./" in validated
            or validated.endswith("/.")
            or validated.startswith(("/sub/", "/std/"))
        ):
            raise ValueError(f"Invalid secret_base_path: {value!r}")
        return validated

    @field_validator("locations")
    @classmethod
    def validate_locations_paths(cls, locations: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        for loc in locations:
            if not isinstance(loc, dict):
                raise ValueError("Each location entry must be an object")
            if "path" in loc and loc["path"] is not None:
                loc["path"] = _validate_nginx_path_strict(loc["path"])
            if "paths" in loc and loc["paths"] is not None:
                if not isinstance(loc["paths"], dict):
                    raise ValueError("location.paths must be a mapping of CDN key to path")
                validated_paths: Dict[str, str] = {}
                for k, v in loc["paths"].items():
                    validated_paths[str(k)] = _validate_nginx_path_strict(v)
                loc["paths"] = validated_paths
        return locations


class NodeLinksUpdateRequest(BaseModel):
    standard: Optional[NodeLinksSectionSpec] = None
    bi: Optional[NodeLinksSectionSpec] = None
    probe_bridges: Optional[List[BridgeSpec]] = None
    exit_nodes: Optional[List[BridgeSpec]] = None
    allowed_ru_ips: Optional[List[str]] = None
    allowed_hub_ips: Optional[List[str]] = None
    incoming_ru_hubs: Optional[List[IncomingHubSpec]] = None
    incoming_hubs: Optional[List[IncomingHubSpec]] = None
    routes: Optional[List[HubRouteSpec]] = None

    @model_validator(mode="after")
    def validate_ip_lists(self) -> "NodeLinksUpdateRequest":
        if self.allowed_ru_ips is not None:
            self.allowed_ru_ips = [_validate_ipv4_strict(x) for x in self.allowed_ru_ips]
        if self.allowed_hub_ips is not None:
            self.allowed_hub_ips = [_validate_ipv4_strict(x) for x in self.allowed_hub_ips]
        return self


class ClientBatchSyncItem(ClientSyncRequest):
    uuid: str


class ClientBatchSyncRequest(BaseModel):
    clients: List[ClientBatchSyncItem] = Field(default_factory=list, max_length=2000)
