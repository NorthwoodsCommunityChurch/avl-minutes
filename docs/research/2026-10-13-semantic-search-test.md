# Semantic search test: does a RAG index help Hermes? (2026-10-13)

Aaron asked whether mail, Teams, and calendar should live in a RAG (vector) database instead of Hermes "looking
through all the documents." She already searches an index: the helper's SQLite FTS5 index (`notes-index.db`,
7,639 records, refreshed every 2 min), through `search_notes`. The question tested here is whether adding
semantic (embedding) search to that index finds things keyword search misses.

## Method

- **Questions:** 24 real questions Aaron sent Hermes between Oct 7 and Oct 13, each with the first `search_notes`
  query Hermes actually ran for it, plus its folder and `since` filter (from `~/.hermes/state.db`).
- **Methods, top 10 each:**
  - **F**: keyword search, which is today's search, rebuilt exactly as `NotesIndex.search` does it (`FTSQuery` OR of quoted tokens,
    `bm25(notes_fts, 3.0, 1.0)`, same folder and date rules).
  - **S**: semantic search with Hermes's query (BAAI/bge-base-en-v1.5, records chunked at 1,500 chars with 200 overlap,
    at most 6 chunks per record, best chunk wins, same filters).
  - **A**: semantic search with Aaron's own words instead of Hermes's query.
  - **H**: hybrid, F and S merged by reciprocal rank fusion (k = 60).
- **Where:** entirely on edit-3 (`~/ragtest`, mode 700); the data never left the mini. Snapshots, vectors, and the
  question list were deleted after the run; scripts and the Python venv remain.
- **Judging:** by hand (Claude), per question, against what Aaron was asking for.

## Results

| Verdict | Questions |
|---|---|
| Semantic clearly better | Brian's email (keyword stuck on April "Northwoods Kids AVL Control" threads; semantic found the House Right wrap-up, LED budget, Atrium chat); House Right quote (keyword: W9, a Dante VLAN mail, construction update; semantic: House Right project mails); "higsfeild" (only semantic found the "higgsfeild ai is $59 a month" message, a spelling variant); everything Seth asked for this year (keyword: mostly noise; semantic: six of Seth's app ideas and requests) |
| Semantic slightly better | auditorium lights how-to; Dante clocking emails (semantic surfaced the Oct 2, Oct 11, Oct 13 updates); Danny can't connect to a switch (keyword's top hit was the Hermes index note) |
| Keyword clearly better | "things Claude needs to give you access to" (only keyword found "A to do for me, I want Claude to give you access to whisper verses" and the Q-SYS Reflect API token message) |
| Tie (both found the same useful items, or neither did) | 16 others: atrium notes, Danny/Dante call, Josh/Ableton, MJ transcript, Todd/Blake meeting, 2 pm meeting transcript, network storage, lighting fixtures note, teleprompter, Teams apps public, Seth's Claude task, Katie's manuscript (neither found Katie's message), B&H quote, Tiemo meeting, B&H tax exempt, Q-SYS network |

**Hybrid kept every win from both sides:** "whisper verses" at rank 4, "higgsfeild ai" at 2, House Right mails at 2,
4, and 7, and four of Seth's app requests in the top 10.

**Aaron's raw words did worse than Hermes's query** (column A): "Did you see Brians email come through" returned
B&H quote confirmations and promo mail. Semantic search needs a real query, which Hermes already writes.

## Cost on the mini (edit-3, M1, 16 GB)

| | CPU (ONNX, fastembed) | GPU (PyTorch MPS, fp16) |
|---|---|---|
| Full index, 10,979 chunks | stopped after 42 min unfinished | 341 s (32 chunks/s) |
| One query | | ~0.05 s including a full scan of 10,979 vectors |
| Vectors on disk | | 34 MB (768-dim float32) |

New records arrive a handful at a time every 2 min, so upkeep is seconds. CPU-only embedding is too slow for the
first build; a real build must use the GPU or the Neural Engine (Core ML).

## Recommendation

Add semantic search **inside the existing `search_notes`** as a hybrid (keyword + semantic, merged by rank), so
Hermes calls the same tool and gets both kinds of match. No new tool for her to learn, and SOUL.md and the relay note
stay unchanged. Open design questions for the build: an embedding runtime the helper can carry (Core ML conversion of
bge-base vs a small sidecar process), where vectors live (a table in `notes-index.db`), and re-embedding on edits.

## Side findings

- **Aaron's messages to Hermes are in her own search results.** 177 Teams records are his 1:1 chat with the bot
  (chat id contains `685fac05-84be-4bb9-aa30-4a2a430d22b1`), and his own question was the top hit in 8 of the 24
  tests. They are there on purpose (SOUL.md: "my notes" includes what he told her in Teams), so they are not
  removed, but a search for the current question will always return the question itself first.
- **A plain-text credential is in Aaron's Apple Notes.** A Northwoods-folder note last edited 2026-01-22 holds a
  Claude OAuth access token as JSON. It is indexed, so Hermes can read it and send it to Puget inside a search
  result. Reported to Aaron; the note is his, so nothing here changes it.
