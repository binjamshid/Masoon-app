/// Canonical Quran value objects (DOMAIN_MODEL §1).
/// Canonical content is riwayah + surah + ayah range; pages/juz/hizb/rubʿ are
/// edition-dependent projections and never identifiers. Riwayah is implicit
/// Ḥafṣ v1 throughout the v1 engine (ENGINE_PARITY §4.1).

public enum QuranUnit: String, Hashable, Sendable, CaseIterable {
    case ayah, line, page, rub, hizb, juz
    case customRange = "custom_range"
}

public struct QuranAmount: Hashable, Sendable {
    public let unit: QuranUnit
    public let value: DecimalValue

    public init(unit: QuranUnit, value: DecimalValue) {
        self.unit = unit
        self.value = value
    }

    /// Parses `{"unit": "...", "value": "1"}`; `value` may be a JSON number in
    /// curriculum definitions or a decimal string in policies/fixtures.
    public init?(json: JSONValue) {
        guard let obj = json.objectValue,
              let unitStr = obj["unit"]?.stringValue,
              let unit = QuranUnit(rawValue: unitStr),
              let value = obj["value"]?.decimalValue
        else { return nil }
        self.init(unit: unit, value: value)
    }

    /// Resolved micropage size; nil for ayah/custom units (ayah amounts are
    /// resolved by ayah count, ENGINE_SEMANTICS §1).
    public var micropages: Int64? {
        guard let per = Micropage.unitMicropages(unit) else { return nil }
        return value.scaled(by: per)
    }
}

public struct CanonicalRange: Hashable, Sendable, CustomStringConvertible {
    public let surah: Int      // valid range enforced by QuranSurahValidation (QuranIndex.swift)
    public let ayahStart: Int  // 1-based, inclusive
    public let ayahEnd: Int    // inclusive; single-surah, ordered, non-empty

    // MARK: Corpus-agnostic aliases (Batch 3 Stage 2 `ContentIndex`).
    // Identical values under different names — engine code that must not
    // hardcode Qur'an vocabulary (Engine.swift, MemorizationOrder.swift)
    // reads/writes through these; every existing `.surah`/`.ayahStart`/
    // `.ayahEnd` call site (~150+ across the app) is untouched.
    public var work: Int { surah }
    public var unitStart: Int { ayahStart }
    public var unitEnd: Int { ayahEnd }

    public init?(surah: Int, ayahStart: Int, ayahEnd: Int) {
        guard QuranSurahValidation.isValidSurah(surah), ayahStart >= 1, ayahEnd >= ayahStart else { return nil }
        self.surah = surah
        self.ayahStart = ayahStart
        self.ayahEnd = ayahEnd
    }

    /// Content-index terminology for the same validated coordinates.
    public init?(work: Int, unitStart: Int, unitEnd: Int) {
        self.init(surah: work, ayahStart: unitStart, ayahEnd: unitEnd)
    }

    public init?(json: JSONValue) {
        guard let obj = json.objectValue,
              let s = obj["surah"]?.intValue,
              let a = obj["ayah_start"]?.intValue,
              let b = obj["ayah_end"]?.intValue
        else { return nil }
        self.init(surah: s, ayahStart: a, ayahEnd: b)
    }

    /// Normalized stream form: `{surah}:{ayah_start}-{ayah_end}` (ENGINE_PARITY §3).
    public var streamForm: String { "\(surah):\(ayahStart)-\(ayahEnd)" }
    public var description: String { streamForm }
}

public struct CanonicalPosition: Hashable, Sendable, CustomStringConvertible {
    public let surah: Int
    public let ayah: Int

    // MARK: Corpus-agnostic aliases (Batch 3 Stage 2 `ContentIndex`); see
    // `CanonicalRange`'s aliases above for rationale.
    public var work: Int { surah }
    public var unit: Int { ayah }

    public init?(surah: Int, ayah: Int) {
        guard QuranSurahValidation.isValidSurah(surah), ayah >= 1 else { return nil }
        self.surah = surah
        self.ayah = ayah
    }

    /// Generic-name constructor alias; see `CanonicalRange.init(work:unitStart:unitEnd:)`.
    public init?(work: Int, unit: Int) {
        self.init(surah: work, ayah: unit)
    }

    public init?(json: JSONValue) {
        guard let obj = json.objectValue,
              let s = obj["surah"]?.intValue,
              let a = obj["ayah"]?.intValue
        else { return nil }
        self.init(surah: s, ayah: a)
    }

    public var description: String { "\(surah):\(ayah)" }
}

public enum Strength: String, Hashable, Sendable {
    case strong, moderate, weak

    /// Scaled integer factor for workload math (ENGINE_SEMANTICS §1).
    public var scaledFactor: Int64 {
        switch self {
        case .weak: return 1500
        case .moderate: return 1200
        case .strong: return 1000
        }
    }
}

public struct DeclaredRange: Hashable, Sendable {
    public let range: CanonicalRange
    public let strength: Strength
    public let declaredBy: String

    public init(range: CanonicalRange, strength: Strength, declaredBy: String) {
        self.range = range
        self.strength = strength
        self.declaredBy = declaredBy
    }

    public init?(json: JSONValue) {
        guard let obj = json.objectValue,
              let rangeJSON = obj["range"], let range = CanonicalRange(json: rangeJSON),
              let strengthStr = obj["strength"]?.stringValue,
              let strength = Strength(rawValue: strengthStr)
        else { return nil }
        self.init(range: range, strength: strength, declaredBy: obj["declared_by"]?.stringValue ?? "self")
    }
}

public struct LearnerStartingState: Hashable, Sendable {
    public let memorizedRanges: [DeclaredRange]
    public let placementCursor: CanonicalPosition

    public init(memorizedRanges: [DeclaredRange], placementCursor: CanonicalPosition) {
        self.memorizedRanges = memorizedRanges
        self.placementCursor = placementCursor
    }

    public init?(json: JSONValue) {
        guard let obj = json.objectValue,
              let cursorJSON = obj["placement_cursor"], let cursor = CanonicalPosition(json: cursorJSON)
        else { return nil }
        var declared: [DeclaredRange] = []
        for item in obj["memorized_ranges"]?.arrayValue ?? [] {
            guard let d = DeclaredRange(json: item) else { return nil }
            declared.append(d)
        }
        self.init(memorizedRanges: declared, placementCursor: cursor)
    }
}
