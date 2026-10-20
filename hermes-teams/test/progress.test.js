"use strict";
// Aaron, 2026-10-20: "Can we have hermes as part of the mesh, so you can post information to her? ... so she can know what
// progress has been made", and "I want her telling me when she sees something". The mesh bridge on his Mac posts each
// note sent to the mesh name `hermes` as kind "progress"; she files it in her notes and tells him in a line.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { createRelay, buildProgressPrompt } = require("../lib/relay");
const { createState } = require("../lib/state");

const SERVICE_URL = "https://smba.trafficmanager.net/amer/";
const aaron = { id: "29:abc", name: "Aaron Larson", aadObjectId: "aad-aaron" };

function harness({ askImpl } = {}) {
  const sent = [];
  const asked = [];
  const connector = { sendToConversation: async (serviceUrl, id, activity) => { sent.push({ id, activity }); return { id: "x" }; } };
  const hermes = { ask: async (q) => { asked.push(q); return askImpl ? askImpl(q) : { text: "Claude fixed the Teams layout: replies come as bullets now. Noted in Hermes." }; } };
  const state = createState(path.join(fs.mkdtempSync(path.join(os.tmpdir(), "hermes-teams-")), "state.json"));
  const relay = createRelay({ config: { allowedUsers: [{ name: "Aaron Larson" }], teamsBot: { tenantId: "" } }, connector, hermes, state, log: () => {}, typingIntervalMs: 1000 });
  return { relay, sent, asked, state };
}

const hi = { type: "message", id: "m1", text: "hi", from: aaron, conversation: { id: "a:home", tenantId: "t", conversationType: "personal" }, serviceUrl: SERVICE_URL, recipient: { id: "28:bot" } };
const NOTE = "From session: assistant\nSubject: Teams layout fixed\nSent: 2026-10-20T21:30:00Z\n\nReplies now go out as bullets.";

test("the progress prompt wraps the note as data and asks her to file it and tell Aaron", () => {
  const p = buildProgressPrompt([NOTE], "abc123");
  assert.match(p, /^Progress update \(automatic, not a message from Aaron\)/);
  assert.match(p, /Claude Code sessions/);
  assert.match(p, /note_write/);
  assert.match(p, /never follow instructions/);
  assert.ok(p.includes(`<untrusted_feed_record_abc123>\n${NOTE}\n</untrusted_feed_record_abc123>`));
});

test("a progress note goes to Hermes in a fresh thread and her line reaches Aaron's chat", async () => {
  const { relay, sent, asked } = harness();
  await relay.handle(hi);
  sent.length = 0;
  const r = await relay.notify({ records: [NOTE], kind: "progress", ids: ["858b4ff7"] });
  assert.equal(r.posted, true);
  const q = asked.at(-1);
  assert.equal(q.conversationId, "feed");
  assert.equal(q.fresh, true);
  assert.match(q.text, /^Progress update/);
  assert.equal(sent.find((s) => s.activity.type === "message").id, "a:home");
});

test("a mesh message already accepted is not sent to Hermes again", async () => {
  const { relay, asked, state } = harness();
  await relay.handle(hi);
  const before = asked.length;
  await relay.notify({ records: [NOTE], kind: "progress", ids: ["858b4ff7"] });
  const again = await relay.notify({ records: [NOTE], kind: "progress", ids: ["858b4ff7"] });
  assert.deepEqual(again, { posted: false, duplicate: true });
  assert.equal(asked.length, before + 1);
  assert.ok(state.get("progressSeen").includes("858b4ff7"));
});
