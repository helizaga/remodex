const test = require("node:test");
const assert = require("node:assert/strict");

const { isActiveRelaySocket } = require("../src/bridge");

test("isActiveRelaySocket only accepts the current relay socket", () => {
  const currentSocket = { id: "current" };
  const staleSocket = { id: "stale" };

  assert.equal(isActiveRelaySocket(currentSocket, currentSocket), true);
  assert.equal(isActiveRelaySocket(currentSocket, staleSocket), false);
  assert.equal(isActiveRelaySocket(null, staleSocket), false);
});
