#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="openclaw-miao-gateway"
OPENCLAW_HOME="${HOME}/.openclaw"
CONFIG_PATH="${OPENCLAW_HOME}/openclaw.json"
EXT_DIR="${OPENCLAW_HOME}/extensions/${PLUGIN_ID}"

if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "[ERROR] not found: ${CONFIG_PATH}"
  exit 1
fi

python - <<'PY'
import json
from pathlib import Path

plugin_id = "openclaw-miao-gateway"
config_path = Path.home() / ".openclaw" / "openclaw.json"

cfg = json.loads(config_path.read_text(encoding="utf-8"))
plugins = cfg.setdefault("plugins", {})

allow = plugins.get("allow", [])
if isinstance(allow, list):
    plugins["allow"] = [x for x in allow if x != plugin_id]

entries = plugins.get("entries", {})
if isinstance(entries, dict):
    entries.pop(plugin_id, None)

installs = plugins.get("installs", {})
if isinstance(installs, dict):
    installs.pop(plugin_id, None)

config_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"[OK] removed plugin config: {plugin_id}")
print(f"[OK] openclaw config: {config_path}")
PY

rm -rf "${EXT_DIR}"
echo "[OK] removed extension dir: ${EXT_DIR}"
echo "[DONE] uninstall completed"
