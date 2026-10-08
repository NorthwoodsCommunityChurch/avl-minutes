"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { createHermesClient } = require("../lib/hermes");
const { createState } = require("../lib/state");

function tmpFile() {
  return path.join(fs.mkdtempSync(path.join(os.tmpdir(), "hermes-teams-")), "state.json");
}

function response(id, text) {
  return {
    id,
    object: "response",
    status: "completed",
    output: [
      { type: "function_call", name: "mcp_notes_search_notes", arguments: "{}" },
      { type: "message", role: "assistant", content: [{ type: "output_text", text }] },
    ],
  };
}

test("ask sends the stored previous_response_id and keeps the new id", async () => {
  const state = createState(tmpFile());
  state.setResponse("conv-1", "resp_old");
  const calls = [];
  const fetch = async (url, init) => {
    calls.push({ url: String(url), body: JSON.parse(init.body), headers: init.headers });
    return { ok: true, status: 200, json: async () => response("resp_new", "Here you go") };
  };
  const h = createHermesClient({ url: "http://127.0.0.1:8642", key: "k", fetch, state });
  const r = await h.ask({ conversationId: "conv-1", text: "hello" });
  assert.equal(r.text, "Here you go");
  assert.equal(calls[0].url, "http://127.0.0.1:8642/v1/responses");
  assert.equal(calls[0].body.previous_response_id, "resp_old");
  assert.equal(calls[0].body.input, "hello");
  assert.equal(calls[0].body.store, true);
  assert.equal(calls[0].headers.Authorization, "Bearer k");
  assert.equal(state.getResponse("conv-1"), "resp_new");
});

test("ask retries once without a previous id Hermes no longer knows", async () => {
  const state = createState(tmpFile());
  state.setResponse("conv-1", "resp_gone");
  let n = 0;
  const fetch = async (url, init) => {
    n++;
    const body = JSON.parse(init.body);
    if (body.previous_response_id) return { ok: false, status: 404, json: async () => ({ error: { message: "previous_response_id not found" } }) };
    return { ok: true, status: 200, json: async () => response("resp_fresh", "fresh") };
  };
  const h = createHermesClient({ url: "http://127.0.0.1:8642", key: "k", fetch, state });
  const r = await h.ask({ conversationId: "conv-1", text: "again" });
  assert.equal(n, 2);
  assert.equal(r.text, "fresh");
  assert.equal(state.getResponse("conv-1"), "resp_fresh");
});

test("ask reports Hermes errors and empty answers", async () => {
  const state = createState(tmpFile());
  const failing = createHermesClient({ url: "http://127.0.0.1:8642", key: "k", state, fetch: async () => ({ ok: false, status: 500, json: async () => ({ error: { message: "boom" } }) }) });
  await assert.rejects(failing.ask({ conversationId: "c", text: "x" }), /boom/);
  const empty = createHermesClient({ url: "http://127.0.0.1:8642", key: "k", state, fetch: async () => ({ ok: true, status: 200, json: async () => ({ id: "r", output: [] }) }) });
  assert.equal((await empty.ask({ conversationId: "c", text: "x" })).text, "Hermes had no answer.");
});

test("ask gives up after the timeout", async () => {
  const state = createState(tmpFile());
  const fetch = (url, init) => new Promise((_, reject) => init.signal.addEventListener("abort", () => reject(Object.assign(new Error("aborted"), { name: "AbortError" }))));
  const h = createHermesClient({ url: "http://127.0.0.1:8642", key: "k", state, fetch, timeoutMs: 20 });
  await assert.rejects(h.ask({ conversationId: "c", text: "x" }), /timed out/i);
});

test("state persists to disk and forgets a conversation", () => {
  const file = tmpFile();
  const s = createState(file);
  s.setResponse("c", "r1");
  s.set("tenantId", "t");
  const again = createState(file);
  assert.equal(again.getResponse("c"), "r1");
  assert.equal(again.get("tenantId"), "t");
  again.clearResponse("c");
  assert.equal(createState(file).getResponse("c"), null);
});
