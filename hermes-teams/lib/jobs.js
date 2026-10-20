"use strict";
/**
 * Hermes's scheduled jobs due soon, read from her own job file (~/.hermes/cron/jobs.json, same user on the mini), so an
 * automated prompt can tell her "your Scrum Prep Notes job runs at 9:00" and she can leave the briefing to it.
 */
const fs = require("node:fs");
const { formatWhen } = require("./outbox");

const HORIZON_MS = 2 * 60 * 60 * 1000;
const PROMPT_CHARS = 300;
const RUNS_KEPT = 6;
/** Longer than any real run: a start further back than this belongs to some other run. */
const MAX_RUN_MS = 3 * 60 * 60 * 1000;

/** The job list from Hermes's file, or null when it cannot be read. */
function readJobList(file) {
  let data;
  try {
    data = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
  return Array.isArray(data) ? data : data && Array.isArray(data.jobs) ? data.jobs : [];
}

function readUpcomingJobs({ file, now = Date.now, horizonMs = HORIZON_MS } = {}) {
  const list = readJobList(file);
  if (!list) return { ok: false, jobs: [] };
  const t = now();
  const jobs = list
    .filter((j) => j && j.enabled !== false && (!j.state || j.state === "scheduled") && !j.paused_at)
    .map((j) => ({ id: String(j.id || ""), name: String(j.name || j.id || "Scheduled job"), nextRunAt: Date.parse(j.next_run_at), prompt: String(j.prompt || "") }))
    .filter((j) => Number.isFinite(j.nextRunAt) && j.nextRunAt > t && j.nextRunAt <= t + horizonMs)
    .sort((a, b) => a.nextRunAt - b.nextRunAt);
  return { ok: true, jobs };
}

function renderUpcomingJobs({ ok, jobs }, { timeZone, runs = () => [] } = {}) {
  if (!ok) return "Your scheduled jobs could not be read; if it matters, check with cronjob_manage {\"action\":\"list\"}.";
  if (!jobs.length) return "None of your scheduled jobs run in the next 2 hours.";
  const line = (j) => {
    const prompt = j.prompt.replace(/\s+/g, " ").trim();
    const took = runs(j.id);
    const timing = took.length ? ` (recent runs took ${took.join(", ")} min)` : "";
    return `- "${j.name}" at ${formatWhen(j.nextRunAt, timeZone)}${timing}: ${prompt.length > PROMPT_CHARS ? `${prompt.slice(0, PROMPT_CHARS - 1)}…` : prompt}`;
  };
  return ["Your scheduled jobs that run in the next 2 hours:", ...jobs.map(line)].join("\n");
}

/**
 * What each job is, by id, without its run bookkeeping (next/last run change on every run), or null when the file
 * cannot be read. Taken before and after each automated turn so a job Hermes removed or changed is always reported:
 * Aaron approved her fixing her own jobs on the condition that she says so (2026-10-13).
 */
function snapshotJobs({ file } = {}) {
  const list = readJobList(file);
  if (!list) return null;
  const out = {};
  for (const j of list) {
    if (!j || !j.id) continue;
    const schedule = j.schedule && typeof j.schedule === "object" ? j.schedule.expr || j.schedule.display || JSON.stringify(j.schedule) : j.schedule;
    const repeat = j.repeat && typeof j.repeat === "object" ? j.repeat : {};
    out[j.id] = {
      name: String(j.name || j.id),
      schedule: String(schedule || j.schedule_display || ""),
      prompt: String(j.prompt || ""),
      enabled: j.enabled !== false && !j.paused_at,
      state: String(j.state || ""),
      // A one-shot, or a job on its last repeat: the next run ends it (Hermes marks it completed or drops it).
      lastRun: Number.isInteger(repeat.times) && (repeat.completed || 0) + 1 >= repeat.times,
    };
  }
  return out;
}

/**
 * Each difference between two snapshots as { name, line }; nothing when either could not be read. A job that ended by
 * itself (a one-shot that fired, a last repeat, a run that failed) is not a change Hermes made.
 */
function jobChanges(before, after) {
  if (!before || !after) return [];
  const out = [];
  for (const [id, b] of Object.entries(before)) {
    const a = after[id];
    if (!a) {
      if (b.lastRun) continue;
      out.push({ name: b.name, line: `Removed my scheduled job "${b.name}".` });
      continue;
    }
    if (a.state === "completed" || a.state === "error") continue;
    if (b.enabled && !a.enabled) {
      out.push({ name: b.name, line: `Paused my scheduled job "${b.name}".` });
      continue;
    }
    const fields = ["schedule", "prompt"].filter((f) => a[f] !== b[f]);
    if (!b.enabled && a.enabled) fields.push("resumed");
    if (a.name !== b.name) fields.push(`now named "${a.name}"`);
    if (fields.length) out.push({ name: b.name, line: `Changed my scheduled job "${b.name}" (${fields.join(", ")}).` });
  }
  for (const [id, a] of Object.entries(after)) if (!before[id]) out.push({ name: a.name, line: `Added a scheduled job "${a.name}".` });
  return out;
}

/** When a job's run started (its last dispatch in Hermes's job file), or NaN when the file or the job is missing. */
function readJobStart({ file, jobId } = {}) {
  const job = (readJobList(file) || []).find((j) => j && j.id === jobId);
  return job && job.last_dispatch ? Date.parse(job.last_dispatch.dispatched_at) : NaN;
}

/** A run's finish time from its output file's name ("<job id>/2026-10-14_09-19-02.md", the mini's own zone), or NaN. */
function finishedAtFromKey(key) {
  const m = /(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})\.md$/.exec(String(key || ""));
  return m ? new Date(`${m[1]}T${m[2]}:${m[3]}:${m[4]}`).getTime() : NaN;
}

/**
 * How long each of Hermes's jobs took, last six runs per job (relay state "jobRuns"). Her runs share Puget with other
 * work: the 9:00 scrum brief took 42, 2, and 19 min on its first three runs and once landed a minute before the
 * meeting (2026-10-14). She sees these numbers when she reviews a run and in the jobs-due list, and plans from them.
 */
function createRunLog({ state }) {
  const all = () => state.get("jobRuns") || {};
  function record(jobId, { startedAt, finishedAt }) {
    if (!jobId || !Number.isFinite(startedAt) || !Number.isFinite(finishedAt)) return;
    if (startedAt > finishedAt || finishedAt - startedAt > MAX_RUN_MS) return;
    const runs = all();
    const list = (runs[jobId] || []).filter((r) => r.finishedAt !== finishedAt);
    runs[jobId] = [...list, { startedAt, finishedAt }].sort((a, b) => a.finishedAt - b.finishedAt).slice(-RUNS_KEPT);
    state.set("jobRuns", runs);
  }
  /** Each kept run's length in whole minutes (at least 1), oldest first. */
  const minutes = (jobId) => (all()[jobId] || []).map((r) => Math.max(1, Math.round((r.finishedAt - r.startedAt) / 60_000)));
  return { record, minutes };
}

const describeJobChanges = (before, after) => jobChanges(before, after).map((c) => c.line);

module.exports = { readUpcomingJobs, renderUpcomingJobs, snapshotJobs, jobChanges, describeJobChanges, readJobStart, finishedAtFromKey, createRunLog, HORIZON_MS };
