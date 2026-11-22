package masoon.publicui.planner

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Hearing
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.PauseCircle
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.RecordVoiceOver
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.Replay
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import masoon.publicui.designsystem.L
import masoon.publicui.designsystem.MasoonColors

internal object PlannerTaskTypes {
    @Composable
    fun label(type: String): String =
        when (type) {
            "prep_dhikr" -> L("التسبيح والاستغفار", "Preparation")
            "warmup" -> L("التهيئة", "Warm-up")
            "new_hifz" -> L("الحفظ الجديد", "New memorization")
            "takrar" -> L("التكرار الموزّع", "Distributed repetition")
            "murajaah" -> L("المراجعة", "Revision")
            "listening" -> L("الاستماع", "Listening")
            "tasmee" -> L("التسميع", "Recitation check")
            "weekend_consolidation" -> L("تثبيت الأسبوع", "Weekend consolidation")
            "juz_review" -> L("مراجعة الجزء", "Juz review")
            "juz_review_distributed" -> L("مراجعة موزّعة", "Distributed review")
            "cycle_consolidation" -> L("تثبيت الدورة", "Cycle consolidation")
            else -> type
        }

    fun icon(type: String): ImageVector =
        when (type) {
            "prep_dhikr" -> Icons.Filled.AutoAwesome
            "warmup" -> Icons.Filled.LocalFireDepartment
            "new_hifz" -> Icons.AutoMirrored.Filled.MenuBook
            "takrar", "weekend_consolidation" -> Icons.Filled.Repeat
            "murajaah" -> Icons.Filled.Replay
            "listening" -> Icons.Filled.Hearing
            "tasmee" -> Icons.Filled.RecordVoiceOver
            else -> Icons.Filled.Checklist
        }
}

internal val PlannerDayState.label: String
    @Composable get() =
        when (this) {
            PlannerDayState.PLANNED -> L("مخطط", "Planned")
            PlannerDayState.COMPLETED -> L("مكتمل", "Completed")
            PlannerDayState.PARTIAL -> L("جزئي", "Partial")
            PlannerDayState.MISSED -> L("فائت", "Missed")
            PlannerDayState.REST -> L("راحة", "Rest")
        }

internal val PlannerDayState.icon: ImageVector
    get() =
        when (this) {
            PlannerDayState.PLANNED -> Icons.Filled.RadioButtonUnchecked
            PlannerDayState.COMPLETED -> Icons.Filled.CheckCircle
            PlannerDayState.PARTIAL -> Icons.Filled.PauseCircle
            PlannerDayState.MISSED -> Icons.Filled.Error
            PlannerDayState.REST -> Icons.Filled.Bedtime
        }

internal val PlannerDayState.tint: Color
    @Composable get() =
        when (this) {
            PlannerDayState.PLANNED, PlannerDayState.REST -> MasoonColors.textSecondary
            PlannerDayState.COMPLETED -> MasoonColors.success
            PlannerDayState.PARTIAL -> MasoonColors.warning
            PlannerDayState.MISSED -> MasoonColors.attention
        }
