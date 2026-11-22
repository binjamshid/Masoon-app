import Foundation
import XCTest

@testable import MasoonDomain
@testable import MasoonWatchShared

/// The wrist's durable stores (D-199).
///
/// These run on macOS as well as watchOS — `MasoonWatchShared` is Foundation +
/// `MasoonDomain`, so the suite executes on a development Mac like every other
/// package test, rather than needing a paired watch simulator.
final class WatchStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var queueURL: URL { directory.appendingPathComponent("queue.json") }
    private var snapshotURL: URL { directory.appendingPathComponent("snapshot.json") }

    private func record(
        id: String, taskUid: String = "task-1", dateISO: String = "2026-07-12", seq: Int64 = 0
    ) -> WatchPendingEvent {
        WatchPendingEvent(
            eventId: id,
            planId: "plan-1",
            accountScope: "scope-1",
            planGeneration: 3,
            type: "task.completed",
            occurredAtLocal: "2026-07-12T06:30:00+03:00",
            dateISO: dateISO,
            taskUid: taskUid,
            evidence: .selfCheck(),
            watchSeq: seq)
    }

    // MARK: - Queue

    func testAppendIsFIFOAndSurvivesReopen() async throws {
        let queue = WatchQueueStore(fileURL: queueURL)
        for i in 1...3 {
            _ = try await queue.append { seq in
                self.record(id: "e\(i)", taskUid: "task-\(i)", seq: seq)
            }
        }
        // A fresh store over the same file — the wrist app having been killed.
        let reopened = WatchQueueStore(fileURL: queueURL)
        let pending = await reopened.pending()
        XCTAssertEqual(pending.map(\.eventId), ["e1", "e2", "e3"])
        XCTAssertEqual(pending.map(\.watchSeq), [0, 1, 2])
    }

    /// A double-tap on a small screen must not become two completions the phone
    /// has to reconcile.
    func testDuplicateTaskAndDateIsNotQueuedTwice() async throws {
        let queue = WatchQueueStore(fileURL: queueURL)
        let first = try await queue.append { seq in self.record(id: "e1", seq: seq) }
        let second = try await queue.append { seq in self.record(id: "e2", seq: seq) }
        XCTAssertNotNil(first)
        XCTAssertNil(second, "same (task_uid, date) must not queue twice")
        let count = await queue.count()
        XCTAssertEqual(count, 1)
    }

    /// The same task on a different date is a different instance.
    func testSameTaskDifferentDateIsQueued() async throws {
        let queue = WatchQueueStore(fileURL: queueURL)
        _ = try await queue.append { seq in self.record(id: "e1", dateISO: "2026-07-12", seq: seq) }
        _ = try await queue.append { seq in self.record(id: "e2", dateISO: "2026-07-13", seq: seq) }
        let count = await queue.count()
        XCTAssertEqual(count, 2)
    }

    func testAcknowledgeRemovesExactlyTheAckedIds() async throws {
        let queue = WatchQueueStore(fileURL: queueURL)
        for i in 1...4 {
            _ = try await queue.append { seq in
                self.record(id: "e\(i)", taskUid: "task-\(i)", seq: seq)
            }
        }
        try await queue.acknowledge(eventIds: ["e2", "e4", "not-queued"])
        let remaining = await queue.pending()
        XCTAssertEqual(remaining.map(\.eventId), ["e1", "e3"])
    }

    func testAcknowledgeIsPersisted() async throws {
        let queue = WatchQueueStore(fileURL: queueURL)
        _ = try await queue.append { seq in self.record(id: "e1", taskUid: "a", seq: seq) }
        _ = try await queue.append { seq in self.record(id: "e2", taskUid: "b", seq: seq) }
        try await queue.acknowledge(eventIds: ["e1"])

        let reopened = WatchQueueStore(fileURL: queueURL)
        let remaining = await reopened.pending()
        XCTAssertEqual(remaining.map(\.eventId), ["e2"])
    }

    func testCapacityEvictsOldestFirst() async throws {
        let queue = WatchQueueStore(fileURL: queueURL, capacity: 3)
        for i in 1...5 {
            _ = try await queue.append { seq in
                self.record(id: "e\(i)", taskUid: "task-\(i)", seq: seq)
            }
        }
        let pending = await queue.pending()
        XCTAssertEqual(pending.map(\.eventId), ["e3", "e4", "e5"])
    }

    func testPendingCompletionDrivesTheOverlay() async throws {
        let queue = WatchQueueStore(fileURL: queueURL)
        _ = try await queue.append { seq in
            self.record(id: "e1", taskUid: "task-9", dateISO: "2026-07-12", seq: seq)
        }
        var hit = await queue.hasPendingCompletion(taskUid: "task-9", dateISO: "2026-07-12")
        XCTAssertTrue(hit)
        hit = await queue.hasPendingCompletion(taskUid: "task-9", dateISO: "2026-07-13")
        XCTAssertFalse(hit, "the overlay is per task INSTANCE, not per task")
        hit = await queue.hasPendingCompletion(taskUid: "other", dateISO: "2026-07-12")
        XCTAssertFalse(hit)
    }

    /// A truncated file (killed mid-write on a filesystem without the atomic
    /// rename, or corrupted) must not crash the wrist or wedge it into a state
    /// where it can never queue again.
    func testTruncatedQueueFileDegradesToEmpty() async throws {
        try Data("[{\"eventId\":\"e1\",\"pla".utf8).write(to: queueURL)
        let queue = WatchQueueStore(fileURL: queueURL)
        let pending = await queue.pending()
        XCTAssertEqual(pending.count, 0)

        // And it still works afterwards.
        _ = try await queue.append { seq in self.record(id: "e-new", seq: seq) }
        let after = await queue.pending()
        XCTAssertEqual(after.map(\.eventId), ["e-new"])
    }

    func testWipeClearsEverything() async throws {
        let queue = WatchQueueStore(fileURL: queueURL)
        _ = try await queue.append { seq in self.record(id: "e1", seq: seq) }
        try await queue.wipe()
        let count = await queue.count()
        XCTAssertEqual(count, 0)

        let reopened = WatchQueueStore(fileURL: queueURL)
        let persisted = await reopened.count()
        XCTAssertEqual(persisted, 0)
    }

    // MARK: - Snapshot store

    func testSnapshotRoundTrips() async throws {
        let store = WatchSnapshotStore(fileURL: snapshotURL)
        let snapshot = makeSnapshot(generatedAt: 1000)
        _ = try await store.store(snapshot)

        let reopened = WatchSnapshotStore(fileURL: snapshotURL)
        let loaded = await reopened.current()
        XCTAssertEqual(loaded, snapshot)
    }

    func testOlderSnapshotIsRejected() async throws {
        let store = WatchSnapshotStore(fileURL: snapshotURL)
        _ = try await store.store(makeSnapshot(generatedAt: 2000))
        let accepted = try await store.store(makeSnapshot(generatedAt: 1000))
        XCTAssertFalse(accepted, "an older snapshot must not replace a newer one")
        let current = await store.current()
        XCTAssertEqual(current?.generatedAtUnixMillis, 2000)
    }

    func testNewerSnapshotReplaces() async throws {
        let store = WatchSnapshotStore(fileURL: snapshotURL)
        _ = try await store.store(makeSnapshot(generatedAt: 1000))
        let accepted = try await store.store(makeSnapshot(generatedAt: 3000))
        XCTAssertTrue(accepted)
        let current = await store.current()
        XCTAssertEqual(current?.generatedAtUnixMillis, 3000)
    }

    /// A snapshot for a *different* plan always wins regardless of timestamp —
    /// the learner switched plans, and the old plan's recency is irrelevant.
    func testDifferentPlanAlwaysReplaces() async throws {
        let store = WatchSnapshotStore(fileURL: snapshotURL)
        _ = try await store.store(makeSnapshot(generatedAt: 5000))
        var other = makeSnapshot(generatedAt: 1000)
        other.planId = "plan-2"
        let accepted = try await store.store(other)
        XCTAssertTrue(accepted)
    }

    // MARK: - Forward compatibility

    /// A newer phone build adds fields; an older watch build must still decode.
    /// This is the real-world case — the two ship independently through the App
    /// Store and a user can update one without the other for weeks.
    func testUnknownKeysStillDecode() throws {
        let json = """
            {
              "schemaVersion": 99,
              "planId": "plan-1",
              "planTimezone": "Asia/Riyadh",
              "accountScope": "scope-1",
              "planGeneration": 4,
              "locale": "ar",
              "generatedAtUnixMillis": 1234,
              "validThroughISO": "2026-07-13",
              "days": [],
              "ackedEventIds": [],
              "wipe": false,
              "somethingTheWatchHasNeverHeardOf": {"nested": [1, 2, 3]},
              "anotherNewField": "hello"
            }
            """
        let decoded = try JSONDecoder().decode(WatchDaySnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.planId, "plan-1")
        XCTAssertEqual(decoded.schemaVersion, 99)
        XCTAssertEqual(decoded.planGeneration, 4)
    }

    /// Missing optional fields decode to defaults rather than throwing, so one
    /// added field on the phone never bricks the wrist.
    func testMissingFieldsDecodeToDefaults() throws {
        let decoded = try JSONDecoder().decode(
            WatchDaySnapshot.self, from: Data(#"{"planId":"plan-1"}"#.utf8))
        XCTAssertEqual(decoded.planId, "plan-1")
        XCTAssertEqual(decoded.planTimezone, "UTC")
        XCTAssertTrue(decoded.days.isEmpty)
        XCTAssertFalse(decoded.wipe)
    }

    /// An evidence kind the watch build predates is read-only, not fatal.
    func testUnknownEvidenceKindIsUnsupported() throws {
        let decoded = try JSONDecoder().decode(
            WatchEvidenceKind.self, from: Data(#"{"kind":"retina_scan"}"#.utf8))
        XCTAssertEqual(decoded, .unsupported)
        let row = WatchTaskRow(
            taskUid: "t", title: "T", statusRaw: "pending", evidence: decoded)
        XCTAssertFalse(row.isCompletableOnWrist)
    }

    /// Evidence the wrist cannot run must never be completable there — silently
    /// downgrading teacher verification to a tap would forge assessment.
    func testTeacherAndFormEvidenceAreNotCompletableOnWrist() {
        for kind in [WatchEvidenceKind.teacherVerification, .form, .unsupported] {
            let row = WatchTaskRow(taskUid: "t", title: "T", statusRaw: "pending", evidence: kind)
            XCTAssertFalse(row.isCompletableOnWrist, "\(kind) must stay read-only on the wrist")
        }
        for kind in [WatchEvidenceKind.selfCheck, .counter(target: 5), .timer(minSeconds: 60)] {
            let row = WatchTaskRow(taskUid: "t", title: "T", statusRaw: "pending", evidence: kind)
            XCTAssertTrue(row.isCompletableOnWrist)
        }
    }

    /// `composite` is deliberately not reduced: a learner must not satisfy a
    /// two-part requirement with one tap.
    func testCompositeSpecFlattensToUnsupported() {
        let spec = EvidenceSpec.composite([.selfCheck, .counter(target: 5)])
        XCTAssertEqual(WatchEvidenceKind(spec: spec), .unsupported)
    }

    func testUnknownStatusDecodesToPending() {
        let row = WatchTaskRow(
            taskUid: "t", title: "T", statusRaw: "some_future_status", evidence: .selfCheck)
        XCTAssertEqual(row.status, .pending)
    }

    // MARK: - Freshness

    func testStaleSnapshotIsNotFresh() {
        let snapshot = makeSnapshot(generatedAt: 1000, validThrough: "2026-07-13")
        XCTAssertTrue(snapshot.isFresh(onPlanLocalDate: LocalDate(iso: "2026-07-12")!))
        XCTAssertTrue(snapshot.isFresh(onPlanLocalDate: LocalDate(iso: "2026-07-13")!))
        XCTAssertFalse(
            snapshot.isFresh(onPlanLocalDate: LocalDate(iso: "2026-07-14")!),
            "past validThrough the wrist must say 'reconnect', not present a stale day")
    }

    /// Fail closed: an unparseable validity window is treated as stale rather
    /// than as valid forever.
    func testUnparseableValidThroughIsStale() {
        let snapshot = makeSnapshot(generatedAt: 1000, validThrough: "")
        XCTAssertFalse(snapshot.isFresh(onPlanLocalDate: LocalDate(iso: "2026-07-12")!))
    }

    // MARK: - Helpers

    private func makeSnapshot(generatedAt: Int64, validThrough: String = "2026-07-13") -> WatchDaySnapshot {
        WatchDaySnapshot(
            planId: "plan-1",
            planTimezone: "Asia/Riyadh",
            accountScope: "scope-1",
            planGeneration: 3,
            locale: "ar",
            generatedAtUnixMillis: generatedAt,
            validThroughISO: validThrough,
            days: [
                WatchDay(
                    dateISO: "2026-07-12",
                    rows: [
                        WatchTaskRow(
                            taskUid: "task-1", title: "حفظ جديد", detail: "الوحدات ١–٥",
                            statusRaw: "pending", evidence: .counter(target: 5),
                            targetRepetitions: 5, spacingMinutes: 15, sessionId: "morning")
                    ])
            ])
    }
}
