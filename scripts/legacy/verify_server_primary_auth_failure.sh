#!/usr/bin/env bash
set -euo pipefail

WS_URL="${WS_URL:-ws://81.70.216.46:8081/ws/channel-gateway}"
CHANNEL_ID="${CHANNEL_ID:-ch_server_primary_auth_fail_probe}"
WRONG_TOKEN="${WRONG_TOKEN:-__invalid_register_token__}"

echo "[INFO] verify auth failure code"
echo "  WS_URL=${WS_URL}"
echo "  CHANNEL_ID=${CHANNEL_ID}"

python3 - "${WS_URL}" "${CHANNEL_ID}" "${WRONG_TOKEN}" <<'PY'
import importlib.util
import json
import subprocess
import sys
import time

ws_url = sys.argv[1]
channel_id = sys.argv[2]
wrong_token = sys.argv[3]

if importlib.util.find_spec("websocket") is None:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--user", "websocket-client"])

import websocket  # type: ignore

msg = {
    "protocol_version": "channel.v0",
    "event": "register",
    "msg_id": f"msg_{int(time.time() * 1000)}",
    "trace_id": "tr_auth_fail_probe",
    "payload": {
        "channel_id": channel_id,
        "auth": {"token": wrong_token},
    },
}

ws = websocket.create_connection(ws_url, timeout=8)
try:
    ws.settimeout(8)
    ws.send(json.dumps(msg, ensure_ascii=False))
    raw = ws.recv()
    data = json.loads(raw)
    event = data.get("event")
    payload = data.get("payload") or {}
    code = payload.get("code")

    if event != "register.error":
        print(f"[FAIL] expected register.error, got event={event!r} payload={payload}")
        print("[HINT] backend may not enable channel-gateway.register-token; configure it first for AC4.")
        sys.exit(2)
    if code != "CHANNEL_AUTH_FAILED":
        print(f"[FAIL] expected CHANNEL_AUTH_FAILED, got code={code!r} payload={payload}")
        sys.exit(3)
    print("[PASS] register.error code=CHANNEL_AUTH_FAILED")
finally:
    try:
        ws.close()
    except Exception:
        pass
PY
