# Minutes — Design

Mockup: [design/sketches/index.html](design/sketches/index.html) (open in Safari). The SwiftUI port must match it.

---

## 1. Aesthetic direction

> **Industrial / Broadcast Cockpit** — Minutes is an on-air tally for a meeting: the single most important fact is *is it listening right now, and is anything being recorded* (no), and broadcast tally language is the clearest way Aaron already reads that state.

## 2. The unforgettable thing

> **The tally strip**: a full-bleed color block across the top of the popover that *is* the state — navy "READY", coral "● LISTENING · NOT RECORDING" with the elapsed time in big monospaced numerals, green "SAVED TO NOTES", gold when something needs a fix. Under it, a two-channel meter bridge (ROOM / CALL) like a mixer's.

## 3. Reference apps

| App | What to learn |
|---|---|
| ATEM Software Control | Tally as a solid color block, not a dot; ALL-CAPS state labels you can read from across a room |
| OBS Studio (audio mixer) | Segmented level meters per source, labelled by source name, green-to-amber-to-red ramp |
| CleanShot X | A menu-bar popover that feels like an app, not a menu: custom buttons, layered warm surfaces, nothing stock |

## 4. Visual system

### Type scale

| Role | Font + weight | Size | Notes |
|---|---|---|---|
| Tally label | Myriad Pro Black | 11pt | ALL-CAPS, tracking 1.8 |
| Timer | Myriad Pro Black, monospaced digits | 34pt | on the coral block |
| Section label | Myriad Pro Black | 9pt | ALL-CAPS, tracking 1.5, tertiary |
| Body / controls | Myriad Pro Regular / Semibold | 13pt | |
| Transcript lines | Minion Pro Regular | 13pt | the words are the "minutes" — set like print |
| Speaker chip | Myriad Pro Black | 9pt | ALL-CAPS in a tinted capsule |
| Caption / status | Myriad Pro Regular | 11pt | secondary foreground |
| Onboarding display | Myriad Pro Light | 30pt | tracking -0.3 |

### Color

- Surfaces (warm black, never `#000`): window `#1B1815`, panel `#24201C`, raised `#2D2926`, hairline `#3A3531`.
- Text: primary `#F4EFEA`, secondary `#B8AFA7`, tertiary `#7D746C`.
- Interactive accent: light blue `#009CDE` (links, focus, "Me" chip). Never primary blue `#004C97` for text on dark.
- Tally states: READY navy `#002855`; LISTENING coral `#FF6D6A`; SAVED green `#86AD3F`; NEEDS ATTENTION gold `#F1BE48` (dark text on it).
- Speaker chips: Me = light blue; Speaker n (room) = gold tint; Caller n = green tint; Unknown = neutral.
- Meters: green → gold (−12 dBFS) → coral (−3 dBFS), unlit segments `#3A3531`.

### Spacing

`tight 4 / small 8 / medium 12 / large 16 / xlarge 24 / xxlarge 36` (`Theme.Space`).

### Motion — snap

State changes snap (0.15 s). The LISTENING dot breathes (1.4 s). Meters update at capture rate with a 0.3 s peak fall. New transcript lines slide up 0.18 s.

### Iconography

- Hero illustration (onboarding, voice training): drawn in code — a waveform whose right half turns into lines of text (sound becomes words; no tape, no file).
- Northwoods symbol (white PNG from the brand repo) on the onboarding color block and About.
- The **pointer** (marker tip) marks the newest transcript line and the current onboarding step.
- SF Symbols only for utility: gear, power, xmark, arrow.up.right.

## 5. Surfaces

### Popover — ready
```
████ READY ·························· TEXT ONLY ████   navy block
  MEETING NAME
  [ Staff meeting                               ]
  SOURCES
  [ ● ROOM MIC  ▮▮▯▯▯ ] [ ● CALL AUDIO  ▯▯▯▯▯ ]       toggle tiles w/ live meter
  ┌───────────────────────────────────────────┐
  │            ● START LISTENING              │       coral button
  └───────────────────────────────────────────┘
  Let everyone know you're transcribing.  Don't remind me
  ─────────────────────────────────────────────
  118 notes indexed · 1 min ago           ⚙   ⏻
```

### Popover — listening
```
████ ● LISTENING · NOT RECORDING ███████████████   coral block
████            00:14:32              ██████████
  ROOM ▮▮▮▮▮▮▯▯▯▯▯▯     CALL ▮▮▮▯▯▯▯▯▯▯▯▯           meter bridge
  ▸ ME        We decided the screens can wait.      Minion
    CALLER 1  I'll send the quote by Friday.
    SPEAKER 1 …and the mounts (dimmed, in progress)
  Saved to Notes 12 s ago
  [ ■ STOP ]
```

### Popover — saved
```
████ ✓ SAVED TO NOTES ██████████████████████████   green block
  Staff meeting
  47 min · Room and call · Meeting Transcripts
  [ OPEN IN NOTES ]  [ NEW MEETING ]
```

### Popover — needs attention
```
████ ! CALL AUDIO IS OFF ███████████████████████   gold block, dark text
  Minutes needs permission to hear call audio.
  [ OPEN SYSTEM SETTINGS ]        Room mic still works.
```

### First run (window 640 × 440)
```
┌──────────────┬───────────────────────────────┐
│ navy block   │  Listens. Never records.      │  Myriad Light 30
│  [symbol]    │  ▸ 1 What Minutes does        │  pointer = current step
│  waveform →  │    2 Permissions              │
│  text lines  │    3 Speech models            │
│  "Minutes"   │    4 Your voice               │
│              │    5 Connect Claude           │
│              │  [ CONTINUE ]                 │
└──────────────┴───────────────────────────────┘
```

### Voice training (sheet)
```
  READ THIS ALOUD                                  section label
  "The best meetings end with a clear next step…"  Minion 15, quoted passage
  SPEECH  ▮▮▮▮▮▮▮▮▯▯▯▯  12 of 20 s                  progress meter
  LEVEL   ▮▮▮▯▯▯▯▯▯▯▯▯
  Audio stays in memory and is erased after.       caption
  [ CANCEL ]                      [ DONE ]
```

### Settings (window)
Navy section bands: VOICE · TRANSCRIPTS · CLAUDE · STARTUP · MODELS · UPDATES; rows beneath each.

## 6. Custom components

| Stock control | Replacement |
|---|---|
| Menu bar icon | `TallyIcon` — waveform outline; filled coral while listening |
| `Toggle` for sources | `SourceTile` — capsule tile with on/off dot, label, mini meter |
| `.borderedProminent` | `TallyButton` — full-width, 40pt, ALL-CAPS Myriad Black, coral / navy / ghost styles |
| `ProgressView` | `SegmentMeter` — 12 segments, green/gold/coral ramp |
| Section headers | `BandHeader` — full-bleed navy color block with Myriad Black caps |
| Transcript list | `LiveLine` — pointer marker, speaker chip, Minion text |
| `ContentUnavailableView` | not used anywhere |

## 7. Motion specifics

| Surface | Trigger | Animation |
|---|---|---|
| Tally strip | state change | color snap 0.15 s |
| LISTENING dot | listening | opacity 1 → 0.35 → 1, 1.4 s |
| Meters | audio | immediate rise, 0.3 s fall |
| Live line | new line | slide up + fade 0.18 s |

## 8. Implementation gates

- [ ] Myriad Pro (Light, Regular, Semibold, Black) and Minion Pro Regular bundled and registered at launch
- [ ] Every color from `Theme`; no hex in views
- [ ] Spacing from `Theme.Space`
- [ ] No `ContentUnavailableView`
- [ ] Custom illustration drawn in code (waveform → lines)
- [ ] Northwoods symbol on the onboarding block
- [ ] Color-block tally strip on every popover state
