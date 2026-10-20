"use strict";
/**
 * 2026-10-14: Aaron asked for his scrum notes at 8:38, asked again at 8:43 because nothing had come back yet (the first
 * answer took 5 min behind Puget's queue), got the same notes twice, then got them a third time from the 9:00 job.
 */
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { createRelay, buildContextSection } = require("../lib/relay");
const { createOutbox } = require("../lib/outbox");
const { parseCronOutput } = require("../lib/cron-output");
const { createState } = require("../lib/state");

const SERVICE_URL = "https://smba.trafficmanager.net/amer/";
const aaron = { id: "29:abc", name: "Aaron Larson", aadObjectId: "aad-aaron" };
const message = (text) => ({ type: "message", id: "m1", text, from: aaron, conversation: { id: "a:home", tenantId: "t-1", conversationType: "personal" }, serviceUrl: SERVICE_URL, recipient: { id: "28:bot" } });
const stateFile = () => path.join(fs.mkdtempSync(path.join(os.tmpdir(), "resend-")), "state.json");
// Wed Oct 14 2026, 8:38 AM in Chicago.
const T0 = Date.parse("2026-10-14T13:38:00Z");

function harness(askImpl) {
  let clock = T0;
  const sent = [];
  const asked = [];
  const connector = { sendToConversation: async (serviceUrl, id, activity) => { if (activity.type === "message") sent.push(activity.text); return { id: "x" }; } };
  const hermes = { ask: async (q) => { asked.push(q); return askImpl(q); } };
  const state = createState(stateFile());
  const relay = createRelay({ config: { allowedUsers: [{ name: "Aaron Larson" }], teamsBot: { tenantId: "" } }, connector, hermes, state, typingIntervalMs: 1000, timeZone: "America/Chicago", now: () => clock });
  return { relay, sent, asked, state, tick: (ms) => { clock += ms; } };
}

test("a message sent while Hermes is still answering the previous one tells her so, quoting it, so a repeat gets one line", async () => {
  let release;
  const gate = new Promise((r) => { release = r; });
  const { relay, asked, tick } = harness(async (q) => {
    if (q.text.startsWith("Send me my scrum notes early")) {
      await gate;
      tick(60_000);
      return { text: "Here are your scrum notes: …" };
    }
    return { text: "That's my message just above." };
  });
  const first = relay.handle(message("Send me my scrum notes early"));
  await new Promise((r) => setImmediate(r));
  tick(4 * 60_000 + 30_000);
  const second = relay.handle(message("Send me the scum notes"));
  release();
  await Promise.all([first, second]);
  assert.equal(asked.length, 2);
  assert.ok(!/while you were still answering/.test(asked[0].text), "the first message carries no such note");
  const p = asked[1].text;
  assert.match(p, /^Send me the scum notes\n/);
  assert.match(p, /sent this at Wed 8:42 AM, while you were still answering his previous message \("Send me my scrum notes early", Wed 8:38 AM\)/);
  assert.match(p, /Your answer to that reached him at Wed 8:43 AM/);
  assert.match(p, /If this asks for the same thing, do not send it again/);
});

test("a message sent after the previous answer arrived is an ordinary message", async () => {
  const { relay, asked, tick } = harness(async () => ({ text: "notes" }));
  await relay.handle(message("Send me my scrum notes"));
  tick(60_000);
  await relay.handle(message("Send me my scrum notes"));
  assert.ok(!/while you were still answering/.test(asked[1].text));
});

test("a message sent while the previous one failed is an ordinary message (nothing reached him)", async () => {
  let release;
  const gate = new Promise((r) => { release = r; });
  let n = 0;
  const { relay, asked } = harness(async () => {
    if (n++ === 0) {
      await gate;
      throw new Error("Hermes timed out");
    }
    return { text: "notes" };
  });
  const first = relay.handle(message("notes?"));
  await new Promise((r) => setImmediate(r));
  const second = relay.handle(message("notes?"));
  release();
  await Promise.all([first, second]);
  assert.ok(!/while you were still answering/.test(asked[1].text));
});

test("what Aaron already got keeps a whole chat answer, and every automated prompt says what time it is", async () => {
  const notes = `**What I worked on:**\n${"- a line about the week\n".repeat(40)}**Hurdles:**\n- Interprefy decision for this weekend`;
  assert.ok(notes.length > 1_000);
  const { relay, asked, tick } = harness(async (q) => ({ text: q.text.startsWith("Job review") ? "NO_MESSAGE" : notes }));
  await relay.handle(message("Send me my scrum notes"));
  tick(42 * 60_000);
  await relay.deliverScheduled(parseCronOutput("# Cron Job: Scrum Prep Notes\n\n## Prompt\n\nDo it.\n\n## Response\n\nScrum prep: Interprefy decision\n"));
  const review = asked.at(-1).text;
  assert.match(review, /Interprefy decision for this weekend/, "the end of a long chat answer is still in the record");
  assert.match(review, /It is now Wed 9:20 AM\./);
  assert.match(buildContextSection({ sent: "s", jobs: "j", now: "Wed 9:20 AM" }, "abc"), /It is now Wed 9:20 AM\./);
});

test("the record still has a budget: newest kept, oldest dropped, one entry never more than it stored", () => {
  let clock = T0;
  const box = createOutbox({ state: createState(stateFile()), now: () => clock, timeZone: "America/Chicago" });
  for (let i = 0; i < 20; i++) {
    box.record({ source: "chat", text: `${i} ${"x".repeat(5_000)}` });
    clock += 1_000;
  }
  const r = box.render();
  assert.ok(r.length <= 12_000 + 200, `section is ${r.length} chars`);
  assert.ok(r.includes("(chat): 19 "));
  assert.ok(!r.includes("(chat): 0 "));
});
