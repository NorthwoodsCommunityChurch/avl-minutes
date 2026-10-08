"use strict";
/** What happens to each Teams activity: who may talk, the two commands, typing, Hermes, the reply. */
const { cleanText, splitMessage, GLOBAL_SERVICE_URL } = require("./teams");

const GREETING = "Hi Aaron. Ask me about your notes and meetings. `/new` starts a fresh conversation, `/help` repeats this.";
const HELP = "Just type a question. `/new` starts a fresh conversation (I forget the thread so far). `/help` shows this.";
const PRIVATE = "Sorry, this assistant is private.";

function createRelay({ config, connector, hermes, state, log = () => {}, typingIntervalMs = 4000, now = () => Date.now() }) {
  const allowed = (config && config.allowedUsers) || [];
  const configuredTenant = (config && config.teamsBot && config.teamsBot.tenantId) || "";
  let queue = Promise.resolve();

  const tenantOf = (activity) => (activity.conversation && activity.conversation.tenantId) || (activity.channelData && activity.channelData.tenant && activity.channelData.tenant.id) || "";

  /** The tenant is pinned by config or by the first authorized message; anything else is ignored. */
  function tenantOk(activity) {
    const pinned = configuredTenant || state.get("tenantId");
    if (!pinned) return true;
    const t = tenantOf(activity);
    return !!t && t === pinned;
  }

  /**
   * An allowlist entry with an aadObjectId matches only that immutable id. A name-only entry is a one-time
   * bootstrap: the first account whose Teams display name matches is pinned to that entry (state "pins"),
   * and from then on only that account's id matches, so a stranger renaming themselves gets nothing.
   */
  function isAllowed(from = {}) {
    const aad = String(from.aadObjectId || "").toLowerCase();
    const name = String(from.name || "").trim().toLowerCase();
    const pins = state.get("pins") || {};
    for (const u of allowed) {
      if (u.aadObjectId) {
        if (aad && String(u.aadObjectId).toLowerCase() === aad) return u;
        continue;
      }
      if (!u.name) continue;
      const key = String(u.name).trim().toLowerCase();
      if (pins[key]) {
        if (aad && String(pins[key]).toLowerCase() === aad) return u;
        continue;
      }
      if (aad && name === key) {
        pins[key] = from.aadObjectId;
        state.set("pins", pins);
        log("info", { event: "pinned", aadObjectId: from.aadObjectId, name: from.name });
        return u;
      }
    }
    return null;
  }

  /** Only after a message passed both checks: remember the tenant and service URL for later replies. */
  function learn(activity) {
    if (activity.serviceUrl) state.set("serviceUrl", activity.serviceUrl);
    const tenant = tenantOf(activity);
    if (tenant && !state.get("tenantId")) state.set("tenantId", tenant);
  }

  const send = (activity, payload) => connector.sendToConversation(activity.serviceUrl || state.get("serviceUrl") || GLOBAL_SERVICE_URL, activity.conversation.id, payload);

  async function say(activity, text) {
    for (const part of splitMessage(text)) await send(activity, { type: "message", textFormat: "markdown", text: part });
  }

  /** Repeats a typing indicator until stopped; stops promptly. */
  function startTyping(activity) {
    let stopped = false;
    let wake = null;
    let timer = null;
    const loop = (async () => {
      while (!stopped) {
        try {
          await send(activity, { type: "typing" });
        } catch {
          /* typing is best effort */
        }
        if (stopped) break;
        await new Promise((resolve) => {
          wake = resolve;
          timer = setTimeout(resolve, typingIntervalMs);
        });
      }
    })();
    return async () => {
      stopped = true;
      if (timer) clearTimeout(timer);
      if (wake) wake();
      await loop;
    };
  }

  async function answer(activity, text, who) {
    const conversationId = activity.conversation.id;
    const started = now();
    const stopTyping = startTyping(activity);
    try {
      const r = await hermes.ask({ conversationId, text });
      await stopTyping();
      await say(activity, r.text);
      log("info", { event: "answered", ...who, chars: r.text.length, seconds: Math.round((now() - started) / 1000) });
    } catch (err) {
      await stopTyping();
      log("error", { event: "failed", ...who, message: err.message, seconds: Math.round((now() - started) / 1000) });
      await say(activity, `Hermes couldn't answer: ${err.message}`);
    }
  }

  async function onMessage(activity) {
    const from = activity.from || {};
    const who = { aadObjectId: from.aadObjectId || null, name: from.name || null };
    if (!tenantOk(activity)) {
      log("warn", { event: "refused", reason: "tenant", ...who, tenant: tenantOf(activity) || null });
      return; // a foreign tenant gets silence, not a reply
    }
    const user = isAllowed(from);
    if (!user) {
      log("warn", { event: "refused", reason: "user", ...who });
      await say(activity, PRIVATE);
      return;
    }
    learn(activity);
    const text = cleanText(activity.text);
    if (!text) return;
    if (/^\/?new( chat)?[.!]?$/i.test(text)) {
      state.clearResponse(activity.conversation.id);
      await say(activity, "Started a fresh conversation.");
      return;
    }
    if (/^\/?help[.!?]?$/i.test(text)) {
      await say(activity, HELP);
      return;
    }
    await answer(activity, text, who);
  }

  async function onConversationUpdate(activity) {
    if (!tenantOk(activity)) return;
    const added = (activity.membersAdded || []).map((m) => m.id);
    if (activity.recipient && added.includes(activity.recipient.id)) await say(activity, GREETING);
  }

  /** Processes one activity; activities run one at a time, in arrival order (the model has one slot). */
  function handle(activity) {
    const run = async () => {
      if (activity.type === "message") await onMessage(activity);
      else if (activity.type === "conversationUpdate") await onConversationUpdate(activity);
    };
    const p = queue.then(run, run);
    queue = p.catch(() => {});
    return p;
  }

  return { handle, isAllowed, tenantOk };
}

module.exports = { createRelay, GREETING, HELP, PRIVATE };
