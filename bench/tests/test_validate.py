import copy

from bench import validate

TRANSCRIPT = """Lobby screens check-in
Tuesday, October 13, 2026 · 2:00 PM · 2 min · Room
Transcribed by Minutes. Audio was not recorded.

[00:00:04] Me: Okay Dana, let's look at the lobby screens.
[00:00:20] Speaker 1: The left one keeps dropping signal again.
[00:00:41] Me: Let's just replace the HDMI extender on that side.
[00:00:55] Speaker 1: Sure, I'll order one today.
[00:01:10] Speaker 1: What if we moved the whole thing to NDI someday?
[00:01:30] Me: Maybe, not now. Who owns the budget line for it, though?
[00:01:52] Unknown: Yeah.
"""

KEY = {
    "id": "m99", "title": "Lobby screens check-in", "type": "one-on-one", "minutes": 2, "sources": ["room"],
    "control": False,
    "people": [{"label": "Me", "name": "Aaron", "role": "AVL director"},
               {"label": "Speaker 1", "name": "Dana", "role": "AV tech"}],
    "decisions": [{"id": "d1", "text": "Replace the left HDMI extender",
                   "evidence": "Let's just replace the HDMI extender on that side."}],
    "actions": [{"id": "a1", "task": "Order an HDMI extender", "owner": "Speaker 1", "due": "today",
                 "evidence": "I'll order one today."}],
    "questions": [{"id": "q1", "text": "Who owns the budget line", "evidence": "Who owns the budget line for it"}],
    "traps": [{"id": "t1", "kind": "hypothetical", "claim": "They decided to move to NDI",
               "evidence": "What if we moved the whole thing to NDI someday?"},
              {"id": "t2", "kind": "tentative", "claim": "NDI move approved for later",
               "evidence": "Maybe, not now."}],
}

BRIEF = {"id": "m99", "minutes": 2, "words": 55, "control": False}


def problems(transcript=TRANSCRIPT, key=KEY, brief=BRIEF):
    return validate.check(transcript, key, brief)


def test_valid_meeting_has_no_problems():
    assert problems() == []


def test_evidence_must_be_exact_substring():
    key = copy.deepcopy(KEY)
    key["actions"][0]["evidence"] = "I will order one today."
    assert any("a1" in p and "evidence" in p for p in problems(key=key))


def test_line_format_is_enforced():
    bad = TRANSCRIPT.replace("[00:00:20] Speaker 1:", "[0:20] Speaker 1:")
    assert any("line" in p for p in problems(transcript=bad))


def test_unknown_label_name_is_rejected():
    bad = TRANSCRIPT.replace("[00:00:20] Speaker 1:", "[00:00:20] Dana:")
    assert any("line" in p for p in problems(transcript=bad))


def test_timestamps_must_not_go_backwards():
    bad = TRANSCRIPT.replace("[00:00:55]", "[00:00:30]").replace("[00:00:41]", "[00:00:50]")
    assert any("backwards" in p for p in problems(transcript=bad))


def test_header_minutes_must_match_brief():
    bad = TRANSCRIPT.replace("· 2 min ·", "· 5 min ·")
    assert any("header" in p for p in problems(transcript=bad))


def test_length_out_of_range_is_flagged():
    assert any("words" in p for p in problems(brief=dict(BRIEF, words=400)))


def test_duplicate_ids_are_flagged():
    key = copy.deepcopy(KEY)
    key["traps"][1]["id"] = "t1"
    assert any("duplicate" in p for p in problems(key=key))


def test_control_meeting_must_have_no_decisions():
    assert any("control" in p for p in problems(key=dict(KEY, control=True), brief=dict(BRIEF, control=True)))


def test_regular_meeting_needs_a_decision_and_two_traps():
    key = copy.deepcopy(KEY)
    key["decisions"] = []
    key["traps"] = key["traps"][:1]
    found = problems(key=key)
    assert any("decision" in p for p in found)
    assert any("trap" in p for p in found)


def test_owner_must_be_a_present_label_or_named_in_transcript():
    key = copy.deepcopy(KEY)
    key["actions"][0]["owner"] = "Caller 3"
    assert any("owner" in p for p in problems(key=key))
    key["actions"][0]["owner"] = "Dana"
    assert not any("owner" in p for p in problems(key=key))


def test_unknown_trap_kind_is_flagged():
    key = copy.deepcopy(KEY)
    key["traps"][0]["kind"] = "sarcasm"
    assert any("kind" in p for p in problems(key=key))


def test_corpus_level_trap_coverage_and_controls():
    keys = {f"m{i:02d}": {"control": i <= 3, "traps": [{"kind": "joke"}]} for i in range(1, 31)}
    issues = validate.corpus_checks(keys)
    assert any("reversed" in p for p in issues)   # kinds never used
    assert not any("control" in p for p in issues)
    keys["m04"]["control"] = True
    assert any("control" in p for p in validate.corpus_checks(keys))
