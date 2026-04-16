// FILE: session-state.js
// Purpose: Persists the latest active Remodex thread and reusable relay session metadata for local handoff.
// Layer: CLI helper
// Exports: rememberActiveThread, openLastActiveThread, readLastActiveThread, relay session helpers
// Depends on: fs, os, path, child_process

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const STATE_DIR = path.join(os.homedir(), ".remodex");
const LAST_THREAD_STATE_FILE = path.join(STATE_DIR, "last-thread.json");
const RELAY_SESSION_STATE_FILE = path.join(STATE_DIR, "relay-session.json");
const DEFAULT_BUNDLE_ID = "com.openai.codex";

function rememberActiveThread(threadId, source, { stateDir = STATE_DIR } = {}) {
  if (!threadId || typeof threadId !== "string") {
    return false;
  }

  const payload = {
    threadId,
    source: source || "unknown",
    updatedAt: new Date().toISOString(),
  };

  writeStateFile(lastThreadStateFilePath(stateDir), payload, stateDir);
  return true;
}

function openLastActiveThread({ bundleId = DEFAULT_BUNDLE_ID, stateDir = STATE_DIR } = {}) {
  const state = readLastActiveThread({ stateDir });
  const threadId = state?.threadId;
  if (!threadId) {
    throw new Error("No remembered Remodex thread found yet.");
  }

  const targetUrl = `codex://threads/${threadId}`;
  execFileSync("open", ["-b", bundleId, targetUrl], { stdio: "ignore" });
  return state;
}

function readLastActiveThread({ stateDir = STATE_DIR } = {}) {
  return readStateFile(lastThreadStateFilePath(stateDir));
}

function readPersistedRelaySessionId({ stateDir = STATE_DIR } = {}) {
  const state = readStateFile(relaySessionStateFilePath(stateDir));
  const sessionId = typeof state?.sessionId === "string" ? state.sessionId.trim() : "";
  return sessionId || null;
}

function rememberRelaySessionId(sessionId, { stateDir = STATE_DIR } = {}) {
  if (!sessionId || typeof sessionId !== "string") {
    return false;
  }

  writeStateFile(
    relaySessionStateFilePath(stateDir),
    {
      sessionId,
      updatedAt: new Date().toISOString(),
    },
    stateDir
  );
  return true;
}

function clearPersistedRelaySession({ stateDir = STATE_DIR } = {}) {
  const filePath = relaySessionStateFilePath(stateDir);
  if (!fs.existsSync(filePath)) {
    return false;
  }

  fs.rmSync(filePath, { force: true });
  return true;
}

function readStateFile(filePath) {
  if (!fs.existsSync(filePath)) {
    return null;
  }

  try {
    const raw = fs.readFileSync(filePath, "utf8");
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function writeStateFile(filePath, payload, stateDir) {
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(payload, null, 2));
}

function lastThreadStateFilePath(stateDir) {
  return path.join(stateDir, path.basename(LAST_THREAD_STATE_FILE));
}

function relaySessionStateFilePath(stateDir) {
  return path.join(stateDir, path.basename(RELAY_SESSION_STATE_FILE));
}

module.exports = {
  rememberActiveThread,
  openLastActiveThread,
  readLastActiveThread,
  readPersistedRelaySessionId,
  rememberRelaySessionId,
  clearPersistedRelaySession,
};
