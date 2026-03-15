const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");

const {
  rememberRelaySessionId,
  readPersistedRelaySessionId,
  clearPersistedRelaySession,
} = require("../src/session-state");

function makeStateDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "remodex-session-state-"));
}

test("relay session id persists across reads and can be cleared", () => {
  const stateDir = makeStateDir();

  assert.equal(readPersistedRelaySessionId({ stateDir }), null);
  assert.equal(rememberRelaySessionId("session-123", { stateDir }), true);
  assert.equal(readPersistedRelaySessionId({ stateDir }), "session-123");
  assert.equal(clearPersistedRelaySession({ stateDir }), true);
  assert.equal(readPersistedRelaySessionId({ stateDir }), null);
});

test("empty relay session ids are rejected", () => {
  const stateDir = makeStateDir();

  assert.equal(rememberRelaySessionId("", { stateDir }), false);
  assert.equal(readPersistedRelaySessionId({ stateDir }), null);
});
