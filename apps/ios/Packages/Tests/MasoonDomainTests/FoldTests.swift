import XCTest
@testable import MasoonDomain

final class FoldTests: XCTestCase {
    private func event(
        id: String,
        type: String,
        serverSeq: Int64?,
        device: String = "d-1",
        clientSeq: Int64,
        superseded: String? = nil,
        payloadJSON: String = "{}"
    ) -> PlanEvent {
        PlanEvent(
            eventId: id,
            type: type,
            serverSeq: serverSeq,
            deviceId: device,
            clientSeq: clientSeq,
            occurredAtLocal: "2026-07-12T06:40:00+03:00",
            supersededBy: superseded,
            payload: try! JSONParser.parse(payloadJSON))
    }

    private func sampleEvents() -> [PlanEvent] {
        [
            event(id: "e1", type: PlanEventType.taskCompleted, serverSeq: 1, clientSeq: 1,
                  payloadJSON: #"{"task_uid":"uid-a","evidence":{"kind":"counter","count":5}}"#),
            event(id: "e2", type: PlanEventType.taskCompleted, serverSeq: 2, clientSeq: 2,
                  payloadJSON: #"{"task_uid":"uid-b"}"#),
            event(id: "e3", type: PlanEventType.taskUncompleted, serverSeq: 3, clientSeq: 3,
                  payloadJSON: #"{"task_uid":"uid-b","reason":"mistake"}"#),
            event(id: "e4", type: PlanEventType.planPolicyChanged, serverSeq: 4, clientSeq: 4,
                  payloadJSON: #"{"patch":{"takrar_count":7},"effective_from":"2026-07-20"}"#),
            event(id: "e5", type: PlanEventType.taskCompleted, serverSeq: 5, clientSeq: 5,
                  superseded: "e9", payloadJSON: #"{"task_uid":"uid-c"}"#),
            event(id: "e6", type: PlanEventType.taskExcused, serverSeq: 6, clientSeq: 6,
                  payloadJSON: #"{"task_uid":"uid-d","by":"teacher","reason":"illness"}"#),
            // Local-unacked events on two devices.
            event(id: "e7", type: PlanEventType.taskCompleted, serverSeq: nil, device: "d-2", clientSeq: 1,
                  payloadJSON: #"{"task_uid":"uid-e"}"#),
            event(id: "e8", type: PlanEventType.taskUncompleted, serverSeq: nil, device: "d-2", clientSeq: 2,
                  payloadJSON: #"{"task_uid":"uid-e"}"#),
            event(id: "e9", type: PlanEventType.taskCompleted, serverSeq: nil, device: "d-1", clientSeq: 7,
                  payloadJSON: #"{"task_uid":"uid-f"}"#),
        ]
    }

    func testFoldSemantics() {
        let folded = EventFold.fold(sampleEvents())
        XCTAssertNotNil(folded.completions["uid-a"])
        XCTAssertNil(folded.completions["uid-b"])       // uncompleted removed it
        XCTAssertNil(folded.completions["uid-c"])       // superseded folds as no-op
        XCTAssertTrue(folded.excused.contains("uid-d"))
        XCTAssertNil(folded.completions["uid-e"])       // completed then uncompleted, per (device, client_seq) order
        XCTAssertNotNil(folded.completions["uid-f"])
        XCTAssertEqual(folded.policyTimeline.count, 1)
        XCTAssertEqual(folded.policyTimeline[0].effectiveFrom, LocalDate(iso: "2026-07-20"))
    }

    func testFoldIsOrderInvariantUnderInputShuffle() {
        let events = sampleEvents()
        let reference = EventFold.fold(events)
        // Deterministic pseudo-shuffles: rotate + stride permutations.
        var permutations: [[PlanEvent]] = [events.reversed()]
        for rotation in 1..<events.count {
            permutations.append(Array(events[rotation...] + events[..<rotation]))
        }
        var strided: [PlanEvent] = []
        for i in stride(from: 0, to: events.count, by: 2) { strided.append(events[i]) }
        for i in stride(from: 1, to: events.count, by: 2) { strided.append(events[i]) }
        permutations.append(strided)

        for permutation in permutations {
            XCTAssertEqual(EventFold.fold(permutation), reference,
                           "fold must be invariant to input array order (server_seq total order)")
        }
    }

    func testPauseSpans() {
        let events = [
            event(id: "p1", type: PlanEventType.planPaused, serverSeq: 1, clientSeq: 1,
                  payloadJSON: #"{"effective_from":"2026-07-20"}"#),
            event(id: "p2", type: PlanEventType.planResumed, serverSeq: 2, clientSeq: 2,
                  payloadJSON: #"{"anchor":"2026-07-25"}"#),
        ]
        let folded = EventFold.fold(events)
        XCTAssertEqual(folded.pauseSpans.count, 1)
        XCTAssertTrue(folded.isPaused(on: LocalDate(iso: "2026-07-20")!))
        XCTAssertTrue(folded.isPaused(on: LocalDate(iso: "2026-07-24")!))
        XCTAssertFalse(folded.isPaused(on: LocalDate(iso: "2026-07-25")!))  // anchor resumes
        XCTAssertFalse(folded.isPaused(on: LocalDate(iso: "2026-07-19")!))
    }

    func testD032TaskDateKeying() {
        // task.* events key on payload.date, falling back to the local-date
        // part of occurred_at_local (D-032; ENGINE_SEMANTICS §9).
        let withDate = event(id: "d1", type: PlanEventType.taskCompleted, serverSeq: 1, clientSeq: 1,
                             payloadJSON: #"{"task_uid":"uid-x","date":"2026-07-10"}"#)
        let withoutDate = event(id: "d2", type: PlanEventType.taskCompleted, serverSeq: 2, clientSeq: 2,
                                payloadJSON: #"{"task_uid":"uid-y"}"#)
        let folded = EventFold.fold([withDate, withoutDate])
        XCTAssertEqual(folded.completions["uid-x"]?.date, LocalDate(iso: "2026-07-10"),
                       "payload.date wins over occurred_at_local (D-021 backdating)")
        XCTAssertEqual(folded.completions["uid-y"]?.date, LocalDate(iso: "2026-07-12"),
                       "legacy events fall back to occurred_at_local's date part")
    }

    func testD032OverrideWithoutEffectiveFromAppliesFromPlanStart() {
        // D-032(5): override.applied without effective_from is effective from
        // the beginning of the plan; supervisor authority never silently narrowed.
        let override = event(id: "o1", type: PlanEventType.overrideApplied, serverSeq: 1, clientSeq: 1,
                             payloadJSON: #"{"patch":{"takrar_count":3},"reason":"org policy"}"#)
        let folded = EventFold.fold([override])
        XCTAssertEqual(folded.policyTimeline.count, 1)
        XCTAssertNil(folded.policyTimeline[0].effectiveFrom)
        XCTAssertTrue(folded.policyTimeline[0].isEffective(on: LocalDate(iso: "1970-01-01")!))
        // plan.policy_changed without effective_from is dropped (malformed).
        let malformed = event(id: "o2", type: PlanEventType.planPolicyChanged, serverSeq: 1, clientSeq: 1,
                              payloadJSON: #"{"patch":{"takrar_count":3}}"#)
        XCTAssertTrue(EventFold.fold([malformed]).policyTimeline.isEmpty)
    }

    func testTaskStatusDerivation() {
        let folded = EventFold.fold(sampleEvents())
        let today = LocalDate(iso: "2026-07-15")!
        let past = LocalDate(iso: "2026-07-13")!
        XCTAssertEqual(TaskStatusDerivation.status(taskUid: "uid-a", date: past, today: today, folded: folded), .completed)
        XCTAssertEqual(TaskStatusDerivation.status(taskUid: "uid-d", date: past, today: today, folded: folded), .excused)
        XCTAssertEqual(TaskStatusDerivation.status(taskUid: "uid-zzz", date: past, today: today, folded: folded), .missed)
        XCTAssertEqual(TaskStatusDerivation.status(taskUid: "uid-zzz", date: today, today: today, folded: folded), .pending)
        // Teacher-verified completion.
        let verified = EventFold.fold([
            event(id: "v1", type: PlanEventType.taskCompleted, serverSeq: 1, clientSeq: 1,
                  payloadJSON: #"{"task_uid":"uid-v","evidence":{"kind":"teacher_verification"}}"#)
        ])
        XCTAssertEqual(TaskStatusDerivation.status(taskUid: "uid-v", date: past, today: today, folded: verified), .verified)
    }

    /// v1 audit 6.11: a task carrying a submission window (e.g. the Friday
    /// tasmeeʿ, window opens Sunday/closes the day after its own date) must
    /// not read `.missed` while its own window is still open, even though
    /// its `date` is already in the past. Once the window itself has closed
    /// with no completion, it genuinely is missed — deadline moves from
    /// `date` to `window.closesOn`, nothing else changes.
    func testTaskStatusDerivationHonoursSubmissionWindow() {
        let folded = FoldedEvents()  // nothing completed/excused
        let friday = LocalDate(iso: "2026-07-17")!
        let saturday = LocalDate(iso: "2026-07-18")!  // window.closesOn
        let sunday = LocalDate(iso: "2026-07-19")!
        let window = (opensOn: LocalDate(iso: "2026-07-12")!, closesOn: saturday)

        // No window supplied (every existing call site today): unchanged —
        // a past date reads missed the instant `today` moves past it.
        XCTAssertEqual(
            TaskStatusDerivation.status(taskUid: "tasmee-1", date: friday, today: saturday, folded: folded),
            .missed)

        // Window supplied and still open as of `today`: not missed yet.
        XCTAssertEqual(
            TaskStatusDerivation.status(
                taskUid: "tasmee-1", date: friday, today: saturday, folded: folded, window: window),
            .pending)

        // Window supplied and has now closed with nothing submitted: missed.
        XCTAssertEqual(
            TaskStatusDerivation.status(
                taskUid: "tasmee-1", date: friday, today: sunday, folded: folded, window: window),
            .missed)
    }
}
