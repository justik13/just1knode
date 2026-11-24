#!/usr/bin/env bash
set -euo pipefail

NODE_ROLE="${NODE_ROLE:-ru_hub}"
PORT="${PORT:-8444}"
GRPC_PORT="${GRPC_PORT:-10085}"
: "${XRAY_API_KEY:?XRAY_API_KEY must be set}"
LOCATION_CODE="${LOCATION_CODE:-de}"
DOMAIN="${DOMAIN:-dash.just1k.pro}"

echo "=========================================================="
echo " Starting Real Just1kNode Container"
echo " Role: ${NODE_ROLE}"
echo " Port: ${PORT}"
echo " Grpc Port: ${GRPC_PORT}"
echo " Xray Version: $(xray version | head -n 1)"
echo "=========================================================="

mkdir -p /etc/just1knode /usr/local/etc/xray /var/lib/xray-api /var/log/xray /run

# Generate state.json for the API agent
cat <<EOF > /etc/just1knode/state.json
{
  "role": "${NODE_ROLE}",
  "domain": "${DOMAIN}",
  "api_key": "${XRAY_API_KEY}",
  "tunnel_uuid": "11111111-1111-4111-8111-111111111111",
  "secret_base_path": "/assets_test",
  "country_code": "${LOCATION_CODE}",
  "modules": {
    "vless_tls": {"enabled": true},
    "cdn_yandex": {"enabled": true}
  }
}
EOF

# Initialize empty clients and links if missing
[[ -f /etc/just1knode/clients.json ]] || echo "{}" > /etc/just1knode/clients.json
[[ -f /etc/just1knode/links.json ]] || echo "{}" > /etc/just1knode/links.json

# Build the exact full Xray configuration
python3 - <<'PYEOF'
import json, os

role = os.getenv("NODE_ROLE", "ru_hub")
grpc_port = int(os.getenv("GRPC_PORT", "10085"))
loc_code = os.getenv("LOCATION_CODE", "de")

cfg = {
    "log": {"loglevel": "warning"},
    "api": {
        "tag": "just1k-wl-api",
        "services": ["HandlerService", "StatsService", "LoggerService"]
    },
    "stats": {},
    "policy": {
        "levels": {
            "0": {
                "handshake": 4,
                "connIdle": 300,
                "statsUserUplink": True,
                "statsUserDownlink": True
            }
        },
        "system": {
            "statsInboundUplink": True,
            "statsInboundDownlink": True
        }
    },
    "inbounds": [
        {
            "tag": "just1k-wl-api-grpc",
            "listen": "127.0.0.1",
            "port": grpc_port,
            "protocol": "dokodemo-door",
            "settings": {"address": "127.0.0.1"}
        }
    ],
    "outbounds": [
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "just1k-wl-api", "protocol": "blackhole", "settings": {}}
    ],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            {
                "type": "field",
                "inboundTag": ["just1k-wl-api-grpc"],
                "outboundTag": "just1k-wl-api"
            }
        ]
    }
}

if role == "ru_hub":
    cfg["inbounds"].extend([
        {
            "tag": "just1k-vless-direct",
            "listen": "0.0.0.0",
            "port": 443,
            "protocol": "vless",
            "settings": {"clients": [], "decryption": "none"},
            "streamSettings": {"network": "tcp", "security": "none"}
        },
        {
            "tag": "just1k-vless-wi",
            "listen": "0.0.0.0",
            "port": 8081,
            "protocol": "vless",
            "settings": {"clients": [], "decryption": "none"},
            "streamSettings": {"network": "tcp", "security": "none"}
        },
        {
            "tag": "just1k-wl-default",
            "listen": "0.0.0.0",
            "port": 8082,
            "protocol": "vless",
            "settings": {"clients": [], "decryption": "none"},
            "streamSettings": {"network": "xhttp", "security": "none", "xhttpSettings": {"path": "/wi-test-xhttp"}}
        },
        {
            "tag": f"just1k-wl-inbound-{loc_code}",
            "listen": "0.0.0.0",
            "port": 8083,
            "protocol": "vless",
            "settings": {"clients": [], "decryption": "none"},
            "streamSettings": {"network": "xhttp", "security": "none", "xhttpSettings": {"path": f"/wi-test-xhttp-{loc_code}"}}
        }
    ])
else:
    cfg["inbounds"].append({
        "tag": "just1k-vless-direct",
        "listen": "0.0.0.0",
        "port": 443,
        "protocol": "vless",
        "settings": {"clients": [], "decryption": "none"},
        "streamSettings": {"network": "tcp", "security": "none"}
    })

with open("/usr/local/etc/xray/config.json", "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF

echo "==> Running real Xray configuration syntax test..."
xray run -test -format json -config /usr/local/etc/xray/config.json
echo "==> ✔ Real Xray syntax check PASSED!"

echo "==> Starting Xray Core daemon in background..."
xray run -config /usr/local/etc/xray/config.json &
XRAY_PID=$!
echo "$XRAY_PID" > /run/xray.pid
echo "==> Xray Core started with PID ${XRAY_PID}"

# Wait a moment for Xray gRPC to be ready
sleep 1

export XRAY_API_KEY
export XRAY_GRPC_HOST="127.0.0.1"
export XRAY_GRPC_PORT="${GRPC_PORT}"
export XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
export CLIENTS_FILE_PATH="/etc/just1knode/clients.json"
export STATE_FILE_PATH="/etc/just1knode/state.json"
export LINKS_FILE_PATH="/etc/just1knode/links.json"
export PYTHONPATH="/opt/just1knode/scripts/xray_api"

echo "==> Starting Just1kNode FastAPI agent on port ${PORT}..."
cd /opt/just1knode/scripts/xray_api
exec uvicorn app:app --host 0.0.0.0 --port "${PORT}" --log-level info
