package masoon.mushaf

/**
 * Pure RTL page-order math. Every function is a plain value transform — no Composable, no
 * gesture types — so page ordering is exhaustively unit-testable without a rendered view.
 */
object MushafPaging {
    /**
     * A direction in terms of PAGE NUMBER, not screen side. Screen side is RTL-mirrored; page
     * number order is not — page 604 is the last page regardless of which edge "next" is on.
     */
    enum class Direction {
        /** Deeper into the muṣḥaf: page number increases. */
        FORWARD,

        /** Back toward the beginning: page number decreases. */
        BACKWARD,
    }

    /**
     * Which third of the page width a tap fell into. The centre never pages — it is reserved
     * for the chrome toggle, a decision the caller applies rather than this geometry function.
     */
    enum class TapZone { LEFT, CENTER, RIGHT }

    /** Default edge width: 15% per side, leaving 70% of the page reliably "touch the text". */
    const val DEFAULT_EDGE_FRACTION: Float = 0.15f

    /**
     * [edgeFraction] is the fraction of [pageWidth] reserved for each edge zone. An [x] outside
     * `0..pageWidth` clamps to the nearest zone rather than failing.
     *
     * The fraction was narrowed from 0.3 to 0.15 on iOS to cut interaction friction, and this
     * port keeps the corrected value. At 0.3, 60% of the page was a page-turn trap, and whether
     * a tap turned the page or selected an āyah depended on whether it landed on a glyph or in
     * the space beside it — a distinction the reader cannot see and so cannot aim for. Swipe is
     * the primary page-turn gesture; the edge zones are a convenience strip.
     */
    fun tapZone(
        x: Float,
        pageWidth: Float,
        edgeFraction: Float = DEFAULT_EDGE_FRACTION,
    ): TapZone {
        if (pageWidth <= 0f) return TapZone.CENTER
        val clamped = edgeFraction.coerceIn(0f, 0.5f)
        return when {
            x < pageWidth * clamped -> TapZone.LEFT
            x > pageWidth * (1 - clamped) -> TapZone.RIGHT
            else -> TapZone.CENTER
        }
    }

    /**
     * RTL page order.
     *
     * A muṣḥaf is bound on the RIGHT. Reading advances leftward across the spread, so the page
     * being moved toward sits to the right of the spine and the leaf sweeps RIGHTWARD — the
     * same motion as turning a page in any Arabic book. In a single-page pager that makes the
     * RIGHT edge "next" and the LEFT edge "previous": the mirror image of a Latin book.
     *
     * iOS shipped this inverted in 2.0(1), derived from the module plan's shorthand "page N+1
     * is to the LEFT". Read against a real muṣḥaf, that shorthand describes where the next page
     * sits on an open two-page SPREAD, not which way a single-page pager advances. It was
     * founder-reported as backwards and corrected; this port starts from the corrected form.
     */
    fun direction(forTapZone: TapZone): Direction? =
        when (forTapZone) {
            TapZone.RIGHT -> Direction.FORWARD
            TapZone.LEFT -> Direction.BACKWARD
            TapZone.CENTER -> null
        }

    /**
     * The same RTL order applied to a horizontal drag. `dx > 0` means the finger swept RIGHT,
     * the direction a leaf turns in a right-bound muṣḥaf, so FORWARD. Translations under
     * [minimumDistance] are not a deliberate swipe and resolve to `null`.
     */
    fun direction(
        forSwipeTranslationX: Float,
        minimumDistance: Float = 40f,
    ): Direction? =
        when {
            forSwipeTranslationX >= minimumDistance -> Direction.FORWARD
            forSwipeTranslationX <= -minimumDistance -> Direction.BACKWARD
            else -> null
        }

    /**
     * The destination page, or `null` at either boundary — the pager never wraps, and page 604
     * swiping forward does nothing rather than landing on page 1.
     */
    fun destinationPage(
        from: Int,
        direction: Direction,
        pageCount: Int,
    ): Int? {
        if (pageCount < 1 || from < 1 || from > pageCount) return null
        return when (direction) {
            Direction.FORWARD -> if (from < pageCount) from + 1 else null
            Direction.BACKWARD -> if (from > 1) from - 1 else null
        }
    }

    /** Odd page on the right, following even page on the left (D-230). */
    fun spreadPages(
        containing: Int,
        pageCount: Int,
    ): Pair<Int, Int>? {
        if (containing !in 1..pageCount || pageCount < 2) return null
        val right = if (containing % 2 == 1) containing else containing - 1
        val left = right + 1
        return if (left <= pageCount) left to right else null
    }

    /** Turns a two-page spread without re-pairing its leaves. */
    fun spreadDestination(
        containing: Int,
        direction: Direction,
        pageCount: Int,
    ): Int? {
        val spread = spreadPages(containing, pageCount) ?: return null
        val right = spread.second
        val nextRight = if (direction == Direction.FORWARD) right + 2 else right - 2
        return nextRight.takeIf { it in 1..pageCount && spreadPages(it, pageCount) != null }
    }

    /**
     * Adjacent page numbers to prefetch, clamped to `1..pageCount`. Deliberately independent of
     * RTL: prefetching is about which page NUMBERS are near, not which screen side they land on.
     */
    fun prefetchPages(
        around: Int,
        pageCount: Int,
    ): List<Int> {
        if (pageCount < 1 || around < 1 || around > pageCount) return emptyList()
        return listOf(around - 1, around + 1).filter { it in 1..pageCount }
    }
}
