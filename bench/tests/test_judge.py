import json

import pytest

from bench import judge

KEY = {
    "decisions": [{"id": "d1", "text": "x", "evidence": "e"}, {"id": "d2", "text": "y", "evidence": "e"}],
    "actions": [{"id": "a1", "task": "t", "owner": "Me", "due": None, "evidence": "e"}],
    "questions": [{"id": "q1", "text": "q", "evidence": "e"}],
    "traps": [{"id": "t1", "kind": "joke", "claim": "c", "evidence": "e"}],
}

SUMMARIES = {("gemma-bigctx", 0): "G0", ("gemma-bigctx", 1): "G1", ("qwen-coder", 0): "Q0",
             ("qwen-coder", 1): "Q1", ("claude-sonnet", 0): "S0", ("claude-sonnet", 1): "S1"}


def test_blind_is_deterministic_and_covers_every_summary():
    a_text, a_map = judge.blind("m01", SUMMARIES, seed="s")
    b_text, b_map = judge.blind("m01", SUMMARIES, seed="s")
    assert a_map == b_map and a_text == b_text
    assert sorted(a_text) == list("ABCDEF")
    assert sorted(tuple(v) for v in a_map.values()) == sorted(SUMMARIES)
    assert {a_text[k] for k in a_text} == set(SUMMARIES.values())


def test_blind_order_differs_between_meetings():
    _, m1 = judge.blind("m01", SUMMARIES, seed="s")
    _, m2 = judge.blind("m02", SUMMARIES, seed="s")
    assert m1 != m2


def test_judge_input_leaks_no_contestant_identity():
    lettered, _ = judge.blind("m01", {k: f"summary text {i}" for i, k in enumerate(SUMMARIES)}, seed="s")
    text = judge.judge_user_message("transcript", KEY, lettered)
    for leak in ("gemma", "qwen", "claude", "sonnet", "rep0", "rep 1", "Puget"):
        assert leak.lower() not in text.lower()


def good_reply(letters="AB"):
    one = {"decisions": {"d1": "hit", "d2": "partial"},
           "actions": {"a1": {"found": "hit", "owner": "right"}},
           "questions": {"q1": "miss"},
           "extras": [{"section": "decisions", "claim": "c", "verdict": "trap", "trap": "t1"}],
           "format_ok": True}
    return {L: one for L in letters}


def test_parse_accepts_fenced_json():
    text = "```json\n" + json.dumps(good_reply()) + "\n```"
    parsed, flags = judge.parse_judgment(text, ["A", "B"], KEY)
    assert parsed["A"]["decisions"]["d2"] == "partial"
    assert parsed["B"]["extras"][0]["trap"] == "t1"
    assert flags == []


def test_parse_rejects_a_missing_letter():
    with pytest.raises(judge.JudgeError):
        judge.parse_judgment(json.dumps(good_reply("A")), ["A", "B"], KEY)


def test_parse_fills_missing_key_ids_as_miss_and_flags_them():
    reply = good_reply("A")
    reply["A"]["decisions"] = {"d1": "hit"}
    del reply["A"]["actions"]["a1"]
    parsed, flags = judge.parse_judgment(json.dumps(reply), ["A"], KEY)
    assert parsed["A"]["decisions"]["d2"] == "miss"
    assert parsed["A"]["actions"]["a1"] == {"found": "miss", "owner": "n/a"}
    assert len(flags) == 2


def test_parse_rejects_unknown_verdicts():
    reply = good_reply("A")
    reply["A"]["decisions"]["d1"] = "kinda"
    with pytest.raises(judge.JudgeError):
        judge.parse_judgment(json.dumps(reply), ["A"], KEY)
    reply = good_reply("A")
    reply["A"]["extras"][0]["trap"] = "t9"
    with pytest.raises(judge.JudgeError):
        judge.parse_judgment(json.dumps(reply), ["A"], KEY)
