package masoon.curriculum

import masoon.domain.CanonicalRange
import masoon.domain.ContentIndex
import masoon.domain.DeclaredRange
import masoon.domain.LearnerStartingState
import masoon.domain.Strength

/**
 * B7-C (gate 4 simulation): the three canonical [LearnerStartingState] profiles a curriculum
 * simulation ([CurriculumSimulator]) runs a draft curriculum against — Kotlin port of
 * `apps/ios/Packages/Sources/MasoonCurriculum/SimulationProfiles.swift`. Every profile is computed
 * generically off [ContentIndex]'s global/boundary geometry — never a hardcoded Qur'an
 * surah/ayah literal — so the same three definitions work for whatever corpus a
 * [CompiledCurriculum] is actually paired with.
 */
enum class SimulationProfile {
    /**
     * No prior memorization; cursor at the very first content unit. Mirrors the real fixture
     * convention for a brand-new plan: `memorized_ranges: []`, `placement_cursor: {surah:1, ayah:1}`.
     */
    FRESH,

    /**
     * A partial ḥāfiẓ: a meaningful chunk already memorized, cursor pointing at the next
     * unmemorized unit. Chosen amount: the first 10 of the Qur'an's 30 juz (the lower bound of
     * boundary 11 — everything strictly before juz 11 begins). 10/30 is a round third:
     * comfortably "mid-curriculum" regardless of a given built-in's pacing, and — like every
     * other profile here — computed from real corpus geometry, not invented.
     */
    MID,

    /**
     * Fully memorized, maintenance-only. This is the profile curricula like `muraja-only`/
     * `seven-manzil` are actually designed for — real fixtures declare every surah 1-114 fully
     * memorized with `strength: "strong"` and place the cursor at the corpus's very LAST unit
     * (114:6 for the Qur'an) rather than one past the end — mirrored exactly here.
     */
    HAFIZ,
    ;

    override fun toString(): String = name.lowercase()

    /** Builds this profile's starting state against [index]. */
    fun startingState(index: ContentIndex): LearnerStartingState = when (this) {
        FRESH -> LearnerStartingState(emptyList(), index.positionOfGlobal(0))
        MID -> {
            val cutover = midCutoverGlobal(index)
            LearnerStartingState(declaredRanges(index, cutover), index.positionOfGlobal(cutover))
        }
        HAFIZ -> {
            val total = index.totalUnits
            LearnerStartingState(declaredRanges(index, total), index.positionOfGlobal(maxOf(0, total - 1)))
        }
    }

    companion object {
        /**
         * MID's cutover, in global-id space: the start of boundary 11 (Qur'an: juz 11), i.e. juz
         * 1-10 fully declared. A corpus with fewer than 11 boundaries (never true for the Qur'an)
         * falls back to one third of its total units so MID stays a meaningful "some but not all"
         * chunk instead of crashing.
         */
        internal fun midCutoverGlobal(index: ContentIndex): Int = index.boundaryGlobalRange(11)?.first ?: (index.totalUnits / 3)

        /**
         * Declares global units `[0, cutover)` as fully memorized (`strong`), grouped into one
         * [DeclaredRange] per contiguous same-work run.
         */
        internal fun declaredRanges(index: ContentIndex, upToGlobalExclusive: Int): List<DeclaredRange> {
            if (upToGlobalExclusive <= 0) return emptyList()
            val out = mutableListOf<DeclaredRange>()
            var runStart = 0
            var prevWork = index.workOfGlobal(0)
            fun flush(endGlobalInclusive: Int) {
                out += DeclaredRange(
                    range = CanonicalRange.ofWork(prevWork, index.unitOfGlobal(runStart), index.unitOfGlobal(endGlobalInclusive)),
                    strength = Strength.STRONG,
                    declaredBy = "curriculum_simulation",
                )
            }
            for (g in 1 until upToGlobalExclusive) {
                val w = index.workOfGlobal(g)
                if (w != prevWork) {
                    flush(g - 1)
                    runStart = g
                    prevWork = w
                }
            }
            flush(upToGlobalExclusive - 1)
            return out
        }
    }
}
