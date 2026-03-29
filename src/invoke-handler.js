import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import http from "node:http";
import https from "node:https";

const LOCAL_ATTACHMENT_DIR = "/tmp/openclaw/input";

function shortId(prefix = "m") {
  return `${prefix}_${Math.random().toString(16).slice(2, 10)}${Date.now().toString(16).slice(-6)}`;
}

let gatewayClientClassPromise = null;
let activeInvokeCount = 0;
const activeInvokeIds = new Set();
const pendingInvokeQueue = [];
const MAX_PENDING_QUEUE_SIZE = 100;

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

export async function loadGatewayClientClass(config) {
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

export function extractMessageText(message) {
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

function normalizeAttachments(rawAttachments) {
  if (!Array.isArray(rawAttachments) || rawAttachments.length === 0) {
    return [];
  }
  const result = [];
  for (const item of rawAttachments) {
    const fileId = String(item?.file_id ?? item?.fileId ?? "").trim();
    if (!fileId) {
      continue;
    }
    result.push({
      file_id: fileId,
      name: String(item?.name ?? "").trim(),
      mime: String(item?.mime ?? "").trim(),
      size: Number(item?.size ?? 0) || 0,
      signed_url: String(item?.signed_url ?? item?.signedUrl ?? "").trim(),
    });
  }
  return result;
}

function summarizeSignedUrl(urlValue) {
  const raw = String(urlValue ?? "").trim();
  if (!raw) {
    return { present: false, error: "blank" };
  }
  try {
    const parsed = new URL(raw);
    const keys = [];
    parsed.searchParams.forEach((_, key) => {
      if (!keys.includes(key)) {
        keys.push(key);
      }
    });
    return {
      present: true,
      host: parsed.host || "",
      path: parsed.pathname || "",
      has_q_sign: keys.some((key) => key.toLowerCase().startsWith("q-sign-")),
      query_keys: keys.slice(0, 8),
    };
  } catch (error) {
    return {
      present: true,
      error: String(error?.message ?? error),
    };
  }
}

function isInlineReadableAttachment(item) {
  const mime = String(item?.mime ?? "").toLowerCase();
  return mime === "text/plain" || mime === "text/markdown" || mime === "text/x-markdown";
}

function isImageAttachment(item) {
  const mime = String(item?.mime ?? "").toLowerCase();
  return mime.startsWith("image/");
}

function ensureLocalAttachmentDir() {
  fs.mkdirSync(LOCAL_ATTACHMENT_DIR, { recursive: true });
}

function sanitizeAttachmentFilename(name, fallbackBase = "attachment") {
  const raw = String(name ?? "").trim();
  const baseName = raw ? path.basename(raw) : fallbackBase;
  const sanitized = baseName
    .replace(/[^a-zA-Z0-9._-]/g, "_")
    .replace(/_+/g, "_")
    .replace(/^_+|_+$/g, "");
  return sanitized || fallbackBase;
}

function buildLocalAttachmentPath(item) {
  const safeName = sanitizeAttachmentFilename(item?.name, `${item?.file_id || "attachment"}`);
  const prefix = String(item?.file_id || shortId("att")).replace(/[^a-zA-Z0-9_-]/g, "");
  ensureLocalAttachmentDir();
  return path.join(LOCAL_ATTACHMENT_DIR, `${prefix}_${safeName}`);
}

function writeLocalAttachmentFile(targetPath, buffer) {
  fs.writeFileSync(targetPath, buffer);
  return targetPath;
}

function downloadBuffer(url, timeoutMs) {
  return new Promise((resolve, reject) => {
    if (!url) {
      resolve({ buffer: Buffer.alloc(0), contentType: "" });
      return;
    }
    const target = new URL(url);
    const client = target.protocol === "https:" ? https : http;
    const request = client.get(target, { timeout: timeoutMs }, (response) => {
      if (response.statusCode && response.statusCode >= 400) {
        reject(new Error(`download failed: http ${response.statusCode}`));
        response.resume();
        return;
      }
      const chunks = [];
      response.on("data", (chunk) => {
        chunks.push(chunk);
      });
      response.on("end", () => {
        resolve({
          buffer: Buffer.concat(chunks),
          contentType: String(response.headers["content-type"] ?? "").trim(),
        });
      });
    });
    request.on("timeout", () => {
      request.destroy(new Error("download timeout"));
    });
    request.on("error", reject);
  });
}

async function downloadText(url, timeoutMs) {
  const { buffer } = await downloadBuffer(url, timeoutMs);
  return buffer.toString("utf8");
}

function normalizeImageMime(preferredMime, responseMime) {
  const responseValue = String(responseMime ?? "").split(";")[0].trim().toLowerCase();
  if (responseValue.startsWith("image/")) {
    return responseValue;
  }
  const preferredValue = String(preferredMime ?? "").split(";")[0].trim().toLowerCase();
  if (preferredValue.startsWith("image/")) {
    return preferredValue;
  }
  return "";
}

async function buildOpenclawPayload(prompt, attachments, timeoutMs) {
  if (!attachments || attachments.length === 0) {
    return {
      message: prompt,
      chatAttachments: [],
    };
  }
  const attachmentPreviews = [];
  const chatAttachments = [];
  const attachmentWarnings = [];
  const localAttachments = [];
  for (const item of attachments) {
    if (!item?.signed_url) {
      continue;
    }
    if (isInlineReadableAttachment(item)) {
      try {
        const { buffer } = await downloadBuffer(item.signed_url, Math.min(15000, timeoutMs));
        const text = buffer.toString("utf8");
        const preview = text.trim().slice(0, 12000);
        const localPath = writeLocalAttachmentFile(buildLocalAttachmentPath(item), buffer);
        if (preview) {
          attachmentPreviews.push({
            file_id: item.file_id,
            name: item.name,
            content_preview: preview,
          });
        }
        localAttachments.push({
          file_id: item.file_id,
          name: item.name,
          mime: item.mime,
          local_path: localPath,
          source: "downloaded",
        });
      } catch {
        attachmentWarnings.push({
          file_id: item.file_id,
          name: item.name,
          reason: "text_preview_fetch_failed",
        });
      }
      continue;
    }
    if (!isImageAttachment(item)) {
      try {
        const { buffer } = await downloadBuffer(item.signed_url, Math.min(20000, timeoutMs));
        if (!buffer || buffer.length === 0) {
          attachmentWarnings.push({
            file_id: item.file_id,
            name: item.name,
            reason: "file_empty",
          });
          continue;
        }
        const localPath = writeLocalAttachmentFile(buildLocalAttachmentPath(item), buffer);
        localAttachments.push({
          file_id: item.file_id,
          name: item.name,
          mime: item.mime,
          local_path: localPath,
          source: "downloaded",
          size: buffer.length,
        });
      } catch {
        attachmentWarnings.push({
          file_id: item.file_id,
          name: item.name,
          reason: "file_download_failed",
        });
      }
      continue;
    }
    try {
      const { buffer, contentType } = await downloadBuffer(item.signed_url, Math.min(20000, timeoutMs));
      if (!buffer || buffer.length === 0) {
        attachmentWarnings.push({
          file_id: item.file_id,
          name: item.name,
          reason: "image_empty",
        });
        continue;
      }
      if (buffer.length > 5_000_000) {
        attachmentWarnings.push({
          file_id: item.file_id,
          name: item.name,
          reason: "image_too_large",
          size: buffer.length,
        });
        continue;
      }
      const mimeType = normalizeImageMime(item.mime, contentType);
      if (!mimeType) {
        attachmentWarnings.push({
          file_id: item.file_id,
          name: item.name,
          reason: "image_mime_invalid",
          mime: item.mime,
          content_type: contentType,
        });
        continue;
      }
      chatAttachments.push({
        type: "image",
        mimeType,
        fileName: item.name || `${item.file_id || "image"}.${mimeType.split("/")[1] || "bin"}`,
        content: buffer.toString("base64"),
      });
      const localPath = writeLocalAttachmentFile(buildLocalAttachmentPath(item), buffer);
      localAttachments.push({
        file_id: item.file_id,
        name: item.name,
        mime: mimeType,
        local_path: localPath,
        source: "downloaded",
        size: buffer.length,
      });
    } catch {
      attachmentWarnings.push({
        file_id: item.file_id,
        name: item.name,
        reason: "image_fetch_failed",
      });
    }
  }
  const context = {
    attachments: attachments.map((item) => ({
      file_id: item.file_id,
      name: item.name,
      mime: item.mime,
      size: item.size,
      signed_url: item.signed_url,
    })),
    attachment_previews: attachmentPreviews,
    attachment_local_files: localAttachments,
    attachment_warnings: attachmentWarnings,
  };
  return {
    message: `${prompt}\n\n[INPUT_ATTACHMENTS]\n${JSON.stringify(context, null, 2)}`,
    chatAttachments,
  };
}

function buildEffectivePrompt(prompt, attachments) {
  const trimmedPrompt = String(prompt ?? "").trim();
  if (trimmedPrompt) {
    return trimmedPrompt;
  }
  if (Array.isArray(attachments) && attachments.length > 0) {
    const names = attachments
      .map((item) => String(item?.name ?? "").trim())
      .filter(Boolean)
      .slice(0, 3);
    const summary = names.length > 0 ? `，附件包括：${names.join("、")}` : "";
    return `用户发送了 ${attachments.length} 个附件${summary}。请优先读取附件内容后再回答；如果附件暂时不可访问，请明确说明原因。`;
  }
  return "";
}

export function buildSocketAuth(config) {
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

function logAttachmentUrlSummary(logger, baseFields, attachments) {
  if (!Array.isArray(attachments) || attachments.length === 0) {
    return;
  }
  attachments.forEach((item, index) => {
    emitInvokeLog(logger, "info", "invoke_attachment_url", {
      ...baseFields,
      attachment_index: index,
      file_id: String(item?.file_id ?? ""),
      name: String(item?.name ?? ""),
      mime: String(item?.mime ?? ""),
      signed_url: summarizeSignedUrl(item?.signed_url),
    });
  });
}

function resolveMaxConcurrent(config) {
  if (!Number.isFinite(config?.maxConcurrentInvokes)) {
    return 1;
  }
  return Math.max(1, Math.round(config.maxConcurrentInvokes));
}

function resolveQueueWaitTimeoutMs(config) {
  if (!Number.isFinite(config?.queueWaitTimeoutMs)) {
    return 60000;
  }
  const ms = Math.round(config.queueWaitTimeoutMs);
  return Math.min(600000, Math.max(1000, ms));
}

function hasPendingRequest(requestId) {
  if (!requestId) {
    return false;
  }
  if (activeInvokeIds.has(requestId)) {
    return true;
  }
  return pendingInvokeQueue.some((task) => task.requestId === requestId);
}

async function streamOpenclaw(config, requestId, prompt, attachments, timeoutMs, onDelta) {
  const GatewayClient = await loadGatewayClientClass(config);
  const sessionKey = String(config.openclawSessionKey ?? "").trim();
  const runId = requestId;
  const connectTimeoutMs = Math.min(15000, Math.max(3000, Math.floor(timeoutMs / 2)));
  const socketAuth = buildSocketAuth(config);

  const openclawPayload = await buildOpenclawPayload(prompt, attachments, timeoutMs);

  return await new Promise((resolve, reject) => {
    let settled = false;
    let connected = false;
    let sent = false;
    let usage = { input_tokens: 0, output_tokens: 0 };
    let currentText = "";
    let acceptedRunId = "";

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
            ...(sessionKey ? { sessionKey } : {}),
            message: openclawPayload.message,
            ...(openclawPayload.chatAttachments.length > 0
              ? { attachments: openclawPayload.chatAttachments }
              : {}),
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
        const state = String(payload?.state ?? "");
        if (state === "delta" || state === "final") {
          const text = extractMessageText(payload?.message)
            || String(payload?.text ?? payload?.content ?? "");
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
          // Treat remote abort as graceful completion so upstream can render
          // existing partial text instead of hard-failing the whole turn.
          usage = normalizeUsage(payload?.usage);
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
    }, connectTimeoutMs);

    const overallTimer = setTimeout(() => {
      settle(new Error("local openclaw timeout"));
    }, Math.max(5000, timeoutMs + 3000));

    client.start();
  });
}

async function runInvokeTask(task) {
  const {
    logger,
    wsSend,
    config,
    traceId,
    requestId,
    turnId,
    assistantMessageId,
    attachments,
    effectivePrompt,
    effectiveTimeoutMs,
    baseFields,
    queuedAtMs,
  } = task;
  const maxConcurrent = resolveMaxConcurrent(config);
  const startedAtMs = Date.now();
  if (task.queueTimer) {
    clearTimeout(task.queueTimer);
  }
  activeInvokeIds.add(requestId);
  activeInvokeCount = activeInvokeIds.size;

  emitInvokeLog(logger, "info", "invoke_start", {
    ...baseFields,
    timeout_ms: effectiveTimeoutMs,
    attachment_count: attachments.length,
    active_invokes: activeInvokeCount,
    max_concurrent_invokes: maxConcurrent,
    queue_wait_ms: Math.max(0, startedAtMs - queuedAtMs),
    queue_size: pendingInvokeQueue.length,
  });
  logAttachmentUrlSummary(logger, baseFields, attachments);

  try {
    let seq = 0;
    const usage = await streamOpenclaw(config, requestId, effectivePrompt, attachments, effectiveTimeoutMs, (chunk) => {
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
      queue_size: pendingInvokeQueue.length,
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
      queue_size: pendingInvokeQueue.length,
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
    drainInvokeQueue();
  }
}

function drainInvokeQueue() {
  if (pendingInvokeQueue.length === 0) {
    return;
  }
  while (pendingInvokeQueue.length > 0) {
    const nextTask = pendingInvokeQueue[0];
    const nextMaxConcurrent = resolveMaxConcurrent(nextTask.config);
    if (activeInvokeCount >= nextMaxConcurrent) {
      break;
    }
    pendingInvokeQueue.shift();
    void runInvokeTask(nextTask);
  }
}

export async function handleInvokeStart({ logger, wsSend, config, event }) {
  const payload = event.payload ?? {};
  const traceId = event.trace_id || "";
  const requestId = String(payload.request_id ?? "").trim();
  const turnId = String(payload.turn_id ?? "").trim();
  const assistantMessageId = String(payload.assistant_message_id ?? "").trim();
  const prompt = String(payload?.prompt?.content ?? "");
  const attachments = normalizeAttachments(payload?.attachments);
  const effectivePrompt = buildEffectivePrompt(prompt, attachments);
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
  if (!effectivePrompt) {
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
  if (hasPendingRequest(requestId)) {
    emitInvokeLog(logger, "warn", "invoke_duplicate_request", {
      ...baseFields,
      queue_size: pendingInvokeQueue.length,
      active_invokes: activeInvokeCount,
    });
    return;
  }

  if (pendingInvokeQueue.length >= MAX_PENDING_QUEUE_SIZE) {
    emitInvokeLog(logger, "warn", "invoke_rejected_queue_full", {
      ...baseFields,
      queue_size: pendingInvokeQueue.length,
      active_invokes: activeInvokeCount,
      queue_limit: MAX_PENDING_QUEUE_SIZE,
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
        code: "CHANNEL_QUEUE_FULL",
        message: "plugin queue is full, retry later",
      },
    });
    return;
  }

  const task = {
    logger,
    wsSend,
    config,
    traceId,
    requestId,
    turnId,
    assistantMessageId,
    attachments,
    effectivePrompt,
    effectiveTimeoutMs,
    baseFields,
    queuedAtMs: Date.now(),
  };
  pendingInvokeQueue.push(task);
  const queueWaitTimeoutMs = resolveQueueWaitTimeoutMs(config);
  task.queueTimer = setTimeout(() => {
    const idx = pendingInvokeQueue.indexOf(task);
    if (idx < 0) {
      return;
    }
    pendingInvokeQueue.splice(idx, 1);
    emitInvokeLog(logger, "warn", "invoke_queue_timeout", {
      ...baseFields,
      queue_wait_timeout_ms: queueWaitTimeoutMs,
      queue_size: pendingInvokeQueue.length,
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
        code: "CHANNEL_QUEUE_TIMEOUT",
        message: `plugin queue wait timeout (${queueWaitTimeoutMs}ms)`,
      },
    });
    drainInvokeQueue();
  }, queueWaitTimeoutMs);

  emitInvokeLog(logger, "info", "invoke_queued", {
    ...baseFields,
    queue_size: pendingInvokeQueue.length,
    active_invokes: activeInvokeCount,
    max_concurrent_invokes: resolveMaxConcurrent(config),
    queue_wait_timeout_ms: queueWaitTimeoutMs,
    timeout_ms: effectiveTimeoutMs,
  });
  drainInvokeQueue();
}
