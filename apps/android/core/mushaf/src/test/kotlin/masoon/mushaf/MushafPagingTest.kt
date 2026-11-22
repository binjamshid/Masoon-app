package masoon.mushaf

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class MushafPagingTest {
    // --- tap zones -------------------------------------------------------------------------

    @Test
    fun `a tap in the left 15 percent is the left zone`() {
        assertEquals(MushafPaging.TapZone.LEFT, MushafPaging.tapZone(x = 10f, pageWidth = 1000f))
    }

    @Test
    fun `a tap in the right 15 percent is the right zone`() {
        assertEquals(MushafPaging.TapZone.RIGHT, MushafPaging.tapZone(x = 990f, pageWidth = 1000f))
    }

    @Test
    fun `the middle 70 percent is the centre zone and never pages`() {
        // The whole point of narrowing the edges from 0.3 to 0.15: everything from 150 to 850
        // must be "touch the text", not a page-turn trap.
        listOf(151f, 400f, 500f, 700f, 849f).forEach { x ->
            assertEquals(
                MushafPaging.TapZone.CENTER,
                MushafPaging.tapZone(x = x, pageWidth = 1000f),
                "x=$x should be the centre zone",
            )
        }
        assertNull(MushafPaging.direction(forTapZone = MushafPaging.TapZone.CENTER))
    }

    @Test
    fun `an out-of-bounds x clamps to the nearest zone rather than failing`() {
        assertEquals(MushafPaging.TapZone.LEFT, MushafPaging.tapZone(x = -50f, pageWidth = 1000f))
        assertEquals(MushafPaging.TapZone.RIGHT, MushafPaging.tapZone(x = 5000f, pageWidth = 1000f))
    }

    @Test
    fun `a zero-width page resolves to centre instead of dividing by zero`() {
        assertEquals(MushafPaging.TapZone.CENTER, MushafPaging.tapZone(x = 0f, pageWidth = 0f))
    }

    // --- RTL direction ---------------------------------------------------------------------

    @Test
    fun `the right edge advances and the left edge goes back - a mushaf is bound on the right`() {
        // This is the assertion that would have caught iOS's inverted 2.0(1) gesture. A muṣḥaf
        // is right-bound, so the leaf sweeps rightward to advance: RIGHT is forward.
        assertEquals(
            MushafPaging.Direction.FORWARD,
            MushafPaging.direction(forTapZone = MushafPaging.TapZone.RIGHT),
        )
        assertEquals(
            MushafPaging.Direction.BACKWARD,
            MushafPaging.direction(forTapZone = MushafPaging.TapZone.LEFT),
        )
    }

    @Test
    fun `a rightward swipe advances and a leftward swipe goes back`() {
        assertEquals(
            MushafPaging.Direction.FORWARD,
            MushafPaging.direction(forSwipeTranslationX = 60f),
        )
        assertEquals(
            MushafPaging.Direction.BACKWARD,
            MushafPaging.direction(forSwipeTranslationX = -60f),
        )
    }

    @Test
    fun `a swipe shorter than the minimum distance is not a deliberate page turn`() {
        assertNull(MushafPaging.direction(forSwipeTranslationX = 39f))
        assertNull(MushafPaging.direction(forSwipeTranslationX = -39f))
        assertNull(MushafPaging.direction(forSwipeTranslationX = 0f))
    }

    // --- destination and prefetch ----------------------------------------------------------

    @Test
    fun `the pager never wraps at either boundary`() {
        assertNull(
            MushafPaging.destinationPage(from = 604, MushafPaging.Direction.FORWARD, pageCount = 604),
        )
        assertNull(
            MushafPaging.destinationPage(from = 1, MushafPaging.Direction.BACKWARD, pageCount = 604),
        )
    }

    @Test
    fun `an ordinary page advances and retreats by one`() {
        assertEquals(
            256,
            MushafPaging.destinationPage(from = 255, MushafPaging.Direction.FORWARD, pageCount = 604),
        )
        assertEquals(
            254,
            MushafPaging.destinationPage(from = 255, MushafPaging.Direction.BACKWARD, pageCount = 604),
        )
    }

    @Test
    fun `malformed input yields no destination rather than an exception`() {
        assertNull(MushafPaging.destinationPage(0, MushafPaging.Direction.FORWARD, 604))
        assertNull(MushafPaging.destinationPage(605, MushafPaging.Direction.FORWARD, 604))
        assertNull(MushafPaging.destinationPage(1, MushafPaging.Direction.FORWARD, 0))
    }

    @Test
    fun `prefetch returns both numeric neighbours clamped to the mushaf`() {
        assertEquals(listOf(254, 256), MushafPaging.prefetchPages(around = 255, pageCount = 604))
        assertEquals(listOf(2), MushafPaging.prefetchPages(around = 1, pageCount = 604))
        assertEquals(listOf(603), MushafPaging.prefetchPages(around = 604, pageCount = 604))
        assertEquals(emptyList<Int>(), MushafPaging.prefetchPages(around = 700, pageCount = 604))
    }

    @Test
    fun `tablet spreads put odd leaf right and even leaf left without re-pairing`() {
        assertEquals(2 to 1, MushafPaging.spreadPages(containing = 1, pageCount = 604))
        assertEquals(26 to 25, MushafPaging.spreadPages(containing = 26, pageCount = 604))
        assertEquals(28 to 27, MushafPaging.spreadPages(containing = 27, pageCount = 604))
        assertEquals(27, MushafPaging.spreadDestination(25, MushafPaging.Direction.FORWARD, 604))
        assertEquals(23, MushafPaging.spreadDestination(25, MushafPaging.Direction.BACKWARD, 604))
    }
}
