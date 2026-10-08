"use strict";
/** Tiny JSON file: what the relay learned from Teams (tenant, serviceUrl) and Hermes's last response id per chat. */
const fs = require("node:fs");
const path = require("node:path");

function createState(file) {
  let data = { responses: {} };
  try {
    data = { responses: {}, ...JSON.parse(fs.readFileSync(file, "utf8")) };
  } catch {
    /* first run */
  }
  const save = () => {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`, { mode: 0o600 });
  };
  return {
    file,
    get: (key) => (key in data ? data[key] : null),
    set(key, value) {
      data[key] = value;
      save();
    },
    getResponse: (conversationId) => data.responses[conversationId] || null,
    setResponse(conversationId, id) {
      data.responses[conversationId] = id;
      save();
    },
    clearResponse(conversationId) {
      delete data.responses[conversationId];
      save();
    },
  };
}

module.exports = { createState };
