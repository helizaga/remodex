// FILE: OnboardingView.swift
// Purpose: Split onboarding flow that keeps the fork's local-first setup steps explicit.
// Layer: View
// Exports: OnboardingView
// Depends on: SwiftUI, OnboardingWelcomePage, OnboardingFeaturesPage, OnboardingStepPage

import SwiftUI

struct OnboardingView: View {
    let onScanQRCode: () -> Void
    let onPairWithCode: () -> Void
    @State private var currentPage = 0
    @State private var isShowingCodexInstallReminder = false

    private let pageCount = 5
    private let codexInstallStepIndex = 2
    private let codexInstallCommand = "npm install -g @openai/codex@latest"
    private let localBridgeCommand = "./run-local-remodex.sh up"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    OnboardingWelcomePage()
                        .tag(0)

                    OnboardingFeaturesPage()
                        .tag(1)

                    OnboardingStepPage(
                        stepNumber: 1,
                        icon: "terminal",
                        title: "Install Codex CLI",
                        description: "Install Codex on your Mac first. Remodex connects to that local runtime from your iPhone.",
                        command: codexInstallCommand
                    )
                    .tag(2)

                    OnboardingStepPage(
                        stepNumber: 2,
                        icon: "link",
                        title: "Start the Local Bridge",
                        description: "From this fork's repo root on your Mac, run the local-first launcher so the bridge and relay come up together.",
                        command: localBridgeCommand,
                        commandCaption: "Remodex uses macOS caffeinate by default while the bridge is running so your Mac stays reachable even if the display turns off. You can change this later in Settings."
                    )
                    .tag(3)

                    OnboardingStepPage(
                        stepNumber: 3,
                        icon: "qrcode.viewfinder",
                        title: "Scan the Pairing QR",
                        description: "Open Remodex on your iPhone and scan the QR from inside the app. Do not use the generic Camera app for pairing."
                    )
                    .tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomBar
            }
        }
        .preferredColorScheme(.dark)
        .alert("Install Codex CLI First", isPresented: $isShowingCodexInstallReminder) {
            Button("Stay Here", role: .cancel) {}
            Button("Continue Anyway") {
                advanceToNextPage()
            }
        } message: {
            Text("Copy and paste \"\(codexInstallCommand)\" on your computer before moving on. Remodex will not work until Codex CLI is installed and available in your PATH.")
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 20) {
            HStack(spacing: 8) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == currentPage ? Color.white : Color.white.opacity(0.18))
                        .frame(width: index == currentPage ? 24 : 8, height: 8)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: currentPage)

            finalPageActions

            OpenSourceBadge(style: .light)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.6), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 50)
            .offset(y: -50),
            alignment: .top
        )
    }

    // MARK: - State

    @ViewBuilder
    private var finalPageActions: some View {
        if currentPage == pageCount - 1 {
            VStack(spacing: 10) {
                PrimaryCapsuleButton(
                    title: "Scan with QR Code",
                    systemImage: "qrcode",
                    action: handleContinue
                )

                secondaryCapsuleButton(
                    title: "Pair with Code",
                    systemImage: "keyboard",
                    action: onPairWithCode
                )
            }
        } else {
            PrimaryCapsuleButton(
                title: buttonTitle,
                action: handleContinue
            )
        }
    }

    // Offers the first-run manual pairing path without competing visually with the primary QR flow.
    private func secondaryCapsuleButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RemodexIcon.image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))

                Text(title)
                    .font(AppFont.body(weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.1))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var buttonTitle: String {
        switch currentPage {
        case 0: return "Get Started"
        case 1: return "Set Up"
        default: return "Continue"
        }
    }

    private func handleContinue() {
        if currentPage == codexInstallStepIndex {
            isShowingCodexInstallReminder = true
            return
        }

        if currentPage < pageCount - 1 {
            advanceToNextPage()
        } else {
            onScanQRCode()
        }
    }

    private func advanceToNextPage() {
        withAnimation(.easeInOut(duration: 0.3)) {
            currentPage += 1
        }
    }
}

#Preview("Full Flow") {
    OnboardingView(
        onScanQRCode: {
            print("Scan tapped")
        },
        onPairWithCode: {
            print("Code tapped")
        }
    )
}

#Preview("Light Override") {
    OnboardingView(
        onScanQRCode: {
            print("Scan tapped")
        },
        onPairWithCode: {
            print("Code tapped")
        }
    )
    .preferredColorScheme(.light)
}
