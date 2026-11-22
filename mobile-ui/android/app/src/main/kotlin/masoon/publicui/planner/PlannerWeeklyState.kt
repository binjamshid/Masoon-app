package masoon.publicui.planner

import java.time.LocalDate

/**
 * A visible week. Supply days in display order and session IDs in the order
 * their columns should appear. The host chooses the first day of the week.
 */
data class PlannerWeeklyState(
    val weekOffset: Int,
    val weekStart: LocalDate,
    val sessionIds: List<String>,
    val days: List<PlannerWeeklyDay>,
)

data class PlannerWeeklyDay(
    val date: LocalDate,
    val isToday: Boolean,
    val dayState: PlannerDayState,
    val hasConsolidation: Boolean,
    val tasksBySession: Map<String, List<PlannerTask>>,
)

enum class PlannerDayState { PLANNED, COMPLETED, PARTIAL, MISSED, REST }

/** The optional detail is display text supplied by the host. */
data class PlannerTask(
    val type: String,
    val detail: String? = null,
)

data class PlannerWeeklyCallbacks(
    val onWeekShift: (Int) -> Unit,
    val onJumpToCurrentWeek: () -> Unit,
)
