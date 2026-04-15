// FILE: CodexMessagePersistence.swift
// Purpose: Persists per-thread message timelines to disk between app launches.
// Layer: Service
// Exports: CodexMessagePersistence
// Depends on: Foundation, CryptoKit, CodexMessage

import CryptoKit
import Foundation

struct CodexMessagePersistence {
    nonisolated(unsafe) private let loadImpl: () -> [String: [CodexMessage]]
    nonisolated(unsafe) private let saveImpl: ([String: [CodexMessage]]) -> Void

    // v6 encrypts the on-device message cache while keeping backward-compatible legacy fallbacks.
    private static let fileName = "codex-message-history-v6.bin"
    private static let legacyFileNames = [
        "codex-message-history-v5.json",
        "codex-message-history-v4.json",
        "codex-message-history-v3.json",
        "codex-message-history-v2.json",
        "codex-message-history.json",
    ]

    init() {
        self.loadImpl = { Self.liveLoad() }
        self.saveImpl = { value in Self.liveSave(value) }
    }

    private init(
        load: @escaping () -> [String: [CodexMessage]],
        save: @escaping ([String: [CodexMessage]]) -> Void
    ) {
        self.loadImpl = load
        self.saveImpl = save
    }

    static var disabled: CodexMessagePersistence {
        CodexMessagePersistence(load: { [:] }, save: { _ in })
    }

    // Loads the saved message map from disk. Returns an empty store on failure.
    nonisolated func load() -> [String: [CodexMessage]] {
        loadImpl()
    }

    // Persists all thread timelines atomically to avoid corrupt partial writes.
    nonisolated func save(_ value: [String: [CodexMessage]]) {
        saveImpl(value)
    }

    private nonisolated static func liveLoad() -> [String: [CodexMessage]] {
        let decoder = JSONDecoder()

        for fileURL in storeURLs {
            guard let data = try? Data(contentsOf: fileURL) else {
                continue
            }

            if fileURL.lastPathComponent == Self.fileName,
               let decrypted = Self.decryptPersistedPayload(data),
               let value = try? decoder.decode([String: [CodexMessage]].self, from: decrypted) {
                return Self.sanitizedForPersistence(value)
            }

            if let value = try? decoder.decode([String: [CodexMessage]].self, from: data) {
                return Self.sanitizedForPersistence(value)
            }
        }

        return [:]
    }

    // Persists all thread timelines atomically to avoid corrupt partial writes.
    private nonisolated static func liveSave(_ value: [String: [CodexMessage]]) {
        let encoder = JSONEncoder()
        guard let plaintext = try? encoder.encode(sanitizedForPersistence(value)),
              let data = encryptPersistedPayload(plaintext) else {
            return
        }

        let fileURL = Self.storeURL
        Self.ensureParentDirectoryExists(for: fileURL)
        try? data.write(to: fileURL, options: [.atomic])
    }

    private nonisolated static var storeURL: URL {
        Self.storeURLs[0]
    }

    private nonisolated static var storeURLs: [URL] {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.codexmobile.app"
        let directory = base.appendingPathComponent(bundleID, isDirectory: true)
        let names = [Self.fileName] + Self.legacyFileNames
        return names.map { directory.appendingPathComponent($0, isDirectory: false) }
    }

    private nonisolated static func ensureParentDirectoryExists(for fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // Uses a Keychain-backed AES key so chat history remains private if the app data is copied out.
    private nonisolated static func encryptPersistedPayload(_ plaintext: Data) -> Data? {
        let key = messageHistoryKey()
        let sealedBox = try? AES.GCM.seal(plaintext, using: key)
        return sealedBox?.combined
    }

    // Opens the encrypted chat cache while still allowing plaintext fallbacks from older app versions.
    private nonisolated static func decryptPersistedPayload(_ encryptedData: Data) -> Data? {
        let key = messageHistoryKey()
        guard let sealedBox = try? AES.GCM.SealedBox(combined: encryptedData) else {
            return nil
        }
        return try? AES.GCM.open(sealedBox, using: key)
    }

    private nonisolated static func messageHistoryKey() -> SymmetricKey {
        if let storedKey = SecureStore.readData(for: CodexSecureKeys.messageHistoryKey) {
            return SymmetricKey(data: storedKey)
        }

        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        SecureStore.writeData(keyData, for: CodexSecureKeys.messageHistoryKey)
        return newKey
    }

    // Keep pending structured prompts on disk so reconnects and relaunches can still surface
    // a request the server is waiting on; lifecycle cleanup removes them once the request resolves.
    private nonisolated static func sanitizedForPersistence(_ value: [String: [CodexMessage]]) -> [String: [CodexMessage]] {
        value.mapValues { messages in
            messages.map { message in
                guard !message.attachments.isEmpty else {
                    return message
                }

                var sanitizedMessage = message
                let shouldPreservePayloadDataURL = message.deliveryState == .pending
                sanitizedMessage.attachments = message.attachments.map {
                    $0.sanitizedForStorage(preservingPayloadDataURL: shouldPreservePayloadDataURL)
                }
                return sanitizedMessage
            }
        }
    }
}
