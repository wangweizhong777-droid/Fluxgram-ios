const fs = require("node:fs");
const fsPromises = require("node:fs/promises");
const path = require("node:path");
const crypto = require("node:crypto");
const http = require("node:http");

const { Api, TelegramClient } = require("telegram");
const { StringSession } = require("telegram/sessions");
const { NewMessage } = require("telegram/events");

const POLL_INTERVAL_MS = 10_000;
const REALTIME_GRACE_MS = 60_000;
const MAX_SEEN_MESSAGES = 4_000;
const DEFAULT_SEEN_MESSAGES_PATH = "/data/seen-messages.json";
const DEFAULT_PENDING_NOTIFICATIONS_PATH = "/data/pending-notifications.json";
const DEFAULT_NOTIFICATION_SETTINGS_PATH = "/data/notification-settings.json";
const DEFAULT_NOTIFICATION_RETRY_DELAY_MS = 30_000;
const DEFAULT_AVATAR_RETENTION_MS = 30 * 24 * 60 * 60 * 1_000;

const listenerState = {
  enabled: true,
  connected: false,
  pollingSeeded: false,
  lastTelegramSyncAt: null,
  lastRealtimeUpdateAt: null,
  lastBarkSuccessAt: null,
  lastBarkFailureAt: null,
  watchdogAlerted: false,
  counters: {
    polls: 0,
    realtimeMessages: 0,
    pollingMessages: 0,
    mutedSkipped: 0,
    barkSuccess: 0,
    barkFailure: 0,
  },
};

const notificationControl = {
  setEnabled: null,
};

function notificationSettingsPath() {
  return (process.env.NOTIFY_SETTINGS_PATH || DEFAULT_NOTIFICATION_SETTINGS_PATH).trim();
}

function loadNotificationEnabled() {
  try {
    const value = JSON.parse(fs.readFileSync(notificationSettingsPath(), "utf8"));
    return value?.enabled !== false;
  } catch (error) {
    if (error.code !== "ENOENT") {
      console.warn(`Notification settings could not be loaded: ${error.constructor.name}`);
    }
    return true;
  }
}

async function persistNotificationEnabled(enabled) {
  const filePath = notificationSettingsPath();
  await fsPromises.mkdir(path.dirname(filePath), { recursive: true });
  const temporaryPath = `${filePath}.tmp`;
  await fsPromises.writeFile(
    temporaryPath,
    JSON.stringify({ enabled, updatedAt: new Date().toISOString() }),
    { encoding: "utf8", mode: 0o600 },
  );
  await fsPromises.rename(temporaryPath, filePath);
}

function required(name) {
  const value = (process.env[name] || "").trim();
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function sessionText(path) {
  try {
    return fs.readFileSync(path, "utf8").trim();
  } catch (error) {
    if (error.code === "ENOENT") {
      return "";
    }
    throw error;
  }
}

function connectionOptions() {
  const options = { connectionRetries: 5 };
  const host = (process.env.TELEGRAM_PROXY_HOST || "").trim();
  const port = Number(process.env.TELEGRAM_PROXY_PORT || 0);
  if (host && port > 0) {
    options.proxy = {
      ip: host,
      port,
      socksType: Number(process.env.TELEGRAM_PROXY_TYPE || 5),
    };
  }
  return options;
}

function displayName(entity) {
  const personName = [entity?.firstName, entity?.lastName]
    .filter((part) => typeof part === "string" && part.trim())
    .join(" ");
  const name = entity?.title || personName || entity?.username;
  return typeof name === "string"
    ? name.replace(/\s+/g, " ").trim().slice(0, 80)
    : "";
}

function messagePreview(message) {
  const text = (message.message || "").trim().replace(/\s+/g, " ");
  if (text) {
    return text.slice(0, 180);
  }

  const kind = message.media?.className;
  if (kind === "MessageMediaPhoto") return "[图片]";
  if (kind === "MessageMediaDocument") return "[文件]";
  return "[新消息]";
}

function messageUrl(chat, message) {
  if (chat?.username) {
    return `tg://resolve?domain=${encodeURIComponent(chat.username)}&post=${message.id}`;
  }
  if (chat?.className === "User") {
    return `tg://openmessage?user_id=${chat.id}&message_id=${message.id}`;
  }
  if (chat?.className === "Channel") {
    return `tg://privatepost?channel=${chat.id}&post=${message.id}`;
  }
  if (chat?.id) {
    return `tg://openmessage?chat_id=${chat.id}&message_id=${message.id}`;
  }
  return "tg://";
}

const muteCache = new Map();
const avatarCache = new Map();

async function cleanupAvatarFiles(directory) {
  const retention = Number(process.env.BARK_AVATAR_RETENTION_MS || DEFAULT_AVATAR_RETENTION_MS);
  if (!Number.isFinite(retention) || retention < 60_000) return;
  try {
    const entries = await fsPromises.readdir(directory, { withFileTypes: true });
    const cutoff = Date.now() - retention;
    await Promise.all(entries
      .filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith(".jpg"))
      .map(async (entry) => {
        const filePath = path.join(directory, entry.name);
        const stats = await fsPromises.stat(filePath);
        if (stats.mtimeMs < cutoff) {
          await fsPromises.unlink(filePath);
        }
      }));
  } catch (error) {
    if (error.code !== "ENOENT") {
      console.warn(`Avatar cleanup failed: ${error.constructor.name}`);
    }
  }
}

async function avatarUrl(client, event, chat) {
  const baseUrl = (process.env.BARK_PUBLIC_BASE_URL || "").replace(/\/$/, "");
  const directory = process.env.BARK_AVATAR_DIR;
  if (!baseUrl || !directory) return process.env.BARK_ICON_URL;
  const key = String(event.chatId);
  if (avatarCache.has(key)) return avatarCache.get(key);
  try {
    const image = await client.downloadProfilePhoto(chat);
    if (!Buffer.isBuffer(image)) return process.env.BARK_ICON_URL;
    await fsPromises.mkdir(directory, { recursive: true });
    void cleanupAvatarFiles(directory);
    const file = `${crypto.randomUUID()}.jpg`;
    await fsPromises.writeFile(path.join(directory, file), image, { mode: 0o644 });
    const url = `${baseUrl}/notify-avatars/${file}`;
    avatarCache.set(key, url);
    return url;
  } catch (error) {
    return process.env.BARK_ICON_URL;
  }
}

async function isMuted(client, chatId) {
  const cacheKey = String(chatId);
  const now = Math.floor(Date.now() / 1000);
  const cached = muteCache.get(cacheKey);
  if (cached && cached.expiresAt > now) {
    return cached.muted;
  }

  const inputPeer = await client.getInputEntity(chatId);
  const settings = await client.invoke(new Api.account.GetNotifySettings({
    peer: new Api.InputNotifyPeer({ peer: inputPeer }),
  }));
  const muteUntil = Number(settings.muteUntil || 0);
  const muted = muteUntil > now;

  muteCache.set(cacheKey, { muted, expiresAt: now + 60 });
  return muted;
}

async function sendBark(title, body, icon, url) {
  const payload = {
    device_key: required("BARK_DEVICE_TOKEN"),
    title,
    body: process.env.MESSAGE_PREVIEW === "false" ? "Fluxgram 收到一条新消息" : body,
    group: "fluxgram",
    level: process.env.BARK_LEVEL || "active",
    url: url || "tg://",
  };
  if (icon || process.env.BARK_ICON_URL) {
    payload.icon = icon || process.env.BARK_ICON_URL;
  }

  let failure = "未知错误";
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const response = await fetch(`${(process.env.BARK_SERVER || "https://api.day.app").replace(/\/$/, "")}/push`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(10_000),
      });
      if (response.ok) {
        listenerState.lastBarkSuccessAt = new Date().toISOString();
        listenerState.counters.barkSuccess += 1;
        return true;
      }
      failure = `HTTP ${response.status}`;
      // A client error is deterministic; retrying it would only duplicate a
      // bad request. Retry one transient server failure instead.
      if (response.status < 500 || attempt === 1) break;
    } catch (error) {
      failure = error.constructor.name;
      if (attempt === 1) break;
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  listenerState.lastBarkFailureAt = new Date().toISOString();
  listenerState.counters.barkFailure += 1;
  console.warn(`Bark delivery failed: ${failure}`);
  return false;
}

function startWatchdog() {
  const interval = Number(process.env.NOTIFY_WATCHDOG_INTERVAL_MS || 30_000);
  const grace = Number(process.env.NOTIFY_WATCHDOG_GRACE_MS || 120_000);
  if (!Number.isFinite(interval) || interval < 10_000 || !Number.isFinite(grace) || grace < interval) {
    console.warn("Notification watchdog disabled: invalid watchdog interval or grace period.");
    return;
  }

  let disconnectedSince = Date.now();
  let inFlight = false;
  const check = async () => {
    if (!listenerState.enabled) {
      disconnectedSince = Date.now();
      listenerState.watchdogAlerted = false;
      return;
    }
    if (inFlight) return;
    if (listenerState.connected) {
      if (listenerState.watchdogAlerted) {
        inFlight = true;
        await sendBark("Fluxgram 通知服务", "通知监听已恢复。", null, "tg://");
        inFlight = false;
        listenerState.watchdogAlerted = false;
      }
      disconnectedSince = Date.now();
      return;
    }

    if (Date.now() - disconnectedSince < grace || listenerState.watchdogAlerted) return;
    inFlight = true;
    await sendBark("Fluxgram 通知服务", "通知监听已中断，请检查 NAS 服务。", null, "tg://");
    inFlight = false;
    listenerState.watchdogAlerted = true;
  };

  const timer = setInterval(() => {
    check().catch((error) => {
      inFlight = false;
      console.warn(`Notification watchdog failed: ${error.constructor.name}`);
    });
  }, interval);
  timer.unref?.();
}

function statusPayload() {
  const now = Date.now();
  const realtimeHealthy = listenerState.connected
    && listenerState.lastRealtimeUpdateAt !== null
    && now - Date.parse(listenerState.lastRealtimeUpdateAt) <= REALTIME_GRACE_MS;
  return {
    ok: true,
    version: "1",
    enabled: listenerState.enabled,
    connection: listenerState.connected ? (realtimeHealthy ? "realtime" : "polling") : "disconnected",
    realtimeHealthy,
    pollingSeeded: listenerState.pollingSeeded,
    lastTelegramSyncAt: listenerState.lastTelegramSyncAt,
    lastRealtimeUpdateAt: listenerState.lastRealtimeUpdateAt,
    lastBarkSuccessAt: listenerState.lastBarkSuccessAt,
    lastBarkFailureAt: listenerState.lastBarkFailureAt,
    watchdogAlerted: listenerState.watchdogAlerted,
    counters: listenerState.counters,
  };
}

function markRealtimeActivity() {
  const now = new Date().toISOString();
  listenerState.lastRealtimeUpdateAt = now;
  listenerState.lastTelegramSyncAt = now;
}

function tokenMatches(value, expected) {
  const supplied = Buffer.from(value || "");
  const configured = Buffer.from(expected || "");
  return supplied.length === configured.length
    && supplied.length > 0
    && crypto.timingSafeEqual(supplied, configured);
}

function startStatusServer() {
  const token = (process.env.NOTIFY_STATUS_TOKEN || "").trim();
  if (!token) {
    console.warn("Status endpoint disabled: NOTIFY_STATUS_TOKEN is not configured.");
    return;
  }
  const port = Number(process.env.NOTIFY_STATUS_PORT || 30178);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error("NOTIFY_STATUS_PORT must be a valid TCP port.");
  }
  const host = (process.env.NOTIFY_STATUS_HOST || "0.0.0.0").trim();
  const server = http.createServer(async (request, response) => {
    if (request.method === "GET" && request.url === "/status") {
      if (!tokenMatches(request.headers["x-tgapp-token"], token)) {
        response.writeHead(401).end();
        return;
      }
      response.writeHead(200, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
      response.end(JSON.stringify(statusPayload()));
      return;
    }
    if (request.method !== "POST" || request.url !== "/control") {
      response.writeHead(404).end();
      return;
    }
    if (!tokenMatches(request.headers["x-tgapp-token"], token)) {
      response.writeHead(401).end();
      return;
    }
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => {
      body += chunk;
      if (body.length > 1024) request.destroy();
    });
    request.on("error", () => response.writeHead(400).end());
    request.on("end", async () => {
      let payload;
      try {
        payload = JSON.parse(body || "{}");
      } catch (error) {
        response.writeHead(400, { "content-type": "application/json; charset=utf-8" });
        response.end(JSON.stringify({ ok: false, error: "请求内容不是有效 JSON。" }));
        return;
      }
      if (typeof payload.enabled !== "boolean" || typeof notificationControl.setEnabled !== "function") {
        response.writeHead(400, { "content-type": "application/json; charset=utf-8" });
        response.end(JSON.stringify({ ok: false, error: "enabled 必须是布尔值。" }));
        return;
      }
      try {
        await notificationControl.setEnabled(payload.enabled);
        response.writeHead(200, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
        response.end(JSON.stringify(statusPayload()));
      } catch (error) {
        console.warn(`Notification control failed: ${error.constructor.name}`);
        response.writeHead(503, { "content-type": "application/json; charset=utf-8" });
        response.end(JSON.stringify({ ok: false, error: "通知服务暂时无法切换状态。" }));
      }
    });
  });
  server.listen(port, host, () => console.log(`Status endpoint is listening on port ${port}.`));
}

async function main() {
  listenerState.enabled = loadNotificationEnabled();
  const apiId = Number(required("TELEGRAM_API_ID"));
  const apiHash = required("TELEGRAM_API_HASH");
  const sessionPath = process.env.TELEGRAM_SESSION_PATH || "/data/telegram";
  const client = new TelegramClient(
    new StringSession(sessionText(sessionPath)),
    apiId,
    apiHash,
    connectionOptions(),
  );
  const latestMessageIds = new Map();
  const notificationRetryAt = new Map();
  const pendingNotifications = new Map();
  const seenMessageKeys = new Set();
  const entityCache = new Map();
  const seenMessagesPath = (process.env.NOTIFY_SEEN_MESSAGES_PATH || DEFAULT_SEEN_MESSAGES_PATH).trim();
  const pendingNotificationsPath = (process.env.NOTIFY_PENDING_NOTIFICATIONS_PATH || DEFAULT_PENDING_NOTIFICATIONS_PATH).trim();
  let seenPersistTimer = null;
  let seenPersistChain = Promise.resolve();
  let pendingPersistChain = Promise.resolve();

  async function loadSeenMessages() {
    try {
      const raw = await fsPromises.readFile(seenMessagesPath, "utf8");
      const values = JSON.parse(raw);
      if (!Array.isArray(values)) return;
      for (const value of values) {
        if (typeof value === "string" && value) seenMessageKeys.add(value);
      }
      while (seenMessageKeys.size > MAX_SEEN_MESSAGES) {
        seenMessageKeys.delete(seenMessageKeys.values().next().value);
      }
    } catch (error) {
      if (error.code !== "ENOENT") {
        console.warn(`Seen message state could not be loaded: ${error.constructor.name}`);
      }
    }
  }

  function persistSeenMessages() {
    const values = JSON.stringify(Array.from(seenMessageKeys));
    seenPersistChain = seenPersistChain
      .then(async () => {
        await fsPromises.mkdir(path.dirname(seenMessagesPath), { recursive: true });
        const temporaryPath = `${seenMessagesPath}.tmp`;
        await fsPromises.writeFile(temporaryPath, values, { encoding: "utf8", mode: 0o600 });
        await fsPromises.rename(temporaryPath, seenMessagesPath);
      })
      .catch((error) => {
        console.warn(`Seen message state could not be saved: ${error.constructor.name}`);
      });
    return seenPersistChain;
  }

  function scheduleSeenMessagePersistence() {
    if (seenPersistTimer !== null) return;
    seenPersistTimer = setTimeout(() => {
      seenPersistTimer = null;
      void persistSeenMessages();
    }, 1_000);
    seenPersistTimer.unref?.();
  }

  async function flushSeenMessagePersistence() {
    if (seenPersistTimer !== null) {
      clearTimeout(seenPersistTimer);
      seenPersistTimer = null;
    }
    await persistSeenMessages();
  }

  function pendingNotificationValues() {
    return Array.from(pendingNotifications.entries()).map(([messageKey, pending]) => ({
      messageKey,
      chatId: String(pending.chatId),
      messageId: String(pending.messageId),
      retryAt: notificationRetryAt.get(messageKey) || 0,
    }));
  }

  function parseTelegramMessageId(value) {
    const text = String(value || "").trim();
    if (!/^\d+$/.test(text)) return null;
    const messageId = Number(text);
    return Number.isSafeInteger(messageId) && messageId > 0 ? messageId : null;
  }

  function persistPendingNotifications() {
    const values = JSON.stringify(pendingNotificationValues());
    pendingPersistChain = pendingPersistChain
      .then(async () => {
        await fsPromises.mkdir(path.dirname(pendingNotificationsPath), { recursive: true });
        const temporaryPath = `${pendingNotificationsPath}.tmp`;
        await fsPromises.writeFile(temporaryPath, values, { encoding: "utf8", mode: 0o600 });
        await fsPromises.rename(temporaryPath, pendingNotificationsPath);
      })
      .catch((error) => {
        console.warn(`Pending notification state could not be saved: ${error.constructor.name}`);
      });
    return pendingPersistChain;
  }

  async function loadPendingNotifications() {
    try {
      const raw = await fsPromises.readFile(pendingNotificationsPath, "utf8");
      const values = JSON.parse(raw);
      if (!Array.isArray(values)) return;
      for (const value of values) {
        if (!value || typeof value !== "object") continue;
        const chatId = String(value.chatId || "").trim();
        const messageId = parseTelegramMessageId(value.messageId);
        if (!chatId || messageId === null) continue;
        const messageKey = `${chatId}:${messageId}`;
        const retryAt = Number(value.retryAt || 0);
        pendingNotifications.set(messageKey, {
          chatId,
          messageId: String(messageId),
          chat: null,
          message: null,
        });
        notificationRetryAt.set(
          messageKey,
          Number.isFinite(retryAt) ? Math.max(0, retryAt) : 0,
        );
      }
    } catch (error) {
      if (error.code !== "ENOENT") {
        console.warn(`Pending notification state could not be loaded: ${error.constructor.name}`);
      }
    }
  }

  await loadSeenMessages();
  await loadPendingNotifications();

  if (!listenerState.enabled && pendingNotifications.size > 0) {
    pendingNotifications.clear();
    notificationRetryAt.clear();
    await persistPendingNotifications();
  }

  let controlChain = Promise.resolve();

  function clearPendingNotifications() {
    pendingNotifications.clear();
    notificationRetryAt.clear();
    return persistPendingNotifications();
  }

  notificationControl.setEnabled = (enabled) => {
    const operation = controlChain.then(async () => {
      if (listenerState.enabled === enabled) return;

      listenerState.enabled = enabled;
      listenerState.watchdogAlerted = false;
      if (!enabled) {
        // A disabled listener must not resume with messages accumulated while
        // it was off. Reset the cursor so the next poll seeds current state.
        latestMessageIds.clear();
        listenerState.pollingSeeded = false;
        await clearPendingNotifications();
        listenerState.connected = false;
        await client.disconnect();
        console.log("Telegram notifications disabled.");
      } else {
        console.log("Telegram notifications enabled.");
      }
      await persistNotificationEnabled(enabled);
    });
    controlChain = operation.catch(() => undefined);
    return operation;
  };

  function rememberMessage(chatId, messageId) {
    const key = `${chatId}:${messageId}`;
    if (seenMessageKeys.has(key)) return false;
    seenMessageKeys.add(key);
    if (seenMessageKeys.size > MAX_SEEN_MESSAGES) {
      seenMessageKeys.delete(seenMessageKeys.values().next().value);
    }
    scheduleSeenMessagePersistence();
    return true;
  }

  function forgetMessage(chatId, messageId) {
    const key = `${chatId}:${messageId}`;
    if (!seenMessageKeys.delete(key)) return;
    scheduleSeenMessagePersistence();
  }

  async function notificationName(chatId, chat, message) {
    const directName = displayName(chat);
    if (directName) return directName;

    const cacheKey = String(chatId);
    let resolved = entityCache.get(cacheKey);
    if (!resolved) {
      try {
        resolved = await client.getEntity(chatId);
        if (resolved) entityCache.set(cacheKey, resolved);
      } catch (error) {
        resolved = null;
      }
    }
    const resolvedName = displayName(resolved);
    if (resolvedName) return resolvedName;

    // A private message may expose only the sender peer on the event.
    if (message?.senderId) {
      try {
        const sender = await client.getEntity(message.senderId);
        const senderName = displayName(sender);
        if (senderName) return senderName;
      } catch (error) {
        // The chat name remains a valid fallback when the sender is unavailable.
      }
    }
    return "新消息";
  }

  async function notifyMessage(chatId, chat, message, source) {
    if (!listenerState.enabled || !message) return;
    const messageKey = `${chatId}:${message.id}`;
    const retryAt = notificationRetryAt.get(messageKey) || 0;
    if (retryAt > Date.now()) return;
    if (!rememberMessage(chatId, message.id)) return;
    // Persist the deduplication key before delivery. A process restart after
    // Bark accepted the request must not make the polling fallback send it a
    // second time.
    await flushSeenMessagePersistence();
    if (!listenerState.enabled) return;
    let muted = false;
    try {
      muted = await isMuted(client, chatId);
    } catch (error) {
      // A failed settings lookup must not suppress a real message. Later
      // messages will retry after the cache expires.
      console.warn(`Telegram notification settings lookup failed: ${error.constructor.name}`);
    }
    if (!listenerState.enabled) return;
    if (message.out || muted) {
      if (!message.out) listenerState.counters.mutedSkipped += 1;
      notificationRetryAt.delete(messageKey);
      pendingNotifications.delete(messageKey);
      await persistPendingNotifications();
      return;
    }
    if (source === "realtime") listenerState.counters.realtimeMessages += 1;
    if (source === "polling") listenerState.counters.pollingMessages += 1;
    if (!listenerState.enabled) return;
    const delivered = await sendBark(
      await notificationName(chatId, chat, message),
      messagePreview(message),
      await avatarUrl(client, { chatId }, chat),
      messageUrl(chat, message),
    );
    if (!listenerState.enabled) return;
    if (delivered) {
      notificationRetryAt.delete(messageKey);
      pendingNotifications.delete(messageKey);
      await persistPendingNotifications();
      return;
    }

    // Keep failed deliveries retryable. The polling cursor is normally
    // advanced before Bark is called, so simply removing the dedup key would
    // not be enough to discover this message again on the next poll.
    latestMessageIds.delete(String(chatId));
    notificationRetryAt.set(messageKey, Date.now() + DEFAULT_NOTIFICATION_RETRY_DELAY_MS);
    pendingNotifications.set(messageKey, {
      chatId,
      messageId: String(message.id),
      chat,
      message,
    });
    // Persist the retry record before removing the deduplication key. A
    // restart in between these writes can still recover the message from the
    // durable retry queue instead of losing it behind the polling cursor.
    await persistPendingNotifications();
    forgetMessage(chatId, message.id);
    await flushSeenMessagePersistence();
  }

  async function retryPendingNotifications() {
    if (!listenerState.enabled) return;
    const now = Date.now();
    for (const [messageKey, pending] of pendingNotifications) {
      if (!listenerState.enabled) return;
      if ((notificationRetryAt.get(messageKey) || 0) > now) continue;

      let message = pending.message;
      let chat = pending.chat;
      if (!message) {
        const messageId = parseTelegramMessageId(pending.messageId);
        if (messageId === null) {
          notificationRetryAt.delete(messageKey);
          pendingNotifications.delete(messageKey);
          await persistPendingNotifications();
          continue;
        }
        try {
          const messages = await client.getMessages(pending.chatId, {
            ids: [messageId],
          });
          message = Array.isArray(messages) ? messages[0] : messages;
          if (message && !chat) {
            try {
              chat = await client.getEntity(pending.chatId);
            } catch (error) {
              chat = null;
            }
          }
        } catch (error) {
          notificationRetryAt.set(messageKey, Date.now() + DEFAULT_NOTIFICATION_RETRY_DELAY_MS);
          await persistPendingNotifications();
          console.warn(`Pending Telegram message could not be loaded: ${error.constructor.name}`);
          continue;
        }
      }

      if (!message) {
        notificationRetryAt.delete(messageKey);
        pendingNotifications.delete(messageKey);
        await persistPendingNotifications();
        continue;
      }
      await notifyMessage(pending.chatId, chat, message, "retry");
    }
  }

  async function pollDialogs() {
    if (!listenerState.enabled) return;
    await retryPendingNotifications();
    let dialogCount = 0;
    let changedCount = 0;
    for await (const dialog of client.iterDialogs({ limit: 100 })) {
      if (!listenerState.enabled) return;
      dialogCount += 1;
      const message = dialog.message;
      if (!message) continue;
      const key = String(dialog.id);
      const previous = latestMessageIds.get(key);
      latestMessageIds.set(key, message.id);
      if (listenerState.pollingSeeded && (previous === undefined || message.id > previous)) {
        const retryAt = notificationRetryAt.get(`${dialog.id}:${message.id}`) || 0;
        if (retryAt > Date.now()) continue;
        changedCount += 1;
        if (previous !== undefined && message.id > previous) {
          for await (const candidate of client.iterMessages(dialog.id, { minId: previous, reverse: true, limit: 100 })) {
            if (!listenerState.enabled) return;
            await notifyMessage(dialog.id, dialog.entity, candidate, "polling");
          }
        } else {
          await notifyMessage(dialog.id, dialog.entity, message, "polling");
        }
      }
    }
    listenerState.pollingSeeded = true;
    listenerState.lastTelegramSyncAt = new Date().toISOString();
    listenerState.counters.polls += 1;
    console.log(`Polling completed: dialogs=${dialogCount}, changed=${changedCount}.`);
  }

  client.addEventHandler(async (event) => {
    if (!listenerState.enabled) return;
    markRealtimeActivity();
    const message = event.message;
    if (!message) return;
    try {
      const chat = await event.getChat();
      const chatId = event.chatId || chat?.id;
      if (chatId === undefined || chatId === null) return;
      latestMessageIds.set(String(chatId), message.id);
      await notifyMessage(chatId, chat, message, "realtime");
    } catch (error) {
      console.warn(`Realtime message handling failed: ${error.constructor.name}`);
    }
  }, new NewMessage({ incoming: true }));

  let stopping = false;
  const stop = async () => {
    stopping = true;
    listenerState.enabled = false;
    listenerState.connected = false;
    await client.disconnect();
    await flushSeenMessagePersistence();
    await pendingPersistChain;
  };
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);

  while (!stopping) {
    if (!listenerState.enabled) {
      await new Promise((resolve) => setTimeout(resolve, 1_000));
      continue;
    }
    try {
      await client.connect();
      if (stopping || !listenerState.enabled) continue;
      if (!(await client.checkAuthorization())) {
        console.warn("Telegram authorization is required; run login.js once.");
        await new Promise((resolve) => setTimeout(resolve, listenerState.enabled ? 60_000 : 1_000));
        continue;
      }

      listenerState.connected = true;
      console.log("Telegram listener is connected.");
      await pollDialogs();
      while (!stopping && listenerState.enabled) {
        await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
        if (!listenerState.enabled) break;
        const lastUpdateAt = listenerState.lastRealtimeUpdateAt ? Date.parse(listenerState.lastRealtimeUpdateAt) : 0;
        if (!lastUpdateAt || Date.now() - lastUpdateAt > REALTIME_GRACE_MS) {
          await pollDialogs();
        }
      }
    } catch (error) {
      listenerState.connected = false;
      console.warn(`Telegram listener disconnected: ${error.constructor.name}`);
      await new Promise((resolve) => setTimeout(resolve, listenerState.enabled ? 15_000 : 1_000));
    } finally {
      listenerState.connected = false;
      await client.disconnect();
    }
  }
}

startStatusServer();
startWatchdog();

main().catch((error) => {
  console.error(`Fatal startup error: ${error.message}`);
  process.exitCode = 1;
});
