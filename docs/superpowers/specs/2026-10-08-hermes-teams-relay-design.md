# Hermes Teams relay — design (2026-10-08)

Lets Aaron chat with Hermes (on the assistant Mac mini) from a 1:1 chat in Microsoft Teams, on desktop and phone. Same pattern as the AVL Help Desk's Teams bot (2026-09-12): a Teams bot registered in the Teams Developer Portal, a public front door on Cloudflare, and a small relay on the mini that checks Microsoft's signature and talks to Hermes. Aaron's rulings: "why not a webhook, like the help desk" (approved); **no fallbacks** (no OneDrive file bridge); no Graph/Entra admin asks; nothing in his calls.

## Flow

```
Teams (Aaron, 1:1 chat with "Hermes")
  → Microsoft Bot Framework  POST https://hermes.northwoodstech.workers.dev/webhooks/teams  (RS256 JWT)
  → Cloudflare Worker "hermes" (forwards only /webhooks/teams and /health; stamps x-front-door-key)
  → Workers VPC service "hermes-relay" → Cloudflare Tunnel "engineering-mac" (cloudflared on the mini, outbound only)
  → relay  http://127.0.0.1:8787  (Node, no dependencies; launchd com.northwoods.hermes-teams)
      checks front-door key, Microsoft's JWT (iss/aud/exp/serviceUrl/signature), and that the sender is Aaron
      answers 200 at once, shows "typing", then
  → Hermes API server  http://127.0.0.1:8642/v1/responses  (hermes gateway as a launchd service; API_SERVER_KEY)
      the full agent: Gemma 4 12B, notes MCP, memory; previous_response_id keeps the conversation
  ← reply posted back through Bot Framework REST as the bot (markdown, split under 25 KB)
```

Reply time is the model's time (2–4 minutes for a question that searches notes); the typing indicator repeats until the answer lands.

## Pieces

| Piece | Where | Notes |
|---|---|---|
| Teams bot "Hermes" | Teams Developer Portal (Aaron, once) | Endpoint `https://hermes.northwoodstech.workers.dev/webhooks/teams`; Bot ID + client secret go into the mini's `config/local.json` through `scripts/setup.js` (prompted, never in git or chat). Same 10-minute step as "Northwoods Tech Help" (still listed 2026-10-08). |
| Teams app package | `hermes-teams/teams-app/NorthwoodsHermes.zip` from `scripts/teams-manifest.js` | Bot scope `personal` only (no team/channel), no RSC permissions. Aaron uploads it: Teams → Apps → Manage your apps → Upload a custom app, then opens the chat. |
| Front door | Cloudflare Worker `hermes` at `hermes.northwoodstech.workers.dev` (`hermes-teams/cloudflare/`) | Forwards `POST /webhooks/teams` and `GET /health` only; anything else 404; 503 JSON when the tunnel is down. Secret `FRONT_DOOR_KEY` stamped on every forwarded request. |
| Tunnel | Cloudflare Tunnel `engineering-mac` + VPC service `hermes-relay` (127.0.0.1:8787) | **Aaron runs `hermes-teams/scripts/cloudflare-setup.sh` once** (creating ingress is gated for Claude). It creates both, fills the service id into `wrangler.jsonc`, deploys the Worker, generates the front-door key, and installs cloudflared on the mini with the tunnel token over SSH (http2, the church network drops UDP 7844). Separate from Puget's `puget` tunnel, which is never touched. |
| Relay | `hermes-teams/` (server.js, lib/, test/), deployed to `~/hermes-teams` on the mini by `scripts/deploy-teams-relay.sh`; launchd `com.northwoods.hermes-teams`; log `~/Library/Logs/hermes-teams.log` | Node 20+ (Homebrew node on the mini), zero npm dependencies, `node --test`. |
| Hermes API | `~/.hermes/.env`: `API_SERVER_ENABLED=true`, `API_SERVER_KEY=<random>`; `hermes gateway install --start-on-login` | Listens on 127.0.0.1:8642 only. Tool switches for the `api_server` platform match the CLI (terminal, browser, computer use, file, code, delegation, image, speech off). |

## The relay

- **Routes:** `GET /health` → `{ok, relay:"hermes-teams", bot:{configured}, hermes:{ok, checkedAt}}`; `POST /webhooks/teams` → front-door key (constant-time compare; required when configured) → JSON body ≤ 256 KB → JWT verify → `200 {}` immediately; the work continues after the response.
- **Who may talk:** the tenant is pinned (by `teamsBot.tenantId` in config, or by the first authorized message) and messages from any other tenant are dropped silently. `allowedUsers` entries with an `aadObjectId` match only that immutable id. A name-only entry is a one-time bootstrap: the first account whose Teams display name matches is pinned to it (`state.pins`), after which only that account's id matches, so a stranger who renames themselves "Aaron Larson" is refused. Refused senders in the right tenant get "Sorry, this assistant is private." and are logged (id + name, no text). The relay learns tenant/serviceUrl only from messages that passed both checks. (Security review finding, 2026-10-08: spoofable display-name allowlist; fixed before first use.)
- **Messages:** text is cleaned of `<at>` and HTML. `/new` (or "new chat") forgets the conversation (`previous_response_id` dropped) and says so; `/help` explains the two commands. Everything else goes to Hermes.
- **Hermes call:** `POST /v1/responses` with `{model:"hermes-agent", input, store:true, previous_response_id}`; 10-minute timeout; one request at a time across all conversations (the model server has one slot). If Hermes rejects the stored `previous_response_id` (gateway restarted, history pruned), the relay retries once without it. The reply text is every `output_text` part of the `message` outputs joined with blank lines; empty → "Hermes had no answer."
- **Typing:** a `typing` activity every 4 s while waiting (Teams shows it for a few seconds each time).
- **Replies:** markdown messages ≤ 25,000 characters each, split at paragraph breaks. On failure: "Hermes couldn't answer: <reason>" plus a log line.
- **State:** `data/state.json` holds `tenantId`, `serviceUrl` (learned from activities, like the help desk) and `responses: {conversationId → lastResponseId}`.
- **Greeting:** on `conversationUpdate` that adds the bot, reply "Hi Aaron. Ask me about your notes and meetings. `/new` starts a fresh conversation."
- **Logs:** JSON lines, state only (who, when, lengths, errors); never message text.

## Security

Four locks on a public URL: the Worker forwards only two paths; the front-door key means nothing on the mini can be reached except through the Worker; Microsoft's JWT (RS256 against `login.botframework.com` keys, `aud` = Bot ID, 5-minute skew, `serviceUrl` claim must match the activity, unknown-`kid` refresh rate-limited); and the sender allowlist. The relay binds 127.0.0.1; the tunnel is outbound only; Hermes's API key never leaves the mini. Hermes's terminal/browser/file tools are off on the API platform, so a crafted message can at most read notes and the web.

## Not in scope

Group chats or channels (bot scope stays `personal`); calls; files or images from Teams (ignored with a note); proactive messages from Hermes to Teams (cron digests) — easy later through the same connector, once Aaron wants them.

## Testing

- `node --test` in `hermes-teams/`: JWT verifier (good token, wrong audience, expired, bad signature, unknown key), connector token caching and post path, Hermes client (previous id, extraction, retry without id), relay (stranger refused, Aaron answered with typing and chunks, `/new`, Hermes error, greeting), server (health, front-door key, 401 on bad token, 200 before processing finishes), text cleaning and splitting.
- Live: `curl https://hermes.northwoodstech.workers.dev/health` through the door; a Teams message "find my notes about projectors" answered in the chat.
