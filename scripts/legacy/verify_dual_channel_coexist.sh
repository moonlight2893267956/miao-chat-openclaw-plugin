#!/usr/bin/env bash
set -euo pipefail

BACKEND_BASE="${BACKEND_BASE:-http://81.70.216.46:8081}"
STATUS_URL="${BACKEND_BASE%/}/api/v1/channel-gateway/status"
LOCAL_CHANNEL_ID="${LOCAL_CHANNEL_ID:-ch_local_dev}"
SERVER_CHANNEL_ID="${SERVER_CHANNEL_ID:-ch_server_primary}"
DURATION_SEC="${DURATION_SEC:-120}"
CHECK_INTERVAL_SEC="${CHECK_INTERVAL_SEC:-10}"
REQUIRE_LOCAL_OFFLINE_ONCE="${REQUIRE_LOCAL_OFFLINE_ONCE:-0}"

echo "[INFO] verify dual-channel coexist/isolation"
echo "  STATUS_URL=${STATUS_URL}"
echo "  LOCAL_CHANNEL_ID=${LOCAL_CHANNEL_ID}"
echo "  SERVER_CHANNEL_ID=${SERVER_CHANNEL_ID}"
echo "  DURATION_SEC=${DURATION_SEC}"
echo "  CHECK_INTERVAL_SEC=${CHECK_INTERVAL_SEC}"
echo "  REQUIRE_LOCAL_OFFLINE_ONCE=${REQUIRE_LOCAL_OFFLINE_ONCE}"

start_ts="$(date +%s)"
end_ts=$((start_ts + DURATION_SEC))
round=0
both_online_seen=0
local_offline_seen=0

while [[ "$(date +%s)" -lt "${end_ts}" ]]; do
  round=$((round + 1))
  resp="$(curl -sS "${STATUS_URL}")"

  result="$(
    RESPONSE_JSON="${resp}" python3 - "${LOCAL_CHANNEL_ID}" "${SERVER_CHANNEL_ID}" "${round}" <<'PY'
import json
import os
import sys

local_channel_id = sys.argv[1]
server_channel_id = sys.argv[2]
round_id = int(sys.argv[3])

payload = json.loads(os.environ.get("RESPONSE_JSON", "")).get("data") or {}
items = payload.get("list") or []
by_id = {str(x.get("channelId")): x for x in items}

local = by_id.get(local_channel_id)
server = by_id.get(server_channel_id)

server_status = str((server or {}).get("status") or "missing").lower()
local_status = str((local or {}).get("status") or "missing").lower()

if server_status != "online":
    print(f"[FAIL][round={round_id}] server channel not online: {server_channel_id} status={server_status!r}")
    sys.exit(2)

both_online = 1 if local_status == "online" and server_status == "online" else 0
local_offline = 1 if local_status in {"offline", "missing"} else 0
print(f"[OK][round={round_id}] local={local_status} server={server_status} both_online={both_online}")
print(f"{both_online},{local_offline}")
PY
  )"

  echo "${result}" | sed '$d'
  flags="$(echo "${result}" | tail -n 1)"
  both_online_seen_round="${flags%%,*}"
  local_offline_seen_round="${flags##*,}"

  if [[ "${both_online_seen_round}" == "1" ]]; then
    both_online_seen=1
  fi
  if [[ "${local_offline_seen_round}" == "1" ]]; then
    local_offline_seen=1
  fi

  sleep "${CHECK_INTERVAL_SEC}"
done

if [[ "${both_online_seen}" != "1" ]]; then
  echo "[FAIL] never observed both channels online at the same time"
  exit 3
fi

if [[ "${REQUIRE_LOCAL_OFFLINE_ONCE}" == "1" && "${local_offline_seen}" != "1" ]]; then
  echo "[FAIL] REQUIRE_LOCAL_OFFLINE_ONCE=1, but local channel never became offline/missing"
  exit 4
fi

if [[ "${REQUIRE_LOCAL_OFFLINE_ONCE}" == "1" ]]; then
  echo "[PASS] coexist + isolation verified (server remained online while local had offline window)"
else
  echo "[PASS] coexist verified (both channels observed online)"
fi
