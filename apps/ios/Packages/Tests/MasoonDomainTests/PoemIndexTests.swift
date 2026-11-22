import XCTest
@testable import MasoonDomain

/// Exercises the poem index with invented work names and unit counts.
final class PoemIndexTests: XCTestCase {
    static let syntheticRefJSON = """
    {
      "corpus_id": "zz_test_fixture_not_real",
      "corpus_kind": "poem",
      "title": {
        "ar": "مجموعة اختبارية وهمية (ليست مجموعة حقيقية)",
        "en": "Synthetic test corpus (fictional placeholder, not a real collection)"
      },
      "recension": "Synthetic test recension",
      "source_sha256": "ff9461117112253f66db0af36fdc80dd8f139bbc106ad3cdf03124fa7fc05e96",
      "units_per_page": 10,
      "unit_micropages": 100000,
      "atomic_unit": "bayt",
      "boundary_kind": "corpus_block",
      "works": [
        {
          "no": 1,
          "slug": "zz_fake_work_one",
          "unit_count": 7,
          "title": {
            "ar": "عمل تجريبي وهمي رقم واحد (بيانات اختبار وليست قصيدة حقيقية)",
            "en": "Synthetic test work one (fictional placeholder, not a real poem)"
          }
        },
        {
          "no": 2,
          "slug": "zz_fake_work_two",
          "unit_count": 3,
          "title": {
            "ar": "عمل تجريبي وهمي رقم اثنان (بيانات اختبار وليست قصيدة حقيقية)",
            "en": "Synthetic test work two (fictional placeholder, not a real poem)"
          }
        }
      ],
      "disagreements": [
        {
          "work_slug": "zz_fake_work_two",
          "editions": [
            { "source": "synthetic-fixture-edition-A", "count": 3 },
            { "source": "synthetic-fixture-edition-B", "count": 4 }
          ],
          "resolution": null
        }
      ]
    }
    """

    static func makeIndex() throws -> PoemIndex {
        try PoemIndex(json: try JSONParser.parse(Self.syntheticRefJSON))
    }

    // MARK: - Parsing the real tool's real output

    func testParsesFieldsFromRealBuildOutput() throws {
        let index = try Self.makeIndex()
        XCTAssertEqual(index.corpusId, "zz_test_fixture_not_real")
        XCTAssertEqual(index.atomicUnit, "bayt")
        XCTAssertEqual(index.boundaryKindRaw, "corpus_block")
        XCTAssertEqual(index.sourceSha256, "ff9461117112253f66db0af36fdc80dd8f139bbc106ad3cdf03124fa7fc05e96")
        XCTAssertEqual(index.corpusKind, "poem")
        XCTAssertEqual(index.titleEn, "Synthetic test corpus (fictional placeholder, not a real collection)")
        XCTAssertEqual(index.works.map(\.no), [1, 2])
        XCTAssertEqual(index.works.map(\.slug), ["zz_fake_work_one", "zz_fake_work_two"])
        XCTAssertEqual(index.works.map(\.unitCount), [7, 3])
        XCTAssertEqual(index.works[0].titleEn, "Synthetic test work one (fictional placeholder, not a real poem)")
        XCTAssertEqual(index.totalUnits, 10)
    }

    func testRejectsMismatchedUnitConstants() throws {
        let tampered = Self.syntheticRefJSON.replacingOccurrences(of: "\"unit_micropages\": 100000", with: "\"unit_micropages\": 50000")
        XCTAssertThrowsError(try PoemIndex(json: try JSONParser.parse(tampered)))
    }

    func testRejectsDuplicateWorkNumbers() throws {
        // A hand-built, equally-synthetic malformed document (never a real
        // corpus) — only checking PoemIndex's own defensive re-validation of
        // an invariant poem-ref-build already enforces upstream.
        let malformed = """
        {"corpus_id":"zz_dup_test","corpus_kind":"poem","title":{"ar":"وهمي"},
         "recension":"SYNTHETIC","source_sha256":"\(String(repeating: "0", count: 64))",
         "units_per_page":10,"unit_micropages":100000,"atomic_unit":"bayt","boundary_kind":"corpus_block",
         "works":[
           {"no":1,"slug":"zz_a","unit_count":2,"title":{"ar":"أ"}},
           {"no":1,"slug":"zz_b","unit_count":3,"title":{"ar":"ب"}}
         ]}
        """
        XCTAssertThrowsError(try PoemIndex(json: try JSONParser.parse(malformed)))
    }

    /// D-198 made both fields required. A corpus that cannot say what kind it
    /// is cannot be matched to a curriculum, and one that cannot name itself
    /// can only be shown to the learner as a raw slug — so neither may parse
    /// into a silently-defaulted index.
    func testRejectsMissingCorpusKindOrTitle() throws {
        let noKind = Self.syntheticRefJSON
            .replacingOccurrences(of: "\"corpus_kind\": \"poem\",", with: "")
        XCTAssertThrowsError(try PoemIndex(json: try JSONParser.parse(noKind)))

        let noTitle = Self.syntheticRefJSON.replacingOccurrences(
            of: "\"ar\": \"مجموعة اختبارية وهمية (ليست مجموعة حقيقية)\",", with: "")
        XCTAssertThrowsError(try PoemIndex(json: try JSONParser.parse(noTitle)))
    }

    // MARK: - ContentIndex conformance

    func testGlobalIndexingAndPositionRoundTrip() throws {
        let index = try Self.makeIndex()
        XCTAssertEqual(index.globalIndex(work: 1, unit: 1), 0)
        XCTAssertEqual(index.globalIndex(work: 1, unit: 7), 6)
        XCTAssertEqual(index.globalIndex(work: 2, unit: 1), 7)
        XCTAssertEqual(index.globalIndex(work: 2, unit: 3), 9)
        XCTAssertNil(index.globalIndex(work: 1, unit: 8))   // work 1 only has 7 units
        XCTAssertNil(index.globalIndex(work: 3, unit: 1))   // no work 3

        for g in 0..<index.totalUnits {
            let pos = index.position(ofGlobal: g)
            XCTAssertEqual(index.globalIndex(of: pos), g, "round trip at global \(g)")
        }
        XCTAssertEqual(index.workOfGlobal(0), 1)
        XCTAssertEqual(index.workOfGlobal(6), 1)
        XCTAssertEqual(index.workOfGlobal(7), 2)
        XCTAssertEqual(index.unitOfGlobal(9), 3)
    }

    func testCanonicalRangeGenericAliasesResolveThroughGlobalRange() throws {
        let index = try Self.makeIndex()
        let range = CanonicalRange(work: 1, unitStart: 2, unitEnd: 5)!
        XCTAssertEqual(range.work, 1)
        XCTAssertEqual(range.unitStart, 2)
        XCTAssertEqual(range.unitEnd, 5)
        // The Qur'an-named aliases must read the identical values.
        XCTAssertEqual(range.surah, 1)
        XCTAssertEqual(range.ayahStart, 2)
        XCTAssertEqual(range.ayahEnd, 5)
        XCTAssertEqual(index.globalRange(of: range), 1..<5)
    }

    func testWeightIsFixedPerAtomicUnit() throws {
        let index = try Self.makeIndex()
        for g in 0..<index.totalUnits {
            XCTAssertEqual(index.weight(ofGlobal: g), 100_000, "every bayt weighs 1/10 page, no per-work variance")
        }
    }

    func testBoundaryCountAndRanges() throws {
        let index = try Self.makeIndex()
        XCTAssertEqual(index.boundaryKind, "corpus_block")
        XCTAssertEqual(index.boundaryCount, 2, "one boundary per work for this corpus")
        XCTAssertEqual(index.boundaryGlobalRange(1), 0..<7)
        XCTAssertEqual(index.boundaryGlobalRange(2), 7..<10)
        XCTAssertNil(index.boundaryGlobalRange(0))
        XCTAssertNil(index.boundaryGlobalRange(3))
        XCTAssertEqual(index.boundaryOfGlobal(0), 1)
        XCTAssertEqual(index.boundaryOfGlobal(6), 1)
        XCTAssertEqual(index.boundaryOfGlobal(7), 2)
        XCTAssertEqual(index.boundaryOfGlobal(9), 2)
    }

    /// PCC-3/E-1b: this corpus has no fixed per-boundary µp constant (works
    /// vary widely in length) — `nil`, not a guessed fallback.
    func testBoundaryUnitMicropagesIsUndefined() throws {
        let index = try Self.makeIndex()
        XCTAssertNil(index.boundaryUnitMicropages)
    }

    func testRefChecksumIsTheDocumentsOwnSourceSha256() throws {
        let index = try Self.makeIndex()
        XCTAssertEqual(index.refChecksum, index.sourceSha256)
    }

    // MARK: - amountMicropages: proves BOTH the resolving and the PCC-3
    // `.unsupported`-throws paths are real for a second corpus, not just
    // theoretical.

    func testAmountMicropagesResolvesPageAndCountUnits() throws {
        let index = try Self.makeIndex()
        let onePage = QuranAmount(unit: .page, value: DecimalValue(string: "1")!)
        XCTAssertEqual(index.amountMicropages(onePage), .micropages(1_000_000))

        let halfPage = QuranAmount(unit: .page, value: DecimalValue(string: "0.5")!)
        XCTAssertEqual(index.amountMicropages(halfPage), .micropages(500_000))

        let threeUnits = QuranAmount(unit: .ayah, value: DecimalValue(string: "3")!)
        XCTAssertEqual(index.amountMicropages(threeUnits), .countUnit(3))

        let customRangeAmount = QuranAmount(unit: .customRange, value: DecimalValue(string: "2")!)
        XCTAssertEqual(index.amountMicropages(customRangeAmount), .countUnit(2))
    }

    func testAmountMicropagesIsUnsupportedForQuranOnlyUnits() throws {
        let index = try Self.makeIndex()
        for unit: QuranUnit in [.line, .juz, .hizb, .rub] {
            let amount = QuranAmount(unit: unit, value: DecimalValue(integer: 1))
            XCTAssertEqual(index.amountMicropages(amount), .unsupported, "\(unit) has no corpus-ref-v1 analogue")
        }
    }

    // MARK: - MemorizationOrder<PoemIndex>: the SAME MasoonDomain generic
    // type used by the engine (Engine.swift's `EngineRun<Index>`) builds a
    // memorization order over this corpus — proving `ContentIndex` is real
    // enough to drive existing generic engine machinery, not just satisfy
    // the protocol's own requirements in isolation.

    func testMemorizationOrderMushafForwardOverPoemIndex() throws {
        let index = try Self.makeIndex()
        let order = try MemorizationOrder(kind: .mushafForward, index: index)
        XCTAssertEqual(order.count, index.totalUnits)
        XCTAssertEqual(order.orderToGlobal, Array(0..<index.totalUnits))
        for g in 0..<index.totalUnits {
            XCTAssertEqual(order.orderPosition(ofGlobal: g), g)
        }
    }

    func testMemorizationOrderCustomListOverPoemIndex() throws {
        let index = try Self.makeIndex()
        // Work 2 (3 units) before work 1 (7 units) — an explicit custom order,
        // exactly the shape a real poem curriculum's memorization_order would
        // eventually express.
        let list = [CanonicalRange(work: 2, unitStart: 1, unitEnd: 3)!, CanonicalRange(work: 1, unitStart: 1, unitEnd: 7)!]
        let order = try MemorizationOrder(kind: .customList(list), index: index)
        XCTAssertEqual(order.count, 10)
        XCTAssertEqual(order.orderToGlobal, [7, 8, 9, 0, 1, 2, 3, 4, 5, 6])
    }
}
