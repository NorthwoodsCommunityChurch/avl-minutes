# Hermes Helper — design (2026-10-07)

A small background app for the assistant Mac mini (`engineering-mac`). It keeps a full-text index of Aaron's Apple Notes and serves it, read-only, to Hermes Agent over MCP, so Hermes can answer from his notes and the meeting transcripts Minutes writes. It replaces the copy of Minutes that was installed on the mini as a stopgap.

Direction record: [2026-10-07-assistant-direction.md](../../research/2026-10-07-assistant-direction.md). Aaron approved the shape in chat on 2026-10-07 ("Wouldn't it make more sense to build a hermes helper" → "approved, and clean up minutes from the mini").

## Goals

- Hermes on the mini can search and read every note in Aaron's iCloud Notes, including Minutes transcripts, within 2 minutes of a change.
- No UI, no menu bar item, no windows. It starts at login, restarts if it dies, and logs state only (never note text).
- Same engine as Minutes (`MinutesKit` index + the Notes bridge), built as its own app with its own name, bundle id, data folder, and Automation permission.
- Minutes goes back to being the transcriber only: its `--index` mode is removed.

## Non-goals (this version)

- Indexing the OneDrive "AI Feed" (mail, calendar, Teams exports). Planned next; see "Later".
- Writing digests back to Notes. Planned; see "Later" for why it needs the index service, not the MCP process.
- Sparkle auto-updates, a Canopy listing, an app icon, or a release. The helper is deployed over SSH by `scripts/deploy-helper.sh` and lives only on the mini. This deviates from the org rule "every macOS Swift app MUST use Sparkle"; a background agent with no UI has no place to show Sparkle's prompts and no appcast to read. Flagged to Aaron as a decision.

## The app

| Item | Value |
|---|---|
| XcodeGen target | `HermesHelper` (application, macOS 26, hardened runtime, no sandbox) |
| Product | `HermesHelper.app`, executable `HermesHelper`, display name "Hermes Helper" |
| Bundle id | `com.northwoods.HermesHelper` |
| Version | 0.1.0 (1) |
| Signing | Apple Development, team `TQ6Y49W7UW` (same as Minutes) |
| Entitlements | `com.apple.security.automation.apple-events` only |
| Info.plist | `LSUIElement` true; `NSAppleEventsUsageDescription` "Hermes Helper reads your notes so Hermes can search them." No microphone, audio-capture, speech, or Sparkle keys |
| Data | `~/Library/Application Support/Hermes Helper/notes-index.db` (WAL) |
| Logs | unified log subsystem `com.northwoods.HermesHelper`; stdout status line every 10 minutes, captured by launchd into `~/Library/Logs/HermesHelper.log` |
| Dependencies | `MinutesKit`, `MinutesMCP` (no AudioDeps, no Sparkle) |

### Modes (one binary)

| Arguments | What runs |
|---|---|
| none, or `--index` | The index service: refreshes the Notes index every 2 minutes (`NotesIndexer`), prints a status line at start and every 10 minutes, runs until killed. launchd runs this. |
| `--mcp` | The read-only MCP server (`MinutesMCPServer`) over stdio against the helper's index. Hermes runs this as a child. Server name `hermes-helper`. If the index file doesn't exist yet the tools answer "No notes indexed yet — the Hermes Helper index service hasn't run on this Mac." |
| `--notes-helper` | One Apple Notes request from stdin (JSON), reply on stdout, exit. The index service spawns this for every Notes call so NSAppleScript never blocks the service. |
| `--version` | Prints `Hermes Helper <version> (<build>)` and exits 0. The deploy script uses it to verify the install. |

Any other argument prints the modes to stderr and exits 2. There is no login-item code: launchd owns the lifecycle.

### launchd

`~/Library/LaunchAgents/com.northwoods.HermesHelper.plist` (written by the deploy script from the template in `HermesHelper/launchd/`):

- `ProgramArguments`: `/Applications/HermesHelper.app/Contents/MacOS/HermesHelper --index`
- `RunAtLoad` true, `KeepAlive` true (restarts after a crash or kill), `ThrottleInterval` 10
- `LimitLoadToSessionType` `Aqua` — Apple events to Notes need the logged-in GUI session (the mini auto-logs in)
- `ProcessType` `Background`
- `StandardOutPath` / `StandardErrorPath`: `/Users/<user>/Library/Logs/HermesHelper.log` (launchd doesn't expand `~`; the deploy script substitutes the home directory)

### Permission

The first index refresh sends Apple events to Notes, so macOS shows "Hermes Helper wants access to control Notes" on the mini's screen. Aaron clicks Allow once (System Settings > Privacy & Security > Automation shows it afterward). Until then each refresh fails with the permission error and the log's status line says so; nothing else breaks. TCC keys the grant to the bundle id, so redeploying the same bundle id keeps it.

Because the `--notes-helper` child is the same signed bundle, its Apple events count as the helper's.

## Shared code

`Minutes/Notes/*` moves to `Shared/Notes/*` (`NotesBridge`, `NotesIndexer`, `NotesScriptRunner`, `NotesScriptSource`) and is compiled into both app targets. Two app-specific values it used to hard-code come from a new `Shared/AppIdentity.swift`:

```swift
enum AppIdentity {
    /// The running app's bundle id; log subsystem.
    static let bundleID: String
    /// "Minutes" or "Hermes Helper"; used in user-facing error text.
    static let name: String
}
```

Both read `Bundle.main` (`CFBundleIdentifier`, `CFBundleDisplayName`, falling back to `CFBundleName`, then "Minutes"). Loggers in the shared files use `AppIdentity.bundleID` as their subsystem; `NotesBridgeError.permissionDenied` and `.badOutput` messages name `AppIdentity.name`.

`IndexService.swift` moves from `Minutes/App/` to `HermesHelper/` and Minutes loses its `--index` mode. (`--unregister-login` stays in Minutes.)

## MinutesKit changes

- `NotesIndex.defaultURL(appFolder: String = "Minutes") -> URL` — the helper passes `"Hermes Helper"`. Existing callers are unchanged.
- `MinutesMCPServer.run(indexURL:version:name:noIndexHint:)` and `call(name:arguments:indexURL:timeZone:now:noIndexHint:)` — `name` defaults to `"minutes"`, `noIndexHint` defaults to `"open Minutes once so it can index your notes"`. The missing-index reply becomes `"No notes indexed yet — \(noIndexHint)."`. The generic read failure no longer says "Minutes".

## Scripts

- `scripts/check-no-audio-writes.sh` scans `Shared/` and `HermesHelper/` too, and the helper target runs it as a pre-build step. The helper has no audio code; the guard keeps the promise for the whole repo.
- `scripts/mcp-smoke-test.sh <binary>` already takes a path; it is run against the helper binary.
- `scripts/deploy-helper.sh [host]` (default `engineering-mac`): `xcodegen`, Release build of the `HermesHelper` scheme, `ditto -c -k` zip, `scp`, on the host: `launchctl bootout` the agent if loaded, replace `/Applications/HermesHelper.app`, write the launchd plist with the home path substituted, `launchctl bootstrap gui/<uid>`, then print `--version` output and the last log lines. Never `rsync` (OneDrive extended attributes break signatures).

## Hermes registration (done in the Hermes step, recorded here for the shape)

```yaml
mcp_servers:
  notes:
    command: /Applications/HermesHelper.app/Contents/MacOS/HermesHelper
    args: ["--mcp"]
```

Hermes gets `search_notes`, `list_notes`, `get_note`, `list_folders`.

## Minutes on the mini (removal, approved)

After the helper's index has refreshed once with permission granted: quit Minutes, run `Minutes --unregister-login`, delete `/Applications/Minutes.app`, `~/Library/Application Support/Minutes`, `~/Library/Application Support/FluidAudio` (speech models Minutes downloaded), `defaults delete com.northwoods.Minutes`, `tccutil reset AppleEvents com.northwoods.Minutes`. Minutes on Aaron's laptop is untouched.

## Testing

- MinutesKit (Swift Testing): `defaultURL(appFolder:)` path; MCP `noIndexHint` appears in the missing-index reply. Whole suite stays green.
- Build: both targets build; the no-audio guard passes; `swift test` passes.
- Laptop: `HermesHelper --version`; `mcp-smoke-test.sh` against the Debug helper (tools listed; `list_folders` answers, even before any index exists).
- Mini: log shows `notes indexed: <N>` within 5 minutes of Allow; `mcp-smoke-test.sh` on the mini; a `search_notes` call over stdio returns hits.
- Minutes: still builds, `--mcp` smoke test still passes, `--index` is gone.

## Later

- **AI Feed:** the index service also walks the OneDrive "AI Feed" folder and indexes each file as a note-like record with a `source` column; the MCP tools gain a `source` filter. Same FTS table.
- **Write-back:** Hermes asks the helper to write a digest note. Apple events from a `--mcp` child of Hermes would be attributed to Hermes's parent process by TCC, so writes go through the launchd-run index service (local socket), which already holds the Notes permission.
- **Teams bridge:** separate; Power Automate, per Aaron.
