"use strict";
/**
 * Delivers the output of Hermes's own scheduled jobs. Hermes cron can post to its chat platforms (Telegram, Discord…)
 * but not to the API server the relay talks to, so a job Aaron asked for ("scrum prep every Tue/Wed/Fri") ran and its
 * brief sat in a file (edit-3, 2026-10-09). Every run writes ~/.hermes/cron/output/<job id>/<time>.md whatever its
 * delivery target; this module reads each new file and posts the response to Aaron's chat.
 */
const fs = require("node:fs");
const path = require("node:path");

const SILENT = "[SILENT]";
const FAILURE = "[CRON_FAILURE]";

/** One output file: the job's name from the first line, the text after the "## Response" heading. */
function parseCronOutput(text) {
  const lines = String(text || "").split(/\r?\n/);
  const named = /^#\s*Cron Job:\s*(.+?)\s*$/.exec(lines[0] || "");
  const name = named ? named[1] : "Scheduled job";
  const at = lines.findIndex((l) => /^##\s*Response\s*$/.test(l));
  const response = at === -1 ? "" : lines.slice(at + 1).join("\n").trim();
  const bare = response.replace(/[`*_\s]/g, "").toUpperCase();
  return { name, response, silent: !response || bare === SILENT, failed: response.startsWith(FAILURE) };
}

/** The Teams message for a parsed output: the job's name as a bold header line, then its words. */
function formatCronOutput({ name, response, failed }) {
  if (failed) return `**${name}** failed:\n${response.slice(FAILURE.length).trim()}`;
  return `**${name}**\n${response}`;
}

/**
 * Watches Hermes's cron output folder and posts each new file's response once.
 *   dir             ~/.hermes/cron/output (job folders inside; Hermes writes .output_* temp files, then renames)
 *   state           the relay's state (key postedOutputs)
 *   post(text)      async; rejects when there is nowhere to post yet (no home conversation) — the file then waits
 *   pollMs          full rescan interval; fs.watch is the fast path, the poll is the guarantee
 *   settleMs        a file is read once its size and mtime have held this long
 *   startupGraceMs  at start, files older than this are history and never posted; younger ones were missed while
 *                   the relay was down and are posted
 */
function createCronOutputWatcher({ dir, state, post, log = () => {}, pollMs = 60_000, settleMs = 2_000, startupGraceMs = 10 * 60_000, now = Date.now }) {
  const posted = new Set(state.get("postedOutputs") || []);
  const seen = new Set(posted);
  const pending = new Map(); // rel -> { size, mtimeMs, since, warned }
  let seeded = false;
  let timer = null;
  let watcher = null;
  let scanning = null;

  function remember(rel) {
    posted.add(rel);
    seen.add(rel);
    pending.delete(rel);
    state.set("postedOutputs", [...posted].slice(-500));
  }

  /** Every <job>/<file>.md, two levels deep, sorted by path. Throws when the folder is missing. */
  function list() {
    const out = [];
    for (const job of fs.readdirSync(dir, { withFileTypes: true })) {
      if (!job.isDirectory() || job.name.startsWith(".")) continue;
      const jobDir = path.join(dir, job.name);
      for (const entry of fs.readdirSync(jobDir, { withFileTypes: true })) {
        if (!entry.isFile() || entry.name.startsWith(".") || !entry.name.endsWith(".md")) continue;
        try {
          const stat = fs.statSync(path.join(jobDir, entry.name));
          out.push({ rel: `${job.name}/${entry.name}`, size: stat.size, mtimeMs: stat.mtimeMs });
        } catch {
          /* vanished between readdir and stat */
        }
      }
    }
    return out.sort((a, b) => a.rel.localeCompare(b.rel)); // readdir order is not stable across filesystems
  }

  function scan() {
    if (scanning) return scanning;
    scanning = (async () => {
      let files;
      try {
        files = list();
      } catch {
        return; // no folder yet: the poll keeps looking
      }
      const t = now();
      if (!seeded) {
        for (const f of files) if (t - f.mtimeMs > startupGraceMs) seen.add(f.rel);
        seeded = true;
      }
      const present = new Set(files.map((f) => f.rel));
      for (const rel of [...pending.keys()]) if (!present.has(rel)) pending.delete(rel);
      for (const f of files) {
        if (seen.has(f.rel)) continue;
        const p = pending.get(f.rel);
        if (!p || p.size !== f.size || p.mtimeMs !== f.mtimeMs) {
          pending.set(f.rel, { size: f.size, mtimeMs: f.mtimeMs, since: t, warned: false });
          continue;
        }
        if (t - p.since < settleMs) continue;
        let text;
        try {
          text = fs.readFileSync(path.join(dir, f.rel), "utf8");
        } catch {
          continue;
        }
        const parsed = parseCronOutput(text);
        if (parsed.silent) {
          remember(f.rel);
          log("info", { event: "cron-output", job: parsed.name, chars: 0, posted: false });
          continue;
        }
        try {
          await post(formatCronOutput(parsed));
          remember(f.rel);
          log("info", { event: "cron-output", job: parsed.name, chars: parsed.response.length, posted: true });
        } catch (err) {
          if (!p.warned) {
            p.warned = true;
            log("warn", { event: "cron-output-waiting", job: parsed.name, message: err.message });
          }
        }
      }
    })().finally(() => {
      scanning = null;
    });
    return scanning;
  }

  function arm() {
    if (watcher) return;
    try {
      watcher = fs.watch(dir, { recursive: true }, () => schedule(settleMs + 50));
      watcher.on("error", () => {
        watcher = null;
      });
    } catch {
      watcher = null; // no folder yet; the next poll tries again
    }
  }

  function schedule(ms) {
    if (timer) clearTimeout(timer);
    timer = setTimeout(async () => {
      timer = null;
      arm();
      await scan();
      if (!timer) schedule(pending.size ? settleMs : pollMs);
    }, ms);
    if (timer.unref) timer.unref();
  }

  return {
    start() {
      arm();
      schedule(0);
    },
    stop() {
      if (timer) clearTimeout(timer);
      timer = null;
      if (watcher) watcher.close();
      watcher = null;
    },
    scan,
  };
}

module.exports = { parseCronOutput, formatCronOutput, createCronOutputWatcher, SILENT, FAILURE };
