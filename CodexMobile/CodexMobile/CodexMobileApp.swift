// FILE: CodexMobileApp.swift
// Purpose: App entry point, RevenueCat setup, and root dependency wiring.
// Layer: App
// Exports: CodexMobileApp

import RevenueCat
import SwiftUI
import UserNotifications

private struct CodexUnitTestHostView: View {
    var body: some View {
        Color.clear
    }
}

@MainActor
@main
struct CodexMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(CodexMobileAppDelegate.self) private var appDelegate
    @State private var codexService: CodexService
    @State private var subscriptionService: SubscriptionService
    @State private var uiTestFixture: CodexUITestLaunchFixture?
    private let shouldSkipAppBootstrap: Bool

    init() {
        let shouldSkipAppBootstrap = CodexRuntimeEnvironment.isRunningAutomatedTests
        self.shouldSkipAppBootstrap = shouldSkipAppBootstrap
        Self.configureRevenueCatIfAvailable(skip: shouldSkipAppBootstrap)
        if let fixtureContext = CodexUITestHarness.makeIfEnabled(arguments: ProcessInfo.processInfo.arguments) {
            _codexService = State(initialValue: fixtureContext.service)
            _subscriptionService = State(initialValue: fixtureContext.subscriptions)
            _uiTestFixture = State(initialValue: fixtureContext.fixture)
        } else {
            let service = shouldSkipAppBootstrap
                ? CodexService(
                    defaults: UserDefaults(suiteName: "CodexMobile.AutomatedTestHost") ?? .standard,
                    messagePersistence: .disabled,
                    aiChangeSetPersistence: .disabled,
                    userNotificationCenter: CodexNoopUserNotificationCenter(),
                    remoteNotificationRegistrar: CodexNoopRemoteNotificationRegistrar(),
                    secureStateBootstrap: .ephemeral
                )
                : CodexService()
            if !shouldSkipAppBootstrap {
                service.configureNotifications()
            }
            _codexService = State(initialValue: service)
            _subscriptionService = State(initialValue: SubscriptionService())
            _uiTestFixture = State(initialValue: nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(codexService)
                .environment(subscriptionService)
                .onOpenURL { url in
                    Task { @MainActor in
                        guard CodexService.legacyGPTLoginCallbackEnabled else {
                            return
                        }
                        await codexService.handleGPTLoginCallbackURL(url)
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didReceiveMemoryWarningNotification
                    )
                ) { _ in
                    TurnCacheManager.resetAll()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .background else { return }
                    TurnCacheManager.resetAll()
                }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        if let uiTestFixture {
            CodexUITestFixtureRootView(fixture: uiTestFixture)
        } else if shouldSkipAppBootstrap {
            // Keep host-based unit tests out of the real app shell and its scene/lifecycle work.
            CodexUnitTestHostView()
        } else {
            ContentView()
                .task {
                    guard !shouldSkipAppBootstrap else {
                        return
                    }
                    await subscriptionService.bootstrap()
                }
        }
    }
    private static func configureRevenueCatIfAvailable(skip: Bool) {
        guard !skip else {
            return
        }

        guard AppEnvironment.requiresProSubscription else {
            return
        }

        guard let apiKey = AppEnvironment.revenueCatPublicAPIKey else {
            assertionFailure("Missing RevenueCat public API key in Info.plist")
            return
        }

        #if DEBUG
        Purchases.logLevel = .debug
        #endif

        Purchases.configure(withAPIKey: apiKey)
    }
}
