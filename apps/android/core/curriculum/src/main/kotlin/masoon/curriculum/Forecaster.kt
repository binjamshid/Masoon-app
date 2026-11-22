package masoon.curriculum

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import masoon.domain.ContentIndex
import masoon.domain.EventPayload
import masoon.domain.EvidenceSpec
import masoon.domain.LocalDate
import masoon.domain.PlanEvent
import masoon.domain.PlanPolicy
import masoon.domain.QuranAmount
import masoon.domain.RampSpec
import masoon.domain.RecoveryPolicy
import masoon.domain.Uuid5
import masoon.domain.VarValue
import masoon.domain.Weekday
import masoon.domain.curriculumOn
import masoon.domain.foldEvents
import masoon.domain.roundHalfUpDiv

/**
 * Pure forecaster (PRD §7.10, T-015a). Port of
 * `apps/ios/Packages/Sources/MasoonCurriculum/Forecaster.swift` (711 lines).
 *
 * The forecast IS `Engine.generate` run forward in projection mode — there is no parallel
 * scheduling model (AC-5.4: the pre-confirmation diff and the post-confirmation regeneration are
 * the same engine call on the same inputs). Every workload number is the engine-stamped
 * `estimatedMinutes` (ENGINE_SEMANTICS §1/§11.3); the forecaster only sums, groups, and diffs.
 * Deterministic: same inputs -> identical result; integer math only; no wall clock, RNG, locale,
 * or I/O (enforced by [EnginePurityTest][masoon.curriculum.EnginePurityTest]'s scan).
 *
 * AC-O4: onboarding comparison figures come from this forecaster.
 *
 * Kotlin-vs-Swift shape notes (so a reviewer diffing against the Swift source isn't surprised):
 * - Swift declares [AdherenceMode]/[DayLoad]/[WeekBurden]/[JuzMilestone]/[CapacitySeverity]/
 *   [CapacityWarning]/[RecoveryImpact]/[ComparisonDelta]/[ForecastResult] at FILE scope (siblings
 *   of `enum Forecaster`, not nested inside it) — this port keeps them top-level in this file for
 *   the same reason, confirmed against real cross-module call sites (`FeaturePlanner/ForecastView.swift`
 *   reads bare `AdherenceMode`/`DayLoad`/`ForecastResult`/`CapacityWarning`, never
 *   `Forecaster.AdherenceMode`).
 * - Swift's `PlanGenerationContext.events`/`.quranIndex` are this port's `PlanGenerationContext
 *   .eventLog`/`.index` (existing Kotlin field names, unchanged here).
 * - Swift's `JSONValue` (a hand-rolled enum) is `kotlinx.serialization.json.JsonElement` here —
 *   [policyPatch] returns a real [JsonObject] that [masoon.domain.PolicyJson.applyPatch] consumes
 *   directly, with no intermediate hand-rolled JSON type.
 * - Swift's `PlanEvent.payload` is a raw `JSONValue`; Kotlin's [PlanEvent.payload] is the already-typed
 *   [EventPayload] sealed hierarchy, so every synthetic event this file builds
 *   ([recoveryAppliedEvent], [policyChangedEvent], [assumedCompletionEvents]) constructs an
 *   [EventPayload] case directly instead of hand-building a JSON object first.
 */
sealed interface AdherenceMode {
    /** Every projected task completes (engine projection default). */
    data object Full : AdherenceMode

    /**
     * Thin the assumed completion of the daily new-hifz task to [rateBasisPoints] basis points
     * (0..10000; e.g. trailing-28-day actual adherence).
     *
     * Deterministic integer thinning — no randomness, no opaque heuristics: the projection day at
     * offset `k` (`date == today + k`, k >= 1) keeps its new-hifz completion iff
     *
     *     (k * rate) / 10000  !=  ((k - 1) * rate) / 10000     (integer division)
     *
     * so over any prefix of n projection days exactly `floor(n * rate / 10000)` new-hifz
     * completions are assumed. A thinned day folds exactly like a real missed day under strict
     * backlog: the cursor stalls, the ledger has a gap (warm-up/takrar shrink automatically), and
     * the same content is re-selected on the next kept day. Thinning applies to new-hifz only;
     * murajaah is still assumed done (its misses create no content debt, PRD §7.9).
     */
    data class TrailingActual(val rateBasisPoints: Int) : AdherenceMode
}

/** One projected day's workload (engine-stamped minutes, summed by task type). */
data class DayLoad(
    val date: LocalDate,
    val estimatedMinutes: Int,
    val byType: Map<String, Int>,
)

/**
 * Weekly murajaah-family burden: average minutes per day of murajaah + juz_review_distributed +
 * cycle_consolidation over the days of the week that fall inside the projection horizon
 * (round-half-up).
 */
data class WeekBurden(val weekStart: LocalDate, val avgMinutes: Int)

/**
 * In-plan cumulative content covered a whole juz on [date] (declared prior hifz never counts,
 * matching R-J1 trigger semantics). Projection dates only.
 */
data class JuzMilestone(val juz: Int, val date: LocalDate)

enum class CapacitySeverity {
    /** estimated > declared (over 100%). */
    WARN,

    /** estimated > 150% of declared. */
    SEVERE,
}

/**
 * A maximal run of consecutive calendar days sharing the same severity whose estimated total
 * exceeds the declared daily availability.
 */
data class CapacityWarning(
    val startDate: LocalDate,
    val endDate: LocalDate,
    /** Peak estimated daily minutes within the range. */
    val estimatedMinutes: Int,
    val declaredAvailableMinutes: Int,
    val severity: CapacitySeverity,
)

/**
 * Diff between applying the plan's recovery policy tomorrow vs staying on strict backlog (PRD
 * §5.5): produced by running the same forecast twice — once with a projected
 * `plan.recovery_applied` event effective tomorrow, once without — and diffing (AC-5.4: identical
 * to what confirming in the Recovery Center regenerates).
 */
data class RecoveryImpact(
    /**
     * Days the strict path finishes later than the recovery path (0 when either completion date
     * is outside the horizon).
     */
    val slipDays: Int,
    /**
     * Average extra minutes on days where the recovery path is heavier (round-half-up over
     * positive-delta days; 0 when none).
     */
    val extraDailyMinutes: Int,
    /** Distinct curriculum weeks containing at least one positive-delta day. */
    val weeksAffected: Int,
)

/**
 * Candidate-policy comparison (AC-6 plan-change preview): the candidate is applied as a
 * `plan.policy_changed` patch effective tomorrow — exactly the event confirming the wizard would
 * append — and the same forecast is re-run.
 */
data class ComparisonDelta(
    /** candidate.completionDate - base.completionDate in days; null when either is outside the horizon. */
    val completionDeltaDays: Int?,
    /**
     * candidate - base average daily minutes, each averaged from tomorrow through its own
     * completion date (or the horizon end when incomplete).
     */
    val avgDailyMinutesDelta: Int,
    val candidateCompletionDate: LocalDate?,
)

data class ForecastResult(
    /**
     * Date the target range finishes (R-C1 flip = the last completed new-hifz task's date); null
     * when completion falls outside the horizon.
     */
    val completionDate: LocalDate? = null,
    val juzMilestones: List<JuzMilestone> = emptyList(),
    /** One entry per projection day (today+1 ... today+horizon), dense; days with no tasks carry 0 minutes. */
    val dailyLoadCurve: List<DayLoad> = emptyList(),
    val murajaahBurdenCurve: List<WeekBurden> = emptyList(),
    val capacityWarnings: List<CapacityWarning> = emptyList(),
    val recoveryImpact: RecoveryImpact? = null,
    val comparison: ComparisonDelta? = null,
)

object Forecaster {

    /** Horizon hard cap (~8.2 years of projection). */
    const val MAX_HORIZON_DAYS = 3000

    /**
     * Runs `Engine.generate` forward over today+1 .. today+min(horizonDays, [MAX_HORIZON_DAYS])
     * and aggregates the projected stream. May throw whatever the engine/context throw for
     * invalid inputs (e.g. [CurriculumValidationException]); a valid generation context always
     * forecasts.
     */
    fun forecast(
        context: PlanGenerationContext,
        horizonDays: Int,
        assumedAdherence: AdherenceMode = AdherenceMode.Full,
        declaredDailyAvailableMinutes: Int? = null,
        candidate: PlanPolicy? = null,
    ): ForecastResult {
        val horizon = minOf(horizonDays, MAX_HORIZON_DAYS)
        if (horizon < 1) return ForecastResult()

        val base = projection(context, horizon, assumedAdherence, emptyList())
        val weekStartDay = context.curriculum.calendar.weekStart

        var result = ForecastResult(
            completionDate = base.completionDate,
            juzMilestones = base.milestones,
            dailyLoadCurve = base.curve,
            murajaahBurdenCurve = murajaahBurden(base.curve, weekStartDay),
            capacityWarnings = declaredDailyAvailableMinutes?.let { capacityWarnings(base.curve, it) } ?: emptyList(),
        )

        // Recovery diff (PRD §5.5): only when the plan carries new-hifz debt today.
        if (outstandingDebtRanges(context) > 0) {
            val recoveryRun = projection(context, horizon, assumedAdherence, listOf(recoveryAppliedEvent(context)))
            result = result.copy(recoveryImpact = recoveryImpact(base, recoveryRun, weekStartDay))
        }

        // Candidate comparison (AC-6 preview): candidate policy effective tomorrow.
        if (candidate != null) {
            val candidateRun = projection(
                context, horizon, assumedAdherence, listOf(policyChangedEvent(context, candidate)),
            )
            val delta = base.completionDate?.let { b -> candidateRun.completionDate?.let { c -> daysBetween(b, c) } }
            result = result.copy(
                comparison = ComparisonDelta(
                    completionDeltaDays = delta,
                    avgDailyMinutesDelta = candidateRun.avgActiveDailyMinutes - base.avgActiveDailyMinutes,
                    candidateCompletionDate = candidateRun.completionDate,
                ),
            )
        }

        return result
    }

    // -------------------------------------------------------------- one projection run --

    internal data class ProjectionOutcome(
        val completionDate: LocalDate?,
        val milestones: List<JuzMilestone>,
        /** Dense: one entry per date in today+1 .. today+horizon. */
        val curve: List<DayLoad>,
        /** Average daily minutes from tomorrow through completion (or horizon end when incomplete), round-half-up. */
        val avgActiveDailyMinutes: Int,
    )

    /**
     * One `Engine.generate` pass plus stream aggregation. [extraEvents] are projected events
     * (recovery application / candidate policy patch) that a confirmation would append for real —
     * the AC-5.4 equivalence mechanism.
     */
    internal fun projection(
        context: PlanGenerationContext,
        horizonDays: Int,
        adherence: AdherenceMode,
        extraEvents: List<PlanEvent>,
    ): ProjectionOutcome {
        val today = context.today
        val horizonEnd = today.plusDays(horizonDays)
        val windowFrom = minOf(context.calendar.anchorDate, today.plusDays(1))

        // Effective engine input. `.TrailingActual` moves the engine's `today` to the horizon
        // end and supplies explicit assumed-completion events, because projection mode
        // unconditionally assumes completion; actual mode reads the event fold — the identical
        // code path real history uses.
        val engineContext = when (adherence) {
            is AdherenceMode.Full ->
                if (extraEvents.isEmpty()) context else rebuilt(context, context.eventLog + extraEvents, today)
            is AdherenceMode.TrailingActual -> {
                val assumed = assumedCompletionEvents(context, horizonDays, adherence.rateBasisPoints)
                rebuilt(context, context.eventLog + extraEvents + assumed, horizonEnd)
            }
        }

        val generated = Engine(engineContext.curriculum).generateFull(engineContext, DateRange(windowFrom, horizonEnd))
        val folded = foldEvents(engineContext.eventLog)

        val scan = scanTasks(generated.tasks, today, engineContext.today, folded.completed, context.index)
        val completionDate = if (generated.state.status == "completed") scan.lastCompletedNewHifz else null
        val curve = buildCurve(today, horizonDays, scan.totalsByDate)
        val avg = averageActiveDailyMinutes(curve, today, horizonEnd, completionDate)

        return ProjectionOutcome(completionDate, scan.milestones, curve, avg)
    }

    // -------------------------------------------------------- adherence thinning (assumed events) --

    /**
     * Only two task types fold state on completion: `new_hifz` (ledger, cursor, boundary
     * triggers, R-C1) and `murajaah` (rotation cursor). The thinned projection therefore assumes
     * murajaah always completes and new-hifz completes only on kept days per the documented
     * formula.
     */
    internal fun assumedCompletionEvents(
        context: PlanGenerationContext,
        horizonDays: Int,
        rateBasisPoints: Int,
    ): List<PlanEvent> {
        val rate = rateBasisPoints.coerceIn(0, 10_000)
        val fold = foldEvents(context.eventLog)
        val cache = mutableMapOf<String, RuleClassification>()

        fun classifiedOn(date: LocalDate): RuleClassification {
            val change = fold.curriculumOn(date)
            val curriculum = if (change == null) {
                context.curriculum
            } else {
                context.curriculaByKey[change.key] ?: context.curriculum
            }
            return cache.getOrPut(curriculum.meta.slug) { classifyRules(curriculum) }
        }

        val events = mutableListOf<PlanEvent>()
        var seq = 1L
        fun append(date: LocalDate, session: String, ruleId: String) {
            val uid = Uuid5.uuid5(context.planId, "$date|$session|$ruleId|0")
            events.add(assumedCompletionEvent(seq, date, uid))
            seq += 1
        }

        for (k in 1..horizonDays) {
            val date = context.today.plusDays(k)
            // occurrence is always 0 for daily-rule emissions (one evaluation per rule per day;
            // ENGINE_SEMANTICS §10).
            val keep = (k.toLong() * rate.toLong()) / 10_000L != ((k - 1).toLong() * rate.toLong()) / 10_000L
            val classified = classifiedOn(date)
            for ((session, ruleId) in classified.murajaahRules) append(date, session, ruleId)
            if (keep) {
                for ((session, ruleId) in classified.newHifzRules) append(date, session, ruleId)
            }
        }
        return events
    }

    // ------------------------------------------------------- projected events (recovery / candidate) --

    /**
     * Missed-new debt records outstanding at `context.today` (engine-derived).
     *
     * Public (not `internal`, unlike its Swift-parity siblings below) because Batch 7b's
     * `feature/planner` needs the exact same debt-gate computation [forecast] itself uses for its
     * `recoveryImpact` branch — the Recovery Center's "is there anything to recover?" check must
     * never disagree with what a forecast run would decide, and a second, re-derived copy in a
     * feature module is exactly how that drifts. Widening this one function's visibility is a
     * pure additive change (no behavior differs); every other Swift-mirroring helper in this file
     * stays `internal`.
     */
    fun outstandingDebtRanges(context: PlanGenerationContext): Int {
        if (context.today < context.calendar.anchorDate) return 0
        val history = Engine(context.curriculum).generateFull(
            context,
            DateRange(context.calendar.anchorDate, context.today),
        )
        return history.state.debtNewRangeCount
    }

    internal fun recoveryAppliedEvent(context: PlanGenerationContext): PlanEvent {
        val effective = context.today.plusDays(1)
        return PlanEvent(
            eventId = "forecast-recovery-preview",
            type = "plan.recovery_applied",
            payload = EventPayload.RecoveryApplied(effective),
            serverSeq = null,
            deviceId = "~masoon-forecast",
            clientSeq = Long.MAX_VALUE - 1,
            occurredAtLocal = "${context.today}T23:59:00+00:00",
        )
    }

    /**
     * PC-10: [effective]/[eventId]/[deviceId] are optional so this stays the exact call
     * `Forecaster.forecast(candidate:)` already made ([effective] defaulting to `today+1`, the
     * original hardcoded value) while giving `PlanChangeDiff` a way to reuse this SAME
     * patch-serialization/event-shape logic with an explicit, caller-chosen effective date
     * instead — `PlanChangeDiff` must never go through the `today+1`-hardcoded default path
     * (that hardcoding is exactly why it drives `Engine.generate` directly instead of calling
     * [forecast]; see `PlanChangeDiff.kt`'s header comment).
     */
    internal fun policyChangedEvent(
        context: PlanGenerationContext,
        candidate: PlanPolicy,
        effective: LocalDate? = null,
        eventId: String = "forecast-candidate-preview",
        deviceId: String = "~masoon-forecast",
    ): PlanEvent {
        val effectiveDate = effective ?: context.today.plusDays(1)
        return PlanEvent(
            eventId = eventId,
            type = "plan.policy_changed",
            payload = EventPayload.PolicyChanged(effectiveDate, policyPatch(candidate)),
            serverSeq = null,
            deviceId = deviceId,
            clientSeq = Long.MAX_VALUE,
            occurredAtLocal = "${context.today}T23:59:00+00:00",
        )
    }

    /**
     * Serializes a candidate policy as a `plan.policy_changed` patch — the exact payload
     * [masoon.domain.PolicyJson.applyPatch] consumes, and the shape the plan-change wizard
     * appends on confirm. Only fields `applyPatch` supports here are expressed (never
     * `target_range`/`memorization_order`/`sessions` — those change via other flows, AC-6.2);
     * derive candidates from the current policy.
     *
     * PC-6: this function serializes [policy] as a COMPLETE snapshot (the candidate becomes
     * exactly this), not a diff — so an empty `variable_overrides`/`evidence_policy` or an absent
     * `murajaah_ramp` must actively CLEAR whatever the base context's policy already had there,
     * not silently inherit it (matches Swift's own PC-6 comment verbatim).
     *
     * KOTLIN DIVERGENCE (reported, not silently narrowed): Swift's `PlanPolicy` keeps
     * `listeningDays`/`listeningCount`/`takrarCount`/`takrarSpacingMinutes`/`murajaahDailyCeiling`
     * NON-optional (tracking "was this explicitly set" out of band via `explicitPolicyFields`) and
     * always emits them, using an explicit JSON `null` to clear a field back to the curriculum's
     * own DSL default when the candidate never set it. Kotlin's `PlanPolicy` (2026-07-16, "H-2
     * masking DSL defaults" fix) instead makes those five fields genuinely nullable — but
     * [masoon.domain.PolicyJson.applyPatch] only implements a null-clearing branch for
     * `murajaah_ramp`/`variable_overrides`/`evidence_policy`; passing JSON `null` for the other
     * five would throw inside `applyPatch` (`JsonNull.jsonPrimitive.int`). This function therefore
     * OMITS those five keys when the candidate's own field is null, rather than emitting a `null`
     * `applyPatch` cannot consume. Because every real caller derives its candidate from
     * `context.policy` itself, an omitted key here is a safe no-op in the case that actually
     * occurs today (the field was already null/unset going in); the one narrow gap is a candidate
     * that deliberately clears an EXPLICITLY-set base value back to the curriculum default for one
     * of these five fields — that cannot be expressed as a patch until `PolicyJson.applyPatch`
     * gains a null-clearing branch for them too (a `:core:domain` change, out of this port's
     * scope — flagged here rather than silently worked around).
     */
    fun policyPatch(policy: PlanPolicy): JsonObject = buildJsonObject {
        put("new_amount", amountJson(policy.newAmount))
        put("active_weekdays", weekdaysJson(policy.activeWeekdays))
        policy.listeningDays?.let { put("listening_days", weekdaysJson(it)) }
        policy.listeningCount?.let { put("listening_count", it) }
        policy.takrarCount?.let { put("takrar_count", it) }
        policy.takrarSpacingMinutes?.let { put("takrar_spacing_minutes", it) }
        policy.murajaahDailyCeiling?.let { put("murajaah_daily_ceiling", amountJson(it)) }
        put("variable_overrides", overridesOrNull(policy.variableOverrides))
        put("evidence_policy", evidencePolicyOrNull(policy.evidencePolicy))
        put("murajaah_ramp", murajaahRampOrNull(policy.murajaahRamp))
        put("recovery_policy", recoveryPolicyJson(policy.recoveryPolicy))
        policy.cycleWeekMode?.let { put("cycle_week_mode", it) }
    }

    // -------------------------------------------------------------------- aggregations --

    internal fun murajaahBurden(curve: List<DayLoad>, weekStartDay: Weekday): List<WeekBurden> {
        val burdenTypes = listOf("murajaah", "juz_review_distributed", "cycle_consolidation")
        val totals = LinkedHashMap<LocalDate, LongArray>() // index 0 = minutes, index 1 = days
        for (load in curve) {
            val ws = weekStart(load.date, weekStartDay)
            val entry = totals.getOrPut(ws) { longArrayOf(0L, 0L) }
            for (type in burdenTypes) entry[0] += (load.byType[type] ?: 0).toLong()
            entry[1] += 1L
        }
        return totals.keys.sorted().map { ws ->
            val entry = totals.getValue(ws)
            WeekBurden(ws, roundHalfUpDiv(entry[0], entry[1]).toInt())
        }
    }

    internal fun capacityWarnings(curve: List<DayLoad>, declared: Int): List<CapacityWarning> =
        CapacityRunTracker(declared).run(curve)

    internal fun recoveryImpact(
        strict: ProjectionOutcome,
        recovery: ProjectionOutcome,
        weekStartDay: Weekday,
    ): RecoveryImpact {
        var slip = 0
        val strictDone = strict.completionDate
        val recoveryDone = recovery.completionDate
        if (strictDone != null && recoveryDone != null) {
            slip = daysBetween(recoveryDone, strictDone)
        }
        var positiveTotal = 0L
        var positiveDays = 0L
        val weeks = mutableSetOf<LocalDate>()
        for ((base, applied) in strict.curve.zip(recovery.curve)) {
            val delta = applied.estimatedMinutes - base.estimatedMinutes
            if (delta > 0) {
                positiveTotal += delta.toLong()
                positiveDays += 1L
                weeks.add(weekStart(applied.date, weekStartDay))
            }
        }
        val extra = if (positiveDays > 0) roundHalfUpDiv(positiveTotal, positiveDays).toInt() else 0
        return RecoveryImpact(slipDays = slip, extraDailyMinutes = extra, weeksAffected = weeks.size)
    }

    // -------------------------------------------------------------------------- helpers --

    internal fun weekStart(date: LocalDate, weekStartDay: Weekday): LocalDate {
        val delta = (date.weekday.ordinal - weekStartDay.ordinal + 7) % 7
        return date.minusDays(delta)
    }

    /** Rebuilds a context with a different event log / `today` — every other field carried through unchanged. */
    internal fun rebuilt(
        context: PlanGenerationContext,
        events: List<PlanEvent>,
        today: LocalDate,
    ): PlanGenerationContext = context.copy(eventLog = events, today = today)
}

// ============================================================================================
// File-private implementation details. Kept OUTSIDE `object Forecaster` deliberately, so the
// object's own member count stays well under detekt's TooManyFunctions(thresholdInObjects=20) —
// these are never called as `Forecaster.xxx`, unlike the members above which mirror named Swift
// `static func`s 1:1.
// ============================================================================================

private fun daysBetween(from: LocalDate, to: LocalDate): Int = (to.epochDay - from.epochDay).toInt()

private data class DayTotal(var total: Int = 0, val byType: MutableMap<String, Int> = mutableMapOf())

private data class TaskScanResult(
    val totalsByDate: Map<LocalDate, DayTotal>,
    val milestones: List<JuzMilestone>,
    val lastCompletedNewHifz: LocalDate?,
)

/** Milestone bookkeeping (cumulative in-plan juz coverage) + per-day minute totals, one pass over the stream. */
private fun scanTasks(
    tasks: List<TaskInstance>,
    today: LocalDate,
    engineToday: LocalDate,
    completed: Set<String>,
    index: ContentIndex,
): TaskScanResult {
    val covered = BooleanArray(index.totalUnits)
    val remaining = IntArray(index.boundaryCount + 1)
    if (index.boundaryCount >= 1) {
        for (juz in 1..index.boundaryCount) remaining[juz] = index.boundaryGlobalRange(juz)?.count() ?: 0
    }
    val milestones = mutableListOf<JuzMilestone>()
    var lastCompletedNewHifz: LocalDate? = null
    val totalsByDate = LinkedHashMap<LocalDate, DayTotal>()

    for (task in tasks) {
        if (task.date > today) {
            val entry = totalsByDate.getOrPut(task.date) { DayTotal() }
            entry.total += task.estimatedMinutes
            entry.byType[task.type] = (entry.byType[task.type] ?: 0) + task.estimatedMinutes
        }
        if (task.type != "new_hifz") continue
        // Completed iff projection-assumed (date beyond the engine's today) or a folded
        // `task.completed` exists (actual/assumed events).
        val isCompleted = task.date > engineToday || completed.contains(task.taskUid)
        if (!isCompleted) continue
        lastCompletedNewHifz = task.date
        for (range in task.content) {
            val globals = index.globalRangeOf(range) ?: continue
            for (g in globals) {
                if (covered[g]) continue
                covered[g] = true
                val juz = index.boundaryOfGlobal(g)
                remaining[juz] -= 1
                if (remaining[juz] == 0 && task.date > today) milestones.add(JuzMilestone(juz, task.date))
            }
        }
    }
    return TaskScanResult(totalsByDate, milestones, lastCompletedNewHifz)
}

private fun buildCurve(today: LocalDate, horizonDays: Int, totalsByDate: Map<LocalDate, DayTotal>): List<DayLoad> {
    val curve = ArrayList<DayLoad>(horizonDays)
    for (offset in 1..horizonDays) {
        val date = today.plusDays(offset)
        val entry = totalsByDate[date]
        curve.add(DayLoad(date, entry?.total ?: 0, entry?.byType?.toMap() ?: emptyMap()))
    }
    return curve
}

/** Average daily minutes: tomorrow -> completion (or horizon end). */
private fun averageActiveDailyMinutes(
    curve: List<DayLoad>,
    today: LocalDate,
    horizonEnd: LocalDate,
    completionDate: LocalDate?,
): Int {
    val activeEnd = if (completionDate != null) {
        maxOf(minOf(completionDate, horizonEnd), today.plusDays(1))
    } else {
        horizonEnd
    }
    var activeTotal = 0L
    for (load in curve) {
        if (load.date <= activeEnd) activeTotal += load.estimatedMinutes.toLong()
    }
    val activeDays = daysBetween(today, activeEnd).toLong()
    return if (activeDays > 0) roundHalfUpDiv(activeTotal, activeDays).toInt() else 0
}

/** A rule's (session, id) pair, classified by which task type it emits. */
private data class RuleClassification(
    val newHifzRules: List<Pair<String, String>>,
    val murajaahRules: List<Pair<String, String>>,
)

private fun classifyRules(curriculum: CompiledCurriculum): RuleClassification {
    val newHifz = mutableListOf<Pair<String, String>>()
    val murajaah = mutableListOf<Pair<String, String>>()
    fun addRule(rule: RuleSpec) {
        when (rule.emit.type) {
            "new_hifz" -> newHifz.add(rule.whenSpec.session to rule.id)
            "murajaah" -> murajaah.add(rule.whenSpec.session to rule.id)
        }
    }
    for (rule in curriculum.rules) addRule(rule)
    for (trigger in curriculum.triggers) {
        for (effect in trigger.effects) {
            if (effect is TriggerEffect.InsertWeek) {
                for (rule in effect.dayRules) addRule(rule)
            }
        }
    }
    return RuleClassification(newHifz, murajaah)
}

private fun assumedCompletionEvent(seq: Long, date: LocalDate, taskUid: String): PlanEvent = PlanEvent(
    eventId = "forecast-assumed-$seq",
    type = "task.completed",
    payload = EventPayload.TaskCompleted(taskUid = taskUid, date = date, verified = false),
    serverSeq = null,
    deviceId = "~masoon-forecast",
    clientSeq = seq,
    occurredAtLocal = "${date}T23:59:00+00:00",
)

// -- capacityWarnings run-tracking (kept out of Forecaster to stay well under LongMethod=60) --

private fun capacitySeverity(minutes: Int, declared: Int): CapacitySeverity? {
    if (minutes <= declared) return null
    // > 150%: minutes/declared > 3/2 <=> 2*minutes > 3*declared (integers).
    return if (2 * minutes > 3 * declared) CapacitySeverity.SEVERE else CapacitySeverity.WARN
}

/**
 * Direct, mutable-state port of Swift's `flush()`-based run tracker: a maximal run of
 * consecutive calendar days sharing the same severity. Kept as a small stateful class (rather
 * than a chain of `.copy()`-returning pure functions) so "extend the current run" is a plain
 * field mutation, not a fragile identity comparison on freshly-copied data-class instances.
 */
private class CapacityRunTracker(private val declared: Int) {
    private val warnings = mutableListOf<CapacityWarning>()
    private var runStart: LocalDate? = null
    private var runEnd: LocalDate? = null
    private var runPeak = 0
    private var runSeverity: CapacitySeverity? = null

    fun run(curve: List<DayLoad>): List<CapacityWarning> {
        for (load in curve) {
            val severity = capacitySeverity(load.estimatedMinutes, declared)
            if (severity == null) {
                flush()
                continue
            }
            val end = runEnd
            if (end != null && severity == runSeverity && load.date == end.plusDays(1)) {
                runEnd = load.date
                runPeak = maxOf(runPeak, load.estimatedMinutes)
            } else {
                flush()
                runStart = load.date
                runEnd = load.date
                runPeak = load.estimatedMinutes
                runSeverity = severity
            }
        }
        flush()
        return warnings
    }

    private fun flush() {
        val start = runStart
        val end = runEnd
        val sev = runSeverity
        if (start != null && end != null && sev != null) {
            warnings.add(CapacityWarning(start, end, runPeak, declared, sev))
        }
        runStart = null
        runEnd = null
        runPeak = 0
        runSeverity = null
    }
}

// -- policyPatch JSON helpers --

private fun amountJson(amount: QuranAmount): JsonObject = buildJsonObject {
    put("unit", amount.unit.code)
    put("value", amount.value)
}

private fun weekdaysJson(set: Set<Weekday>): JsonArray = JsonArray(set.sorted().map { JsonPrimitive(it.code) })

private fun varValueJson(value: VarValue): JsonElement = when (value) {
    is VarValue.IntV -> JsonPrimitive(value.value)
    is VarValue.BoolV -> JsonPrimitive(value.value)
    is VarValue.StrV -> JsonPrimitive(value.value)
    is VarValue.AmountV -> amountJson(value.value)
    is VarValue.WeekdaySetV -> weekdaysJson(value.value)
}

private fun overridesOrNull(map: Map<String, VarValue>): JsonElement =
    if (map.isEmpty()) JsonNull else JsonObject(map.mapValues { (_, v) -> varValueJson(v) })

private fun evidenceSpecJson(spec: EvidenceSpec): JsonElement = when (spec) {
    EvidenceSpec.SelfCheck -> JsonPrimitive("self_check")
    is EvidenceSpec.Timer -> buildJsonObject {
        put("timer", buildJsonObject { put("min_seconds", spec.minSeconds) })
    }
    is EvidenceSpec.Counter -> buildJsonObject {
        put("counter", buildJsonObject { put("target", spec.target) })
    }
    is EvidenceSpec.TeacherVerification -> buildJsonObject {
        put(
            "teacher_verification",
            buildJsonObject { spec.formVersionId?.let { put("form_version_id", it) } },
        )
    }
    is EvidenceSpec.Form -> buildJsonObject {
        put("form", buildJsonObject { put("form_version_id", spec.formVersionId) })
    }
    is EvidenceSpec.Composite -> buildJsonObject {
        put("composite", JsonArray(spec.parts.map { evidenceSpecJson(it) }))
    }
}

private fun evidencePolicyOrNull(map: Map<String, EvidenceSpec>): JsonElement =
    if (map.isEmpty()) JsonNull else JsonObject(map.mapValues { (_, v) -> evidenceSpecJson(v) })

private fun murajaahRampOrNull(ramp: RampSpec?): JsonElement =
    if (ramp == null) {
        JsonNull
    } else {
        buildJsonObject {
            put("start", amountJson(ramp.start))
            put("step", amountJson(ramp.step))
        }
    }

private fun recoveryPolicyJson(policy: RecoveryPolicy): JsonObject = when (policy) {
    RecoveryPolicy.StrictBacklog -> buildJsonObject { put("kind", "strict_backlog") }
    is RecoveryPolicy.Redistribute -> buildJsonObject {
        put("kind", "redistribute")
        put("days", policy.days)
        policy.maxExtra?.let { put("max_extra", amountJson(it)) }
    }
    RecoveryPolicy.PauseAndResume -> buildJsonObject { put("kind", "pause_and_resume") }
}
