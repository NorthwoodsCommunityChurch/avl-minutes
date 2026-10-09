"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { createRelay } = require("../lib/relay");
const { createState } = require("../lib/state");

const SERVICE_URL = "https://smba.trafficmanager.net/amer/";
const aaron = { id: "29:abc", name: "Aaron Larson", aadObjectId: "aad-aaron" };

function tmpFile() {
  return path.join(fs.mkdtempSync(path.join(os.tmpdir(), "hermes-teams-")), "state.json");
}

function harness({ allowedUsers = [{ name: "Aaron Larson" }], askImpl, tenantId = "" } = {}) {
  const sent = [];
  const asked = [];
  const logs = [];
  const connector = {
    sendToConversation: async (serviceUrl, id, activity) => {
      sent.push({ serviceUrl, id, activity });
      return { id: "x" };
    },
  };
  const hermes = {
    ask: async (q) => {
      asked.push(q);
      return askImpl ? askImpl(q) : { text: "The answer" };
    },
  };
  const state = createState(tmpFile());
  const relay = createRelay({ config: { allowedUsers, teamsBot: { tenantId } }, connector, hermes, state, log: (level, data) => logs.push({ level, ...data }), typingIntervalMs: 1000 });
  return { relay, sent, asked, state, logs };
}

function message(text, from = aaron, conv = "a:conv1") {
  return { type: "message", id: "m1", text, from, conversation: { id: conv, tenantId: "tenant-1" }, serviceUrl: SERVICE_URL, recipient: { id: "28:bot" } };
}

test("a stranger is refused without reaching Hermes", async () => {
  const { relay, sent, asked, logs } = harness();
  await relay.handle(message("hi", { id: "29:x", name: "Someone Else", aadObjectId: "aad-x" }));
  assert.equal(asked.length, 0);
  assert.match(sent[0].activity.text, /private/);
  assert.ok(logs.some((l) => l.event === "refused" && l.aadObjectId === "aad-x"));
});

test("Aaron's message is answered after typing, in the same conversation", async () => {
  const { relay, sent, asked, state, logs } = harness();
  await relay.handle(message("find my notes about projectors"));
  assert.equal(asked[0].conversationId, "a:conv1");
  assert.ok(asked[0].text.startsWith("find my notes about projectors\n\n[Relay note"), "Aaron's words first, then the relay note");
  assert.ok(sent.some((s) => s.activity.type === "typing"));
  const reply = sent.find((s) => s.activity.type === "message");
  assert.equal(reply.activity.text, "The answer");
  assert.equal(reply.activity.textFormat, "markdown");
  assert.equal(reply.id, "a:conv1");
  assert.equal(reply.serviceUrl, SERVICE_URL);
  assert.equal(state.get("tenantId"), "tenant-1");
  assert.equal(state.get("serviceUrl"), SERVICE_URL);
  assert.ok(logs.some((l) => l.event === "answered" && l.aadObjectId === "aad-aaron"));
  assert.ok(!logs.some((l) => JSON.stringify(l).includes("projectors")), "log lines never carry message text");
});

test("a pinned aadObjectId wins over a matching name", async () => {
  const { relay, asked } = harness({ allowedUsers: [{ aadObjectId: "aad-other" }] });
  await relay.handle(message("hi"));
  assert.equal(asked.length, 0);
});

test("/new forgets the conversation and /help explains", async () => {
  const { relay, sent, asked, state } = harness();
  state.setResponse("a:conv1", "resp_1");
  await relay.handle(message("/new"));
  assert.equal(asked.length, 0);
  assert.equal(state.getResponse("a:conv1"), null);
  assert.match(sent[0].activity.text, /fresh/i);
  await relay.handle(message("/help"));
  assert.match(sent[1].activity.text, /\/new/);
  assert.equal(asked.length, 0);
});

test("a Hermes failure becomes an apology", async () => {
  const { relay, sent } = harness({ askImpl: async () => { throw new Error("connect ECONNREFUSED"); } });
  await relay.handle(message("hello"));
  const reply = sent.find((s) => s.activity.type === "message");
  assert.match(reply.activity.text, /couldn't answer.*ECONNREFUSED/);
});

test("messages are processed one at a time, in order", async () => {
  const order = [];
  let release;
  const { relay } = harness({
    askImpl: async (q) => {
      const words = q.text.split("\n")[0]; // Aaron's line; the relay note follows it
      order.push(`start ${words}`);
      if (words === "one") await new Promise((r) => { release = r; });
      order.push(`end ${words}`);
      return { text: "ok" };
    },
  });
  const p1 = relay.handle(message("one"));
  await new Promise((r) => setTimeout(r, 5));
  const p2 = relay.handle(message("two"));
  await new Promise((r) => setTimeout(r, 5));
  assert.deepEqual(order, ["start one"]);
  release();
  await Promise.all([p1, p2]);
  assert.deepEqual(order, ["start one", "end one", "start two", "end two"]);
});

test("the bot greets when added to a chat", async () => {
  const { relay, sent } = harness();
  await relay.handle({ type: "conversationUpdate", membersAdded: [{ id: "28:bot" }], recipient: { id: "28:bot" }, conversation: { id: "a:conv1" }, serviceUrl: SERVICE_URL });
  assert.match(sent[0].activity.text, /Hi Aaron/);
});

test("long answers are split into several messages and empty text is ignored", async () => {
  const long = Array.from({ length: 30 }, (_, i) => `Paragraph ${i} ${"y".repeat(1000)}`).join("\n\n");
  const { relay, sent, asked } = harness({ askImpl: async () => ({ text: long }) });
  await relay.handle(message("long one"));
  const msgs = sent.filter((s) => s.activity.type === "message");
  assert.ok(msgs.length >= 2);
  assert.ok(msgs.every((m) => m.activity.text.length <= 25000));
  await relay.handle(message("   "));
  assert.equal(asked.length, 1);
});

test("a name match pins the account id: the same name from another account is refused afterwards", async () => {
  const { relay, asked, sent, state } = harness();
  await relay.handle(message("first"));
  assert.equal(asked.length, 1);
  assert.equal(state.get("pins")["aaron larson"], "aad-aaron");
  await relay.handle(message("second", { id: "29:imp", name: "Aaron Larson", aadObjectId: "aad-impostor" }));
  assert.equal(asked.length, 1);
  assert.match(sent[sent.length - 1].activity.text, /private/);
});

test("messages from another tenant are refused and teach the relay nothing", async () => {
  const { relay, asked, state, logs } = harness();
  await relay.handle(message("hello"));
  assert.equal(state.get("tenantId"), "tenant-1");
  const foreign = message("hi", aaron);
  foreign.conversation = { id: "a:other", tenantId: "tenant-2" };
  foreign.serviceUrl = "https://smba.trafficmanager.net/emea/";
  await relay.handle(foreign);
  assert.equal(asked.length, 1);
  assert.equal(state.get("tenantId"), "tenant-1");
  assert.equal(state.get("serviceUrl"), SERVICE_URL);
  assert.ok(logs.some((l) => l.event === "refused" && l.reason === "tenant"));
});

test("a stranger's message teaches the relay nothing", async () => {
  const { relay, state } = harness();
  await relay.handle(message("hi", { id: "29:x", name: "Someone Else", aadObjectId: "aad-x" }));
  assert.equal(state.get("tenantId"), null);
  assert.equal(state.get("serviceUrl"), null);
});

test("a configured tenant id is enforced from the first message", async () => {
  const { relay, asked } = harness({ tenantId: "tenant-9" });
  await relay.handle(message("hello"));
  assert.equal(asked.length, 0);
});

test("every message to Hermes carries the relay note after Aaron's own words, exactly once, unwrapped", () => {
  const { buildAaronPrompt } = require("../lib/relay");
  const p = buildAaronPrompt("I need to email Danny about the ticket");
  assert.ok(p.startsWith("I need to email Danny about the ticket\n\n[Relay note, not from Aaron."));
  assert.match(p, /create its card on the To Do board first/);
  assert.match(p, /search mail, teams, and notes for it first/);
  assert.equal(p.split("[Relay note").length, 2);
  assert.ok(!p.includes("untrusted_feed_record"));
});
