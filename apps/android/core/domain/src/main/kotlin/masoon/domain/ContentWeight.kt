package masoon.domain

/**
 * Micropage (µp) weight summation helpers (ENGINE_SEMANTICS §1: 1 page = [MICRO_PAGES_PER_PAGE] µp).
 *
 * Batch 3 Stage 3 (PC-10; Swift parity: `MasoonDomain/ContentWeight.swift`). The
 * `globalRange -> Σ weightOfGlobal` loop appears, subtly duplicated, wherever coverage,
 * plan-change diffs and forecast milestones need the size of a set of canonical ranges — this is
 * the single place that pattern now lives.
 *
 * These are the only µp sums that belong on a public, content-index-space surface. The engine's
 * own order-space sums (weights indexed by memorization-order position) are a deliberately
 * different, lower-level concern and stay inside `:core:curriculum`.
 */
object ContentWeight {

    /**
     * Sums `weights[g]` for every index `g` in `0 until min(values.size, weights.size)` whose
     * `values[g]` satisfies [predicate]. [values] and [weights] are dense, same-length,
     * per-global-unit arrays (a per-ayah state array paired with [QuranIndex.weightMicro] is the
     * canonical caller). A length mismatch contributes 0 for the excess on the longer side rather
     * than throwing, matching the defensive-by-construction style used elsewhere in the engine.
     */
    fun <T> microPages(values: List<T>, weights: LongArray, predicate: (T) -> Boolean): Long {
        var total = 0L
        val count = minOf(values.size, weights.size)
        for (g in 0 until count) {
            if (predicate(values[g])) total += weights[g]
        }
        return total
    }

    /**
     * Sums the µp weight of a set of canonical content ranges against any [ContentIndex] (Qur'an
     * today, a structurally different corpus tomorrow — see [PoemIndex]). A range with no valid
     * global mapping (outside the index's bounds) contributes 0, mirroring
     * [ContentIndex.globalRangeOf]'s null-is-out-of-bounds contract used throughout the engine.
     */
    fun microPages(ranges: List<CanonicalRange>, index: ContentIndex): Long {
        var total = 0L
        for (range in ranges) {
            val globals = index.globalRangeOf(range) ?: continue
            for (g in globals) total += index.weightOfGlobal(g)
        }
        return total
    }
}
