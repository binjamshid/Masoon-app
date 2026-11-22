package masoon.domain

/** Memorization order spec (policy input, D-005). */
sealed interface OrderSpec {
    data object MushafForward : OrderSpec

    /**
     * D-005 / ENGINE_SEMANTICS §2 normalized definition: juz blocks descending (30, 29, 28, ...),
     * surahs descending inside each juz block, ayahs ascending within a surah.
     */
    data object JuzAmmaBackward : OrderSpec

    data class CustomList(val list: List<CanonicalRange>) : OrderSpec
}

/** What "completion" means (policy.target_range). */
sealed interface TargetRange {
    data object FullQuran : TargetRange
    data class Ranges(val ranges: List<CanonicalRange>) : TargetRange
}

/**
 * A memorization order over the whole Quran: `seq[pos] = global ayah index`,
 * `pos[globalIdx] = order position` (or -1 if the ayah is not in the order — custom lists).
 */
class OrderIndex(val seq: IntArray, val pos: IntArray)

/**
 * Generic over any [ContentIndex] (Batch 3 Stage 2): [QuranIndex] today, [PoemIndex] proving a
 * second corpus walks the same order-building logic. [OrderSpec.JuzAmmaBackward]'s name stays
 * Qur'an-flavoured — it is curriculum POLICY vocabulary, not part of this file's generalization.
 */
fun buildOrder(spec: OrderSpec, index: ContentIndex): OrderIndex {
    val seq: IntArray = when (spec) {
        OrderSpec.MushafForward -> IntArray(index.totalUnits) { it }

        OrderSpec.JuzAmmaBackward -> {
            val out = IntArray(index.totalUnits)
            var k = 0
            for (j in index.boundaryCount downTo 1) {
                val range = index.boundaryGlobalRange(j)
                    ?: throw IllegalArgumentException("boundary $j missing from index")
                // group by work, work blocks descending, units ascending within a work
                val byWork = LinkedHashMap<Int, MutableList<Int>>()
                for (i in range) byWork.getOrPut(index.workOfGlobal(i)) { mutableListOf() }.add(i)
                for (s in byWork.keys.sortedDescending()) {
                    for (i in byWork.getValue(s)) out[k++] = i // ascending: insertion order is ascending
                }
            }
            out
        }

        is OrderSpec.CustomList -> {
            val seen = HashSet<Int>()
            val out = mutableListOf<Int>()
            for (r in spec.list) {
                val globals = index.globalRangeOf(r)
                    ?: throw IllegalArgumentException("custom_list range outside index bounds: $r")
                for (i in globals) {
                    require(seen.add(i)) { "custom_list ranges overlap at ayah ${index.positionOfGlobal(i)}" }
                    out.add(i)
                }
            }
            out.toIntArray()
        }
    }
    val pos = IntArray(index.totalUnits) { -1 }
    for ((p, i) in seq.withIndex()) pos[i] = p
    return OrderIndex(seq, pos)
}

/**
 * The new-hifz walk: the memorization order restricted to the target range.
 * Returns global ayah indices in memorization order.
 */
fun buildWalk(order: OrderIndex, target: TargetRange, index: ContentIndex): IntArray = when (target) {
    TargetRange.FullQuran -> order.seq
    is TargetRange.Ranges -> {
        val inTarget = BooleanArray(index.totalUnits)
        for (r in target.ranges) {
            val globals = index.globalRangeOf(r)
                ?: throw IllegalArgumentException("target_range outside index bounds: $r")
            for (i in globals) inTarget[i] = true
        }
        order.seq.filter { inTarget[it] }.toIntArray()
    }
}
