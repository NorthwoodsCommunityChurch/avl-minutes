#!/usr/bin/env python3
"""Builds two Power Automate import packages from Aaron's exported AI Feed flows (so they reuse his
connection ids):

  sent      from an export of "AI Feed: mail":     "AI Feed: mail sent" — same flow watching Sent Items,
            JSON carries "direction": "sent" so the helper titles it "To <recipient>: <subject>".
  calendar  from an export of "AI Feed: calendar": "AI Feed: calendar backfill" — run once; writes
            every event from 30 days ago to 120 days ahead (recurring ones expanded) in flow 2's shape.

    python3 scripts/power-automate/make-feed-flows.py sent     <aimail-export.zip>     <out.zip>
    python3 scripts/power-automate/make-feed-flows.py calendar <aicalendar-export.zip> <out.zip>

Import: Power Automate > My flows > Import > Import Package (Legacy), map the three connections.
"""
import datetime
import json
import os
import shutil
import sys
import tempfile
import uuid
import zipfile

kind, src_zip, out_zip = sys.argv[1], sys.argv[2], sys.argv[3]
work = tempfile.mkdtemp()
src = os.path.join(work, "src"); out = os.path.join(work, "out")
with zipfile.ZipFile(src_zip) as z: z.extractall(src)
flows_dir = os.path.join(src, "Microsoft.Flow", "flows")
old_flow = [d for d in os.listdir(flows_dir) if os.path.isdir(os.path.join(flows_dir, d))][0]
d = json.load(open(f"{flows_dir}/{old_flow}/definition.json"))
defn = d["properties"]["definition"]
auth = "@parameters('$authentication')"
def after(names): return {n: ["Succeeded"] for n in names}

if kind == "sent":
    display, desc = "AI Feed: mail sent", "Copies every email Aaron sends into OneDrive AI Feed/mail with a sent marker."
    trig = next(iter(defn["triggers"].values()))
    trig["inputs"]["parameters"]["folderPath"] = "SentItems"
    defn["actions"]["Compose"]["inputs"]["direction"] = "sent"
elif kind == "calendar":
    display, desc = "AI Feed: calendar backfill", "Run once: writes every calendar event from 30 days ago to 120 days ahead into OneDrive AI Feed/calendar."
    trig = next(iter(defn["triggers"].values()))
    calendar_id = trig["inputs"]["parameters"]["table"]
    o365 = {"apiId": "/providers/Microsoft.PowerApps/apis/shared_office365", "connectionName": "shared_office365", "operationId": "GetEventsCalendarViewV3"}
    html_host = defn["actions"]["Html_to_text"]["inputs"]["host"]
    od_host = defn["actions"]["Create_file"]["inputs"]["host"]
    per_event = {
        "Html_to_text": {"type": "OpenApiConnection", "inputs": {"parameters": {"Content": "<p class=\"editor-paragraph\">@{item()?['body']}</p>"}, "host": html_host, "authentication": auth}},
        "Compose": {"type": "Compose", "runAfter": after(["Html_to_text"]), "inputs": {
            "type": "calendar", "action": "backfill",
            "subject": "@{item()?['subject']}", "start": "@{item()?['start']}", "end": "@{item()?['end']}",
            "location": "@{item()?['location']}", "organizer": "@{item()?['organizer']}",
            "attendees": "@{item()?['requiredAttendees']}", "id": "@{item()?['id']}", "body": "@{body('Html_to_text')}"}},
        "Create_file": {"type": "OpenApiConnection", "runAfter": after(["Compose"]), "inputs": {"parameters": {
            "folderPath": "/AI Feed/calendar",
            "name": "@concat('backfill-', formatDateTime(utcNow(),'yyyyMMdd-HHmmss'), '-', rand(1000,9999), '.json')",
            "body": "@outputs('Compose')"}, "host": od_host, "authentication": auth},
            "runtimeConfiguration": {"contentTransfer": {"transferMode": "Chunked"}}},
    }
    page = {
        "Get_calendar_view": {"type": "OpenApiConnection", "inputs": {"parameters": {
            "calendarId": calendar_id,
            "startDateTimeUtc": "@{addDays(utcNow(), -30)}",
            "endDateTimeUtc": "@{addDays(utcNow(), 120)}",
            "$top": 100, "$skip": "@variables('skip')"}, "host": o365, "authentication": auth}},
        "For_each_event": {"type": "Foreach", "runAfter": after(["Get_calendar_view"]), "foreach": "@outputs('Get_calendar_view')?['body/value']",
                           "actions": per_event, "runtimeConfiguration": {"concurrency": {"repetitions": 10}}},
        "Next_skip": {"type": "Compose", "runAfter": after(["For_each_event"]), "inputs": "@add(variables('skip'), 100)"},
        "Set_skip": {"type": "SetVariable", "runAfter": after(["Next_skip"]), "inputs": {"name": "skip", "value": "@outputs('Next_skip')"}},
        "Set_more": {"type": "SetVariable", "runAfter": after(["Set_skip"]), "inputs": {"name": "more", "value": "@greaterOrEquals(length(outputs('Get_calendar_view')?['body/value']), 100)"}},
    }
    defn["triggers"] = {"manual": {"type": "Request", "kind": "Button", "inputs": {"schema": {"type": "object", "properties": {}, "required": []}}}}
    defn["actions"] = {
        "Initialize_skip": {"type": "InitializeVariable", "inputs": {"variables": [{"name": "skip", "type": "Integer", "value": 0}]}},
        "Initialize_more": {"type": "InitializeVariable", "runAfter": after(["Initialize_skip"]), "inputs": {"variables": [{"name": "more", "type": "Boolean", "value": True}]}},
        "Page_through_events": {"type": "Until", "runAfter": after(["Initialize_more"]), "expression": "@equals(variables('more'), false)",
                                "limit": {"count": 30, "timeout": "PT2H"}, "actions": page},
    }
else:
    raise SystemExit("kind must be sent or calendar")

new_id = str(uuid.uuid4())
d["name"] = new_id; d["id"] = f"/providers/Microsoft.Flow/flows/{new_id}"
d["properties"]["displayName"] = display
m = json.load(open(f"{src}/manifest.json"))
new_flow = str(uuid.uuid4())
flowres = m["resources"].pop(old_flow)
flowres["details"]["displayName"] = display; flowres["suggestedCreationType"] = "New"
m["resources"] = {new_flow: flowres, **m["resources"]}
m["details"].update(displayName=display, description=desc, createdTime=datetime.datetime.now(datetime.UTC).isoformat().replace("+00:00", "Z"), packageTelemetryId=str(uuid.uuid4()))
os.makedirs(f"{out}/Microsoft.Flow/flows/{new_flow}")
json.dump(m, open(f"{out}/manifest.json", "w"), separators=(",", ":"))
json.dump({"packageSchemaVersion": "1.0", "flowAssets": {"assetPaths": [new_flow]}}, open(f"{out}/Microsoft.Flow/flows/manifest.json", "w"), separators=(",", ":"))
for f in ("apisMap.json", "connectionsMap.json"):
    shutil.copy(f"{flows_dir}/{old_flow}/{f}", f"{out}/Microsoft.Flow/flows/{new_flow}/{f}")
json.dump(d, open(f"{out}/Microsoft.Flow/flows/{new_flow}/definition.json", "w"), indent=1)
def _check(actions, where="actions"):
    for name, a in actions.items():
        if a.get("type") == "OpenApiConnection":
            host = a["inputs"]["host"]
            assert host.get("operationId") and host.get("connectionName") in d["properties"]["connectionReferences"], f"{where}/{name}: bad host {host}"
        if "actions" in a:
            _check(a["actions"], f"{where}/{name}")
_check(defn["actions"])
with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(out):
        for f in files:
            full = os.path.join(root, f); z.write(full, os.path.relpath(full, out))
print(f"wrote {out_zip}: {display}")
