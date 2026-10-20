"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { createOutbox, formatWhen, WINDOW_MS, ENTRY_CHARS, SECTION_CHARS } = require("../lib/outbox");
const { createState } = require("../lib/state");

const TZ = "America/Chicago";
const T0 = Date.parse("2026-10-13T13:47:00Z"); // Tue 8:47 AM CDT
const stateFile = () => path.join(fs.mkdtempSync(path.join(os.tmpdir(), "outbox-")), "state.json");

test("records what was sent, renders it oldest first with local times, and survives a restart", () => {
  const file = stateFile();
  let clock = T0;
  const box = createOutbox({ state: createState(file), now: () => clock, timeZone: TZ });
  assert.match(box.render(), /Nothing was sent to Aaron in the last 12 hours\./);
  box.record({ source: "meeting", text: "Scrum prep — Tue Oct 13\n- Check Q-SYS" });
  clock += 15 * 60_000;
  box.record({ source: "scheduled: Scrum Prep Notes", text: "Scrum is cancelled today." });
  box.record({ source: "chat", text: "   " });
  const again = createOutbox({ state: createState(file), now: () => clock, timeZone: TZ });
  assert.equal(again.recent().length, 2, "blank text is not recorded; the rest survived a new state object");
  const r = again.render();
  assert.match(r, /^Sent to Aaron in the last 12 hours, oldest first:/);
  const first = r.indexOf("- Tue 8:47 AM (meeting): Scrum prep — Tue Oct 13 - Check Q-SYS");
  const second = r.indexOf("- Tue 9:02 AM (scheduled: Scrum Prep Notes): Scrum is cancelled today.");
  assert.ok(first > 0 && second > first, r);
  assert.equal(formatWhen(T0, TZ), "Tue 8:47 AM");
});

test("entries older than 12 hours are dropped, at most 40 are kept, and the rendered section stays within its limits", () => {
  let clock = T0;
  const box = createOutbox({ state: createState(stateFile()), now: () => clock, timeZone: TZ });
  box.record({ source: "feed", text: "old line" });
  clock += WINDOW_MS + 1;
  for (let i = 0; i < 45; i++) box.record({ source: "chat", text: `${i} ${"x".repeat(ENTRY_CHARS + 500)}` });
  const kept = box.recent();
  assert.equal(kept.length, 40);
  assert.ok(!kept.some((e) => e.text === "old line"));
  const r = box.render();
  assert.ok(r.length <= SECTION_CHARS + 200, `section is ${r.length} chars`);
  assert.ok(r.includes("(chat): 44 "), "the newest entry is kept when the budget drops some");
  assert.ok(!r.includes("(chat): 5 "), "the oldest are dropped first");
  assert.ok(r.split("\n").slice(1).every((l) => l.length <= ENTRY_CHARS + 40), "each entry is cut");
});
