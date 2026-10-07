import json

from bench import run_local


def sse(*objs, done=True):
    lines = [b": keep-alive\n", b"\n"]
    for o in objs:
        lines += [b"data: " + json.dumps(o).encode() + b"\n", b"\n"]
    if done:
        lines.append(b"data: [DONE]\n")
    return lines


def delta(**d):
    return {"choices": [{"index": 0, "delta": d, "finish_reason": None}]}


def test_parse_sse_collects_content_reasoning_usage_and_timings():
    stream = sse(
        delta(reasoning_content="Let me think. "), delta(reasoning_content="Done."),
        delta(content="## Summary\n"), delta(content="Short."),
        {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
         "timings": {"prompt_ms": 9900.0, "predicted_ms": 52000.0}},
        {"choices": [], "usage": {"prompt_tokens": 16500, "completion_tokens": 1584}},
    )
    out = run_local.parse_sse(stream)
    assert out["content"] == "## Summary\nShort."
    assert out["reasoning"] == "Let me think. Done."
    assert out["finish_reason"] == "stop"
    assert out["usage"]["completion_tokens"] == 1584
    assert out["timings"]["predicted_ms"] == 52000.0


def test_parse_sse_reports_truncation():
    stream = sse(delta(reasoning_content="loop " * 5),
                 {"choices": [{"index": 0, "delta": {}, "finish_reason": "length"}]})
    out = run_local.parse_sse(stream)
    assert out["finish_reason"] == "length"
    assert out["content"] == ""


def test_parse_sse_accepts_reasoning_field_alias_and_missing_done():
    out = run_local.parse_sse(sse(delta(reasoning="hmm"), delta(content="ok"), done=False))
    assert out["reasoning"] == "hmm"
    assert out["content"] == "ok"
    assert out["finish_reason"] is None


def test_clean_summary_strips_leaked_think_tags_and_fences():
    raw = "<think>private</think>\n```markdown\n## Summary\nText.\n```"
    assert run_local.clean_summary(raw) == "## Summary\nText."


def test_clean_summary_leaves_plain_summary_alone():
    assert run_local.clean_summary("## Summary\nText.\n") == "## Summary\nText."
