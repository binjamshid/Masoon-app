package masoon.publicui.planner

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import masoon.publicui.designsystem.Chip
import masoon.publicui.designsystem.L
import masoon.publicui.designsystem.MasoonColors
import masoon.publicui.designsystem.MasoonMetrics
import masoon.publicui.designsystem.MasoonRadius
import masoon.publicui.designsystem.MasoonSpacing
import masoon.publicui.designsystem.MasoonTypeStyle
import masoon.publicui.designsystem.masoonCard
import masoon.publicui.designsystem.plannerLocale
import masoon.publicui.designsystem.toTextStyle
import java.time.LocalDate
import java.util.Locale

/** Displays one week of a study plan, with each day grouped by session. */
@Composable
fun WeeklyBoardScreen(
    state: PlannerWeeklyState,
    callbacks: PlannerWeeklyCallbacks,
    modifier: Modifier = Modifier,
) {
    val locale = plannerLocale()
    Column(
        modifier = modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(MasoonSpacing.lg),
        verticalArrangement = Arrangement.spacedBy(MasoonSpacing.lg),
    ) {
        WeeklyHeader(state.weekOffset, state.weekStart, locale, callbacks)
        state.days.forEach { day -> WeeklyDayCard(day, state.sessionIds, locale) }
    }
}

@Composable
private fun WeeklyHeader(
    weekOffset: Int,
    weekStart: LocalDate,
    locale: Locale,
    callbacks: PlannerWeeklyCallbacks,
) {
    val weekEnd = weekStart.plusDays(6)
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        WeekNavButton(Icons.AutoMirrored.Filled.ArrowBack, L("الأسبوع السابق", "Previous week")) {
            callbacks.onWeekShift(-1)
        }
        Column(modifier = Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                PlannerDateFormatting.weekTitle(weekStart, weekEnd, locale),
                style = MasoonTypeStyle.Headline.toTextStyle(),
                textAlign = TextAlign.Center,
                modifier = Modifier.semantics { heading() },
            )
            if (weekOffset == 0) {
                Text(
                    L("الأسبوع الحالي", "Current week"),
                    style = MasoonTypeStyle.Caption.toTextStyle(color = MasoonColors.primary),
                )
            } else {
                Text(
                    L("العودة للأسبوع الحالي", "Back to current week"),
                    style = MasoonTypeStyle.Caption.toTextStyle(color = MasoonColors.primary),
                    modifier =
                        Modifier
                            .defaultMinSize(minHeight = MasoonMetrics.minTarget)
                            .wrapContentHeight(Alignment.CenterVertically)
                            .clickable(role = Role.Button, onClick = callbacks.onJumpToCurrentWeek),
                )
            }
        }
        WeekNavButton(Icons.AutoMirrored.Filled.ArrowForward, L("الأسبوع التالي", "Next week")) {
            callbacks.onWeekShift(1)
        }
    }
}

@Composable
private fun WeekNavButton(
    icon: ImageVector,
    label: String,
    onClick: () -> Unit,
) {
    IconButton(onClick = onClick, modifier = Modifier.size(MasoonMetrics.minTarget)) {
        Icon(icon, contentDescription = label, tint = MasoonColors.primary)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun WeeklyDayCard(
    day: PlannerWeeklyDay,
    sessionIds: List<String>,
    locale: Locale,
) {
    Column(
        modifier = Modifier.fillMaxWidth().masoonCard().padding(MasoonSpacing.lg),
        verticalArrangement = Arrangement.spacedBy(MasoonSpacing.sm),
    ) {
        Text(
            PlannerDateFormatting.dayTitle(day.date, locale),
            style = MasoonTypeStyle.Headline.toTextStyle(),
            modifier = Modifier.semantics { heading() },
        )
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(MasoonSpacing.sm),
            verticalArrangement = Arrangement.spacedBy(MasoonSpacing.xs),
            itemVerticalAlignment = Alignment.CenterVertically,
        ) {
            Chip(day.dayState.label, tint = day.dayState.tint, icon = day.dayState.icon)
            if (day.isToday) Chip(L("اليوم", "Today"), tint = MasoonColors.primary)
            if (day.hasConsolidation) Chip(L("تثبيت", "Consolidation"), tint = MasoonColors.primary)
        }

        if (day.tasksBySession.isEmpty()) {
            Text(
                L("يوم راحة — لا مهام", "Rest day — no tasks"),
                style = MasoonTypeStyle.Footnote.toTextStyle(color = MasoonColors.textSecondary),
            )
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(MasoonSpacing.md)) {
                sessionIds.forEach { session ->
                    SessionColumn(session, day.tasksBySession[session].orEmpty(), Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun SessionColumn(
    sessionId: String,
    tasks: List<PlannerTask>,
    modifier: Modifier,
) {
    Column(
        modifier =
            modifier
                .clip(RoundedCornerShape(MasoonRadius.sm))
                .background(MasoonColors.surfaceSecondary)
                .padding(MasoonSpacing.sm),
        verticalArrangement = Arrangement.spacedBy(MasoonSpacing.xs),
    ) {
        Text(sessionTitle(sessionId), style = MasoonTypeStyle.Caption.toTextStyle(color = MasoonColors.textSecondary))
        if (tasks.isEmpty()) {
            Text("—", style = MasoonTypeStyle.Footnote.toTextStyle(color = MasoonColors.textSecondary))
        } else {
            tasks.forEach { task -> SessionTaskRow(task) }
        }
    }
}

@Composable
private fun SessionTaskRow(task: PlannerTask) {
    Row(verticalAlignment = Alignment.Top) {
        Icon(
            imageVector = PlannerTaskTypes.icon(task.type),
            contentDescription = null,
            tint = MasoonColors.primary,
            modifier = Modifier.size(16.dp),
        )
        Spacer(Modifier.width(MasoonSpacing.xs))
        Column {
            Text(PlannerTaskTypes.label(task.type), style = MasoonTypeStyle.Footnote.toTextStyle())
            task.detail?.let { detail ->
                Text(
                    detail,
                    style = MasoonTypeStyle.Caption.toTextStyle(color = MasoonColors.textSecondary),
                )
            }
        }
    }
}

@Composable
private fun sessionTitle(sessionId: String): String =
    when (sessionId) {
        "morning" -> L("الصباح", "Morning")
        "evening" -> L("المساء", "Evening")
        else -> sessionId
    }
