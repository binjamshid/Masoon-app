package masoon.domain

/**
 * Day of week. Ordinal order SUN..SAT matches the Maknoon week (week_start = sun) and the
 * lowercase 3-letter codes used in contracts (`sun`..`sat`).
 */
enum class Weekday(val code: String) {
    SUN("sun"), MON("mon"), TUE("tue"), WED("wed"), THU("thu"), FRI("fri"), SAT("sat");

    companion object {
        fun fromCode(code: String): Weekday =
            entries.firstOrNull { it.code == code }
                ?: throw IllegalArgumentException("unknown weekday code: $code")
    }
}

/**
 * Pure civil (proleptic Gregorian) date. Deliberately NOT java.time: all day-of-week and
 * add-days math is implemented here (Howard Hinnant's days-from-civil algorithm) so the
 * arithmetic is bit-identical with the Swift and TypeScript engines (ENGINE_PARITY §1).
 */
data class LocalDate(val year: Int, val month: Int, val day: Int) : Comparable<LocalDate> {

    init {
        require(month in 1..12) { "month out of range: $month" }
        require(day in 1..daysInMonth(year, month)) { "day out of range: $year-$month-$day" }
    }

    /** Days since 1970-01-01. */
    val epochDay: Long
        get() {
            val y = if (month <= 2) year - 1 else year
            val era = Math.floorDiv(y, 400)
            val yoe = y - era * 400 // [0, 399]
            val mp = (month + 9) % 12 // [0, 11]
            val doy = (153 * mp + 2) / 5 + day - 1 // [0, 365]
            val doe = yoe.toLong() * 365 + yoe / 4 - yoe / 100 + doy // [0, 146096]
            return era * 146097L + doe - 719468L
        }

    val weekday: Weekday
        get() = Weekday.entries[Math.floorMod(epochDay + 4L, 7L).toInt()]

    fun plusDays(n: Long): LocalDate = fromEpochDay(epochDay + n)
    fun plusDays(n: Int): LocalDate = plusDays(n.toLong())
    fun minusDays(n: Int): LocalDate = plusDays(-n.toLong())

    override fun compareTo(other: LocalDate): Int = epochDay.compareTo(other.epochDay)

    /** `YYYY-MM-DD`, zero padded. */
    override fun toString(): String = "%04d-%02d-%02d".format(year, month, day)

    companion object {
        fun isLeapYear(y: Int): Boolean = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0

        fun daysInMonth(y: Int, m: Int): Int = when (m) {
            1, 3, 5, 7, 8, 10, 12 -> 31
            4, 6, 9, 11 -> 30
            2 -> if (isLeapYear(y)) 29 else 28
            else -> throw IllegalArgumentException("month out of range: $m")
        }

        fun fromEpochDay(epochDay: Long): LocalDate {
            val z = epochDay + 719468L
            val era = Math.floorDiv(z, 146097L)
            val doe = (z - era * 146097L).toInt() // [0, 146096]
            val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 // [0, 399]
            val y = yoe + era.toInt() * 400
            val doy = doe - (365 * yoe + yoe / 4 - yoe / 100) // [0, 365]
            val mp = (5 * doy + 2) / 153 // [0, 11]
            val d = doy - (153 * mp + 2) / 5 + 1 // [1, 31]
            val m = if (mp < 10) mp + 3 else mp - 9 // [1, 12]
            return LocalDate(if (m <= 2) y + 1 else y, m, d)
        }

        private val PATTERN = Regex("""(\d{4})-(\d{2})-(\d{2})""")

        fun parse(s: String): LocalDate {
            val m = PATTERN.matchEntire(s)
                ?: throw IllegalArgumentException("invalid date (want YYYY-MM-DD): $s")
            return LocalDate(m.groupValues[1].toInt(), m.groupValues[2].toInt(), m.groupValues[3].toInt())
        }
    }
}
