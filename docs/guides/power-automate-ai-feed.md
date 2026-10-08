# Power Automate → OneDrive "AI Feed" (the mini's view of mail, calendar, and Teams)

Three cloud flows in Aaron's own Power Automate (make.powerautomate.com, work account) copy new items into
OneDrive `AI Feed/` as one small JSON file each. The assistant mini syncs that folder; Hermes Helper indexes it
(next build step) so Hermes can answer from mail, calendar, and chats. Standard connectors only: no admin, no
premium license, nothing leaves Microsoft 365 except into Aaron's own OneDrive. Written 2026-10-08.

Folder (already created from the laptop, syncs everywhere): `AI Feed/mail`, `AI Feed/calendar`, `AI Feed/teams`.

Every flow ends with the same two steps, so the file names sort by time:

- **Compose** (Data Operation) builds the JSON object; dynamic-content fields are escaped by the designer.
- **Create file** (OneDrive for Business): *Folder Path* the subfolder, *File Name* the expression
  `concat(formatDateTime(utcNow(),'yyyyMMdd-HHmmss'),'-',rand(1000,9999),'.json')`, *File Content* = Compose **Outputs**.

To type an expression: click the field → the dynamic content panel → the **Expression** tab (fx) → paste → Add.

## Flow 1 — "AI Feed: mail"

1. **+ Create → Automated cloud flow**, name `AI Feed: mail`, trigger **When a new email arrives (V3)** (Office 365 Outlook) → Create.
2. Trigger: *Folder* = Inbox; **Show advanced options**: *Include Attachments* = No, *Only with Attachments* = No.
3. **+ New step → Html to text** (Content Conversion): *Content* = **Body** (from the trigger).
4. **+ New step → Compose** (Data Operation). In *Inputs* type `{` and paste this, replacing each `«…»` with the dynamic-content field of that name:
   ```json
   {
     "type": "mail",
     "received": "«Received Time»",
     "from": "«From»",
     "to": "«To»",
     "subject": "«Subject»",
     "conversation": "«Conversation Id»",
     "body": "«The plain text content»"
   }
   ```
   (`The plain text content` comes from the Html to text step.)
5. **+ New step → Create file** (OneDrive for Business): *Folder Path* `/AI Feed/mail`; *File Name* = the expression above; *File Content* = **Outputs** (from Compose).
6. **Save**, then **Test → Manually** and send yourself an email. A file appears in `AI Feed/mail` within a minute or two.

## Flow 2 — "AI Feed: calendar"

1. Automated cloud flow `AI Feed: calendar`, trigger **When an event is added, updated or deleted (V3)** (Office 365 Outlook); *Calendar id* = Calendar.
2. **Html to text**: *Content* = **Body**.
3. **Compose**:
   ```json
   {
     "type": "calendar",
     "action": "«Action Type»",
     "subject": "«Subject»",
     "start": "«Start time»",
     "end": "«End time»",
     "location": "«Location»",
     "organizer": "«Organizer»",
     "attendees": "«Required attendees»",
     "id": "«Id»",
     "body": "«The plain text content»"
   }
   ```
4. **Create file** into `/AI Feed/calendar` (same File Name expression, File Content = Outputs).
5. Save, test by creating a throwaway event.

## Flow 3 — "AI Feed: teams"

1. Automated cloud flow `AI Feed: teams`, trigger **When a new chat message is added** (Microsoft Teams). It fires for any chat Aaron is in (not channels); one user per flow, which is fine.
2. **+ New step → Get message details** (Microsoft Teams): *Message* = **Message ID** (from the trigger); *Message type* = **Group chat**; *Chat* = **Chat ID** (from the trigger; the field appears after picking the type).
3. **Html to text**: *Content* = **Body Content** (from Get message details).
4. **Compose**:
   ```json
   {
     "type": "teams",
     "chat": "«Chat ID»",
     "from": "«From User Display Name»",
     "created": "«Created DateTime»",
     "id": "«Message ID»",
     "body": "«The plain text content»"
   }
   ```
5. **Create file** into `/AI Feed/teams`.
6. Save, test by sending any chat message. The Hermes 1:1 chat is captured too (both sides); harmless, and the indexer can skip it.

## Checks and limits

- The Teams chat trigger and the channel triggers poll about every 3 minutes; mail and calendar are near-instant.
- Microsoft 365 licenses allow 6,000 flow actions per user per day; each item here costs 3–4, so a very busy day stays under 1,500.
- On the mini, OneDrive's Files On-Demand keeps new files cloud-only until read. Right-click `AI Feed` in Finder on the mini → **Always Keep on This Device** so the indexer reads them locally.
- Power Automate owner: add a second staff account as co-owner on each flow (Share) so the feed survives a departure, same as the help desk's Teams workflow.

## What the mini does with it (next step, not built yet)

Hermes Helper's index service also walks `AI Feed/` and indexes each JSON as a record with a `source`
(mail/calendar/teams); the MCP tools gain a `source` filter; later a digest can be written back to Notes.
