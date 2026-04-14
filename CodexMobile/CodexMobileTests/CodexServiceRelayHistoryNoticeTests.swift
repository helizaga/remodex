// FILE: CodexServiceRelayHistoryNoticeTests.swift
// Purpose: Verifies relay-truncated thread history surfaces a visible notice and clears after a later full refresh.
// Layer: Unit Test
// Exports: CodexServiceRelayHistoryNoticeTests
// Depends on: XCTest, Network, CodexMobile

import XCTest
import Network
@testable import CodexMobile

@MainActor
final class CodexServiceRelayHistoryNoticeTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testOversizedHistoryFallbackAppendsRelayHistoryNotice() async throws {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        service.upsertThread(CodexThread(id: threadID, title: "Large Thread"))
        service.messagesByThread[threadID] = [
            CodexMessage(threadId: threadID, role: .assistant, text: "Cached transcript"),
        ]

        var includeTurnsRequests: [Bool] = []
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/read")
            let includeTurns = params?.objectValue?["includeTurns"]?.boolValue ?? false
            includeTurnsRequests.append(includeTurns)

            if includeTurns {
                throw NWError.posix(.EMSGSIZE)
            }

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "id": .string(threadID),
                        "title": .string("Large Thread"),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let outcome = try await service.loadThreadHistoryIfNeeded(threadId: threadID)

        XCTAssertEqual(outcome, .loadedTruncatedHistory)
        XCTAssertEqual(includeTurnsRequests, [true, false])
        XCTAssertTrue(service.hydratedThreadIDs.contains(threadID))
        XCTAssertTrue(service.threadsWithSatisfiedDeferredHistoryHydration.contains(threadID))
        XCTAssertNotNil(relayHistoryNotice(in: service.messages(for: threadID)))
    }

    func testFullHistoryRefreshClearsExistingRelayHistoryNotice() async throws {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        service.upsertThread(CodexThread(id: threadID, title: "Recovered Thread"))

        var requestCount = 0
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/read")
            requestCount += 1

            let threadObject: [String: JSONValue]
            if requestCount == 1 {
                threadObject = [
                    "id": .string(threadID),
                    "title": .string("Recovered Thread"),
                    "relayHistoryTruncated": .bool(true),
                    "relayHistoryDroppedTurns": .integer(2),
                    "relayHistoryDroppedItems": .integer(1),
                    "turns": .array([]),
                ]
            } else {
                threadObject = [
                    "id": .string(threadID),
                    "title": .string("Recovered Thread"),
                    "turns": .array([]),
                ]
            }

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object(threadObject),
                ]),
                includeJSONRPC: false
            )
        }

        let firstOutcome = try await service.loadThreadHistoryIfNeeded(threadId: threadID)
        XCTAssertEqual(firstOutcome, .loadedTruncatedHistory)
        XCTAssertEqual(
            relayHistoryNotice(in: service.messages(for: threadID))?.text,
            "Older history was omitted while reopening this thread to fit the relay size limit. The transcript on iPhone may be incomplete. Dropped 2 older turns and 1 item."
        )

        let secondOutcome = try await service.loadThreadHistoryIfNeeded(
            threadId: threadID,
            forceRefresh: true
        )

        XCTAssertEqual(secondOutcome, .loadedCanonicalHistory)
        XCTAssertNil(relayHistoryNotice(in: service.messages(for: threadID)))
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceRelayHistoryNoticeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }

    private func relayHistoryNotice(in messages: [CodexMessage]) -> CodexMessage? {
        messages.first(where: { message in
            message.role == .system
                && message.kind == .chat
                && message.text.contains("transcript on iPhone may be incomplete")
        })
    }
}
