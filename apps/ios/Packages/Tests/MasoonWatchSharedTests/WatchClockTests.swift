import Foundation
import XCTest

@testable import MasoonDomain
@testable import MasoonWatchShared

/// The wrist's clock, and the shared timestamp primitives it and the phone both
/// depend on (D-199).
final class WatchClockTests: XCTestCase {

    /// A fixed-offset clock, mirroring `MasoonDataTests.TestClock`.
    private struct FixedClock: WatchClock {
        let millis: Int64
        let offsetSeconds: Int
        func nowUnixMillis() -> Int64 { millis }
        func utcOffsetSeconds(timezone: String, atUnixMillis millis: Int64) -> Int { offsetSeconds }
    }

    // MARK: - Plan timezone, not device timezone

    /// The property the whole "wrong day" class of bugs turns on: a learner
    /// flying with the watch on their wrist must still complete against the
    /// *plan's* day.
    func testLocalDateUsesPlanZoneNotDeviceZone() {
        // 2026-07-12T22:30:00Z. In Asia/Riyadh (+03:00) that is already the 13th.
        let millis = (Int64(LocalDate(iso: "2026-07-12")!.dayNumber) * 86_400 + 22 * 3600 + 1800) * 1000

        let riyadh = FixedClock(millis: millis, offsetSeconds: 3 * 3600)
        XCTAssertEqual(riyadh.localDate(timezone: "Asia/Riyadh").isoString, "2026-07-13")

        let newYork = FixedClock(millis: millis, offsetSeconds: -4 * 3600)
        XCTAssertEqual(newYork.localDate(timezone: "America/New_York").isoString, "2026-07-12")
    }

    func testLocalTimestampCarriesTheOffset() {
        let millis = (Int64(LocalDate(iso: "2026-07-12")!.dayNumber) * 86_400 + 3 * 3600 + 30 * 60) * 1000
        let clock = FixedClock(millis: millis, offsetSeconds: 3 * 3600)
        XCTAssertEqual(clock.localTimestamp(timezone: "Asia/Riyadh"), "2026-07-12T06:30:00+03:00")
    }

    func testNegativeOffsetFormatting() {
        let millis = (Int64(LocalDate(iso: "2026-12-31")!.dayNumber) * 86_400 + 4 * 3600 + 5 * 60 + 9) * 1000
        let clock = FixedClock(millis: millis, offsetSeconds: -5 * 3600)
        XCTAssertEqual(clock.localTimestamp(timezone: "America/New_York"), "2026-12-30T23:05:09-05:00")
    }

    /// An unknown zone resolves to UTC rather than failing: losing a learner's
    /// completion is worse than an hour of skew.
    func testUnknownTimezoneFallsBackToUTCRatherThanFailing() {
        let clock = SystemWatchClock()
        XCTAssertEqual(clock.utcOffsetSeconds(timezone: "Not/AZone", atUnixMillis: 0), 0)
    }

    // MARK: - Instant comparison (the staleness check's foundation)

    func testEpochSecondsRoundTripsThroughFormatting() {
        let millis: Int64 = 1_784_000_000_000
        for offset in [0, 3 * 3600, -5 * 3600, 5 * 3600 + 1800] {
            let text = LocalTimestamp.iso8601(unixMillis: millis, utcOffsetSeconds: offset)
            XCTAssertEqual(
                LocalTimestamp.epochSeconds(fromISO8601: text), millis / 1000,
                "offset \(offset) must round-trip")
        }
    }

    /// The reason `occurred_at_local` is compared as an instant and not as text.
    /// Across a DST fall-back the later instant sorts *earlier* lexicographically
    /// — and the ingestor decides whether to keep or drop a learner's completion
    /// on exactly this comparison.
    func testStringOrderingDisagreesWithInstantOrderingAcrossDST() {
        // US fall-back 2026-11-01: 01:30 EDT (-04:00) happens BEFORE 01:15 EST (-05:00).
        let earlier = "2026-11-01T01:30:00-04:00"  // 05:30Z
        let later = "2026-11-01T01:15:00-05:00"  // 06:15Z

        XCTAssertGreaterThan(earlier, later, "as text, the earlier instant sorts later")

        let earlierAt = LocalTimestamp.epochSeconds(fromISO8601: earlier)!
        let laterAt = LocalTimestamp.epochSeconds(fromISO8601: later)!
        XCTAssertLessThan(earlierAt, laterAt, "as instants, the ordering is correct")
    }

    func testEpochSecondsHandlesZuluAndBareTimestamps() {
        XCTAssertEqual(
            LocalTimestamp.epochSeconds(fromISO8601: "1970-01-01T00:00:00Z"), 0)
        XCTAssertEqual(
            LocalTimestamp.epochSeconds(fromISO8601: "1970-01-01T00:00:00"), 0)
        XCTAssertEqual(
            LocalTimestamp.epochSeconds(fromISO8601: "1970-01-02T00:00:00Z"), 86_400)
    }

    func testEpochSecondsRejectsMalformedInput() {
        for bad in ["", "2026-07-12", "not a timestamp", "2026-13-01T00:00:00Z",
                    "2026-07-12T25:00:00Z", "2026-07-12X06:30:00+03:00"] {
            XCTAssertNil(LocalTimestamp.epochSeconds(fromISO8601: bad), "\(bad) should not parse")
        }
    }

    func testDatePartExtractsThePlanLocalDate() {
        XCTAssertEqual(
            LocalTimestamp.datePart(ofISO8601: "2026-07-12T06:30:00+03:00")?.isoString, "2026-07-12")
        XCTAssertEqual(LocalTimestamp.datePart(ofISO8601: "2026-07-12")?.isoString, "2026-07-12")
        XCTAssertNil(LocalTimestamp.datePart(ofISO8601: "garbage"))
    }

    // MARK: - Event ids

    func testGeneratedIdsAreUUIDv7ShapedAndMonotonic() {
        var generator = WatchIDGenerator(
            clock: FixedClock(millis: 1_784_000_000_000, offsetSeconds: 0))
        let ids = (0..<50).map { _ in generator.next() }

        XCTAssertEqual(Set(ids).count, ids.count, "ids must be unique")
        XCTAssertEqual(ids, ids.sorted(), "same-millisecond ids must stay monotonic")
        for id in ids {
            XCTAssertEqual(id.count, 36)
            let bytes = try? XCTUnwrap(UUIDv5.parse(id))
            XCTAssertEqual((bytes?[6] ?? 0) & 0xF0, 0x70, "version nibble must be 7")
            XCTAssertEqual((bytes?[8] ?? 0) & 0xC0, 0x80, "variant bits must be 10")
        }
    }

    /// The wrist and the phone share `UUIDv7Core`, so the timestamp bits encode
    /// the injected clock identically on both.
    func testIdEncodesTheInjectedClock() throws {
        let millis: Int64 = 1_784_000_000_000
        var generator = WatchIDGenerator(clock: FixedClock(millis: millis, offsetSeconds: 0))
        let bytes = try XCTUnwrap(UUIDv5.parse(generator.next()))
        var encoded: Int64 = 0
        for i in 0..<6 { encoded = (encoded << 8) | Int64(bytes[i]) }
        XCTAssertEqual(encoded, millis)
    }

    // MARK: - Evidence payload parity

    /// The wrist's evidence must serialise to exactly what the phone writes —
    /// both go through `MasoonDomain.EvidencePayloads`.
    func testWatchEvidenceMatchesTheSharedPayloads() {
        XCTAssertEqual(WatchEvidence.selfCheck().jsonValue, EvidencePayloads.selfCheck())
        XCTAssertEqual(
            WatchEvidence.counter(count: 5, increments: ["06:00", "06:15"]).jsonValue,
            EvidencePayloads.counter(count: 5, increments: ["06:00", "06:15"]))
        XCTAssertEqual(
            WatchEvidence.timer(seconds: 90).jsonValue, EvidencePayloads.timer(seconds: 90))
    }

    /// An unrecognised kind falls back to `self_check` rather than emitting a
    /// shape the fold has never seen.
    func testUnknownEvidenceKindFallsBackToSelfCheck() {
        XCTAssertEqual(
            WatchEvidence(kind: "telepathy").jsonValue, EvidencePayloads.selfCheck())
    }
}
