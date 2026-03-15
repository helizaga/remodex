// FILE: QRScannerPairingValidatorTests.swift
// Purpose: Verifies QR validation blocks stale bridge payloads before the user retries pairing.
// Layer: Unit Test
// Exports: QRScannerPairingValidatorTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class QRScannerPairingValidatorTests: XCTestCase {
    func testOlderVersionRequiresBridgeUpdateBeforeScanning() {
        let result = validatePairingQRCode(
            pairingQRCode(
                v: codexPairingQRVersion - 1,
                expiresAt: 1_900_000_000_000
            )
        )

        guard case .bridgeUpdateRequired(let prompt) = result else {
            return XCTFail("Expected a bridge update prompt for mismatched QR versions.")
        }

        XCTAssertEqual(prompt.title, "Update Remodex on your Mac before scanning")
        XCTAssertEqual(prompt.command, "npm install -g remodex@latest")
        XCTAssertTrue(prompt.message.contains("older Remodex bridge"))
    }

    func testNewerVersionRequiresAppUpdateBeforeScanning() {
        let result = validatePairingQRCode(
            pairingQRCode(
                v: codexPairingQRVersion + 1,
                expiresAt: 1_900_000_000_000
            )
        )

        guard case .appUpdateRequired(let message) = result else {
            return XCTFail("Expected an app update prompt for newer QR versions.")
        }

        XCTAssertTrue(message.contains("newer Remodex bridge"))
        XCTAssertTrue(message.contains("Update the Remodex iPhone app"))
    }

    func testLegacyBridgePayloadRequiresBridgeUpdateBeforeScanning() {
        let result = validatePairingQRCode("""
        {"relay":"wss://relay.example","sessionId":"session-123","expiresAt":1900000000000}
        """)

        guard case .bridgeUpdateRequired(let prompt) = result else {
            return XCTFail("Expected a bridge update prompt for legacy pairing payloads.")
        }

        XCTAssertEqual(prompt.command, "npm install -g remodex@latest")
        XCTAssertTrue(prompt.message.contains("older Remodex bridge"))
    }

    func testRelayAndSessionWithoutMetadataDoNotTriggerBridgeUpdatePrompt() {
        let result = validatePairingQRCode("""
        {"relay":"wss://relay.example","sessionId":"session-123"}
        """)

        guard case .scanError(let message) = result else {
            return XCTFail("Expected a scan error for non-pairing payloads without enough legacy metadata.")
        }

        XCTAssertEqual(message, "Not a valid secure pairing code. Make sure you're scanning a QR from the latest Remodex bridge.")
    }

    func testRawNewerVersionFallbackStillRequiresAppUpdate() {
        let result = validatePairingQRCode("""
        {"v":\(codexPairingQRVersion + 1),"relay":"wss://relay.example"}
        """)

        guard case .appUpdateRequired(let message) = result else {
            return XCTFail("Expected a fallback app update prompt for newer raw QR versions.")
        }

        XCTAssertTrue(message.contains("newer Remodex bridge"))
    }

    func testValidPayloadReturnsSuccess() {
        let result = validatePairingQRCode(
            pairingQRCode(
                v: codexPairingQRVersion,
                expiresAt: 1_900_000_000_000
            ),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        guard case .success(let payload) = result else {
            return XCTFail("Expected a valid payload.")
        }

        XCTAssertEqual(payload.sessionId, "session-123")
        XCTAssertEqual(payload.relay, "wss://relay.example")
    }

    func testExpiredPayloadReturnsScanError() {
        let result = validatePairingQRCode(
            pairingQRCode(
                v: codexPairingQRVersion,
                expiresAt: 1_700_000_000_000
            ),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        guard case .scanError(let message) = result else {
            return XCTFail("Expected an expiry error.")
        }

        XCTAssertEqual(message, "This pairing QR code has expired. Generate a new one from the Mac bridge.")
    }

    private func pairingQRCode(v: Int, expiresAt: Int64) -> String {
        """
        {"v":\(v),"relay":"wss://relay.example","sessionId":"session-123","macDeviceId":"mac-123","macIdentityPublicKey":"pub-key","expiresAt":\(expiresAt)}
        """
    }
}
