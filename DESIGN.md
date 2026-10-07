# Minutes — Design

## 1. Direction

> **Apple native, current as of September 2026** (Liquid Glass, introduced in macOS 26 and refined in macOS 27). Aaron's call, 2026-10-07: Minutes should look and behave like a built-in Mac utility, not a branded app.

Consequences:
- System font (SF Pro), system colors, the user's accent color, SF Symbols. No bundled brand fonts, no custom color palette, no custom-drawn controls.
- Standard controls everywhere: `TextField`, `Toggle(.switch)`, `Gauge`, `Form(.grouped)`, `Button` with `.glass` / `.glassProminent` (Liquid Glass), `SettingsLink`, `ContentUnavailableView` where Apple would use one.
- Build against the macOS 26 SDK; Liquid Glass controls pick up macOS 27's refinements (transparency slider, corner radii) automatically.
- Light and dark mode both supported by construction (no hard-coded colors).

Superseded: the "broadcast tally" direction and its HTML mockup (removed; see git history 2026-10-07).

## 2. The one thing that must read instantly

Whether Minutes is listening. Expressed natively:
- Menu bar icon: `waveform` when idle; a red `record.circle.fill` plus elapsed time (`14:32`) while listening — the same pattern macOS uses for screen recording.
- In the popover: a red `record.circle.fill`, "Listening", a large monospaced timer, and the subtitle "Audio is not being recorded."

## 3. Surfaces

### Menu bar popover (`MenuBarExtra`, `.window` style, 320 pt wide)

**Ready**
```
 Minutes                                   (title3, semibold)
 Transcribes meetings into Notes. Audio is never recorded.   (callout, secondary)
 [ Meeting name (optional)               ]   TextField
 Room microphone          ▁▂▃  [toggle]      Toggle + small level Gauge
 Call audio               ▁    [toggle]
 [        Start Listening        ]           .glassProminent, .large, full width
 Let everyone know you're transcribing.  Don't Remind Me   (footnote + .link button)
 ─────────────────────────────────────────
 118 notes indexed · 1 min ago        ⚙  ⏻   footnote; SettingsLink; Quit
```
"Set up Minutes…" replaces Start until permissions, models, and Notes access are in place.

**Listening**
```
 ● Listening                    00:14:32     red symbol; .title2 monospacedDigit
 Audio is not being recorded.                caption, secondary
 Room  ▓▓▓▓▓░░░░░   Call ▓▓░░░░░░░░           Gauge(.accessoryLinearCapacity)
 Me         Agreed, I'll approve it Friday.  speaker: caption semibold secondary
 Caller 1   I'll send the quote…             in-progress text: tertiary, italic
 Saved to Notes 12 s ago                     footnote
 [            Stop            ]              .glassProminent, tint red
```

**Saved**
```
 ✓ Saved to Notes                            green checkmark.circle.fill
 Staff meeting · 47 min                      headline / callout
 [ Open in Notes ]   [ New Meeting ]         .glass / .glassProminent
```

**Problems** — an inline `Label` with `exclamationmark.triangle.fill` (yellow) and one action button ("Open System Settings", "Try Again", "Copy Transcript"). Never a modal alert while a meeting runs.

### Settings (`Settings` scene, `Form` `.grouped`)
Sections: **Voice** (status, Train / Retrain / Delete), **Transcripts** (Notes folder name, "Remind me to tell attendees"), **Claude** (Connected / Connect, notes indexed, last refresh, Refresh Now), **General** (Open at login), **Models** (status, Download).

### Welcome (window, first launch until setup is complete)
A single setup checklist, Apple-setup-assistant style: large `waveform` symbol, "Welcome to Minutes", one line on the promise, then rows — Microphone, Call audio, Notes, Speech models, Your voice (optional), Claude — each with a status symbol and an action button. "Done" (.glassProminent) closes it.

### Voice training (sheet)
Passage to read (body, in a rounded `GroupBox`), "Speech heard" `Gauge` toward 20 s, live level `Gauge`, footnote "Your voice stays in memory and is erased afterward. Minutes keeps only a voiceprint that can't be played back.", Cancel / Done.

## 4. Motion
System defaults only: `.default` animation for state changes, `.contentTransition(.numericText())` for the timer, lines insert with `.opacity` transition.

## 5. Implementation gates
- [ ] No hex colors, no custom fonts, no custom-drawn controls
- [ ] Every button is a system style (`.glass`, `.glassProminent`, `.link`, `.borderless`)
- [ ] Works in light and dark appearance
- [ ] VoiceOver labels on the menu bar icon, meters, and timer
