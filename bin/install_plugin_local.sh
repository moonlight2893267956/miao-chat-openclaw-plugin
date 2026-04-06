#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="openclaw-miao-gateway"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_SRC="$(cd "${SCRIPT_DIR}/.." && pwd)"
OPENCLAW_HOME="${HOME}/.openclaw"
CONFIG_PATH="${OPENCLAW_HOME}/openclaw.json"
EXT_DIR="${OPENCLAW_HOME}/extensions/${PLUGIN_ID}"
DEFAULT_WS_URL="ws://81.70.216.46:8081/ws/channel-gateway"
DEFAULT_CHANNEL_ID="miao-node-local"
DEFAULT_DISPLAY_NAME="My Mac OpenClaw"
DEFAULT_HEARTBEAT_SEC="20"
DEFAULT_RECONNECT_MAX_SEC="8"
DEFAULT_MAX_CONCURRENT_INVOKES="1"
DEFAULT_QUEUE_WAIT_TIMEOUT_MS="60000"
DEFAULT_STREAM_BUBBLE_SPLIT_GAP_MS="4000"
DEFAULT_OPENCLAW_GATEWAY_URL="ws://127.0.0.1:18789"
DEFAULT_OPENCLAW_SESSION_NAMESPACE="agent:local:main"
DEFAULT_REGISTER_TOKEN="miao_reg_jnpIHD4gxsphosDUt-Vcoy3P"
DEFAULT_CAPABILITIES="stream,retry,heartbeat"
DEFAULT_CHANNEL_TAGS=""

load_existing_config_value() {
  local key="$1"
  python3 - "$CONFIG_PATH" "$PLUGIN_ID" "$key" <<'PY'
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
plugin_id = sys.argv[2]
key = sys.argv[3]
if not config_path.exists():
    raise SystemExit(0)
try:
    cfg = json.loads(config_path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)
entry = (((cfg.get("plugins") or {}).get("entries") or {}).get(plugin_id) or {})
plugin_cfg = entry.get("config") or {}
value = plugin_cfg.get(key)
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

mkdir -p "${OPENCLAW_HOME}/extensions"
rm -rf "${EXT_DIR}"
mkdir -p "${EXT_DIR}"

cp -R "${PLUGIN_SRC}/"* "${EXT_DIR}/"

EXISTING_WS_URL="$(load_existing_config_value "wsUrl" || true)"
EXISTING_CHANNEL_ID="$(load_existing_config_value "channelId" || true)"
EXISTING_DISPLAY_NAME="$(load_existing_config_value "displayName" || true)"
EXISTING_DEVICE_ID="$(load_existing_config_value "deviceId" || true)"
EXISTING_CAPABILITIES="$(load_existing_config_value "capabilities" || true)"
EXISTING_CHANNEL_TAGS="$(load_existing_config_value "channelTags" || true)"
EXISTING_REGISTER_TOKEN="$(load_existing_config_value "registerToken" || true)"
EXISTING_HEARTBEAT_SEC="$(load_existing_config_value "heartbeatIntervalSec" || true)"
EXISTING_RECONNECT_MAX_SEC="$(load_existing_config_value "reconnectMaxSec" || true)"
EXISTING_MAX_CONCURRENT_INVOKES="$(load_existing_config_value "maxConcurrentInvokes" || true)"
EXISTING_QUEUE_WAIT_TIMEOUT_MS="$(load_existing_config_value "queueWaitTimeoutMs" || true)"
EXISTING_STREAM_BUBBLE_SPLIT_GAP_MS="$(load_existing_config_value "streamBubbleSplitGapMs" || true)"
EXISTING_OPENCLAW_GATEWAY_URL="$(load_existing_config_value "openclawGatewayUrl" || true)"
EXISTING_OPENCLAW_SESSION_NAMESPACE="$(load_existing_config_value "openclawSessionKey" || true)"

WS_URL="${WS_URL:-${EXISTING_WS_URL:-$DEFAULT_WS_URL}}"
CHANNEL_ID="${CHANNEL_ID:-${EXISTING_CHANNEL_ID:-$DEFAULT_CHANNEL_ID}}"
DISPLAY_NAME="${DISPLAY_NAME:-${EXISTING_DISPLAY_NAME:-$DEFAULT_DISPLAY_NAME}}"
DEVICE_ID="${DEVICE_ID:-${EXISTING_DEVICE_ID:-}}"
CAPABILITIES="${CAPABILITIES:-${EXISTING_CAPABILITIES:-$DEFAULT_CAPABILITIES}}"
CHANNEL_TAGS="${CHANNEL_TAGS:-${EXISTING_CHANNEL_TAGS:-$DEFAULT_CHANNEL_TAGS}}"
REGISTER_TOKEN="${REGISTER_TOKEN:-${EXISTING_REGISTER_TOKEN:-$DEFAULT_REGISTER_TOKEN}}"
HEARTBEAT_SEC="${HEARTBEAT_SEC:-${EXISTING_HEARTBEAT_SEC:-}}"
RECONNECT_MAX_SEC="${RECONNECT_MAX_SEC:-${EXISTING_RECONNECT_MAX_SEC:-}}"
MAX_CONCURRENT_INVOKES="${MAX_CONCURRENT_INVOKES:-${EXISTING_MAX_CONCURRENT_INVOKES:-}}"
QUEUE_WAIT_TIMEOUT_MS="${QUEUE_WAIT_TIMEOUT_MS:-${EXISTING_QUEUE_WAIT_TIMEOUT_MS:-}}"
STREAM_BUBBLE_SPLIT_GAP_MS="${STREAM_BUBBLE_SPLIT_GAP_MS:-${EXISTING_STREAM_BUBBLE_SPLIT_GAP_MS:-}}"
OPENCLAW_GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-${EXISTING_OPENCLAW_GATEWAY_URL:-$DEFAULT_OPENCLAW_GATEWAY_URL}}"
OPENCLAW_SESSION_NAMESPACE="${OPENCLAW_SESSION_NAMESPACE:-${OPENCLAW_SESSION_KEY:-${EXISTING_OPENCLAW_SESSION_NAMESPACE:-$DEFAULT_OPENCLAW_SESSION_NAMESPACE}}}"
LOCAL_SAFE_GUARD="${LOCAL_SAFE_GUARD:-1}"

if [[ "${LOCAL_SAFE_GUARD}" == "1" ]]; then
  if [[ -z "${CHANNEL_ID}" ]]; then
    CHANNEL_ID="${DEFAULT_CHANNEL_ID}"
  fi
  if [[ -z "${OPENCLAW_SESSION_NAMESPACE}" ]]; then
    OPENCLAW_SESSION_NAMESPACE="${DEFAULT_OPENCLAW_SESSION_NAMESPACE}"
  fi
fi

if [[ -t 0 && -t 1 ]]; then
  echo "[INFO] 进入交互式配置（仅 wsUrl/channelId 必填，其它可省略）"
  WS_URL="$(prompt_default "后端 wsUrl" "${WS_URL}")"
  while [[ -z "${WS_URL}" ]]; do
    echo "[WARN] wsUrl 不能为空"
    WS_URL="$(prompt_default "后端 wsUrl" "${WS_URL}")"
  done

  CHANNEL_ID="$(prompt_default "channelId" "${CHANNEL_ID}")"
  while [[ -z "${CHANNEL_ID}" ]]; do
    echo "[WARN] channelId 不能为空"
    CHANNEL_ID="$(prompt_default "channelId" "${CHANNEL_ID}")"
  done

  DISPLAY_NAME="$(prompt_default "displayName" "${DISPLAY_NAME:-$CHANNEL_ID}")"
  DEVICE_ID="$(prompt_optional_with_default "deviceId" "${DEVICE_ID}")"
  CAPABILITIES="$(prompt_default "capabilities(逗号分隔)" "${CAPABILITIES:-$DEFAULT_CAPABILITIES}")"
  CHANNEL_TAGS="$(prompt_optional_with_default "channelTags(逗号分隔)" "${CHANNEL_TAGS}")"
  REGISTER_TOKEN="$(prompt_default "registerToken" "${REGISTER_TOKEN}")"

  if prompt_yes_no "是否配置高级参数（心跳/重连/并发/分气泡/OpenClaw 本地网关）?" "n"; then
    HEARTBEAT_SEC="$(prompt_default "heartbeatIntervalSec" "${HEARTBEAT_SEC:-$DEFAULT_HEARTBEAT_SEC}")"
    RECONNECT_MAX_SEC="$(prompt_default "reconnectMaxSec" "${RECONNECT_MAX_SEC:-$DEFAULT_RECONNECT_MAX_SEC}")"
    MAX_CONCURRENT_INVOKES="$(prompt_default "maxConcurrentInvokes" "${MAX_CONCURRENT_INVOKES:-$DEFAULT_MAX_CONCURRENT_INVOKES}")"
    QUEUE_WAIT_TIMEOUT_MS="$(prompt_default "queueWaitTimeoutMs" "${QUEUE_WAIT_TIMEOUT_MS:-$DEFAULT_QUEUE_WAIT_TIMEOUT_MS}")"
    STREAM_BUBBLE_SPLIT_GAP_MS="$(prompt_default "streamBubbleSplitGapMs" "${STREAM_BUBBLE_SPLIT_GAP_MS:-$DEFAULT_STREAM_BUBBLE_SPLIT_GAP_MS}")"
    OPENCLAW_GATEWAY_URL="$(prompt_default "openclawGatewayUrl" "${OPENCLAW_GATEWAY_URL}")"
    OPENCLAW_SESSION_NAMESPACE="$(prompt_default "openclawSessionNamespace(会话前缀)" "${OPENCLAW_SESSION_NAMESPACE}")"
  fi
else
  WS_URL="${WS_URL:-${EXISTING_WS_URL:-$DEFAULT_WS_URL}}"
  CHANNEL_ID="${CHANNEL_ID:-${EXISTING_CHANNEL_ID:-$DEFAULT_CHANNEL_ID}}"
  DISPLAY_NAME="${DISPLAY_NAME:-${EXISTING_DISPLAY_NAME:-$CHANNEL_ID}}"
  CAPABILITIES="${CAPABILITIES:-${EXISTING_CAPABILITIES:-$DEFAULT_CAPABILITIES}}"
  CHANNEL_TAGS="${CHANNEL_TAGS:-${EXISTING_CHANNEL_TAGS:-$DEFAULT_CHANNEL_TAGS}}"
  OPENCLAW_GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-${EXISTING_OPENCLAW_GATEWAY_URL:-$DEFAULT_OPENCLAW_GATEWAY_URL}}"
  OPENCLAW_SESSION_NAMESPACE="${OPENCLAW_SESSION_NAMESPACE:-${OPENCLAW_SESSION_KEY:-${EXISTING_OPENCLAW_SESSION_NAMESPACE:-$DEFAULT_OPENCLAW_SESSION_NAMESPACE}}}"
fi

export WS_URL CHANNEL_ID DISPLAY_NAME DEVICE_ID CAPABILITIES CHANNEL_TAGS REGISTER_TOKEN
export HEARTBEAT_SEC RECONNECT_MAX_SEC MAX_CONCURRENT_INVOKES QUEUE_WAIT_TIMEOUT_MS STREAM_BUBBLE_SPLIT_GAP_MS OPENCLAW_GATEWAY_URL OPENCLAW_SESSION_NAMESPACE

python3 - <<'PY'
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

def parse_csv(name: str):
    value = getenv(name, "")
    if not value:
        return []
    return [item.strip() for item in value.split(",") if item.strip()]

ws_url = getenv("WS_URL", "ws://81.70.216.46:8081/ws/channel-gateway")
channel_id = getenv("CHANNEL_ID", "miao-node-local")
display_name = getenv("DISPLAY_NAME", channel_id) or channel_id

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
    "displayName": display_name,
    "capabilities": parse_csv("CAPABILITIES"),
    "channelTags": parse_csv("CHANNEL_TAGS"),
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

queue_wait_timeout_ms = maybe_int("QUEUE_WAIT_TIMEOUT_MS")
if queue_wait_timeout_ms is not None:
    plugin_config["queueWaitTimeoutMs"] = queue_wait_timeout_ms

stream_bubble_split_gap_ms = maybe_int("STREAM_BUBBLE_SPLIT_GAP_MS")
if stream_bubble_split_gap_ms is not None:
    plugin_config["streamBubbleSplitGapMs"] = stream_bubble_split_gap_ms

openclaw_gateway_url = getenv("OPENCLAW_GATEWAY_URL")
if openclaw_gateway_url:
    plugin_config["openclawGatewayUrl"] = openclaw_gateway_url

openclaw_session_namespace = getenv("OPENCLAW_SESSION_NAMESPACE", "agent:local:main")
if openclaw_session_namespace:
    plugin_config["openclawSessionKey"] = openclaw_session_namespace

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
