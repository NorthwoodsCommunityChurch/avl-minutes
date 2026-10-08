# pco-mcp (mirror)

The Planning Center MCP server Hermes uses (`planning_center`). Its home is the Weekend Rundown project
(`~/Documents/VS Code/Weekend Rundown/Weekend Rundown/pco-mcp/`), which is **not under git** (the whole
Weekend Rundown folder is gitignored in the VS Code root repo), so this mirror is the versioned copy.
Keep the two identical: edit in Weekend Rundown, run `scripts/deploy-pco-mcp.sh`, which copies from there
and refreshes this mirror. `song_prep.py` + `test_song_prep.py` are the song prep tools added 2026-10-08
for Hermes; `python3 -m pytest test_song_prep.py -q` runs their tests (pure logic, no network).
Secrets: `.env` with PCO_APP_ID / PCO_SECRET lives only on the mini and in OneDrive `secrets/planning-center.env`.
