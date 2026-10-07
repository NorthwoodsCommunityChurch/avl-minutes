from collections import Counter

from bench import common, validate


def test_briefs_match_the_spec_distribution():
    briefs = common.load_briefs()
    assert len(briefs) == 30
    assert Counter(b["minutes"] for b in briefs) == {10: 6, 20: 6, 30: 7, 45: 5, 60: 4, 90: 2}
    assert sum(b["control"] for b in briefs) == 3
    assert all(b["counts"]["decisions"] == 0 for b in briefs if b["control"])
    assert all(b["counts"]["decisions"] >= 1 for b in briefs if not b["control"])
    kinds = Counter(t for b in briefs for t in b["traps"])
    assert all(kinds[k] >= 3 for k in validate.TRAP_KINDS)
    assert all(len(b["traps"]) >= 2 for b in briefs)
    sources = Counter(tuple(b["sources"]) for b in briefs)
    assert sources[("room",)] == sources[("call",)] == sources[("room", "call")] == 10
