const test = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const path = require("node:path");

const launcherPath = path.resolve(__dirname, "..", "..", "run-local-remodex.sh");

function runLauncherFunction(command) {
  return execFileSync("bash", [
    "-lc",
    `source "${launcherPath}" >/dev/null 2>&1; set +e; ${command}`,
  ], {
    encoding: "utf8",
    env: {
      ...process.env,
      REMODEX_TUNNEL_MODE: "",
    },
  }).trim();
}

test("launcher defaults tunnel mode to ngrok", () => {
  assert.equal(runLauncherFunction('printf "%s" "$TUNNEL_MODE_RAW"'), "ngrok");
  assert.equal(runLauncherFunction('normalize_tunnel_mode "$TUNNEL_MODE_RAW"'), "ngrok");
  assert.equal(runLauncherFunction('normalize_tunnel_mode "NGROK"'), "ngrok");
});

test("launcher keeps local-only mode available when explicitly requested", () => {
  assert.equal(runLauncherFunction('normalize_tunnel_mode "off"'), "off");
  assert.equal(runLauncherFunction('normalize_tunnel_mode "unexpected"'), "off");
});

test("launcher enables ngrok when selected", () => {
  assert.equal(runLauncherFunction('normalize_tunnel_mode "ngrok"'), "ngrok");
  assert.equal(runLauncherFunction('should_use_ngrok_tunnel "" "ngrok"; echo $?'), "0");
  assert.equal(runLauncherFunction('should_use_ngrok_tunnel "" "off"; echo $?'), "1");
});

test("explicit relay bypasses the ngrok tunnel path", () => {
  assert.equal(
    runLauncherFunction('should_use_ngrok_tunnel "wss://relay.example/relay" "ngrok"; echo $?'),
    "1"
  );
});

test("launcher parses ngrok tunnel session ids for the requested endpoint", () => {
  assert.equal(
    runLauncherFunction(
      `extract_ngrok_tunnel_session_ids_for_endpoint '${JSON.stringify({
        endpoints: [
          { url: "https://foo.ngrok.app", tunnel_session: { id: "session-123" } },
        ],
      })}' 'https://foo.ngrok.app'`
    ),
    "session-123"
  );
});

test("launcher returns exit code 2 when no ngrok tunnel session matches the endpoint", () => {
  assert.equal(
    runLauncherFunction(
      `extract_ngrok_tunnel_session_ids_for_endpoint '${JSON.stringify({
        endpoints: [
          { url: "https://foo.ngrok.app", tunnel_session: { id: "session-123" } },
        ],
      })}' 'https://bar.ngrok.app'; echo $?`
    ),
    "2"
  );
});
