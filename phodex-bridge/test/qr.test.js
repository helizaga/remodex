const test = require("node:test");
const assert = require("node:assert/strict");
const qrcode = require("qrcode-terminal");
const {
  SHORT_PAIRING_CODE_ALPHABET,
  SHORT_PAIRING_CODE_LENGTH,
  createShortPairingCode,
} = require("../src/qr");

test("createShortPairingCode emits a short human-friendly token", () => {
  const code = createShortPairingCode({
    randomBytesImpl() {
      return Buffer.from([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    },
  });

  assert.equal(code.length, SHORT_PAIRING_CODE_LENGTH);
  assert.match(code, new RegExp(`^[${SHORT_PAIRING_CODE_ALPHABET}]+$`));
});

test("printQR does not echo the raw pairing session id to the console", () => {
  const originalGenerate = qrcode.generate;
  const originalLog = console.log;
  const logs = [];
  const calls = [];

  qrcode.generate = (payload, options) => {
    calls.push({ payload, options });
  };
  console.log = (...args) => {
    logs.push(args.join(" "));
  };

  try {
    delete require.cache[require.resolve("../src/qr")];
    const { printQR } = require("../src/qr");
    printQR({
      sessionId: "secret-session",
      macDeviceId: "mac-1",
      expiresAt: 0,
    });
  } finally {
    qrcode.generate = originalGenerate;
    console.log = originalLog;
    delete require.cache[require.resolve("../src/qr")];
  }

  assert.equal(calls.length, 1);
  assert.equal(calls[0].payload.includes("secret-session"), true);
  assert.equal(calls[0].options.small, true);

  const combinedOutput = logs.join("\n");
  assert.equal(combinedOutput.includes("secret-session"), false);
  assert.equal(combinedOutput.includes("Pairing token: embedded in QR only"), true);
  assert.equal(combinedOutput.includes("Device ID: mac-1"), true);
  assert.equal(combinedOutput.includes("Expires: 1970-01-01T00:00:00.000Z"), true);
});
