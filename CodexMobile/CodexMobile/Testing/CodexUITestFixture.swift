// FILE: CodexUITestFixture.swift
// Purpose: Deterministic app-launch fixtures for XCUITest and timeline performance coverage.
// Layer: Testing
// Exports: CodexUITestHarness, CodexUITestLaunchFixture, CodexUITestFixtureRootView
// Depends on: SwiftUI, CodexService, SubscriptionService, CodexThread, CodexMessage

import Foundation
import SwiftUI

enum CodexUITestHarness {
    @MainActor
    static func makeIfEnabled(
        arguments: [String]
    ) -> (fixture: CodexUITestLaunchFixture, service: CodexService, subscriptions: SubscriptionService)? {
        guard let options = CodexUITestLaunchOptions(arguments: arguments) else {
            return nil
        }

        let suiteName = "CodexUITests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            assertionFailure("Could not create isolated UI test defaults suite: \(suiteName)")
            return nil
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(
            defaults: defaults,
            userNotificationCenter: CodexNoopUserNotificationCenter(),
            remoteNotificationRegistrar: CodexNoopRemoteNotificationRegistrar()
        )
        let subscriptions = SubscriptionService(defaults: defaults)
        let fixture = configureFixture(options: options, service: service)
        return (fixture, service, subscriptions)
    }

    @MainActor
    private static func configureFixture(
        options: CodexUITestLaunchOptions,
        service: CodexService
    ) -> CodexUITestLaunchFixture {
        reset(service: service)

        let thread = CodexThread(
            id: "uitest-thread-primary",
            title: options.threadTitle,
            preview: options.threadPreview,
            updatedAt: Date(timeIntervalSince1970: 1_710_000_000)
        )

        service.upsertThread(thread)
        service.activeThreadId = thread.id
        service.isInitialized = true
        service.syncRealtimeEnabled = true

        switch options.scenario {
        case .timeline:
            service.isConnected = false
            service.messagesByThread[thread.id] = timelineMessages(
                threadId: thread.id,
                count: options.messageCount
            )
            service.hydratedThreadIDs.insert(thread.id)
        case .oversizedHistoryWithLocalTranscript:
            service.isConnected = true
            service.messagesByThread[thread.id] = timelineMessages(
                threadId: thread.id,
                count: max(12, options.messageCount)
            )
            service.requestTransportOverride = oversizedHistoryTransportOverride(
                thread: thread,
                includeLocalTranscript: true
            )
        case .oversizedHistoryWithoutLocalTranscript:
            service.isConnected = true
            service.relaySessionId = "uitest-saved-session"
            service.relayUrl = "ws://uitest-relay.local/relay"
            service.requestTransportOverride = oversizedHistoryTransportOverride(
                thread: thread,
                includeLocalTranscript: false
            )
        }

        service.updateCurrentOutput(for: thread.id)
        return CodexUITestLaunchFixture(options: options, threadID: thread.id, fallbackThread: thread)
    }

    @MainActor
    private static func reset(service: CodexService) {
        service.stopSyncLoop()
        service.isConnected = false
        service.isConnecting = false
        service.isInitialized = false
        service.isLoadingThreads = false
        service.isBootstrappingConnectionSync = false
        service.currentOutput = ""
        service.activeThreadId = nil
        service.activeTurnId = nil
        service.activeTurnIdByThread = [:]
        service.runningThreadIDs = []
        service.protectedRunningFallbackThreadIDs = []
        service.readyThreadIDs = []
        service.failedThreadIDs = []
        service.lastErrorMessage = nil
        service.connectionRecoveryState = .idle
        service.messagesByThread = [:]
        service.messageRevisionByThread = [:]
        service.contextWindowUsageByThread = [:]
        service.hydratedThreadIDs = []
        service.loadingThreadIDs = []
        service.resumedThreadIDs = []
        service.relaySessionId = nil
        service.relayUrl = nil
        service.relayMacDeviceId = nil
        service.relayMacIdentityPublicKey = nil
        service.requestTransportOverride = nil
        service.removeAllThreadTimelineState()
        service.threads = []
    }

    private static func timelineMessages(threadId: String, count: Int) -> [CodexMessage] {
        let resolvedCount = max(1, count)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        return (0..<resolvedCount).map { index in
            let role: CodexMessageRole = index.isMultiple(of: 2) ? .user : .assistant
            let text: String
            if role == .user {
                text = "Fixture user prompt \(index): summarize the latest timeline state for deterministic scrolling coverage."
            } else {
                text = """
                Fixture assistant response \(index): this row exists to exercise layout, markdown shaping, and long-thread scrolling without relying on a live bridge connection.
                """
            }

            return CodexMessage(
                id: "uitest-message-\(index)",
                threadId: threadId,
                role: role,
                text: text,
                createdAt: baseDate.addingTimeInterval(Double(index)),
                orderIndex: index + 1
            )
        }
    }

    private static func oversizedHistoryTransportOverride(
        thread: CodexThread,
        includeLocalTranscript: Bool
    ) -> (String, JSONValue?) async throws -> RPCMessage {
        { method, params in
            switch method {
            case "thread/resume":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(thread.id),
                            "title": .string(thread.displayTitle),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/read":
                let includeTurns = params?.objectValue?["includeTurns"]?.boolValue ?? false
                if includeTurns {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(POSIXErrorCode.EMSGSIZE.rawValue),
                        userInfo: nil
                    )
                }

                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(thread.id),
                            "title": .string(thread.displayTitle),
                            "preview": .string(
                                includeLocalTranscript
                                    ? "Recovered from oversized history using local transcript."
                                    : "Oversized history requires reconnect recovery."
                            ),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/contextWindow/read", "account/rateLimits/read":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }
    }
}

struct CodexUITestLaunchFixture {
    let options: CodexUITestLaunchOptions
    let threadID: String
    let fallbackThread: CodexThread

    @MainActor
    func startIfNeeded(using service: CodexService) async {
        guard options.autoStream else {
            return
        }

        let turnID = "uitest-stream-turn"
        let itemID = "uitest-stream-item"
        let chunks = [
            "Streaming fixture chunk 1. ",
            "Streaming fixture chunk 2. ",
            "Streaming fixture chunk 3. ",
            "Streaming fixture chunk 4."
        ]

        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }

        service.markThreadAsRunning(threadID)
        service.setActiveTurnID(turnID, for: threadID)
        service.beginAssistantMessage(threadId: threadID, turnId: turnID, itemId: itemID)

        for chunk in chunks {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: itemID, delta: chunk)
        }

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: itemID,
            text: chunks.joined()
        )
        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        service.setActiveTurnID(nil, for: threadID)
        service.clearRunningState(for: threadID)
    }
}

struct CodexUITestFixtureRootView: View {
    let fixture: CodexUITestLaunchFixture

    @Environment(CodexService.self) private var codex
    @State private var didStartFixtureScenario = false

    private var resolvedThread: CodexThread {
        codex.thread(for: fixture.threadID) ?? fixture.fallbackThread
    }

    var body: some View {
        NavigationStack {
            TurnView(
                thread: resolvedThread,
                isWakingMacDisplayRecovery: false
            )
        }
        .task {
            guard !didStartFixtureScenario else { return }
            didStartFixtureScenario = true
            await fixture.startIfNeeded(using: codex)
        }
    }
}

struct CodexUITestLaunchOptions {
    enum Scenario: String {
        case timeline
        case oversizedHistoryWithLocalTranscript
        case oversizedHistoryWithoutLocalTranscript
    }

    let messageCount: Int
    let autoStream: Bool
    let scenario: Scenario

    init?(arguments: [String]) {
        guard arguments.contains("-CodexUITestsFixture") else {
            return nil
        }

        let rawMessageCount = Self.value(after: "-CodexUITestsMessageCount", in: arguments)
        let parsedMessageCount = rawMessageCount.flatMap(Int.init) ?? 120
        self.messageCount = max(0, parsedMessageCount)
        self.autoStream = arguments.contains("-CodexUITestsAutoStream")

        let rawScenario = Self.value(after: "-CodexUITestsScenario", in: arguments)
        self.scenario = rawScenario.flatMap(Scenario.init(rawValue:)) ?? .timeline
    }

    var threadTitle: String {
        switch scenario {
        case .timeline:
            return "Fixture Timeline"
        case .oversizedHistoryWithLocalTranscript:
            return "Oversized History (Recovered)"
        case .oversizedHistoryWithoutLocalTranscript:
            return "Oversized History (Needs Recovery)"
        }
    }

    var threadPreview: String {
        switch scenario {
        case .timeline:
            return "Deterministic timeline fixture"
        case .oversizedHistoryWithLocalTranscript:
            return "Uses the local transcript when thread/read is oversized"
        case .oversizedHistoryWithoutLocalTranscript:
            return "Shows recovery UI when no local transcript exists"
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let flagIndex = arguments.firstIndex(of: flag) else {
            return nil
        }

        let valueIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(valueIndex) else {
            return nil
        }

        return arguments[valueIndex]
    }
}
