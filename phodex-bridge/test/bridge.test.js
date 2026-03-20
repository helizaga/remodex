const test = require("node:test");
const assert = require("node:assert/strict");

const {
  isActiveRelaySocket,
  nextRelayReconnectDelayMs,
  relayCloseDiagnostic,
  shouldShutdownOnRelayCloseCode,
} = require("../src/bridge");

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

test("shouldShutdownOnRelayCloseCode only fails closed for invalid relay sessions", () => {
  assert.equal(shouldShutdownOnRelayCloseCode(4000), true);
  assert.equal(shouldShutdownOnRelayCloseCode(4001), false);
  assert.equal(shouldShutdownOnRelayCloseCode(4002), false);
  assert.equal(shouldShutdownOnRelayCloseCode(1006), false);
});

test("relayCloseDiagnostic classifies saved-session and permanent reconnect failures", () => {
  assert.deepEqual(relayCloseDiagnostic(4002), {
    code: "saved_session_unavailable",
    message: "The saved session expired or is temporarily unavailable. Retrying...",
    isPermanent: false,
  });

  assert.deepEqual(relayCloseDiagnostic(4000), {
    code: "re_pair_required",
    message: "This relay pairing is no longer valid. Scan a new QR code to reconnect.",
    isPermanent: true,
  });

  assert.deepEqual(relayCloseDiagnostic(4010, "relay proxy reset"), {
    code: "relay_temporarily_unavailable",
    message: "The relay connection closed unexpectedly: relay proxy reset",
    isPermanent: false,
  });
});
