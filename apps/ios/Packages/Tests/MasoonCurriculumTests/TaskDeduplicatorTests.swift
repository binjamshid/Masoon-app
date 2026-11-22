import XCTest
@testable import MasoonCurriculum
@testable import MasoonDomain

final class TaskDeduplicatorTests: XCTestCase {
    private let namespace = UUIDv5.parse("11111111-1111-1111-1111-111111111111")!

    private func task(
        origin: String,
        session: String = "morning",
        ordering: Int = 1,
        repetitions: Int = 3
    ) -> TaskInstance {
        TaskInstance(
            date: LocalDate(iso: "2026-08-28")!, dayClass: "weekday",
            session: session, ordering: ordering, type: "murajaah",
            originRuleId: origin, occurrence: 0,
            content: [CanonicalRange(surah: 1, ayahStart: 1, ayahEnd: 7)!],
            repetitions: repetitions, spacingMinutes: 5, listenCount: 1,
            window: (LocalDate(iso: "2026-08-28")!, LocalDate(iso: "2026-08-29")!),
            estimatedMinutes: 9, evidence: .selfCheck,
            flags: ["first_active_day"], taskUid: "uid-\(origin)")
    }

    func testExactExecutionDedupMergesPresentationDifferencesAndMapsEverySourceToOneUID() {
        let result = TaskDeduplicator.deduplicate(
            namespace: namespace,
            tasks: [task(origin: "manzil", session: "morning", ordering: 1),
                    task(origin: "adaptive", session: "evening", ordering: 7)])

        XCTAssertEqual(result.output.count, 1)
        XCTAssertEqual(result.stateTasks.map(\.taskUid), [result.output[0].taskUid, result.output[0].taskUid])
        XCTAssertEqual(result.output[0].originRuleId, "adaptive+manzil")
        XCTAssertEqual(result.output[0].flags,
                       ["first_active_day", "source_rule:adaptive", "source_rule:manzil"])
        XCTAssertNotEqual(result.output[0].taskUid, "uid-manzil")
    }

    func testExactExecutionDedupKeepsDifferentExecutionRequirementsSeparate() {
        let result = TaskDeduplicator.deduplicate(
            namespace: namespace,
            tasks: [task(origin: "a", repetitions: 3), task(origin: "b", repetitions: 4)])
        XCTAssertEqual(result.output.count, 2)
        XCTAssertEqual(result.stateTasks.map(\.taskUid), ["uid-a", "uid-b"])
    }
}
