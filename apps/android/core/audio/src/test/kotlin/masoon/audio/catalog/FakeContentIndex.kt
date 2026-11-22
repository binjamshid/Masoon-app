package masoon.audio.catalog

import masoon.domain.AmountResolution
import masoon.domain.CanonicalPosition
import masoon.domain.CanonicalRange
import masoon.domain.ContentIndex
import masoon.domain.QuranAmount

/**
 * A minimal [ContentIndex] conformer for [QuranAudioMappingTest]/[RangePlaybackPlanTest] — no
 * dependency on the real bundled `quran-ref.json` (that data lives in `:core:content`/`:core:data`,
 * which this module does not depend on). Two "works" using real, schema-valid surah numbers
 * ([CanonicalRange]/[CanonicalPosition] always validate `1..114`): work 1 has 3 units (global
 * `0..2`), work 2 has 5 units (global `3..7`). Ported from `QuranAudioMappingTests.swift`'s own
 * `FakeContentIndex`.
 */
class FakeContentIndex : ContentIndex {
    override val totalUnits: Int = 8

    override fun globalIndexOf(position: CanonicalPosition): Int? =
        when (position.work) {
            1 -> if (position.unit in 1..3) position.unit - 1 else null
            2 -> if (position.unit in 1..5) 2 + position.unit else null
            else -> null
        }

    override fun positionOfGlobal(g: Int): CanonicalPosition =
        if (g < 3) CanonicalPosition.ofWork(1, g + 1) else CanonicalPosition.ofWork(2, g - 2)

    override fun globalRangeOf(range: CanonicalRange): IntRange? =
        when (range.work) {
            1 -> if (range.unitStart >= 1 && range.unitEnd <= 3) (range.unitStart - 1)..(range.unitEnd - 1) else null
            2 -> if (range.unitStart >= 1 && range.unitEnd <= 5) (2 + range.unitStart)..(2 + range.unitEnd) else null
            else -> null
        }

    override fun workOfGlobal(g: Int): Int = if (g < 3) 1 else 2

    override fun unitOfGlobal(g: Int): Int = if (g < 3) g + 1 else g - 2

    override fun weightOfGlobal(g: Int): Long = 1

    override val boundaryKind: String = "test_boundary"

    override val boundaryCount: Int = 1

    override fun boundaryGlobalRange(n: Int): IntRange? = if (n == 1) 0..7 else null

    override fun boundaryOfGlobal(g: Int): Int = 1

    override val boundaryUnitMicroPages: Long? = null

    override fun amountMicroPages(amount: QuranAmount): AmountResolution = AmountResolution.Unsupported

    override val refChecksum: String = "fake"
}
