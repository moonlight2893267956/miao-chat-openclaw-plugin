#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 3 ]; then
  echo "Usage: $0 <api_base> <user_id> <conversation_id> [file_path]"
  exit 1
fi

API_BASE="$1"
USER_ID="$2"
CONVERSATION_ID="$3"
FILE_PATH="${4:-/tmp/miaochat_skill_verify_$(date +%s).txt}"

if [ ! -f "$FILE_PATH" ]; then
  echo "MiaoChat skill verify file generated at $(date -u +%FT%TZ)" > "$FILE_PATH"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "$SCRIPT_DIR/send_generated_file.py" \
  --api-base "$API_BASE" \
  --user-id "$USER_ID" \
  --conversation-id "$CONVERSATION_ID" \
  --file-path "$FILE_PATH"
