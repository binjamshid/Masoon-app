import XCTest
@testable import MasoonDomain

final class LocalDateTests: XCTestCase {
    func testWeekdayOfKnownDates() {
        // 2026-07-12 is a Sunday.
        XCTAssertEqual(LocalDate(iso: "2026-07-12")?.weekday, .sun)
        // 1970-01-01 was a Thursday.
        XCTAssertEqual(LocalDate(iso: "1970-01-01")?.weekday, .thu)
        // 2000-01-01 was a Saturday.
        XCTAssertEqual(LocalDate(iso: "2000-01-01")?.weekday, .sat)
        // 2024-02-29 (leap day) was a Thursday.
        XCTAssertEqual(LocalDate(iso: "2024-02-29")?.weekday, .thu)
    }

    func testLeapYearRules() {
        XCTAssertTrue(LocalDate.isLeapYear(2024))
        XCTAssertFalse(LocalDate.isLeapYear(2026))
        XCTAssertTrue(LocalDate.isLeapYear(2000))   // divisible by 400
        XCTAssertFalse(LocalDate.isLeapYear(1900))  // divisible by 100 but not 400
        XCTAssertNotNil(LocalDate(year: 2024, month: 2, day: 29))
        XCTAssertNil(LocalDate(year: 2026, month: 2, day: 29))
        XCTAssertNil(LocalDate(year: 1900, month: 2, day: 29))
    }

    func testMonthEdges() {
        XCTAssertEqual(LocalDate(iso: "2026-01-31")?.adding(days: 1).isoString, "2026-02-01")
        XCTAssertEqual(LocalDate(iso: "2026-12-31")?.adding(days: 1).isoString, "2027-01-01")
        XCTAssertEqual(LocalDate(iso: "2024-02-28")?.adding(days: 1).isoString, "2024-02-29")
        XCTAssertEqual(LocalDate(iso: "2026-02-28")?.adding(days: 1).isoString, "2026-03-01")
        XCTAssertEqual(LocalDate(iso: "2026-03-01")?.adding(days: -1).isoString, "2026-02-28")
        XCTAssertNil(LocalDate(iso: "2026-04-31"))
        XCTAssertNil(LocalDate(iso: "2026-13-01"))
        XCTAssertNil(LocalDate(iso: "2026-7-12"))   // strict zero-padded format
    }

    func testISORoundTripAndDayNumberRoundTrip() {
        // Sweep ±3000 days around an anchor: dayNumber and ISO round-trip exactly,
        // weekday cycles with period 7.
        let anchor = LocalDate(iso: "2026-07-12")!
        for offset in -3000...3000 {
            let date = anchor.adding(days: offset)
            XCTAssertEqual(LocalDate(dayNumber: date.dayNumber), date)
            XCTAssertEqual(LocalDate(iso: date.isoString), date)
            XCTAssertEqual(date.weekday.rawValue, ((anchor.weekday.rawValue + offset) % 7 + 7) % 7)
        }
    }

    func testDifferenceAndComparable() {
        let a = LocalDate(iso: "2026-07-12")!
        let b = LocalDate(iso: "2026-08-15")!
        XCTAssertEqual(b - a, 34)
        XCTAssertTrue(a < b)
        XCTAssertEqual(a.adding(days: 34), b)
    }
}
