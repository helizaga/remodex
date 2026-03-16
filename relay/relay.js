// FILE: relay.js
// Purpose: Thin WebSocket relay used by the default hosted Remodex pairing flow.
// Layer: Standalone server module
// Exports: setupRelay, getRelayStats

const { createHash } = require("crypto");
const path = require("path");

const { WebSocket } = loadWsModule();

const CLEANUP_DELAY_MS = 15_000;
const HEARTBEAT_INTERVAL_MS = 15_000;
const CLOSE_CODE_SESSION_UNAVAILABLE = 4002;
const CLOSE_CODE_IPHONE_REPLACED = 4003;

// In-memory session registry for one Mac host and one live iPhone client per session.
const sessions = new Map();

// Attaches relay behavior to a ws WebSocketServer instance.
function setupRelay(wss) {
  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (ws._relayAlive === false) {
        ws.terminate();
        continue;
      }
      ws._relayAlive = false;
      ws.ping();
    }

    sweepSessions();
  }, HEARTBEAT_INTERVAL_MS);

  wss.on("close", () => clearInterval(heartbeat));

  wss.on("connection", (ws, req) => {
    const urlPath = req.url || "";
    const match = urlPath.match(/^\/relay\/([^/?]+)/);
    const sessionId = match?.[1];
    const role = req.headers["x-role"];

    if (!sessionId || (role !== "mac" && role !== "iphone")) {
      ws.close(4000, "Missing sessionId or invalid x-role header");
      return;
    }

    ws._relayAlive = true;
    ws.on("pong", () => {
      ws._relayAlive = true;
    });

    // Only the Mac host is allowed to create a fresh session room.
    if (role === "iphone" && !sessions.has(sessionId)) {
      ws.close(CLOSE_CODE_SESSION_UNAVAILABLE, "Mac session not available");
      return;
    }

    if (!sessions.has(sessionId)) {
      sessions.set(sessionId, {
        mac: null,
        clients: new Set(),
        cleanupTimer: null,
      });
    }

    const session = sessions.get(sessionId);
    pruneSessionState(session);

    if (role === "iphone" && !isSocketOpen(session.mac)) {
      ws.close(CLOSE_CODE_SESSION_UNAVAILABLE, "Mac session not available");
      return;
    }

    if (session.cleanupTimer) {
      clearTimeout(session.cleanupTimer);
      session.cleanupTimer = null;
    }

    if (role === "mac") {
      retireOtherMacSessions(sessionId);
      if (isSocketOpen(session.mac)) {
        session.mac.close(4001, "Replaced by new Mac connection");
      }
      session.mac = ws;
      console.log(`[relay] Mac connected -> ${relaySessionLogLabel(sessionId)}`);
    } else {
      // Keep one live iPhone RPC client per session to avoid competing sockets.
      for (const existingClient of Array.from(session.clients)) {
        if (existingClient === ws) {
          continue;
        }
        if (isSocketLive(existingClient)) {
          existingClient.close(
            CLOSE_CODE_IPHONE_REPLACED,
            "Replaced by newer iPhone connection"
          );
        }
        session.clients.delete(existingClient);
      }

      session.clients.add(ws);
      console.log(
        `[relay] iPhone connected -> ${relaySessionLogLabel(sessionId)} `
        + `(${session.clients.size} client(s))`
      );
    }

    ws.on("message", (data) => {
      pruneSessionState(session);
      const msg = typeof data === "string" ? data : data.toString("utf-8");
      console.log(
        `[relay] forwarded ${role} -> ${relaySessionLogLabel(sessionId)} `
        + `(${Buffer.byteLength(msg, "utf8")} bytes)`
      );

      if (role === "mac") {
        for (const client of session.clients) {
          if (isSocketOpen(client)) {
            client.send(msg);
          }
        }
      } else if (isSocketOpen(session.mac)) {
        session.mac.send(msg);
      }
    });

    ws.on("close", () => {
      if (role === "mac") {
        if (session.mac === ws) {
          session.mac = null;
          console.log(`[relay] Mac disconnected -> ${relaySessionLogLabel(sessionId)}`);
          for (const client of session.clients) {
            if (isSocketLive(client)) {
              client.close(CLOSE_CODE_SESSION_UNAVAILABLE, "Mac disconnected");
            }
          }
        }
      } else {
        session.clients.delete(ws);
        console.log(
          `[relay] iPhone disconnected -> ${relaySessionLogLabel(sessionId)} `
          + `(${session.clients.size} remaining)`
        );
      }
      pruneSessionState(session);
      scheduleCleanup(sessionId);
    });

    ws.on("error", (err) => {
      console.error(
        `[relay] WebSocket error (${role}, ${relaySessionLogLabel(sessionId)}):`,
        err.message
      );
    });
  });
}

function scheduleCleanup(sessionId) {
  const session = sessions.get(sessionId);
  if (!session) {
    return;
  }
  pruneSessionState(session);
  if (session.mac || session.clients.size > 0 || session.cleanupTimer) {
    return;
  }

  session.cleanupTimer = setTimeout(() => {
    const activeSession = sessions.get(sessionId);
    if (!activeSession) {
      return;
    }

    activeSession.cleanupTimer = null;
    pruneSessionState(activeSession);
    if (!activeSession.mac && activeSession.clients.size === 0) {
      sessions.delete(sessionId);
      console.log(`[relay] ${relaySessionLogLabel(sessionId)} cleaned up`);
    }
  }, CLEANUP_DELAY_MS);
}

function relaySessionLogLabel(sessionId) {
  const normalizedSessionId = typeof sessionId === "string" ? sessionId.trim() : "";
  if (!normalizedSessionId) {
    return "session=[redacted]";
  }

  const digest = createHash("sha256")
    .update(normalizedSessionId)
    .digest("hex")
    .slice(0, 8);
  return `session#${digest}`;
}

// Exposes lightweight runtime stats for health/status endpoints.
function getRelayStats() {
  sweepSessions();

  let totalClients = 0;
  let sessionsWithMac = 0;
  let activeSessions = 0;

  for (const session of sessions.values()) {
    const hasMac = Boolean(session.mac);
    const clientCount = session.clients.size;

    if (!hasMac && clientCount === 0) {
      continue;
    }

    activeSessions += 1;
    totalClients += session.clients.size;
    if (hasMac) {
      sessionsWithMac += 1;
    }
  }

  return {
    activeSessions,
    sessionsWithMac,
    totalClients,
  };
}

function sweepSessions() {
  for (const [sessionId, session] of sessions.entries()) {
    pruneSessionState(session);
    scheduleCleanup(sessionId);
  }
}

function pruneSessionState(session) {
  if (session.mac && !isSocketLive(session.mac)) {
    session.mac = null;
  }

  for (const client of Array.from(session.clients)) {
    if (!isSocketLive(client)) {
      session.clients.delete(client);
    }
  }
}

function retireOtherMacSessions(activeSessionId) {
  for (const [sessionId, session] of sessions.entries()) {
    if (sessionId === activeSessionId) {
      continue;
    }

    pruneSessionState(session);
    if (!session.mac) {
      continue;
    }

    if (isSocketLive(session.mac)) {
      session.mac.close(4001, "Replaced by newer Mac session");
    }
    session.mac = null;

    for (const client of Array.from(session.clients)) {
      if (isSocketLive(client)) {
        client.close(CLOSE_CODE_SESSION_UNAVAILABLE, "Mac disconnected");
      }
      session.clients.delete(client);
    }

    scheduleCleanup(sessionId);
  }
}

function isSocketOpen(socket) {
  return Boolean(socket) && socket.readyState === WebSocket.OPEN;
}

function isSocketLive(socket) {
  return Boolean(socket)
    && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING);
}

function loadWsModule() {
  try {
    return require("ws");
  } catch {
    return require(path.join(__dirname, "..", "phodex-bridge", "node_modules", "ws"));
  }
}

function resetRelayStateForTests() {
  for (const session of sessions.values()) {
    if (session.cleanupTimer) {
      clearTimeout(session.cleanupTimer);
    }
  }
  sessions.clear();
}

module.exports = {
  setupRelay,
  getRelayStats,
  __resetRelayStateForTests: resetRelayStateForTests,
};
