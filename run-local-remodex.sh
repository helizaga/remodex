#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$ROOT_DIR/phodex-bridge"
PORT="${REMODEX_LOCAL_PORT:-9000}"
BIND_HOST="${REMODEX_LOCAL_BIND_HOST:-127.0.0.1}"
REFRESH_ENABLED="${REMODEX_REFRESH_ENABLED:-false}"
EXPLICIT_RELAY_URL="${REMODEX_RELAY:-${PHODEX_RELAY:-}}"
TUNNEL_MODE_RAW="${REMODEX_TUNNEL_MODE:-ngrok}"
STATE_DIR="${HOME}/.remodex-local"
BRIDGE_PID_FILE="${STATE_DIR}/bridge.pid"
RELAY_PID_FILE="${STATE_DIR}/relay.pid"
TUNNEL_PID_FILE="${STATE_DIR}/tunnel.pid"
NGROK_LOG_FILE="${STATE_DIR}/ngrok.log"
BRIDGE_LOG_FILE="${STATE_DIR}/bridge.log"
RELAY_LOG_FILE="${STATE_DIR}/relay.log"
LOCAL_RELAY_URL="ws://127.0.0.1:${PORT}/relay"
RELAY_URL=""

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
    terminate_pid "$pid"
    echo "[remodex-local] stopped ${label} (pid ${pid})"
  else
    echo "[remodex-local] ${label} not running"
  fi

  rm -f "$pid_file"
}

terminate_pid() {
  local pid="$1"
  local attempts=10

  kill "$pid" 2>/dev/null || true
  for ((i=1; i<=attempts; i++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done

  kill -9 "$pid" 2>/dev/null || true
}

find_repo_launcher_pids() {
  {
    pgrep -f "${ROOT_DIR}/run-local-remodex.sh up" 2>/dev/null || true
    pgrep -f '(^|.*/)run-local-remodex\.sh up($| )' 2>/dev/null || true
  } | awk 'NF { print $1 }' | sort -u
}

cleanup_repo_launcher_orphans() {
  local action_label="$1"
  local pid
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    [[ "$pid" == "$$" ]] && continue
    if kill -0 "$pid" 2>/dev/null; then
      terminate_pid "$pid"
      echo "[remodex-local] stopped stale launcher during ${action_label} (pid ${pid})"
    fi
  done < <(find_repo_launcher_pids)
}

find_repo_worker_pids() {
  {
    pgrep -f "${ROOT_DIR}/relay/local-server.js" 2>/dev/null || true
    pgrep -f 'node ./bin/remodex\.js up' 2>/dev/null || true
    pgrep -f "ngrok http http://127.0.0.1:${PORT}" 2>/dev/null || true
  } | awk 'NF { print $1 }' | sort -u
}

cleanup_repo_worker_orphans() {
  local action_label="$1"
  local pid
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    if kill -0 "$pid" 2>/dev/null; then
      terminate_pid "$pid"
      echo "[remodex-local] stopped stale worker during ${action_label} (pid ${pid})"
    fi
  done < <(find_repo_worker_pids)
}

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

require_command() {
  local command_name="$1"
  local install_hint="$2"

  if command -v "$command_name" >/dev/null 2>&1; then
    return 0
  fi

  echo "[remodex-local] missing required command: $command_name" >&2
  echo "[remodex-local] $install_hint" >&2
  exit 1
}

spawn_detached() {
  local pid_file="$1"
  local log_file="$2"
  shift 2

  node - "$pid_file" "$log_file" "$@" <<'NODE'
const fs = require("fs");
const { spawn } = require("child_process");

const [, , pidFile, logFile, ...cmd] = process.argv;
if (cmd.length === 0) {
  process.exit(1);
}

const logFd = fs.openSync(logFile, "a");
const child = spawn(cmd[0], cmd.slice(1), {
  detached: true,
  stdio: ["ignore", logFd, logFd],
});
fs.writeFileSync(pidFile, `${child.pid}`);
console.log(child.pid);
child.unref();
NODE
}

normalize_tunnel_mode() {
  local raw_value="${1:-off}"
  raw_value="$(printf '%s' "$raw_value" | tr '[:upper:]' '[:lower:]')"

  case "$raw_value" in
    ngrok)
      printf 'ngrok\n'
      ;;
    *)
      printf 'off\n'
      ;;
  esac
}

should_use_ngrok_tunnel() {
  local explicit_relay_url="${1:-}"
  local tunnel_mode
  tunnel_mode="$(normalize_tunnel_mode "${2:-off}")"

  [[ -z "$explicit_relay_url" && "$tunnel_mode" == "ngrok" ]]
}

preflight_up() {
  require_command "node" "Install Node.js and make sure 'node' is in your PATH."
  if should_use_ngrok_tunnel "$EXPLICIT_RELAY_URL" "$TUNNEL_MODE"; then
    require_command "ngrok" "Install ngrok and make sure 'ngrok' is in your PATH."
  fi

  if [[ -z "${REMODEX_CODEX_ENDPOINT:-}" && -z "${PHODEX_CODEX_ENDPOINT:-}" ]]; then
    require_command "codex" "Install the Codex CLI or set REMODEX_CODEX_ENDPOINT to an existing app-server URL."
  fi
}

wait_for_relay() {
  local attempts=20
  local delay_s=0.25

  for ((i=1; i<=attempts; i++)); do
    if curl -fsS "http://${BIND_HOST}:${PORT}/health" >/dev/null 2>&1; then
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
    if [[ -f "$NGROK_LOG_FILE" ]] && grep -q 'ERR_NGROK_' "$NGROK_LOG_FILE" 2>/dev/null; then
      return 1
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

ngrok_log_contains() {
  local pattern="$1"
  [[ -f "$NGROK_LOG_FILE" ]] && grep -q "$pattern" "$NGROK_LOG_FILE" 2>/dev/null
}

cleanup_ngrok_state() {
  if [[ -f "$TUNNEL_PID_FILE" ]]; then
    stop_pid_file "tunnel" "$TUNNEL_PID_FILE"
  fi

  rm -f "$NGROK_LOG_FILE"
}

extract_ngrok_collision_endpoint() {
  if [[ ! -f "$NGROK_LOG_FILE" ]]; then
    return 1
  fi

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
  const err = typeof obj.err === "string" ? obj.err : "";
  const match = err.match(/The endpoint '"'"'([^'"'"']+)'"'"' is already online/);
  if (match) {
    process.stdout.write(match[1]);
    process.exit(0);
  }
}
process.exit(1);
' "$NGROK_LOG_FILE"
}

auto_clear_ngrok_collision() {
  local endpoint_url="$1"
  local api_key="${NGROK_API_KEY:-}"

  if [[ -z "$endpoint_url" || -z "$api_key" ]]; then
    return 1
  fi

  echo "[remodex-local] attempting automatic ngrok recovery for: $endpoint_url" >&2

  local endpoint_json
  if ! endpoint_json="$(curl -fsS \
    --url "https://api.ngrok.com/endpoints" \
    --header "Authorization: Bearer ${api_key}" \
    --header "ngrok-version: 2" \
    --header "Content-Type: application/json")"; then
    echo "[remodex-local] could not query ngrok endpoints API for automatic recovery" >&2
    return 1
  fi

  local session_ids
  session_ids="$(printf '%s' "$endpoint_json" | node -e '
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { input += chunk; });
process.stdin.on("end", () => {
  let parsed;
  try {
    parsed = JSON.parse(input);
  } catch {
    process.exit(1);
  }
  const endpoints = Array.isArray(parsed?.endpoints) ? parsed.endpoints : [];
  const ids = endpoints
    .filter((endpoint) => endpoint?.url === process.argv[1] || endpoint?.public_url === process.argv[1])
    .map((endpoint) => endpoint?.tunnel_session?.id)
    .filter((value) => typeof value === "string" && value.length > 0);
  if (ids.length === 0) {
    process.exit(2);
  }
  process.stdout.write(ids.join("\n"));
});
') "$endpoint_url")"

  local parser_status=$?
  if [[ $parser_status -eq 2 ]]; then
    echo "[remodex-local] ngrok API does not currently report an active tunnel session for that endpoint; waiting for release" >&2
    sleep 2
    return 0
  fi
  if [[ $parser_status -ne 0 || -z "$session_ids" ]]; then
    echo "[remodex-local] could not parse ngrok endpoint metadata for automatic recovery" >&2
    return 1
  fi

  local stopped_any=0
  local session_id
  while IFS= read -r session_id; do
    [[ -z "$session_id" ]] && continue
    echo "[remodex-local] stopping conflicting ngrok tunnel session: $session_id" >&2
    if curl -fsS \
      --request POST \
      --url "https://api.ngrok.com/tunnel_sessions/${session_id}/stop" \
      --header "Authorization: Bearer ${api_key}" \
      --header "ngrok-version: 2" \
      --header "Content-Type: application/json" \
      --data "{\"id\":\"${session_id}\"}" >/dev/null; then
      stopped_any=1
    fi
  done <<< "$session_ids"

  if [[ $stopped_any -eq 0 ]]; then
    echo "[remodex-local] automatic ngrok recovery could not stop the conflicting session" >&2
    return 1
  fi

  echo "[remodex-local] waiting for ngrok to release the endpoint" >&2
  sleep 2
  return 0
}

recover_ngrok_collision() {
  local endpoint_url="$1"
  local max_attempts=6
  local attempt=1

  while (( attempt <= max_attempts )); do
    if [[ -n "$endpoint_url" ]]; then
      auto_clear_ngrok_collision "$endpoint_url" || true
    fi

    if (( attempt < max_attempts )); then
      echo "[remodex-local] waiting for ngrok endpoint release (${attempt}/${max_attempts})" >&2
      sleep 5
    fi

    start_ngrok_tunnel
    if wait_for_ngrok; then
      return 0
    fi

    if ! ngrok_log_contains 'ERR_NGROK_334'; then
      return 1
    fi

    endpoint_url="$(extract_ngrok_collision_endpoint 2>/dev/null || printf '%s' "$endpoint_url")"
    attempt=$((attempt + 1))
  done

  return 1
}

start_ngrok_tunnel() {
  cleanup_ngrok_state
  tunnel_pid="$(spawn_detached "$TUNNEL_PID_FILE" "$NGROK_LOG_FILE" \
    ngrok http "http://127.0.0.1:${PORT}" --log=stdout --log-format=json)"
  started_tunnel=1
}

report_ngrok_failure() {
  if [[ ! -f "$NGROK_LOG_FILE" ]]; then
    echo "[remodex-local] ngrok exited before writing a log file." >&2
    return
  fi

  if grep -q 'ERR_NGROK_334' "$NGROK_LOG_FILE" 2>/dev/null; then
    endpoint="$(extract_ngrok_collision_endpoint 2>/dev/null || true)"
    echo "[remodex-local] ngrok endpoint is already online${endpoint:+: $endpoint}" >&2
    if [[ -n "${NGROK_API_KEY:-}" ]]; then
      echo "[remodex-local] automatic recovery using NGROK_API_KEY did not succeed; free the endpoint in ngrok or retry later." >&2
    else
      echo "[remodex-local] set NGROK_API_KEY to allow automatic cloud-session cleanup, or free the endpoint in ngrok and retry." >&2
    fi
    return
  fi

  echo "[remodex-local] ngrok failed to start. Recent log output:" >&2
  tail -20 "$NGROK_LOG_FILE" >&2 || true
}

ensure_local_relay() {
  if curl -fsS "http://${BIND_HOST}:${PORT}/health" >/dev/null 2>&1; then
    echo "[remodex-local] reusing existing local relay on :$PORT"
    return 0
  fi

  rm -f "$RELAY_LOG_FILE"
  relay_pid="$(spawn_detached "$RELAY_PID_FILE" "$RELAY_LOG_FILE" \
    /usr/bin/env "NODE_PATH=$BRIDGE_DIR/node_modules" \
    node "$ROOT_DIR/relay/local-server.js" --host "$BIND_HOST" --port "$PORT")"
  started_relay=1

  if ! wait_for_relay; then
    echo "[remodex-local] failed to start local relay on :$PORT" >&2
    exit 1
  fi
}

write_bridge_status() {
  local state="$1"
  local connection_status="$2"
  local last_error="$3"
  local diagnostic_code="${4:-}"
  local diagnostic_message="${5:-}"

  node - "$BRIDGE_DIR" "$state" "$connection_status" "$last_error" "$diagnostic_code" "$diagnostic_message" <<'NODE'
const path = require("path");
const [bridgeDir, state, connectionStatus, lastError, diagnosticCode, diagnosticMessage] = process.argv.slice(2);
const { writeBridgeStatus } = require(path.join(bridgeDir, "src", "daemon-state"));

const latestReconnectDiagnostic = diagnosticCode
  ? {
      code: diagnosticCode,
      message: diagnosticMessage || lastError || "No reconnect diagnostic available.",
      isPermanent: true,
    }
  : null;

const lastPermanentReconnectReason = latestReconnectDiagnostic
  ? {
      code: latestReconnectDiagnostic.code,
      message: latestReconnectDiagnostic.message,
    }
  : null;

writeBridgeStatus({
  state,
  connectionStatus,
  pid: null,
  lastError,
  latestReconnectDiagnostic,
  lastPermanentReconnectReason,
});
NODE
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

preserve_runtime_after_successful_up() {
  trap - EXIT INT TERM
  rm -f "$BRIDGE_PID_FILE"
}

main() {
  local command="${1:-up}"
  TUNNEL_MODE="$(normalize_tunnel_mode "$TUNNEL_MODE_RAW")"

  if [[ "$command" != "up" && "$command" != "stop" ]]; then
    echo "Usage: ./run-local-remodex.sh [up|stop]" >&2
    exit 1
  fi

  if [[ ! -d "$BRIDGE_DIR/node_modules" ]]; then
    echo "[remodex-local] installing bridge dependencies"
    (cd "$BRIDGE_DIR" && npm install)
  fi

  mkdir -p "$STATE_DIR"

  if [[ "$command" == "stop" ]]; then
    if [[ "$OSTYPE" == darwin* ]]; then
      (
        cd "$BRIDGE_DIR"
        node ./bin/remodex.js stop
      ) || true
    fi
    cleanup_repo_launcher_orphans "stop"
    cleanup_repo_worker_orphans "stop"
    stop_pid_file "bridge" "$BRIDGE_PID_FILE"
    stop_pid_file "tunnel" "$TUNNEL_PID_FILE"
    stop_pid_file "relay" "$RELAY_PID_FILE"
    exit 0
  fi

  trap cleanup EXIT INT TERM

  echo "[remodex-local] bind host: $BIND_HOST"
  echo "[remodex-local] desktop refresh: $REFRESH_ENABLED"
  echo "[remodex-local] tunnel mode: $TUNNEL_MODE"
  if [[ -n "$EXPLICIT_RELAY_URL" ]]; then
    echo "[remodex-local] mode: explicit relay override"
  elif should_use_ngrok_tunnel "$EXPLICIT_RELAY_URL" "$TUNNEL_MODE"; then
    echo "[remodex-local] mode: opt-in remote tunnel"
  else
    echo "[remodex-local] mode: local relay only"
  fi

  preflight_up

  cleanup_repo_launcher_orphans "startup"
  cleanup_repo_worker_orphans "startup"

  if existing_bridge_pid="$(read_live_pid "$BRIDGE_PID_FILE")"; then
    echo "[remodex-local] bridge already running (pid ${existing_bridge_pid})"
    echo "[remodex-local] stop the existing session before starting a new one"
    exit 1
  fi

  echo "$$" > "$BRIDGE_PID_FILE"

  if [[ -n "$EXPLICIT_RELAY_URL" ]]; then
    RELAY_URL="$EXPLICIT_RELAY_URL"
    if [[ "$RELAY_URL" == "$LOCAL_RELAY_URL" || "$RELAY_URL" == "ws://localhost:${PORT}/relay" ]]; then
      ensure_local_relay
      echo "[remodex-local] local relay url: $LOCAL_RELAY_URL"
    fi
    echo "[remodex-local] relay url: $RELAY_URL"
  else
    ensure_local_relay
    echo "[remodex-local] local relay url: $LOCAL_RELAY_URL"

    if should_use_ngrok_tunnel "$EXPLICIT_RELAY_URL" "$TUNNEL_MODE"; then
      rm -f "$NGROK_LOG_FILE"
      start_ngrok_tunnel

      if ! wait_for_ngrok; then
        if ngrok_log_contains 'ERR_NGROK_334'; then
          echo "[remodex-local] ngrok endpoint collision detected; retrying after local cleanup" >&2
          collision_endpoint="$(extract_ngrok_collision_endpoint 2>/dev/null || true)"
          if ! recover_ngrok_collision "$collision_endpoint"; then
            echo "[remodex-local] failed to start ngrok tunnel" >&2
            report_ngrok_failure
            exit 1
          fi
        else
          echo "[remodex-local] failed to start ngrok tunnel" >&2
          report_ngrok_failure
          exit 1
        fi
      fi

      RELAY_URL="$(discover_ngrok_relay_url)"
      echo "[remodex-local] relay url: $RELAY_URL"
    else
      write_bridge_status \
        "idle" \
        "not_configured" \
        "No iPhone-reachable relay URL is configured." \
        "relay_url_required" \
        "Set REMODEX_RELAY to your self-hosted relay URL, or rerun with REMODEX_TUNNEL_MODE=ngrok."
      preserve_runtime_after_successful_up
      echo "[remodex-local] local relay is running, but no iPhone-reachable relay URL is configured."
      echo "[remodex-local] next step: set REMODEX_RELAY to your self-hosted relay URL, or rerun with REMODEX_TUNNEL_MODE=ngrok."
      echo "[remodex-local] no pairing QR was generated because the default local-only path should fail closed."
      return 0
    fi
  fi

  cd "$BRIDGE_DIR"
  echo "[remodex-local] bridge log: $BRIDGE_LOG_FILE"
  rm -f "$BRIDGE_LOG_FILE"
  REMODEX_RELAY="$RELAY_URL" \
  REMODEX_REFRESH_ENABLED="$REFRESH_ENABLED" \
  node ./bin/remodex.js up 2>&1 | tee -a "$BRIDGE_LOG_FILE"

  preserve_runtime_after_successful_up
  echo "[remodex-local] bridge service is up; use remodex stop to stop the local relay, tunnel, and macOS bridge service"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
