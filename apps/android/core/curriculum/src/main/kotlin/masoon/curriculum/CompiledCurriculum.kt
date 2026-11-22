package masoon.curriculum

import masoon.domain.CanonicalRange
import masoon.domain.QuranAmount
import masoon.domain.Weekday

/**
 * Typed model of a compiled curriculum definition (PRD §8, curriculum-v1.schema.json).
 * Loaded from `*.compiled.json`; the loader performs D-028 reference validation.
 */

class CurriculumValidationException(message: String) : IllegalArgumentException(message)

/** A literal value or a `$var` reference (resolved against variables/policy at generation time). */
sealed interface VarOr<out T> {
    data class Lit<T>(val value: T) : VarOr<T>
    data class Ref(val name: String) : VarOr<Nothing>
}

data class Meta(
    val slug: String,
    val titleAr: String?,
    val titleEn: String?,
    val nonNegotiables: List<String>,
    /**
     * Raw `meta.corpora` (curriculum-v1.schema.json) — which corpus KINDS ("quran", "poem") this
     * curriculum can plan. Empty when the field is absent from the compiled document, which is
     * itself meaningful under the schema's own "absence means Qur'an-only" rule (mirrors iOS's
     * `CompiledCurriculum.corpora == nil` default) — callers apply that fallback themselves
     * (`corpora.ifEmpty { listOf("quran") }`), matching `FeaturePlans/AddPlanModel.swift`'s own
     * `?? ["quran"]` read-site pattern, rather than baking the substitute value in here where a
     * caller that genuinely wants to know "was this field present at all" would lose that signal.
     *
     * Added narrowly for Batch 7 Wave C (`feature/plans`'s corpus-generic `NewPlanFromCurriculumFlow`
     * / `CorpusCatalog`): every bundled `*.compiled.json` already carries this key (verified against
     * `mauritanian.compiled.json`/`tikrar.compiled.json`, which declare `["quran", "poem"]`), but
     * [masoon.curriculum.CurriculumLoader] silently dropped it — a real, narrow parsing gap, not a
     * fold/generation-logic change. Purely additive: existing callers/tests constructing [Meta]
     * without this parameter are unaffected.
     */
    val corpora: List<String> = emptyList(),
)

/** B:CB-1 `LocalizedText` — an authored display label. Presentation-only; never serialized in the stream. */
data class LocalizedText(val ar: String?, val en: String?)

data class UnitsSpec(val allowed: List<String>, val defaultPace: QuranAmount)

data class CalendarSpec(
    val weekStart: Weekday,
    /** day-class name -> weekdays. */
    val dayClasses: Map<String, List<Weekday>>,
    val exceptionClasses: List<String>,
)

data class SessionDef(val id: String, val defaultTime: String?)

data class VariableDef(
    val type: String, // int | bool | amount | weekday_set | enum
    val default: VarDefault,
    val min: Int? = null,
    val max: Int? = null,
    val values: List<String>? = null,
    val nonNegotiable: Boolean = false,
)

sealed interface VarDefault {
    data class IntD(val value: Int) : VarDefault
    data class BoolD(val value: Boolean) : VarDefault
    data class StrD(val value: String) : VarDefault
    data class AmountD(val value: QuranAmount) : VarDefault
    data class WeekdaySetD(val value: Set<Weekday>) : VarDefault
}

/** Closed selector algebra (PRD §8.2). */
sealed interface SelectorSpec {
    data class NextContent(val amount: VarOr<QuranAmount>) : SelectorSpec
    data class NextNew(val amount: VarOr<QuranAmount>) : SelectorSpec
    data class LedgerWindow(val days: VarOr<Int>, val sundayDays: VarOr<Int>?) : SelectorSpec
    // E-2 (D-039): the new-ḥifẓ ledger of exactly one prior day (D − daysAgo).
    data class LedgerOffset(val daysAgo: VarOr<Int>) : SelectorSpec
    data object WeekToDate : SelectorSpec
    // E-1 (D-038): which prior ḥifẓ a murājaʿah layer rotates.
    sealed interface PoolWindow {
        data object PriorHifz : PoolWindow
        data class RecentPages(val count: VarOr<Int>) : PoolWindow
        data class RecentJuz(val count: VarOr<Int>) : PoolWindow

        /**
         * E-1b (D-043): the exact complement of the recent window — material that
         * has ROLLED OFF it (ITQAAN's list of pages beyond the active window).
         */
        data class AllExceptRecentPages(val count: VarOr<Int>) : PoolWindow
        data class AllExceptRecentJuz(val count: VarOr<Int>) : PoolWindow
    }
    /** How much of a murājaʿah pool to take each day. */
    sealed interface PerDay {
        /** Grows with WEEKS elapsed, capped at a ceiling (Maknoon-style). */
        data class Ramp(
            val start: VarOr<QuranAmount>,
            val step: VarOr<QuranAmount>,
            val ceiling: VarOr<QuranAmount>,
        ) : PerDay

        /**
         * E-3a (D-045): cover the whole pool every N days. The amount derives from
         * the POOL SIZE, so each item's review interval stays FIXED as the corpus
         * grows — the South-Asian Dhor mechanic, which a ramp cannot express.
         */
        data class CycleDays(val days: VarOr<Int>) : PerDay
    }

    data class PoolRotation(
        val pool: PoolWindow,
        val perDay: PerDay,
        val weakBoost: Int,
    ) : SelectorSpec
    data class CompletedJuz(val which: String) : SelectorSpec
    data class PriorHifzSplit(val parts: VarOr<Int>) : SelectorSpec
    data class Block(val juzCount: VarOr<Int>, val which: String) : SelectorSpec
    data object TomorrowNew : SelectorSpec
    data class Fixed(val ranges: List<CanonicalRange>) : SelectorSpec
    /** Inline in consolidation-week day rules: one near-equal slice of another selector's block. */
    data class BlockSlice(val of: String, val parts: Int) : SelectorSpec
    data class IntersectPriorHifz(val of: SelectorRef) : SelectorSpec
}

/** A named selector reference or an inline selector (consolidation-week `block_slice`). */
sealed interface SelectorRef {
    data class Named(val name: String) : SelectorRef
    data class Inline(val spec: SelectorSpec) : SelectorRef
}

enum class TaskDeduplicationMode(val code: String) {
    EXACT_EXECUTION("exact_execution"),
}

data class TaskWindowSpec(val opens: Weekday, val closes: Weekday)

data class RuleWhen(
    val dayClasses: List<String>,
    val session: String,
    val not: List<String> = emptyList(),
    val enabled: String? = null, // $var name (D-028 rule enablement)
    val dayIn: String? = null, // $weekday_set var name
)

data class RuleEmit(
    val type: String,
    val select: SelectorRef? = null,
    val repetitions: VarOr<Int>? = null,
    val spacingMinutes: VarOr<Int>? = null,
    val listenCount: VarOr<Int>? = null,
    val window: TaskWindowSpec? = null,
    val infoOnly: Boolean = false,
    val ordering: Int,
    /**
     * B:CB-1/D-053 — OPTIONAL authored display label overriding the presentation layer's generic
     * per-type title. Parsed for tri-engine model parity (Swift `RuleEmit.label`); the normalized
     * task stream (ENGINE_PARITY §3) carries no label field, so this never reaches a golden.
     */
    val label: LocalizedText? = null,
    /**
     * B:CB-2/D-054 — OPTIONAL authored minute estimate. Evaluated FIRST in the estimate function,
     * ahead of the `prep_dhikr` zero-out and every rate lookup (ENGINE_SEMANTICS §1; Swift
     * `estimateMinutes`, TS `estimateMinutes`).
     */
    val estMinutes: Int? = null,
)

data class RuleSpec(
    val id: String,
    val whenSpec: RuleWhen,
    val emit: RuleEmit,
    val suppressedBy: List<String> = emptyList(),
)

/**
 * Exactly one of `boundary`, `cursorReaches` or `taskFailed` is set.
 * `cursor_reaches` is parsed but INERT in v1 (§11.24).
 *
 * E-5 (D-047) `taskFailed` = the id of a rule whose task, on a CLOSED day, was
 * not verified — the Wifaq weekly milestone the student failed (or did not sit).
 */
data class TriggerOn(
    val boundary: String? = null,
    val cursorReaches: CanonicalRange? = null,
    val every: VarOr<Int>? = null,
    val taskFailed: String? = null,
)

sealed interface TriggerEffect {
    data class Schedule(
        val type: String,
        val select: SelectorRef,
        val distributeOverDays: Int? = null,
        val intoSession: String? = null,
        val starting: String = "next_active_day", // D-028 (5)
        /** B:CB-1/D-053 — mirrors [RuleEmit.label] for the synthetic `"{trigger}.{type}"` origin. */
        val label: LocalizedText? = null,
        /** B:CB-2/D-054 — mirrors [RuleEmit.estMinutes] for trigger-scheduled tasks. */
        val estMinutes: Int? = null,
    ) : TriggerEffect

    data class InsertWeek(
        val name: String,
        val modeVar: String?,
        val dayRules: List<RuleSpec>,
    ) : TriggerEffect

    data object CompletePlan : TriggerEffect

    /** Parsed and validated but INERT in v1 engines (§11.24). */
    data class SetFlag(val name: String, val until: String? = null) : TriggerEffect

    /** Parsed and validated but INERT in v1 engines (§11.24). */
    data class ClearFlag(val name: String) : TriggerEffect
}

data class TriggerSpec(val id: String, val on: TriggerOn, val effects: List<TriggerEffect>)

data class RecoverySpec(
    val allowedPolicies: List<String>,
    val default: String,
    val escalationDays: Int,
)

/** Evidence default with possibly-unresolved `$var` parameters (resolved per-plan at generation). */
sealed interface EvidenceDefaultSpec {
    data object SelfCheck : EvidenceDefaultSpec
    data class Timer(val minSeconds: VarOr<Int>) : EvidenceDefaultSpec
    data class Counter(val target: VarOr<Int>) : EvidenceDefaultSpec
    data class TeacherVerification(val formVersionId: String? = null) : EvidenceDefaultSpec
    data class Form(val formVersionId: String) : EvidenceDefaultSpec
    data class Composite(val parts: List<EvidenceDefaultSpec>) : EvidenceDefaultSpec
}

data class ForecastSpec(
    /** minutes-per-page (or per-rep / per-lesson) integer rates by rate key. */
    val workloadRates: Map<String, Long>,
    /** strength -> scaled factor (×1000): weak 1500, moderate 1200, strong 1000. */
    val strengthFactorsScaled: Map<String, Long>,
)

data class CompiledCurriculum(
    val meta: Meta,
    val units: UnitsSpec,
    val calendar: CalendarSpec,
    val sessions: List<SessionDef>,
    val variables: Map<String, VariableDef>,
    val selectors: Map<String, SelectorSpec>,
    val rules: List<RuleSpec>,
    val triggers: List<TriggerSpec>,
    val taskDeduplication: TaskDeduplicationMode? = null,
    val recovery: RecoverySpec,
    /**
     * E-4b (D-046): advancement requires a VERIFIED pass — a teacher-rejected
     * (mardūd) sabaq holds the cursor (and owes debt like any fail, D-048).
     *
     * NB (D-048): there is deliberately no `gate` knob. It once meant "an
     * unmastered portion owes no debt"; a fail becomes debt, so it had nothing
     * left to do and was removed rather than kept as a misleading no-op.
     */
    val requireVerified: Boolean = false,
    /** task_type (or "default") -> evidence default. */
    val evidenceDefaults: Map<String, EvidenceDefaultSpec>,
    val forecast: ForecastSpec,
) {
    /** weekday -> day-class name (validated total). */
    val dayClassOfWeekday: Map<Weekday, String> = buildMap {
        for ((name, days) in calendar.dayClasses) for (d in days) put(d, name)
    }
}
