package masoon.domain

data class SessionSpec(val id: String, val start: String)

data class RampSpec(val start: QuranAmount, val step: QuranAmount)

sealed interface RecoveryPolicy {
    data object StrictBacklog : RecoveryPolicy
    data class Redistribute(val days: Int, val maxExtra: QuranAmount?) : RecoveryPolicy
    data object PauseAndResume : RecoveryPolicy
}

/** Typed values for curriculum `variable_overrides`. */
sealed interface VarValue {
    data class IntV(val value: Int) : VarValue
    data class BoolV(val value: Boolean) : VarValue
    data class StrV(val value: String) : VarValue
    data class AmountV(val value: QuranAmount) : VarValue
    data class WeekdaySetV(val value: Set<Weekday>) : VarValue
}

/**
 * Plan policy (PRD §7.2, fixture shape ENGINE_PARITY §4.1). Immutable; policy changes and
 * supervisor overrides create new timeline entries via patches.
 */
data class PlanPolicy(
    val newAmount: QuranAmount,
    val targetRange: TargetRange,
    val memorizationOrder: OrderSpec,
    val activeWeekdays: Set<Weekday>,
    val sessions: List<SessionSpec>,
    val separateSessionCompletion: Boolean,
    // Variable-bound fields are NULLABLE: when the policy omits them, the
    // §11.21 binding must fall through to the curriculum's own DSL variable
    // default (NOT a hardcoded Maknoon default). Non-null only when the plan
    // explicitly set them. (2026-07-16: fixes H-2 masking DSL defaults.)
    val listeningDays: Set<Weekday>? = null,
    val listeningCount: Int? = null,
    val takrarCount: Int? = null,
    val takrarSpacingMinutes: Int? = null,
    val murajaahDailyCeiling: QuranAmount? = null,
    val murajaahRamp: RampSpec?,
    val recoveryPolicy: RecoveryPolicy,
    val variableOverrides: Map<String, VarValue> = emptyMap(),
    val cycleWeekMode: String? = null,
    val evidencePolicy: Map<String, EvidenceSpec> = emptyMap(),
)
