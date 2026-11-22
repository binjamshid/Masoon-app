import XCTest
@testable import MasoonDomain

/// PC-22 (Batch 3 Stage 6, Track A) — `EventFold.fold(_:).curriculumTimeline`
/// (D-054's `plan.curriculum_upgraded` fold). `FoldTests.swift` covers the
/// general fold machinery; this file isolates the curriculum-timeline
/// bookkeeping specifically, which had ZERO dedicated coverage before this —
/// every existing assertion about it lived inside `PlanChangeDiffTests`
/// (MasoonCurriculumTests), which exercises it only indirectly through a
/// full `Engine.generate` run.
final class FoldCurriculumTimelineTests: XCTestCase {
    private func event(
        id: String, type: String, serverSeq: Int64?, clientSeq: Int64, payloadJSON: String
    ) -> PlanEvent {
        PlanEvent(
            eventId: id, type: type, serverSeq: serverSeq, deviceId: "d-1", clientSeq: clientSeq,
            occurredAtLocal: "2026-07-12T06:40:00+03:00", payload: try! JSONParser.parse(payloadJSON))
    }

    // MARK: - Well-formed switch appends an entry

    func testWellFormedSwitchAppendsCurriculumChange() {
        let e = event(
            id: "e1", type: PlanEventType.planCurriculumUpgraded, serverSeq: 1, clientSeq: 1,
            payloadJSON: #"{"slug":"part-time","version":"1.0.0","effective_from":"2026-08-01"}"#)
        let folded = EventFold.fold([e])
        XCTAssertEqual(folded.curriculumTimeline.count, 1)
        XCTAssertEqual(folded.curriculumTimeline[0].slug, "part-time")
        XCTAssertEqual(folded.curriculumTimeline[0].version, "1.0.0")
        XCTAssertEqual(folded.curriculumTimeline[0].effectiveFrom, LocalDate(iso: "2026-08-01"))
    }

    // MARK: - Missing `version` defaults to empty string, never fatal

    func testMissingVersionDefaultsToEmptyString() {
        let e = event(
            id: "e1", type: PlanEventType.planCurriculumUpgraded, serverSeq: 1, clientSeq: 1,
            payloadJSON: #"{"slug":"part-time","effective_from":"2026-08-01"}"#)
        let folded = EventFold.fold([e])
        XCTAssertEqual(folded.curriculumTimeline.count, 1)
        XCTAssertEqual(folded.curriculumTimeline[0].version, "")
    }

    // MARK: - Missing `slug` is a deterministic no-op (whole event skipped)

    func testMissingSlugSkipsTheWholeEvent() {
        let e = event(
            id: "e1", type: PlanEventType.planCurriculumUpgraded, serverSeq: 1, clientSeq: 1,
            payloadJSON: #"{"effective_from":"2026-08-01","policy_patch":{"takrar_count":7}}"#)
        let folded = EventFold.fold([e])
        XCTAssertTrue(folded.curriculumTimeline.isEmpty)
        // The bundled policy_patch must NOT ride in either — the whole event
        // is skipped, not just the curriculum half of it.
        XCTAssertTrue(folded.policyTimeline.isEmpty)
    }

    // MARK: - Unparseable `effective_from` is a deterministic no-op

    func testUnparseableEffectiveFromSkipsTheWholeEvent() {
        let e = event(
            id: "e1", type: PlanEventType.planCurriculumUpgraded, serverSeq: 1, clientSeq: 1,
            payloadJSON: #"{"slug":"part-time","effective_from":"not-a-date"}"#)
        let folded = EventFold.fold([e])
        XCTAssertTrue(folded.curriculumTimeline.isEmpty)
    }

    // MARK: - Bundled policy_patch rides the SAME effective_from into policyTimeline

    func testBundledPolicyPatchRidesSameEffectiveFromIntoPolicyTimeline() {
        let e = event(
            id: "e1", type: PlanEventType.planCurriculumUpgraded, serverSeq: 1, clientSeq: 1,
            payloadJSON: #"{"slug":"part-time","version":"1.0.0","effective_from":"2026-08-01","policy_patch":{"takrar_count":7}}"#)
        let folded = EventFold.fold([e])
        XCTAssertEqual(folded.curriculumTimeline.count, 1)
        XCTAssertEqual(folded.policyTimeline.count, 1)
        XCTAssertEqual(folded.policyTimeline[0].effectiveFrom, LocalDate(iso: "2026-08-01"))
        XCTAssertFalse(folded.policyTimeline[0].isOverride, "a bundled switch patch is not a supervisor override")
        XCTAssertEqual(folded.policyTimeline[0].patch, try! JSONParser.parse(#"{"takrar_count":7}"#))
    }

    // MARK: - A switch with no bundled patch touches ONLY the curriculum timeline

    func testSwitchWithoutBundledPatchLeavesPolicyTimelineEmpty() {
        let e = event(
            id: "e1", type: PlanEventType.planCurriculumUpgraded, serverSeq: 1, clientSeq: 1,
            payloadJSON: #"{"slug":"part-time","version":"1.0.0","effective_from":"2026-08-01"}"#)
        let folded = EventFold.fold([e])
        XCTAssertEqual(folded.curriculumTimeline.count, 1)
        XCTAssertTrue(folded.policyTimeline.isEmpty)
    }

    // MARK: - Multiple switches append IN FOLD ORDER (append-only)

    func testMultipleSwitchesAppendInFoldOrder() {
        let first = event(
            id: "e1", type: PlanEventType.planCurriculumUpgraded, serverSeq: 1, clientSeq: 1,
            payloadJSON: #"{"slug":"part-time","version":"1.0.0","effective_from":"2026-08-01"}"#)
        let second = event(
            id: "e2", type: PlanEventType.planCurriculumUpgraded, serverSeq: 2, clientSeq: 2,
            payloadJSON: #"{"slug":"line-chunking","version":"1.0.0","effective_from":"2026-09-01"}"#)
        let folded = EventFold.fold([second, first])  // fed out of order — server_seq total order wins
        XCTAssertEqual(folded.curriculumTimeline.map(\.slug), ["part-time", "line-chunking"])
        XCTAssertEqual(folded.curriculumTimeline.map(\.effectiveFrom), [
            LocalDate(iso: "2026-08-01"), LocalDate(iso: "2026-09-01"),
        ])
    }

    // MARK: - Fold is order-invariant for curriculumTimeline too (mirrors FoldTests' shuffle proof)

    func testCurriculumTimelineIsOrderInvariantUnderInputShuffle() {
        let events = [
            event(id: "e1", type: PlanEventType.planCurriculumUpgraded, serverSeq: 1, clientSeq: 1,
                  payloadJSON: #"{"slug":"part-time","version":"1.0.0","effective_from":"2026-08-01"}"#),
            event(id: "e2", type: PlanEventType.planCurriculumUpgraded, serverSeq: 2, clientSeq: 2,
                  payloadJSON: #"{"slug":"line-chunking","version":"1.0.0","effective_from":"2026-09-01","policy_patch":{"takrar_count":6}}"#),
            event(id: "e3", type: PlanEventType.taskCompleted, serverSeq: 3, clientSeq: 3,
                  payloadJSON: #"{"task_uid":"uid-a"}"#),
        ]
        let reference = EventFold.fold(events)
        XCTAssertEqual(EventFold.fold(events.reversed()), reference)
    }
}
