#!/usr/bin/env bash
set -euo pipefail

BACKEND_BASE="${BACKEND_BASE:-http://81.70.216.46:8081}"
CHANNEL_ID="${CHANNEL_ID:-ch_server_primary}"
STATUS_URL="${BACKEND_BASE%/}/api/v1/channel-gateway/status"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-12}"
SLEEP_SEC="${SLEEP_SEC:-5}"

echo "[INFO] check channel online + last_seen"
echo "  STATUS_URL=${STATUS_URL}"
echo "  CHANNEL_ID=${CHANNEL_ID}"
echo "  MAX_ATTEMPTS=${MAX_ATTEMPTS}"
echo "  SLEEP_SEC=${SLEEP_SEC}"

attempt=0
while [[ "${attempt}" -lt "${MAX_ATTEMPTS}" ]]; do
  attempt=$((attempt + 1))
  resp="$(curl -sS "${STATUS_URL}")"
  if RESPONSE_JSON="${resp}" python3 - "${CHANNEL_ID}" "${attempt}" <<'PY'
import json
import os
import sys

channel_id = sys.argv[1]
attempt = int(sys.argv[2])
data = json.loads(os.environ.get("RESPONSE_JSON", ""))
payload = data.get("data") or {}
items = payload.get("list") or []
target = None
for item in items:
    if item.get("channelId") == channel_id:
        target = item
        break

if not target:
    print(f"[WARN][attempt={attempt}] channel not found: {channel_id}")
    sys.exit(10)

status = str(target.get("status") or "").lower()
last_seen = target.get("lastSeenAt") or target.get("last_seen")
if status != "online":
    print(f"[WARN][attempt={attempt}] channel status={status!r}, expected 'online'")
    sys.exit(11)
if not last_seen:
    print(f"[WARN][attempt={attempt}] last_seen/lastSeenAt missing")
    sys.exit(12)

print(f"[PASS] channel online: {channel_id}")
print(f"[PASS] last_seen={last_seen}")
PY
  then
    exit 0
  fi
  if [[ "${attempt}" -lt "${MAX_ATTEMPTS}" ]]; then
    sleep "${SLEEP_SEC}"
  fi
done

echo "[FAIL] channel not online after retries: ${CHANNEL_ID}"
exit 3
