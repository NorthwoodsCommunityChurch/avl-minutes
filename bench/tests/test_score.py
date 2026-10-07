from bench import score

KEY = {
    "control": False,
    "decisions": [{"id": "d1"}, {"id": "d2"}],
    "actions": [{"id": "a1"}, {"id": "a2"}],
    "questions": [{"id": "q1"}],
    "traps": [{"id": "t1", "kind": "reversed"}, {"id": "t2", "kind": "joke"}],
}
CONTROL = {"control": True, "decisions": [], "actions": [{"id": "a1"}], "questions": [], "traps": [{"id": "t1", "kind": "hypothetical"}]}


def grade(d1="hit", d2="partial", a1=("hit", "right"), a2=("miss", "n/a"), q1="hit", extras=(), fmt=True):
    return {"decisions": {"d1": d1, "d2": d2},
            "actions": {"a1": {"found": a1[0], "owner": a1[1]}, "a2": {"found": a2[0], "owner": a2[1]}},
            "questions": {"q1": q1}, "extras": list(extras), "format_ok": fmt}


ROW = {"status": "ok", "wall_s": 50.0, "model_s": 40.0}


def test_recall_counts_partials_as_half():
    m = score.score_rep([(KEY, grade(), ROW)])
    assert m["decision_recall"] == 0.75          # 1 + 0.5 of 2
    assert m["action_recall"] == 0.5             # 1 of 2
    assert m["core_recall"] == 2.5 / 4
    assert m["question_recall"] == 1.0


def test_owner_accuracy_uses_found_actions_only():
    m = score.score_rep([(KEY, grade(a1=("hit", "wrong"), a2=("partial", "right")), ROW)])
    assert m["owner_accuracy"] == 0.5


def test_invented_decisions_count_invented_and_trap_extras_in_decisions_only():
    extras = [{"section": "decisions", "verdict": "invented", "trap": None},
              {"section": "decisions", "verdict": "trap", "trap": "t1"},
              {"section": "decisions", "verdict": "supported", "trap": None},
              {"section": "actions", "verdict": "invented", "trap": None}]
    m = score.score_rep([(KEY, grade(extras=extras), ROW)])
    assert m["invented_decisions"] == 2
    assert m["invented_actions"] == 1
    assert m["supported_extras"] == 1
    assert m["traps_by_kind"] == {"reversed": 1}


def test_control_meeting_counts_decision_bullets_but_penalizes_only_judged_inventions():
    g = {"decisions": {}, "actions": {"a1": {"found": "hit", "owner": "right"}}, "questions": {},
         "extras": [{"section": "decisions", "verdict": "supported", "trap": None},
                    {"section": "decisions", "verdict": "invented", "trap": None}], "format_ok": True}
    m = score.score_rep([(CONTROL, g, ROW)])
    assert m["control_decisions"] == 2
    assert m["invented_decisions"] == 1


def test_unusable_counts_failed_status_or_bad_format():
    m = score.score_rep([(KEY, grade(fmt=False), ROW), (KEY, grade(), dict(ROW, status="truncated"))])
    assert m["unusable"] == 2


def test_bar_edges():
    ok = {"core_recall": 0.90, "invented_decisions": 1, "unusable": 0, "model_p90_s": 180.0}
    assert score.bar([ok, ok], local=True)["pass"]
    assert not score.bar([ok, dict(ok, invented_decisions=2)], local=True)["pass"]
    assert not score.bar([ok, dict(ok, core_recall=0.899)], local=True)["pass"]
    assert not score.bar([dict(ok, unusable=1), ok], local=True)["pass"]
    assert not score.bar([dict(ok, model_p90_s=181.0), ok], local=True)["pass"]
    assert score.bar([dict(ok, model_p90_s=None), ok], local=False)["pass"]


def test_percentile():
    assert score.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.9) == 9.1
    assert score.percentile([], 0.9) is None
