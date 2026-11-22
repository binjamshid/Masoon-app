/// Loads numbered works and their unit counts into the same global
/// coordinate and weight model used by other content indexes.

public enum PoemIndexError: Error, CustomStringConvertible {
    case malformed(String)
    public var description: String {
        if case .malformed(let m) = self { return "corpus-ref error: \(m)" }
        return "corpus-ref error"
    }
}

public struct PoemIndex: Sendable {
    public struct Work: Sendable, Equatable {
        /// 1-based author-defined ordering (corpus-ref-v1 `works[].no`).
        public let no: Int
        public let slug: String
        public let unitCount: Int
        public let titleAr: String
        public let titleEn: String?

        public init(no: Int, slug: String, unitCount: Int, titleAr: String, titleEn: String?) {
            self.no = no
            self.slug = slug
            self.unitCount = unitCount
            self.titleAr = titleAr
            self.titleEn = titleEn
        }
    }

    /// µp size of one atomic unit (bayt), per the batch's fixed, integer-only
    /// ruling: 1 bayt = 1 page / 10 = 100_000 µp (never floating point,
    /// mirrors `Micropage`'s existing discipline). Cross-checked against the
    /// document's own `unit_micropages`/`units_per_page` in `init` rather
    /// than trusted blindly, so a malformed/tampered corpus-ref document
    /// cannot silently smuggle in a different per-unit size.
    public static let unitMicropages: Int64 = 100_000
    public static let unitsPerPage: Int = 10

    public let corpusId: String
    /// Which `meta.corpora` KIND token this concrete corpus instantiates
    /// ("poem"). The join between the curriculum vocabulary and the corpus
    /// vocabulary — see corpus-ref-v1's own field notes and D-198.
    public let corpusKind: String
    /// Corpus-level display name (the collection's name, not a work's).
    public let titleAr: String
    public let titleEn: String?
    public let recension: String
    public let sourceSha256: String
    public let atomicUnit: String
    public let boundaryKindRaw: String
    /// In `no` order (author-defined global ordering, mirroring
    /// `QuranIndex`'s use of `surah_ayah_counts`' array order for surahs).
    public let works: [Work]
    public let totalUnits: Int

    /// global unit id -> index into `works`
    private let workIndexOfGlobal: [Int]
    /// global unit id -> 1-based unit-within-work number
    private let unitOfGlobalArr: [Int]
    /// `works` index (0-based) -> global id of its first unit
    private let workStartGlobal: [Int]

    public init(json: JSONValue) throws {
        guard let obj = json.objectValue else { throw PoemIndexError.malformed("root is not an object") }
        guard let corpusId = obj["corpus_id"]?.stringValue else {
            throw PoemIndexError.malformed("corpus_id missing")
        }
        guard let corpusKind = obj["corpus_kind"]?.stringValue else {
            throw PoemIndexError.malformed("corpus_kind missing")
        }
        // Required, not optional-with-a-fallback: the only fallback available
        // would be displaying `corpus_id` as a title, and a
        // corpus that cannot be named cannot honestly be offered.
        guard let corpusTitleObj = obj["title"]?.objectValue,
              let corpusTitleAr = corpusTitleObj["ar"]?.stringValue, !corpusTitleAr.isEmpty
        else {
            throw PoemIndexError.malformed("title.ar missing")
        }
        guard let recension = obj["recension"]?.stringValue else {
            throw PoemIndexError.malformed("recension missing")
        }
        guard let sourceSha256 = obj["source_sha256"]?.stringValue else {
            throw PoemIndexError.malformed("source_sha256 missing")
        }
        guard let atomicUnit = obj["atomic_unit"]?.stringValue else {
            throw PoemIndexError.malformed("atomic_unit missing")
        }
        guard let boundaryKind = obj["boundary_kind"]?.stringValue else {
            throw PoemIndexError.malformed("boundary_kind missing")
        }
        // Check the required unit size against the input.
        guard let unitsPerPage = obj["units_per_page"]?.intValue, unitsPerPage == PoemIndex.unitsPerPage else {
            throw PoemIndexError.malformed("units_per_page must be \(PoemIndex.unitsPerPage)")
        }
        guard let unitMp = obj["unit_micropages"]?.intValue, Int64(unitMp) == PoemIndex.unitMicropages else {
            throw PoemIndexError.malformed("unit_micropages must be \(PoemIndex.unitMicropages)")
        }
        guard let worksJSON = obj["works"]?.arrayValue, !worksJSON.isEmpty else {
            throw PoemIndexError.malformed("works must be a non-empty array")
        }

        var parsed: [Work] = []
        parsed.reserveCapacity(worksJSON.count)
        for item in worksJSON {
            guard let wobj = item.objectValue,
                  let no = wobj["no"]?.intValue, no >= 1,
                  let slug = wobj["slug"]?.stringValue,
                  let unitCount = wobj["unit_count"]?.intValue, unitCount >= 1,
                  let titleObj = wobj["title"]?.objectValue,
                  let titleAr = titleObj["ar"]?.stringValue
            else { throw PoemIndexError.malformed("bad entry in works[]") }
            parsed.append(Work(no: no, slug: slug, unitCount: unitCount, titleAr: titleAr, titleEn: titleObj["en"]?.stringValue))
        }
        parsed.sort { $0.no < $1.no }
        // The schema's own cross-field invariant check (poem-ref-build's
        // checkCrossFieldInvariants) already rejects duplicate no/slug before
        // a document is ever written; re-validated here too since this index
        // must not trust its input file's provenance blindly.
        var seenNo = Set<Int>()
        var seenSlug = Set<String>()
        for w in parsed {
            guard seenNo.insert(w.no).inserted else {
                throw PoemIndexError.malformed("duplicate works[].no = \(w.no)")
            }
            guard seenSlug.insert(w.slug).inserted else {
                throw PoemIndexError.malformed("duplicate works[].slug = \"\(w.slug)\"")
            }
        }

        self.corpusId = corpusId
        self.corpusKind = corpusKind
        self.titleAr = corpusTitleAr
        self.titleEn = corpusTitleObj["en"]?.stringValue
        self.recension = recension
        self.sourceSha256 = sourceSha256
        self.atomicUnit = atomicUnit
        self.boundaryKindRaw = boundaryKind
        self.works = parsed

        var workIndexOf: [Int] = []
        var unitOf: [Int] = []
        var starts: [Int] = []
        starts.reserveCapacity(parsed.count)
        var running = 0
        for (i, w) in parsed.enumerated() {
            starts.append(running)
            for u in 1...w.unitCount {
                workIndexOf.append(i)
                unitOf.append(u)
            }
            running += w.unitCount
        }
        self.workIndexOfGlobal = workIndexOf
        self.unitOfGlobalArr = unitOf
        self.workStartGlobal = starts
        self.totalUnits = running
    }

    public func globalIndex(work: Int, unit: Int) -> Int? {
        guard let i = works.firstIndex(where: { $0.no == work }), unit >= 1, unit <= works[i].unitCount else {
            return nil
        }
        return workStartGlobal[i] + unit - 1
    }
}

// MARK: - ContentIndex conformance

extension PoemIndex: ContentIndex {
    public func globalIndex(of position: CanonicalPosition) -> Int? {
        globalIndex(work: position.work, unit: position.unit)
    }

    public func position(ofGlobal g: Int) -> CanonicalPosition {
        CanonicalPosition(work: works[workIndexOfGlobal[g]].no, unit: unitOfGlobalArr[g])!
    }

    public func globalRange(of range: CanonicalRange) -> Range<Int>? {
        guard let start = globalIndex(work: range.work, unit: range.unitStart),
              let end = globalIndex(work: range.work, unit: range.unitEnd)
        else { return nil }
        return start..<(end + 1)
    }

    public func workOfGlobal(_ g: Int) -> Int { works[workIndexOfGlobal[g]].no }
    public func unitOfGlobal(_ g: Int) -> Int { unitOfGlobalArr[g] }
    /// Every atomic unit weighs the same (unlike a Qur'an ayah, whose weight
    /// varies with how many ayahs share its mushaf page) — the batch's fixed
    /// 1 bayt = 100_000 µp ruling.
    public func weight(ofGlobal g: Int) -> Int64 { PoemIndex.unitMicropages }

    public var boundaryKind: String { boundaryKindRaw }
    /// `corpus_block`/`work_boundary` (corpus-ref-v1 schema): for this stage
    /// both map to per-work boundaries — one work is one boundary block. A
    /// poem corpus has no Qur'an-juz-style sub-work grouping; `work_boundary`
    /// is reserved (per the schema's own notes) for a later corpus needing a
    /// boundary finer than a whole work, which nothing in this batch
    /// exercises yet.
    public var boundaryCount: Int { works.count }
    public func boundaryGlobalRange(_ n: Int) -> Range<Int>? {
        guard n >= 1, n <= works.count else { return nil }
        let i = n - 1
        return workStartGlobal[i]..<(workStartGlobal[i] + works[i].unitCount)
    }
    public func boundaryOfGlobal(_ g: Int) -> Int { workIndexOfGlobal[g] + 1 }
    /// No fixed per-boundary µp size exists for this corpus: works vary
    /// widely in length (the synthetic test fixture alone has works of 7 and
    /// 3 units), so a "recent N boundaries" murājaʿah pool window is
    /// genuinely undefined here — `ContentIndex.boundaryUnitMicropages`'s
    /// documented nil case, not a guessed fallback.
    public var boundaryUnitMicropages: Int64? { nil }

    /// Deliberately narrower than `QuranIndex.amountMicropages`: only the
    /// corpus-invariant `page` unit and the count-based `ayah`/`custom_range`
    /// units resolve. `line`/`juz`/`hizb`/`rub` have no corpus-ref-v1
    /// analogue for a poem collection and correctly hit PCC-3's
    /// `.unsupported` case — proving `selectNextNew`'s thrown-error path is
    /// real, not just theoretical, for a second conformer.
    public func amountMicropages(_ amount: QuranAmount) -> AmountResolution {
        switch amount.unit {
        case .ayah, .customRange:
            return .countUnit(Int(amount.value.roundedInt))
        case .page:
            return .micropages(amount.value.scaled(by: Micropage.perPage))
        case .line, .juz, .hizb, .rub:
            return .unsupported
        }
    }

    /// The corpus-ref document's own provenance checksum (build.js computes
    /// it from the supplied counts file; never re-derived here).
    public var refChecksum: String { sourceSha256 }
}
