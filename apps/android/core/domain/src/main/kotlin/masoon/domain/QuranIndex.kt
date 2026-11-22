package masoon.domain

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Qur'an-specific surah-range validator (ENGINE_PARITY §3), factored out of
 * [CanonicalRange]/[CanonicalPosition]'s own `init` blocks (Quran.kt) so that now-corpus-generic
 * file — which also carries the `work`/`unitStart`/`unitEnd`/`unit` aliases — does not itself
 * spell out a Qur'an-only structural constant. Behaviour is identical to the previous inline
 * `surah in 1..114` guard: a pure location move, not a relaxation. A poem/other corpus never
 * reuses this validator ([PoemIndex] validates its own work numbers independently).
 */
object QuranSurahValidation {
    const val SURAH_COUNT: Int = 114

    fun isValidSurah(surah: Int): Boolean = surah in 1..SURAH_COUNT
}

/**
 * Canonical Quran reference index (Hafs v1, Tanzil-derived; quran-ref.json markers).
 * Provides per-ayah juz / rub / page projections and micropage weights (ENGINE_SEMANTICS §1):
 * `weight(a) = 1_000_000 / n_p` (integer division) where n_p = ayah count on ayah a's page.
 *
 * The engine never hardcodes boundary positions; everything derives from the loaded markers.
 */
class QuranIndex private constructor(
    val surahAyahCounts: IntArray,
    juzStarts: List<IntArray>,
    rubStarts: List<IntArray>,
    pageStarts: List<IntArray>,
) : ContentIndex {
    val surahCount: Int get() = surahAyahCounts.size
    val totalAyahs: Int

    /** Global 0-based index of (surah, 1) for each surah (1-based surah -> offset). */
    private val surahOffsets: IntArray

    /** Per-ayah (global index) projections, 1-based unit numbers. */
    val juzOfAyah: IntArray
    val rubOfAyah: IntArray
    val pageOfAyah: IntArray

    /** Per-ayah micropage weight. */
    val weightMicro: LongArray

    val juzCount: Int
    private val juzStartIdx: IntArray // juz j (1-based) starts at global index juzStartIdx[j-1]

    init {
        require(surahAyahCounts.size == 114) { "expected 114 surahs, got ${surahAyahCounts.size}" }
        surahOffsets = IntArray(115)
        var acc = 0
        for (s in 1..114) {
            surahOffsets[s] = acc
            acc += surahAyahCounts[s - 1]
        }
        totalAyahs = acc

        fun markerIdx(m: IntArray): Int = globalIndex(m[1], m[2])
        fun fill(markers: List<IntArray>): IntArray {
            val sorted = markers.sortedBy { it[0] }
            val out = IntArray(totalAyahs)
            for ((k, m) in sorted.withIndex()) {
                val from = markerIdx(m)
                val to = if (k + 1 < sorted.size) markerIdx(sorted[k + 1]) else totalAyahs
                require(from < to) { "invalid marker ordering at unit ${m[0]}" }
                for (i in from until to) out[i] = m[0]
            }
            return out
        }

        juzOfAyah = fill(juzStarts)
        rubOfAyah = fill(rubStarts)
        pageOfAyah = fill(pageStarts)
        juzCount = juzStarts.size
        juzStartIdx = juzStarts.sortedBy { it[0] }.map { globalIndex(it[1], it[2]) }.toIntArray()

        // micropage weights: 1_000_000 / (ayah count on the ayah's projection page)
        val pageCounts = HashMap<Int, Int>()
        for (p in pageOfAyah) pageCounts[p] = (pageCounts[p] ?: 0) + 1
        weightMicro = LongArray(totalAyahs) { i -> MICRO_PAGES_PER_PAGE / pageCounts.getValue(pageOfAyah[i]) }
    }

    fun ayahCount(surah: Int): Int {
        require(surah in 1..114) { "surah out of range: $surah" }
        return surahAyahCounts[surah - 1]
    }

    /** Global 0-based ayah index. */
    fun globalIndex(surah: Int, ayah: Int): Int {
        require(surah in 1..114) { "surah out of range: $surah" }
        require(ayah in 1..ayahCount(surah)) { "ayah out of range: $surah:$ayah" }
        return surahOffsets[surah] + (ayah - 1)
    }

    fun globalIndex(pos: CanonicalPosition): Int = globalIndex(pos.surah, pos.ayah)

    fun positionOf(globalIdx: Int): CanonicalPosition {
        require(globalIdx in 0 until totalAyahs) { "global index out of range: $globalIdx" }
        var lo = 1
        var hi = 114
        while (lo < hi) {
            val mid = (lo + hi + 1) / 2
            if (surahOffsets[mid] <= globalIdx) lo = mid else hi = mid - 1
        }
        return CanonicalPosition(lo, globalIdx - surahOffsets[lo] + 1)
    }

    fun surahOf(globalIdx: Int): Int = positionOf(globalIdx).surah

    /** Global ayah index range of juz j (contiguous in mushaf order). */
    fun juzAyahRange(juz: Int): IntRange {
        require(juz in 1..juzCount) { "juz out of range: $juz" }
        val from = juzStartIdx[juz - 1]
        val to = if (juz < juzCount) juzStartIdx[juz] - 1 else totalAyahs - 1
        return from..to
    }

    /** All global ayah indices of a canonical range, ascending. */
    fun rangeIndices(range: CanonicalRange): IntRange {
        require(range.ayahEnd <= ayahCount(range.surah)) { "range past surah end: $range" }
        return globalIndex(range.surah, range.ayahStart)..globalIndex(range.surah, range.ayahEnd)
    }

    /** Σ weight over the range, in µp. */
    fun rangeSizeMicro(range: CanonicalRange): Long {
        var sum = 0L
        for (i in rangeIndices(range)) sum += weightMicro[i]
        return sum
    }

    // ---- ContentIndex conformance (Batch 3 Stage 2) -------------------------------------------
    //
    // Purely additive: every member above stays exactly as it was for the call sites that hold a
    // concrete QuranIndex. This section only maps them onto the corpus-agnostic surface that
    // :core:curriculum is written against. Nothing here computes anything new — each override
    // delegates to the existing member, so µp values and boundary maths are unchanged by
    // construction.

    override val totalUnits: Int get() = totalAyahs

    override fun globalIndexOf(position: CanonicalPosition): Int? =
        if (position.surah in 1..surahCount && position.ayah in 1..ayahCount(position.surah)) {
            globalIndex(position.surah, position.ayah)
        } else {
            null
        }

    override fun positionOfGlobal(g: Int): CanonicalPosition = positionOf(g)

    override fun globalRangeOf(range: CanonicalRange): IntRange? {
        if (range.surah !in 1..surahCount) return null
        if (range.ayahEnd > ayahCount(range.surah)) return null
        return rangeIndices(range)
    }

    override fun workOfGlobal(g: Int): Int = surahOf(g)

    override fun unitOfGlobal(g: Int): Int = positionOf(g).ayah

    override fun weightOfGlobal(g: Int): Long = weightMicro[g]

    override val boundaryKind: String get() = "juz"

    override val boundaryCount: Int get() = juzCount

    override fun boundaryGlobalRange(n: Int): IntRange? = if (n in 1..juzCount) juzAyahRange(n) else null

    override fun boundaryOfGlobal(g: Int): Int = juzOfAyah[g]

    /**
     * Nominal per-juz µp size, used only for "recent N juz" murājaʿah pool windows (E-1b) — NOT
     * derived from actual per-juz ayah weights (those vary slightly by integer rounding). Same
     * fixed constant the engine has always used here.
     */
    override val boundaryUnitMicroPages: Long? get() = AmountUnit.JUZ.microPages

    /**
     * Mirrors [QuranAmount.microPages] / [QuranAmount.unitCount] exactly — fixture-parity-critical:
     * this must never grow its own arithmetic.
     */
    override fun amountMicroPages(amount: QuranAmount): AmountResolution = when (amount.unit) {
        AmountUnit.AYAH, AmountUnit.CUSTOM -> AmountResolution.CountUnit(amount.unitCount())
        else -> amount.unit.microPages
            ?.let { AmountResolution.MicroPages(amount.microPages()) }
            ?: AmountResolution.Unsupported
    }

    /**
     * Deterministic FNV-1a checksum over the structural marker data, identifying which
     * quran-ref.json content backs this index instance. Not cryptographic; a corpus-ref-v1
     * document's own `source_sha256` fills the same role for [PoemIndex]. Hand-rolled (no digest
     * library, no platform text formatting) so it stays byte-identical with the Swift engine.
     */
    override val refChecksum: String by lazy(LazyThreadSafetyMode.NONE) {
        var hash = FNV_OFFSET_BASIS
        fun mix(value: Int) {
            var v = value.toLong().toULong()
            repeat(8) {
                hash = hash xor (v and 0xffUL)
                hash *= FNV_PRIME
                v = v shr 8
            }
        }
        mix(totalAyahs)
        mix(juzCount)
        for (c in surahAyahCounts) mix(c)
        val out = CharArray(16)
        var v = hash
        for (i in 15 downTo 0) {
            out[i] = HEX_DIGITS[(v and 0xfUL).toInt()]
            v = v shr 4
        }
        String(out)
    }

    companion object {
        private val FNV_OFFSET_BASIS: ULong = 0xcbf2_9ce4_8422_2325UL
        private val FNV_PRIME: ULong = 0x0000_0100_0000_01b3UL
        private const val HEX_DIGITS = "0123456789abcdef"

        /** Loads contracts/fixtures/quran/quran-ref.json (data boundary; JSON never enters engine math). */
        fun fromJson(text: String): QuranIndex {
            val root = Json.parseToJsonElement(text).jsonObject
            val counts = root.getValue("surah_ayah_counts").jsonArray.map { it.jsonPrimitive.int }.toIntArray()
            fun markers(key: String): List<IntArray> =
                root.getValue(key).jsonArray.map { row ->
                    val a = row.jsonArray
                    intArrayOf(a[0].jsonPrimitive.int, a[1].jsonPrimitive.int, a[2].jsonPrimitive.int)
                }
            return QuranIndex(counts, markers("juz_starts"), markers("rub_starts"), markers("page_starts"))
        }
    }
}
