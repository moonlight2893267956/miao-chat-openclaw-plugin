#!/usr/bin/env bash
set -euo pipefail

# 动态渠道验证：连续 10 次 invoke-sync，要求每次都返回有效 content 或明确失败原因。
# 用法：
#   bash scripts/verify_channel_invoke.sh [backend_base] [channel_id]
# 例子：
#   bash scripts/verify_channel_invoke.sh http://81.70.216.46:8081 miao-node-local

BACKEND_BASE="${1:-http://81.70.216.46:8081}"
CHANNEL_ID="${2:-miao-node-local}"
URL="${BACKEND_BASE%/}/api/v1/channel-gateway/invoke-sync"

ok_count=0
fail_count=0

for i in $(seq 1 10); do
  payload=$(cat <<JSON
{"channel_id":"${CHANNEL_ID}","prompt":"M2 verify run #${i}: reply with one short line","timeout_ms":45000}
JSON
)

  resp="$(curl -sS --max-time 70 -H 'Content-Type: application/json' -d "${payload}" "${URL}" || true)"
  if [[ -z "${resp}" ]]; then
    echo "[$i] FAIL empty response"
    fail_count=$((fail_count+1))
    continue
  fi

  code="$(printf '%s' "${resp}" | python -c 'import sys,json;d=json.load(sys.stdin);print(d.get("code",""))' 2>/dev/null || true)"
  biz_code="$(printf '%s' "${resp}" | python -c 'import sys,json;d=json.load(sys.stdin);print(((d.get("data") or {}).get("code") or ""))' 2>/dev/null || true)"
  content_len="$(printf '%s' "${resp}" | python -c 'import sys,json;d=json.load(sys.stdin);print(len(((d.get("data") or {}).get("content") or "")))' 2>/dev/null || true)"

  if [[ "${code}" == "0" && -n "${content_len}" && "${content_len}" != "0" ]]; then
    text_preview="$(printf '%s' "${resp}" | python -c 'import sys,json;d=json.load(sys.stdin);print(((d.get("data") or {}).get("content") or "").replace("\n"," ")[:80])' 2>/dev/null || true)"
    echo "[$i] OK ${text_preview}"
    ok_count=$((ok_count+1))
  else
    err_msg="$(printf '%s' "${resp}" | python -c 'import sys,json;d=json.load(sys.stdin);print(((d.get("data") or {}).get("error_message") or d.get("message") or "")[:160])' 2>/dev/null || true)"
    echo "[$i] FAIL code=${code} biz_code=${biz_code} content_len=${content_len} msg=${err_msg}"
    fail_count=$((fail_count+1))
  fi

done

echo "RESULT ok=${ok_count} fail=${fail_count} channel=${CHANNEL_ID} backend=${BACKEND_BASE}"
if [[ ${fail_count} -gt 0 ]]; then
  exit 2
fi
