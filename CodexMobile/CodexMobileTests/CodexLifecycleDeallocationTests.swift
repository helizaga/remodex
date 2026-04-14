// FILE: CodexLifecycleDeallocationTests.swift
// Purpose: Proves the service and turn view model can deallocate under the unit-test harness.
// Layer: Unit Test
// Exports: CodexLifecycleDeallocationTests
// Depends on: XCTest, UserNotifications, CodexMobile

import XCTest
import UserNotifications
@testable import CodexMobile

@MainActor
final class CodexLifecycleDeallocationTests: XCTestCase {
    func testCodexServiceDeallocatesAfterNotificationSetup() async {
        weak var weakService: CodexService?
        let notificationCenter = LifecycleMockUserNotificationCenter()

        do {
            let suiteName = "CodexLifecycleDeallocationTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.removePersistentDomain(forName: suiteName)

            let service = CodexService(
                defaults: defaults,
                userNotificationCenter: notificationCenter,
                remoteNotificationRegistrar: LifecycleMockRemoteNotificationRegistrar()
            )
            service.messagesByThread["thread-1"] = [
                CodexMessage(
                    threadId: "thread-1",
                    role: .assistant,
                    text: "Saved before teardown",
                    createdAt: Date(),
                    isStreaming: false
                )
            ]
            service.messagePersistenceDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            service.gptAccountLoginSyncTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            service.configureNotifications()
            XCTAssertNotNil(notificationCenter.delegate)
            weakService = service
        }

        await assertReleased("CodexService", weakReference: weakService)
        XCTAssertNil(notificationCenter.delegate)
    }

    func testTurnViewModelDeallocatesWithPendingWorktreeHandlers() async {
        weak var weakViewModel: TurnViewModel?

        do {
            let viewModel = TurnViewModel()
            viewModel.pendingGitBranchOperation = .createWorktree(
                branchName: "feature/lifecycle",
                baseBranch: "main",
                changeTransfer: .none
            )
            viewModel.pendingGitWorktreeOpenHandler = { [weak viewModel] _ in
                viewModel?.input = "opened"
            }
            viewModel.pendingManagedGitWorktreeOpenHandler = { [weak viewModel] _ in
                viewModel?.input = "managed-opened"
            }
            viewModel.fileAutocompleteDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            weakViewModel = viewModel
        }

        await assertReleased("TurnViewModel", weakReference: weakViewModel)
    }

    private func assertReleased(
        _ name: String,
        weakReference: @autoclosure @escaping () -> AnyObject?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<20 {
            if weakReference() == nil {
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("\(name) should deallocate after leaving scope.", file: file, line: line)
    }
}

@MainActor
private final class LifecycleMockUserNotificationCenter: CodexUserNotificationCentering {
    var delegate: UNUserNotificationCenterDelegate?

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        false
    }

    func add(_ request: UNNotificationRequest) async throws {}

    func authorizationStatus() async -> UNAuthorizationStatus {
        .notDetermined
    }
}

@MainActor
private final class LifecycleMockRemoteNotificationRegistrar: CodexRemoteNotificationRegistering {
    func registerForRemoteNotifications() {}
}
