"use strict";
/**
 * hermes-teams: the relay between the Teams bot "Hermes" and Hermes Agent on this Mac.
 *   GET  /health          -> {ok, relay, bot:{configured}, hermes:{ok}}
 *   POST /webhooks/teams  -> front-door key, Microsoft's JWT, 200 at once; the answer follows in the chat.
 *   POST /notify          -> local only; {records[], kind?: feed|meeting} from Hermes Helper, needs x-notify-key.
 * Binds 127.0.0.1 only; the Cloudflare Worker reaches it through the tunnel. Run by launchd (see launchd/).
 */
const http = require("node:http");
const crypto = require("node:crypto");
const { RelayError, createJwtVerifier, createConnectorClient } = require("./lib/teams");
const { createHermesClient } = require("./lib/hermes");
const { createRelay } = require("./lib/relay");
const { createState } = require("./lib/state");
const { createLog } = require("./lib/log");
const { loadConfig } = require("./lib/config");

const BODY_LIMIT = 256 * 1024;

function createServer({ config, relay, verifier, hermes, log = () => {} }) {
  const key = (config && config.frontDoorKey) || "";

  function keyOk(value) {
    if (!key) return true;
    const a = Buffer.from(String(value || ""));
    const b = Buffer.from(key);
    return a.length === b.length && crypto.timingSafeEqual(a, b);
  }

  function json(res, status, body) {
    res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff" });
    res.end(JSON.stringify(body));
  }

  function readBody(req) {
    return new Promise((resolve, reject) => {
      const chunks = [];
      let size = 0;
      req.on("data", (c) => {
        size += c.length;
        if (size > BODY_LIMIT) {
          reject(new RelayError(413, "Body too large"));
          req.destroy();
        } else {
          chunks.push(c);
        }
      });
      req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
      req.on("error", reject);
    });
  }

  return http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, "http://relay");
      if (req.method === "GET" && url.pathname === "/health") {
        const ok = hermes && hermes.health ? await hermes.health() : null;
        return json(res, 200, { ok: true, relay: "hermes-teams", bot: { configured: !!(config && config.teamsBot && config.teamsBot.appId) }, hermes: { ok } });
      }
      if (req.method === "POST" && url.pathname === "/webhooks/teams") {
        if (!keyOk(req.headers["x-front-door-key"])) throw new RelayError(403, "Missing front-door key");
        const raw = await readBody(req);
        let activity;
        try {
          activity = JSON.parse(raw);
        } catch {
          throw new RelayError(400, "Expected a JSON activity");
        }
        if (!activity || typeof activity !== "object" || Array.isArray(activity)) throw new RelayError(400, "Expected a JSON activity");
        await verifier.verify(req.headers.authorization, activity);
        log("info", { event: "inbound", type: activity.type || null, name: (activity.from && activity.from.name) || null, aadObjectId: (activity.from && activity.from.aadObjectId) || null, conversation: (activity.conversation && activity.conversation.conversationType) || null, hasText: !!activity.text });
        json(res, 200, {});
        relay.handle(activity).catch((err) => log("error", { event: "handle-failed", message: err.message }));
        return;
      }
      if (req.method === "POST" && url.pathname === "/notify") {
        // Local only: the Cloudflare Worker forwards nothing but /webhooks/teams and /health. The helper sends feed
        // changes here with the shared notify key; Hermes decides whether Aaron hears about them.
        if (!config.notifyKey || req.headers["x-notify-key"] !== config.notifyKey) throw new RelayError(403, "Missing notify key");
        const raw = await readBody(req);
        let payload;
        try {
          payload = JSON.parse(raw);
        } catch {
          throw new RelayError(400, "Expected JSON");
        }
        const records = Array.isArray(payload && payload.records) ? payload.records.map(String) : [];
        if (!records.length) throw new RelayError(400, "records[] is empty");
        const kind = payload.kind === undefined ? "feed" : String(payload.kind);
        if (kind !== "feed" && kind !== "meeting") throw new RelayError(400, "kind must be feed or meeting");
        log("info", { event: "notify", kind, records: records.length });
        json(res, 202, { accepted: records.length });
        relay.notify({ records, kind }).catch((err) => log(err.status === 409 ? "warn" : "error", { event: "notify-failed", message: err.message }));
        return;
      }
      throw new RelayError(404, "Not found");
    } catch (err) {
      const status = err && err.status ? err.status : 500;
      log(status === 500 ? "error" : "warn", { event: "request-failed", status, path: req.url, message: err.message });
      if (!res.headersSent) json(res, status, { ok: false, error: err.message });
    }
  });
}

function main() {
  const config = loadConfig();
  const log = createLog();
  const state = createState(config.stateFile);
  const hermes = createHermesClient({ url: config.hermes.url, key: config.hermes.key, state, timeoutMs: config.hermes.timeoutMs });
  const bot = config.teamsBot;
  const configured = !!(bot.appId && bot.appPassword);
  const verifier = configured
    ? createJwtVerifier({ appId: bot.appId })
    : { verify: async () => { throw new RelayError(503, "Teams bot not configured yet: run scripts/setup.js"); } };
  const connector = configured ? createConnectorClient({ appId: bot.appId, appPassword: bot.appPassword, tenantId: () => bot.tenantId || state.get("tenantId") }) : null;
  const relay = createRelay({ config, connector, hermes, state, log });
  const server = createServer({ config, relay, verifier, hermes, log });
  server.listen(config.port, config.host, () => log("info", { event: "listening", host: config.host, port: config.port, bot: configured, hermes: config.hermes.url }));
  for (const sig of ["SIGTERM", "SIGINT"]) process.on(sig, () => { log("info", { event: "stopping", signal: sig }); server.close(() => process.exit(0)); });
}

module.exports = { createServer };
if (require.main === module) main();
