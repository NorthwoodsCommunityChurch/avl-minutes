"""Song prep logic for the Planning Center MCP server: what a song's structure says about how it
starts and ends, plus a small store for what Aaron himself says about a song's energy.

Pure functions only (no network) so they can be unit tested; server.py gathers the PCO data and
calls these. Energy here is an inference from structure, never a measurement: the labels come with
their reasons, and Aaron's own note (NotesStore) always outranks them.
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Optional

CUE_WORDS = re.compile(
    r"\b(soft|softly|quiet|quietly|gentle|gently|build|builds|building|swell|swells|big|huge|full band|full|"
    r"pads?|piano only|acoustic|a ?cappella|drums? (?:in|out)|half[- ]?time|double[- ]?time|drop|breakdown|"
    r"hit|hits|stop|stops|hold|rit\.?|ritard|slow down|free|free worship|instrumental|solo|crescendo|dim\.?|"
    r"decrescendo|fade|tag|vamp|space)(?!\w)",
    re.IGNORECASE,
)
SECTION_HEAD = re.compile(
    r"^(Intro|Verse|Pre[- ]?Chorus|Chorus|Bridge|Tag|Turn(?:around)?|Inter(?:lude)?|Instrumental|Refrain|Vamp|"
    r"Outro|Ending|End|Breakdown|Solo)\b.*$",
    re.IGNORECASE,
)
QUIET_SECTIONS = {"intro", "verse", "vamp", "tag", "turnaround", "turn", "prechorus", "pre-chorus", "pre chorus", "refrain"}
BIG_SECTIONS = {"chorus", "bridge", "instrumental", "interlude", "inter", "breakdown", "solo"}
ENDING_WORDS = {"ending", "end", "outro"}


def chart_cues(text: str) -> dict:
    """Section headings and dynamics cue words found in a chart's text (number chart PDFs)."""
    words = sorted({m.group(1).lower() for m in CUE_WORDS.finditer(text or "")})
    sections = [line.strip() for line in (text or "").splitlines() if SECTION_HEAD.match(line.strip())]
    return {"words": words, "sections": sections}


def _who_sings(vocals_note: str, section: str) -> Optional[str]:
    """From a Vocals note ("• 1 Verse – WL", "• 8 Bridge – WT Unis"), who sings the first line that
    names this section: "leader alone", "whole team", or "parts"."""
    if not vocals_note:
        return None
    key = section.lower().rstrip("s")
    for line in vocals_note.splitlines():
        low = line.lower()
        if key not in low:
            continue
        if re.search(r"\bwl\b|leads?\b|worship leader", low):
            return "leader alone"
        if re.search(r"\bwt\b|whole team|unis", low):
            return "whole team"
        if re.search(r"\(mel\)|\(harm\)|parts|\bsat\b|\bats\b|\btsa\b|\bsa\b", low):
            return "parts"
        return None
    return None


def _label(sections: list[str], singer: Optional[str], bpm: Optional[float], cues: list[str], ending: bool) -> tuple[str, list[str]]:
    score = 0
    why: list[str] = []
    names = [s.lower() for s in sections]
    core = [n for n in names if n not in ENDING_WORDS] or names
    if core and all(n in QUIET_SECTIONS for n in core):
        score -= 1; why.append(f"{' then '.join(sections)}: quiet sections")
    elif any(n in BIG_SECTIONS for n in core):
        score += 1; why.append(f"{' then '.join(sections)}: big sections")
    if ending and len(core) >= 2 and core[-1] == core[-2] and core[-1] in BIG_SECTIONS:
        score += 1; why.append("repeated at the end")
    if singer == "leader alone":
        score -= 1; why.append("leader alone")
    elif singer == "whole team":
        score += 1; why.append("whole team singing")
    if bpm:
        if bpm >= 110: score += 1; why.append(f"{int(bpm)} BPM, up-tempo")
        elif bpm <= 76: score -= 1; why.append(f"{int(bpm)} BPM, slow")
    quiet_cues = [c for c in cues if c in {"soft", "softly", "quiet", "quietly", "gentle", "gently", "pad", "pads", "piano only", "acoustic", "a cappella", "acappella", "space", "fade", "rit.", "rit", "ritard", "slow down"}]
    loud_cues = [c for c in cues if c in {"big", "huge", "full", "full band", "build", "builds", "building", "swell", "swells", "hit", "hits", "crescendo"}]
    if quiet_cues: score -= 1; why.append("chart says " + ", ".join(quiet_cues))
    if loud_cues: score += 1; why.append("chart says " + ", ".join(loud_cues))
    label = "high" if score >= 2 else "low" if score <= -1 else "medium"
    return label, why


def structure_summary(sequence_full: list[str], vocals_note: str, bpm: Optional[float], chart_text: str, description: str) -> dict:
    """How the song starts and ends, inferred from the arrangement sequence, who sings, tempo, chart
    cue words, and the item description. Returns labels with reasons and a confidence."""
    seq = [s for s in (sequence_full or []) if s]
    if not seq:
        return {"start": {"sections": [], "energy": "unknown", "why": "no arrangement sequence in PCO"},
                "end": {"sections": [], "energy": "unknown", "landing": "unknown", "why": "no arrangement sequence in PCO"},
                "tempo": _tempo(bpm), "confidence": "none"}
    cues = chart_cues(chart_text)
    text_low = (chart_text or "").lower()
    desc_low = (description or "").lower()
    start_sections = seq[:3]
    end_sections = seq[-3:]
    start_label, start_why = _label(start_sections, _who_sings(vocals_note, start_sections[0] if start_sections[0].lower() not in {"intro", "vamp"} else (start_sections[1] if len(start_sections) > 1 else start_sections[0])), bpm, [], ending=False)
    end_core = [s for s in end_sections if s.lower() not in ENDING_WORDS] or end_sections
    end_cues = [w for w in cues["words"] if w in {"rit.", "rit", "ritard", "slow down", "fade", "space", "free", "free worship", "a cappella", "pads", "pad", "soft", "softly", "build", "builds", "swell", "big", "full"}]
    end_label, end_why = _label(end_sections, _who_sings(vocals_note, end_core[-1]), bpm, end_cues, ending=True)
    if "space at the end" in desc_low or "allow some space" in desc_low:
        end_label = "low" if end_label != "high" else "medium"; end_why.append("description: allow space at the end")
    landing = "hard stop"
    if any(k in text_low for k in ("rit.", "ritard", "slow down", "fade")) or "space" in desc_low:
        landing = "soft landing"
    elif "free worship" in desc_low or "free worship" in text_low or "instrumental" in (end_core[-1].lower() if end_core else ""):
        landing = "open ended"
    confidence = "medium" if (vocals_note and chart_text) else "low"
    return {
        "start": {"sections": start_sections, "energy": start_label, "why": "; ".join(start_why) or "structure only"},
        "end": {"sections": end_sections, "energy": end_label, "landing": landing, "why": "; ".join(end_why) or "structure only"},
        "tempo": _tempo(bpm),
        "chart_cues": cues["words"],
        "confidence": confidence,
    }


def _tempo(bpm: Optional[float]) -> str:
    if not bpm:
        return "unknown"
    b = int(bpm)
    return f"slow ({b} BPM)" if b <= 76 else f"up-tempo ({b} BPM)" if b >= 110 else f"mid ({b} BPM)"


class NotesStore:
    """What Aaron said about a song's energy, keyed by song title (case-insensitive), in one JSON file."""

    def __init__(self, path: Path | str):
        self.path = Path(path)

    def _load(self) -> dict[str, Any]:
        try:
            return json.loads(self.path.read_text())
        except Exception:
            return {}

    def get(self, song: str) -> Optional[dict]:
        return self._load().get(song.strip().lower())

    def set(self, song: str, note: str) -> dict:
        data = self._load()
        entry = {"song": song.strip(), "note": note.strip()}
        data[song.strip().lower()] = entry
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(data, indent=2, ensure_ascii=False))
        return entry

    def all(self) -> dict[str, dict]:
        return self._load()
