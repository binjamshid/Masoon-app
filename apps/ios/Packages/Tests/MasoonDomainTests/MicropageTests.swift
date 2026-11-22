import XCTest
@testable import MasoonDomain

final class MicropageTests: XCTestCase {
    func testRoundHalfUp() {
        XCTAssertEqual(Micropage.roundHalfUp(1, 2), 1)    // 0.5 → 1
        XCTAssertEqual(Micropage.roundHalfUp(1, 3), 0)    // 0.333 → 0
        XCTAssertEqual(Micropage.roundHalfUp(2, 3), 1)    // 0.667 → 1
        XCTAssertEqual(Micropage.roundHalfUp(3, 2), 2)    // 1.5 → 2
        XCTAssertEqual(Micropage.roundHalfUp(0, 7), 0)
        XCTAssertEqual(Micropage.roundHalfUp(7, 7), 1)
        XCTAssertEqual(Micropage.roundHalfUp(10, 4), 3)   // 2.5 → 3
    }

    func testDecimalValueParsing() {
        XCTAssertEqual(DecimalValue(string: "1")?.scaled(by: 1_000_000), 1_000_000)
        XCTAssertEqual(DecimalValue(string: "0.5")?.scaled(by: 1_000_000), 500_000)
        XCTAssertEqual(DecimalValue(string: "2.25")?.scaled(by: 1_000_000), 2_250_000)
        XCTAssertEqual(DecimalValue(string: "0.000001")?.scaled(by: 1_000_000), 1)
        XCTAssertEqual(DecimalValue(string: "1.5")?.roundedInt, 2)  // half-up
        XCTAssertNil(DecimalValue(string: "-1"))
        XCTAssertNil(DecimalValue(string: "1e3"))
        XCTAssertNil(DecimalValue(string: ""))
        XCTAssertNil(DecimalValue(string: "abc"))
    }

    func testUnitMicropages() {
        XCTAssertEqual(Micropage.unitMicropages(.page), 1_000_000)
        XCTAssertEqual(Micropage.unitMicropages(.juz), 20_000_000)
        XCTAssertEqual(Micropage.unitMicropages(.hizb), 10_000_000)
        XCTAssertEqual(Micropage.unitMicropages(.rub), 2_500_000)
        XCTAssertEqual(Micropage.unitMicropages(.line), 66_666)
        XCTAssertNil(Micropage.unitMicropages(.ayah))  // resolved by count, not µp
    }

    func testAmountMicropages() throws {
        let json = try JSONParser.parse(#"{"unit":"rub","value":"2"}"#)
        XCTAssertEqual(QuranAmount(json: json)?.micropages, 5_000_000)
        // Curriculum definitions carry numbers, policies carry decimal strings.
        let numeric = try JSONParser.parse(#"{"unit":"page","value":1}"#)
        XCTAssertEqual(QuranAmount(json: numeric)?.micropages, 1_000_000)
        let fractional = try JSONParser.parse(#"{"unit":"page","value":"0.5"}"#)
        XCTAssertEqual(QuranAmount(json: fractional)?.micropages, 500_000)
    }
}

final class OrderSpanSetTests: XCTestCase {
    func testInsertCoalescesAdjacentAndOverlapping() {
        var set = OrderSpanSet()
        set.insert(0..<3)
        set.insert(5..<7)
        set.insert(3..<5)  // bridges the gap
        XCTAssertEqual(set.spans.count, 1)
        XCTAssertEqual(set.positionCount, 7)
        XCTAssertTrue(set.contains(6))
        XCTAssertFalse(set.contains(7))
    }

    func testSubtracting() {
        var set = OrderSpanSet()
        set.insert(0..<10)
        var cut = OrderSpanSet()
        cut.insert(3..<5)
        cut.insert(8..<12)
        let result = set.subtracting(cut)
        XCTAssertEqual(result.positions, [0, 1, 2, 5, 6, 7])
    }

    func testFirstPositionAtOrAfter() {
        var set = OrderSpanSet()
        set.insert(5..<8)
        set.insert(12..<14)
        XCTAssertEqual(set.firstPosition(atOrAfter: 0), 5)
        XCTAssertEqual(set.firstPosition(atOrAfter: 6), 6)
        XCTAssertEqual(set.firstPosition(atOrAfter: 9), 12)
        XCTAssertNil(set.firstPosition(atOrAfter: 14))
    }
}
