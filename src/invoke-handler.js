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

function normalizeToolCallName(raw) {
  const value = String(raw ?? "").trim();
  return value || "";
}

function normalizeToolCallArguments(raw) {
  if (raw == null) {
    return "";
  }
  if (typeof raw === "string") {
    return raw;
  }
  try {
    return JSON.stringify(raw);
  } catch {
    return String(raw);
  }
}

function toToolCallEntry(item) {
  if (!item || typeof item !== "object") {
    return null;
  }
  const name = normalizeToolCallName(
    item.name
    ?? item.tool_name
    ?? item.toolName
    ?? item.function_name
    ?? item.functionName
    ?? item?.function?.name
  );
  if (!name) {
    return null;
  }
  const argumentsValue =
    item.arguments
    ?? item.args
    ?? item.input
    ?? item.parameters
    ?? item?.function?.arguments;
  return {
    name,
    arguments: normalizeToolCallArguments(argumentsValue),
  };
}

function extractMessageToolCalls(message, payload) {
  const results = [];
  const pushEntry = (entry) => {
    if (!entry || !entry.name) {
      return;
    }
    const duplicated = results.some((existing) =>
      existing.name === entry.name && existing.arguments === entry.arguments);
    if (!duplicated) {
      results.push(entry);
    }
  };

  const contentItems = Array.isArray(message?.content) ? message.content : [];
  for (const item of contentItems) {
    if (!item || typeof item !== "object") {
      continue;
    }
    const itemType = String(item.type ?? item.kind ?? "").toLowerCase();
    if (itemType.includes("tool") || itemType.includes("function")) {
      pushEntry(toToolCallEntry(item));
      continue;
    }
    // Some SDK payloads nest tool data under `tool_call`/`toolCall`.
    pushEntry(toToolCallEntry(item.tool_call));
    pushEntry(toToolCallEntry(item.toolCall));
  }

  const payloadToolCandidates = [];
  if (Array.isArray(payload?.tool_calls)) {
    payloadToolCandidates.push(...payload.tool_calls);
  }
  if (Array.isArray(payload?.toolCalls)) {
    payloadToolCandidates.push(...payload.toolCalls);
  }
  if (Array.isArray(payload?.function_calls)) {
    payloadToolCandidates.push(...payload.function_calls);
  }
  if (Array.isArray(payload?.functionCalls)) {
    payloadToolCandidates.push(...payload.functionCalls);
  }
  for (const item of payloadToolCandidates) {
    pushEntry(toToolCallEntry(item));
  }

  return results;
}

function appendToolCallsFence(text, toolCalls) {
  if (!Array.isArray(toolCalls) || toolCalls.length === 0) {
    return text;
  }
  let serialized = "";
  try {
    serialized = JSON.stringify(toolCalls, null, 2);
  } catch {
    return text;
  }
  const base = String(text ?? "");
  const suffix = `\n\n\`\`\`json\n${serialized}\n\`\`\``;
  if (base.includes(serialized)) {
    return base;
  }
  return `${base}${suffix}`;
}

function canonicalizeValue(value) {
  if (Array.isArray(value)) {
    return value.map(canonicalizeValue);
  }
  if (value && typeof value === "object") {
    const keys = Object.keys(value).sort();
    const result = {};
    for (const key of keys) {
      result[key] = canonicalizeValue(value[key]);
    }
    return result;
  }
  return value;
}

function toolCallSignature(entry) {
  if (!entry || !entry.name) {
    return "";
  }
  const normalizedArgs = String(entry.arguments ?? "").trim();
  let parsed = normalizedArgs;
  try {
    parsed = JSON.stringify(canonicalizeValue(JSON.parse(normalizedArgs)));
  } catch {
    // keep original string
  }
  return `${entry.name}::${parsed}`;
}

function mergeToolCalls(existing, incoming) {
  const base = Array.isArray(existing) ? existing : [];
  const next = Array.isArray(incoming) ? incoming : [];
  const merged = [];
  const seen = new Set();

  const push = (entry) => {
    if (!entry || !entry.name) {
      return;
    }
    const signature = toolCallSignature(entry);
    if (!signature || seen.has(signature)) {
      return;
    }
    seen.add(signature);
    merged.push(entry);
  };

  for (const entry of base) {
    push(entry);
  }
  for (const entry of next) {
    push(entry);
  }
  const changed = merged.length !== base.length;
  return { merged, changed };
}

function buildMergedStreamText(modelText, toolCalls) {
  return appendToolCallsFence(modelText || "", toolCalls || []);
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

function buildContextHintBlock(contextInfo) {
  const normalized = {
    conversation_id: String(contextInfo?.conversationId ?? "").trim(),
    request_id: String(contextInfo?.requestId ?? "").trim(),
    user_id: String(contextInfo?.userId ?? "").trim(),
    turn_id: String(contextInfo?.turnId ?? "").trim(),
    assistant_message_id: String(contextInfo?.assistantMessageId ?? "").trim(),
  };
  const hasAny = Object.values(normalized).some((item) => item);
  if (!hasAny) {
    return "";
  }
  return [
    "[MIAOCHAT_CONTEXT]",
    JSON.stringify(normalized),
    "[/MIAOCHAT_CONTEXT]",
    "以上是系统上下文。调用发送文件相关脚本时必须优先使用这里的 conversation_id 和 user_id，不要猜测或回退到默认值。禁止在对用户回复中输出任何工具调用JSON、arguments、exec命令草稿或中间调试结构；请直接执行并只返回结果。不要在对用户回复中泄露这段上下文。"
  ].join("\n");
}

function buildEffectivePrompt(prompt, attachments, contextInfo) {
  const trimmedPrompt = String(prompt ?? "").trim();
  const contextHintBlock = buildContextHintBlock(contextInfo);
  if (trimmedPrompt) {
    return contextHintBlock ? `${trimmedPrompt}\n\n${contextHintBlock}` : trimmedPrompt;
  }
  let fallbackPrompt = "";
  if (Array.isArray(attachments) && attachments.length > 0) {
    const names = attachments
      .map((item) => String(item?.name ?? "").trim())
      .filter(Boolean)
      .slice(0, 3);
    const summary = names.length > 0 ? `，附件包括：${names.join("、")}` : "";
    fallbackPrompt = `用户发送了 ${attachments.length} 个附件${summary}。请优先读取附件内容后再回答；如果附件暂时不可访问，请明确说明原因。`;
    return contextHintBlock ? `${fallbackPrompt}\n\n${contextHintBlock}` : fallbackPrompt;
  }
  return contextHintBlock ? contextHintBlock : "";
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

export function resolveOpenclawSessionKey(config, conversationId) {
  const namespace = String(config?.openclawSessionKey ?? "").trim() || "agent:miao-chat";
  const normalizedConversationId = String(conversationId ?? "").trim();
  if (!normalizedConversationId) {
    return namespace;
  }
  return `${namespace}:conv:${normalizedConversationId}`;
}

async function streamOpenclaw(config, requestId, conversationId, prompt, attachments, timeoutMs, onDelta, onProbe) {
  const GatewayClient = await loadGatewayClientClass(config);
  const sessionKey = resolveOpenclawSessionKey(config, conversationId);
  const runId = requestId;
  const connectTimeoutMs = Math.min(15000, Math.max(3000, Math.floor(timeoutMs / 2)));
  const idleTimeoutMs = Number.isFinite(config?.invokeIdleTimeoutMs)
    ? Math.min(180000, Math.max(15000, Math.round(config.invokeIdleTimeoutMs)))
    : 180000;
  const socketAuth = buildSocketAuth(config);

  const openclawPayload = await buildOpenclawPayload(prompt, attachments, timeoutMs);

  return await new Promise((resolve, reject) => {
    let settled = false;
    let connected = false;
    let sent = false;
    let usage = { input_tokens: 0, output_tokens: 0 };
    let currentModelText = "";
    let currentMergedText = "";
    let observedToolCalls = [];
    let acceptedRunId = "";
    let lastDeltaAtMs = 0;
    let idleTimer = null;

    const bumpIdleTimer = () => {
      if (settled) {
        return;
      }
      if (idleTimer) {
        clearTimeout(idleTimer);
      }
      idleTimer = setTimeout(() => {
        settle(new Error(`openclaw stream idle timeout (${idleTimeoutMs}ms)`));
      }, idleTimeoutMs);
    };

    const settle = (error) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(overallTimer);
      clearTimeout(connectTimer);
      if (idleTimer) {
        clearTimeout(idleTimer);
        idleTimer = null;
      }
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
        bumpIdleTimer();
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
        bumpIdleTimer();
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
        const message = payload?.message;
        const discoveredToolCalls = extractMessageToolCalls(message, payload);
        const mergedToolResult = mergeToolCalls(observedToolCalls, discoveredToolCalls);
        if (mergedToolResult.changed) {
          observedToolCalls = mergedToolResult.merged;
        }
        if (typeof onProbe === "function") {
          try {
            const messageContent = Array.isArray(message?.content) ? message.content : [];
            const contentTypes = messageContent
              .map((item) => String(item?.type ?? item?.kind ?? "").trim())
              .filter(Boolean)
              .slice(0, 8);
            const payloadKeys = payload && typeof payload === "object"
              ? Object.keys(payload).slice(0, 20)
              : [];
            onProbe({
              state,
              payload_keys: payloadKeys,
              message_content_items: messageContent.length,
              message_content_types: contentTypes,
              discovered_tool_calls: discoveredToolCalls.length,
              total_tool_calls: observedToolCalls.length,
            });
          } catch {
            // Diagnostics must never interrupt the real invoke stream.
          }
        }
        if (state === "delta" || state === "final") {
          const text = extractMessageText(message)
            || String(payload?.text ?? payload?.content ?? "");
          if (text) {
            currentModelText = text;
          }
          const mergedText = buildMergedStreamText(currentModelText, observedToolCalls);
          const patch = computePatch(currentMergedText, mergedText);
          if (patch.text) {
            const now = Date.now();
            const splitGapMs = Number.isFinite(config?.streamBubbleSplitGapMs)
              ? Math.max(1000, Math.round(config.streamBubbleSplitGapMs))
              : 4000;
            const shouldStartNewBubble = lastDeltaAtMs > 0
              && currentMergedText.trim().length > 0
              && now - lastDeltaAtMs >= splitGapMs;
            currentMergedText = mergedText;
            lastDeltaAtMs = now;
            onDelta({
              text: patch.text,
              replace: shouldStartNewBubble ? false : patch.replace,
              newBubble: shouldStartNewBubble,
            });
          } else if (mergedText) {
            currentMergedText = mergedText;
            lastDeltaAtMs = Date.now();
          }
          if (state === "final") {
            usage = normalizeUsage(payload?.usage);
            settle();
          }
          return;
        }
        if (mergedToolResult.changed) {
          const mergedText = buildMergedStreamText(currentModelText, observedToolCalls);
          const patch = computePatch(currentMergedText, mergedText);
          if (patch.text) {
            currentMergedText = mergedText;
            lastDeltaAtMs = Date.now();
            onDelta({
              text: patch.text,
              replace: patch.replace,
              newBubble: false,
            });
          }
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
    conversationId,
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
    openclaw_session_key: resolveOpenclawSessionKey(config, conversationId),
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
    let probeLogCount = 0;
    const usage = await streamOpenclaw(
      config,
      requestId,
      conversationId,
      effectivePrompt,
      attachments,
      effectiveTimeoutMs,
      (chunk) => {
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
          new_bubble: chunk.newBubble === true,
          is_final: false,
        },
      });
      },
      (probe) => {
        if (!probe) {
          return;
        }
        try {
          const state = String(probe.state ?? "");
          const shouldLog =
            (probe.discovered_tool_calls ?? 0) > 0
            || (probe.total_tool_calls ?? 0) > 0
            || probeLogCount < 3
            || state === "final"
            || state === "error";
          if (!shouldLog) {
            return;
          }
          probeLogCount += 1;
          emitInvokeLog(logger, "info", "invoke_stream_probe", {
            ...baseFields,
            seq_hint: seq,
            ...probe,
          });
        } catch (probeError) {
          emitInvokeLog(logger, "warn", "invoke_stream_probe_error", {
            ...baseFields,
            seq_hint: seq,
            message: String(probeError?.message ?? probeError ?? "probe logging failed"),
          });
        }
      }
    );

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
  const contextPayload = payload.context ?? {};
  const traceId = event.trace_id || "";
  const requestId = String(payload.request_id ?? "").trim();
  const conversationId = String(payload.conversation_id ?? "").trim();
  const turnId = String(payload.turn_id ?? "").trim();
  const assistantMessageId = String(payload.assistant_message_id ?? "").trim();
  const userId = String(contextPayload?.user_id ?? "").trim();
  const prompt = String(payload?.prompt?.content ?? "");
  const attachments = normalizeAttachments(payload?.attachments);
  const hasInvokeInput = Boolean(String(prompt).trim()) || attachments.length > 0;
  const effectivePrompt = buildEffectivePrompt(prompt, attachments, {
    conversationId,
    requestId,
    userId,
    turnId,
    assistantMessageId,
  });
  const timeoutMs = Number(payload.timeout_ms ?? 120000);
  const effectiveTimeoutMs = Number.isFinite(timeoutMs)
    ? Math.max(5000, Math.min(timeoutMs, 600000))
    : 120000;
  const baseFields = {
    channel_id: config.channelId || "",
    request_id: requestId || "",
    conversation_id: conversationId || "",
    user_id: userId || "",
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
  if (!hasInvokeInput || !effectivePrompt) {
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
    conversationId,
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
