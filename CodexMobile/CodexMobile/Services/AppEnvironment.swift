// FILE: AppEnvironment.swift
// Purpose: Centralizes local runtime endpoint configuration for app fallbacks.
// Layer: Service
// Exports: AppEnvironment
// Depends on: Foundation

import Foundation

enum AppEnvironment {
    private static let defaultRelayURLInfoPlistKeys = [
        "PHODEX_DEFAULT_RELAY_URL",
        "PHODEX_DEFAULT_WS_URL",
    ]

    // Open-source builds should provide an explicit relay instead of silently
    // pointing at a hosted service the user does not control.
    static let defaultRelayURLString = ""

    static var relayBaseURL: String {
        for key in defaultRelayURLInfoPlistKeys {
            if let infoURL = resolvedString(forInfoPlistKey: key) {
                return normalizedRelayURLString(infoURL)
            }
        }
        return defaultRelayURLString
    }
}

private extension AppEnvironment {
    static func resolvedString(forInfoPlistKey key: String) -> String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return nil
        }

        if trimmedValue.hasPrefix("$("), trimmedValue.hasSuffix(")") {
            return nil
        }

        return trimmedValue
    }

    static func normalizedRelayURLString(_ rawValue: String) -> String {
        if rawValue.hasSuffix("/ws") {
            return "\(rawValue.dropLast(3))/relay"
        }

        return rawValue
    }
}
