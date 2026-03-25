import os from "node:os";

function homePath(p) {
  return p.replace(/^~\//, `${os.homedir()}/`);
}

export function resolvePluginConfig(raw) {
  return {
    enabled: raw.enabled !== false,
    wsUrl: String(raw.wsUrl ?? "ws://81.70.216.46:8081/ws/channel-gateway").trim(),
    channelId: String(raw.channelId ?? "").trim(),
    deviceId: String(raw.deviceId ?? os.hostname()).trim(),
    registerToken: String(raw.registerToken ?? "").trim(),
    heartbeatIntervalSec: Number(raw.heartbeatIntervalSec ?? 20),
    reconnectMaxSec: Number(raw.reconnectMaxSec ?? 8),
    openclawGatewayUrl: String(raw.openclawGatewayUrl ?? "ws://127.0.0.1:18789").trim(),
    openclawSessionKey: String(raw.openclawSessionKey ?? "").trim(),
    openclawApiToken: String(raw.openclawApiToken ?? "").trim(),
    openclawCliPath: homePath(String(raw.openclawCliPath ?? "~/.nvm/versions/node/v22.16.0/bin/openclaw")),
    openclawNodeBinDir: homePath(String(raw.openclawNodeBinDir ?? "~/.nvm/versions/node/v22.16.0/bin")),
    pluginVersion: "0.1.0",
  };
}
