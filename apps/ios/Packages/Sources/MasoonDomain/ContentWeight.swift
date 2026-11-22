/// Micropage (µp) weight summation helpers (ENGINE_SEMANTICS §1: 1 page =
/// 1_000_000 µp; see `Micropage.swift`).
///
/// These sums operate on global content indexes, independently of
/// memorization order.
public enum ContentWeight {
    /// Sums `weights[g]` for every index `g` in `0..<min(values.count,
    /// weights.count)` whose `values[g]` satisfies `predicate`. `values` and
    /// `weights` are dense, same-length, per-global-unit arrays —
    /// `ProgressAnalytics.coverage`'s per-ayah `states` array paired with
    /// `QuranIndex.weightOfGlobal` is the canonical caller. A length
    /// mismatch contributes 0 for the excess on the longer side rather than
    /// trapping, matching the defensive-by-construction style used
    /// elsewhere in this package (e.g. `EngineRun`'s boundary-count guards).
    public static func micropages<T>(
        where predicate: (T) -> Bool,
        values: [T],
        weights: [Int64]
    ) -> Int64 {
        var total: Int64 = 0
        let count = min(values.count, weights.count)
        var g = 0
        while g < count {
            if predicate(values[g]) { total += weights[g] }
            g += 1
        }
        return total
    }

    /// Sums the µp weight of a set of canonical content ranges against a
    /// `ContentIndex` (any corpus — Qur'an today, a structurally different
    /// corpus tomorrow, PoemIndex.swift). A range with no valid global
    /// mapping (out of the index's bounds) contributes 0, mirroring
    /// `globalRange(of:)`'s existing nil-is-out-of-bounds contract used
    /// throughout the engine (Engine.swift, Forecaster.swift).
    public static func micropages<Index: ContentIndex>(
        of ranges: [CanonicalRange],
        index: Index
    ) -> Int64 {
        var total: Int64 = 0
        for range in ranges {
            guard let globals = index.globalRange(of: range) else { continue }
            for g in globals {
                total += index.weight(ofGlobal: g)
            }
        }
        return total
    }
}
