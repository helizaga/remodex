// FILE: CodexServiceConnectionErrorTests.swift
// Purpose: Verifies background disconnects stay silent while real connection failures still surface.
// Layer: Unit Test
// Exports: CodexServiceConnectionErrorTests
// Depends on: XCTest, Network, UIKit, CodexMobile

import XCTest
import Network
import UIKit
@testable import CodexMobile

@MainActor
final class CodexServiceConnectionErrorTests: XCTestCase {
    func testBenignBackgroundAbortIsSuppressedFromUserFacingErrors() {
        let service = CodexService()
        let error = NWError.posix(.ECONNABORTED)
        service.isAppInForeground = false

        XCTAssertTrue(service.isBenignBackgroundDisconnect(error))
        XCTAssertTrue(service.shouldSuppressUserFacingConnectionError(error))
    }

    func testSendSideNoDataDisconnectIsTreatedAsBenign() {
        let service = CodexService()
        let error = NWError.posix(.ENODATA)
        service.isAppInForeground = false

        XCTAssertTrue(service.isBenignBackgroundDisconnect(error))
        XCTAssertTrue(service.shouldTreatSendFailureAsDisconnect(error))
        XCTAssertTrue(service.shouldSuppressUserFacingConnectionError(error))
    }

    func testConnectionResetIsTreatedAsBenignRelayDisconnect() {
        let service = CodexService()
        let error = NWError.posix(.ECONNRESET)
        service.isAppInForeground = false

        XCTAssertTrue(service.isBenignBackgroundDisconnect(error))
        XCTAssertTrue(service.shouldSuppressUserFacingConnectionError(error))
    }

    func testInactiveAppStateStillSuppressesBenignDisconnectNoise() {
        let service = CodexService()
        let error = NWError.posix(.ECONNRESET)
        service.isAppInForeground = true
        service.applicationStateProvider = { .inactive }

        XCTAssertTrue(service.shouldSuppressUserFacingConnectionError(error))
    }

    func testTransientTimeoutStillSurfacesToUser() {
        let service = CodexService()
        let error = NWError.posix(.ETIMEDOUT)

        XCTAssertTrue(service.isRecoverableTransientConnectionError(error))
        XCTAssertFalse(service.shouldSuppressUserFacingConnectionError(error))
    }

    func testOversizedRelayPayloadGetsFriendlyFailureCopy() {
        let service = CodexService()
        let error = NWError.posix(.EMSGSIZE)

        XCTAssertTrue(service.isOversizedRelayPayloadError(error))
        XCTAssertEqual(
            service.userFacingConnectFailureMessage(error),
            "A thread payload was too large for the relay connection. This can happen while reopening image-heavy chats even if you didn't press Send."
        )
    }

    func testReceiveDispositionUsesFriendlyOversizedPayloadMessage() {
        let service = CodexService()
        let error = NWError.posix(.EMSGSIZE)

        service.handleReceiveError(error)

        XCTAssertEqual(
            service.lastErrorMessage,
            "A thread payload was too large for the relay connection. This can happen while reopening image-heavy chats even if you didn't press Send."
        )
    }

    func testValidateOutgoingWebSocketMessageSizeRejectsOversizedPayload() {
        let service = CodexService()
        let oversizedText = String(repeating: "a", count: codexWebSocketMaximumMessageSizeBytes + 1)

        XCTAssertThrowsError(try service.validateOutgoingWebSocketMessageSize(oversizedText)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "This payload is too large for the relay connection. Try fewer or smaller images and retry."
            )
        }
    }

    func testBenignDisconnectStaysSilentWhileAutoReconnectIsRunning() {
        let service = CodexService()
        let error = CodexServiceError.disconnected
        service.isAppInForeground = true
        service.shouldAutoReconnectOnForeground = true
        service.connectionRecoveryState = .retrying(attempt: 1, message: "Reconnecting...")

        XCTAssertTrue(service.shouldSuppressRecoverableConnectionError(error))
        XCTAssertTrue(service.shouldSuppressUserFacingConnectionError(error))
    }

    func testConnectionRefusedStillSurfacesToUser() {
        let service = CodexService()
        let error = NWError.posix(.ECONNREFUSED)

        XCTAssertFalse(service.shouldSuppressUserFacingConnectionError(error))
        XCTAssertEqual(
            service.userFacingConnectError(
                error: error,
                attemptedURL: "wss://relay.example/relay/session",
                host: "relay.example"
            ),
            "Connection refused by relay server at wss://relay.example/relay/session."
        )
    }

    func testBenignBackgroundAbortGetsFriendlyFailureCopy() {
        let service = CodexService()

        XCTAssertEqual(
            service.userFacingConnectFailureMessage(NWError.posix(.ECONNABORTED)),
            "The relay or network is temporarily unavailable. Check your connection and try again."
        )
    }

    func testBrokenPipeGetsFriendlyFailureCopy() {
        let service = CodexService()

        XCTAssertEqual(
            service.userFacingConnectFailureMessage(NWError.posix(.EPIPE)),
            "Connection was interrupted. Tap Reconnect to try again."
        )
    }

    func testUnknownNWErrorGetsFriendlyFailureCopy() {
        let service = CodexService()

        XCTAssertEqual(
            service.userFacingConnectFailureMessage(NWError.posix(.EIO)),
            "The relay or network is temporarily unavailable. Check your connection and try again."
        )
    }

    func testTurnErrorSuppressesBrokenPipeWhileAutoReconnectIsRunning() {
        let service = CodexService()
        let error = NWError.posix(.EPIPE)
        service.isAppInForeground = true
        service.shouldAutoReconnectOnForeground = true
        service.connectionRecoveryState = .retrying(attempt: 1, message: "Reconnecting...")

        XCTAssertTrue(service.shouldSuppressRecoverableConnectionError(error))
        XCTAssertEqual(service.userFacingTurnErrorMessage(from: error), "")
    }

    func testConnectTimeSessionUnavailableCloseIsRetryable() {
        let service = CodexService()
        let error = CodexServiceError.invalidInput("WebSocket closed during connect (4002)")

        XCTAssertTrue(service.isRetryableSavedSessionConnectError(error))
        XCTAssertEqual(
            service.userFacingConnectFailureMessage(error),
            "Trying to reach your saved Mac. Remodex will keep retrying. If you restarted the bridge on your Mac, scan the new QR code."
        )
    }

    func testTrustedReconnectUnsupportedRelayGetsDirectRecoveryCopy() {
        let service = CodexService()

        XCTAssertEqual(
            service.reconnectFailurePresentation(for: .unsupportedRelay)?.message,
            "This relay does not support trusted reconnect. Scan a fresh QR code to reconnect."
        )
    }

    func testTrustedReconnectOfflineMacGetsDirectRecoveryCopy() {
        let service = CodexService()

        XCTAssertEqual(
            service.reconnectFailurePresentation(for: .macOffline("ignored"))?.message,
            "Reconnect could not find your Mac's live session. Wake the screen or try reconnecting."
        )
    }

    func testIncompatibleSecureTransportVersionMapsToVersionMismatchReason() {
        let service = CodexService()
        let message = "Update the Remodex iPhone app before reconnecting."

        XCTAssertEqual(
            service.reconnectFailurePresentation(for: CodexSecureTransportError.incompatibleVersion(message))?.code,
            .versionMismatch
        )
        XCTAssertEqual(
            service.reconnectFailurePresentation(for: CodexSecureTransportError.incompatibleVersion(message))?.message,
            message
        )
    }

    func testManualWebSocketClosePayloadPreservesRetryableRelayCode() {
        let service = CodexService()
        let closeCode = service.relayCloseCode(
            fromManualWebSocketClosePayload: Data([0x0F, 0xA2])
        )

        XCTAssertEqual(service.relayCloseCodeRawValue(closeCode), 4002)
    }

    func testManualWebSocketCloseFrameUsesRetryableRelayRecovery() async throws {
        let service = CodexService()
        let connection = NWConnection(
            host: NWEndpoint.Host("localhost"),
            port: NWEndpoint.Port(rawValue: 80)!,
            using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        )
        service.relaySessionId = "session-\(UUID().uuidString)"
        service.relayUrl = "ws://mac.local/relay"
        service.isConnected = true
        service.isInitialized = true
        service.setForegroundState(true)
        service.manualWebSocketReadBuffer = Data([0x88, 0x02, 0x0F, 0xA2])

        let didHandleClose = try await service.drainManualWebSocketFrames(on: connection)

        XCTAssertTrue(didHandleClose)
        XCTAssertFalse(service.isConnected)
        XCTAssertFalse(service.isInitialized)
        XCTAssertTrue(service.shouldAutoReconnectOnForeground)
        XCTAssertEqual(service.connectionRecoveryState, .retrying(attempt: 0, message: "Trying your saved Mac again..."))
        XCTAssertEqual(
            service.lastErrorMessage,
            "Trying to reach your saved Mac. Remodex will keep retrying. If you restarted the bridge on your Mac, scan the new QR code."
        )
    }

    func testLanAddressStillRequiresLocalNetworkAuthorization() {
        let service = CodexService()
        let url = URL(string: "ws://192.168.1.31:9000/relay/session")!

        XCTAssertTrue(service.requiresLocalNetworkAuthorization(for: url))
        XCTAssertTrue(service.prefersDirectRelayTransport(for: url))
    }

    func testTailscaleAddressPrefersDirectRelayTransportWithoutLocalNetworkPrompt() {
        let service = CodexService()
        let url = URL(string: "ws://100.122.27.82:9000/relay/session")!

        XCTAssertTrue(service.prefersDirectRelayTransport(for: url))
        XCTAssertFalse(service.requiresLocalNetworkAuthorization(for: url))
    }

    func testTailscaleMagicDNSHostPrefersDirectRelayTransportWithoutLocalNetworkPrompt() {
        let service = CodexService()
        let url = URL(string: "ws://my-mac.tail-scale.ts.net:9000/relay/session")!

        XCTAssertTrue(service.prefersDirectRelayTransport(for: url))
        XCTAssertFalse(service.requiresLocalNetworkAuthorization(for: url))
    }

    func testWebSocketUpgradeHeadersIncludeTrustedPhoneIdentityForIphoneRole() {
        let service = CodexService()
        service.phoneIdentityState = CodexPhoneIdentityState(
            phoneDeviceId: "phone-123",
            phoneIdentityPrivateKey: "private-key",
            phoneIdentityPublicKey: "public-key"
        )

        let headers = Dictionary(
            uniqueKeysWithValues: service.webSocketUpgradeHeaders(token: "", role: "iphone").map {
                ($0.name, $0.value)
            }
        )

        XCTAssertEqual(headers["x-role"], "iphone")
        XCTAssertEqual(headers["x-phone-device-id"], "phone-123")
        XCTAssertEqual(headers["x-phone-identity-public-key"], "public-key")
        XCTAssertEqual(headers["x-secure-handshake-mode"], "trusted_reconnect")
    }

    func testWebSocketUpgradeHeadersForceQrBootstrapModeAfterFreshScan() {
        let service = CodexService()
        service.phoneIdentityState = CodexPhoneIdentityState(
            phoneDeviceId: "phone-123",
            phoneIdentityPrivateKey: "private-key",
            phoneIdentityPublicKey: "public-key"
        )
        service.shouldForceQRBootstrapOnNextHandshake = true

        let headers = Dictionary(
            uniqueKeysWithValues: service.webSocketUpgradeHeaders(token: "", role: "iphone").map {
                ($0.name, $0.value)
            }
        )

        XCTAssertEqual(headers["x-role"], "iphone")
        XCTAssertEqual(headers["x-phone-device-id"], "phone-123")
        XCTAssertEqual(headers["x-phone-identity-public-key"], "public-key")
        XCTAssertEqual(headers["x-secure-handshake-mode"], "qr_bootstrap")
    }

    func testWebSocketUpgradeHeadersDoNotLeakPhoneIdentityForNonIphoneRoles() {
        let service = CodexService()
        service.phoneIdentityState = CodexPhoneIdentityState(
            phoneDeviceId: "phone-123",
            phoneIdentityPrivateKey: "private-key",
            phoneIdentityPublicKey: "public-key"
        )

        let headers = Dictionary(
            uniqueKeysWithValues: service.webSocketUpgradeHeaders(token: "", role: "mac").map {
                ($0.name, $0.value)
            }
        )

        XCTAssertEqual(headers["x-role"], "mac")
        XCTAssertNil(headers["x-phone-device-id"])
        XCTAssertNil(headers["x-phone-identity-public-key"])
        XCTAssertNil(headers["x-secure-handshake-mode"])
    }

    func testWebSocketUpgradeHeadersUseAuthorizationWhenRoleIsMissing() {
        let service = CodexService()
        let headers = Dictionary(
            uniqueKeysWithValues: service.webSocketUpgradeHeaders(token: "relay-token", role: nil).map {
                ($0.name, $0.value)
            }
        )

        XCTAssertEqual(headers["Authorization"], "Bearer relay-token")
        XCTAssertNil(headers["x-role"])
        XCTAssertNil(headers["x-phone-device-id"])
        XCTAssertNil(headers["x-secure-handshake-mode"])
    }

    func testDirectRelaySocketTimeoutRemainsRetryable() {
        let service = CodexService()
        let error = CodexServiceError.invalidInput(
            "Connection timed out after 12s while opening the direct relay socket."
        )

        XCTAssertTrue(service.isRecoverableTransientConnectionError(error))
        XCTAssertEqual(
            service.userFacingConnectFailureMessage(error),
            "The relay or network is temporarily unavailable. Check your connection and try again."
        )
    }

    func testPrepareForConnectionAttemptPreservesFreshQRHandshakeState() async {
        let service = CodexService()
        let payload = CodexPairingQRPayload(
            v: codexPairingQRVersion,
            relay: "ws://100.122.27.82:9000/relay",
            sessionId: "session-123",
            macDeviceId: "mac-123",
            macIdentityPublicKey: Data(repeating: 1, count: 32).base64EncodedString(),
            expiresAt: 1_800_000_000_000
        )

        service.rememberRelayPairing(payload)
        XCTAssertEqual(service.secureConnectionState, .handshaking)

        await service.prepareForConnectionAttempt(preserveReconnectIntent: true)

        XCTAssertEqual(service.secureConnectionState, .handshaking)
    }

    func testPrepareForConnectionAttemptKeepsThreadStateWhenSocketAlreadyDropped() async {
        let service = CodexService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.activeTurnIdByThread[threadID] = turnID
        service.runningThreadIDs.insert(threadID)
        service.bufferedSecureControlMessages["secureError"] = ["{\"kind\":\"secureError\",\"message\":\"stale\"}"]

        await service.prepareForConnectionAttempt(preserveReconnectIntent: true)

        XCTAssertEqual(service.activeTurnID(for: threadID), turnID)
        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .running)
        XCTAssertTrue(service.bufferedSecureControlMessages.isEmpty)
    }
}
