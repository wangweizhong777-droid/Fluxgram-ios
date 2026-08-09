const fs = require("node:fs/promises");
const path = require("node:path");
const { TelegramClient } = require("telegram");
const { StringSession } = require("telegram/sessions");

function required(name) {
  const value = (process.env[name] || "").trim();
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

async function sessionText(sessionPath) {
  try {
    return (await fs.readFile(sessionPath, "utf8")).trim();
  } catch (error) {
    if (error.code === "ENOENT") return "";
    throw error;
  }
}

async function readOnce(file) {
  const value = (await fs.readFile(file, "utf8")).trim();
  await fs.rm(file, { force: true });
  if (!value) throw new Error("Telegram two-step verification password is empty.");
  return value;
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

async function main() {
  const sessionPath = process.env.TELEGRAM_SESSION_PATH || "/data/telegram";
  const qrPath = path.join(path.dirname(sessionPath), ".qr-url");
  const apiId = Number(required("TELEGRAM_API_ID"));
  const apiHash = required("TELEGRAM_API_HASH");
  const client = new TelegramClient(
    new StringSession(await sessionText(sessionPath)),
    apiId,
    apiHash,
    connectionOptions(),
  );

  await client.connect();
  try {
    if (await client.checkAuthorization()) {
      console.log("Telegram is already authorized.");
      return;
    }

    await client.signInUserWithQrCode(
      { apiId, apiHash },
      {
        qrCode: async ({ token }) => {
          const url = `tg://login?token=${Buffer.from(token).toString("base64url")}`;
          await fs.writeFile(qrPath, url, { mode: 0o600 });
          console.log("QR_READY");
        },
        password: async () => readOnce(path.join(path.dirname(sessionPath), ".login-password")),
        onError: async (error) => {
          console.warn(`Telegram QR login error: ${error.errorMessage || error.constructor.name}`);
          return false;
        },
      },
    );

    await fs.writeFile(sessionPath, client.session.save(), { mode: 0o600 });
    console.log("Telegram authorization completed.");
  } finally {
    await fs.rm(qrPath, { force: true });
    await client.disconnect();
  }
}

main().catch((error) => {
  console.error(`Telegram authorization failed: ${error.errorMessage || error.message}`);
  process.exitCode = 1;
});
