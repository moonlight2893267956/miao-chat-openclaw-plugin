#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <conversation_id> [file_path]"
  echo "Required env: MIAO_CHAT_API_BASE"
  echo "Required env: MIAO_CHAT_USER_ID"
  echo "Optional env: MIAO_CHAT_TOKEN"
  exit 1
fi

CONVERSATION_ID="$1"
API_BASE="${MIAO_CHAT_API_BASE:-}"
USER_ID="${MIAO_CHAT_USER_ID:-}"
TOKEN="${MIAO_CHAT_TOKEN:-}"
FILE_PATH="${2:-/tmp/miaochat_assistant_output_e2e_$(date +%s).txt}"

if [ -z "$API_BASE" ]; then
  echo "MIAO_CHAT_API_BASE is required, example: export MIAO_CHAT_API_BASE=http://127.0.0.1:8081"
  exit 1
fi

if [ -z "$USER_ID" ]; then
  echo "MIAO_CHAT_USER_ID is required, example: export MIAO_CHAT_USER_ID=u_xxx"
  exit 1
fi

if [ ! -f "$FILE_PATH" ]; then
  cat > "$FILE_PATH" <<TXT
MiaoChat assistant output e2e verify file
Generated at: $(date -u +%FT%TZ)
Conversation: $CONVERSATION_ID
TXT
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SEND_OUTPUT_FILE="$(mktemp /tmp/miaochat_send_output_XXXXXX.json)"
MSG_OUTPUT_FILE="$(mktemp /tmp/miaochat_messages_XXXXXX.json)"
trap 'rm -f "$SEND_OUTPUT_FILE" "$MSG_OUTPUT_FILE"' EXIT

SEND_ARGS=(
  "$SCRIPT_DIR/send_generated_file.py"
  "--api-base" "$API_BASE"
  "--user-id" "$USER_ID"
  "--conversation-id" "$CONVERSATION_ID"
  "--file-path" "$FILE_PATH"
)

if [ -n "$TOKEN" ]; then
  SEND_ARGS+=("--token" "$TOKEN")
fi

python3 "${SEND_ARGS[@]}" | tee "$SEND_OUTPUT_FILE"

MESSAGE_URL="$API_BASE/api/v1/conversations/$CONVERSATION_ID/messages"
CURL_ARGS=(
  -sS
  -H "X-User-Id: $USER_ID"
)
if [ -n "$TOKEN" ]; then
  CURL_ARGS+=( -H "Authorization: Bearer $TOKEN" )
fi
CURL_ARGS+=("$MESSAGE_URL")

curl "${CURL_ARGS[@]}" > "$MSG_OUTPUT_FILE"

python3 - "$SEND_OUTPUT_FILE" "$MSG_OUTPUT_FILE" <<'PY'
import json
import pathlib
import sys

send_path = pathlib.Path(sys.argv[1])
msg_path = pathlib.Path(sys.argv[2])

send = json.loads(send_path.read_text(encoding='utf-8'))
resp = json.loads(msg_path.read_text(encoding='utf-8'))

if int(resp.get('code', -1)) != 0:
    raise SystemExit(f"messages API failed: {json.dumps(resp, ensure_ascii=False)}")

expected_message_id = send.get('message_id')
expected_file_id = send.get('file_id')

items = ((resp.get('data') or {}).get('list') or [])
for item in items:
    if item.get('message_id') != expected_message_id:
        continue
    for att in item.get('attachments') or []:
        if att.get('file_id') == expected_file_id:
            print(json.dumps({
                'ok': True,
                'message_id': expected_message_id,
                'file_id': expected_file_id,
                'attachment_name': att.get('name'),
                'attachment_mime': att.get('mime'),
                'attachment_size': att.get('size'),
            }, ensure_ascii=False))
            raise SystemExit(0)

raise SystemExit(
    f"E2E verify failed: message_id={expected_message_id}, file_id={expected_file_id} not found in conversation messages"
)
PY

echo "E2E verify passed for conversation_id=$CONVERSATION_ID"
