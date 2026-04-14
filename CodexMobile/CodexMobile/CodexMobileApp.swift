// FILE: CodexMobileApp.swift
// Purpose: App entry point, RevenueCat setup, and root dependency wiring.
// Layer: App
// Exports: CodexMobileApp

import RevenueCat
import SwiftUI

@MainActor
@main
struct CodexMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(CodexMobileAppDelegate.self) private var appDelegate
    @State private var codexService: CodexService
    @State private var subscriptionService: SubscriptionService
    @State private var uiTestFixture: CodexUITestLaunchFixture?

    init() {
        Self.configureRevenueCatIfAvailable()
        if let fixtureContext = CodexUITestHarness.makeIfEnabled(arguments: ProcessInfo.processInfo.arguments) {
            _codexService = State(initialValue: fixtureContext.service)
            _subscriptionService = State(initialValue: fixtureContext.subscriptions)
            _uiTestFixture = State(initialValue: fixtureContext.fixture)
        } else {
            let service = CodexService()
            service.configureNotifications()
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
        } else {
            ContentView()
                .task {
                    await subscriptionService.bootstrap()
                }
        }
    }

    // Configures RevenueCat once at launch using the client-safe public SDK key.
    private static func configureRevenueCatIfAvailable() {
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
