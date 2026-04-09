const test = require("node:test");
const assert = require("node:assert/strict");

const {
  createHealthPayload,
  createLocalRelayServer,
  createStatusPayload,
} = require("./local-server");

test("createLocalRelayServer defaults to loopback and still allows explicit overrides", () => {
  const defaultServer = createLocalRelayServer();
  assert.equal(defaultServer.host, "127.0.0.1");
  defaultServer.wss.close();
  defaultServer.server.close();

  const explicitServer = createLocalRelayServer({ host: "0.0.0.0" });
  assert.equal(explicitServer.host, "0.0.0.0");
  explicitServer.wss.close();
  explicitServer.server.close();
});

test("createHealthPayload keeps the minimal relay health shape", () => {
  assert.deepEqual(
    createHealthPayload({
      activeSessions: 1,
      sessionsWithMac: 1,
      totalClients: 0,
    }),
    {
      ok: true,
      activeSessions: 1,
      sessionsWithMac: 1,
      totalClients: 0,
    }
  );
});

test("createStatusPayload exposes reconnect diagnostics without sensitive fields", () => {
  const payload = createStatusPayload({
    relayStats: {
      activeSessions: 2,
      sessionsWithMac: 1,
      totalClients: 3,
    },
    bridgeStatus: {
      state: "running",
      connectionStatus: "disconnected",
      updatedAt: "2026-03-20T12:00:00.000Z",
      latestReconnectDiagnostic: {
        code: "saved_session_unavailable",
        message: "The saved session expired or is temporarily unavailable. Retrying...",
        isPermanent: false,
      },
      lastPermanentReconnectReason: {
        code: "re_pair_required",
        message: "This relay pairing is no longer valid. Scan a new QR code to reconnect.",
      },
      sessionId: "secret-session",
      notificationSecret: "secret-notification",
    },
  });

  assert.deepEqual(payload, {
    ok: true,
    activeSessions: 2,
    sessionsWithMac: 1,
    totalClients: 3,
    trustedReconnectSupported: true,
    hasLiveMac: true,
    bridge: {
      state: "running",
      connectionStatus: "disconnected",
      updatedAt: "2026-03-20T12:00:00.000Z",
      lastPermanentReconnectReason: {
        code: "re_pair_required",
        message: "This relay pairing is no longer valid. Scan a new QR code to reconnect.",
      },
      latestReconnectDiagnostic: {
        code: "saved_session_unavailable",
        message: "The saved session expired or is temporarily unavailable. Retrying...",
        isPermanent: false,
      },
    },
  });

  assert.ok(!JSON.stringify(payload).includes("secret-session"));
  assert.ok(!JSON.stringify(payload).includes("secret-notification"));
});
