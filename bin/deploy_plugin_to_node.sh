#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Generic node defaults
export WS_URL="${WS_URL:-ws://81.70.216.46:8081/ws/channel-gateway}"
export CHANNEL_ID="${CHANNEL_ID:-miao-node-server}"
export DEVICE_ID="${DEVICE_ID:-}"
export OPENCLAW_GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-ws://127.0.0.1:18789}"
export OPENCLAW_SESSION_KEY="${OPENCLAW_SESSION_KEY:-agent:main:main}"
export HEARTBEAT_SEC="${HEARTBEAT_SEC:-20}"
export RECONNECT_MAX_SEC="${RECONNECT_MAX_SEC:-8}"
export MAX_CONCURRENT_INVOKES="${MAX_CONCURRENT_INVOKES:-1}"
export QUEUE_WAIT_TIMEOUT_MS="${QUEUE_WAIT_TIMEOUT_MS:-60000}"

RESTART_GATEWAY="${RESTART_GATEWAY:-1}"
RUN_VERIFY_ONLINE="${RUN_VERIFY_ONLINE:-1}"
RUN_VERIFY_STABILITY="${RUN_VERIFY_STABILITY:-0}"

if [[ -n "${REGISTER_TOKEN:-}" ]]; then
  export REGISTER_TOKEN
fi

echo "[INFO] deploy plugin config to node"
echo "  WS_URL=${WS_URL}"
echo "  CHANNEL_ID=${CHANNEL_ID}"
echo "  DEVICE_ID=${DEVICE_ID}"
echo "  OPENCLAW_GATEWAY_URL=${OPENCLAW_GATEWAY_URL}"
echo "  OPENCLAW_SESSION_KEY=${OPENCLAW_SESSION_KEY}"

export LOCAL_SAFE_GUARD=0
bash "${SCRIPT_DIR}/install_plugin_local.sh" < /dev/null

if [[ "${RESTART_GATEWAY}" == "1" ]]; then
  echo "[INFO] restart openclaw gateway"
  if command -v openclaw >/dev/null 2>&1; then
    openclaw gateway restart
  elif [[ -n "${OPENCLAW_BIN:-}" ]]; then
    OPENCLAW_BIN_DIR="$(dirname "${OPENCLAW_BIN}")"
    export PATH="${OPENCLAW_BIN_DIR}:${PATH}"
    "${OPENCLAW_BIN}" gateway restart
  else
    echo "[WARN] openclaw command not found; skip restart"
    echo "[HINT] set OPENCLAW_BIN=/abs/path/to/openclaw or restart manually"
  fi
fi

if [[ "${RUN_VERIFY_ONLINE}" == "1" ]]; then
  echo "[INFO] verify online"
  BACKEND_BASE="${BACKEND_BASE:-http://127.0.0.1:8081}" CHANNEL_ID="${CHANNEL_ID}" \
    bash "${ROOT_DIR}/scripts/verify_channel_online.sh"
fi

if [[ "${RUN_VERIFY_STABILITY}" == "1" ]]; then
  echo "[INFO] verify stability"
  BACKEND_BASE="${BACKEND_BASE:-http://127.0.0.1:8081}" CHANNEL_ID="${CHANNEL_ID}" \
    bash "${ROOT_DIR}/scripts/verify_channel_longrun.sh"
fi

echo "[DONE] node plugin one-click deploy completed"
