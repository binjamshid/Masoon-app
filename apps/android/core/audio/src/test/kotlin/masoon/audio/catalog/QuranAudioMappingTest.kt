package masoon.audio.catalog

import masoon.domain.CanonicalRange
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows

/** Ported from `apps/ios/Packages/Tests/MasoonAudioTests/QuranAudioMappingTests.swift`. */
class QuranAudioMappingTest {
    private val index = FakeContentIndex()

    @Test
    fun `single range within one work expands in order`() {
        val range = CanonicalRange.ofWork(1, 1, 3)
        val units = QuranAudioMapping.units(range, index)
        assertEquals(listOf(PlaybackUnit(1, 1), PlaybackUnit(1, 2), PlaybackUnit(1, 3)), units)
    }

    @Test
    fun `partial range within second work`() {
        val range = CanonicalRange.ofWork(2, 2, 4)
        val units = QuranAudioMapping.units(range, index)
        assertEquals(listOf(PlaybackUnit(2, 2), PlaybackUnit(2, 3), PlaybackUnit(2, 4)), units)
    }

    @Test
    fun `single ayah range expands to one unit`() {
        val range = CanonicalRange.ofWork(1, 2, 2)
        val units = QuranAudioMapping.units(range, index)
        assertEquals(listOf(PlaybackUnit(1, 2)), units)
    }

    @Test
    fun `multiple ranges concatenate in order`() {
        val rangeA = CanonicalRange.ofWork(1, 2, 3)
        val rangeB = CanonicalRange.ofWork(2, 1, 2)
        val units = QuranAudioMapping.units(listOf(rangeA, rangeB), index)
        assertEquals(
            listOf(PlaybackUnit(1, 2), PlaybackUnit(1, 3), PlaybackUnit(2, 1), PlaybackUnit(2, 2)),
            units,
        )
    }

    @Test
    fun `repeated range is not deduplicated`() {
        val range = CanonicalRange.ofWork(1, 1, 1)
        val units = QuranAudioMapping.units(listOf(range, range), index)
        assertEquals(listOf(PlaybackUnit(1, 1), PlaybackUnit(1, 1)), units)
    }

    @Test
    fun `out of range range throws with the offending range`() {
        // Work 2 in this fake index only has 5 units; asking for unit 9 is out of bounds.
        val range = CanonicalRange.ofWork(2, 1, 9)
        val error = assertThrows<QuranAudioMappingException> { QuranAudioMapping.units(range, index) }
        assertEquals(2, error.surah)
        assertEquals(1, error.ayahStart)
        assertEquals(9, error.ayahEnd)
    }

    @Test
    fun `empty ranges list returns empty playlist`() {
        val units = QuranAudioMapping.units(emptyList(), index)
        assertEquals(emptyList<PlaybackUnit>(), units)
    }
}
