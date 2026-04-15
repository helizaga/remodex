// FILE: CodexServiceAssistantMessageTests.swift
// Purpose: Verifies assistant streaming, completion, and legacy agent message handling outside the run-indicator suite.
// Layer: Unit Test
// Exports: CodexServiceAssistantMessageTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexServiceAssistantMessageTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearStoredSecureRelayState()
    }

    override func tearDown() {
        clearStoredSecureRelayState()
        super.tearDown()
    }

    func testAssistantStreamingKeepsSeparateBlocksWhenItemChangesWithinTurn() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: "First")
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: " chunk")
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-2", delta: "Second")

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 2)
        XCTAssertEqual(assistantMessages[0].itemId, "item-1")
        XCTAssertEqual(assistantMessages[0].text, "First chunk")
        XCTAssertFalse(assistantMessages[0].isStreaming)

        XCTAssertEqual(assistantMessages[1].itemId, "item-2")
        XCTAssertEqual(assistantMessages[1].text, "Second")
        XCTAssertTrue(assistantMessages[1].isStreaming)
    }

    func testAssistantStreamingUpdatesExistingRenderSnapshotText() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        _ = service.timelineState(for: threadID)
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: "First")
        let firstSnapshot = service.timelineState(for: threadID).renderSnapshot

        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: " chunk")
        let secondSnapshot = service.timelineState(for: threadID).renderSnapshot

        XCTAssertEqual(firstSnapshot.messages.count, 1)
        XCTAssertEqual(firstSnapshot.messages[0].text, "First")
        XCTAssertEqual(secondSnapshot.messages.count, 1)
        XCTAssertEqual(secondSnapshot.messages[0].text, "First chunk")
        XCTAssertGreaterThan(secondSnapshot.timelineChangeToken, firstSnapshot.timelineChangeToken)
    }

    func testAssistantStreamingFastPathKeepsCurrentOutputInSync() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        _ = service.timelineState(for: threadID)
        service.activeThreadId = threadID

        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: "First")
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: " chunk")

        XCTAssertEqual(service.currentOutput, "First chunk")
    }

    func testAssistantStreamingFallbackKeepsCurrentOutputInSyncWithoutTimelineState() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.activeThreadId = threadID

        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: "First")
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: " chunk")

        XCTAssertEqual(service.currentOutput, "First chunk")
        XCTAssertEqual(service.timelineState(for: threadID).renderSnapshot.messages.first?.text, "First chunk")
    }

    func testLateDeltaForOlderAssistantItemDoesNotReplaceLatestOutput() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        _ = service.timelineState(for: threadID)
        service.activeThreadId = threadID

        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: "First")
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-2", delta: "Second")
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: " tail")

        XCTAssertEqual(service.currentOutput, "Second")
    }

    func testMergeAssistantDeltaKeepsLongReplayOverlapWithoutDuplication() {
        let service = makeService()
        let overlap = String(repeating: "a", count: 300)
        let existing = "prefix-" + overlap
        let incoming = overlap + "-suffix"

        let merged = service.mergeAssistantDelta(existingText: existing, incomingDelta: incoming)

        XCTAssertEqual(merged, "prefix-" + overlap + "-suffix")
    }

    func testMarkTurnCompletedFinalizesAllAssistantItemsForTurn() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: "A")
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-2", delta: "B")

        service.markTurnCompleted(threadId: threadID, turnId: turnID)

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 2)
        XCTAssertTrue(assistantMessages.allSatisfy { !$0.isStreaming })

        let turnStreamingKey = "\(threadID)|\(turnID)"
        XCTAssertFalse(service.streamingAssistantMessageByTurnID.keys.contains { key in
            key == turnStreamingKey || key.hasPrefix("\(turnStreamingKey)|item:")
        })
    }

    func testSuccessfulTurnCompletionFinalizesIncompletePlanSteps() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "item-\(UUID().uuidString)"

        service.handleNotification(
            method: "turn/plan/updated",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "explanation": .string("Finish the work in safe slices."),
                "plan": .array([
                    .object([
                        "step": .string("Inspect"),
                        "status": .string("completed"),
                    ]),
                    .object([
                        "step": .string("Implement"),
                        "status": .string("in_progress"),
                    ]),
                    .object([
                        "step": .string("Verify"),
                        "status": .string("pending"),
                    ]),
                ]),
            ])
        )

        service.handleNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string(itemID),
                    "type": .string("plan"),
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("1. Inspect\n2. Implement\n3. Verify"),
                        ]),
                    ]),
                ]),
            ])
        )

        sendTurnCompletedSuccess(service: service, threadID: threadID, turnID: turnID)

        let planMessages = service.messages(for: threadID).filter { $0.kind == .plan }
        XCTAssertEqual(planMessages.count, 1)
        XCTAssertFalse(planMessages[0].isStreaming)
        XCTAssertEqual(planMessages[0].planState?.steps.map(\.status), [.completed, .completed, .completed])
        XCTAssertFalse(planMessages[0].shouldDisplayPinnedPlanAccessory)
    }

    func testLegacyAgentDeltaParsesTopLevelTurnIdAndMessageId() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.handleNotification(
            method: "codex/event/agent_message_content_delta",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("agent_message_content_delta"),
                    "message_id": .string("message-1"),
                    "delta": .string("Primo blocco"),
                ]),
            ])
        )

        service.handleNotification(
            method: "codex/event/agent_message_content_delta",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("agent_message_content_delta"),
                    "message_id": .string("message-2"),
                    "delta": .string("Secondo blocco"),
                ]),
            ])
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 2)
        XCTAssertEqual(assistantMessages[0].turnId, turnID)
        XCTAssertEqual(assistantMessages[0].itemId, "message-1")
        XCTAssertEqual(assistantMessages[0].text, "Primo blocco")
        XCTAssertFalse(assistantMessages[0].isStreaming)

        XCTAssertEqual(assistantMessages[1].turnId, turnID)
        XCTAssertEqual(assistantMessages[1].itemId, "message-2")
        XCTAssertEqual(assistantMessages[1].text, "Secondo blocco")
        XCTAssertTrue(assistantMessages[1].isStreaming)
    }

    func testLegacyAgentCompletionUsesMessageIdToFinalizeMatchingStream() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.handleNotification(
            method: "codex/event/agent_message_content_delta",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("agent_message_content_delta"),
                    "message_id": .string("message-1"),
                    "delta": .string("Testo parziale"),
                ]),
            ])
        )

        service.handleNotification(
            method: "codex/event/agent_message",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("agent_message"),
                    "message_id": .string("message-1"),
                    "message": .string("Testo finale"),
                ]),
            ])
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages[0].turnId, turnID)
        XCTAssertEqual(assistantMessages[0].itemId, "message-1")
        XCTAssertEqual(assistantMessages[0].text, "Testo finale")
        XCTAssertFalse(assistantMessages[0].isStreaming)
    }

    func testLateLegacyAgentCompletionWithoutMessageIdUpdatesClosedSingleAssistantBubble() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.handleNotification(
            method: "codex/event/agent_message_content_delta",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("agent_message_content_delta"),
                    "message_id": .string("message-1"),
                    "delta": .string("Testo parziale"),
                ]),
            ])
        )

        sendTurnCompletedSuccess(service: service, threadID: threadID, turnID: turnID)

        service.handleNotification(
            method: "codex/event/agent_message",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("agent_message"),
                    "message": .string("Testo finale"),
                ]),
            ])
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages[0].turnId, turnID)
        XCTAssertEqual(assistantMessages[0].itemId, "message-1")
        XCTAssertEqual(assistantMessages[0].text, "Testo finale")
        XCTAssertFalse(assistantMessages[0].isStreaming)
    }

    func testLateLegacyAgentCompletionWithoutMessageIdIsIgnoredForClosedMultiAssistantTurn() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.handleNotification(
            method: "codex/event/agent_message_content_delta",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("agent_message_content_delta"),
                    "message_id": .string("message-1"),
                    "delta": .string("Primo blocco"),
                ]),
            ])
        )
        service.handleNotification(
            method: "codex/event/agent_message_content_delta",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("agent_message_content_delta"),
                    "message_id": .string("message-2"),
                    "delta": .string("Secondo blocco"),
                ]),
            ])
        )

        sendTurnCompletedSuccess(service: service, threadID: threadID, turnID: turnID)

        service.handleNotification(
            method: "codex/event/agent_message",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("agent_message"),
                    "message": .string("Risposta finale ambigua"),
                ]),
            ])
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 2)
        XCTAssertEqual(assistantMessages[0].text, "Primo blocco")
        XCTAssertEqual(assistantMessages[1].text, "Secondo blocco")
    }

    func testLateLegacyAgentCompletionWithoutMessageIdDoesNotRegressClosedSingleAssistantBubble() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.handleNotification(
            method: "codex/event/agent_message_content_delta",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("agent_message_content_delta"),
                    "message_id": .string("message-1"),
                    "delta": .string("Testo finale completo"),
                ]),
            ])
        )

        sendTurnCompletedSuccess(service: service, threadID: threadID, turnID: turnID)

        service.handleNotification(
            method: "codex/event/agent_message",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("agent_message"),
                    "message": .string("Testo finale"),
                ]),
            ])
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages[0].text, "Testo finale completo")
        XCTAssertEqual(assistantMessages[0].itemId, "message-1")
    }

    private func sendTurnCompletedSuccess(service: CodexService, threadID: String, turnID: String) {
        service.handleNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceAssistantMessageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(
            defaults: defaults,
            messagePersistence: .disabled,
            aiChangeSetPersistence: .disabled,
            userNotificationCenter: CodexNoopUserNotificationCenter(),
            remoteNotificationRegistrar: CodexNoopRemoteNotificationRegistrar(),
            secureStateBootstrap: .ephemeral
        )
        service.messagesByThread = [:]
        return service
    }

    private func clearStoredSecureRelayState() {
        SecureStore.deleteValue(for: CodexSecureKeys.relaySessionId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayUrl)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacDeviceId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacIdentityPublicKey)
        SecureStore.deleteValue(for: CodexSecureKeys.relayProtocolVersion)
        SecureStore.deleteValue(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)
        SecureStore.deleteValue(for: CodexSecureKeys.trustedMacRegistry)
        SecureStore.deleteValue(for: CodexSecureKeys.lastTrustedMacDeviceId)
    }
}
