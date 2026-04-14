const test = require("node:test");
const assert = require("node:assert/strict");

const {
  buildHeartbeatBridgeStatus,
  createMacOSBridgeWakeAssertion,
  hasRelayConnectionGoneStale,
  isActiveRelaySocket,
  nextRelayReconnectDelayMs,
  persistBridgePreferences,
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

test("createMacOSBridgeWakeAssertion spawns a macOS caffeinate idle-sleep assertion tied to the bridge pid", () => {
  const spawnCalls = [];
  const fakeChild = {
    killed: false,
    on() {},
    unref() {},
    kill() {
      this.killed = true;
    },
  };

  const assertion = createMacOSBridgeWakeAssertion({
    platform: "darwin",
    pid: 4242,
    spawnImpl(command, args, options) {
      spawnCalls.push({ command, args, options });
      return fakeChild;
    },
  });

  assert.equal(assertion.active, true);
  assert.deepEqual(spawnCalls, [{
    command: "/usr/bin/caffeinate",
    args: ["-i", "-w", "4242"],
    options: { stdio: "ignore" },
  }]);

  assertion.stop();
  assert.equal(fakeChild.killed, true);
});

test("createMacOSBridgeWakeAssertion can toggle the caffeinate assertion on and off live", () => {
  const spawnCalls = [];
  const children = [];

  const assertion = createMacOSBridgeWakeAssertion({
    platform: "darwin",
    pid: 9001,
    enabled: false,
    spawnImpl(command, args, options) {
      const child = {
        killed: false,
        on() {},
        unref() {},
        kill() {
          this.killed = true;
        },
      };
      children.push(child);
      spawnCalls.push({ command, args, options });
      return child;
    },
  });

  assert.equal(assertion.active, false);
  assert.equal(assertion.enabled, false);
  assert.deepEqual(spawnCalls, []);

  assertion.setEnabled(true);
  assert.equal(assertion.enabled, true);
  assert.equal(assertion.active, true);
  assert.equal(spawnCalls.length, 1);

  assertion.setEnabled(false);
  assert.equal(assertion.enabled, false);
  assert.equal(assertion.active, false);
  assert.equal(children[0].killed, true);
});

test("createMacOSBridgeWakeAssertion is a no-op outside macOS", () => {
  let didSpawn = false;
  const assertion = createMacOSBridgeWakeAssertion({
    platform: "linux",
    spawnImpl() {
      didSpawn = true;
      throw new Error("should not spawn");
    },
  });

  assert.equal(assertion.active, false);
  assertion.stop();
  assert.equal(didSpawn, false);
});

test("persistBridgePreferences only saves the daemon preference field", () => {
  const writes = [];

  persistBridgePreferences(
    { keepMacAwakeEnabled: false },
    {
      readDaemonConfigImpl() {
        return {
          relayUrl: "ws://127.0.0.1:9000/relay",
          refreshEnabled: true,
        };
      },
      writeDaemonConfigImpl(config) {
        writes.push(config);
      },
    }
  );

  assert.deepEqual(writes, [{
    relayUrl: "ws://127.0.0.1:9000/relay",
    refreshEnabled: true,
    keepMacAwakeEnabled: false,
  }]);
});

test("sanitizeThreadHistoryImagesForRelay strips bulky compaction replacement history", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-resume",
    result: {
      thread: {
        id: "thread-compaction",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "item-compaction",
                type: "context_compaction",
                payload: {
                  message: "",
                  replacement_history: [
                    {
                      type: "message",
                      role: "assistant",
                      content: [{ type: "output_text", text: "very old transcript" }],
                    },
                  ],
                },
              },
              {
                id: "item-compaction-camel",
                type: "contextCompaction",
                replacementHistory: [
                  {
                    type: "message",
                    role: "user",
                    content: [{ type: "input_text", text: "older prompt" }],
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
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/resume")
  );
  const items = sanitized.result.thread.turns[0].items;

  assert.deepEqual(items[0], {
    id: "item-compaction",
    type: "context_compaction",
    payload: {
      message: "",
    },
  });
  assert.deepEqual(items[1], {
    id: "item-compaction-camel",
    type: "contextCompaction",
  });
});

test("sanitizeThreadHistoryImagesForRelay recursively elides inline image payload fields outside content arrays", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-read-recursive",
    result: {
      thread: {
        id: "thread-recursive-images",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "item-recursive-image",
                type: "user_message",
                attachment: {
                  sourceURL: "data:image/png;base64,AAAA",
                  payloadDataURL: "data:image/png;base64,BBBB",
                },
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
  const attachment = sanitized.result.thread.turns[0].items[0].attachment;

  assert.deepEqual(attachment, {
    sourceURL: "remodex://history-image-elided",
  });
});

test("sanitizeThreadHistoryImagesForRelay strips attachment previews once the sanitized thread is still too large", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-read-soft-cap",
    result: {
      thread: {
        id: "thread-soft-cap",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "item-attachment-preview",
                type: "user_message",
                attachment: {
                  thumbnailBase64JPEG: "A".repeat(10_000),
                  sourceURL: "https://example.com/image.png",
                },
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read", {
      softCapBytes: 1_000,
    })
  );
  const attachment = sanitized.result.thread.turns[0].items[0].attachment;

  assert.deepEqual(attachment, {
    thumbnailBase64JPEG: "",
    sourceURL: "https://example.com/image.png",
  });
});

test("sanitizeThreadHistoryImagesForRelay drops oldest turns once sanitizing still exceeds the relay budget", () => {
  const oversizedText = "x".repeat(4_096);
  const rawMessage = JSON.stringify({
    id: "req-thread-read-truncated",
    result: {
      thread: {
        id: "thread-large-history",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "item-1",
                type: "assistant_message",
                text: oversizedText,
              },
            ],
          },
          {
            id: "turn-2",
            items: [
              {
                id: "item-2",
                type: "assistant_message",
                text: oversizedText,
              },
            ],
          },
          {
            id: "turn-3",
            items: [
              {
                id: "item-3",
                type: "assistant_message",
                text: "latest",
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read", {
      softCapBytes: 5_000,
    })
  );

  assert.equal(sanitized.result.thread.relayHistoryTruncated, true);
  assert.equal(sanitized.result.thread.relayHistoryDroppedTurns, 1);
  assert.deepEqual(
    sanitized.result.thread.turns.map((turn) => turn.id),
    ["turn-2", "turn-3"]
  );
});
