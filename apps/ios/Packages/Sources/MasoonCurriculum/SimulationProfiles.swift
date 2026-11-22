import MasoonDomain

/// CB-6: the three canonical `LearnerStartingState` profiles a curriculum
/// simulation (`CurriculumSimulator.swift`, gate 4 of the CB-5 pipeline)
/// runs a draft curriculum against. Every profile is computed generically
/// off `ContentIndex`'s global/boundary geometry (Batch 3 Stage 2) — never a
/// hardcoded Qur'an surah/ayah literal — so the same three definitions work
/// for whatever corpus a `CompiledCurriculum` is actually paired with.
///
/// `LearnerStartingState` itself (`MasoonDomain/Quran.swift`) is just
/// `{memorizedRanges: [DeclaredRange], placementCursor: CanonicalPosition}`.
public enum SimulationProfile: String, CaseIterable, Sendable, CustomStringConvertible {
    /// No prior memorization. The cursor starts at the first unit.
    case fresh

    /// Partial memorization. The cursor starts at boundary 11 if available,
    /// or one third of the way through the index.
    case mid

    /// Full memorization. The cursor starts at the last unit.
    case hafiz

    public var description: String { rawValue }

    /// Builds this profile's starting state against `index`.
    public func startingState(index: any ContentIndex) -> LearnerStartingState {
        switch self {
        case .fresh:
            return LearnerStartingState(memorizedRanges: [], placementCursor: index.position(ofGlobal: 0))
        case .mid:
            let cutover = SimulationProfile.midCutoverGlobal(index: index)
            return LearnerStartingState(
                memorizedRanges: SimulationProfile.declaredRanges(index: index, upToGlobalExclusive: cutover),
                placementCursor: index.position(ofGlobal: cutover))
        case .hafiz:
            let total = index.totalUnits
            return LearnerStartingState(
                memorizedRanges: SimulationProfile.declaredRanges(index: index, upToGlobalExclusive: total),
                placementCursor: index.position(ofGlobal: max(0, total - 1)))
        }
    }

    /// MID's cutover, in global-id space: the start of boundary 11 (Qur'an:
    /// juz 11), i.e. juz 1-10 fully declared. A corpus with fewer than 11
    /// boundaries (never true for the Qur'an — `QuranIndex.boundaryCount`
    /// is always 30; only a hypothetical future non-Qur'an corpus could
    /// trip this) falls back to one third of its total units so MID stays
    /// a meaningful "some but not all" chunk instead of crashing.
    static func midCutoverGlobal(index: any ContentIndex) -> Int {
        if let range = index.boundaryGlobalRange(11) { return range.lowerBound }
        return index.totalUnits / 3
    }

    /// Declares global units `[0, cutover)` as fully memorized (`strong`),
    /// grouped into one `DeclaredRange` per contiguous same-work run —
    /// independently mirrors `Engine.contentRanges`'s grouping (that method
    /// walks `MemorizationOrder` positions off a live `EngineRun`; this
    /// walks plain global ids directly, since a starting-state profile is
    /// built BEFORE any `EngineRun`/`MemorizationOrder` exists).
    static func declaredRanges(index: any ContentIndex, upToGlobalExclusive cutover: Int) -> [DeclaredRange] {
        guard cutover > 0 else { return [] }
        var out: [DeclaredRange] = []
        var runStart = 0
        var prevWork = index.workOfGlobal(0)
        func flush(endGlobalInclusive: Int) {
            out.append(DeclaredRange(
                range: CanonicalRange(
                    work: prevWork, unitStart: index.unitOfGlobal(runStart), unitEnd: index.unitOfGlobal(endGlobalInclusive))!,
                strength: .strong,
                declaredBy: "curriculum_simulation"))
        }
        for g in 1..<cutover {
            let w = index.workOfGlobal(g)
            if w != prevWork {
                flush(endGlobalInclusive: g - 1)
                runStart = g
                prevWork = w
            }
        }
        flush(endGlobalInclusive: cutover - 1)
        return out
    }
}
