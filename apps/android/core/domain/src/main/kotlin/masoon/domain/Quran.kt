package masoon.domain

/** One micropage (µp) = 10^-6 of a Madinah-15 page. All size math is integer µp (ENGINE_SEMANTICS §1). */
const val MICRO_PAGES_PER_PAGE: Long = 1_000_000L

/** The cursor: next new-hifz start. Riwayah implicit = hafs v1 in v1 contracts. */
data class CanonicalPosition(val surah: Int, val ayah: Int) {
    init {
        require(QuranSurahValidation.isValidSurah(surah)) { "surah out of range: $surah" }
        require(ayah >= 1) { "ayah out of range: $ayah" }
    }

    /** Corpus-agnostic read alias (Batch 3 Stage 2 [ContentIndex]); identical value, generic name. */
    val work: Int get() = surah

    /** Corpus-agnostic read alias (Batch 3 Stage 2 [ContentIndex]); identical value, generic name. */
    val unit: Int get() = ayah

    override fun toString(): String = "$surah:$ayah"

    companion object {
        /**
         * Generic-name factory for [ContentIndex]-driven engine code. Identical validation to the
         * primary constructor: today only [QuranIndex] actually drives plan generation, so that
         * guard never rejects a real call; a corpus whose work count could exceed 114 would need
         * its own validation path when it is actually wired into generation.
         */
        fun ofWork(work: Int, unit: Int): CanonicalPosition = CanonicalPosition(work, unit)
    }
}

/** Ordered, non-empty, single-surah canonical range. Multi-surah content is List<CanonicalRange>. */
data class CanonicalRange(val surah: Int, val ayahStart: Int, val ayahEnd: Int) {
    init {
        require(QuranSurahValidation.isValidSurah(surah)) { "surah out of range: $surah" }
        require(ayahStart >= 1) { "ayahStart out of range: $ayahStart" }
        require(ayahEnd >= ayahStart) { "empty/inverted range: $surah:$ayahStart-$ayahEnd" }
    }

    // Corpus-agnostic read aliases (Batch 3 Stage 2 [ContentIndex]). Identical values under
    // generic names — engine code that must not hardcode Qur'an vocabulary reads through these;
    // every existing `.surah`/`.ayahStart`/`.ayahEnd` call site is untouched.
    val work: Int get() = surah
    val unitStart: Int get() = ayahStart
    val unitEnd: Int get() = ayahEnd

    /** Serialized `{surah}:{ayah_start}-{ayah_end}` (ENGINE_PARITY §3). */
    override fun toString(): String = "$surah:$ayahStart-$ayahEnd"

    companion object {
        /** Generic-name factory alias; see [CanonicalPosition.ofWork]. */
        fun ofWork(work: Int, unitStart: Int, unitEnd: Int): CanonicalRange =
            CanonicalRange(work, unitStart, unitEnd)
    }
}

enum class AmountUnit(val code: String, val microPages: Long?) {
    AYAH("ayah", null),
    LINE("line", 66_666L),
    PAGE("page", 1_000_000L),
    RUB("rub", 2_500_000L),
    HIZB("hizb", 10_000_000L),
    JUZ("juz", 20_000_000L),
    CUSTOM("custom", null);

    companion object {
        fun fromCode(code: String): AmountUnit =
            entries.firstOrNull { it.code == code }
                ?: throw IllegalArgumentException("unknown amount unit: $code")
    }
}

/** Round-half-up integer division for non-negative operands (ENGINE_PARITY §1). */
fun roundHalfUpDiv(numerator: Long, denominator: Long): Long {
    require(numerator >= 0 && denominator > 0) { "roundHalfUpDiv domain: $numerator / $denominator" }
    return (2L * numerator + denominator) / (2L * denominator)
}

/**
 * `QuranAmount.value` is a decimal string ("1", "0.5", "2.75"); binary floating point never
 * touches scheduling math. `microPages()` = round_half_up(value × unit_µp).
 */
data class QuranAmount(val unit: AmountUnit, val value: String) {

    init {
        require(DECIMAL.matches(value)) { "QuranAmount.value must be a non-negative decimal string: '$value'" }
    }

    /** Micropage size for page-like units. AYAH amounts resolve by ayah count, not µp. */
    fun microPages(): Long {
        val unitMicro = unit.microPages
            ?: throw IllegalArgumentException("unit ${unit.code} has no micropage size")
        val (num, scale) = parseDecimal(value)
        return roundHalfUpDiv(num * unitMicro, scale)
    }

    /**
     * Whole atomic-unit count for count-based amounts (round-half-up on fractional input).
     * Corpus-agnostic ([ContentIndex.amountMicroPages] resolves both `ayah` and `custom` to a
     * plain count); [ayahCount] is the Qur'an-named, unit-checked wrapper around it.
     */
    fun unitCount(): Int {
        val (num, scale) = parseDecimal(value)
        return roundHalfUpDiv(num, scale).toInt()
    }

    /** Whole-ayah count for AYAH-unit amounts (round-half-up on fractional input). */
    fun ayahCount(): Int {
        require(unit == AmountUnit.AYAH) { "ayahCount() only valid for ayah unit" }
        return unitCount()
    }

    companion object {
        private val DECIMAL = Regex("""\d+(\.\d+)?""")

        /** "2.75" -> (275, 100). Pure integer decimal parse. */
        fun parseDecimal(s: String): Pair<Long, Long> {
            val dot = s.indexOf('.')
            return if (dot < 0) {
                Pair(s.toLong(), 1L)
            } else {
                val intPart = s.substring(0, dot)
                val fracPart = s.substring(dot + 1)
                var scale = 1L
                repeat(fracPart.length) { scale *= 10L }
                Pair(intPart.toLong() * scale + fracPart.toLong(), scale)
            }
        }
    }
}
