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
const { setupRelay, getRelayStats } = require("./relay");

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
