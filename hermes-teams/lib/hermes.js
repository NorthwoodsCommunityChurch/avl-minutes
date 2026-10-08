"use strict";
/**
 * Client for Hermes Agent's API server (`hermes gateway` with API_SERVER_ENABLED): POST /v1/responses runs the
 * full agent (tools, memory) and keeps the conversation server-side; the relay stores each chat's last
 * response id so the next message continues the thread.
 */
function createHermesClient({ url, key, state, fetch = globalThis.fetch, timeoutMs = 20 * 60 * 1000, model = "hermes-agent" }) {
  const base = String(url || "http://127.0.0.1:8642").replace(/\/+$/, "");

  async function post(body, signal) {
    const res = await fetch(`${base}/v1/responses`, {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal,
    });
    const json = await res.json().catch(() => ({}));
    return { res, json };
  }

  function extract(json) {
    const texts = [];
    for (const item of json.output || []) {
      if (item.type !== "message") continue;
      for (const part of item.content || []) if (part.type === "output_text" && part.text) texts.push(part.text);
    }
    return texts.join("\n\n").trim();
  }

  async function ask({ conversationId, text }) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const previous = state.getResponse(conversationId);
      const body = { model, input: text, store: true };
      if (previous) body.previous_response_id = previous;
      let { res, json } = await post(body, controller.signal);
      if (!res.ok && previous && (res.status === 404 || res.status === 400) && /previous_response_id/i.test(JSON.stringify(json))) {
        state.clearResponse(conversationId);
        delete body.previous_response_id;
        ({ res, json } = await post(body, controller.signal));
      }
      if (!res.ok) throw new Error(`Hermes answered ${res.status}: ${(json.error && json.error.message) || json.message || "unknown error"}`);
      if (json.id) state.setResponse(conversationId, json.id);
      return { text: extract(json) || "Hermes had no answer.", responseId: json.id || null };
    } catch (err) {
      if (err && err.name === "AbortError") throw new Error(`Hermes timed out after ${Math.round(timeoutMs / 1000)} s`);
      throw err;
    } finally {
      clearTimeout(timer);
    }
  }

  async function health() {
    try {
      const res = await fetch(`${base}/health`, { signal: AbortSignal.timeout(3000) });
      return !!res.ok;
    } catch {
      return false;
    }
  }

  return { ask, health };
}

module.exports = { createHermesClient };
