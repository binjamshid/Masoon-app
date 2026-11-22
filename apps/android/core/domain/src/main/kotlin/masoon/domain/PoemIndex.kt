package masoon.domain

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * A second [ContentIndex] implementation (Batch 3 Stage 2; Swift parity:
 * `MasoonDomain/PoemIndex.swift`), proving the curriculum engine generalizes past the Qur'an.
 * Parses ANY schema-valid `corpus-ref-v1` document (see
 * `contracts/json-schema/corpus-ref-v1.schema.json`, built by `tooling/poem-ref-build/build.js`)
 * into the same global-position / µp-weight shape [QuranIndex] exposes, over a corpus of titled
 * "works" made of "atomic units" (a poem collection's bayt; the DSL wire vocabulary still calls
 * the count-based amount style `ayah`/`custom`) rather than surahs and ayahs.
 *
 * Corpus titles, counts and edition metadata come from the supplied corpus document.
 */
class PoemIndex private constructor(
    val corpusId: String,
    /**
     * Which curriculum-v1 `meta.corpora` KIND token this concrete corpus instantiates ("poem") —
     * the join between the curriculum vocabulary and the corpus vocabulary (D-198).
     */
    val corpusKind: String,
    /** Corpus-level display name (the collection's name, not any single work's). */
    val titleAr: String,
    val titleEn: String?,
    val recension: String,
    val sourceSha256: String,
    val atomicUnit: String,
    private val boundaryKindRaw: String,
    /** In `no` order (founder-supplied global ordering). */
    val works: List<Work>,
) : ContentIndex {

    data class Work(
        /** 1-based founder-supplied ordering (corpus-ref-v1 `works[].no`). */
        val no: Int,
        val slug: String,
        val unitCount: Int,
        val titleAr: String,
        val titleEn: String?,
    )

    override val totalUnits: Int

    /** global unit id -> index into [works]. */
    private val workIndexOfGlobal: IntArray

    /** global unit id -> 1-based unit-within-work number. */
    private val unitNumberOfGlobal: IntArray

    /** [works] index (0-based) -> global id of its first unit. */
    private val workStartGlobal: IntArray

    init {
        workStartGlobal = IntArray(works.size)
        var running = 0
        for ((i, w) in works.withIndex()) {
            workStartGlobal[i] = running
            running += w.unitCount
        }
        totalUnits = running
        workIndexOfGlobal = IntArray(running)
        unitNumberOfGlobal = IntArray(running)
        var g = 0
        for ((i, w) in works.withIndex()) {
            for (u in 1..w.unitCount) {
                workIndexOfGlobal[g] = i
                unitNumberOfGlobal[g] = u
                g++
            }
        }
    }

    /** Global 0-based unit id for a (work `no`, 1-based unit) pair, or null when out of range. */
    fun globalIndexOf(work: Int, unit: Int): Int? {
        val i = works.indexOfFirst { it.no == work }
        if (i < 0 || unit < 1 || unit > works[i].unitCount) return null
        return workStartGlobal[i] + unit - 1
    }

    // ---- ContentIndex conformance --------------------------------------------------------------

    override fun globalIndexOf(position: CanonicalPosition): Int? = globalIndexOf(position.work, position.unit)

    override fun positionOfGlobal(g: Int): CanonicalPosition =
        CanonicalPosition.ofWork(works[workIndexOfGlobal[g]].no, unitNumberOfGlobal[g])

    override fun globalRangeOf(range: CanonicalRange): IntRange? {
        val start = globalIndexOf(range.work, range.unitStart) ?: return null
        val end = globalIndexOf(range.work, range.unitEnd) ?: return null
        return start..end
    }

    override fun workOfGlobal(g: Int): Int = works[workIndexOfGlobal[g]].no

    override fun unitOfGlobal(g: Int): Int = unitNumberOfGlobal[g]

    /**
     * Every atomic unit weighs the same — unlike a Qur'an ayah, whose weight varies with how many
     * ayahs share its mushaf page. The fixed 1 bayt = [UNIT_MICRO_PAGES] µp ruling.
     */
    override fun weightOfGlobal(g: Int): Long = UNIT_MICRO_PAGES

    override val boundaryKind: String get() = boundaryKindRaw

    /**
     * `corpus_block` / `work_boundary` (corpus-ref-v1): for this stage both map to per-work
     * boundaries — one work is one boundary block. A poem corpus has no juz-style sub-work
     * grouping; `work_boundary` is reserved (per the schema's own notes) for a later corpus
     * needing a boundary finer than a whole work, which nothing exercises yet.
     */
    override val boundaryCount: Int get() = works.size

    override fun boundaryGlobalRange(n: Int): IntRange? {
        if (n < 1 || n > works.size) return null
        val i = n - 1
        return workStartGlobal[i]..(workStartGlobal[i] + works[i].unitCount - 1)
    }

    override fun boundaryOfGlobal(g: Int): Int = workIndexOfGlobal[g] + 1

    /**
     * No fixed per-boundary µp size exists for this corpus: works vary widely in length, so a
     * "recent N boundaries" murājaʿah pool window is genuinely undefined here —
     * [ContentIndex.boundaryUnitMicroPages]'s documented null case, not a guessed fallback.
     */
    override val boundaryUnitMicroPages: Long? get() = null

    /**
     * Deliberately narrower than [QuranIndex.amountMicroPages]: only the corpus-invariant `page`
     * unit and the count-based `ayah`/`custom` units resolve. `line`/`juz`/`hizb`/`rub` have no
     * corpus-ref-v1 analogue for a poem collection and correctly hit PCC-3's
     * [AmountResolution.Unsupported] — proving the selector's thrown-error path is real, not just
     * theoretical, for a second implementation.
     */
    override fun amountMicroPages(amount: QuranAmount): AmountResolution = when (amount.unit) {
        AmountUnit.AYAH, AmountUnit.CUSTOM -> AmountResolution.CountUnit(amount.unitCount())
        AmountUnit.PAGE -> AmountResolution.MicroPages(amount.microPages())
        AmountUnit.LINE, AmountUnit.JUZ, AmountUnit.HIZB, AmountUnit.RUB -> AmountResolution.Unsupported
    }

    /**
     * The corpus-ref document's own provenance checksum (the build tool computes it from the
     * founder-supplied raw counts file; never re-derived here).
     */
    override val refChecksum: String get() = sourceSha256

    companion object {
        /**
         * µp size of one atomic unit (bayt), per the batch's fixed, integer-only ruling:
         * 1 bayt = 1 page / 10 = 100_000 µp. Cross-checked against the document's own
         * `unit_micropages`/`units_per_page` in [fromJson] rather than trusted blindly, so a
         * malformed or tampered corpus-ref document cannot silently smuggle in a different
         * per-unit size.
         */
        const val UNIT_MICRO_PAGES: Long = 100_000L
        const val UNITS_PER_PAGE: Int = 10

        /** Parses a corpus-ref-v1 document. Data boundary only: JSON never enters engine math. */
        fun fromJson(root: JsonObject): PoemIndex {
            fun str(key: String): String = root[key]?.jsonPrimitive?.contentOrNull
                ?: throw PoemIndexException("$key missing")

            val corpusId = str("corpus_id")
            val corpusKind = str("corpus_kind")
            // Required, not optional-with-a-fallback: the only fallback available would be echoing
            // `corpus_id` at the learner, and a corpus that cannot be named cannot honestly be
            // offered as a choice (D-198).
            val titleObj = root["title"]?.jsonObject ?: throw PoemIndexException("title missing")
            val titleAr = titleObj["ar"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotEmpty() }
                ?: throw PoemIndexException("title.ar missing")
            val recension = str("recension")
            val sourceSha256 = str("source_sha256")
            val atomicUnit = str("atomic_unit")
            val boundaryKind = str("boundary_kind")

            // Load-bearing batch-wide invariant (corpus-ref-v1 declares both `const`): re-checked
            // here rather than trusting the document's provenance.
            val unitsPerPage = root["units_per_page"]?.jsonPrimitive?.int
            if (unitsPerPage != UNITS_PER_PAGE) throw PoemIndexException("units_per_page must be $UNITS_PER_PAGE")
            val unitMicro = root["unit_micropages"]?.jsonPrimitive?.int?.toLong()
            if (unitMicro != UNIT_MICRO_PAGES) throw PoemIndexException("unit_micropages must be $UNIT_MICRO_PAGES")

            val worksJson = root["works"]?.jsonArray?.takeIf { it.isNotEmpty() }
                ?: throw PoemIndexException("works must be a non-empty array")
            val works = worksJson.map { parseWork(it.jsonObject) }.sortedBy { it.no }

            // The build tool's cross-field invariant check already rejects duplicates before a
            // document is ever written; re-validated here since this index must not trust its
            // input file's provenance blindly.
            val seenNo = HashSet<Int>()
            val seenSlug = HashSet<String>()
            for (w in works) {
                if (!seenNo.add(w.no)) throw PoemIndexException("duplicate works[].no = ${w.no}")
                if (!seenSlug.add(w.slug)) throw PoemIndexException("duplicate works[].slug = \"${w.slug}\"")
            }

            return PoemIndex(
                corpusId = corpusId,
                corpusKind = corpusKind,
                titleAr = titleAr,
                titleEn = titleObj["en"]?.jsonPrimitive?.contentOrNull,
                recension = recension,
                sourceSha256 = sourceSha256,
                atomicUnit = atomicUnit,
                boundaryKindRaw = boundaryKind,
                works = works,
            )
        }

        private fun parseWork(o: JsonObject): Work {
            val no = o["no"]?.jsonPrimitive?.int
            val slug = o["slug"]?.jsonPrimitive?.contentOrNull
            val unitCount = o["unit_count"]?.jsonPrimitive?.int
            val title = o["title"]?.jsonObject
            val titleAr = title?.get("ar")?.jsonPrimitive?.contentOrNull
            if (no == null || no < 1 || slug == null || unitCount == null || unitCount < 1 || titleAr == null) {
                throw PoemIndexException("bad entry in works[]")
            }
            return Work(no, slug, unitCount, titleAr, title["en"]?.jsonPrimitive?.contentOrNull)
        }
    }
}

/** A corpus-ref document that cannot be trusted as an index. */
class PoemIndexException(message: String) : IllegalArgumentException("corpus-ref error: $message")
