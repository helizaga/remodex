const test = require("node:test");
const assert = require("node:assert/strict");

const {
  buildHeartbeatBridgeStatus,
  hasRelayConnectionGoneStale,
  isActiveRelaySocket,
  nextRelayReconnectDelayMs,
  relayCloseDiagnostic,
  shouldShutdownOnRelayCloseCode,
  sanitizeThreadHistoryImagesForRelay,
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

test("hasRelayConnectionGoneStale returns true once the relay silence crosses the timeout", () => {
  assert.equal(
    hasRelayConnectionGoneStale(1_000, {
      now: 71_000,
      staleAfterMs: 70_000,
    }),
    true
  );
});

test("hasRelayConnectionGoneStale returns false for fresh or missing activity timestamps", () => {
  assert.equal(
    hasRelayConnectionGoneStale(1_000, {
      now: 70_999,
      staleAfterMs: 70_000,
    }),
    false
  );
  assert.equal(hasRelayConnectionGoneStale(Number.NaN), false);
});

test("buildHeartbeatBridgeStatus downgrades stale connected snapshots", () => {
  assert.deepEqual(
    buildHeartbeatBridgeStatus(
      {
        state: "running",
        connectionStatus: "connected",
        pid: 123,
        lastError: "",
      },
      1_000,
      {
        now: 26_500,
        staleAfterMs: 25_000,
        staleMessage: "Relay heartbeat stalled; reconnect pending.",
      }
    ),
    {
      state: "running",
      connectionStatus: "disconnected",
      pid: 123,
      lastError: "Relay heartbeat stalled; reconnect pending.",
    }
  );
});

test("buildHeartbeatBridgeStatus leaves fresh or already-disconnected snapshots unchanged", () => {
  const freshStatus = {
    state: "running",
    connectionStatus: "connected",
    pid: 123,
    lastError: "",
  };
  assert.deepEqual(
    buildHeartbeatBridgeStatus(freshStatus, 1_000, {
      now: 20_000,
      staleAfterMs: 25_000,
    }),
    freshStatus
  );

  const disconnectedStatus = {
    state: "running",
    connectionStatus: "disconnected",
    pid: 123,
    lastError: "",
  };
  assert.deepEqual(buildHeartbeatBridgeStatus(disconnectedStatus, 1_000), disconnectedStatus);
});

test("sanitizeThreadHistoryImagesForRelay replaces inline history images with lightweight references", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-read",
    result: {
      thread: {
        id: "thread-images",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "item-user",
                type: "user_message",
                content: [
                  {
                    type: "input_text",
                    text: "Look at this screenshot",
                  },
                  {
                    type: "image",
                    image_url: "data:image/png;base64,AAAA",
                  },
                ],
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const content = sanitized.result.thread.turns[0].items[0].content;

  assert.deepEqual(content[0], {
    type: "input_text",
    text: "Look at this screenshot",
  });
  assert.deepEqual(content[1], {
    type: "image",
    url: "remodex://history-image-elided",
  });
});

test("sanitizeThreadHistoryImagesForRelay leaves unrelated RPC payloads unchanged", () => {
  const rawMessage = JSON.stringify({
    id: "req-other",
    result: {
      ok: true,
    },
  });

  assert.equal(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "turn/start"),
    rawMessage
  );
});
