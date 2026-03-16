const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");

const {
  setupRelay,
  getRelayStats,
  __resetRelayStateForTests,
} = require("./relay");

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

function relayRequest(sessionId, role) {
  return {
    url: `/relay/${sessionId}`,
    headers: { "x-role": role },
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
  wss.connect(mac, relayRequest("session-a", "mac"));
  wss.connect(iphone, relayRequest("session-a", "iphone"));

  assert.deepEqual(getRelayStats(), {
    activeSessions: 1,
    sessionsWithMac: 1,
    totalClients: 1,
  });

  iphone.readyState = WS_CLOSED;
  assert.deepEqual(getRelayStats(), {
    activeSessions: 1,
    sessionsWithMac: 1,
    totalClients: 0,
  });

  mac.readyState = WS_CLOSED;
  assert.deepEqual(getRelayStats(), {
    activeSessions: 0,
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

  wss.connect(mac, relayRequest("session-b", "mac"));
  wss.connect(staleIphone, relayRequest("session-b", "iphone"));
  wss.connect(nextIphone, relayRequest("session-b", "iphone"));

  assert.equal(staleIphone.readyState, WS_CLOSED);
  assert.deepEqual(getRelayStats(), {
    activeSessions: 1,
    sessionsWithMac: 1,
    totalClients: 1,
  });
});

test("a newer Mac session retires older Mac sessions across the relay", (t) => {
  __resetRelayStateForTests();

  const wss = new FakeWebSocketServer();
  setupRelay(wss);
  t.after(() => {
    wss.emit("close");
    __resetRelayStateForTests();
  });

  const firstMac = new FakeWebSocket();
  const secondMac = new FakeWebSocket();

  wss.connect(firstMac, relayRequest("session-c", "mac"));
  assert.deepEqual(getRelayStats(), {
    activeSessions: 1,
    sessionsWithMac: 1,
    totalClients: 0,
  });

  wss.connect(secondMac, relayRequest("session-d", "mac"));
  assert.equal(firstMac.readyState, WS_CLOSED);
  assert.deepEqual(getRelayStats(), {
    activeSessions: 1,
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
  setupRelay(wss);
  t.after(() => {
    console.log = originalLog;
    console.error = originalError;
    wss.emit("close");
    __resetRelayStateForTests();
  });

  const mac = new FakeWebSocket();
  const iphone = new FakeWebSocket();
  wss.connect(mac, relayRequest("session-sensitive", "mac"));
  wss.connect(iphone, relayRequest("session-sensitive", "iphone"));
  mac.emit("message", "hello");
  iphone.close();
  mac.close();

  assert.ok(capturedLogs.some((line) => line.includes("session#")));
  assert.ok(capturedLogs.every((line) => !line.includes("session-sensitive")));
});
