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
DEFAULT_OPENCLAW_GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-ws://127.0.0.1:18789}"
DEFAULT_OPENCLAW_SESSION_NAMESPACE="${OPENCLAW_SESSION_NAMESPACE:-${OPENCLAW_SESSION_KEY:-agent:main:main}}"
DEFAULT_BACKEND_BASE="${BACKEND_BASE:-http://127.0.0.1:8081}"

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
OPENCLAW_GATEWAY_URL="${DEFAULT_OPENCLAW_GATEWAY_URL}"
OPENCLAW_SESSION_NAMESPACE="${DEFAULT_OPENCLAW_SESSION_NAMESPACE}"

if prompt_yes_no "是否配置高级参数（心跳/重连/并发/OpenClaw 本地网关）?" "n"; then
  HEARTBEAT_SEC="$(prompt_default "heartbeatIntervalSec" "${DEFAULT_HEARTBEAT_SEC}")"
  RECONNECT_MAX_SEC="$(prompt_default "reconnectMaxSec" "${DEFAULT_RECONNECT_MAX_SEC}")"
  MAX_CONCURRENT_INVOKES="$(prompt_default "maxConcurrentInvokes" "${DEFAULT_MAX_CONCURRENT_INVOKES}")"
  QUEUE_WAIT_TIMEOUT_MS="$(prompt_default "queueWaitTimeoutMs" "${DEFAULT_QUEUE_WAIT_TIMEOUT_MS}")"
  OPENCLAW_GATEWAY_URL="$(prompt_default "openclawGatewayUrl" "${DEFAULT_OPENCLAW_GATEWAY_URL}")"
  OPENCLAW_SESSION_NAMESPACE="$(prompt_default "openclawSessionNamespace(会话前缀)" "${DEFAULT_OPENCLAW_SESSION_NAMESPACE}")"
fi

BACKEND_BASE="$(prompt_default "后端 HTTP 地址(用于在线校验)" "${DEFAULT_BACKEND_BASE}")"
RUN_VERIFY_STABILITY="0"
if prompt_yes_no "是否执行长稳校验(较慢)?" "n"; then
  RUN_VERIFY_STABILITY="1"
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
  printf "set -euo pipefail; cd %q; WS_URL=%q CHANNEL_ID=%q DISPLAY_NAME=%q DEVICE_ID=%q CAPABILITIES=%q CHANNEL_TAGS=%q REGISTER_TOKEN=%q HEARTBEAT_SEC=%q RECONNECT_MAX_SEC=%q MAX_CONCURRENT_INVOKES=%q QUEUE_WAIT_TIMEOUT_MS=%q OPENCLAW_GATEWAY_URL=%q OPENCLAW_SESSION_NAMESPACE=%q LOCAL_SAFE_GUARD=0 bash bin/install_plugin_local.sh < /dev/null; if command -v openclaw >/dev/null 2>&1; then openclaw gateway restart; else echo '[WARN] openclaw command not found; 请远端手动重启'; fi" \
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
    "${OPENCLAW_GATEWAY_URL}" \
    "${OPENCLAW_SESSION_NAMESPACE}"
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
