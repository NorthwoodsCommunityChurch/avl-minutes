# Hermes Helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A second app target, Hermes Helper, that indexes Apple Notes and serves them over MCP on the assistant mini, replacing the Minutes copy there.

**Architecture:** Move the Notes bridge/indexer sources into `Shared/` and compile them into both apps; a thin `HermesHelper` main picks a mode; MinutesKit gains two small parameters (index folder, MCP server name/hint). A launchd user agent runs `--index`; Hermes runs `--mcp`.

**Tech Stack:** Swift 6 / macOS 26, XcodeGen, MinutesKit (Swift Testing), launchd, SSH deploy.

**Spec:** [docs/superpowers/specs/2026-10-07-hermes-helper-design.md](../specs/2026-10-07-hermes-helper-design.md)

## Global Constraints

- Never save audio; `scripts/check-no-audio-writes.sh` must pass for `Minutes/`, `Shared/`, `HermesHelper/`, `Packages/MinutesKit/Sources`.
- No note text in logs (state only).
- Bundle id `com.northwoods.HermesHelper`; product `HermesHelper.app`; display name "Hermes Helper"; data in `~/Library/Application Support/Hermes Helper/`.
- Minutes' own index path, MCP name (`minutes`) and behavior stay exactly as they are.
- Never `rsync` an `.app`; use `ditto -c -k` → `scp` → `ditto -x -k`.
- Confirm with Aaron before anything destructive on the mini beyond what he approved (Minutes removal is approved).

## Review Focus

1. Index service started before Notes permission is granted: refresh fails with `permissionDenied`, status line says so, service keeps running and retries every 2 min (no crash loop). Test: run `--index` on the laptop under a bundle id with no grant? Not automatable without TCC; verified by hand on the mini (first launch).
2. `--mcp` before the index file exists: tools answer the no-index hint, exit code 0. Covered by `missingIndexUsesHint` test + smoke test on a fresh machine.
3. Two index services at once (launchd restart while the old one is finishing a refresh): `NotesIndex` uses `BEGIN IMMEDIATE` and WAL, so the second waits or fails one transaction and retries next tick. Not tested; accepted.
4. Hermes kills `--mcp` mid-call: the server is read-only; nothing to corrupt. Accepted.
5. `HermesHelper` run from a terminal attributes the Notes grant to the terminal (existing Minutes gotcha). Documented; the deploy script only ever runs it under launchd.

---

### Task 1: `NotesIndex.defaultURL(appFolder:)`

**Files:**
- Modify: `Packages/MinutesKit/Sources/MinutesKit/Notes/NotesIndex.swift:10`
- Test: `Packages/MinutesKit/Tests/MinutesKitTests/NotesIndexTests.swift`

- [ ] **Step 1: Write the failing test** (append to NotesIndexTests.swift)

```swift
@Test func defaultURLUsesTheAppFolder() {
    let minutes = NotesIndex.defaultURL()
    #expect(minutes.pathComponents.suffix(3) == ["Application Support", "Minutes", "notes-index.db"])
    let helper = NotesIndex.defaultURL(appFolder: "Hermes Helper")
    #expect(helper.pathComponents.suffix(3) == ["Application Support", "Hermes Helper", "notes-index.db"])
}
```

- [ ] **Step 2: Run it** — `swift test --package-path Packages/MinutesKit --filter defaultURLUsesTheAppFolder` — Expected: compile error, extra argument 'appFolder'.
- [ ] **Step 3: Implement** — `public static func defaultURL(appFolder: String = "Minutes") -> URL` using `appFolder` for the directory component.
- [ ] **Step 4: Run it** — Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "MinutesKit: NotesIndex.defaultURL(appFolder:)"`

### Task 2: MCP server name and no-index hint

**Files:**
- Modify: `Packages/MinutesKit/Sources/MinutesMCP/MinutesMCPServer.swift`
- Test: `Packages/MinutesKit/Tests/MinutesMCPTests/MinutesMCPTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test func missingIndexUsesHint() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString).db")
    let r = MinutesMCPServer.call(name: "list_folders", arguments: nil, indexURL: url, noIndexHint: "wait for the index service")
    #expect(text(r) == "No notes indexed yet — wait for the index service.")
}
```

- [ ] **Step 2: Run it** — Expected: compile error, extra argument 'noIndexHint'.
- [ ] **Step 3: Implement** — add `noIndexHint: String = "open Minutes once so it can index your notes"` to `call` (last parameter) and `name: String = "minutes", noIndexHint: String = …` to `run`; message `"No notes indexed yet — \(noIndexHint)."`; generic failure `"Could not read the notes index: \(error)"`. Existing test `missingIndexIsExplained` still matches "No notes indexed yet".
- [ ] **Step 4: Run the MinutesMCP tests** — Expected: all PASS.
- [ ] **Step 5: Commit** — `git commit -m "MinutesMCP: server name and no-index hint are parameters"`

### Task 3: Shared Notes code + AppIdentity

**Files:**
- Move: `Minutes/Notes/{NotesBridge,NotesIndexer,NotesScriptRunner,NotesScriptSource}.swift` → `Shared/Notes/`
- Create: `Shared/AppIdentity.swift`
- Modify: `project.yml` (Minutes `sources: [Minutes, Shared]`), `scripts/check-no-audio-writes.sh` (add `Shared`, `HermesHelper`)

- [ ] **Step 1: `git mv` the four files; create `AppIdentity`** (bundleID from `Bundle.main.bundleIdentifier`, name from `CFBundleDisplayName` → `CFBundleName` → "Minutes").
- [ ] **Step 2: Replace** `Logger(subsystem: "com.northwoods.Minutes", …)` with `Logger(subsystem: AppIdentity.bundleID, …)` in the three shared files; `"Minutes isn't allowed…"` → `"\(AppIdentity.name) isn't allowed…"`; `"…something Minutes couldn't read."` → `"…something \(AppIdentity.name) couldn't read."`; doc comments say "the app" instead of "Minutes" where they describe shared behavior.
- [ ] **Step 3: Update the guard script and `project.yml`; run** `bash scripts/test-check-no-audio-writes.sh && xcodegen generate --quiet && xcodebuild -project Minutes.xcodeproj -scheme Minutes -configuration Debug -derivedDataPath build/DerivedData -quiet build` — Expected: clean build.
- [ ] **Step 4: Commit** — `git commit -m "Shared Notes bridge/indexer; AppIdentity for logs and messages"`

### Task 4: The HermesHelper target

**Files:**
- Create: `HermesHelper/HermesHelperMain.swift`, `HermesHelper/Info.plist`, `HermesHelper/HermesHelper.entitlements`
- Move: `Minutes/App/IndexService.swift` → `HermesHelper/IndexService.swift` (subsystem via AppIdentity, messages say "HermesHelper --index")
- Modify: `Minutes/App/MinutesMain.swift` (drop `--index`), `project.yml` (new target)

- [ ] **Step 1: Write `HermesHelperMain.swift`**

```swift
import Foundation
import MinutesKit
import MinutesMCP

/// One binary, four modes: `--index` (default; launchd) keeps the Notes index current,
/// `--mcp` serves it read-only to Hermes over stdio, `--notes-helper` runs one Apple Notes
/// request for the index service, `--version` prints the version.
@main
enum HermesHelperMain {
    static let indexFolder = "Hermes Helper"
    static let serverName = "hermes-helper"
    static let noIndexHint = "the Hermes Helper index service hasn't run on this Mac"

    static func main() {
        let args = Set(CommandLine.arguments.dropFirst())
        if args.contains("--notes-helper") { MainActor.assumeIsolated { NotesHelper.run() } }
        if args.contains("--version") {
            print("Hermes Helper \(version) (\(build))")
            exit(0)
        }
        if args.contains("--mcp") {
            Task.detached {
                do {
                    try await MinutesMCPServer.run(indexURL: NotesIndex.defaultURL(appFolder: indexFolder),
                                                   version: version, name: serverName, noIndexHint: noIndexHint)
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("HermesHelper --mcp: \(error)\n".utf8))
                    exit(1)
                }
            }
            dispatchMain()
        }
        if args.isEmpty || args == ["--index"] {
            MainActor.assumeIsolated { IndexService.run(indexURL: NotesIndex.defaultURL(appFolder: indexFolder)) }
        }
        FileHandle.standardError.write(Data("usage: HermesHelper [--index | --mcp | --notes-helper | --version]\n".utf8))
        exit(2)
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
}
```

- [ ] **Step 2: `IndexService.run(indexURL:)`** takes the URL; status line unchanged.
- [ ] **Step 3: Info.plist / entitlements per the spec; `project.yml` target** `HermesHelper` with `sources: [HermesHelper, Shared]`, settings mirroring Minutes minus the icon, `INFOPLIST_FILE: HermesHelper/Info.plist`, `CODE_SIGN_ENTITLEMENTS: HermesHelper/HermesHelper.entitlements`, dependencies MinutesKit + MinutesMCP, same pre-build guard.
- [ ] **Step 4: Build both** — `xcodegen generate --quiet && xcodebuild … -scheme HermesHelper … build && xcodebuild … -scheme Minutes … build` — Expected: both clean.
- [ ] **Step 5: Smoke** — `build/DerivedData/Build/Products/Debug/HermesHelper.app/Contents/MacOS/HermesHelper --version` prints `Hermes Helper 0.1.0 (1)`; `bash scripts/mcp-smoke-test.sh build/DerivedData/Build/Products/Debug/HermesHelper.app/Contents/MacOS/HermesHelper` → PASS; `swift test --package-path Packages/MinutesKit` → all pass; `bash scripts/mcp-smoke-test.sh` (Minutes) → PASS.
- [ ] **Step 6: Commit** — `git commit -m "Hermes Helper: background Notes index + MCP server target; Minutes drops --index"`

### Task 5: launchd template + deploy script; deploy to the mini

**Files:**
- Create: `HermesHelper/launchd/com.northwoods.HermesHelper.plist` (with `__HOME__` placeholder), `scripts/deploy-helper.sh`

- [ ] **Step 1: Write both files per the spec.** The script: `set -euo pipefail`; host arg default `engineering-mac`; `xcodegen generate --quiet`; Release build to `build/DerivedData`; `ditto -c -k --keepParent` → `build/HermesHelper.zip`; `scp` zip + plist to `~/` on the host; remote: `launchctl bootout gui/$(id -u)/com.northwoods.HermesHelper || true`, `rm -rf /Applications/HermesHelper.app`, `ditto -x -k`, `sed "s|__HOME__|$HOME|g"` into `~/Library/LaunchAgents/…plist`, `launchctl bootstrap gui/$(id -u) <plist>`, `sleep 3`, print `--version`, `launchctl print gui/$(id -u)/com.northwoods.HermesHelper | grep -E "state|pid"`, `tail -n 5 ~/Library/Logs/HermesHelper.log`.
- [ ] **Step 2: Run it** — `bash scripts/deploy-helper.sh` — Expected: version line, `state = running`, a status line in the log (permission problem until Aaron clicks Allow).
- [ ] **Step 3: Aaron clicks Allow on the mini.** Then the log's next status line (≤10 min; or `log show --predicate 'subsystem == "com.northwoods.HermesHelper"' --last 5m`) reports `notes indexed: N` with no problem.
- [ ] **Step 4: Mini smoke** — `ssh engineering-mac 'bash -s' < scripts/mcp-smoke-test.sh` with the helper path, plus one `search_notes` call. Expected: PASS and hits.
- [ ] **Step 5: Commit** — `git commit -m "Hermes Helper: launchd agent template and SSH deploy script"`

### Task 6: Remove Minutes from the mini; docs

- [ ] **Step 1: On the mini** (approved): `pkill -x Minutes`; `/Applications/Minutes.app/Contents/MacOS/Minutes --unregister-login`; `rm -rf /Applications/Minutes.app "~/Library/Application Support/Minutes" "~/Library/Application Support/FluidAudio"`; `defaults delete com.northwoods.Minutes`; `tccutil reset AppleEvents com.northwoods.Minutes`. Verify: no Minutes process, no login item, helper still `running`.
- [ ] **Step 2: Docs** — CLAUDE.md (status, modes line, architecture, new target in "Where things live", gotchas), README (a short "Hermes Helper" section), direction doc (mini state + next steps), OneDrive `SSH-ACCESS.md` row, ledger.
- [ ] **Step 3: Commit + push** — `git commit -m "docs: Hermes Helper on the mini; Minutes removed there"` then `git push`.
