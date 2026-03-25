#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="openclaw-miao-gateway"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_SRC="$(cd "${SCRIPT_DIR}/.." && pwd)"
OPENCLAW_HOME="${HOME}/.openclaw"
CONFIG_PATH="${OPENCLAW_HOME}/openclaw.json"
EXT_DIR="${OPENCLAW_HOME}/extensions/${PLUGIN_ID}"

if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "[ERROR] not found: ${CONFIG_PATH}"
  exit 1
fi

mkdir -p "${OPENCLAW_HOME}/extensions"
rm -rf "${EXT_DIR}"
mkdir -p "${EXT_DIR}"

cp -R "${PLUGIN_SRC}/"* "${EXT_DIR}/"

python - <<'PY'
import json
from pathlib import Path

plugin_id = "openclaw-miao-gateway"
home = Path.home() / ".openclaw"
config_path = home / "openclaw.json"
ext_dir = home / "extensions" / plugin_id

cfg = json.loads(config_path.read_text(encoding="utf-8"))
plugins = cfg.setdefault("plugins", {})
allow = plugins.setdefault("allow", [])
if plugin_id not in allow:
    allow.append(plugin_id)

entries = plugins.setdefault("entries", {})
entry = entries.setdefault(plugin_id, {})
entry["enabled"] = True
entry.setdefault("config", {
    "enabled": True,
    "wsUrl": "ws://81.70.216.46:8081/ws/channel-gateway",
    "channelId": "ch_miao_mac_01",
    "deviceId": "macbook-pro",
    "registerToken": "",
    "heartbeatIntervalSec": 20,
    "reconnectMaxSec": 8,
    "openclawGatewayUrl": "ws://127.0.0.1:18789",
    "openclawSessionKey": "agent:main:miao-chat",
    "openclawApiToken": "",
    "openclawCliPath": "~/.nvm/versions/node/v22.16.0/bin/openclaw",
    "openclawNodeBinDir": "~/.nvm/versions/node/v22.16.0/bin"
})

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
PY

echo "[DONE] install completed"
