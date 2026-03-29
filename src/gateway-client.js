import { handleInvokeStart } from "./invoke-handler.js";
import { handleCommandStart } from "./command-handler.js";

function shortId(prefix = "m") {
  return `${prefix}_${Math.random().toString(16).slice(2, 10)}${Date.now().toString(16).slice(-6)}`;
}

async function getWebSocketCtor() {
  if (typeof globalThis.WebSocket === "function") {
    return globalThis.WebSocket;
  }
  const wsPkg = await import("ws");
  return wsPkg.WebSocket;
}

export function createGatewayClient({ api, config }) {
  const logger = api.logger;
  const emitLog = (level, eventName, fields = {}) => {
    const safeLevel = typeof logger?.[level] === "function" ? level : "info";
    logger[safeLevel](JSON.stringify({
      component: "miao-gateway-client",
      event: eventName,
      channel_id: config.channelId || "",
      ...fields,
    }));
  };
  const registerTimeoutMs = Math.max(5000, Math.max(1, config.heartbeatIntervalSec) * 2000);
  let ws = null;
  let heartbeatTimer = null;
  let watchdogTimer = null;
  let reconnectTimer = null;
  let stopped = false;
  let connecting = false;
  let reconnectDelaySec = 1;
  let seq = 0;
  let sessionId = "";
  let lastRegisteredAt = "";
  let lastHeartbeatAt = "";
  let lastHeartbeatAckAt = 0;
  let connectStartedAt = 0;
  let lastError = "";

  const wsSend = (obj) => {
    if (!ws || ws.readyState !== 1) {
      return;
    }
    ws.send(JSON.stringify(obj));
  };

  const ackIncoming = (event) => {
    const msgId = String(event?.msg_id ?? "").trim();
    const eventName = String(event?.event ?? "").trim();
    if (!msgId || eventName === "ack") {
      return;
    }
    wsSend({
      protocol_version: "channel.v0",
      msg_id: shortId(),
      event: "ack",
      ts: new Date().toISOString(),
      trace_id: event?.trace_id || undefined,
      payload: {
        acked_msg_id: msgId,
        status: "ok",
      },
    });
  };

  const clearReconnectTimer = () => {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
  };

  const stopWatchdog = () => {
    if (watchdogTimer) {
      clearInterval(watchdogTimer);
      watchdogTimer = null;
    }
  };

  const hardCloseSocket = () => {
    if (!ws) {
      return;
    }
    try {
      if (typeof ws.terminate === "function") {
        ws.terminate();
      } else {
        ws.close();
      }
    } catch {
      // noop
    }
  };

  const resetSocketState = () => {
    stopHeartbeat();
    sessionId = "";
    lastHeartbeatAckAt = 0;
    connecting = false;
  };

  const forceReconnect = (reason) => {
    lastError = reason || lastError || "force reconnect";
    emitLog("warn", "force_reconnect", { reason: lastError });
    resetSocketState();
    hardCloseSocket();
    scheduleReconnect();
  };

  const sendRegister = () => {
    wsSend({
      protocol_version: "channel.v0",
      msg_id: shortId(),
      event: "register",
      ts: new Date().toISOString(),
      payload: {
        channel_id: config.channelId,
        device_id: config.deviceId,
        plugin_version: config.pluginVersion,
        capabilities: ["stream", "retry", "heartbeat"],
        auth: {
          type: "bearer",
          token: config.registerToken,
        },
      },
    });
  };

  const startHeartbeat = () => {
    stopHeartbeat();
    const intervalMs = Math.max(1, config.heartbeatIntervalSec) * 1000;
    heartbeatTimer = setInterval(() => {
      const nowMs = Date.now();
      if (lastHeartbeatAckAt > 0 && nowMs - lastHeartbeatAckAt > intervalMs * 3) {
        forceReconnect(`heartbeat ack timeout>${intervalMs * 3}ms`);
        return;
      }
      seq += 1;
      wsSend({
        protocol_version: "channel.v0",
        msg_id: shortId(),
        event: "heartbeat",
        ts: new Date().toISOString(),
        payload: {
          session_id: sessionId,
          seq,
          status: "idle",
        },
      });
      lastHeartbeatAt = new Date().toISOString();
    }, intervalMs);
  };

  const stopHeartbeat = () => {
    if (heartbeatTimer) {
      clearInterval(heartbeatTimer);
      heartbeatTimer = null;
    }
  };

  const startWatchdog = () => {
    stopWatchdog();
    watchdogTimer = setInterval(() => {
      if (stopped) {
        return;
      }
      const nowMs = Date.now();
      if (!sessionId) {
        if (connectStartedAt > 0 && nowMs - connectStartedAt > registerTimeoutMs) {
          forceReconnect(`register timeout>${registerTimeoutMs}ms`);
        }
        return;
      }
      const intervalMs = Math.max(1, config.heartbeatIntervalSec) * 1000;
      if (lastHeartbeatAckAt > 0 && nowMs - lastHeartbeatAckAt > intervalMs * 3) {
        forceReconnect(`watchdog heartbeat timeout>${intervalMs * 3}ms`);
      }
    }, 1000);
  };

  const scheduleReconnect = () => {
    if (stopped || reconnectTimer) {
      return;
    }
    const waitSec = Math.min(reconnectDelaySec, Math.max(1, config.reconnectMaxSec));
    emitLog("warn", "reconnect_scheduled", {
      wait_sec: waitSec,
      last_error: lastError || "",
    });
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      connect();
    }, waitSec * 1000);
    reconnectDelaySec = Math.min(reconnectDelaySec * 2, Math.max(1, config.reconnectMaxSec));
  };

  const onMessage = async (raw) => {
    let dataText = "";
    if (typeof raw.data === "string") {
      dataText = raw.data;
    } else if (Buffer.isBuffer(raw.data)) {
      dataText = raw.data.toString("utf-8");
    } else if (raw?.toString) {
      dataText = raw.toString();
    }

    if (!dataText) {
      return;
    }

    let event;
    try {
      event = JSON.parse(dataText);
    } catch {
      emitLog("warn", "invalid_event_json");
      return;
    }

    ackIncoming(event);

    switch (event.event) {
      case "register.ok": {
        sessionId = String(event?.payload?.session_id ?? "");
        const serverHeartbeat = Number(event?.payload?.heartbeat_interval_sec ?? config.heartbeatIntervalSec);
        if (Number.isFinite(serverHeartbeat) && serverHeartbeat > 0) {
          config.heartbeatIntervalSec = serverHeartbeat;
        }
        reconnectDelaySec = 1;
        clearReconnectTimer();
        lastRegisteredAt = new Date().toISOString();
        lastHeartbeatAckAt = Date.now();
        emitLog("info", "register_ok", {
          session_id: sessionId,
          heartbeat_sec: config.heartbeatIntervalSec,
        });
        startHeartbeat();
        break;
      }
      case "register.error": {
        lastError = String(event?.payload?.message ?? "register failed");
        emitLog("error", "register_error", {
          reason: lastError,
        });
        ws?.close();
        break;
      }
      case "heartbeat.ack": {
        lastHeartbeatAckAt = Date.now();
        emitLog("debug", "heartbeat_ack", {
          seq: event?.payload?.seq ?? "",
        });
        break;
      }
      case "channel.kick": {
        lastError = `kicked:${event?.payload?.reason ?? ""}`;
        emitLog("warn", "channel_kick", {
          reason: String(event?.payload?.reason ?? ""),
        });
        ws?.close();
        break;
      }
      case "invoke.start": {
        await handleInvokeStart({ logger, wsSend, config, event });
        break;
      }
      case "command.start": {
        await handleCommandStart({ logger, wsSend, config, event });
        break;
      }
      default:
        break;
    }
  };

  const connect = async () => {
    if (stopped || connecting) {
      return;
    }
    try {
      connecting = true;
      clearReconnectTimer();
      stopHeartbeat();
      stopWatchdog();
      connectStartedAt = Date.now();
      const WebSocketCtor = await getWebSocketCtor();
      emitLog("info", "connect_start", { ws_url: config.wsUrl });
      ws = new WebSocketCtor(config.wsUrl);
      startWatchdog();

      ws.onopen = () => {
        sendRegister();
      };

      ws.onmessage = (event) => {
        void onMessage(event);
      };

      ws.onerror = (event) => {
        lastError = String(event?.message ?? "socket error");
        emitLog("warn", "socket_error", {
          reason: String(event?.message ?? ""),
        });
      };

      ws.onclose = () => {
        stopWatchdog();
        resetSocketState();
        emitLog("info", "socket_closed", {
          last_registered_at: lastRegisteredAt || "",
          last_heartbeat_at: lastHeartbeatAt || "",
        });
        if (!stopped) {
          scheduleReconnect();
        }
      };
    } catch (error) {
      connecting = false;
      lastError = String(error?.message ?? error);
      emitLog("error", "connect_failed", {
        reason: lastError,
      });
      scheduleReconnect();
    }
  };

  return {
    start() {
      stopped = false;
      clearReconnectTimer();
      reconnectDelaySec = 1;
      void connect();
    },
    stop() {
      stopped = true;
      clearReconnectTimer();
      stopWatchdog();
      stopHeartbeat();
      if (ws) {
        hardCloseSocket();
      }
    },
  };
}
