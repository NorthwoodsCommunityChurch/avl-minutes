#!/usr/bin/env python3
"""
Planning Center (PCO) Services MCP server
=========================================

Runs locally on your machine and connects to the Planning Center *Services*
API so Claude can pull weekend service-planning data and build broadcast
rundown sheets.

Exposed tools:
    - test_connection        : verify credentials + list accessible service types
    - list_service_types     : all service types (e.g. "Weekend Services")
    - list_plans             : upcoming/past plans for a service type
    - get_plan               : details for one plan
    - get_plan_times         : service times (Sat 5pm, Sun 9/11, etc.)
    - get_plan_items         : the ordered run of items (the rundown backbone),
                               including per-item department notes
    - get_plan_notes         : plan-level notes by category
    - get_team_members       : who's scheduled (producer, lighting, video, ...)
    - get_weekend_rundown_data : one-call consolidated pull for a rundown
    - song_prep              : per-song prep sheet with inferred start/end energy (Hermes)
    - song_energy_note(s)    : Aaron's own energy notes per song, kept in song-energy-notes.json

Auth: HTTP Basic using a Personal Access Token (Application ID + Secret).
Credentials are read from PCO_APP_ID and PCO_SECRET, supplied either by a
.env file in this folder or by the MCP host config. Nothing is hardcoded.

Quick check from a terminal:
    python3 server.py --selftest
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any, Optional

import httpx

# Load .env from this script's own directory (robust regardless of cwd).
try:
    from dotenv import load_dotenv

    load_dotenv(Path(__file__).resolve().parent / ".env")
except Exception:
    pass

from mcp.server.fastmcp import FastMCP

PCO_BASE = "https://api.planningcenteronline.com"
SERVICES = f"{PCO_BASE}/services/v2"
TIMEOUT = 30.0
USER_AGENT = "weekend-rundown-mcp/1.0"

mcp = FastMCP("planning-center")

# Song prep (what a song's structure says about its start and end, plus Aaron's own energy notes).
# Pure logic lives in song_prep.py so it can be unit tested without the network.
import song_prep as _songprep  # noqa: E402

SONG_NOTES_FILE = Path(os.environ.get("SONG_NOTES_FILE") or (Path(__file__).resolve().parent / "song-energy-notes.json"))
CHART_CACHE_FILE = Path(__file__).resolve().parent / "chart-text-cache.json"


# --------------------------------------------------------------------------- #
# HTTP plumbing
# --------------------------------------------------------------------------- #
def _auth() -> tuple[str, str]:
    app_id = os.environ.get("PCO_APP_ID", "").strip()
    secret = os.environ.get("PCO_SECRET", "").strip()
    if not app_id or not secret:
        raise RuntimeError(
            "Missing PCO credentials. Set PCO_APP_ID and PCO_SECRET in "
            "pco-mcp/.env (or in the MCP host's env config)."
        )
    return app_id, secret


def _client() -> httpx.Client:
    return httpx.Client(
        auth=_auth(),
        timeout=TIMEOUT,
        headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
    )


def _explain_http_error(e: httpx.HTTPStatusError) -> str:
    code = e.response.status_code
    hints = {
        401: "Authentication failed. Check PCO_APP_ID / PCO_SECRET and that the token is active.",
        403: "Permission denied. The token may lack access to the Services app or this resource.",
        404: "Not found. Double-check the service_type_id / plan_id.",
        429: "Rate limited by Planning Center. Wait a moment and retry.",
    }
    hint = hints.get(code, "")
    try:
        body = e.response.text[:400]
    except Exception:
        body = ""
    return f"PCO API error {code}. {hint} {body}".strip()


def _get(path_or_url: str, params: Optional[dict] = None) -> dict:
    url = path_or_url if path_or_url.startswith("http") else f"{SERVICES}{path_or_url}"
    try:
        with _client() as c:
            r = c.get(url, params=params)
            r.raise_for_status()
            return r.json()
    except httpx.HTTPStatusError as e:
        raise RuntimeError(_explain_http_error(e)) from None
    except RuntimeError:
        raise  # e.g. missing-credentials message from _auth(); keep it as-is
    except Exception as e:  # noqa: BLE001 — any transport/SSL/proxy error
        raise RuntimeError(
            f"Could not reach Planning Center ({type(e).__name__}): {e}"
        ) from None


def _get_all(path: str, params: Optional[dict] = None, max_records: int = 500) -> dict:
    """Follow links.next to collect paginated `data` (and `included`), capped."""
    params = dict(params or {})
    params.setdefault("per_page", 100)
    all_data: list[dict] = []
    all_included: list[dict] = []
    next_url: Optional[str] = f"{SERVICES}{path}"
    use_params: Optional[dict] = params
    while next_url and len(all_data) < max_records:
        payload = _get(next_url, use_params)
        use_params = None  # `next` links already carry the query params
        all_data.extend(payload.get("data", []))
        all_included.extend(payload.get("included", []))
        next_url = (payload.get("links") or {}).get("next")
    return {"data": all_data, "included": all_included}


def _fmt_len(seconds: Any) -> str:
    """Seconds -> 'm:ss' (PCO item lengths are in seconds)."""
    try:
        s = int(seconds or 0)
    except (TypeError, ValueError):
        return ""
    return f"{s // 60}:{s % 60:02d}"


# --------------------------------------------------------------------------- #
# Core data helpers (return plain Python; tools wrap these as JSON strings)
# --------------------------------------------------------------------------- #
def _service_types() -> list[dict]:
    res = _get_all("/service_types")
    return [
        {
            "id": t["id"],
            "name": t["attributes"].get("name"),
            "frequency": t["attributes"].get("frequency"),
        }
        for t in res["data"]
    ]


def _plans(service_type_id: str, plan_filter: str = "future", count: int = 5) -> list[dict]:
    res = _get(
        f"/service_types/{service_type_id}/plans",
        {"filter": plan_filter, "order": "sort_date", "per_page": count},
    )
    out = []
    for p in res.get("data", []):
        a = p["attributes"]
        out.append(
            {
                "id": p["id"],
                "dates": a.get("dates"),
                "title": a.get("title"),
                "series_title": a.get("series_title"),
                "sort_date": a.get("sort_date"),
                "items_count": a.get("items_count"),   # size of the order of service (0 = nothing planned yet)
            }
        )
    return out


def _plan(service_type_id: str, plan_id: str) -> dict:
    p = _get(f"/service_types/{service_type_id}/plans/{plan_id}")
    a = (p.get("data") or {}).get("attributes", {})
    return {
        "id": plan_id,
        "title": a.get("title"),
        "series_title": a.get("series_title"),
        "dates": a.get("dates"),
        "sort_date": a.get("sort_date"),
        "total_length_seconds": a.get("total_length"),
        "total_length": _fmt_len(a.get("total_length")),
    }


def _plan_times(service_type_id: str, plan_id: str) -> list[dict]:
    res = _get_all(f"/service_types/{service_type_id}/plans/{plan_id}/plan_times")
    out = []
    for t in res["data"]:
        a = t["attributes"]
        out.append(
            {
                "id": t["id"],
                "name": a.get("name"),
                "starts_at": a.get("starts_at"),
                "time_type": a.get("time_type"),  # service / rehearsal / other
            }
        )
    return out


def _plan_items(service_type_id: str, plan_id: str) -> list[dict]:
    res = _get_all(
        f"/service_types/{service_type_id}/plans/{plan_id}/items",
        {"include": "item_notes", "per_page": 100},
    )
    # Index included ItemNote resources by id.
    notes_by_id: dict[str, dict] = {}
    for inc in res["included"]:
        if inc.get("type") == "ItemNote":
            na = inc.get("attributes", {})
            notes_by_id[inc["id"]] = {
                "category": na.get("category_name"),
                "content": na.get("content"),
            }
    items = []
    for it in res["data"]:
        a = it["attributes"]
        rel = it.get("relationships", {}) or {}
        note_refs = (rel.get("item_notes", {}) or {}).get("data") or []
        item_notes = [notes_by_id[r["id"]] for r in note_refs if r.get("id") in notes_by_id]
        items.append(
            {
                "sequence": a.get("sequence"),
                "title": a.get("title"),
                "type": a.get("item_type"),  # song / header / media / item / ...
                "length_seconds": a.get("length"),
                "length": _fmt_len(a.get("length")),
                "service_position": a.get("service_position"),
                "key_name": a.get("key_name"),
                "description": a.get("description"),
                "notes": item_notes,
            }
        )
    items.sort(key=lambda x: (x["sequence"] is None, x["sequence"] or 0))
    return items


def _plan_notes(service_type_id: str, plan_id: str) -> list[dict]:
    res = _get_all(f"/service_types/{service_type_id}/plans/{plan_id}/notes")
    out = []
    for n in res["data"]:
        a = n["attributes"]
        out.append({"category": a.get("category_name"), "content": a.get("content")})
    return out


def _team_members(service_type_id: str, plan_id: str) -> list[dict]:
    res = _get_all(
        f"/service_types/{service_type_id}/plans/{plan_id}/team_members",
        {"include": "team", "per_page": 100},
    )
    teams_by_id: dict[str, Optional[str]] = {}
    for inc in res["included"]:
        if inc.get("type") == "Team":
            teams_by_id[inc["id"]] = inc.get("attributes", {}).get("name")
    out = []
    for m in res["data"]:
        a = m["attributes"]
        rel = m.get("relationships", {}) or {}
        team_ref = (rel.get("team", {}) or {}).get("data") or {}
        out.append(
            {
                "name": a.get("name"),
                "position": a.get("team_position_name"),
                "team": teams_by_id.get(team_ref.get("id")),
                "status": a.get("status"),  # C=confirmed, U=unconfirmed, D=declined
            }
        )
    return out


# --------------------------------------------------------------------------- #
# MCP tools
# --------------------------------------------------------------------------- #
@mcp.tool()
def test_connection() -> str:
    """Verify the PCO credentials work. Returns the authenticated user and the
    service types the token can see. Use this first to confirm setup."""
    me = _get(f"{PCO_BASE}/people/v2/me")
    attrs = (me.get("data") or {}).get("attributes", {})
    name = attrs.get("name") or f"{attrs.get('first_name', '')} {attrs.get('last_name', '')}".strip()
    types = _service_types()
    return json.dumps(
        {
            "ok": True,
            "authenticated_as": name or "(unknown)",
            "service_type_count": len(types),
            "service_types": types,
        },
        indent=2,
    )


@mcp.tool()
def list_service_types() -> str:
    """List all Services service types (e.g. 'Weekend Services'). Returns id + name."""
    return json.dumps(_service_types(), indent=2)


@mcp.tool()
def list_plans(service_type_id: str, plan_filter: str = "future", count: int = 5) -> str:
    """List plans for a service type.

    Args:
        service_type_id: Service type id (from list_service_types).
        plan_filter: 'future' (default), 'past', or 'no_dates'.
        count: How many plans to return (default 5).
    """
    return json.dumps(_plans(service_type_id, plan_filter, count), indent=2)


@mcp.tool()
def get_plan(service_type_id: str, plan_id: str) -> str:
    """Get details for a single plan (title, series, dates, total length)."""
    return json.dumps(_plan(service_type_id, plan_id), indent=2)


@mcp.tool()
def get_plan_times(service_type_id: str, plan_id: str) -> str:
    """Get the service/rehearsal times for a plan."""
    return json.dumps(_plan_times(service_type_id, plan_id), indent=2)


@mcp.tool()
def get_plan_items(service_type_id: str, plan_id: str) -> str:
    """Get the ordered run of items for a plan — the backbone of the rundown.

    Each item includes sequence, title, type, length, description, and any
    per-item department notes (e.g. Lighting / Video / Audio note categories)."""
    return json.dumps(_plan_items(service_type_id, plan_id), indent=2)


@mcp.tool()
def get_plan_notes(service_type_id: str, plan_id: str) -> str:
    """Get plan-level notes (by category) for a plan."""
    return json.dumps(_plan_notes(service_type_id, plan_id), indent=2)


@mcp.tool()
def get_team_members(service_type_id: str, plan_id: str) -> str:
    """Get scheduled team members for a plan (producer, lighting, video, etc.)."""
    return json.dumps(_team_members(service_type_id, plan_id), indent=2)


@mcp.tool()
def get_weekend_rundown_data(
    service_type_id: Optional[str] = None, plan_id: Optional[str] = None
) -> str:
    """One-call pull of everything needed to build a weekend rundown sheet.

    If service_type_id is omitted and exactly one service type exists, it's used;
    otherwise the available types are returned so you can pick one.
    If plan_id is omitted, the next upcoming (future) plan is used.

    Returns: plan info, service times, scheduled team members, plan-level notes,
    and the ordered item run (with per-item department notes)."""
    if not service_type_id:
        types = _service_types()
        if len(types) == 1:
            service_type_id = types[0]["id"]
        else:
            return json.dumps(
                {"need": "service_type_id", "service_types": types}, indent=2
            )

    if not plan_id:
        upcoming = _plans(service_type_id, "future", 1)
        if not upcoming:
            return json.dumps(
                {"error": "No upcoming plans found for this service type."}, indent=2
            )
        plan_id = upcoming[0]["id"]

    return json.dumps(
        {
            "service_type_id": service_type_id,
            "plan": _plan(service_type_id, plan_id),
            "service_times": _plan_times(service_type_id, plan_id),
            "team_members": _team_members(service_type_id, plan_id),
            "plan_notes": _plan_notes(service_type_id, plan_id),
            "items": _plan_items(service_type_id, plan_id),
        },
        indent=2,
    )


def _chart_text(song_id: str, arrangement_id: str) -> str:
    """Text of the arrangement's number chart (or any chart) PDF, cached by attachment id. Empty when
    there is no PDF or it cannot be read; never raises."""
    try:
        atts = _get_all(f"/songs/{song_id}/arrangements/{arrangement_id}/attachments")["data"]
    except Exception:
        return ""
    pdfs = [a for a in atts if (a.get("attributes", {}).get("content_type") or "").lower() == "application/pdf"]
    if not pdfs:
        return ""
    pdfs.sort(key=lambda a: (0 if "number" in (a["attributes"].get("filename") or "").lower() else
                             1 if "chart" in (a["attributes"].get("filename") or "").lower() else 2))
    att = pdfs[0]
    cache: dict[str, str] = {}
    try:
        cache = json.loads(CHART_CACHE_FILE.read_text())
    except Exception:
        pass
    if att["id"] in cache:
        return cache[att["id"]]
    try:
        import io
        from pypdf import PdfReader
        with httpx.Client(auth=_auth(), timeout=TIMEOUT, headers={"User-Agent": USER_AGENT, "Accept": "application/json"}) as c:
            r = c.post(f"{SERVICES}/attachments/{att['id']}/open")
            r.raise_for_status()
            url = (((r.json().get("data") or {}).get("attributes") or {}).get("attachment_url"))
        if not url:
            return ""
        with httpx.Client(timeout=60.0, follow_redirects=True, headers={"User-Agent": USER_AGENT}) as c:
            content = c.get(url).content
        text = "\n".join((page.extract_text() or "") for page in PdfReader(io.BytesIO(content)).pages)
    except Exception:
        return ""
    cache[att["id"]] = text
    try:
        CHART_CACHE_FILE.write_text(json.dumps(cache))
    except Exception:
        pass
    return text


def _song_prep(service_type_id: str, plan_id: str) -> list[dict]:
    res = _get_all(f"/service_types/{service_type_id}/plans/{plan_id}/items",
                   {"include": "song,arrangement,item_notes", "per_page": 100})
    inc = {(d["type"], d["id"]): d for d in res["included"]}
    notes_store = _songprep.NotesStore(SONG_NOTES_FILE)
    out = []
    for it in res["data"]:
        a = it["attributes"]
        if a.get("item_type") != "song":
            continue
        rel = it.get("relationships", {}) or {}
        song_ref = (rel.get("song", {}) or {}).get("data") or {}
        arr_ref = (rel.get("arrangement", {}) or {}).get("data") or {}
        song = inc.get(("Song", song_ref.get("id")))
        arr = inc.get(("Arrangement", arr_ref.get("id")))
        notes = []
        for n in (rel.get("item_notes", {}) or {}).get("data") or []:
            na = (inc.get(("ItemNote", n["id"])) or {}).get("attributes", {})
            if na:
                notes.append({"category": na.get("category_name"), "content": na.get("content")})
        vocals = "\n".join(n["content"] or "" for n in notes if (n["category"] or "").lower().startswith("vocal"))
        aa = (arr or {}).get("attributes", {})
        sequence_full = [s.get("label") for s in (aa.get("sequence_full") or []) if isinstance(s, dict)]
        chart = _chart_text(song_ref.get("id"), arr_ref.get("id")) if song_ref.get("id") and arr_ref.get("id") else ""
        summary = _songprep.structure_summary(sequence_full, vocals, aa.get("bpm"), chart, a.get("description") or "")
        title = a.get("title") or (song or {}).get("attributes", {}).get("title") or ""
        aaron = notes_store.get(title) if title else None
        out.append({
            "sequence": a.get("sequence"),
            "title": title,
            "key": a.get("key_name"),
            "length": _fmt_len(a.get("length")),
            "leader_or_description": a.get("description"),
            "arrangement": aa.get("name"),
            "bpm": aa.get("bpm"),
            "meter": aa.get("meter"),
            "sequence_short": aa.get("sequence_short"),
            "sequence_full": sequence_full,
            "notes": notes,
            "chart_sections": _songprep.chart_cues(chart)["sections"][:30] if chart else [],
            "inferred": summary,
            "aaron_says": aaron["note"] if aaron else None,
        })
    out.sort(key=lambda x: (x["sequence"] is None, x["sequence"] or 0))
    return out


def _default_service_type_id() -> Optional[str]:
    types = _service_types()
    for t in types:
        if (t.get("name") or "").lower().startswith("sunday"):
            return t["id"]
    return types[0]["id"] if len(types) == 1 else None


@mcp.tool()
def song_prep(service_type_id: str = "", plan_id: str = "") -> str:
    """Prep sheet for every song in a plan: key, tempo, leader, arrangement sequence, the team's notes
    (Vocals, Band, Audio/Visual, Intro/Outro...), the chart's section list, and how the song STARTS and
    ENDS: sections, who sings, an inferred energy label (low / medium / high) with the reasons, and the
    landing (hard stop / soft landing / open ended). The inference comes from structure, not a recording;
    "aaron_says" is Aaron's own note for that song and outranks the inference whenever present. When
    aaron_says is null, ask Aaron how the song starts and ends and save his answer with song_energy_note.
    Defaults: service_type_id = the "Sunday" service type, plan_id = its next upcoming plan."""
    st = service_type_id or _default_service_type_id()
    if not st:
        return json.dumps({"error": "Pass service_type_id; several service types exist.", "service_types": _service_types()}, indent=2)
    pid = plan_id
    if not pid:
        plans = _plans(st, "future", 1)
        if not plans:
            return json.dumps({"error": "No upcoming plan for that service type."}, indent=2)
        pid = plans[0]["id"]
    return json.dumps({"service_type_id": st, "plan_id": pid, "songs": _song_prep(st, pid)}, indent=2)


@mcp.tool()
def song_energy_note(song: str, note: str) -> str:
    """Remember what Aaron said about a song's energy (how it starts, how it ends, the landing, anything
    lighting should know). One note per song title, newest wins; song_prep returns it as aaron_says.
    Use this whenever Aaron tells you about a song; never invent a note."""
    if not song.strip() or not note.strip():
        return json.dumps({"error": "song and note are both required."})
    entry = _songprep.NotesStore(SONG_NOTES_FILE).set(song, note)
    return json.dumps({"saved": entry, "file": str(SONG_NOTES_FILE)}, indent=2)


@mcp.tool()
def song_energy_notes() -> str:
    """Every song energy note Aaron has given, keyed by song title."""
    return json.dumps(_songprep.NotesStore(SONG_NOTES_FILE).all(), indent=2)


def _all_attachments(service_type_id: str, plan_id: str) -> list[dict]:
    """Every attachment reachable for a plan: plan-level ("Files") plus files
    attached to individual items (a blocking sheet is often an item attachment).
    Each returned dict is the raw PCO attachment with an extra '_source' label
    (e.g. 'Plan' or 'Item: Message'). Robust to per-item errors."""
    base = f"/service_types/{service_type_id}/plans/{plan_id}"
    found: list[dict] = []

    def _tag(att_list, source):
        for a in att_list:
            a = dict(a)
            a["_source"] = source
            found.append(a)

    # Plan-level (the plan's "Files").
    try:
        _tag(_get_all(f"{base}/attachments")["data"], "Plan")
    except Exception:
        pass
    # Item-level (files attached to individual items).
    try:
        items = _get_all(f"{base}/items")["data"]
    except Exception:
        items = []
    for it in items:
        itid = it.get("id")
        if not itid:
            continue
        title = (it.get("attributes", {}) or {}).get("title") or f"item {itid}"
        try:
            _tag(_get_all(f"{base}/items/{itid}/attachments")["data"], f"Item: {title}")
        except Exception:
            continue
    return found


@mcp.tool()
def get_plan_attachments(service_type_id: str, plan_id: str) -> str:
    """List file attachments for a plan — both plan-level ("Files") and files
    attached to individual items (e.g. a stage blocking sheet). Returns each
    attachment's id, filename, content type, size, and where it's attached.
    Use download_plan_attachment to fetch one."""
    out = []
    for a in _all_attachments(service_type_id, plan_id):
        at = a.get("attributes", {})
        out.append(
            {
                "id": a.get("id"),
                "filename": at.get("filename"),
                "content_type": at.get("content_type"),
                "file_size": at.get("file_size"),
                "page_order": at.get("page_order"),
                "attached_to": a.get("_source"),
            }
        )
    return json.dumps(out, indent=2)


@mcp.tool()
def download_plan_attachment(service_type_id: str, plan_id: str,
                             name_contains: str = "", attachment_id: str = "",
                             dest_dir: str = "") -> str:
    """Download a plan attachment to this project (e.g. the blocking sheet, to merge
    into the rundown as page 2).

    Choose by attachment_id, or by name_contains (case-insensitive substring of the
    filename); defaults to the first attachment if neither is given. Saves into
    rundown-builder/ by default and returns the local path + metadata. This only
    generates a temporary PCO download link (the attachment 'open' action) and
    fetches the file — it does not modify anything in Planning Center."""
    atts = _all_attachments(service_type_id, plan_id)
    if not atts:
        return json.dumps({"error": "No attachments found on this plan or its items."}, indent=2)
    if attachment_id:
        chosen = next((a for a in atts if a.get("id") == attachment_id), None)
    elif name_contains:
        nc = name_contains.lower()
        chosen = next((a for a in atts
                       if nc in (a.get("attributes", {}).get("filename", "") or "").lower()), None)
    else:
        chosen = atts[0]
    if not chosen:
        names = [a.get("attributes", {}).get("filename") for a in atts]
        return json.dumps({"error": "No matching attachment.", "available": names}, indent=2)

    aid = chosen["id"]
    filename = chosen.get("attributes", {}).get("filename") or f"attachment-{aid}"
    try:
        with httpx.Client(auth=_auth(), timeout=TIMEOUT,
                          headers={"User-Agent": USER_AGENT, "Accept": "application/json"}) as c:
            r = c.post(f"{SERVICES}/attachments/{aid}/open")
            r.raise_for_status()
            url = (((r.json().get("data") or {}).get("attributes") or {}).get("attachment_url"))
        if not url:
            return json.dumps({"error": "PCO returned no download URL for this attachment."}, indent=2)
        with httpx.Client(timeout=60.0, follow_redirects=True,
                          headers={"User-Agent": USER_AGENT}) as c:
            fr = c.get(url)
            fr.raise_for_status()
            content = fr.content
    except httpx.HTTPStatusError as e:
        raise RuntimeError(_explain_http_error(e)) from None
    except Exception as e:  # noqa: BLE001
        raise RuntimeError(f"Could not download attachment: {type(e).__name__}: {e}") from None

    base = Path(dest_dir) if dest_dir else (Path(__file__).resolve().parent.parent / "rundown-builder")
    base.mkdir(parents=True, exist_ok=True)
    safe = "".join(ch for ch in filename if ch.isalnum() or ch in "._- ").strip() or f"attachment-{aid}"
    dest = base / safe
    dest.write_bytes(content)
    return json.dumps(
        {
            "saved": str(dest),
            "filename": filename,
            "content_type": chosen.get("attributes", {}).get("content_type"),
            "bytes": len(content),
        },
        indent=2,
    )


# --------------------------------------------------------------------------- #
# Entry point
# --------------------------------------------------------------------------- #
if __name__ == "__main__":
    import sys

    if "--selftest" in sys.argv:
        try:
            print(test_connection())
        except Exception as exc:  # noqa: BLE001
            print(f"Self-test failed: {exc}")
            sys.exit(1)
    else:
        mcp.run()  # stdio transport (what Claude Desktop / Cowork expects)
