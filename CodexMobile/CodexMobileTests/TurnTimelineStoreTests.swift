// FILE: TurnTimelineStoreTests.swift
// Purpose: Verifies TurnTimelineStore correctly manages per-thread timeline state lifecycle.
// Layer: Unit Test
// Exports: TurnTimelineStoreTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnTimelineStoreTests: XCTestCase {

    // MARK: - timelineState(for:)

    func testTimelineStateCreatesNewStateForUnknownThread() {
        let store = TurnTimelineStore()

        let state = store.timelineState(for: "thread-new")

        XCTAssertNotNil(state)
        XCTAssertEqual(store.stateByThread.count, 1)
        XCTAssertNotNil(store.stateByThread["thread-new"])
    }

    func testTimelineStateReturnsSameInstanceOnConsecutiveCalls() {
        let store = TurnTimelineStore()

        let first = store.timelineState(for: "thread-stable")
        let second = store.timelineState(for: "thread-stable")

        XCTAssertTrue(first === second)
        XCTAssertEqual(store.stateByThread.count, 1)
    }

    func testTimelineStateIsolatesDistinctThreads() {
        let store = TurnTimelineStore()

        let stateA = store.timelineState(for: "thread-a")
        let stateB = store.timelineState(for: "thread-b")

        XCTAssertFalse(stateA === stateB)
        XCTAssertEqual(store.stateByThread.count, 2)
    }

    func testTimelineStateDoesNotAddDuplicateEntries() {
        let store = TurnTimelineStore()

        for _ in 0..<5 {
            _ = store.timelineState(for: "thread-repeat")
        }

        XCTAssertEqual(store.stateByThread.count, 1)
    }

    // MARK: - removeTimelineState(for:)

    func testRemoveTimelineStateClearsAllCachesForThread() {
        let store = TurnTimelineStore()
        let threadID = "thread-remove"

        // Populate all per-thread collections.
        _ = store.timelineState(for: threadID)
        store.stoppedTurnIDsByThread[threadID] = ["turn-1", "turn-2"]
        store.messageIndexCacheByThread[threadID] = ["msg-a": 0, "msg-b": 1]
        store.latestAssistantOutputByThread[threadID] = "last output"
        store.latestRepoAffectingMessageSignalByThread[threadID] = "signal"
        store.assistantRevertStateCacheByThread[threadID] = AssistantRevertStateCacheEntry(
            revertStateRevision: 1,
            statesByMessageID: [:]
        )

        store.removeTimelineState(for: threadID)

        XCTAssertNil(store.stateByThread[threadID])
        XCTAssertNil(store.stoppedTurnIDsByThread[threadID])
        XCTAssertNil(store.messageIndexCacheByThread[threadID])
        XCTAssertNil(store.latestAssistantOutputByThread[threadID])
        XCTAssertNil(store.latestRepoAffectingMessageSignalByThread[threadID])
        XCTAssertNil(store.assistantRevertStateCacheByThread[threadID])
    }

    func testRemoveTimelineStateDoesNotAffectOtherThreads() {
        let store = TurnTimelineStore()

        _ = store.timelineState(for: "thread-keep")
        store.stoppedTurnIDsByThread["thread-keep"] = ["turn-keep"]
        _ = store.timelineState(for: "thread-remove")
        store.stoppedTurnIDsByThread["thread-remove"] = ["turn-remove"]

        store.removeTimelineState(for: "thread-remove")

        XCTAssertNotNil(store.stateByThread["thread-keep"])
        XCTAssertEqual(store.stoppedTurnIDsByThread["thread-keep"], ["turn-keep"])
        XCTAssertNil(store.stateByThread["thread-remove"])
        XCTAssertNil(store.stoppedTurnIDsByThread["thread-remove"])
    }

    func testRemoveTimelineStateOnUnknownThreadIsIdempotent() {
        let store = TurnTimelineStore()
        _ = store.timelineState(for: "thread-existing")

        // Should not crash or affect unrelated state.
        store.removeTimelineState(for: "thread-nonexistent")

        XCTAssertEqual(store.stateByThread.count, 1)
    }

    // MARK: - removeAllTimelineState()

    func testRemoveAllTimelineStateClearsEveryCollection() {
        let store = TurnTimelineStore()

        for i in 0..<3 {
            let id = "thread-\(i)"
            _ = store.timelineState(for: id)
            store.stoppedTurnIDsByThread[id] = ["turn-\(i)"]
            store.messageIndexCacheByThread[id] = ["msg-\(i)": i]
            store.latestAssistantOutputByThread[id] = "output-\(i)"
            store.latestRepoAffectingMessageSignalByThread[id] = "signal-\(i)"
            store.assistantRevertStateCacheByThread[id] = AssistantRevertStateCacheEntry(
                revertStateRevision: i,
                statesByMessageID: [:]
            )
        }

        store.removeAllTimelineState()

        XCTAssertTrue(store.stateByThread.isEmpty)
        XCTAssertTrue(store.stoppedTurnIDsByThread.isEmpty)
        XCTAssertTrue(store.messageIndexCacheByThread.isEmpty)
        XCTAssertTrue(store.latestAssistantOutputByThread.isEmpty)
        XCTAssertTrue(store.latestRepoAffectingMessageSignalByThread.isEmpty)
        XCTAssertTrue(store.assistantRevertStateCacheByThread.isEmpty)
    }

    func testRemoveAllTimelineStateOnEmptyStoreIsIdempotent() {
        let store = TurnTimelineStore()

        // Should not crash when store is already empty.
        store.removeAllTimelineState()
        store.removeAllTimelineState()

        XCTAssertTrue(store.stateByThread.isEmpty)
    }

    func testRemoveAllTimelineStateDoesNotResetScalarProperties() {
        let store = TurnTimelineStore()
        store.assistantRevertStateRevision = 42
        store.busyRepoRootsRevision = 7
        store.busyRepoRoots = ["/repo/root"]

        store.removeAllTimelineState()

        // Scalar counters and busyRepoRoots are NOT part of removeAllTimelineState.
        XCTAssertEqual(store.assistantRevertStateRevision, 42)
        XCTAssertEqual(store.busyRepoRootsRevision, 7)
        XCTAssertEqual(store.busyRepoRoots, ["/repo/root"])
    }

    // MARK: - State after re-add

    func testTimelineStateCanBeReadAfterBeingRemoved() {
        let store = TurnTimelineStore()
        let threadID = "thread-readd"

        let original = store.timelineState(for: threadID)
        store.removeTimelineState(for: threadID)
        let recreated = store.timelineState(for: threadID)

        // After removal a fresh state is created; it is a different instance.
        XCTAssertFalse(original === recreated)
        XCTAssertNotNil(store.stateByThread[threadID])
    }

    // MARK: - Direct property mutations

    func testStoppedTurnIDsByThreadAccumulatesAcrossMultipleWrites() {
        let store = TurnTimelineStore()
        store.stoppedTurnIDsByThread["thread-x"] = ["turn-1"]
        store.stoppedTurnIDsByThread["thread-x"]?.insert("turn-2")

        XCTAssertEqual(store.stoppedTurnIDsByThread["thread-x"], ["turn-1", "turn-2"])
    }

    func testMessageIndexCacheByThreadStoresCorrectMappings() {
        let store = TurnTimelineStore()
        store.messageIndexCacheByThread["thread-y"] = ["msg-0": 0, "msg-1": 1, "msg-2": 2]

        XCTAssertEqual(store.messageIndexCacheByThread["thread-y"]?["msg-1"], 1)
        XCTAssertNil(store.messageIndexCacheByThread["thread-y"]?["msg-99"])
    }
}