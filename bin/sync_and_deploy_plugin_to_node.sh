#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONNECT_SCRIPT="/Users/wuxiangyi/Desktop/script/server_connect.sh"

USER_NAME="${USER_NAME:-yunmiao}"
HOST="${HOST:-81.70.216.46}"
PORT="${PORT:-22}"
REMOTE_DIR="${REMOTE_DIR:-/home/yunmiao/apps/miao-chat-openclaw-plugin}"

if [[ ! -x "${CONNECT_SCRIPT}" ]]; then
  echo "[ERROR] connect script not found: ${CONNECT_SCRIPT}" >&2
  exit 1
fi

CONNECT_ARGS=(-u "${USER_NAME}" -p "${PORT}")
if [[ -n "${HOST}" ]]; then
  CONNECT_ARGS+=(-H "${HOST}")
fi

echo "[1/4] ensure remote dir: ${REMOTE_DIR}"
"${CONNECT_SCRIPT}" "${CONNECT_ARGS[@]}" "mkdir -p '${REMOTE_DIR}'"

echo "[2/4] sync plugin code to remote"
tar -C "${PLUGIN_DIR}" \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude '.DS_Store' \
  -czf - . \
  | "${CONNECT_SCRIPT}" "${CONNECT_ARGS[@]}" "tar -xzf - -C '${REMOTE_DIR}'"

echo "[3/4] deploy plugin on remote"
REMOTE_REGISTER_TOKEN="${REGISTER_TOKEN:-}"
REMOTE_OPENCLAW_BIN="${OPENCLAW_BIN:-}"
REMOTE_WS_URL="${WS_URL:-}"
REMOTE_CHANNEL_ID="${CHANNEL_ID:-}"
REMOTE_DEVICE_ID="${DEVICE_ID:-}"
REMOTE_OPENCLAW_GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-}"
REMOTE_OPENCLAW_SESSION_KEY="${OPENCLAW_SESSION_KEY:-}"
REMOTE_RUN_VERIFY_ONLINE="${RUN_VERIFY_ONLINE:-1}"
REMOTE_RUN_VERIFY_STABILITY="${RUN_VERIFY_STABILITY:-0}"
REMOTE_BACKEND_BASE="${BACKEND_BASE:-http://127.0.0.1:8081}"

REMOTE_CMD=$(
  printf "set -euo pipefail; cd %q; REGISTER_TOKEN=%q OPENCLAW_BIN=%q WS_URL=%q CHANNEL_ID=%q DEVICE_ID=%q OPENCLAW_GATEWAY_URL=%q OPENCLAW_SESSION_KEY=%q BACKEND_BASE=%q RUN_VERIFY_ONLINE=%q RUN_VERIFY_STABILITY=%q bash bin/deploy_plugin_to_node.sh" \
    "${REMOTE_DIR}" \
    "${REMOTE_REGISTER_TOKEN}" \
    "${REMOTE_OPENCLAW_BIN}" \
    "${REMOTE_WS_URL}" \
    "${REMOTE_CHANNEL_ID}" \
    "${REMOTE_DEVICE_ID}" \
    "${REMOTE_OPENCLAW_GATEWAY_URL}" \
    "${REMOTE_OPENCLAW_SESSION_KEY}" \
    "${REMOTE_BACKEND_BASE}" \
    "${REMOTE_RUN_VERIFY_ONLINE}" \
    "${REMOTE_RUN_VERIFY_STABILITY}"
)
"${CONNECT_SCRIPT}" "${CONNECT_ARGS[@]}" "${REMOTE_CMD}"

echo "[4/4] remote status"
"${CONNECT_SCRIPT}" "${CONNECT_ARGS[@]}" "curl -sS http://127.0.0.1:8081/api/v1/channel-gateway/status"

echo "[DONE] remote plugin deploy finished"
