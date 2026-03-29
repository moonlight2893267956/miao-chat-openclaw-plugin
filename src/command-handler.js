import { buildSocketAuth, extractMessageText, loadGatewayClientClass } from "./invoke-handler.js";

function shortId(prefix = "m") {
  return `${prefix}_${Math.random().toString(16).slice(2, 10)}${Date.now().toString(16).slice(-6)}`;
}

function emitCommandLog(logger, level, eventName, fields = {}) {
  const safeLevel = typeof logger?.[level] === "function" ? level : "info";
  logger[safeLevel](JSON.stringify({
    component: "miao-gateway-command",
    event: eventName,
    ...fields,
  }));
}

function resolveSessionKey(config) {
  const raw = String(config.openclawSessionKey ?? "").trim();
  return raw || "";
}

function normalizeCommandText(command) {
  const trimmed = String(command ?? "").trim();
  if (!trimmed) {
    return "";
  }
  return trimmed.startsWith("/") ? trimmed : `/${trimmed}`;
}

function getCommandName(commandText) {
  const body = String(commandText ?? "").trim().replace(/^\//, "");
  const first = body.split(/\s+/, 1)[0] || "";
  return first.toLowerCase();
}

async function runSlashCommand(config, commandText, timeoutMs) {
  const GatewayClient = await loadGatewayClientClass(config);
  const sessionKey = resolveSessionKey(config);
  const socketAuth = buildSocketAuth(config);
  const runId = `cmd_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
  const commandName = getCommandName(commandText);
  const allowNoEventSuccess = commandName === "reset";

  if (commandText === "/stop") {
    return await new Promise((resolve, reject) => {
      let settled = false;
      let connected = false;
      let connectTimer = null;
      let overallTimer = null;

      const settle = (error, output = "stop signal sent") => {
        if (settled) {
          return;
        }
        settled = true;
        if (connectTimer) {
          clearTimeout(connectTimer);
        }
        if (overallTimer) {
          clearTimeout(overallTimer);
        }
        try {
          client.stop();
        } catch {
          // noop
        }
        if (error) {
          reject(error);
        } else {
          resolve(output);
        }
      };

      const client = new GatewayClient({
        url: config.openclawGatewayUrl,
        ...socketAuth,
        clientName: "gateway-client",
        clientDisplayName: `miao-gateway-${config.channelId || "plugin"}`,
        clientVersion: config.pluginVersion || "0.1.0",
        platform: process.platform,
        mode: "backend",
        onHelloOk: async () => {
          connected = true;
          try {
            const abortPromise = client.request("chat.abort", {
              ...(sessionKey ? { sessionKey } : {}),
            });
            const ackTimer = setTimeout(() => {
              settle(null, "stop signal sent (best-effort)");
            }, 1200);
            abortPromise.then(() => {
              clearTimeout(ackTimer);
              settle(null, "stop signal sent");
            }).catch((error) => {
              clearTimeout(ackTimer);
              const message = String(error?.message ?? "chat.abort failed");
              const lower = message.toLowerCase();
              if (lower.includes("timeout") || lower.includes("no active")) {
                settle(null, "stop signal sent (best-effort)");
                return;
              }
              settle(error instanceof Error ? error : new Error(message));
            });
          } catch (error) {
            const message = String(error?.message ?? "");
            if (message.toLowerCase().includes("timeout")) {
              settle(null, "stop signal sent (best-effort)");
              return;
            }
            settle(error instanceof Error ? error : new Error(message || "chat.abort failed"));
          }
        },
        onConnectError: (error) => settle(error instanceof Error ? error : new Error(String(error))),
        onClose: (code, reason) => {
          if (!settled && !connected) {
            settle(new Error(`openclaw gateway closed before ready code=${code} reason=${reason || "-"}`));
          }
        },
      });

      connectTimer = setTimeout(() => {
        if (!connected) {
          settle(new Error("openclaw gateway connect timeout"));
        }
      }, Math.min(5000, Math.max(1500, Math.floor(timeoutMs / 4))));

      overallTimer = setTimeout(() => {
        settle(new Error("slash command timeout"));
      }, Math.min(10000, Math.max(3000, Math.floor(timeoutMs / 2))));

      client.start();
    });
  }

  return await new Promise((resolve, reject) => {
    let settled = false;
    let connected = false;
    let sent = false;
    let currentText = "";
    let hasStreamEvent = false;
    let noEventTimer = null;
    let acceptedRunId = "";

    const settle = (error) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(connectTimer);
      clearTimeout(overallTimer);
      if (noEventTimer) {
        clearTimeout(noEventTimer);
      }
      try {
        client.stop();
      } catch {
        // noop
      }
      if (error) {
        reject(error);
      } else {
        resolve(currentText.trim());
      }
    };

    const client = new GatewayClient({
      url: config.openclawGatewayUrl,
      ...socketAuth,
      clientName: "gateway-client",
      clientDisplayName: `miao-gateway-${config.channelId || "plugin"}`,
      clientVersion: config.pluginVersion || "0.1.0",
      platform: process.platform,
      mode: "backend",
      onHelloOk: async () => {
        if (settled || sent) {
          return;
        }
        connected = true;
        sent = true;
        try {
          await client.request("chat.send", {
            ...(sessionKey ? { sessionKey } : {}),
            message: commandText,
            timeoutMs,
            idempotencyKey: runId,
          });
          // Some commands like /reset may not return chat events.
          if (allowNoEventSuccess) {
            noEventTimer = setTimeout(() => {
              if (!hasStreamEvent) {
                settle();
              }
            }, 2500);
          }
        } catch (error) {
          settle(error instanceof Error ? error : new Error(String(error)));
        }
      },
      onEvent: (evt) => {
        if (settled || evt?.event !== "chat") {
          return;
        }
        const payload = evt?.payload ?? {};
        const payloadRunId = String(payload?.runId ?? "");
        if (acceptedRunId) {
          if (payloadRunId && payloadRunId !== acceptedRunId) {
            return;
          }
        } else if (payloadRunId) {
          acceptedRunId = payloadRunId;
        } else {
          acceptedRunId = runId;
        }
        if (payloadRunId && payloadRunId !== acceptedRunId) {
          return;
        }
        hasStreamEvent = true;
        if (noEventTimer) {
          clearTimeout(noEventTimer);
          noEventTimer = null;
        }
        const state = String(payload?.state ?? "");
        if (state === "delta" || state === "final" || state === "done" || state === "completed") {
          const text = extractMessageText(payload?.message)
            || String(payload?.text ?? payload?.content ?? "");
          if (text) {
            currentText = text;
          }
          if (state === "final" || state === "done" || state === "completed") {
            settle();
          }
          return;
        }
        if (state === "error") {
          settle(new Error(String(payload?.errorMessage ?? "slash command error")));
          return;
        }
        if (state === "aborted") {
          settle();
        }
      },
      onConnectError: (error) => {
        settle(error instanceof Error ? error : new Error(String(error)));
      },
      onClose: (code, reason) => {
        if (!settled && !connected) {
          settle(new Error(`openclaw gateway closed before ready code=${code} reason=${reason || "-"}`));
        }
      },
    });

    const connectTimer = setTimeout(() => {
      if (!connected) {
        settle(new Error("openclaw gateway connect timeout"));
      }
    }, Math.min(15000, Math.max(3000, Math.floor(timeoutMs / 2))));
    const overallTimer = setTimeout(() => {
      settle(new Error("slash command timeout"));
    }, Math.max(5000, timeoutMs + 3000));

    client.start();
  });
}

export async function handleCommandStart({ logger, wsSend, config, event }) {
  const payload = event.payload ?? {};
  const traceId = event.trace_id || "";
  const requestId = String(payload.request_id ?? "").trim();
  const commandText = normalizeCommandText(payload.command);
  const timeoutMs = Number(payload.timeout_ms ?? 180000);
  const effectiveTimeoutMs = Number.isFinite(timeoutMs)
    ? Math.max(3000, Math.min(timeoutMs, 600000))
    : 180000;

  const baseFields = {
    channel_id: config.channelId || "",
    request_id: requestId || "",
    trace_id: traceId || "",
    command: commandText || "",
  };

  if (!requestId) {
    emitCommandLog(logger, "warn", "command_invalid_request", {
      ...baseFields,
      reason: "missing_request_id",
    });
    return;
  }
  if (!commandText) {
    emitCommandLog(logger, "warn", "command_invalid_request", {
      ...baseFields,
      reason: "empty_command",
    });
    wsSend({
      protocol_version: "channel.v0",
      msg_id: shortId(),
      event: "command.error",
      ts: new Date().toISOString(),
      trace_id: traceId,
      payload: {
        request_id: requestId,
        code: "CHANNEL_OPENCLAW_ERROR",
        message: "empty command",
      },
    });
    return;
  }

  const startedAtMs = Date.now();
  emitCommandLog(logger, "info", "command_start", {
    ...baseFields,
    timeout_ms: effectiveTimeoutMs,
  });
  try {
    const output = await runSlashCommand(config, commandText, effectiveTimeoutMs);
    wsSend({
      protocol_version: "channel.v0",
      msg_id: shortId(),
      event: "command.done",
      ts: new Date().toISOString(),
      trace_id: traceId,
      payload: {
        request_id: requestId,
        output: output || "",
      },
    });
    emitCommandLog(logger, "info", "command_done", {
      ...baseFields,
      duration_ms: Date.now() - startedAtMs,
      output_chars: (output || "").length,
    });
  } catch (error) {
    const message = String(error?.message ?? "command failed");
    const code = message.toLowerCase().includes("timeout")
      ? "CHANNEL_OPENCLAW_TIMEOUT"
      : "CHANNEL_OPENCLAW_ERROR";
    wsSend({
      protocol_version: "channel.v0",
      msg_id: shortId(),
      event: "command.error",
      ts: new Date().toISOString(),
      trace_id: traceId,
      payload: {
        request_id: requestId,
        code,
        message,
      },
    });
    emitCommandLog(logger, "error", "command_error", {
      ...baseFields,
      code,
      message,
      duration_ms: Date.now() - startedAtMs,
    });
  }
}
