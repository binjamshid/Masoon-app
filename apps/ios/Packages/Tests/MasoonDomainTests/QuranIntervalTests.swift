import XCTest

@testable import MasoonDomain

final class QuranIntervalTests: XCTestCase {
    // The coordinate shape is required by the parser. Each chapter's count
    // and every boundary below are invented for this test.
    private let index = try! QuranIndex(json: .object([
        "surah_ayah_counts": .array(Array(repeating: .number("3"), count: 114)),
        "juz_starts": .array([.array([.number("1"), .number("1"), .number("1")])]),
        "rub_starts": .array([.array([.number("1"), .number("1"), .number("1")])]),
        "page_starts": .array([.array([.number("1"), .number("1"), .number("1")])]),
    ]))

    func testRejectsUnknownCoordinatesAndReversedEndpoints() {
        XCTAssertNil(QuranInterval(
            start: CanonicalPosition(surah: 1, ayah: 4)!,
            end: CanonicalPosition(surah: 2, ayah: 1)!, index: index))
        XCTAssertNil(QuranInterval(
            start: CanonicalPosition(surah: 2, ayah: 1)!,
            end: CanonicalPosition(surah: 1, ayah: 3)!, index: index))
        XCTAssertNil(QuranInterval(
            start: CanonicalPosition(surah: 114, ayah: 3)!,
            end: CanonicalPosition(surah: 114, ayah: 4)!, index: index))
    }

    func testSingleAyahStaysOneSingleSurahRange() throws {
        let interval = try XCTUnwrap(QuranInterval(
            start: CanonicalPosition(surah: 1, ayah: 1)!,
            end: CanonicalPosition(surah: 1, ayah: 1)!, index: index))

        XCTAssertEqual(interval.count, 1)
        XCTAssertEqual(interval.canonicalRanges(in: index), [
            CanonicalRange(surah: 1, ayahStart: 1, ayahEnd: 1)!,
        ])
    }

    func testEndOfSurahToNextSurahSegmentsWithoutLosingEitherBoundary() throws {
        let interval = try XCTUnwrap(QuranInterval(
            start: CanonicalPosition(surah: 1, ayah: 3)!,
            end: CanonicalPosition(surah: 2, ayah: 1)!, index: index))

        XCTAssertEqual(interval.count, 2)
        XCTAssertEqual(interval.canonicalRanges(in: index), [
            CanonicalRange(surah: 1, ayahStart: 3, ayahEnd: 3)!,
            CanonicalRange(surah: 2, ayahStart: 1, ayahEnd: 1)!,
        ])
    }

    func testWholeSyntheticIndexIncludesAllCoordinates() throws {
        let interval = try XCTUnwrap(QuranInterval(
            start: CanonicalPosition(surah: 1, ayah: 1)!,
            end: CanonicalPosition(surah: 114, ayah: 3)!, index: index))
        let ranges = interval.canonicalRanges(in: index)

        XCTAssertEqual(interval.count, 342)
        XCTAssertEqual(ranges.count, 114)
        XCTAssertEqual(ranges.first, CanonicalRange(surah: 1, ayahStart: 1, ayahEnd: 3))
        XCTAssertEqual(ranges.last, CanonicalRange(surah: 114, ayahStart: 1, ayahEnd: 3))
    }
}
