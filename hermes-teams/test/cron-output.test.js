"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { parseCronOutput, formatCronOutput, createCronOutputWatcher } = require("../lib/cron-output");
const { createState } = require("../lib/state");

/** An output file as Hermes writes it (~/.hermes/cron/output/<job id>/<time>.md). */
const FILE = (response, name = "Scrum Prep Notes") =>
  `# Cron Job: ${name}\n\n**Job ID:** ebe61605a654\n**Run Time:** 2026-10-09 09:42:01\n**Schedule:** every tuesday, wednesday, friday 9am\n\n**Prompt Characters:** 12\n## Prompt\n\nDo the thing.\n\n**Response Characters:** ${response.length}\n## Response\n\n${response}\n`;

test("the parser finds the job name and the response, and recognizes silence and failure", () => {
  const p = parseCronOutput(FILE("### Brief\n* one\n* two"));
  assert.equal(p.name, "Scrum Prep Notes");
  assert.equal(p.response, "### Brief\n* one\n* two");
  assert.equal(p.silent, false);
  assert.equal(p.failed, false);
  assert.equal(formatCronOutput(p), "**Scrum Prep Notes**\n### Brief\n* one\n* two");
  assert.equal(parseCronOutput(FILE("[SILENT]")).silent, true);
  assert.equal(parseCronOutput(FILE("`[SILENT]`")).silent, true);
  assert.equal(parseCronOutput(FILE("")).silent, true);
  assert.equal(parseCronOutput("# Cron Job: X\n## Prompt\n\nDo the thing; the run died before writing a response.").silent, true, "no response section posts nothing");
  const f = parseCronOutput(FILE("[CRON_FAILURE]\nchild timed out", "Relay test"));
  assert.equal(f.failed, true);
  assert.equal(formatCronOutput(f), "**Relay test** failed:\nchild timed out");
  assert.equal(parseCronOutput("no header at all").name, "Scheduled job");
});

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "hermes-cron-"));
}
function write(dir, rel, text, mtimeMs) {
  const file = path.join(dir, rel);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text);
  if (mtimeMs) fs.utimesSync(file, mtimeMs / 1000, mtimeMs / 1000);
}
/** A watcher over `dir` with a clock the test moves by hand (settleMs 0 by default: one scan sees, the next posts). */
function harness(dir, { pollMs = 1000, settleMs = 0, startupGraceMs = 10 * 60_000, postImpl, now } = {}) {
  const posts = [];
  const logs = [];
  const state = createState(path.join(tmpDir(), "state.json"));
  let clock = Date.now();
  const w = createCronOutputWatcher({
    dir,
    state,
    pollMs,
    settleMs,
    startupGraceMs,
    now: now || (() => clock),
    log: (level, data) => logs.push({ level, ...data }),
    post: async (text) => {
      if (postImpl) await postImpl(text);
      posts.push(text);
    },
  });
  return { w, posts, logs, state, tick: (ms) => { clock += ms; } };
}

test("a new output file is posted once with the job name as its header; silent runs are not", async () => {
  const dir = tmpDir();
  const { w, posts, logs, state, tick } = harness(dir);
  await w.scan();
  write(dir, "job1/2026-10-09_09-42-01.md", FILE("the brief"));
  await w.scan();
  assert.equal(posts.length, 0, "first sight: pending until it settles");
  tick(10);
  await w.scan();
  assert.deepEqual(posts, ["**Scrum Prep Notes**\nthe brief"]);
  tick(10);
  await w.scan();
  assert.equal(posts.length, 1, "posted once");
  assert.deepEqual(state.get("postedOutputs"), ["job1/2026-10-09_09-42-01.md"]);
  write(dir, "job1/2026-10-09_10-00-00.md", FILE("[SILENT]"));
  await w.scan();
  tick(10);
  await w.scan();
  assert.equal(posts.length, 1);
  assert.ok(logs.some((l) => l.event === "cron-output" && l.posted === false && l.chars === 0));
  assert.ok(logs.some((l) => l.event === "cron-output" && l.posted === true && l.job === "Scrum Prep Notes" && l.chars === 9));
  assert.ok(!logs.some((l) => JSON.stringify(l).includes("the brief")), "logs never carry the text");
});

test("files already there at startup are never posted, except fresh ones the relay missed while down", async () => {
  const dir = tmpDir();
  write(dir, "job1/old.md", FILE("old brief"), Date.now() - 60 * 60_000);
  write(dir, "job1/fresh.md", FILE("fresh brief"), Date.now() - 60_000);
  const { w, posts, tick } = harness(dir);
  await w.scan();
  tick(10);
  await w.scan();
  assert.deepEqual(posts, ["**Scrum Prep Notes**\nfresh brief"]);
});

test("a file still being written waits until it settles; temp and hidden files are ignored", async () => {
  const dir = tmpDir();
  const { w, posts, tick } = harness(dir, { settleMs: 100 });
  await w.scan();
  write(dir, "job1/.output_tmp123", FILE("partial"));
  write(dir, "job1/run.md", "# Cron Job: Scrum Prep Notes\n");
  await w.scan();
  tick(50);
  await w.scan();
  assert.equal(posts.length, 0);
  write(dir, "job1/run.md", FILE("done"));
  await w.scan();
  tick(50);
  await w.scan();
  assert.equal(posts.length, 0, "the settle clock restarted when the file changed");
  tick(60);
  await w.scan();
  assert.deepEqual(posts, ["**Scrum Prep Notes**\ndone"]);
});

test("without a home conversation the file waits and goes out on a later scan; a failed job posts a failure line", async () => {
  const dir = tmpDir();
  let home = false;
  const { w, posts, logs, tick } = harness(dir, {
    postImpl: async () => {
      if (!home) throw Object.assign(new Error("No home conversation yet"), { status: 409 });
    },
  });
  await w.scan();
  write(dir, "job1/a.md", FILE("[CRON_FAILURE]\nchild failed", "Relay test"));
  await w.scan();
  tick(10);
  await w.scan();
  tick(10);
  await w.scan();
  assert.equal(posts.length, 0);
  assert.equal(logs.filter((l) => l.event === "cron-output-waiting").length, 1, "warned once");
  home = true;
  tick(10);
  await w.scan();
  assert.deepEqual(posts, ["**Relay test** failed:\nchild failed"]);
});

test("the posted list is capped at 500", async () => {
  const dir = tmpDir();
  const { w, state, tick } = harness(dir);
  await w.scan();
  for (let i = 0; i < 505; i++) write(dir, `job1/${String(i).padStart(4, "0")}.md`, FILE(`brief ${i}`));
  await w.scan();
  tick(10);
  await w.scan();
  assert.equal(state.get("postedOutputs").length, 500);
  assert.equal(state.get("postedOutputs")[499], "job1/0504.md");
});

test("start() posts a file written later, even when the folder appears after start", async () => {
  const root = tmpDir();
  const dir = path.join(root, "output");
  const { w, posts } = harness(dir, { pollMs: 20, settleMs: 5, now: Date.now });
  w.start();
  await new Promise((r) => setTimeout(r, 60));
  fs.mkdirSync(dir);
  write(dir, "job1/a.md", FILE("late"));
  for (let i = 0; i < 80 && posts.length === 0; i++) await new Promise((r) => setTimeout(r, 25));
  w.stop();
  assert.deepEqual(posts, ["**Scrum Prep Notes**\nlate"]);
});
