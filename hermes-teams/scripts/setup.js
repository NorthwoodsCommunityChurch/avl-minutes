#!/usr/bin/env node
"use strict";
/**
 * Writes config/local.json on the mini (mode 600) and restarts the relay.
 *   node scripts/setup.js --stdin < secrets.json   merge a JSON object (teamsBot, frontDoorKey, allowedUsers, hermes…)
 *   node scripts/setup.js                          prompts for the Bot ID and client secret
 * Fills hermes.key from ~/.hermes/.env (API_SERVER_KEY) when it is not set. Never prints secrets.
 */
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const readline = require("node:readline/promises");
const { execFileSync } = require("node:child_process");
const { ROOT } = require("../lib/config");

const FILE = path.join(ROOT, "config", "local.json");

function readLocal() {
  try {
    return JSON.parse(fs.readFileSync(FILE, "utf8"));
  } catch {
    return {};
  }
}

function apiKeyFromHermesEnv() {
  try {
    const env = fs.readFileSync(path.join(os.homedir(), ".hermes", ".env"), "utf8");
    const m = /^API_SERVER_KEY=(.+)$/m.exec(env);
    return m ? m[1].trim() : "";
  } catch {
    return "";
  }
}

function merge(base, extra) {
  const out = { ...base, ...extra };
  if (base.teamsBot || extra.teamsBot) out.teamsBot = { ...(base.teamsBot || {}), ...(extra.teamsBot || {}) };
  if (base.hermes || extra.hermes) out.hermes = { ...(base.hermes || {}), ...(extra.hermes || {}) };
  return out;
}

async function prompt() {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const appId = (await rl.question("Bot ID (GUID from the Teams Developer Portal): ")).trim();
  const appPassword = (await rl.question("Client secret: ")).trim();
  rl.close();
  return { teamsBot: { appId, appPassword } };
}

async function main() {
  let incoming;
  if (process.argv.includes("--stdin")) incoming = JSON.parse(fs.readFileSync(0, "utf8"));
  else incoming = await prompt();
  for (const key of Object.keys(incoming)) if (key.startsWith("_")) delete incoming[key];
  const local = merge(readLocal(), incoming);
  local.hermes = local.hermes || {};
  if (!local.hermes.key) local.hermes.key = apiKeyFromHermesEnv();
  const bot = local.teamsBot || {};
  for (const [k, v] of Object.entries(bot)) if (/PASTE/i.test(String(v))) throw new Error(`teamsBot.${k} still has the placeholder text`);
  fs.mkdirSync(path.dirname(FILE), { recursive: true });
  fs.writeFileSync(FILE, `${JSON.stringify(local, null, 2)}\n`, { mode: 0o600 });
  fs.chmodSync(FILE, 0o600);
  const report = { file: FILE, bot: !!(bot.appId && bot.appPassword), frontDoorKey: !!local.frontDoorKey, hermesKey: !!local.hermes.key, allowedUsers: (local.allowedUsers || []).length };
  console.log(JSON.stringify(report));
  if (!process.argv.includes("--no-restart")) {
    try {
      execFileSync("launchctl", ["kickstart", "-k", `gui/${process.getuid()}/com.northwoods.hermes-teams`], { stdio: "ignore" });
      console.log("relay restarted");
    } catch {
      console.log("relay not restarted (launchd agent not loaded yet)");
    }
  }
}

main().catch((err) => {
  console.error(`setup: ${err.message}`);
  process.exit(1);
});
