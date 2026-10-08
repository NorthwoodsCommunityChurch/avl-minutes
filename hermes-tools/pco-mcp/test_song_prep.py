"""Pure-logic tests for song_prep (no network). Run: python3 -m pytest test_song_prep.py -q"""
import json
import song_prep as sp


def test_chart_cues_finds_dynamics_words_and_section_heads():
    text = "Intro (2x)\n15 / / / |\nVerse 1\nsoft, pads only\nBridge (3x)\nbuild\nEnding\nrit.\n"
    cues = sp.chart_cues(text)
    assert cues["words"] == ["build", "pads", "rit.", "soft"]
    assert cues["sections"] == ["Intro (2x)", "Verse 1", "Bridge (3x)", "Ending"]


def test_structure_summary_low_start_high_end():
    s = sp.structure_summary(
        sequence_full=["Intro", "Verse", "Verse", "Chorus", "Turnaround", "Verse", "Chorus", "Chorus", "Interlude", "Interlude",
                       "Bridge", "Bridge", "Bridge", "Instrumental", "Chorus", "Chorus", "Bridge", "Bridge", "Ending"],
        vocals_note="• 1 Verse – WL\n• 2 Chorus – AT (mel), S (harm)\n• 8 Bridge – WT Unis",
        bpm=115, chart_text="Intro (2x)\nInstrumental 1 (2x)\nBridge (3x)\nEnd", description="Josh")
    assert s["start"]["sections"] == ["Intro", "Verse", "Verse"]
    assert s["start"]["energy"] == "low"
    assert "leader alone" in s["start"]["why"]
    assert s["end"]["sections"] == ["Bridge", "Bridge", "Ending"]
    assert s["end"]["energy"] == "high"
    assert "whole team" in s["end"]["why"]
    assert s["end"]["landing"] == "hard stop"


def test_structure_summary_soft_landing_from_description_and_rit():
    s = sp.structure_summary(
        sequence_full=["Verse", "Tag", "Chorus", "Verse", "Tag", "Chorus", "Chorus", "Tag", "Interlude", "Bridge", "Bridge",
                       "Chorus", "Chorus", "Tag", "Tag", "Verse", "Tag", "Ending"],
        vocals_note="• 1 Verse – WL\n• 6 Verse – WL\n• Lindsay leads",
        bpm=70, chart_text="Verse 1\nChorus 1\nrit.\nVerse 1", description="Lindsay / Allow some space at the end")
    assert s["end"]["energy"] == "low"
    assert s["end"]["landing"] == "soft landing"
    assert "space at the end" in s["end"]["why"]
    assert s["tempo"] == "slow (70 BPM)"


def test_structure_summary_without_data_is_honest():
    s = sp.structure_summary(sequence_full=[], vocals_note="", bpm=None, chart_text="", description="")
    assert s["start"]["energy"] == "unknown" and s["end"]["energy"] == "unknown"
    assert s["confidence"] == "none"


def test_notes_store_round_trip(tmp_path):
    f = tmp_path / "notes.json"
    store = sp.NotesStore(f)
    assert store.get("Abide") is None
    store.set("Abide", "Starts on pads, swells into the last chorus, hard stop.")
    assert store.get("abide")["note"].startswith("Starts on pads")
    assert json.load(open(f))["abide"]["song"] == "Abide"
