"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { createServer } = require("../server");

function start({ notifyKey = "k-notify" } = {}) {
  const calls = [];
  const relay = { handle: async () => {}, notify: async (p) => { calls.push(p); return { posted: true }; } };
  const verifier = { verify: async () => { throw Object.assign(new Error("no"), { status: 401 }); } };
  const server = createServer({ config: { frontDoorKey: "fd", notifyKey }, relay, verifier, hermes: { health: async () => true } });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve({ server, calls, port: server.address().port })));
}

async function post(port, path, body, headers = {}) {
  const res = await fetch(`http://127.0.0.1:${port}${path}`, { method: "POST", headers: { "content-type": "application/json", ...headers }, body });
  return { status: res.status, json: await res.json().catch(() => ({})) };
}

test("/notify needs the notify key, a records array, and then hands the batch to the relay", async () => {
  const { server, calls, port } = await start();
  try {
    assert.equal((await post(port, "/notify", JSON.stringify({ records: ["x"] }))).status, 403);
    assert.equal((await post(port, "/notify", JSON.stringify({ records: ["x"] }), { "x-notify-key": "wrong" })).status, 403);
    assert.equal((await post(port, "/notify", "{}", { "x-notify-key": "k-notify" })).status, 400);
    assert.equal((await post(port, "/notify", "not json", { "x-notify-key": "k-notify" })).status, 400);
    const ok = await post(port, "/notify", JSON.stringify({ records: ["Calendar event, updated", "Sent by Aaron to: Kirk"] }), { "x-notify-key": "k-notify" });
    assert.equal(ok.status, 202);
    assert.equal(ok.json.accepted, 2);
    await new Promise((r) => setTimeout(r, 10));
    assert.deepEqual(calls, [{ records: ["Calendar event, updated", "Sent by Aaron to: Kirk"], kind: "feed" }]);
    assert.equal((await post(port, "/notify", JSON.stringify({ records: ["x"], kind: "weather" }), { "x-notify-key": "k-notify" })).status, 400);
    const meeting = await post(port, "/notify", JSON.stringify({ records: ["Meeting prep: Sync"], kind: "meeting" }), { "x-notify-key": "k-notify" });
    assert.equal(meeting.status, 202);
    await new Promise((r) => setTimeout(r, 10));
    assert.deepEqual(calls[1], { records: ["Meeting prep: Sync"], kind: "meeting" });
  } finally {
    server.close();
  }
});

test("/notify is off entirely when no key is configured", async () => {
  const { server, port } = await start({ notifyKey: "" });
  try {
    assert.equal((await post(port, "/notify", JSON.stringify({ records: ["x"] }), { "x-notify-key": "" })).status, 403);
  } finally {
    server.close();
  }
});

test("/notify takes kind progress and passes the mesh message ids on", async () => {
  const { server, calls, port } = await start();
  try {
    const r = await post(port, "/notify", JSON.stringify({ records: ["From session: assistant"], kind: "progress", ids: ["858b4ff7"] }), { "x-notify-key": "k-notify" });
    assert.equal(r.status, 202);
    await new Promise((res) => setTimeout(res, 10));
    assert.deepEqual(calls[0], { records: ["From session: assistant"], kind: "progress", ids: ["858b4ff7"] });
  } finally {
    server.close();
  }
});

// Deploys restarted Hermes mid-answer twice on 2026-10-20 (a lost board answer, then "ECONNREFUSED 127.0.0.1:8642").
// The deploy scripts wait on /status until nothing is running or waiting.
test("/status reports whether the relay is busy and how many jobs wait", async () => {
  const relay = { handle: async () => {}, notify: async () => ({}), status: () => ({ busy: true, waiting: 2 }) };
  const server = createServer({ config: { frontDoorKey: "fd", notifyKey: "k" }, relay, verifier: { verify: async () => {} }, hermes: { health: async () => true } });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  try {
    const res = await fetch(`http://127.0.0.1:${server.address().port}/status`);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { busy: true, waiting: 2 });
  } finally {
    server.close();
  }
});
