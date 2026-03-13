#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$ROOT_DIR/phodex-bridge"
PORT="${REMODEX_LOCAL_PORT:-9000}"
BIND_HOST="${REMODEX_LOCAL_BIND_HOST:-0.0.0.0}"
LAN_HOST="${REMODEX_LOCAL_HOST:-$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || hostname)}"
REFRESH_ENABLED="${REMODEX_REFRESH_ENABLED:-true}"
STATE_DIR="${HOME}/.remodex-local"
BRIDGE_PID_FILE="${STATE_DIR}/bridge.pid"
RELAY_PID_FILE="${STATE_DIR}/relay.pid"
TUNNEL_PID_FILE="${STATE_DIR}/tunnel.pid"
NGROK_LOG_FILE="${STATE_DIR}/ngrok.log"
COMMAND="${1:-up}"
RELAY_URL="ws://${LAN_HOST}:${PORT}/relay"

if [[ ! -d "$BRIDGE_DIR/node_modules" ]]; then
  echo "[remodex-local] installing bridge dependencies"
  (cd "$BRIDGE_DIR" && npm install)
fi

mkdir -p "$STATE_DIR"

stop_pid_file() {
  local label="$1"
  local pid_file="$2"
  if [[ ! -f "$pid_file" ]]; then
    echo "[remodex-local] ${label} not running"
    return 0
  fi

  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [[ -z "$pid" ]]; then
    rm -f "$pid_file"
    echo "[remodex-local] ${label} not running"
    return 0
  fi

  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    echo "[remodex-local] stopped ${label} (pid ${pid})"
  else
    echo "[remodex-local] ${label} not running"
  fi

  rm -f "$pid_file"
}

if [[ "$COMMAND" == "stop" ]]; then
  stop_pid_file "bridge" "$BRIDGE_PID_FILE"
  stop_pid_file "tunnel" "$TUNNEL_PID_FILE"
  stop_pid_file "relay" "$RELAY_PID_FILE"
  exit 0
fi

read_live_pid() {
  local pid_file="$1"
  if [[ ! -f "$pid_file" ]]; then
    return 1
  fi

  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [[ -z "$pid" ]]; then
    rm -f "$pid_file"
    return 1
  fi

  if kill -0 "$pid" 2>/dev/null; then
    printf '%s' "$pid"
    return 0
  fi

  rm -f "$pid_file"
  return 1
}

wait_for_relay() {
  local attempts=20
  local delay_s=0.25

  for ((i=1; i<=attempts; i++)); do
    if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay_s"
  done

  return 1
}

wait_for_ngrok() {
  local attempts=40
  local delay_s=0.25

  for ((i=1; i<=attempts; i++)); do
    if [[ -f "$NGROK_LOG_FILE" ]] && grep -q '"msg":"started tunnel"' "$NGROK_LOG_FILE" 2>/dev/null; then
      return 0
    fi
    sleep "$delay_s"
  done

  return 1
}

discover_ngrok_relay_url() {
  node -e '
const fs = require("fs");
const logPath = process.argv[1];
for (const line of fs.readFileSync(logPath, "utf8").split(/\n+/)) {
  if (!line.trim()) continue;
  let obj;
  try {
    obj = JSON.parse(line);
  } catch {
    continue;
  }
  if (obj.msg === "started tunnel" && typeof obj.url === "string" && obj.url.startsWith("https://")) {
    process.stdout.write(`${obj.url.replace(/^https:/, "wss:")}/relay`);
    process.exit(0);
  }
}
process.exit(1);
' "$NGROK_LOG_FILE"
}

cleanup() {
  local status=$?
  rm -f "$BRIDGE_PID_FILE"
  if [[ -n "${tunnel_pid:-}" ]] && kill -0 "$tunnel_pid" 2>/dev/null; then
    kill "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
  fi
  if [[ -n "${relay_pid:-}" ]] && kill -0 "$relay_pid" 2>/dev/null; then
    kill "$relay_pid" 2>/dev/null || true
    wait "$relay_pid" 2>/dev/null || true
  fi
  if [[ -n "${started_tunnel:-}" ]]; then
    rm -f "$TUNNEL_PID_FILE"
    rm -f "$NGROK_LOG_FILE"
  fi
  if [[ -n "${started_relay:-}" ]]; then
    rm -f "$RELAY_PID_FILE"
  fi
  exit "$status"
}

trap cleanup EXIT INT TERM

echo "[remodex-local] lan host: $LAN_HOST"
echo "[remodex-local] desktop refresh: $REFRESH_ENABLED"

if existing_bridge_pid="$(read_live_pid "$BRIDGE_PID_FILE")"; then
  echo "[remodex-local] bridge already running (pid ${existing_bridge_pid})"
  echo "[remodex-local] stop the existing session before starting a new one"
  exit 1
fi

echo "$$" > "$BRIDGE_PID_FILE"

if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
  echo "[remodex-local] reusing existing local relay on :$PORT"
else
  NODE_PATH="$BRIDGE_DIR/node_modules" \
    node "$ROOT_DIR/relay/local-server.js" --host "$BIND_HOST" --port "$PORT" &
  relay_pid=$!
  started_relay=1
  echo "$relay_pid" > "$RELAY_PID_FILE"

  if ! wait_for_relay; then
    echo "[remodex-local] failed to start local relay on :$PORT" >&2
    exit 1
  fi
fi

if [[ "$COMMAND" == "remote" ]]; then
  if ! command -v ngrok >/dev/null 2>&1; then
    echo "[remodex-local] ngrok is required for remote mode" >&2
    exit 1
  fi

  rm -f "$NGROK_LOG_FILE"
  ngrok http "http://127.0.0.1:${PORT}" --log=stdout --log-format=json >"$NGROK_LOG_FILE" 2>&1 &
  tunnel_pid=$!
  started_tunnel=1
  echo "$tunnel_pid" > "$TUNNEL_PID_FILE"

  if ! wait_for_ngrok; then
    echo "[remodex-local] failed to start ngrok tunnel" >&2
    exit 1
  fi

  RELAY_URL="$(discover_ngrok_relay_url)"
  echo "[remodex-local] relay url: $RELAY_URL"
else
  echo "[remodex-local] relay url: $RELAY_URL"
fi

cd "$BRIDGE_DIR"
REMODEX_RELAY="$RELAY_URL" \
REMODEX_REFRESH_ENABLED="$REFRESH_ENABLED" \
node ./bin/remodex.js up
