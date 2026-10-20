"use strict";
/**
 * What the relay posted to Aaron's 1:1 chat in the last 12 hours, so Hermes can see what he already has before she
 * sends him anything on her own. Three paths used to post without knowing about each other: on 2026-10-13 he got the
 * automatic meeting prep at 8:46 and the "Scrum Prep Notes" job at 9:02 for the same 9:20 meeting.
 */
const WINDOW_MS = 12 * 60 * 60 * 1000;
const MAX_ENTRIES = 40;
// A whole chat answer fits (Hermes's are ~1.5K). At 700 an entry showed only the first half of the scrum notes he had
// asked for, so the 9:00 job's brief looked new and he got them a third time (2026-10-14).
const STORED_CHARS = 3_000;
const ENTRY_CHARS = 3_000;
const SECTION_CHARS = 12_000;

/** "Tue 8:47 AM" in Aaron's time zone (the mini's own zone unless one is given). */
function formatWhen(ms, timeZone) {
  return new Intl.DateTimeFormat("en-US", { weekday: "short", hour: "numeric", minute: "2-digit", timeZone }).format(new Date(ms));
}

const oneLine = (text) => String(text || "").replace(/\s+/g, " ").trim();
const cut = (text, n) => (text.length > n ? `${text.slice(0, n - 1)}…` : text);

function createOutbox({ state, now = Date.now, timeZone } = {}) {
  function recent() {
    const t = now();
    return (state.get("outbox") || []).filter((e) => e && typeof e.at === "number" && t - e.at < WINDOW_MS);
  }

  function record({ source, text }) {
    const body = String(text || "").trim();
    if (!body) return;
    const entry = { at: now(), source: String(source || "relay"), text: body.slice(0, STORED_CHARS) };
    state.set("outbox", [...recent(), entry].slice(-MAX_ENTRIES));
  }

  /** Newest entries first into the budget, then printed oldest first. */
  function render() {
    const entries = recent();
    if (!entries.length) return "Nothing was sent to Aaron in the last 12 hours.";
    const lines = [];
    let used = 0;
    for (let i = entries.length - 1; i >= 0; i--) {
      const e = entries[i];
      const line = `- ${formatWhen(e.at, timeZone)} (${e.source}): ${cut(oneLine(e.text), ENTRY_CHARS)}`;
      if (used + line.length + 1 > SECTION_CHARS) break;
      lines.unshift(line);
      used += line.length + 1;
    }
    return ["Sent to Aaron in the last 12 hours, oldest first:", ...lines].join("\n");
  }

  return { record, recent, render };
}

module.exports = { createOutbox, formatWhen, WINDOW_MS, MAX_ENTRIES, ENTRY_CHARS, SECTION_CHARS };
