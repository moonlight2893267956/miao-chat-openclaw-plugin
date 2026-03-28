import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

function shortId(prefix = "m") {
  return `${prefix}_${Math.random().toString(16).slice(2, 10)}${Date.now().toString(16).slice(-6)}`;
}

let gatewayClientClassPromise = null;
let activeInvokeCount = 0;
const activeInvokeIds = new Set();

function resolveOpenclawInstallRoot(config) {
  const cliCandidate = String(process.env.OPENCLAW_CLI_PATH || "openclaw").trim();
  const cliPath = fs.existsSync(cliCandidate)
    ? cliCandidate
    : execFileSync("which", [cliCandidate], { encoding: "utf8" }).trim();
  const real = fs.realpathSync(cliPath);
  const dir = path.dirname(real);

  // npm global symlink usually resolves to .../openclaw/openclaw.mjs
  if (fs.existsSync(path.join(dir, "dist"))) {
    return dir;
  }

  // fallback for layouts resolving to .../openclaw/bin/openclaw
  const parent = path.dirname(dir);
  if (fs.existsSync(path.join(parent, "dist"))) {
    return parent;
  }

  throw new Error(`cannot resolve openclaw install root from ${real}`);
}

function hasGatewayClientShape(value) {
  return (
    typeof value === "function" &&
    value.name === "GatewayClient" &&
    typeof value.prototype?.start === "function" &&
    typeof value.prototype?.request === "function"
  );
}

function listGatewayClientBundles(distDir) {
  const files = fs.readdirSync(distDir);
  const patterns = [
    /^method-scopes-.*\.js$/,
    /^reply-.*\.js$/,
    /^pi-embedded-.*\.js$/,
    /^gateway-runtime-.*\.js$/,
  ];
  const selected = [];
  for (const pattern of patterns) {
    const matches = files.filter((name) => pattern.test(name)).sort().reverse();
    selected.push(...matches);
  }
  return [...new Set(selected)].map((name) => path.join(distDir, name));
}

async function loadGatewayClientClass(config) {
  if (gatewayClientClassPromise) {
    return gatewayClientClassPromise;
  }
  gatewayClientClassPromise = (async () => {
    const root = resolveOpenclawInstallRoot(config);
    const distDir = path.join(root, "dist");
    if (!fs.existsSync(distDir)) {
      throw new Error(`openclaw dist directory not found: ${distDir}`);
    }

    const bundles = listGatewayClientBundles(distDir);
    if (bundles.length === 0) {
      throw new Error(`no candidate bundles for GatewayClient under ${distDir}`);
    }

    const importErrors = [];
    for (const file of bundles) {
      try {
        const mod = await import(pathToFileURL(file).href);
        const GatewayClient = Object.values(mod).find(hasGatewayClientShape);
        if (GatewayClient) {
          return GatewayClient;
        }
      } catch (error) {
        importErrors.push(`${path.basename(file)}: ${String(error?.message ?? error)}`);
      }
    }

    const detail = [
      `searched bundles=${bundles.map((f) => path.basename(f)).join(",")}`,
      importErrors.length > 0 ? `import_errors=${importErrors.slice(0, 3).join(" | ")}` : "",
    ]
      .filter(Boolean)
      .join(" ; ");
    throw new Error(`GatewayClient export not found (${detail})`);
  })().catch((error) => {
    // allow retries after failed lazy load
    gatewayClientClassPromise = null;
    throw error;
  });

  return gatewayClientClassPromise;
}

function extractMessageText(message) {
  if (!message) {
    return "";
  }
  if (typeof message === "string") {
    return message;
  }
  const content = Array.isArray(message?.content) ? message.content : [];
  const lines = [];
  for (const item of content) {
    const text = typeof item?.text === "string" ? item.text : "";
    if (text) {
      lines.push(text);
    }
  }
  return lines.join("\n");
}

function computePatch(previous, current) {
  if (!current) {
    return { text: "", replace: false };
  }
  if (!previous) {
    return { text: current, replace: false };
  }
  if (current.startsWith(previous)) {
    return { text: current.slice(previous.length), replace: false };
  }
  return { text: current, replace: true };
}

function normalizeUsage(usage) {
  const input = Number(usage?.inputTokens ?? usage?.input ?? 0);
  const output = Number(usage?.outputTokens ?? usage?.output ?? 0);
  return {
    input_tokens: Number.isFinite(input) ? Math.max(0, input) : 0,
    output_tokens: Number.isFinite(output) ? Math.max(0, output) : 0,
  };
}

function buildSocketAuth(config) {
  // runtime gateway auth defaults to token mode; keep empty when caller did not configure it.
  const token = String(process.env.OPENCLAW_API_TOKEN || "").trim();
  if (token) {
    return { token };
  }
  return {};
}

function emitInvokeLog(logger, level, eventName, fields = {}) {
  const safeLevel = typeof logger?.[level] === "function" ? level : "info";
  logger[safeLevel](JSON.stringify({
    component: "miao-gateway-invoke",
    event: eventName,
    ...fields,
  }));
}

async function streamOpenclaw(config, requestId, prompt, timeoutMs, onDelta) {
  const GatewayClient = await loadGatewayClientClass(config);
  const sessionKey = config.openclawSessionKey || `agent:main:${config.channelId || "miao-chat"}`;
  const runId = requestId;
  const connectTimeoutMs = Math.min(15000, Math.max(3000, Math.floor(timeoutMs / 2)));
  const socketAuth = buildSocketAuth(config);

  return await new Promise((resolve, reject) => {
    let settled = false;
    let connected = false;
    let sent = false;
    let usage = { input_tokens: 0, output_tokens: 0 };
    let currentText = "";

    const settle = (error) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(overallTimer);
      clearTimeout(connectTimer);
      try {
        client.stop();
      } catch {
        // noop
      }
      if (error) {
        reject(error);
      } else {
        resolve(usage);
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
            sessionKey,
            message: prompt,
            timeoutMs,
            idempotencyKey: runId,
          });
        } catch (error) {
          settle(error instanceof Error ? error : new Error(String(error)));
        }
      },
      onEvent: (evt) => {
        if (settled || evt?.event !== "chat") {
          return;
        }
        const payload = evt?.payload ?? {};
        if (String(payload?.runId ?? "") !== runId) {
          return;
        }
        const state = String(payload?.state ?? "");
        if (state === "delta" || state === "final") {
          const text = extractMessageText(payload?.message);
          const patch = computePatch(currentText, text);
          if (patch.text) {
            currentText = text;
            onDelta(patch);
          } else if (text) {
            currentText = text;
          }
          if (state === "final") {
            usage = normalizeUsage(payload?.usage);
            settle();
          }
          return;
        }
        if (state === "error") {
          settle(new Error(String(payload?.errorMessage ?? "openclaw stream error")));
          return;
        }
        if (state === "aborted") {
          settle(new Error("openclaw run aborted"));
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
    }, connectTimeoutMs);

    const overallTimer = setTimeout(() => {
      settle(new Error("local openclaw timeout"));
    }, Math.max(5000, timeoutMs + 3000));

    client.start();
  });
}

export async function handleInvokeStart({ logger, wsSend, config, event }) {
  const payload = event.payload ?? {};
  const traceId = event.trace_id || "";
  const requestId = String(payload.request_id ?? "").trim();
  const turnId = String(payload.turn_id ?? "").trim();
  const assistantMessageId = String(payload.assistant_message_id ?? "").trim();
  const prompt = String(payload?.prompt?.content ?? "");
  const timeoutMs = Number(payload.timeout_ms ?? 120000);
  const effectiveTimeoutMs = Number.isFinite(timeoutMs)
    ? Math.max(5000, Math.min(timeoutMs, 240000))
    : 120000;
  const baseFields = {
    channel_id: config.channelId || "",
    request_id: requestId || "",
    turn_id: turnId || "",
    assistant_message_id: assistantMessageId || "",
    trace_id: traceId || "",
  };

  if (!requestId) {
    emitInvokeLog(logger, "warn", "invoke_invalid_request", {
      ...baseFields,
      reason: "missing_request_id",
    });
    return;
  }
  if (!prompt.trim()) {
    emitInvokeLog(logger, "warn", "invoke_invalid_request", {
      ...baseFields,
      reason: "empty_prompt",
    });
    wsSend({
      protocol_version: "channel.v0",
      msg_id: shortId(),
      event: "invoke.error",
      ts: new Date().toISOString(),
      trace_id: traceId,
      payload: {
        request_id: requestId,
        turn_id: turnId,
        assistant_message_id: assistantMessageId,
        code: "CHANNEL_OPENCLAW_ERROR",
        message: "empty prompt",
      },
    });
    return;
  }
  const maxConcurrent = Number.isFinite(config.maxConcurrentInvokes)
    ? Math.max(1, config.maxConcurrentInvokes)
    : 1;
  if (activeInvokeCount >= maxConcurrent) {
    emitInvokeLog(logger, "warn", "invoke_rejected_busy", {
      ...baseFields,
      active_invokes: activeInvokeCount,
      max_concurrent_invokes: maxConcurrent,
    });
    wsSend({
      protocol_version: "channel.v0",
      msg_id: shortId(),
      event: "invoke.error",
      ts: new Date().toISOString(),
      trace_id: traceId,
      payload: {
        request_id: requestId,
        turn_id: turnId,
        assistant_message_id: assistantMessageId,
        code: "CHANNEL_BUSY",
        message: "plugin is busy, retry later",
      },
    });
    return;
  }
  const startedAtMs = Date.now();
  activeInvokeIds.add(requestId);
  activeInvokeCount = activeInvokeIds.size;
  emitInvokeLog(logger, "info", "invoke_start", {
    ...baseFields,
    timeout_ms: effectiveTimeoutMs,
    active_invokes: activeInvokeCount,
    max_concurrent_invokes: maxConcurrent,
  });

  try {
    let seq = 0;
    const usage = await streamOpenclaw(config, requestId, prompt, effectiveTimeoutMs, (chunk) => {
      seq += 1;
      wsSend({
        protocol_version: "channel.v0",
        msg_id: shortId(),
        event: "invoke.chunk",
        ts: new Date().toISOString(),
        trace_id: traceId,
        payload: {
          request_id: requestId,
          turn_id: turnId,
          assistant_message_id: assistantMessageId,
          seq,
          delta: chunk.text,
          replace: chunk.replace === true,
          is_final: false,
        },
      });
    });

    wsSend({
      protocol_version: "channel.v0",
      msg_id: shortId(),
      event: "invoke.done",
      ts: new Date().toISOString(),
      trace_id: traceId,
      payload: {
        request_id: requestId,
        turn_id: turnId,
        assistant_message_id: assistantMessageId,
        last_seq: seq,
        usage,
      },
    });
    emitInvokeLog(logger, "info", "invoke_done", {
      ...baseFields,
      chunks: seq,
      duration_ms: Date.now() - startedAtMs,
      active_invokes: activeInvokeCount,
    });
  } catch (error) {
    const message = String(error?.message ?? "invoke failed");
    const lowerMessage = message.toLowerCase();
    const errorCode = lowerMessage.includes("timeout")
      ? "CHANNEL_OPENCLAW_TIMEOUT"
      : "CHANNEL_OPENCLAW_ERROR";
    emitInvokeLog(logger, "error", "invoke_error", {
      ...baseFields,
      code: errorCode,
      message,
      duration_ms: Date.now() - startedAtMs,
      active_invokes: activeInvokeCount,
    });
    wsSend({
      protocol_version: "channel.v0",
      msg_id: shortId(),
      event: "invoke.error",
      ts: new Date().toISOString(),
      trace_id: traceId,
      payload: {
        request_id: requestId,
        turn_id: turnId,
        assistant_message_id: assistantMessageId,
        code: errorCode,
        message,
      },
    });
  } finally {
    activeInvokeIds.delete(requestId);
    activeInvokeCount = activeInvokeIds.size;
  }
}
