#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_TARGET_DIR="${HOME}/.openclaw/workspace/skills/miaochat-file-output"
DEFAULT_LEGACY_LINK="${HOME}/.openclaw/skills/miaochat_file_output"

TARGET_DIR="${DEFAULT_TARGET_DIR}"
LEGACY_LINK="${DEFAULT_LEGACY_LINK}"
ENABLE_LEGACY_LINK="0"
API_BASE="${MIAO_CHAT_API_BASE:-}"
USER_ID="${MIAO_CHAT_USER_ID:-}"
TOKEN="${MIAO_CHAT_TOKEN:-}"

usage() {
  cat <<'USAGE'
Usage:
  bash install_skill.sh [--target-dir <dir>] [--legacy-link <dir>] [--no-legacy-link] [--api-base <url>] [--user-id <uid>] [--token <token>]

Options:
  --target-dir       安装目录（默认: ~/.openclaw/workspace/skills/miaochat-file-output）
  --legacy-link      旧路径兼容软链（默认关闭，路径: ~/.openclaw/skills/miaochat_file_output）
  --no-legacy-link   不创建旧路径软链（默认行为）
  --api-base         写入 config.json 的 apiBase
  --user-id          写入 config.json 的 userId（可选）
  --token            写入 config.json 的 token（可选）
  -h, --help         显示帮助
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-dir)
      TARGET_DIR="$2"
      shift 2
      ;;
    --legacy-link)
      LEGACY_LINK="$2"
      shift 2
      ;;
    --no-legacy-link)
      ENABLE_LEGACY_LINK="0"
      shift
      ;;
    --api-base)
      API_BASE="$2"
      shift 2
      ;;
    --user-id)
      USER_ID="$2"
      shift 2
      ;;
    --token)
      TOKEN="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

TARGET_DIR="${TARGET_DIR/#\~/$HOME}"
LEGACY_LINK="${LEGACY_LINK/#\~/$HOME}"

mkdir -p "${TARGET_DIR}/scripts"
cp -f "${SCRIPT_DIR}/send_generated_file.py" "${TARGET_DIR}/scripts/send_generated_file.py"
cp -f "${SCRIPT_DIR}/verify_skill.sh" "${TARGET_DIR}/scripts/verify_skill.sh"
cp -f "${SCRIPT_DIR}/verify_assistant_output_e2e.sh" "${TARGET_DIR}/scripts/verify_assistant_output_e2e.sh"
cp -f "${SCRIPT_DIR}/README.md" "${TARGET_DIR}/README.md"

ENTRY_SCRIPT="${TARGET_DIR}/scripts/send_generated_file.py"
CONFIG_PATH="${TARGET_DIR}/config.json"

cat > "${TARGET_DIR}/SKILL.md" <<'SKILL'
# miaochat-file-output

## Purpose
将 OpenClaw 在本地生成的文件，上传并回传到 Miao Chat 当前会话附件消息。

## Required Context
- `conversation_id`（优先从 invoke context 获取）
- `user_id`（优先从 invoke context 获取）

## Execute
```bash
python3 "__ENTRY_SCRIPT__" \
  --file-path /abs/path/to/file \
  --context-json '{"conversation_id":"c_xxx","user_id":"u_xxx"}' \
  --config "__CONFIG_PATH__"
```

## Notes
- 必须优先使用上下文中的 `conversation_id` 和 `user_id`，禁止回退到 demo 默认值。
- `scripts/send_generated_file.py` 在缺少 `user_id` 时会直接报错，避免误发到错误会话。
SKILL

python3 - "${TARGET_DIR}/SKILL.md" "${ENTRY_SCRIPT}" "${CONFIG_PATH}" <<'PY'
import pathlib
import sys

skill_path = pathlib.Path(sys.argv[1])
entry_script = sys.argv[2]
config_path = sys.argv[3]
content = skill_path.read_text(encoding="utf-8")
content = content.replace("__ENTRY_SCRIPT__", entry_script)
content = content.replace("__CONFIG_PATH__", config_path)
skill_path.write_text(content, encoding="utf-8")
PY

chmod +x "${TARGET_DIR}/scripts/send_generated_file.py"
chmod +x "${TARGET_DIR}/scripts/verify_skill.sh"
chmod +x "${TARGET_DIR}/scripts/verify_assistant_output_e2e.sh"

if [[ -n "${API_BASE}" || -n "${USER_ID}" || -n "${TOKEN}" ]]; then
  python3 - "${TARGET_DIR}/config.json" "${API_BASE}" "${USER_ID}" "${TOKEN}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
api_base = sys.argv[2].strip()
user_id = sys.argv[3].strip()
token = sys.argv[4].strip()

payload = {}
if api_base:
    payload["apiBase"] = api_base
if user_id:
    payload["userId"] = user_id
if token:
    payload["token"] = token

if payload:
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
fi

if [[ "${ENABLE_LEGACY_LINK}" == "1" ]]; then
  mkdir -p "$(dirname "${LEGACY_LINK}")"
  rm -rf "${LEGACY_LINK}"
  ln -s "${TARGET_DIR}" "${LEGACY_LINK}"
elif [[ -L "${LEGACY_LINK}" ]]; then
  rm -f "${LEGACY_LINK}"
fi

echo "[OK] Installed skill to: ${TARGET_DIR}"
echo "[OK] Entry script: ${TARGET_DIR}/scripts/send_generated_file.py"
if [[ "${ENABLE_LEGACY_LINK}" == "1" ]]; then
  echo "[OK] Legacy link: ${LEGACY_LINK} -> ${TARGET_DIR}"
fi
if [[ -f "${TARGET_DIR}/config.json" ]]; then
  echo "[OK] Config file: ${TARGET_DIR}/config.json"
fi
