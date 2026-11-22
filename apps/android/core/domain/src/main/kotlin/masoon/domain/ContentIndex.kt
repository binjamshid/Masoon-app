package masoon.domain

/**
 * Corpus-agnostic content index (Batch 3 Stage 2; Swift parity: `MasoonDomain/ContentIndex.swift`).
 *
 * [QuranIndex] used to be the engine's only content index, and `:core:curriculum` hardcoded it.
 * This interface extracts exactly the surface the engine actually consumes, so the SAME engine can
 * run over a second, structurally different corpus (a poem/manẓūma collection — [PoemIndex])
 * without ever knowing which one it holds.
 *
 * Vocabulary mapping (Qur'an term -> generic term):
 * - surah -> work     (a titled subdivision of the corpus)
 * - ayah  -> unit     (the atomic memorization element)
 * - juz   -> boundary (a structural grouping that fires "end of N" triggers, R-J1/R-J2)
 *
 * [CanonicalRange] / [CanonicalPosition] keep their `surah`/`ayahStart`/`ayahEnd`/`ayah` stored
 * properties and JSON wire keys unchanged (ENGINE_PARITY §3 byte-freeze) and gain
 * `work`/`unitStart`/`unitEnd`/`unit` as additive read aliases for this interface's generic callers.
 *
 * Ranges are Kotlin-idiomatic INCLUSIVE [IntRange]s (matching [QuranIndex.juzAyahRange] and
 * [QuranIndex.rangeIndices]), not Swift's half-open `Range<Int>` — same set of global ids either
 * way, and the whole Kotlin engine already speaks `IntRange`.
 */
interface ContentIndex {
    /** Total atomic content units in the corpus (Qur'an: ayahs; poem: abyāt). */
    val totalUnits: Int

    /** Global 0-based unit id for a canonical (work, unit) position, or null when out of range. */
    fun globalIndexOf(position: CanonicalPosition): Int?

    /** Canonical (work, unit) position for a global 0-based unit id. */
    fun positionOfGlobal(g: Int): CanonicalPosition

    /** Inclusive global-id range covered by a canonical range, or null when either endpoint is out of bounds. */
    fun globalRangeOf(range: CanonicalRange): IntRange?

    /** The work (surah-equivalent) containing global position [g]. */
    fun workOfGlobal(g: Int): Int

    /** The 1-based unit-within-work number (ayah-equivalent) at [g]. */
    fun unitOfGlobal(g: Int): Int

    /** µp weight of the atomic unit at global position [g] (ENGINE_SEMANTICS §1). */
    fun weightOfGlobal(g: Int): Long

    /**
     * Name of this corpus's structural boundary unit ("juz" for the Qur'an; "corpus_block" /
     * "work_boundary" for a poem collection, mirroring corpus-ref-v1's declared `boundary_kind`).
     * Descriptive only — the engine does not branch on this string; it is surfaced for
     * diagnostics/reporting.
     */
    val boundaryKind: String

    /** Count of structural boundaries (Qur'an: 30 juz). */
    val boundaryCount: Int

    /** Inclusive global-id range covering boundary [n] (1-based), or null when [n] is out of range. */
    fun boundaryGlobalRange(n: Int): IntRange?

    /** The boundary number (1-based) containing global position [g]. */
    fun boundaryOfGlobal(g: Int): Int

    /**
     * Nominal µp size of exactly one boundary unit, used only for "recent N boundaries" murājaʿah
     * pool windows (ENGINE_SEMANTICS §4 E-1b, D-043). Null when this corpus has no fixed
     * per-boundary µp constant (e.g. a poem corpus whose works vary widely in length) — callers
     * must treat null as "this pool-window kind is undefined for this corpus", never substitute a
     * guessed value.
     */
    val boundaryUnitMicroPages: Long?

    /**
     * Resolves a DSL amount to this corpus's selection unit (PCC-3).
     * [AmountResolution.Unsupported] is the only case new-hifz selection treats as a thrown,
     * distinguishable error (the unit genuinely does not apply to this corpus); a
     * resolvable-but-empty amount stays a legitimate null return from the caller, not `Unsupported`.
     */
    fun amountMicroPages(amount: QuranAmount): AmountResolution

    /** Checksum identifying the concrete reference document backing this index instance. */
    val refChecksum: String
}

/** Corpus-aware resolution of a [QuranAmount] to its engine-selection unit. See [ContentIndex.amountMicroPages]. */
sealed interface AmountResolution {
    /** Resolved to an exact micropage size (page/juz/hizb/rubʿ/line-style units). */
    data class MicroPages(val value: Long) : AmountResolution

    /**
     * Resolved to a plain atomic-unit count (ayah / custom-range-style units; selection walks by
     * count, not µp — ENGINE_SEMANTICS §1).
     */
    data class CountUnit(val value: Int) : AmountResolution

    /**
     * The unit does not apply to this corpus at all (PCC-3) — the caller throws rather than
     * silently treating it as "nothing to select".
     */
    data object Unsupported : AmountResolution
}
