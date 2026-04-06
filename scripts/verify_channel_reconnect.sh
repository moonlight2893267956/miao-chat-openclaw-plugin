#!/usr/bin/env bash
set -euo pipefail

# 动态渠道重连验证。
# 用法：
#   bash scripts/verify_channel_reconnect.sh [backend_base] [channel_id] [max_recover_sec]

BACKEND_BASE="${1:-http://81.70.216.46:8081}"
CHANNEL_ID="${2:-miao-node-local}"
MAX_RECOVER_SEC="${3:-10}"
STATUS_URL="${BACKEND_BASE%/}/api/v1/channel-gateway/status"

extract_field() {
  local json="$1"
  local field="$2"
  python - "$CHANNEL_ID" "$field" "$json" <<'PY'
import json
import sys
channel_id = sys.argv[1]
field = sys.argv[2]
raw = sys.argv[3]
try:
    data = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)
items = ((data.get("data") or {}).get("list") or [])
for item in items:
    if item.get("channelId") == channel_id:
        val = item.get(field, "")
        print("" if val is None else val)
        break
else:
    print("")
PY
}

now_ts() {
  python - <<'PY'
import time
print(time.time())
PY
}

echo "[M3] checking current online status channel=${CHANNEL_ID}"
start_wait="$(now_ts)"
while true; do
  status_json="$(curl -sS --max-time 5 "$STATUS_URL" || true)"
  cur_status="$(extract_field "$status_json" "status")"
  cur_connected_at="$(extract_field "$status_json" "connectedAt")"
  if [[ "$cur_status" == "online" ]]; then
    break
  fi
  elapsed="$(python - <<PY
import time
print(round(time.time() - float('$start_wait'),2))
PY
)"
  if python - <<PY
import sys
sys.exit(0 if float('$elapsed') <= 20 else 1)
PY
  then
    sleep 0.5
  else
    echo "[M3] FAIL channel not online before test (waited ${elapsed}s)"
    exit 2
  fi
done

echo "[M3] baseline connectedAt=${cur_connected_at}"

t0="$(now_ts)"
echo "[M3] restarting openclaw gateway to simulate disconnect..."
openclaw gateway restart >/tmp/m3_gateway_restart.log 2>&1

while true; do
  status_json="$(curl -sS --max-time 5 "$STATUS_URL" || true)"
  cur_status="$(extract_field "$status_json" "status")"
  new_connected_at="$(extract_field "$status_json" "connectedAt")"

  if [[ "$cur_status" == "online" && -n "$new_connected_at" && "$new_connected_at" != "$cur_connected_at" ]]; then
    break
  fi
  sleep 0.3

done

t1="$(now_ts)"
recover_sec="$(python - <<PY
print(round(float('$t1') - float('$t0'), 3))
PY
)"

echo "[M3] reconnect observed connectedAt=${new_connected_at}"
echo "[M3] recover_sec=${recover_sec}, threshold=${MAX_RECOVER_SEC}"

if python - <<PY
import sys
sys.exit(0 if float('$recover_sec') <= float('$MAX_RECOVER_SEC') else 1)
PY
then
  echo "[M3] PASS reconnect within ${MAX_RECOVER_SEC}s"
  exit 0
else
  echo "[M3] FAIL reconnect exceeded ${MAX_RECOVER_SEC}s"
  exit 3
fi
