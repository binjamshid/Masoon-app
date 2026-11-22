package masoon.audio.catalog

import masoon.domain.CanonicalRange
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows

/** Ported from `apps/ios/Packages/Tests/MasoonAudioTests/RangePlaybackPlanTests.swift`. */
class RangePlaybackPlanTest {
    private val index = FakeContentIndex()

    @Test
    fun `plan expands the range into units and carries reciter and corpus`() {
        val range = CanonicalRange.ofWork(1, 1, 3)
        val plan = QuranRangePlayback.plan(range, index, "alafasy", count = 2, displayTitle = "At-Tawbah")
        assertEquals("alafasy", plan.request.reciterId)
        assertEquals(Corpus.QURAN, plan.request.corpus)
        assertEquals(listOf(PlaybackUnit(1, 1), PlaybackUnit(1, 2), PlaybackUnit(1, 3)), plan.request.units)
        assertEquals(2, plan.request.repeatCount)
        assertEquals("At-Tawbah", plan.request.displayTitle)
    }

    @Test
    fun `default count is one and default pause and speed are neutral`() {
        val range = CanonicalRange.ofWork(1, 1, 1)
        val plan = QuranRangePlayback.plan(range, index, "alafasy", displayTitle = "x")
        assertEquals(1, plan.request.repeatCount)
        assertEquals(0L, plan.pauseBetweenRepeatsMillis)
        assertEquals(1.0f, plan.speed)
    }

    @Test
    fun `pause between repeats and speed are carried through unmodified`() {
        val range = CanonicalRange.ofWork(1, 1, 1)
        val plan =
            QuranRangePlayback.plan(
                range,
                index,
                "alafasy",
                count = 3,
                pauseBetweenMillis = 12_000,
                speed = 1.5f,
                displayTitle = "x",
            )
        assertEquals(12_000L, plan.pauseBetweenRepeatsMillis)
        assertEquals(1.5f, plan.speed)
    }

    @Test
    fun `negative pause between repeats is clamped to zero`() {
        val range = CanonicalRange.ofWork(1, 1, 1)
        val plan = QuranRangePlayback.plan(range, index, "alafasy", pauseBetweenMillis = -5_000, displayTitle = "x")
        assertEquals(0L, plan.pauseBetweenRepeatsMillis)
    }

    @Test
    fun `out of range range propagates the mapping error`() {
        val range = CanonicalRange.ofWork(2, 1, 9)
        assertThrows<QuranAudioMappingException> {
            QuranRangePlayback.plan(range, index, "alafasy", displayTitle = "x")
        }
    }

    @Test
    fun `multi range overload concatenates in order`() {
        val rangeA = CanonicalRange.ofWork(1, 2, 3)
        val rangeB = CanonicalRange.ofWork(2, 1, 2)
        val plan = QuranRangePlayback.plan(listOf(rangeA, rangeB), index, "alafasy", displayTitle = "x")
        assertEquals(
            listOf(PlaybackUnit(1, 2), PlaybackUnit(1, 3), PlaybackUnit(2, 1), PlaybackUnit(2, 2)),
            plan.request.units,
        )
    }

    @Test
    fun `display subtitle is carried through verbatim when provided`() {
        val range = CanonicalRange.ofWork(1, 1, 1)
        val plan = QuranRangePlayback.plan(range, index, "alafasy", displayTitle = "x", displaySubtitle = "y")
        assertEquals("y", plan.request.displaySubtitle)
    }
}
