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
    @State private var petCompanionStore: PetCompanionStore
    @State private var petCompanionStatusStore: PetCompanionStatusStore
    @State private var subscriptionService: SubscriptionService
    @State private var uiTestFixture: CodexUITestLaunchFixture?
    private let shouldSkipAppBootstrap: Bool

    init() {
        let shouldSkipAppBootstrap = CodexRuntimeEnvironment.isRunningAutomatedTests
        self.shouldSkipAppBootstrap = shouldSkipAppBootstrap
        Self.configureRevenueCatIfAvailable(skip: shouldSkipAppBootstrap)
        if let fixtureContext = CodexUITestHarness.makeIfEnabled(arguments: ProcessInfo.processInfo.arguments) {
            _codexService = State(initialValue: fixtureContext.service)
            _petCompanionStore = State(initialValue: PetCompanionStore())
            _petCompanionStatusStore = State(initialValue: PetCompanionStatusStore())
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
            _petCompanionStore = State(initialValue: PetCompanionStore())
            _petCompanionStatusStore = State(initialValue: PetCompanionStatusStore())
            _subscriptionService = State(initialValue: SubscriptionService())
            _uiTestFixture = State(initialValue: nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(codexService)
                .environment(petCompanionStore)
                .environment(petCompanionStatusStore)
                .environment(subscriptionService)
                .onOpenURL { url in
                    Task { @MainActor in
                        guard !routeRemodexDeepLink(url) else {
                            return
                        }
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
                    await subscriptionService.bootstrap()
                }
        }
    }

    @discardableResult
    private func routeRemodexDeepLink(_ url: URL) -> Bool {
        guard url.scheme?.caseInsensitiveCompare("phodex") == .orderedSame else {
            return false
        }

        let threadId = Self.remodexDeepLinkThreadID(from: url)

        let decodedThreadId = threadId?.removingPercentEncoding ?? threadId
        guard let normalizedThreadId = decodedThreadId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedThreadId.isEmpty else {
            return false
        }

        codexService.handleNotificationOpen(threadId: normalizedThreadId, turnId: nil)
        return true
    }

    private static func remodexDeepLinkThreadID(from url: URL) -> String? {
        let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathComponents = url.pathComponents
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let host, isThreadRouteComponent(host) {
            return pathComponents.first
        }
        if host?.isEmpty != false,
           let route = pathComponents.first,
           Self.isThreadRouteComponent(route) {
            return pathComponents.dropFirst().first
        }

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return queryItems.first { item in
            item.name.caseInsensitiveCompare("threadId") == .orderedSame
                || item.name.caseInsensitiveCompare("thread") == .orderedSame
        }?.value
    }

    private static func isThreadRouteComponent(_ value: String) -> Bool {
        value.caseInsensitiveCompare("thread") == .orderedSame
            || value.caseInsensitiveCompare("threads") == .orderedSame
    }

    // Configures RevenueCat once at launch using the client-safe public SDK key.
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
