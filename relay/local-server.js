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
const {
  setupRelay,
  getRelayStats,
  resolveTrustedMacSession,
} = require("./relay");

const args = process.argv.slice(2);
const port = readFlag(args, "--port", "9000");
const host = readFlag(args, "--host", "0.0.0.0");

const server = http.createServer((req, res) => {
  if (req.url === "/health") {
    const body = JSON.stringify({
      ok: true,
      ...getRelayStats(),
    });
    res.writeHead(200, {
      "content-type": "application/json",
      "content-length": Buffer.byteLength(body),
    });
    res.end(body);
    return;
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

server.listen(Number(port), host, () => {
  console.log(`[remodex-relay] listening on http://${host}:${port}`);
});

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

    req.on("data", (chunk) => {
      totalSize += chunk.length;
      if (totalSize > 64 * 1024) {
        reject(Object.assign(new Error("Request body too large"), {
          status: 413,
          code: "body_too_large",
        }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });

    req.on("end", () => {
      const rawBody = Buffer.concat(chunks).toString("utf8");
      if (!rawBody.trim()) {
        resolve({});
        return;
      }

      try {
        resolve(JSON.parse(rawBody));
      } catch {
        reject(Object.assign(new Error("Invalid JSON body"), {
          status: 400,
          code: "invalid_json",
        }));
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
