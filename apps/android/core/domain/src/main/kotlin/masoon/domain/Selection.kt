package masoon.domain

/**
 * Range arithmetic (PRD §7.8, ENGINE_SEMANTICS §2). Pure integer µp math; an ayah is never split.
 */

/** Overshoot tolerance for D-013: 40% of a page. */
const val OVERSHOOT_LIMIT_MICRO: Long = 400_000L

data class Selection(
    /** Selected global ayah indices, in walk (memorization) order. */
    val ayahs: IntArray,
    /** Coalesced canonical ranges in walk order. */
    val ranges: List<CanonicalRange>,
    /** Σ full weight, µp. */
    val sizeMicro: Long,
    /** Walk index just past the selection (new cursor). */
    val nextCursor: Int,
) {
    override fun equals(other: Any?): Boolean =
        other is Selection && ayahs.contentEquals(other.ayahs) && nextCursor == other.nextCursor

    override fun hashCode(): Int = ayahs.contentHashCode() * 31 + nextCursor
}

/**
 * Coalesce a traversal-ordered list of global ayah indices into canonical ranges:
 * consecutive global indices within the same surah merge; order of first appearance is kept.
 */
fun coalesceInTraversalOrder(ayahs: IntArray, index: ContentIndex): List<CanonicalRange> {
    if (ayahs.isEmpty()) return emptyList()
    val out = mutableListOf<CanonicalRange>()
    var startPos = index.positionOfGlobal(ayahs[0])
    var prevIdx = ayahs[0]
    for (k in 1 until ayahs.size) {
        val i = ayahs[k]
        val pos = index.positionOfGlobal(i)
        val prevPos = index.positionOfGlobal(prevIdx)
        if (i == prevIdx + 1 && pos.surah == prevPos.surah) {
            prevIdx = i
            continue
        }
        out.add(CanonicalRange(startPos.surah, startPos.ayah, prevPos.ayah))
        startPos = pos
        prevIdx = i
    }
    val prevPos = index.positionOfGlobal(prevIdx)
    out.add(CanonicalRange(startPos.surah, startPos.ayah, prevPos.ayah))
    return out
}

/** Coalesce an unordered ayah set into mushaf-ordered ranges (ledger unions, ENGINE_SEMANTICS §3). */
fun coalesceMushafOrder(ayahs: Collection<Int>, index: ContentIndex): List<CanonicalRange> =
    coalesceInTraversalOrder(ayahs.toSortedSet().toIntArray(), index)

/**
 * New-hifz selection (`next_new`, D-013/D-014, ENGINE_SEMANTICS §2/§11.13):
 * from cursor, walk ayahs in memorization order accumulating weight; stop at the smallest
 * ayah-aligned prefix with size >= amount_µp, unless overshoot > 400_000 µp -> drop the final
 * ayah (never below 1 ayah). D-014 applies at EVERY surah transition within the selection
 * (segment-by-segment ⅓ rule): truncate at the boundary unless the consumed segment of the
 * exiting surah is < amount/3 (then bridge into the next surah in order).
 */
fun nextNew(walk: IntArray, cursor: Int, amountMicro: Long, index: ContentIndex): Selection? {
    if (cursor >= walk.size || amountMicro <= 0L) return null
    val selected = mutableListOf<Int>()
    var acc = 0L
    var segAcc = 0L // weight consumed within the current surah segment
    var i = cursor
    var currentSurah = index.workOfGlobal(walk[cursor])
    while (i < walk.size) {
        val a = walk[i]
        val s = index.workOfGlobal(a)
        if (s != currentSurah) {
            // boundary reached with acc < amountMicro (otherwise we'd have stopped below)
            if (3L * segAcc >= amountMicro) break // truncate: segment >= amount/3
            currentSurah = s // bridge (segment < amount/3)
            segAcc = 0L
        }
        selected.add(a)
        acc += index.weightOfGlobal(a)
        segAcc += index.weightOfGlobal(a)
        i++
        if (acc >= amountMicro) {
            val overshoot = acc - amountMicro
            if (overshoot > OVERSHOOT_LIMIT_MICRO && selected.size > 1) {
                val dropped = selected.removeAt(selected.size - 1)
                acc -= index.weightOfGlobal(dropped)
                i--
            }
            break
        }
    }
    if (selected.isEmpty()) return null
    val arr = selected.toIntArray()
    return Selection(arr, coalesceInTraversalOrder(arr, index), acc, i)
}

/**
 * Ayah-count selection for `QuranAmount(unit=ayah)`: up to N walk ayahs, with the D-014
 * segment rule applied on ayah counts (ENGINE_SEMANTICS §11.13). Never splits an ayah.
 */
fun nextNewByAyahCount(walk: IntArray, cursor: Int, count: Int, index: ContentIndex): Selection? {
    if (cursor >= walk.size || count <= 0) return null
    val selected = mutableListOf<Int>()
    var segTaken = 0
    var i = cursor
    var currentSurah = index.workOfGlobal(walk[cursor])
    while (i < walk.size && selected.size < count) {
        val a = walk[i]
        val s = index.workOfGlobal(a)
        if (s != currentSurah) {
            if (3 * segTaken >= count) break // truncate: segment >= count/3
            currentSurah = s
            segTaken = 0
        }
        selected.add(a)
        segTaken++
        i++
    }
    if (selected.isEmpty()) return null
    val arr = selected.toIntArray()
    var acc = 0L
    for (a in arr) acc += index.weightOfGlobal(a)
    return Selection(arr, coalesceInTraversalOrder(arr, index), acc, i)
}

/**
 * Split a weighted ayah list into exactly `parts` near-equal µp slices (R-J1b,
 * ENGINE_SEMANTICS §5/§11.22): slice k = prefix(k) − prefix(k−1) where prefix(k) is the
 * smallest ayah-aligned prefix with cumulative weight >= k*total/parts (integer comparison
 * `cum*parts >= k*total`). Slices may be EMPTY and are preserved positionally (§11.22:
 * empty slices emit nothing and their day stays empty — non-empty slices never compact).
 */
fun splitNearEqual(ayahs: IntArray, weights: LongArray, parts: Int): List<IntArray> {
    require(parts >= 1) { "parts must be >= 1" }
    if (ayahs.isEmpty()) return List(parts) { IntArray(0) }
    var total = 0L
    for (w in weights) total += w
    val out = mutableListOf<IntArray>()
    var start = 0
    var cum = 0L
    var i = 0
    for (k in 1..parts) {
        while (i < ayahs.size && cum * parts < k * total) {
            cum += weights[i]
            i++
        }
        out.add(ayahs.copyOfRange(start, i))
        start = i
    }
    return out
}
