# Hermes sends one update per thing: design

**Date:** 2026-10-13 · **Status:** approved by Aaron ("approved", 2026-10-13, on the summary below)

## Problem

On 2026-10-13 Aaron got two scrum briefs: the automatic meeting prep at 8:46 (the helper's `MeetingPrep` wake-up,
35 minutes before the 9:20 Scrum) and his "Scrum Prep Notes" scheduled job at 9:02. Three paths send him updates he
did not ask for in the moment, and none of them knows what the others sent:

| Path | Today | Sees what Aaron already got? |
|---|---|---|
| Feed events and meeting prep | helper → relay `POST /notify` → Hermes (thread `feed`) → Teams | Only what is still in the feed thread's history |
| Hermes's scheduled jobs | Hermes cron writes `~/.hermes/cron/output/<job>/<time>.md` → relay `CronOutputWatcher` posts it **raw** | No: Hermes never sees the output again |
| Replies to Aaron | his Teams thread → Hermes (thread = his conversation id) → Teams | Only that thread |

Aaron's requirement (2026-10-13): "I don't want to manage her updating me, she needs to think through that, and
manage that herself. She needs to work on my behalf." So the fix is plumbing that gives Hermes the facts plus one
door for every unprompted update; the judgment (send, trim, stay silent, fix her own jobs) is hers. This follows the
standing preference for general mechanisms over one-off fixes (memory `hermes-agentic-not-rigid`).

## Decisions (what Aaron approved)

1. **One door.** The relay no longer posts a scheduled job's output raw. It hands the output to Hermes as a draft;
   she replies with what Aaron should see (all, only the new part, or `NO_MESSAGE`).
2. **What he already got.** Every automated prompt (feed event, meeting prep, scheduled-job review) carries what
   the relay sent Aaron in the last 12 hours and her scheduled jobs due in the next 2 hours.
3. **She manages it herself.** When a job keeps repeating something he gets another way, she updates or removes the
   job with `cronjob_manage` in the same turn and tells him in one line what she changed, **including jobs Aaron asked
   for**, without asking first (the load-bearing choice, flagged and approved).
4. **Cost accepted:** a scheduled job's update arrives about one Puget turn (~1 min) later.

## Design

### Outbox (new, `hermes-teams/lib/outbox.js`)

The relay's record of what it posted to Aaron's 1:1 chat.

- `record({ source, text })` stores `{ at, source, text }`. Sources: `chat` (a reply to his message), `feed`,
  `meeting`, `scheduled` (with the job name). Persisted in the relay state file (key `outbox`) so a relay restart
  keeps it; entries older than 12 hours are pruned on every write and read; at most 40 entries.
- `render()` gives the prompt section: oldest first, each line `- <local time> (<source>): <text>`, each text cut
  to 700 characters, the whole section to 6,000 characters (oldest entries dropped first). Empty: "Nothing was sent
  to Aaron in the last 12 hours."
- Recorded from: `postHome` (feed, meeting, scheduled, failures) and the relay's replies to Aaron's own messages.
  Greetings, `/help` and `/new` confirmations are not recorded.

### Upcoming jobs (new, `hermes-teams/lib/jobs.js`)

`upcomingJobs({ file, now, horizonMs })` reads Hermes's `~/.hermes/cron/jobs.json` (same user on the mini, read-only)
and returns enabled, scheduled jobs whose `next_run_at` is within the next 2 hours: name, next run (local time), and
the first 300 characters of the prompt. A missing or unreadable file gives an empty list and the section says the
list could not be read. Config key `cronJobsFile` (default `~/.hermes/cron/jobs.json`).

### Prompts (`hermes-teams/lib/relay.js`)

All three automated prompts end with one context section, inside its own nonce-delimited block (the outbox quotes
feed content, so it is data, never instructions):

> Aaron gets one update per thing. Before you reply, read what he was already sent and which of your jobs run soon
> (block below). Never repeat what he already has; if only part of your reply is new, send only that part; if all
> of it is old, reply exactly NO_MESSAGE. If one of your jobs below will cover this before it matters, reply
> NO_MESSAGE and let the job do it.

- **Feed event and meeting prep:** existing prompts plus the section. Meeting prep adds: "If a job of yours due before
  this meeting starts will brief it, reply NO_MESSAGE."
- **Scheduled-job review (new kind `scheduled`):** "Scheduled job (automatic, not a message from Aaron). Your job
  "<name>" just ran; its output is in the block below and has not reached Aaron. Work from it; do not redo its
  research." Then: send all / only the new part / NO_MESSAGE, and: "If this job keeps repeating what he gets another
  way (the automatic meeting prep briefs every meeting with other attendees 35 minutes before it starts, another job,
  a feed line), fix the job now: cronjob_manage list, then update its prompt or schedule or remove it, and add one
  line saying what you changed. He does not want to manage your updates." The job output goes in a nonce-delimited
  block too (it may quote outside records).

### Delivery flow

```
cron output file → CronOutputWatcher → deliver(parsed)
   silent                → nothing (as today)
   [CRON_FAILURE]        → postHome("**<name>** failed: …") directly, recorded in outbox
   otherwise             → relay.reviewScheduled(parsed): queued like a feed event (behind Aaron's messages,
                           never merged with other kinds or with another job's output) → Hermes (thread "feed")
                              NO_MESSAGE → nothing posted, logged posted:false
                              text       → postHome("**<name>**\n<text>"), recorded as scheduled
                              error      → raw output posted (nothing is lost), logged scheduled-review-failed
```

- No home conversation yet: `reviewScheduled` rejects with 409 and the watcher retries on its next scan (today's
  behavior for `post`).
- The watcher's option `post(text)` becomes `deliver(parsed)`; `server.js` wires failures to `postHome` and the rest
  to `reviewScheduled`.

### Hermes's standing rules (`hermes-tools/SOUL.md`)

- Feed events section: one bullet saying every automated prompt carries what Aaron already got and her jobs due
  soon; one update per thing; send only what is new.
- Scheduled work section: her jobs' output reaches Aaron only after her review; when a job duplicates another path,
  she fixes it herself and says so in one line.

## Out of scope

Duplicate task cards, duplicate notes in the Hermes folder, and duplicate jobs that never post (Aaron, 2026-10-13:
"right now I want to focus on why I got two updates").

## Testing

- Unit (node --test): outbox record / prune / persist / render limits; upcoming-jobs filter (horizon, disabled,
  paused, missing file); prompts carry the section and the blocks; scheduled review posts with the header, posts
  nothing on NO_MESSAGE, falls back to the raw output on a Hermes error, posts failures directly, is not merged;
  chat replies are recorded; watcher calls `deliver`.
- Live on edit-3: two one-shot jobs a minute apart named "Relay test", both answering the same line. The first
  reaches Teams; the second's review sees it in the outbox and answers NO_MESSAGE (relay log `posted:false`).
  Then a dry check of the meeting-prep prompt with the Scrum job due inside 2 hours.

## Risks

- Hermes judges wrong and drops something new. Mitigation: the rule says send the new part; the outbox shows
  exactly what was sent; the relay log keeps every decision (`posted`, `chars`).
- She removes a job Aaron wanted. Accepted by Aaron; she must say so in one line, so he sees it.
- Prompt size: the context section is capped at ~6.5K characters (~1.7K tokens), well inside the 56K trigger.
