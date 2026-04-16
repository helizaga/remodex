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

const tempDirs = [];

function makeStateDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-session-state-"));
  tempDirs.push(dir);
  return dir;
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

test("relay session ids are trimmed before persisting", () => {
  const stateDir = makeStateDir();

  assert.equal(rememberRelaySessionId("  session-123  ", { stateDir }), true);
  assert.equal(readPersistedRelaySessionId({ stateDir }), "session-123");
});

test("corrupted relay session state is treated as missing", () => {
  const stateDir = makeStateDir();
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(path.join(stateDir, "relay-session.json"), "{not-json");

  assert.equal(readPersistedRelaySessionId({ stateDir }), null);
});

test.after(() => {
  for (const dir of tempDirs) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
