#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$ROOT_DIR/phodex-bridge"
PORT="${REMODEX_LOCAL_PORT:-9000}"
BIND_HOST="${REMODEX_LOCAL_BIND_HOST:-0.0.0.0}"
LAN_HOST="${REMODEX_LOCAL_HOST:-$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || hostname)}"
RELAY_URL="ws://${LAN_HOST}:${PORT}/relay"
REFRESH_ENABLED="${REMODEX_REFRESH_ENABLED:-true}"
STATE_DIR="${HOME}/.remodex-local"
BRIDGE_PID_FILE="${STATE_DIR}/bridge.pid"
RELAY_PID_FILE="${STATE_DIR}/relay.pid"
COMMAND="${1:-up}"

if [[ "$COMMAND" == "stop" ]]; then
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

  stop_pid_file "bridge" "$BRIDGE_PID_FILE"
  stop_pid_file "relay" "$RELAY_PID_FILE"
  exit 0
fi

if [[ ! -d "$BRIDGE_DIR/node_modules" ]]; then
  echo "[remodex-local] installing bridge dependencies"
  (cd "$BRIDGE_DIR" && npm install)
fi

mkdir -p "$STATE_DIR"

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

cleanup() {
  local status=$?
  rm -f "$BRIDGE_PID_FILE"
  if [[ -n "${relay_pid:-}" ]] && kill -0 "$relay_pid" 2>/dev/null; then
    kill "$relay_pid" 2>/dev/null || true
    wait "$relay_pid" 2>/dev/null || true
  fi
  if [[ -n "${started_relay:-}" ]]; then
    rm -f "$RELAY_PID_FILE"
  fi
  exit "$status"
}

trap cleanup EXIT INT TERM

echo "[remodex-local] lan host: $LAN_HOST"
echo "[remodex-local] relay url: $RELAY_URL"
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

cd "$BRIDGE_DIR"
REMODEX_RELAY="$RELAY_URL" \
REMODEX_REFRESH_ENABLED="$REFRESH_ENABLED" \
node ./bin/remodex.js up
