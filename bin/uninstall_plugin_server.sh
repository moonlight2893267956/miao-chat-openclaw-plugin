#!/usr/bin/env bash
set -euo pipefail

CONNECT_SCRIPT="/Users/wuxiangyi/Desktop/script/server_connect.sh"

DEFAULT_USER_NAME="${USER_NAME:-yunmiao}"
DEFAULT_HOST="${HOST:-81.70.216.46}"
DEFAULT_PORT="${PORT:-22}"
DEFAULT_PLUGIN_ID="openclaw-miao-gateway"

prompt_default() {
  local label="$1"
  local default_value="$2"
  local value
  read -r -p "${label} [${default_value}]: " value
  printf "%s" "${value:-$default_value}"
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

echo "[INFO] 远端卸载 OpenClaw 插件"

USER_NAME="$(prompt_default "服务器用户" "${DEFAULT_USER_NAME}")"
HOST="$(prompt_default "服务器地址" "${DEFAULT_HOST}")"
PORT="$(prompt_default "SSH 端口" "${DEFAULT_PORT}")"
PLUGIN_ID="$(prompt_default "pluginId" "${DEFAULT_PLUGIN_ID}")"

if ! prompt_yes_no "确认卸载远端插件并删除 OpenClaw 注册?" "y"; then
  echo "[INFO] 已取消"
  exit 0
fi

CONNECT_ARGS=(-u "${USER_NAME}" -H "${HOST}" -p "${PORT}")

REMOTE_CMD=$(
  printf "%s" "set -euo pipefail; python3 - <<'PY'
import json
from pathlib import Path

plugin_id = '${PLUGIN_ID}'
home = Path.home() / '.openclaw'
config_path = home / 'openclaw.json'
ext_dir = home / 'extensions' / plugin_id

if config_path.exists():
    cfg = json.loads(config_path.read_text(encoding='utf-8'))
    plugins = cfg.setdefault('plugins', {})
    allow = plugins.get('allow', [])
    if isinstance(allow, list):
        plugins['allow'] = [x for x in allow if x != plugin_id]
    entries = plugins.get('entries', {})
    if isinstance(entries, dict):
        entries.pop(plugin_id, None)
    installs = plugins.get('installs', {})
    if isinstance(installs, dict):
        installs.pop(plugin_id, None)
    config_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'[OK] removed plugin config: {plugin_id}')
else:
    print(f'[WARN] openclaw config missing: {config_path}')

if ext_dir.exists():
    import shutil
    shutil.rmtree(ext_dir)
    print(f'[OK] removed extension dir: {ext_dir}')
else:
    print(f'[WARN] extension dir missing: {ext_dir}')
PY
if command -v openclaw >/dev/null 2>&1; then openclaw gateway restart; else echo '[WARN] openclaw command not found; 请远端手动重启'; fi"
)

"${CONNECT_SCRIPT}" "${CONNECT_ARGS[@]}" "${REMOTE_CMD}"

echo "[DONE] 远端插件卸载完成"
