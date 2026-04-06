#!/usr/bin/env bash
set -euo pipefail

BACKEND_BASE="${BACKEND_BASE:-http://81.70.216.46:8081}"
CHANNEL_ID="${CHANNEL_ID:-ch_server_primary}"
STATUS_URL="${BACKEND_BASE%/}/api/v1/channel-gateway/status"
DURATION_SEC="${DURATION_SEC:-1800}"         # 30 min
CHECK_INTERVAL_SEC="${CHECK_INTERVAL_SEC:-15}"
MAX_LAST_SEEN_AGE_SEC="${MAX_LAST_SEEN_AGE_SEC:-90}"

echo "[INFO] verify 30m channel stability"
echo "  STATUS_URL=${STATUS_URL}"
echo "  CHANNEL_ID=${CHANNEL_ID}"
echo "  DURATION_SEC=${DURATION_SEC}"
echo "  CHECK_INTERVAL_SEC=${CHECK_INTERVAL_SEC}"
echo "  MAX_LAST_SEEN_AGE_SEC=${MAX_LAST_SEEN_AGE_SEC}"

start_ts="$(date +%s)"
end_ts=$((start_ts + DURATION_SEC))
round=0

while [[ "$(date +%s)" -lt "${end_ts}" ]]; do
  round=$((round + 1))
  now_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  resp="$(curl -sS "${STATUS_URL}")"
  RESPONSE_JSON="${resp}" python3 - "${CHANNEL_ID}" "${MAX_LAST_SEEN_AGE_SEC}" "${round}" "${now_iso}" <<'PY'
import datetime as dt
import json
import os
import sys

channel_id = sys.argv[1]
max_age = int(sys.argv[2])
round_id = int(sys.argv[3])
now_iso = sys.argv[4]

payload = json.loads(os.environ.get("RESPONSE_JSON", "")).get("data") or {}
items = payload.get("list") or []
target = next((x for x in items if x.get("channelId") == channel_id), None)
if not target:
    print(f"[FAIL][round={round_id}] channel missing: {channel_id}")
    sys.exit(2)

status = str(target.get("status") or "").lower()
last_seen = target.get("lastSeenAt") or target.get("last_seen")
if status != "online":
    print(f"[FAIL][round={round_id}] status={status!r}")
    sys.exit(3)
if not last_seen:
    print(f"[FAIL][round={round_id}] lastSeen missing")
    sys.exit(4)

def parse_iso(s: str) -> dt.datetime:
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    # Python <=3.10 only supports up to microseconds (6 digits)
    if "." in s:
        head, tail = s.split(".", 1)
        if "+" in tail:
            frac, tz = tail.split("+", 1)
            s = f"{head}.{frac[:6]:<06}+{tz}"
        elif "-" in tail:
            frac, tz = tail.split("-", 1)
            s = f"{head}.{frac[:6]:<06}-{tz}"
        else:
            s = f"{head}.{tail[:6]:<06}"
    return dt.datetime.fromisoformat(s)

now = parse_iso(now_iso)
seen = parse_iso(str(last_seen))
age = (now - seen).total_seconds()
if age > max_age:
    print(f"[FAIL][round={round_id}] lastSeen stale age={age:.1f}s > {max_age}s")
    sys.exit(5)

print(f"[OK][round={round_id}] online lastSeenAge={age:.1f}s")
PY
  sleep "${CHECK_INTERVAL_SEC}"
done

echo "[PASS] channel stayed online for ${DURATION_SEC}s"
