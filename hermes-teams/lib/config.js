"use strict";
/** config/local.json on the mini (mode 600, written by scripts/setup.js). Never committed. */
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..");
const DEFAULTS = {
  port: 8787,
  host: "127.0.0.1",
  baseUrl: "https://hermes.northwoodstech.workers.dev",
  frontDoorKey: "",
  notifyKey: "",
  teamsBot: { appId: "", appPassword: "", tenantId: "" },
  allowedUsers: [{ name: "Aaron Larson" }],
  hermes: { url: "http://127.0.0.1:8642", key: "", timeoutMs: 20 * 60 * 1000 },
  stateFile: path.join(ROOT, "data", "state.json"),
};

function loadConfig(file = path.join(ROOT, "config", "local.json")) {
  let local = {};
  try {
    local = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    /* not set up yet: the relay still serves /health */
  }
  return {
    ...DEFAULTS,
    ...local,
    teamsBot: { ...DEFAULTS.teamsBot, ...(local.teamsBot || {}) },
    hermes: { ...DEFAULTS.hermes, ...(local.hermes || {}) },
    allowedUsers: Array.isArray(local.allowedUsers) && local.allowedUsers.length ? local.allowedUsers : DEFAULTS.allowedUsers,
  };
}

module.exports = { loadConfig, ROOT, DEFAULTS };
