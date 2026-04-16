#!/usr/bin/env node

const http = require("http");
const path = require("path");
const Module = require("module");

const bridgeNodeModules = path.join(__dirname, "..", "phodex-bridge", "node_modules");
process.env.NODE_PATH = process.env.NODE_PATH
  ? `${bridgeNodeModules}${path.delimiter}${process.env.NODE_PATH}`
  : bridgeNodeModules;
Module._initPaths();

const { WebSocketServer } = require("ws");
const { setupRelay, getRelayStats, resolveTrustedMacSession } = require("./relay");
const { readBridgeStatus } = require("../phodex-bridge/src/daemon-state");

function createHealthPayload(relayStats = getRelayStats()) {
  return {
    ok: true,
    ...relayStats,
  };
}

function createStatusPayload({
  relayStats = getRelayStats(),
  bridgeStatus = readBridgeStatus(),
} = {}) {
  return {
    ...createHealthPayload(relayStats),
    trustedReconnectSupported: true,
    hasLiveMac: relayStats.sessionsWithMac > 0,
    bridge: bridgeStatus
      ? {
          state: readString(bridgeStatus.state) || "unknown",
          connectionStatus: readString(bridgeStatus.connectionStatus) || "unknown",
          updatedAt: readString(bridgeStatus.updatedAt) || null,
          lastPermanentReconnectReason: sanitizeReconnectReason(
            bridgeStatus.lastPermanentReconnectReason
          ),
          latestReconnectDiagnostic: sanitizeReconnectDiagnostic(
            bridgeStatus.latestReconnectDiagnostic
          ),
        }
      : null,
  };
}

function createLocalRelayServer({ host = "127.0.0.1", port = "9000" } = {}) {
  const server = http.createServer((req, res) => {
    if (req.url === "/health") {
      return writeJSON(res, 200, createHealthPayload());
    }

    if (req.url === "/status") {
      return writeJSON(res, 200, createStatusPayload());
    }

    if (req.method === "POST" && req.url === "/v1/trusted/session/resolve") {
      void handleJSONRoute(req, res, async (body) => resolveTrustedMacSession(body));
      return;
    }

    res.writeHead(404, { "content-type": "text/plain" });
    res.end("Not found");
  });

  const wss = new WebSocketServer({ server });
  setupRelay(wss);

  return { server, wss, host, port };
}

function main(argv = process.argv.slice(2)) {
  const port = readFlag(argv, "--port", "9000");
  const host = readFlag(argv, "--host", "127.0.0.1");
  const { server } = createLocalRelayServer({ host, port });

  server.listen(Number(port), host, () => {
    console.log(`[remodex-relay] listening on http://${host}:${port}`);
  });
}

function readFlag(argv, name, fallback) {
  const index = argv.indexOf(name);
  if (index === -1) {
    return fallback;
  }

  const value = argv[index + 1];
  if (!value || value.startsWith("--")) {
    return fallback;
  }

  return value;
}

function sanitizeReconnectReason(reason) {
  if (!reason || typeof reason !== "object") {
    return null;
  }

  return {
    code: readString(reason.code) || "unknown",
    message: readString(reason.message) || "Unknown reconnect reason.",
  };
}

function sanitizeReconnectDiagnostic(diagnostic) {
  if (!diagnostic || typeof diagnostic !== "object") {
    return null;
  }

  return {
    code: readString(diagnostic.code) || "unknown",
    message: readString(diagnostic.message) || "Unknown reconnect diagnostic.",
    isPermanent: diagnostic.isPermanent === true,
  };
}

async function handleJSONRoute(req, res, handler) {
  try {
    const body = await readJSONBody(req);
    const result = await handler(body);
    return writeJSON(res, 200, result);
  } catch (error) {
    return writeJSON(res, error.status || 500, {
      ok: false,
      error: error.message || "Internal server error",
      code: error.code || "internal_error",
    });
  }
}

function readJSONBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let totalSize = 0;
    let didReject = false;

    req.on("data", (chunk) => {
      if (didReject) {
        return;
      }

      totalSize += chunk.length;
      if (totalSize > 64 * 1024) {
        didReject = true;
        req.removeAllListeners("data");
        req.resume();
        reject(
          Object.assign(new Error("Request body too large"), {
            status: 413,
            code: "body_too_large",
          })
        );
        return;
      }
      chunks.push(chunk);
    });

    req.on("end", () => {
      if (didReject) {
        return;
      }
      const rawBody = Buffer.concat(chunks).toString("utf8");
      if (!rawBody.trim()) {
        resolve({});
        return;
      }

      try {
        resolve(JSON.parse(rawBody));
      } catch {
        reject(
          Object.assign(new Error("Invalid JSON body"), {
            status: 400,
            code: "invalid_json",
          })
        );
      }
    });

    req.on("error", reject);
  });
}

function writeJSON(res, status, body) {
  res.statusCode = status;
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify(body));
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

if (require.main === module) {
  main();
}

module.exports = {
  createHealthPayload,
  createLocalRelayServer,
  createStatusPayload,
};
