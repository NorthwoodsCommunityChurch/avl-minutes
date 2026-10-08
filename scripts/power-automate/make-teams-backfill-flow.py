#!/usr/bin/env python3
"""Builds the "AI Feed: teams backfill" Power Automate import package from an export of the live
"AI Feed: teams" flow (so it reuses Aaron's connection ids). Run once, import the zip in Power Automate
(My flows > Import > Import package (legacy)), map the three connections, then run the flow by hand.

    python3 scripts/power-automate/make-teams-backfill-flow.py <exported-teams-flow.zip> <out.zip> [since-iso]

What the flow does: lists every chat Aaron is in, pages each one back 50 messages at a time (newest
first, by lastModifiedDateTime, the only field Graph lets a chat be paged on) until it reaches the
`since` date, and writes one JSON file per real message (system events dropped) into OneDrive
"AI Feed/teams" in the same shape the live flow writes. The helper groups Teams records by message
id, so overlap with the live flow is harmless.
"""
import datetime
import json
import os
import shutil
import sys
import tempfile
import uuid
import zipfile

src_zip, out_zip = sys.argv[1], sys.argv[2]
since = sys.argv[3] if len(sys.argv) > 3 else "2026-01-01T00:00:00.000Z"
work = tempfile.mkdtemp()
src = os.path.join(work, "src"); out = os.path.join(work, "out")
with zipfile.ZipFile(src_zip) as z: z.extractall(src)
flows_dir = os.path.join(src, "Microsoft.Flow", "flows")
old_flow = [d for d in os.listdir(flows_dir) if os.path.isdir(os.path.join(flows_dir, d))][0]

m = json.load(open(f"{src}/manifest.json"))
new_flow = str(uuid.uuid4())
flowres = m["resources"].pop(old_flow)
flowres["details"]["displayName"] = "AI Feed: teams backfill"
flowres["suggestedCreationType"] = "New"
m["resources"] = {new_flow: flowres, **m["resources"]}
m["details"].update(displayName="teams backfill", description=f"Run once: copies every chat message since {since[:10]} into OneDrive AI Feed/teams.",
                    createdTime=datetime.datetime.now(datetime.UTC).isoformat().replace("+00:00", "Z"), packageTelemetryId=str(uuid.uuid4()))
os.makedirs(f"{out}/Microsoft.Flow/flows/{new_flow}")
json.dump(m, open(f"{out}/manifest.json", "w"), separators=(",", ":"))
json.dump({"packageSchemaVersion": "1.0", "flowAssets": {"assetPaths": [new_flow]}}, open(f"{out}/Microsoft.Flow/flows/manifest.json", "w"), separators=(",", ":"))
for f in ("apisMap.json", "connectionsMap.json"):
    shutil.copy(f"{flows_dir}/{old_flow}/{f}", f"{out}/Microsoft.Flow/flows/{new_flow}/{f}")

d = json.load(open(f"{flows_dir}/{old_flow}/definition.json"))
new_id = str(uuid.uuid4())
d["name"] = new_id; d["id"] = f"/providers/Microsoft.Flow/flows/{new_id}"
d["properties"]["displayName"] = "AI Feed: teams backfill"
teams = {"apiId": "/providers/Microsoft.PowerApps/apis/shared_teams", "connectionName": "shared_teams"}
conv = {"apiId": "/providers/Microsoft.PowerApps/apis/shared_conversionservice", "connectionName": "shared_conversionservice"}
od = {"apiId": "/providers/Microsoft.PowerApps/apis/shared_onedriveforbusiness", "connectionName": "shared_onedriveforbusiness"}
auth = "@parameters('$authentication')"

def after(names): return {n: ["Succeeded"] for n in names}
def api(host, op, params, run_after=(), extra=None):
    a = {"type": "OpenApiConnection", "inputs": {"parameters": params, "host": {**host, "operationId": op}, "authentication": auth}}
    if run_after: a["runAfter"] = after(run_after)
    if extra: a.update(extra)
    return a
def init(name, typ, value, run_after=()):
    a = {"type": "InitializeVariable", "inputs": {"variables": [{"name": name, "type": typ, "value": value}]}}
    if run_after: a["runAfter"] = after(run_after)
    return a
def setvar(name, value, run_after=()):
    a = {"type": "SetVariable", "inputs": {"name": name, "value": value}}
    if run_after: a["runAfter"] = after(run_after)
    return a

per_message = {
    "Html_to_text": api(conv, "HtmlToText", {"Content": "<p class=\"editor-paragraph\">@{item()?['body']?['content']}</p>"}),
    "Compose": {"type": "Compose", "runAfter": after(["Html_to_text"]), "inputs": {
        "type": "teams",
        "chat": "@{item()?['chatId']}",
        "from": "@{coalesce(item()?['from']?['user']?['displayName'], item()?['from']?['application']?['displayName'], '')}",
        "created": "@{item()?['createdDateTime']}",
        "id": "@{item()?['id']}",
        "body": "@{body('Html_to_text')}"}},
    "Create_file": api(od, "CreateFile", {
        "folderPath": "/AI Feed/teams",
        "name": "@concat('backfill-', formatDateTime(utcNow(),'yyyyMMdd-HHmmss'), '-', rand(1000,9999), '.json')",
        "body": "@outputs('Compose')"}, run_after=["Compose"], extra={"runtimeConfiguration": {"contentTransfer": {"transferMode": "Chunked"}}}),
}
page = {
    "Get_messages": api(teams, "GetMessagesFromChat", {
        "chatId": "@items('For_each_chat')?['id']",
        "$filter": "lastModifiedDateTime gt @{variables('since')} and lastModifiedDateTime lt @{variables('cursor')}",
        "$orderby": "lastModifiedDateTime desc",
        "$top": "50"}),
    "Keep_real_messages": {"type": "Query", "runAfter": after(["Get_messages"]), "inputs": {
        "from": "@outputs('Get_messages')?['body/value']",
        "where": "@and(equals(item()?['messageType'], 'message'), greaterOrEquals(item()?['createdDateTime'], variables('since')))"}},
    "For_each_message": {"type": "Foreach", "runAfter": after(["Keep_real_messages"]), "foreach": "@body('Keep_real_messages')",
                         "actions": per_message, "runtimeConfiguration": {"concurrency": {"repetitions": 10}}},
    "Next_cursor": {"type": "Compose", "runAfter": after(["For_each_message"]),
                    "inputs": "@if(greater(length(outputs('Get_messages')?['body/value']), 0), last(outputs('Get_messages')?['body/value'])?['lastModifiedDateTime'], variables('cursor'))"},
    "Set_cursor": setvar("cursor", "@outputs('Next_cursor')", run_after=["Next_cursor"]),
    "Set_more": setvar("more", "@greaterOrEquals(length(outputs('Get_messages')?['body/value']), 50)", run_after=["Set_cursor"]),
}
per_chat = {
    "Reset_cursor": setvar("cursor", "@utcNow()"),
    "Reset_more": setvar("more", True, run_after=["Reset_cursor"]),
    "Page_back_through_the_chat": {"type": "Until", "runAfter": after(["Reset_more"]), "expression": "@equals(variables('more'), false)",
                                   "limit": {"count": 60, "timeout": "PT3H"}, "actions": page},
}
defn = d["properties"]["definition"]
defn["triggers"] = {"manual": {"type": "Request", "kind": "Button", "inputs": {"schema": {"type": "object", "properties": {}, "required": []}}}}
defn["actions"] = {
    "Initialize_since": init("since", "String", since),
    "Initialize_cursor": init("cursor", "String", "@utcNow()", run_after=["Initialize_since"]),
    "Initialize_more": init("more", "Boolean", True, run_after=["Initialize_cursor"]),
    "List_chats": api(teams, "GetChats", {"chatType": "all", "topic": "all"}, run_after=["Initialize_more"]),
    "For_each_chat": {"type": "Foreach", "runAfter": after(["List_chats"]), "foreach": "@outputs('List_chats')?['body/value']",
                      "actions": per_chat, "runtimeConfiguration": {"concurrency": {"repetitions": 1}}},
}
json.dump(d, open(f"{out}/Microsoft.Flow/flows/{new_flow}/definition.json", "w"), indent=1)
with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(out):
        for f in files:
            full = os.path.join(root, f); z.write(full, os.path.relpath(full, out))
print(f"wrote {out_zip} (flow {new_flow})")
