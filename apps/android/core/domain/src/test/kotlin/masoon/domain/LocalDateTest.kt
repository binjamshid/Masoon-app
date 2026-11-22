package masoon.domain

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class LocalDateTest {

    @Test
    fun `2026-07-12 is a Sunday`() {
        assertEquals(Weekday.SUN, LocalDate.parse("2026-07-12").weekday)
        assertEquals(Weekday.SAT, LocalDate.parse("2026-07-11").weekday)
        assertEquals(Weekday.THU, LocalDate.parse("1970-01-01").weekday)
        assertEquals(Weekday.FRI, LocalDate.parse("2026-07-17").weekday)
    }

    @Test
    fun `leap year rules`() {
        assertTrue(LocalDate.isLeapYear(2024))
        assertTrue(LocalDate.isLeapYear(2000))
        assertTrue(!LocalDate.isLeapYear(1900))
        assertTrue(!LocalDate.isLeapYear(2026))
        assertEquals(29, LocalDate.daysInMonth(2024, 2))
        assertEquals(28, LocalDate.daysInMonth(2026, 2))
        // Feb 29 valid in leap years only
        LocalDate(2024, 2, 29)
        assertThrows(IllegalArgumentException::class.java) { LocalDate(2026, 2, 29) }
    }

    @Test
    fun `plusDays crosses month year and leap boundaries`() {
        assertEquals(LocalDate.parse("2024-02-29"), LocalDate.parse("2024-02-28").plusDays(1))
        assertEquals(LocalDate.parse("2024-03-01"), LocalDate.parse("2024-02-29").plusDays(1))
        assertEquals(LocalDate.parse("1900-03-01"), LocalDate.parse("1900-02-28").plusDays(1))
        assertEquals(LocalDate.parse("2027-01-01"), LocalDate.parse("2026-12-31").plusDays(1))
        assertEquals(LocalDate.parse("2026-07-05"), LocalDate.parse("2026-07-12").minusDays(7))
    }

    @Test
    fun `epoch day round trip over a long span`() {
        // property: fromEpochDay(d.epochDay) == d, epoch increments by exactly 1 per day
        var d = LocalDate.parse("1999-12-25")
        var epoch = d.epochDay
        repeat(4000) {
            assertEquals(d, LocalDate.fromEpochDay(d.epochDay))
            d = d.plusDays(1)
            assertEquals(epoch + 1, d.epochDay)
            epoch = d.epochDay
        }
    }

    @Test
    fun `parse and format round trip with zero padding`() {
        for (s in listOf("2026-07-12", "2024-02-29", "0999-01-01", "2100-12-31")) {
            assertEquals(s, LocalDate.parse(s).toString())
        }
        assertThrows(IllegalArgumentException::class.java) { LocalDate.parse("2026-7-12") }
        assertThrows(IllegalArgumentException::class.java) { LocalDate.parse("2026-13-01") }
    }

    @Test
    fun `weekday cycles mod 7`() {
        val sun = LocalDate.parse("2026-07-12")
        assertEquals(Weekday.SUN, sun.plusDays(7).weekday)
        assertEquals(Weekday.MON, sun.plusDays(1).weekday)
        assertEquals(Weekday.SAT, sun.minusDays(1).weekday)
        assertEquals(Weekday.THU, sun.plusDays(4).weekday)
    }
}
