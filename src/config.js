import os from "node:os";

function parseNumber(value, fallback) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    return fallback;
  }
  return parsed;
}

function clampInt(value, min, max) {
  const n = Math.round(value);
  return Math.min(max, Math.max(min, n));
}

function resolveSecret(value) {
  const raw = String(value ?? "").trim();
  if (!raw) {
    return "";
  }
  const envPattern = raw.match(/^\$\{([A-Z0-9_]+)\}$/i);
  if (envPattern) {
    return String(process.env[envPattern[1]] ?? "").trim();
  }
  const envPrefixPattern = raw.match(/^env:([A-Z0-9_]+)$/i);
  if (envPrefixPattern) {
    return String(process.env[envPrefixPattern[1]] ?? "").trim();
  }
  return raw;
}

function resolveStringList(value, fallback = []) {
  if (Array.isArray(value)) {
    return value
      .map((item) => String(item ?? "").trim())
      .filter(Boolean);
  }
  if (typeof value === "string") {
    return value
      .split(",")
      .map((item) => item.trim())
      .filter(Boolean);
  }
  return fallback;
}

function isValidWsUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === "ws:" || url.protocol === "wss:";
  } catch {
    return false;
  }
}

export function resolvePluginConfig(raw) {
  const warnings = [];
  const wsUrl = String(raw.wsUrl ?? "ws://81.70.216.46:8081/ws/channel-gateway").trim();
  const openclawGatewayUrl = String(raw.openclawGatewayUrl ?? "ws://127.0.0.1:18789").trim();
  const heartbeatIntervalSec = clampInt(parseNumber(raw.heartbeatIntervalSec ?? 20, 20), 5, 60);
  const reconnectMaxSec = clampInt(parseNumber(raw.reconnectMaxSec ?? 8, 8), 1, 120);
  const maxConcurrentInvokes = clampInt(parseNumber(raw.maxConcurrentInvokes ?? 1, 1), 1, 8);
  const queueWaitTimeoutMs = clampInt(parseNumber(raw.queueWaitTimeoutMs ?? 60000, 60000), 1000, 600000);
  const streamBubbleSplitGapMs = clampInt(parseNumber(raw.streamBubbleSplitGapMs ?? 4000, 4000), 1000, 15000);
  if (!isValidWsUrl(wsUrl)) {
    warnings.push("wsUrl is invalid; expected ws:// or wss://");
  }
  if (!isValidWsUrl(openclawGatewayUrl)) {
    warnings.push("openclawGatewayUrl is invalid; expected ws:// or wss://");
  }
  if (!String(raw.channelId ?? "").trim()) {
    warnings.push("channelId is empty; plugin will stay idle");
  }

  return {
    enabled: raw.enabled !== false,
    wsUrl,
    channelId: String(raw.channelId ?? "").trim(),
    displayName: String(raw.displayName ?? raw.channelId ?? "").trim(),
    deviceId: String(raw.deviceId ?? os.hostname()).trim(),
    capabilities: resolveStringList(raw.capabilities, ["stream", "retry", "heartbeat"]),
    channelTags: resolveStringList(raw.channelTags, []),
    registerToken: resolveSecret(raw.registerToken ?? ""),
    heartbeatIntervalSec,
    reconnectMaxSec,
    maxConcurrentInvokes,
    queueWaitTimeoutMs,
    streamBubbleSplitGapMs,
    openclawGatewayUrl,
    openclawSessionKey: String(raw.openclawSessionKey ?? "").trim(),
    configWarnings: warnings,
    pluginVersion: "0.1.0",
  };
}
