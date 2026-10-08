"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");
const { createServer } = require("../server");

function start(opts) {
  const srv = createServer(opts);
  return new Promise((resolve) => srv.listen(0, "127.0.0.1", () => resolve({ srv, port: srv.address().port })));
}

function req(port, method, path, { body, raw, headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const r = http.request({ host: "127.0.0.1", port, method, path, headers: { "content-type": "application/json", ...headers } }, (res) => {
      let data = "";
      res.on("data", (c) => (data += c));
      res.on("end", () => resolve({ status: res.statusCode, body: data ? JSON.parse(data) : null }));
    });
    r.on("error", reject);
    if (raw !== undefined) r.write(raw);
    else if (body) r.write(JSON.stringify(body));
    r.end();
  });
}

test("health answers with the relay's state", async () => {
  const { srv, port } = await start({ config: { frontDoorKey: "", teamsBot: { appId: "bot" } }, relay: { handle: async () => {} }, verifier: { verify: async () => ({}) }, hermes: { health: async () => true } });
  const r = await req(port, "GET", "/health");
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { ok: true, relay: "hermes-teams", bot: { configured: true }, hermes: { ok: true } });
  srv.close();
});

test("webhook needs the front-door key and a valid token, then answers 200 before the work is done", async () => {
  let finished = false;
  let resolveWork;
  const relay = { handle: () => new Promise((r) => { resolveWork = () => { finished = true; r(); }; }) };
  const verifier = { verify: async (auth) => { if (auth !== "Bearer good") { const e = new Error("bad"); e.status = 401; throw e; } return {}; } };
  const logs = [];
  const { srv, port } = await start({ config: { frontDoorKey: "door" }, relay, verifier, log: (level, data) => logs.push({ level, ...data }) });
  const activity = { type: "message", text: "hi", from: { name: "A", aadObjectId: "aad" } };
  assert.equal((await req(port, "POST", "/webhooks/teams", { body: activity, headers: { authorization: "Bearer good" } })).status, 403);
  assert.equal((await req(port, "POST", "/webhooks/teams", { body: activity, headers: { authorization: "Bearer bad", "x-front-door-key": "door" } })).status, 401);
  assert.equal((await req(port, "POST", "/webhooks/teams", { raw: "not json", headers: { authorization: "Bearer good", "x-front-door-key": "door" } })).status, 400);
  const ok = await req(port, "POST", "/webhooks/teams", { body: activity, headers: { authorization: "Bearer good", "x-front-door-key": "door" } });
  assert.equal(ok.status, 200);
  assert.ok(logs.some((l) => l.event === "inbound" && l.type === "message" && l.aadObjectId === "aad" && !("text" in l)));
  assert.ok(logs.some((l) => l.event === "request-failed" && l.status === 401));
  assert.equal(finished, false, "the response came back before the relay finished");
  resolveWork();
  await new Promise((r) => setTimeout(r, 5));
  assert.equal(finished, true);
  assert.equal((await req(port, "GET", "/nope")).status, 404);
  assert.equal((await req(port, "GET", "/webhooks/teams")).status, 404);
  srv.close();
});

test("oversized bodies are refused", async () => {
  const { srv, port } = await start({ config: { frontDoorKey: "" }, relay: { handle: async () => {} }, verifier: { verify: async () => ({}) } });
  const r = await req(port, "POST", "/webhooks/teams", { raw: JSON.stringify({ type: "message", text: "x".repeat(300 * 1024) }) }).catch((e) => ({ status: "closed", error: e.code }));
  assert.ok(r.status === 413 || r.status === "closed");
  srv.close();
});
