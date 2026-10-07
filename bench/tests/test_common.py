import json

from bench import common


def test_done_pairs_reads_meeting_and_rep_and_skips_blank_lines(tmp_path):
    path = tmp_path / "results.jsonl"
    path.write_text(json.dumps({"meeting": "m01", "rep": 0}) + "\n\n" + json.dumps({"meeting": "m02", "rep": 1}) + "\n")
    assert common.done_pairs(path) == {("m01", 0), ("m02", 1)}


def test_done_pairs_of_missing_file_is_empty(tmp_path):
    assert common.done_pairs(tmp_path / "nope.jsonl") == set()


def test_append_jsonl_round_trips_unicode(tmp_path):
    path = tmp_path / "out" / "rows.jsonl"
    common.append_jsonl(path, {"meeting": "m01", "rep": 0, "text": "Caller 1 — café ✓"})
    common.append_jsonl(path, {"meeting": "m02", "rep": 0, "text": "two"})
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    assert rows[0]["text"] == "Caller 1 — café ✓"
    assert len(rows) == 2
