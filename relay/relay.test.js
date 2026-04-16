const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");

const { setupRelay, getRelayStats, __resetRelayStateForTests } = require("./relay");

const WS_CONNECTING = 0;
const WS_OPEN = 1;
const WS_CLOSED = 3;

class FakeWebSocket extends EventEmitter {
  constructor() {
    super();
    this.readyState = WS_OPEN;
    this._relayAlive = true;
  }

  send() {}

  ping() {}

  terminate() {
    this.close();
  }

  close(code, reason) {
    if (this.readyState === WS_CLOSED) {
      return;
    }

    this.readyState = WS_CLOSED;
    this.emit("close", code, reason);
  }
}

class FakeWebSocketServer extends EventEmitter {
  constructor() {
    super();
    this.clients = new Set();
  }

  connect(ws, req) {
    this.clients.add(ws);
    this.emit("connection", ws, req);
  }
}

function relayRequest(sessionId, role, headers = {}) {
  return {
    url: `/relay/${sessionId}`,
    headers: { "x-role": role, ...headers },
  };
}

test("getRelayStats counts only live sockets", (t) => {
  __resetRelayStateForTests();

  const wss = new FakeWebSocketServer();
  setupRelay(wss);
  t.after(() => {
    wss.emit("close");
    __resetRelayStateForTests();
  });

  const mac = new FakeWebSocket();
  const iphone = new FakeWebSocket();
  wss.connect(
    mac,
    relayRequest("session-a", "mac", {
      "x-notification-secret": "secret-a",
      "x-mac-device-id": "mac-a",
      "x-mac-identity-public-key": "mac-key-a",
    })
  );
  wss.connect(iphone, relayRequest("session-a", "iphone"));

  assert.deepEqual(getRelayStats(), {
    activeSessions: 1,
    pairingCodes: 0,
    sessionsWithMac: 1,
    totalClients: 1,
  });

  iphone.readyState = WS_CLOSED;
  assert.deepEqual(getRelayStats(), {
    activeSessions: 1,
    pairingCodes: 0,
    sessionsWithMac: 1,
    totalClients: 0,
  });

  mac.readyState = WS_CLOSED;
  assert.deepEqual(getRelayStats(), {
    activeSessions: 0,
    pairingCodes: 0,
    sessionsWithMac: 0,
    totalClients: 0,
  });
});

test("replacing an iPhone client removes stale client sockets from stats", (t) => {
  __resetRelayStateForTests();

  const wss = new FakeWebSocketServer();
  setupRelay(wss);
  t.after(() => {
    wss.emit("close");
    __resetRelayStateForTests();
  });

  const mac = new FakeWebSocket();
  const staleIphone = new FakeWebSocket();
  staleIphone.readyState = WS_CONNECTING;
  const nextIphone = new FakeWebSocket();

  wss.connect(
    mac,
    relayRequest("session-b", "mac", {
      "x-notification-secret": "secret-b",
      "x-mac-device-id": "mac-b",
      "x-mac-identity-public-key": "mac-key-b",
    })
  );
  wss.connect(staleIphone, relayRequest("session-b", "iphone"));
  wss.connect(nextIphone, relayRequest("session-b", "iphone"));

  assert.equal(staleIphone.readyState, WS_CLOSED);
  assert.deepEqual(getRelayStats(), {
    activeSessions: 1,
    pairingCodes: 0,
    sessionsWithMac: 1,
    totalClients: 1,
  });
});

test("a newer session for the same Mac retires the older session across the relay", (t) => {
  __resetRelayStateForTests();

  const wss = new FakeWebSocketServer();
  setupRelay(wss);
  t.after(() => {
    wss.emit("close");
    __resetRelayStateForTests();
  });

  const firstMac = new FakeWebSocket();
  const secondMac = new FakeWebSocket();

  wss.connect(
    firstMac,
    relayRequest("session-c", "mac", {
      "x-notification-secret": "secret-c",
      "x-mac-device-id": "mac-shared",
      "x-mac-identity-public-key": "mac-key-shared",
    })
  );
  assert.deepEqual(getRelayStats(), {
    activeSessions: 1,
    pairingCodes: 0,
    sessionsWithMac: 1,
    totalClients: 0,
  });

  wss.connect(
    secondMac,
    relayRequest("session-d", "mac", {
      "x-notification-secret": "secret-d",
      "x-mac-device-id": "mac-shared",
      "x-mac-identity-public-key": "mac-key-shared",
    })
  );
  assert.equal(firstMac.readyState, WS_CLOSED);
  assert.deepEqual(getRelayStats(), {
    activeSessions: 1,
    pairingCodes: 0,
    sessionsWithMac: 1,
    totalClients: 0,
  });
});

test("a different Mac device cannot retire unrelated live sessions", (t) => {
  __resetRelayStateForTests();

  const wss = new FakeWebSocketServer();
  setupRelay(wss);
  t.after(() => {
    wss.emit("close");
    __resetRelayStateForTests();
  });

  const firstMac = new FakeWebSocket();
  const secondMac = new FakeWebSocket();

  wss.connect(
    firstMac,
    relayRequest("session-e", "mac", {
      "x-notification-secret": "secret-e",
      "x-mac-device-id": "mac-e",
      "x-mac-identity-public-key": "mac-key-e",
    })
  );
  wss.connect(
    secondMac,
    relayRequest("session-f", "mac", {
      "x-notification-secret": "secret-f",
      "x-mac-device-id": "mac-f",
      "x-mac-identity-public-key": "mac-key-f",
    })
  );

  assert.equal(firstMac.readyState, WS_OPEN);
  assert.equal(secondMac.readyState, WS_OPEN);
  assert.deepEqual(getRelayStats(), {
    activeSessions: 2,
    pairingCodes: 0,
    sessionsWithMac: 2,
    totalClients: 0,
  });
});

test("replacing a live Mac socket requires the existing session secret", (t) => {
  __resetRelayStateForTests();

  const wss = new FakeWebSocketServer();
  setupRelay(wss);
  t.after(() => {
    wss.emit("close");
    __resetRelayStateForTests();
  });

  const originalMac = new FakeWebSocket();
  const attackerMac = new FakeWebSocket();

  wss.connect(
    originalMac,
    relayRequest("session-g", "mac", {
      "x-notification-secret": "secret-g",
      "x-mac-device-id": "mac-g",
      "x-mac-identity-public-key": "mac-key-g",
    })
  );
  wss.connect(
    attackerMac,
    relayRequest("session-g", "mac", {
      "x-notification-secret": "wrong-secret",
      "x-mac-device-id": "mac-g",
      "x-mac-identity-public-key": "mac-key-g",
    })
  );

  assert.equal(originalMac.readyState, WS_OPEN);
  assert.equal(attackerMac.readyState, WS_CLOSED);
  assert.deepEqual(getRelayStats(), {
    activeSessions: 1,
    pairingCodes: 0,
    sessionsWithMac: 1,
    totalClients: 0,
  });
});

test("relay logs redact live session identifiers", (t) => {
  __resetRelayStateForTests();

  const capturedLogs = [];
  const originalLog = console.log;
  const originalError = console.error;
  console.log = (...args) => {
    capturedLogs.push(args.join(" "));
  };
  console.error = (...args) => {
    capturedLogs.push(args.join(" "));
  };

  const wss = new FakeWebSocketServer();
  t.after(() => {
    console.log = originalLog;
    console.error = originalError;
    wss.emit("close");
    __resetRelayStateForTests();
  });
  setupRelay(wss);

  const mac = new FakeWebSocket();
  const iphone = new FakeWebSocket();
  wss.connect(
    mac,
    relayRequest("session-sensitive", "mac", {
      "x-notification-secret": "secret-sensitive",
      "x-mac-device-id": "mac-sensitive",
      "x-mac-identity-public-key": "mac-key-sensitive",
    })
  );
  wss.connect(iphone, relayRequest("session-sensitive", "iphone"));
  mac.emit("message", "hello");
  iphone.close();
  mac.close();

  assert.ok(capturedLogs.some((line) => line.includes("session#")));
  assert.ok(capturedLogs.every((line) => !line.includes("session-sensitive")));
  assert.ok(capturedLogs.every((line) => !line.includes("secret-sensitive")));
});
