#!/usr/bin/env node
"use strict";
/**
 * Build the Teams app package for the Hermes bot: manifest.json + icons, zipped for "Upload a custom app".
 *   node scripts/teams-manifest.js --app-id <bot id> [--base-url https://hermes.northwoodstech.workers.dev] [--version 1.0.1]
 * Bump --version each time the package is re-uploaded so Teams replaces the installed app.
 * Output: teams-app/manifest.json and teams-app/NorthwoodsHermes.zip. Scope is personal only (a 1:1 chat).
 */
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { ROOT, DEFAULTS } = require("../lib/config");

const ASSETS = path.join(ROOT, "teams-app");

function buildManifest({ appId, baseUrl, version = "1.0.0" }) {
  const host = new URL(baseUrl).host;
  return {
    $schema: "https://developer.microsoft.com/json-schemas/teams/v1.21/MicrosoftTeams.schema.json",
    manifestVersion: "1.21",
    version,
    id: appId,
    developer: { name: "Northwoods Community Church", websiteUrl: "https://northwoods.church", privacyUrl: "https://northwoods.church", termsOfUseUrl: "https://northwoods.church" },
    icons: { color: "color.png", outline: "outline.png" },
    name: { short: "Hermes", full: "Hermes (Aaron's assistant)" },
    description: { short: "Aaron's personal assistant on the Northwoods assistant Mac", full: "A private 1:1 chat with Hermes, the assistant running on the Northwoods assistant Mac mini. It answers from Aaron's notes and meeting transcripts. Only Aaron can use it." },
    accentColor: "#004C97",
    bots: [{ botId: appId, scopes: ["personal"], supportsFiles: false, isNotificationOnly: false }],
    permissions: ["identity"],
    validDomains: [host],
  };
}

function main() {
  const args = process.argv.slice(2);
  const get = (flag) => { const i = args.indexOf(flag); return i >= 0 ? args[i + 1] : undefined; };
  const appId = get("--app-id");
  const baseUrl = get("--base-url") || DEFAULTS.baseUrl;
  const version = get("--version") || "1.0.0";
  if (!appId || !/^[0-9a-f-]{36}$/i.test(appId)) throw new Error("--app-id <bot id GUID> is required");
  const manifest = buildManifest({ appId, baseUrl, version });
  fs.writeFileSync(path.join(ASSETS, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  const zip = path.join(ASSETS, "NorthwoodsHermes.zip");
  fs.rmSync(zip, { force: true });
  execFileSync("zip", ["-j", "-q", zip, path.join(ASSETS, "manifest.json"), path.join(ASSETS, "color.png"), path.join(ASSETS, "outline.png")]);
  console.log(`wrote ${zip}`);
}

if (require.main === module) {
  try { main(); } catch (err) { console.error(`teams-manifest: ${err.message}`); process.exit(1); }
}
module.exports = { buildManifest };
