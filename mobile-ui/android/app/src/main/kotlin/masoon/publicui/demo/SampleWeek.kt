package masoon.publicui.demo

import masoon.publicui.planner.PlannerDayState
import masoon.publicui.planner.PlannerTask
import masoon.publicui.planner.PlannerWeeklyDay
import masoon.publicui.planner.PlannerWeeklyState
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.temporal.TemporalAdjusters

private val sampleToday = LocalDate.of(2026, 4, 15)
private val sampleWeekStart = sampleToday.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
private val sampleSessions = listOf("morning", "evening")

internal fun sampleWeek(weekOffset: Int, arabic: Boolean): PlannerWeeklyState {
    val start = sampleWeekStart.plusWeeks(weekOffset.toLong())
    val unitOne = if (arabic) "الوحدة ١" else "Unit 1"
    val unitTwo = if (arabic) "الوحدة ٢" else "Unit 2"
    val days = (0L..6L).map { index ->
        val date = start.plusDays(index)
        val tasksBySession = when (index) {
            0L, 1L -> mapOf(
                "morning" to listOf(PlannerTask("warmup"), PlannerTask("new_hifz", unitOne)),
                "evening" to listOf(PlannerTask("murajaah", unitOne)),
            )
            2L -> mapOf(
                "morning" to listOf(PlannerTask("cycle_consolidation", unitOne)),
                "evening" to listOf(PlannerTask("listening", unitOne)),
            )
            3L, 4L -> mapOf("morning" to listOf(PlannerTask("new_hifz", unitTwo)))
            else -> emptyMap()
        }
        val dayState = when {
            tasksBySession.isEmpty() -> PlannerDayState.REST
            date > sampleToday -> PlannerDayState.PLANNED
            date == sampleToday -> PlannerDayState.PARTIAL
            index == 1L -> PlannerDayState.MISSED
            else -> PlannerDayState.COMPLETED
        }
        PlannerWeeklyDay(
            date = date,
            isToday = date == sampleToday,
            dayState = dayState,
            hasConsolidation = index == 2L,
            tasksBySession = tasksBySession,
        )
    }
    return PlannerWeeklyState(weekOffset, start, sampleSessions, days)
}
