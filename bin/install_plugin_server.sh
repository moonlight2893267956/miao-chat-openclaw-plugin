#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONNECT_SCRIPT="/Users/wuxiangyi/Desktop/script/server_connect.sh"

DEFAULT_USER_NAME="${USER_NAME:-yunmiao}"
DEFAULT_HOST="${HOST:-81.70.216.46}"
DEFAULT_PORT="${PORT:-22}"
DEFAULT_REMOTE_DIR="${REMOTE_DIR:-/home/${DEFAULT_USER_NAME}/apps/miao-chat-openclaw-plugin}"

DEFAULT_WS_URL="${WS_URL:-ws://81.70.216.46:8081/ws/channel-gateway}"
DEFAULT_CHANNEL_ID="${CHANNEL_ID:-miao-node-server}"
DEFAULT_DISPLAY_NAME="${DISPLAY_NAME:-${DEFAULT_CHANNEL_ID}}"
DEFAULT_DEVICE_ID="${DEVICE_ID:-}"
DEFAULT_CAPABILITIES="${CAPABILITIES:-stream,retry,heartbeat}"
DEFAULT_CHANNEL_TAGS="${CHANNEL_TAGS:-}"
DEFAULT_REGISTER_TOKEN="${REGISTER_TOKEN:-miao_reg_jnpIHD4gxsphosDUt-Vcoy3P}"
DEFAULT_HEARTBEAT_SEC="${HEARTBEAT_SEC:-20}"
DEFAULT_RECONNECT_MAX_SEC="${RECONNECT_MAX_SEC:-8}"
DEFAULT_MAX_CONCURRENT_INVOKES="${MAX_CONCURRENT_INVOKES:-1}"
DEFAULT_QUEUE_WAIT_TIMEOUT_MS="${QUEUE_WAIT_TIMEOUT_MS:-60000}"
DEFAULT_INVOKE_IDLE_TIMEOUT_MS="${INVOKE_IDLE_TIMEOUT_MS:-180000}"
DEFAULT_STREAM_BUBBLE_SPLIT_GAP_MS="${STREAM_BUBBLE_SPLIT_GAP_MS:-4000}"
DEFAULT_OPENCLAW_GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-ws://127.0.0.1:18789}"
DEFAULT_OPENCLAW_SESSION_NAMESPACE="${OPENCLAW_SESSION_NAMESPACE:-${OPENCLAW_SESSION_KEY:-agent:main:main}}"
DEFAULT_BACKEND_BASE="${BACKEND_BASE:-http://127.0.0.1:8081}"
DEFAULT_INSTALL_FILE_OUTPUT_SKILL="${INSTALL_FILE_OUTPUT_SKILL:-y}"
DEFAULT_SKILL_TARGET_DIR="${SKILL_TARGET_DIR:-/home/${DEFAULT_USER_NAME}/.openclaw/workspace/skills/miaochat-file-output}"
DEFAULT_SKILL_API_BASE="${SKILL_API_BASE:-http://127.0.0.1:8081}"
DEFAULT_SKILL_USER_ID="${SKILL_USER_ID:-}"
DEFAULT_SKILL_TOKEN="${SKILL_TOKEN:-}"

prompt_default() {
  local label="$1"
  local default_value="$2"
  local value
  read -r -p "${label} [${default_value}]: " value
  printf "%s" "${value:-$default_value}"
}

prompt_optional_with_default() {
  local label="$1"
  local default_value="$2"
  local value
  if [[ -n "${default_value}" ]]; then
    read -r -p "${label} [${default_value}] (留空保留默认): " value
    printf "%s" "${value:-$default_value}"
  else
    read -r -p "${label} (留空则省略): " value
    printf "%s" "${value}"
  fi
}

prompt_yes_no() {
  local label="$1"
  local default_value="$2"
  local value
  read -r -p "${label} [${default_value}]: " value
  value="${value:-$default_value}"
  case "${value}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

fetch_remote_plugin_config_json() {
  local user_name="$1"
  local host="$2"
  local port="$3"
  "${CONNECT_SCRIPT}" -u "${user_name}" -H "${host}" -p "${port}" "python3 - <<'PY'
import json
from pathlib import Path

config_path = Path.home() / '.openclaw' / 'openclaw.json'
plugin_id = 'openclaw-miao-gateway'
if not config_path.exists():
    raise SystemExit(0)
try:
    cfg = json.loads(config_path.read_text(encoding='utf-8'))
except Exception:
    raise SystemExit(0)
entry = (((cfg.get('plugins') or {}).get('entries') or {}).get(plugin_id) or {})
plugin_cfg = entry.get('config') or {}
print(json.dumps(plugin_cfg, ensure_ascii=False))
PY" 2>/dev/null | tail -n 1
}

read_remote_config_value() {
  local json_payload="$1"
  local key="$2"
  if [[ -z "${json_payload}" ]]; then
    return 0
  fi
  JSON_PAYLOAD="${json_payload}" python3 - "$key" <<'PY'
import json
import os
import sys

key = sys.argv[1]
raw = os.environ.get("JSON_PAYLOAD", "").strip()
if not raw:
    raise SystemExit(0)
try:
    payload = json.loads(raw)
except Exception:
    raise SystemExit(0)
value = payload.get(key)
if value is None:
    raise SystemExit(0)
if isinstance(value, list):
    print(",".join(str(item).strip() for item in value if str(item).strip()))
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

if [[ ! -x "${CONNECT_SCRIPT}" ]]; then
  echo "[ERROR] connect script not found: ${CONNECT_SCRIPT}" >&2
  exit 1
fi

if [[ ! -t 0 || ! -t 1 ]]; then
  echo "[ERROR] 请在交互式终端里运行此脚本" >&2
  exit 1
fi

echo "[INFO] 远端交互式部署 OpenClaw 插件"
echo "[INFO] 这个脚本会自动完成：代码同步 -> 远端安装 -> 重启网关 -> 在线校验"

USER_NAME="$(prompt_default "服务器用户" "${DEFAULT_USER_NAME}")"
HOST="$(prompt_default "服务器地址" "${DEFAULT_HOST}")"
PORT="$(prompt_default "SSH 端口" "${DEFAULT_PORT}")"
REMOTE_DIR="$(prompt_default "远端项目目录" "${DEFAULT_REMOTE_DIR}")"

echo "[INFO] 读取远端现有 OpenClaw 插件配置..."
REMOTE_PLUGIN_CONFIG_JSON="$(fetch_remote_plugin_config_json "${USER_NAME}" "${HOST}" "${PORT}" || true)"
if [[ -n "${REMOTE_PLUGIN_CONFIG_JSON}" ]]; then
  DEFAULT_WS_URL="$(read_remote_config_value "${REMOTE_PLUGIN_CONFIG_JSON}" "wsUrl" || true)"
  DEFAULT_CHANNEL_ID="$(read_remote_config_value "${REMOTE_PLUGIN_CONFIG_JSON}" "channelId" || true)"
  DEFAULT_DISPLAY_NAME="$(read_remote_config_value "${REMOTE_PLUGIN_CONFIG_JSON}" "displayName" || true)"
  DEFAULT_DEVICE_ID="$(read_remote_config_value "${REMOTE_PLUGIN_CONFIG_JSON}" "deviceId" || true)"
  DEFAULT_CAPABILITIES="$(read_remote_config_value "${REMOTE_PLUGIN_CONFIG_JSON}" "capabilities" || true)"
  DEFAULT_CHANNEL_TAGS="$(read_remote_config_value "${REMOTE_PLUGIN_CONFIG_JSON}" "channelTags" || true)"
  DEFAULT_REGISTER_TOKEN="$(read_remote_config_value "${REMOTE_PLUGIN_CONFIG_JSON}" "registerToken" || true)"
  DEFAULT_HEARTBEAT_SEC="$(read_remote_config_value "${REMOTE_PLUGIN_CONFIG_JSON}" "heartbeatIntervalSec" || true)"
  DEFAULT_RECONNECT_MAX_SEC="$(read_remote_config_value "${REMOTE_PLUGIN_CONFIG_JSON}" "reconnectMaxSec" || true)"
  DEFAULT_MAX_CONCURRENT_INVOKES="$(read_remote_config_value "${REMOTE_PLUGIN_CONFIG_JSON}" "maxConcurrentInvokes" || true)"
  DEFAULT_QUEUE_WAIT_TIMEOUT_MS="$(read_remote_config_value "${REMOTE_PLUGIN_CONFIG_JSON}" "queueWaitTimeoutMs" || true)"
  DEFAULT_INVOKE_IDLE_TIMEOUT_MS="$(read_remote_config_value "${REMOTE_PLUGIN_CONFIG_JSON}" "invokeIdleTimeoutMs" || true)"
  DEFAULT_STREAM_BUBBLE_SPLIT_GAP_MS="$(read_remote_config_value "${REMOTE_PLUGIN_CONFIG_JSON}" "streamBubbleSplitGapMs" || true)"
  DEFAULT_OPENCLAW_GATEWAY_URL="$(read_remote_config_value "${REMOTE_PLUGIN_CONFIG_JSON}" "openclawGatewayUrl" || true)"
  DEFAULT_OPENCLAW_SESSION_NAMESPACE="$(read_remote_config_value "${REMOTE_PLUGIN_CONFIG_JSON}" "openclawSessionKey" || true)"
  echo "[INFO] 已加载远端默认值"
else
  echo "[INFO] 远端未检测到现有插件配置，继续使用脚本默认值"
fi

DEFAULT_WS_URL="${DEFAULT_WS_URL:-ws://81.70.216.46:8081/ws/channel-gateway}"
DEFAULT_CHANNEL_ID="${DEFAULT_CHANNEL_ID:-miao-node-server}"
DEFAULT_DISPLAY_NAME="${DEFAULT_DISPLAY_NAME:-${DEFAULT_CHANNEL_ID}}"
DEFAULT_HEARTBEAT_SEC="${DEFAULT_HEARTBEAT_SEC:-20}"
DEFAULT_RECONNECT_MAX_SEC="${DEFAULT_RECONNECT_MAX_SEC:-8}"
DEFAULT_MAX_CONCURRENT_INVOKES="${DEFAULT_MAX_CONCURRENT_INVOKES:-1}"
DEFAULT_QUEUE_WAIT_TIMEOUT_MS="${DEFAULT_QUEUE_WAIT_TIMEOUT_MS:-60000}"
DEFAULT_INVOKE_IDLE_TIMEOUT_MS="${DEFAULT_INVOKE_IDLE_TIMEOUT_MS:-180000}"
DEFAULT_STREAM_BUBBLE_SPLIT_GAP_MS="${DEFAULT_STREAM_BUBBLE_SPLIT_GAP_MS:-4000}"
DEFAULT_OPENCLAW_GATEWAY_URL="${DEFAULT_OPENCLAW_GATEWAY_URL:-ws://127.0.0.1:18789}"
DEFAULT_OPENCLAW_SESSION_NAMESPACE="${DEFAULT_OPENCLAW_SESSION_NAMESPACE:-agent:main:main}"
DEFAULT_REGISTER_TOKEN="${DEFAULT_REGISTER_TOKEN:-miao_reg_jnpIHD4gxsphosDUt-Vcoy3P}"
DEFAULT_CAPABILITIES="${DEFAULT_CAPABILITIES:-stream,retry,heartbeat}"
DEFAULT_CHANNEL_TAGS="${DEFAULT_CHANNEL_TAGS:-}"

WS_URL="$(prompt_default "后端 wsUrl" "${DEFAULT_WS_URL}")"
while [[ -z "${WS_URL}" ]]; do
  echo "[WARN] wsUrl 不能为空"
  WS_URL="$(prompt_default "后端 wsUrl" "${DEFAULT_WS_URL}")"
done

CHANNEL_ID="$(prompt_default "channelId" "${DEFAULT_CHANNEL_ID}")"
while [[ -z "${CHANNEL_ID}" ]]; do
  echo "[WARN] channelId 不能为空"
  CHANNEL_ID="$(prompt_default "channelId" "${DEFAULT_CHANNEL_ID}")"
done

DISPLAY_NAME="$(prompt_default "displayName" "${DEFAULT_DISPLAY_NAME:-$CHANNEL_ID}")"
DEVICE_ID="$(prompt_optional_with_default "deviceId" "${DEFAULT_DEVICE_ID}")"
CAPABILITIES="$(prompt_default "capabilities(逗号分隔)" "${DEFAULT_CAPABILITIES}")"
CHANNEL_TAGS="$(prompt_optional_with_default "channelTags(逗号分隔)" "${DEFAULT_CHANNEL_TAGS}")"
REGISTER_TOKEN="$(prompt_default "registerToken" "${DEFAULT_REGISTER_TOKEN}")"

HEARTBEAT_SEC="${DEFAULT_HEARTBEAT_SEC}"
RECONNECT_MAX_SEC="${DEFAULT_RECONNECT_MAX_SEC}"
MAX_CONCURRENT_INVOKES="${DEFAULT_MAX_CONCURRENT_INVOKES}"
QUEUE_WAIT_TIMEOUT_MS="${DEFAULT_QUEUE_WAIT_TIMEOUT_MS}"
INVOKE_IDLE_TIMEOUT_MS="${DEFAULT_INVOKE_IDLE_TIMEOUT_MS}"
STREAM_BUBBLE_SPLIT_GAP_MS="${DEFAULT_STREAM_BUBBLE_SPLIT_GAP_MS}"
OPENCLAW_GATEWAY_URL="${DEFAULT_OPENCLAW_GATEWAY_URL}"
OPENCLAW_SESSION_NAMESPACE="${DEFAULT_OPENCLAW_SESSION_NAMESPACE}"

if prompt_yes_no "是否配置高级参数（心跳/重连/并发/分气泡/OpenClaw 本地网关）?" "n"; then
  HEARTBEAT_SEC="$(prompt_default "heartbeatIntervalSec" "${DEFAULT_HEARTBEAT_SEC}")"
  RECONNECT_MAX_SEC="$(prompt_default "reconnectMaxSec" "${DEFAULT_RECONNECT_MAX_SEC}")"
  MAX_CONCURRENT_INVOKES="$(prompt_default "maxConcurrentInvokes" "${DEFAULT_MAX_CONCURRENT_INVOKES}")"
  QUEUE_WAIT_TIMEOUT_MS="$(prompt_default "queueWaitTimeoutMs" "${DEFAULT_QUEUE_WAIT_TIMEOUT_MS}")"
  INVOKE_IDLE_TIMEOUT_MS="$(prompt_default "invokeIdleTimeoutMs" "${DEFAULT_INVOKE_IDLE_TIMEOUT_MS}")"
  STREAM_BUBBLE_SPLIT_GAP_MS="$(prompt_default "streamBubbleSplitGapMs" "${DEFAULT_STREAM_BUBBLE_SPLIT_GAP_MS}")"
  OPENCLAW_GATEWAY_URL="$(prompt_default "openclawGatewayUrl" "${DEFAULT_OPENCLAW_GATEWAY_URL}")"
  OPENCLAW_SESSION_NAMESPACE="$(prompt_default "openclawSessionNamespace(会话前缀)" "${DEFAULT_OPENCLAW_SESSION_NAMESPACE}")"
fi

BACKEND_BASE="$(prompt_default "后端 HTTP 地址(用于在线校验)" "${DEFAULT_BACKEND_BASE}")"
RUN_VERIFY_STABILITY="0"
if prompt_yes_no "是否执行长稳校验(较慢)?" "n"; then
  RUN_VERIFY_STABILITY="1"
fi

INSTALL_FILE_OUTPUT_SKILL="0"
SKILL_TARGET_DIR="${DEFAULT_SKILL_TARGET_DIR}"
SKILL_API_BASE="${DEFAULT_SKILL_API_BASE}"
SKILL_USER_ID="${DEFAULT_SKILL_USER_ID}"
SKILL_TOKEN="${DEFAULT_SKILL_TOKEN}"
if prompt_yes_no "是否安装 miaochat-file-output skill?" "${DEFAULT_INSTALL_FILE_OUTPUT_SKILL}"; then
  INSTALL_FILE_OUTPUT_SKILL="1"
  SKILL_TARGET_DIR="$(prompt_default "skill 目标目录" "${DEFAULT_SKILL_TARGET_DIR}")"
  SKILL_API_BASE="$(prompt_default "skill apiBase" "${DEFAULT_SKILL_API_BASE}")"
  SKILL_USER_ID="$(prompt_optional_with_default "skill userId(可留空)" "${DEFAULT_SKILL_USER_ID}")"
  SKILL_TOKEN="$(prompt_optional_with_default "skill token(可留空)" "${DEFAULT_SKILL_TOKEN}")"
fi

CONNECT_ARGS=(-u "${USER_NAME}" -H "${HOST}" -p "${PORT}")

echo "[1/4] 创建远端目录 ${REMOTE_DIR}"
"${CONNECT_SCRIPT}" "${CONNECT_ARGS[@]}" "mkdir -p '${REMOTE_DIR}'"

echo "[2/4] 同步插件代码到远端"
tar -C "${PLUGIN_DIR}" \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude '.DS_Store' \
  --exclude 'bin/legacy' \
  -czf - . \
  | "${CONNECT_SCRIPT}" "${CONNECT_ARGS[@]}" "tar -xzf - -C '${REMOTE_DIR}'"

echo "[3/4] 远端安装并重启 OpenClaw"
REMOTE_CMD=$(
  printf "set -euo pipefail; cd %q; WS_URL=%q CHANNEL_ID=%q DISPLAY_NAME=%q DEVICE_ID=%q CAPABILITIES=%q CHANNEL_TAGS=%q REGISTER_TOKEN=%q HEARTBEAT_SEC=%q RECONNECT_MAX_SEC=%q MAX_CONCURRENT_INVOKES=%q QUEUE_WAIT_TIMEOUT_MS=%q INVOKE_IDLE_TIMEOUT_MS=%q STREAM_BUBBLE_SPLIT_GAP_MS=%q OPENCLAW_GATEWAY_URL=%q OPENCLAW_SESSION_NAMESPACE=%q LOCAL_SAFE_GUARD=0 bash bin/install_plugin_local.sh < /dev/null; if [ %q = '1' ]; then rm -rf %q; bash skills/miaochat_file_output/install_skill.sh --no-legacy-link --target-dir %q --api-base %q --user-id %q --token %q; fi; if command -v openclaw >/dev/null 2>&1; then openclaw gateway restart; else echo '[WARN] openclaw command not found; 请远端手动重启'; fi" \
    "${REMOTE_DIR}" \
    "${WS_URL}" \
    "${CHANNEL_ID}" \
    "${DISPLAY_NAME}" \
    "${DEVICE_ID}" \
    "${CAPABILITIES}" \
    "${CHANNEL_TAGS}" \
    "${REGISTER_TOKEN}" \
    "${HEARTBEAT_SEC}" \
    "${RECONNECT_MAX_SEC}" \
    "${MAX_CONCURRENT_INVOKES}" \
    "${QUEUE_WAIT_TIMEOUT_MS}" \
    "${INVOKE_IDLE_TIMEOUT_MS}" \
    "${STREAM_BUBBLE_SPLIT_GAP_MS}" \
    "${OPENCLAW_GATEWAY_URL}" \
    "${OPENCLAW_SESSION_NAMESPACE}" \
    "${INSTALL_FILE_OUTPUT_SKILL}" \
    "/home/${USER_NAME}/.openclaw/skills/miaochat_file_output" \
    "${SKILL_TARGET_DIR}" \
    "${SKILL_API_BASE}" \
    "${SKILL_USER_ID}" \
    "${SKILL_TOKEN}"
)
"${CONNECT_SCRIPT}" "${CONNECT_ARGS[@]}" "${REMOTE_CMD}"

echo "[4/4] 在线校验"
VERIFY_CMD=$(
  printf "set -euo pipefail; cd %q; BACKEND_BASE=%q CHANNEL_ID=%q bash scripts/verify_channel_online.sh" \
    "${REMOTE_DIR}" \
    "${BACKEND_BASE}" \
    "${CHANNEL_ID}"
)
"${CONNECT_SCRIPT}" "${CONNECT_ARGS[@]}" "${VERIFY_CMD}"

if [[ "${RUN_VERIFY_STABILITY}" == "1" ]]; then
  echo "[INFO] 执行长稳校验"
  LONGRUN_CMD=$(
    printf "set -euo pipefail; cd %q; BACKEND_BASE=%q CHANNEL_ID=%q bash scripts/verify_channel_longrun.sh" \
      "${REMOTE_DIR}" \
      "${BACKEND_BASE}" \
      "${CHANNEL_ID}"
  )
  "${CONNECT_SCRIPT}" "${CONNECT_ARGS[@]}" "${LONGRUN_CMD}"
fi

echo "[DONE] 远端插件部署完成"
