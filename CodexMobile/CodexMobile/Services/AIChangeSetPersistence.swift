// FILE: AIChangeSetPersistence.swift
// Purpose: Persists assistant-scoped revertable change sets between app launches.
// Layer: Service
// Exports: AIChangeSetPersistence
// Depends on: Foundation, AIChangeSetModels

import Foundation

struct AIChangeSetPersistence {
    private let loadImpl: () -> [AIChangeSet]
    private let saveImpl: ([AIChangeSet]) -> Void

    private static let fileName = "codex-ai-change-sets-v1.json"

    init() {
        self.loadImpl = { Self.liveLoad() }
        self.saveImpl = { value in Self.liveSave(value) }
    }

    private init(
        load: @escaping () -> [AIChangeSet],
        save: @escaping ([AIChangeSet]) -> Void
    ) {
        self.loadImpl = load
        self.saveImpl = save
    }

    static var disabled: AIChangeSetPersistence {
        AIChangeSetPersistence(load: { [] }, save: { _ in })
    }

    // Loads the stored change-set ledger from disk. Returns an empty array on failure.
    func load() -> [AIChangeSet] {
        loadImpl()
    }

    // Persists the full change-set ledger atomically to keep revert metadata durable.
    func save(_ value: [AIChangeSet]) {
        saveImpl(value)
    }

    private static func liveLoad() -> [AIChangeSet] {
        let decoder = JSONDecoder()
        guard let data = try? Data(contentsOf: storeURL) else {
            return []
        }

        return (try? decoder.decode([AIChangeSet].self, from: data)) ?? []
    }

    // Persists the full change-set ledger atomically to keep revert metadata durable.
    private static func liveSave(_ value: [AIChangeSet]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value) else {
            return
        }

        ensureParentDirectoryExists(for: storeURL)
        try? data.write(to: storeURL, options: [.atomic])
    }

    private static var storeURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.codexmobile.app"
        return base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent(Self.fileName, isDirectory: false)
    }

    private static func ensureParentDirectoryExists(for fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
