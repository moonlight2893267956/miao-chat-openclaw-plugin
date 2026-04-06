#!/usr/bin/env bash
set -euo pipefail

# 动态渠道稳定性巡检。
# 用法：
#   bash scripts/verify_channel_longrun.sh [backend_base] [channel_id] [duration_sec] [interval_sec] [timeout_ms] [out_path]

BACKEND_BASE="${1:-http://81.70.216.46:8081}"
CHANNEL_ID="${2:-miao-node-local}"
DURATION_SEC="${3:-1800}"
INTERVAL_SEC="${4:-30}"
TIMEOUT_MS="${5:-45000}"
OUT_PATH="${6:-}"

INVOKE_URL="${BACKEND_BASE%/}/api/v1/channel-gateway/invoke-sync"
STATUS_URL="${BACKEND_BASE%/}/api/v1/channel-gateway/status"

tmp_latency_file="$(mktemp)"
trap 'rm -f "$tmp_latency_file"' EXIT

ok_count=0
fail_count=0
offline_count=0
round=0
start_ts="$(date +%s)"
end_ts=$((start_ts + DURATION_SEC))

json_field() {
  local input="$1"
  local expr="$2"
  python - "$expr" "$input" <<'PY'
import json, sys
expr = sys.argv[1]
raw = sys.argv[2]
try:
    d = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)
if expr == 'code':
    print(d.get('code', ''))
elif expr == 'content_len':
    print(len(((d.get('data') or {}).get('content') or '')))
elif expr == 'msg':
    print(((d.get('data') or {}).get('error_message') or d.get('message') or '')[:200])
else:
    print("")
PY
}

extract_channel_status() {
  local input="$1"
  local cid="$2"
  python - "$cid" "$input" <<'PY'
import json, sys
cid = sys.argv[1]
raw = sys.argv[2]
try:
    d = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)
items = ((d.get('data') or {}).get('list') or [])
for item in items:
    if item.get('channelId') == cid:
        print(item.get('status', ''))
        break
else:
    print("")
PY
}

while [[ "$(date +%s)" -lt "$end_ts" ]]; do
  round=$((round + 1))

  status_json="$(curl -sS --max-time 6 "$STATUS_URL" || true)"
  ch_status="$(extract_channel_status "$status_json" "$CHANNEL_ID" 2>/dev/null || true)"
  if [[ "$ch_status" != "online" ]]; then
    offline_count=$((offline_count + 1))
  fi

  payload=$(cat <<JSON
{"channel_id":"${CHANNEL_ID}","prompt":"Dynamic channel longrun #${round}: reply short alive line","timeout_ms":${TIMEOUT_MS}}
JSON
)

  curl_resp="$(curl -sS --max-time 70 -w '\n__CURL_TIME_TOTAL__=%{time_total}' -H 'Content-Type: application/json' -d "${payload}" "${INVOKE_URL}" || true)"
  body="$(printf '%s' "$curl_resp" | sed '/^__CURL_TIME_TOTAL__=/d')"
  ttotal="$(printf '%s' "$curl_resp" | awk -F= '/^__CURL_TIME_TOTAL__=/{print $2}')"
  [[ -n "$ttotal" ]] && printf '%s\n' "$ttotal" >> "$tmp_latency_file"

  code="$(json_field "$body" code 2>/dev/null || true)"
  content_len="$(json_field "$body" content_len 2>/dev/null || true)"

  if [[ "$code" == "0" && -n "$content_len" && "$content_len" != "0" ]]; then
    ok_count=$((ok_count + 1))
    echo "[${round}] OK t=${ttotal}s content_len=${content_len}"
  else
    fail_count=$((fail_count + 1))
    msg="$(json_field "$body" msg 2>/dev/null || true)"
    echo "[${round}] FAIL t=${ttotal}s code=${code} content_len=${content_len} msg=${msg}"
  fi

  now="$(date +%s)"
  if [[ "$now" -ge "$end_ts" ]]; then
    break
  fi
  sleep "$INTERVAL_SEC"
done

summary_json="$(python - <<PY
import json
from pathlib import Path
vals=[]
for line in Path('$tmp_latency_file').read_text().splitlines():
    try:
        vals.append(float(line.strip()))
    except Exception:
        pass
vals.sort()
def pct(p):
    if not vals:
        return 0
    idx=max(0,min(len(vals)-1,int(len(vals)*p+0.999999)-1))
    return round(vals[idx],3)
out={
  'duration_sec': int('$DURATION_SEC'),
  'interval_sec': int('$INTERVAL_SEC'),
  'channel_id': '$CHANNEL_ID',
  'ok_count': int('$ok_count'),
  'fail_count': int('$fail_count'),
  'offline_count': int('$offline_count'),
  'latency_p50_sec': pct(0.50),
  'latency_p95_sec': pct(0.95),
  'latency_max_sec': round(vals[-1],3) if vals else 0,
  'pass': int('$fail_count') == 0
}
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
)"

echo "$summary_json"
if [[ -n "$OUT_PATH" ]]; then
  mkdir -p "$(dirname "$OUT_PATH")"
  printf '%s\n' "$summary_json" > "$OUT_PATH"
  echo "report written: $OUT_PATH"
fi

if printf '%s' "$summary_json" | rg -q '"pass"\s*:\s*true'; then
  exit 0
fi
exit 4
