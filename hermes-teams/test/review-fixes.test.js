"use strict";
/** Findings from the whole-change review of the one-update relay (2026-10-13), each pinned by a test. */
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { createRelay } = require("../lib/relay");
const { parseCronOutput } = require("../lib/cron-output");
const { describeJobChanges } = require("../lib/jobs");
const { createState } = require("../lib/state");

const SERVICE_URL = "https://smba.trafficmanager.net/amer/";
const aaron = { id: "29:abc", name: "Aaron Larson", aadObjectId: "aad-aaron" };
const OUTPUT = (response, name = "Scrum Prep Notes", key = "ebe6/2026-10-13_09-01-57.md") =>
  ({ ...parseCronOutput(`# Cron Job: ${name}\n\n## Response\n\n${response}\n`), key, jobId: key.split("/")[0] });
const message = (text) => ({ type: "message", id: "m1", text, from: aaron, conversation: { id: "a:home", tenantId: "t-1", conversationType: "personal" }, serviceUrl: SERVICE_URL, recipient: { id: "28:bot" } });

function harness({ askImpl, jobs, snapshots, failSend } = {}) {
  const sent = [];
  const asked = [];
  const logs = [];
  const connector = { sendToConversation: async (serviceUrl, id, activity) => {
    if (activity.type !== "message") return { id: "t" };
    if (failSend && failSend(activity.text)) throw new Error("Bot Framework 503");
    sent.push(activity.text);
    return { id: "x" };
  } };
  const hermes = { ask: async (q) => { asked.push(q); return askImpl ? askImpl(q) : { text: "a reply" }; } };
  const state = createState(path.join(fs.mkdtempSync(path.join(os.tmpdir(), "review-fixes-")), "state.json"));
  let snap = 0;
  const relay = createRelay({
    config: { allowedUsers: [{ name: "Aaron Larson" }], teamsBot: { tenantId: "" } }, connector, hermes, state,
    log: (level, data) => logs.push({ level, ...data }), typingIntervalMs: 1000, timeZone: "America/Chicago",
    upcomingJobs: () => jobs || { ok: true, jobs: [] },
    jobSnapshot: () => (snapshots ? snapshots[Math.min(snap++, snapshots.length - 1)] : null),
  });
  return { relay, sent, asked, logs, state };
}
const reviewing = (q) => q.text.startsWith("Job review");

test("a Teams failure after the review retries the send only: no second review", async () => {
  let down = true;
  const { relay, sent, asked } = harness({ askImpl: (q) => ({ text: reviewing(q) ? "Scrum is cancelled today." : "a reply" }), failSend: (t) => down && t.startsWith("**Scrum") });
  await relay.handle(message("hi"));
  await assert.rejects(relay.deliverScheduled(OUTPUT("brief")), /503/);
  assert.equal(asked.filter(reviewing).length, 1);
  down = false;
  assert.deepEqual(await relay.deliverScheduled(OUTPUT("brief")), { posted: true });
  assert.equal(asked.filter(reviewing).length, 1, "the reviewed text was kept and only the send was retried");
  assert.equal(sent.at(-1), "**Scrum Prep Notes**\n\nScrum is cancelled today.");
});

test("a placeholder answer is not a review: the raw output goes out", async () => {
  const { relay, sent, logs } = harness({ askImpl: (q) => (reviewing(q) ? { text: "Hermes had no answer.", empty: true } : { text: "a reply" }) });
  await relay.handle(message("hi"));
  await relay.deliverScheduled(OUTPUT("the real brief"));
  assert.equal(sent.at(-1), "**Scrum Prep Notes**\n\nthe real brief");
  assert.ok(logs.some((l) => l.event === "scheduled-review-failed"));
});

test("[SILENT] is silence for a review and for a feed event, and the review prompt is not a scheduled-job prompt", async () => {
  const { relay, sent, asked } = harness({ askImpl: (q) => ({ text: q.text.startsWith("hi") ? "a reply" : "`[SILENT]`" }) });
  await relay.handle(message("hi"));
  const before = sent.length;
  assert.deepEqual(await relay.deliverScheduled(OUTPUT("brief")), { posted: false });
  assert.deepEqual(await relay.notify({ records: ["Calendar event, updated"] }), { posted: false });
  assert.equal(sent.length, before);
  assert.match(asked[1].text, /^Job review \(automatic, not a message from Aaron\)/);
});

test("a reminder is not suppressed by its own next run: the job under review is left out of the jobs due, and reminders may repeat", async () => {
  const jobs = { ok: true, jobs: [
    { id: "ebe6", name: "Call Danny", nextRunAt: Date.now() + 30 * 60_000, prompt: "Reminder for Aaron: call Danny" },
    { id: "other", name: "Scrum Prep Notes", nextRunAt: Date.now() + 60 * 60_000, prompt: "Scrum brief" },
  ] };
  const { relay, asked } = harness({ jobs });
  await relay.handle(message("hi"));
  await relay.deliverScheduled(OUTPUT("Reminder: call Danny", "Call Danny"));
  const p = asked.at(-1).text;
  assert.ok(!p.includes("\"Call Danny\" at "), "its own next run is not 'a job that will cover this'");
  assert.match(p, /"Scrum Prep Notes" at /);
  assert.match(p, /A reminder repeats by design/);
});

test("a job Hermes removed or changed is always reported, even when she answers NO_MESSAGE or times out", async () => {
  const before = { ebe6: { name: "Scrum Prep Notes", schedule: "0 9 * * 2,3,5", prompt: "brief", enabled: true }, r1: { name: "Call Danny", schedule: "every 30m", prompt: "x", enabled: true } };
  const after = { r1: { name: "Call Danny", schedule: "every 1h", prompt: "x", enabled: true } };
  assert.deepEqual(describeJobChanges(before, after), ["Removed my scheduled job \"Scrum Prep Notes\".", "Changed my scheduled job \"Call Danny\" (schedule)."]);
  assert.deepEqual(describeJobChanges(null, after), []);
  // A one-shot (or a job on its last repeat) that fires during the turn ends by itself: Hermes marks it completed or
  // drops it. That is not something she changed.
  const once = { o1: { name: "Remind me at 3", schedule: "2026-10-13T15:00:00", prompt: "x", enabled: true, state: "scheduled", lastRun: true } };
  assert.deepEqual(describeJobChanges(once, { o1: { ...once.o1, enabled: false, state: "completed" } }), []);
  assert.deepEqual(describeJobChanges(once, {}), []);
  assert.deepEqual(describeJobChanges(before, { ...after, ebe6: { ...before.ebe6, enabled: false, state: "error" } }), ["Changed my scheduled job \"Call Danny\" (schedule)."], "a job that failed is not one she paused");

  const silent = harness({ snapshots: [before, after], askImpl: (q) => ({ text: reviewing(q) ? "NO_MESSAGE" : "a reply" }) });
  await silent.relay.handle(message("hi"));
  silent.state; // the chat turn took no snapshot
  assert.deepEqual(await silent.relay.deliverScheduled(OUTPUT("brief")), { posted: true });
  assert.equal(silent.sent.at(-1), "**Scrum Prep Notes**\n\nRemoved my scheduled job \"Scrum Prep Notes\".\n\nChanged my scheduled job \"Call Danny\" (schedule).");

  const mixed = harness({ snapshots: [before, after], askImpl: (q) => ({ text: reviewing(q) ? "NO_MESSAGE\nRemoved the Scrum Prep Notes job; meeting prep covers scrum." : "a reply" }) });
  await mixed.relay.handle(message("hi"));
  await mixed.relay.deliverScheduled(OUTPUT("brief"));
  assert.equal(mixed.sent.at(-1), "**Scrum Prep Notes**\n\nRemoved the Scrum Prep Notes job; meeting prep covers scrum.\n\nChanged my scheduled job \"Call Danny\" (schedule).", "a stray NO_MESSAGE line is dropped and a change she named is not repeated");

  const down = harness({ snapshots: [before, after], askImpl: (q) => { if (reviewing(q)) throw new Error("Hermes timed out"); return { text: "a reply" }; } });
  await down.relay.handle(message("hi"));
  await down.relay.deliverScheduled(OUTPUT("brief"));
  assert.match(down.sent.at(-1), /^\*\*Scrum Prep Notes\*\*\n\nbrief\n\nRemoved my scheduled job "Scrum Prep Notes"\./);
});

/**
 * Live test 2026-10-13: in the shared "feed" thread, a job review answered with a calendar line from the day before
 * ("Creative Crossover moved to 9:30 AM Wednesdays") under the job's name. Each automated prompt now starts fresh; the
 * context block carries what Aaron already got.
 */
test("feed events, meeting prep, and job reviews each start a fresh Hermes conversation; Aaron's chat keeps its thread", async () => {
  const { relay, asked } = harness();
  await relay.handle(message("hi"));
  await relay.notify({ records: ["Calendar event, updated"] });
  await relay.notify({ records: ["Meeting prep: Scrum"], kind: "meeting" });
  await relay.deliverScheduled(OUTPUT("brief"));
  assert.deepEqual(asked.map((q) => !!q.fresh), [false, true, true, true]);
});
