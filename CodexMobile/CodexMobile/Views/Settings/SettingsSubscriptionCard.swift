// FILE: SettingsSubscriptionCard.swift
// Purpose: Presents Remodex Pro subscription status and purchase actions.
// Layer: Settings UI component
// Exports: SettingsSubscriptionCard
// Depends on: SwiftUI, StoreKit, SubscriptionService, RevenueCatPaywallView

import StoreKit
import SwiftUI

struct SettingsSubscriptionCard: View {
    @Environment(SubscriptionService.self) private var subscriptions
    let onShowPaywall: () -> Void
    let onRedeemCode: () -> Void

    private var subscriptionsDisabledForFork: Bool {
        !AppEnvironment.requiresProSubscription
    }

    var body: some View {
        SettingsCard(
            title: subscriptionsDisabledForFork ? "Fork Access" : "Remodex Pro",
            footer: subscriptionFooter
        ) {
            SettingsValueRow(
                title: subscriptionsDisabledForFork ? "Status" : "Plan",
                value: subscriptionsDisabledForFork ? "Unlocked" : (subscriptions.hasProAccess ? "Active" : "Free"),
                valueColor: (subscriptionsDisabledForFork || subscriptions.hasProAccess) ? .green : .secondary
            )

            if !subscriptionsDisabledForFork {
                SettingsButton(subscriptions.hasProAccess ? "View Pro Benefits" : "Upgrade to Pro") {
                    onShowPaywall()
                }

                SettingsButton("Redeem Code") {
                    onRedeemCode()
                }
                .disabled(subscriptions.isPurchasing || subscriptions.isRestoring)

                SettingsButton(
                    subscriptions.isRestoring ? "Restoring..." : "Restore Purchases",
                    isLoading: subscriptions.isRestoring
                ) {
                    Task {
                        await subscriptions.restorePurchases()
                    }
                }
                .disabled(subscriptions.isPurchasing)
            }

            if let error = subscriptions.lastErrorMessage, !error.isEmpty {
                SettingsInlineMessage(text: error, tint: .red)
            }
        }
        .task {
            guard subscriptions.bootstrapState == .idle else {
                return
            }
            await subscriptions.bootstrap()
        }
    }

    private var subscriptionFooter: String {
        if subscriptionsDisabledForFork {
            return "This fork is unlocked by default. Paywall and Pro restrictions are disabled for local-first installs."
        }
        return subscriptions.hasProAccess
            ? "Manage billing through your Apple ID subscription settings."
            : "Unlock voice mode, unlimited threads, and more."
    }
}
