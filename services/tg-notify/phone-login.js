const fs = require("node:fs/promises");
const path = require("node:path");

const { Api, TelegramClient } = require("telegram");
const { StringSession } = require("telegram/sessions");

function required(name) {
  const value = (process.env[name] || "").trim();
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function connectionOptions() {
  const options = { connectionRetries: 5 };
  const host = (process.env.TELEGRAM_PROXY_HOST || "").trim();
  const port = Number(process.env.TELEGRAM_PROXY_PORT || 0);
  if (host && port > 0) {
    options.proxy = { ip: host, port, socksType: Number(process.env.TELEGRAM_PROXY_TYPE || 5) };
  }
  return options;
}

async function readOnce(file) {
  const value = (await fs.readFile(file, "utf8")).trim();
  await fs.rm(file, { force: true });
  if (!value) throw new Error(`The temporary ${path.basename(file)} input is empty.`);
  return value;
}

async function readText(file) {
  try {
    return (await fs.readFile(file, "utf8")).trim();
  } catch (error) {
    if (error.code === "ENOENT") return "";
    throw error;
  }
}

async function writePrivate(file, value) {
  await fs.writeFile(file, value, { mode: 0o600 });
  await fs.chmod(file, 0o600);
}

async function main() {
  const dataDir = path.dirname(process.env.TELEGRAM_SESSION_PATH || "/data/telegram");
  const authSession = path.join(dataDir, "telegram");
  const pendingSession = path.join(dataDir, ".login-pending.session");
  const pendingFile = path.join(dataDir, ".login-pending.json");
  const apiId = Number(required("TELEGRAM_API_ID"));
  const apiHash = required("TELEGRAM_API_HASH");
  const mode = required("TELEGRAM_LOGIN_MODE");
  const client = new TelegramClient(new StringSession(await readText(pendingSession)), apiId, apiHash, connectionOptions());

  await client.connect();
  try {
    if (mode === "request" || mode === "resend-sms") {
      const previous = mode === "resend-sms"
        ? JSON.parse(await fs.readFile(pendingFile, "utf8"))
        : null;
      const phone = previous ? previous.phone : await readOnce(path.join(dataDir, ".login-phone"));
      const sentCode = await client.sendCode({ apiId, apiHash }, phone, mode === "resend-sms");
      await writePrivate(pendingFile, JSON.stringify({ phone, phoneCodeHash: sentCode.phoneCodeHash }));
      await writePrivate(pendingSession, client.session.save());
      console.log(mode === "resend-sms" ? "TELEGRAM_SMS_REQUESTED" : "TELEGRAM_CODE_REQUESTED");
      return;
    }

    const pending = JSON.parse(await fs.readFile(pendingFile, "utf8"));
    if (mode === "complete") {
      const code = await readOnce(path.join(dataDir, ".login-code"));
      try {
        await client.invoke(new Api.auth.SignIn({
          phoneNumber: pending.phone,
          phoneCodeHash: pending.phoneCodeHash,
          phoneCode: code,
        }));
      } catch (error) {
        if (error.errorMessage !== "SESSION_PASSWORD_NEEDED") throw error;
        console.log("TELEGRAM_PASSWORD_REQUIRED");
        return;
      }
    } else if (mode === "password") {
      const password = await readOnce(path.join(dataDir, ".login-password"));
      await client.signInWithPassword(
        { apiId, apiHash },
        { password: async () => password, onError: async () => true },
      );
    } else {
      throw new Error("Unsupported Telegram login mode.");
    }

    await writePrivate(authSession, client.session.save());
    await Promise.all([fs.rm(pendingFile, { force: true }), fs.rm(pendingSession, { force: true })]);
    console.log("TELEGRAM_AUTHORIZATION_COMPLETED");
  } finally {
    await client.disconnect();
  }
}

main().catch((error) => {
  console.error(`Telegram authorization failed: ${error.errorMessage || error.message}`);
  process.exitCode = 1;
});
