#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="openclaw-miao-gateway"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_SRC="$(cd "${SCRIPT_DIR}/.." && pwd)"
OPENCLAW_HOME="${HOME}/.openclaw"
CONFIG_PATH="${OPENCLAW_HOME}/openclaw.json"
EXT_DIR="${OPENCLAW_HOME}/extensions/${PLUGIN_ID}"
DEFAULT_WS_URL="ws://81.70.216.46:8081/ws/channel-gateway"
DEFAULT_CHANNEL_ID="ch_miao_mac_01"
DEFAULT_HEARTBEAT_SEC="20"
DEFAULT_RECONNECT_MAX_SEC="8"
DEFAULT_MAX_CONCURRENT_INVOKES="1"
DEFAULT_OPENCLAW_GATEWAY_URL="ws://127.0.0.1:18789"
DEFAULT_OPENCLAW_SESSION_KEY="agent:main:miao-chat"

if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "[ERROR] not found: ${CONFIG_PATH}"
  exit 1
fi

prompt_default() {
  local label="$1"
  local default_value="$2"
  local value
  read -r -p "${label} [${default_value}]: " value
  if [[ -z "${value}" ]]; then
    printf "%s" "${default_value}"
  else
    printf "%s" "${value}"
  fi
}

prompt_optional() {
  local label="$1"
  local value
  read -r -p "${label} (留空则省略): " value
  printf "%s" "${value}"
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

mkdir -p "${OPENCLAW_HOME}/extensions"
rm -rf "${EXT_DIR}"
mkdir -p "${EXT_DIR}"

cp -R "${PLUGIN_SRC}/"* "${EXT_DIR}/"

WS_URL="${DEFAULT_WS_URL}"
CHANNEL_ID="${DEFAULT_CHANNEL_ID}"
DEVICE_ID=""
REGISTER_TOKEN=""
HEARTBEAT_SEC=""
RECONNECT_MAX_SEC=""
MAX_CONCURRENT_INVOKES=""
OPENCLAW_GATEWAY_URL=""
OPENCLAW_SESSION_KEY=""

if [[ -t 0 && -t 1 ]]; then
  echo "[INFO] 进入交互式配置（仅 wsUrl/channelId 必填，其它可省略）"
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

  DEVICE_ID="$(prompt_optional "deviceId")"
  REGISTER_TOKEN="$(prompt_optional "registerToken")"

  if prompt_yes_no "是否配置高级参数（心跳/重连/并发/OpenClaw 本地网关）?" "n"; then
    HEARTBEAT_SEC="$(prompt_default "heartbeatIntervalSec" "${DEFAULT_HEARTBEAT_SEC}")"
    RECONNECT_MAX_SEC="$(prompt_default "reconnectMaxSec" "${DEFAULT_RECONNECT_MAX_SEC}")"
    MAX_CONCURRENT_INVOKES="$(prompt_default "maxConcurrentInvokes" "${DEFAULT_MAX_CONCURRENT_INVOKES}")"
    OPENCLAW_GATEWAY_URL="$(prompt_default "openclawGatewayUrl" "${DEFAULT_OPENCLAW_GATEWAY_URL}")"
    OPENCLAW_SESSION_KEY="$(prompt_default "openclawSessionKey" "${DEFAULT_OPENCLAW_SESSION_KEY}")"
  fi
else
  WS_URL="${WS_URL:-$DEFAULT_WS_URL}"
  CHANNEL_ID="${CHANNEL_ID:-$DEFAULT_CHANNEL_ID}"
fi

export WS_URL CHANNEL_ID DEVICE_ID REGISTER_TOKEN
export HEARTBEAT_SEC RECONNECT_MAX_SEC MAX_CONCURRENT_INVOKES OPENCLAW_GATEWAY_URL OPENCLAW_SESSION_KEY

python - <<'PY'
import json
import os
from pathlib import Path

plugin_id = "openclaw-miao-gateway"
home = Path.home() / ".openclaw"
config_path = home / "openclaw.json"
ext_dir = home / "extensions" / plugin_id

def getenv(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()

def maybe_int(name: str):
    value = getenv(name, "")
    if not value:
        return None
    return int(value)

ws_url = getenv("WS_URL", "ws://81.70.216.46:8081/ws/channel-gateway")
channel_id = getenv("CHANNEL_ID", "ch_miao_mac_01")

cfg = json.loads(config_path.read_text(encoding="utf-8"))
plugins = cfg.setdefault("plugins", {})
allow = plugins.setdefault("allow", [])
if plugin_id not in allow:
    allow.append(plugin_id)

entries = plugins.setdefault("entries", {})
entry = entries.setdefault(plugin_id, {})
entry["enabled"] = True
plugin_config = {
    "enabled": True,
    "wsUrl": ws_url,
    "channelId": channel_id,
}

device_id = getenv("DEVICE_ID")
if device_id:
    plugin_config["deviceId"] = device_id

register_token = getenv("REGISTER_TOKEN")
if register_token:
    plugin_config["registerToken"] = register_token

heartbeat_sec = maybe_int("HEARTBEAT_SEC")
if heartbeat_sec is not None:
    plugin_config["heartbeatIntervalSec"] = heartbeat_sec

reconnect_sec = maybe_int("RECONNECT_MAX_SEC")
if reconnect_sec is not None:
    plugin_config["reconnectMaxSec"] = reconnect_sec

max_concurrent = maybe_int("MAX_CONCURRENT_INVOKES")
if max_concurrent is not None:
    plugin_config["maxConcurrentInvokes"] = max_concurrent

openclaw_gateway_url = getenv("OPENCLAW_GATEWAY_URL")
if openclaw_gateway_url:
    plugin_config["openclawGatewayUrl"] = openclaw_gateway_url

openclaw_session_key = getenv("OPENCLAW_SESSION_KEY")
if openclaw_session_key:
    plugin_config["openclawSessionKey"] = openclaw_session_key

entry["config"] = plugin_config

installs = plugins.setdefault("installs", {})
installs[plugin_id] = {
    "source": "path",
    "spec": str(ext_dir),
    "installPath": str(ext_dir),
    "version": "0.1.0",
    "resolvedName": plugin_id,
    "resolvedVersion": "0.1.0",
    "resolvedSpec": str(ext_dir)
}

config_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"[OK] configured plugin: {plugin_id}")
print(f"[OK] openclaw config: {config_path}")
print(f"[OK] plugin path: {ext_dir}")
print("[OK] plugin config keys:", ", ".join(sorted(plugin_config.keys())))
PY

echo "[DONE] install completed"
