"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { readUpcomingJobs, renderUpcomingJobs } = require("../lib/jobs");

const TZ = "America/Chicago";
const NOW = Date.parse("2026-10-13T13:46:00Z"); // Tue 8:46 AM CDT
const job = (name, next, extra = {}) => ({ id: name.toLowerCase().replace(/\W/g, ""), name, prompt: `Prompt for ${name}. ${"word ".repeat(100)}`, enabled: true, state: "scheduled", paused_at: null, next_run_at: next, ...extra });
function file(data) {
  const f = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "jobs-")), "jobs.json");
  fs.writeFileSync(f, typeof data === "string" ? data : JSON.stringify(data));
  return f;
}

test("lists enabled, scheduled jobs due in the next two hours, soonest first", () => {
  const f = file({ jobs: [
    job("Nightly notes tidy", "2026-10-13T23:00:00-05:00"),
    job("Scrum Prep Notes", "2026-10-13T09:00:00-05:00"),
    job("Paused one", "2026-10-13T09:10:00-05:00", { state: "paused", paused_at: "2026-10-12T10:00:00-05:00" }),
    job("Disabled one", "2026-10-13T09:20:00-05:00", { enabled: false }),
    job("Early reminder", "2026-10-13T08:50:00-05:00"),
    job("Already past", "2026-10-13T08:00:00-05:00"),
    job("No next run", null),
  ], updated_at: "x" });
  const r = readUpcomingJobs({ file: f, now: () => NOW });
  assert.equal(r.ok, true);
  assert.deepEqual(r.jobs.map((j) => j.name), ["Early reminder", "Scrum Prep Notes"]);
  const text = renderUpcomingJobs(r, { timeZone: TZ });
  assert.match(text, /^Your scheduled jobs that run in the next 2 hours:/);
  assert.match(text, /- "Scrum Prep Notes" at Tue 9:00 AM: Prompt for Scrum Prep Notes\./);
  assert.ok(text.split("\n").every((l) => l.length <= 360), "prompts are cut");
});

test("nothing due, a missing file, and a corrupt file each say so without throwing", () => {
  assert.equal(renderUpcomingJobs(readUpcomingJobs({ file: file({ jobs: [] }), now: () => NOW })), "None of your scheduled jobs run in the next 2 hours.");
  const missing = readUpcomingJobs({ file: "/nonexistent/jobs.json", now: () => NOW });
  assert.deepEqual(missing, { ok: false, jobs: [] });
  assert.match(renderUpcomingJobs(missing), /could not be read/);
  assert.equal(readUpcomingJobs({ file: file("{not json"), now: () => NOW }).ok, false);
  assert.equal(readUpcomingJobs({ file: file([job("Bare list", "2026-10-13T09:30:00-05:00")]), now: () => NOW }).jobs.length, 1, "a bare array is read too");
});
