"use strict";
/**
 * 2026-10-14: the 9:00 "Scrum Prep Notes" job finished at 9:19 for a 9:20 meeting (its runs have taken 42, 2, and 19 min
 * on a shared Puget). Hermes is told how long her jobs take so she can schedule them early enough herself.
 */
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { createRelay, buildScheduledPrompt } = require("../lib/relay");
const { createRunLog, finishedAtFromKey, readJobStart, renderUpcomingJobs } = require("../lib/jobs");
const { parseCronOutput } = require("../lib/cron-output");
const { createState } = require("../lib/state");

const SERVICE_URL = "https://smba.trafficmanager.net/amer/";
const aaron = { id: "29:abc", name: "Aaron Larson", aadObjectId: "aad-aaron" };
const message = (text) => ({ type: "message", id: "m1", text, from: aaron, conversation: { id: "a:home", tenantId: "t-1", conversationType: "personal" }, serviceUrl: SERVICE_URL, recipient: { id: "28:bot" } });
const tmpDir = () => fs.mkdtempSync(path.join(os.tmpdir(), "job-timing-"));
const local = (s) => new Date(s).getTime(); // no offset: the machine's own zone, as the output file names are
const OUTPUT = "# Cron Job: Scrum Prep Notes\n\n## Prompt\n\nDo it.\n\n## Response\n\nScrum brief\n";

test("an output file's name is its finish time; the job file gives the run's start", () => {
  assert.equal(finishedAtFromKey("ebe61605a654/2026-10-14_09-19-02.md"), local("2026-10-14T09:19:02"));
  assert.ok(Number.isNaN(finishedAtFromKey("ebe61605a654/notes.md")));
  const file = path.join(tmpDir(), "jobs.json");
  fs.writeFileSync(file, JSON.stringify({ jobs: [{ id: "ebe61605a654", last_dispatch: { dispatched_at: "2026-10-14T09:00:43.413127-05:00" } }] }));
  assert.equal(readJobStart({ file, jobId: "ebe61605a654" }), Date.parse("2026-10-14T09:00:43.413-05:00"));
  assert.ok(Number.isNaN(readJobStart({ file, jobId: "other" })));
  assert.ok(Number.isNaN(readJobStart({ file: path.join(tmpDir(), "missing.json"), jobId: "ebe61605a654" })));
});

test("the run log keeps each job's last six runs, once each, and drops a start that is not this run's", () => {
  const log = createRunLog({ state: createState(path.join(tmpDir(), "state.json")) });
  const start = local("2026-10-14T09:00:00");
  log.record("a", { startedAt: start, finishedAt: start + 19 * 60_000 });
  log.record("a", { startedAt: start, finishedAt: start + 19 * 60_000 }); // the same output delivered again
  log.record("a", { startedAt: start + 30 * 60_000, finishedAt: start + 20 * 60_000 }); // next run already dispatched
  log.record("a", { startedAt: NaN, finishedAt: start });
  assert.deepEqual(log.minutes("a"), [19]);
  for (let i = 1; i <= 8; i++) log.record("a", { startedAt: start + i * 86_400_000, finishedAt: start + i * 86_400_000 + i * 60_000 });
  assert.deepEqual(log.minutes("a"), [3, 4, 5, 6, 7, 8]);
  assert.deepEqual(log.minutes("unknown"), []);
});

test("the jobs-due list says how long each job's runs have taken", () => {
  const r = renderUpcomingJobs({ ok: true, jobs: [{ id: "a", name: "Scrum Prep Notes", nextRunAt: local("2026-10-16T09:00:00"), prompt: "Brief" }] }, { timeZone: "America/Chicago", runs: () => [42, 2, 19] });
  assert.match(r, /"Scrum Prep Notes" at Fri 9:00 AM \(recent runs took 42, 2, 19 min\): Brief/);
});

test("the review prompt gives the run's start, finish, past run times, and how to move the job", () => {
  const p = buildScheduledPrompt({ name: "Scrum Prep Notes", response: "brief", jobId: "ebe61605a654" }, null, "abc", { started: "Wed 9:00 AM", finished: "Wed 9:19 AM", took: 19, minutes: [42, 2, 19], reviewing: "Wed 9:20 AM" });
  assert.match(p, /This run started at Wed 9:00 AM and finished at Wed 9:19 AM \(19 min\); you are reviewing it at Wed 9:20 AM\./);
  assert.match(p, /Its recent runs took 42, 2, 19 min/);
  assert.match(p, /cronjob_manage \{"action":"update","job_id":"ebe61605a654","schedule":"<new schedule>"\}/);
  const q = buildScheduledPrompt({ name: "x", response: "brief", jobId: "j" }, null, "abc", { started: null, finished: "Wed 9:19 AM", minutes: [], reviewing: "Wed 9:20 AM" });
  assert.match(q, /This run finished at Wed 9:19 AM; you are reviewing it at Wed 9:20 AM\./);
  assert.ok(!/recent runs took/.test(q));
});

test("a job review records the run and carries its timing", async () => {
  const dir = tmpDir();
  const jobsFile = path.join(dir, "jobs.json");
  fs.writeFileSync(jobsFile, JSON.stringify({ jobs: [{ id: "ebe61605a654", last_dispatch: { dispatched_at: new Date(local("2026-10-14T09:00:43")).toISOString() } }] }));
  const asked = [];
  const connector = { sendToConversation: async () => ({ id: "x" }) };
  const hermes = { ask: async (q) => { asked.push(q); return { text: q.text.startsWith("Job review") ? "NO_MESSAGE" : "hi" }; } };
  const state = createState(path.join(dir, "state.json"));
  state.set("jobRuns", { ebe61605a654: [{ startedAt: local("2026-10-09T09:00:00"), finishedAt: local("2026-10-09T09:42:01") }] });
  const relay = createRelay({ config: { allowedUsers: [{ name: "Aaron Larson" }], teamsBot: { tenantId: "" } }, connector, hermes, state, typingIntervalMs: 1000, timeZone: "America/Chicago", now: () => local("2026-10-14T09:20:00"), jobStart: (id) => readJobStart({ file: jobsFile, jobId: id }) });
  await relay.handle(message("hi"));
  await relay.deliverScheduled({ ...parseCronOutput(OUTPUT), key: "ebe61605a654/2026-10-14_09-19-02.md", jobId: "ebe61605a654" });
  const p = asked.at(-1).text;
  assert.match(p, /started at Wed 9:00 AM and finished at Wed 9:19 AM \(18 min\); you are reviewing it at Wed 9:20 AM/);
  assert.match(p, /Its recent runs took 42, 18 min/);
  assert.deepEqual(state.get("jobRuns").ebe61605a654.length, 2);
});
