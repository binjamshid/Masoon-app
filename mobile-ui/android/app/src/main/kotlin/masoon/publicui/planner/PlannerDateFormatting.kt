package masoon.publicui.planner

import android.icu.text.DateFormat
import android.icu.text.DateIntervalFormat
import android.icu.util.DateInterval
import android.icu.util.TimeZone
import android.icu.util.ULocale
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.Date
import java.util.Locale

internal object PlannerDateFormatting {
    fun dayTitle(date: LocalDate, locale: Locale): String =
        DateFormat.getInstanceForSkeleton("EEEEdMMMM", ULocale.forLocale(locale)).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }.format(Date(epochMillis(date)))

    fun weekTitle(start: LocalDate, end: LocalDate, locale: Locale): String =
        DateIntervalFormat.getInstance("yMMMd", ULocale.forLocale(locale)).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }.format(DateInterval(epochMillis(start), epochMillis(end)))

    private fun epochMillis(date: LocalDate): Long =
        date.atTime(12, 0).toInstant(ZoneOffset.UTC).toEpochMilli()
}
