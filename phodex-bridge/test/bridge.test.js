const test = require("node:test");
const assert = require("node:assert/strict");

const { isActiveRelaySocket, nextRelayReconnectDelayMs } = require("../src/bridge");

test("isActiveRelaySocket only accepts the current relay socket", () => {
  const currentSocket = { id: "current" };
  const staleSocket = { id: "stale" };

  assert.equal(isActiveRelaySocket(currentSocket, currentSocket), true);
  assert.equal(isActiveRelaySocket(currentSocket, staleSocket), false);
  assert.equal(isActiveRelaySocket(null, staleSocket), false);
});

test("nextRelayReconnectDelayMs backs off exponentially and caps the delay", () => {
  assert.equal(nextRelayReconnectDelayMs(1), 1_000);
  assert.equal(nextRelayReconnectDelayMs(2), 2_000);
  assert.equal(nextRelayReconnectDelayMs(3), 4_000);
  assert.equal(nextRelayReconnectDelayMs(6), 30_000);
  assert.equal(nextRelayReconnectDelayMs(10), 30_000);
});
