"use strict";
/** JSON lines to stdout (launchd captures them). State only: never message text. */
function createLog(stream = process.stdout) {
  return (level, data = {}) => {
    stream.write(`${JSON.stringify({ t: new Date().toISOString(), level, ...data })}\n`);
  };
}
module.exports = { createLog };
