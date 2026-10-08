# Hermes Teams Relay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aaron chats with Hermes from a 1:1 Teams chat; messages reach the mini through a Cloudflare door and a small relay that calls Hermes's API server.

**Architecture:** Zero-dependency Node relay (`hermes-teams/`) reusing the help desk's Bot Framework JWT/connector code; Hermes gateway's API server on the mini; Cloudflare Worker + Tunnel + VPC service created by a script Aaron runs.

**Tech Stack:** Node 20+ (`node:test`), Cloudflare wrangler 4, launchd, Hermes Agent v0.21.5 API server.

**Spec:** [docs/superpowers/specs/2026-10-08-hermes-teams-relay-design.md](../specs/2026-10-08-hermes-teams-relay-design.md)

## Global Constraints

- No secrets in git or chat: Bot ID/secret, API key, front-door key, tunnel token live only on the mini (`config/local.json`, `.env`, launchd plist) and Cloudflare.
- Relay binds 127.0.0.1:8787; Hermes API 127.0.0.1:8642.
- Logs: state only, never message text.
- Never touch Puget's `puget` tunnel or Workers.
- Claude cannot create ingress (tunnel/VPC/Worker deploy): those are in `scripts/cloudflare-setup.sh` for Aaron.

## Review Focus

1. Message from a stranger (someone else installs the app or a forwarded chat): refused, logged, no Hermes call. `relay.test.js`.
2. Hermes down or slow: relay still answers Microsoft 200 within seconds; after the 10-minute timeout the chat gets a failure message. `server.test.js`, `relay.test.js`.
3. Stale `previous_response_id` after a gateway restart: one retry without it. `hermes.test.js`.
4. Replies over Teams' size limit: split under 25 KB at paragraph breaks. `teams.test.js`.
5. Two messages in a row: processed one at a time, in order (single model slot). `relay.test.js`.

### Task 1: lib/teams.js (verifier, connector, text helpers) — tests first
### Task 2: lib/hermes.js + lib/state.js — tests first
### Task 3: lib/relay.js — tests first
### Task 4: server.js, lib/config.js, lib/log.js — tests first; `npm test` green
### Task 5: scripts (setup.js, teams-manifest.js, deploy-teams-relay.sh, cloudflare-setup.sh, install-cloudflared.sh), cloudflare/worker.mjs + wrangler.jsonc, launchd plist
### Task 6: mini: Hermes API server enabled + gateway service; relay deployed; Aaron runs cloudflare-setup.sh, registers the bot, runs setup.js, uploads the app; live test
### Task 7: docs (CLAUDE.md, README, direction doc, SSH-ACCESS row), commit, push

Each task: write the test file, run `node --test` to watch it fail, implement, run green, commit.
