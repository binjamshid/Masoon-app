package masoon.curriculum

import masoon.domain.CanonicalPosition
import masoon.domain.ContentIndex
import masoon.domain.ContentWeight
import masoon.domain.EventPayload
import masoon.domain.LocalDate
import masoon.domain.PlanEvent
import masoon.domain.PlanPolicy
import masoon.domain.roundHalfUpDiv

/**
 * `PlanChangeDiff` (T-PC-10): a PURE comparison of a plan's CURRENT trajectory ("base") against a
 * CANDIDATE policy-and/or-curriculum change, over the exact same explicit date range for both
 * sides. Port of `apps/ios/Packages/Sources/MasoonCurriculum/PlanChangeDiff.swift` (454 lines).
 *
 * This is deliberately NOT built on top of [Forecaster.forecast] — that function's candidate
 * preview ([Forecaster.policyChangedEvent]'s pre-PC-10 default) hardcodes the candidate's
 * `effective_from` at `context.today + 1` (AC-6's "wizard confirms right now" preview).
 * `PlanChangeDiff` needs an arbitrary, caller-chosen `effectiveFrom` (a supervisor scheduling a
 * curriculum switch for next month, say), so it drives `Engine.generate` directly for BOTH the
 * base and candidate sides, over the IDENTICAL [DateRange] window, so neither side's start date is
 * silently different from the other's (see PC-10's own written correctness requirement).
 *
 * ## `historyUnchanged`
 * Both `Engine.generate` calls use `window.from = effectiveFrom` — never
 * `context.calendar.anchorDate`. The engine still simulates its own internal state (cursor,
 * ledger, debt, rotation cursors) from the plan's anchor forward to establish correct
 * day-`effectiveFrom` state (this is `Engine.generate`'s own unavoidable, pre-existing mechanic —
 * see [Forecaster.projection]'s identical `windowFrom` pattern) — but neither call's RETURNED
 * `tasks` can ever contain a date before `effectiveFrom`, because the engine only appends a day's
 * emissions to its output when `date >= window.from` (see `Engine.kt`'s `Simulation.run`/
 * `processDay`: `if (d in window) tasks.add(...)`). Days before `effectiveFrom` are therefore never
 * part of this diff's output or comparison "by construction — not by comparison" (PC-10's own
 * phrasing): there is no code path in this file that could observe, let alone compare, a
 * pre-`effectiveFrom` day. [Result.historyUnchanged] re-asserts this at runtime (cheap, from
 * arrays already in hand) as a regression guard, not because it is in doubt.
 *
 * ## `coverage.cursorMoved`
 * D-054 requires a curriculum switch to never relocate the memorization cursor. Investigated
 * (not merely asserted) against the Kotlin engine as it exists today:
 *   1. `Simulation.cursorIdx` is initialized exactly ONCE, from `initialCursorIdx()` (which reads
 *      `context.startingState.placementCursor`), and never re-initialized.
 *   2. It is mutated in exactly ONE place in the whole engine — `cursorIdx = sel.nextCursor`
 *      inside `onNewCompleted`, gated on a new-hifz task actually PASSING that day (ordinary
 *      forward advancement only).
 *   3. `sweepAtCurriculumBoundary(_:)` — the ONLY code that runs specifically at a curriculum
 *      switch's `effective_from` (D-054's hard-boundary sweep, PC-5) — mutates
 *      `consolidationWeeks`, `distributionByDate`, `pendingScheduled`, and `rotationCursors` ONLY.
 *      It does not reference `cursorIdx` at all.
 *   4. `PolicyJson.applyPatch` — the only code that applies a `plan.policy_changed`/
 *      `plan.curriculum_upgraded`-bundled patch — has no cursor- or placement-related key, and
 *      `walk`/`fullOrder` (the OTHER thing that could make the cursor's MEANING shift) are computed
 *      once at `Simulation` construction from the context's STATIC `context.policy`, never from a
 *      per-date effective policy, so a patch cannot retarget them either.
 *   5. [candidateContext] never constructs a different `startingState` for the candidate context
 *      (it reuses `context.startingState` byte-for-byte via `.copy(...)`) and never synthesizes a
 *      `starting_state.declared`/`starting_state.amended` event.
 * No code path in the engine or in this file can move the cursor as a side-effect of a
 * switch/patch event; only genuine forward hifz progress moves it, identically to how it always
 * has. `cursorMoved` is therefore `false` by construction, exactly like `historyUnchanged` above —
 * this is reported, not papered over, per PC-10's instructions.
 */
object PlanChangeDiff {

    /** Thrown by [compute] when `effectiveFrom` is not strictly after `context.today`. */
    class DiffError(val effectiveFrom: LocalDate, val today: LocalDate) : IllegalArgumentException(
        "PlanChangeDiff: effective_from $effectiveFrom must be after today $today — a plan-change " +
            "preview only ever proposes a future switch",
    )
    // D-054 previews only ever propose a FUTURE switch/patch. Allowing effectiveFrom <= today
    // would make the candidate side's actual-mode days (Engine.kt's `projection = d > today`)
    // resolve task_uids against a DIFFERENT rule/session vocabulary than the real recorded
    // completions were keyed under, manufacturing synthetic "missed" debt out of a hypothetical
    // retroactive switch — not a real product state, and exactly the kind of confusion
    // historyUnchanged/cursorMoved exist to rule out.

    /**
     * Horizon hard cap, matching [Forecaster.MAX_HORIZON_DAYS] (this file drives the same
     * `Engine.generate` machinery over a comparable span).
     */
    const val MAX_HORIZON_DAYS = Forecaster.MAX_HORIZON_DAYS

    // -------------------------------------------------------------- candidate curriculum switch --

    /**
     * A candidate `plan.curriculum_upgraded` target: the new curriculum's [slug]/[version] (folded
     * into `FoldResult.curriculumTimeline`, D-054) plus its [compiled] definition (injected into
     * the candidate context's `curriculaByKey`, PC-3/PC-7, so curriculum resolution actually finds
     * it instead of silently falling back to base).
     */
    data class CandidateCurriculumSwitch(val slug: String, val version: String, val compiled: CompiledCurriculum)

    // ------------------------------------------------------------------------- result shape --

    data class DateWindow(val from: LocalDate, val to: LocalDate)

    /** One window's average daily workload, base vs candidate. */
    data class Pace(
        val window: DateWindow,
        /**
         * Round-half-up average total `estimatedMinutes`/day over the days of [window] actually
         * inside the diffed horizon.
         */
        val baseAvgMinutes: Int,
        val candidateAvgMinutes: Int,
        /**
         * Days of [window] actually covered by the horizon (0 when the whole window falls beyond
         * `effectiveFrom + horizonDays`).
         */
        val daysCounted: Int,
    )

    /**
     * Characterizes the candidate's ramp-vs-steady pacing shape: a 14-day ramp window
     * `[effectiveFrom, effectiveFrom+13]` and a 28-day steady window
     * `[effectiveFrom+28, effectiveFrom+55]` — PC-10's own literal sampling windows, not
     * re-derived from any curriculum ramp constant.
     */
    data class Shape(val ramp: Pace, val steady: Pace)

    /**
     * One murajaah-family rule's post-switch "bridge" (catch-up) date: the first date on/after
     * `effectiveFrom` the rule's per-occurrence content weight reaches [peakMicropages] — the
     * rule's own steady-state ceiling, observed empirically from the CANDIDATE's own generated
     * stream (never re-derived from the DSL ramp formula, so this can never drift from what the
     * engine actually emits). A rule already at steady state going into the switch reaches its
     * peak on its very first post-switch emission — [fillDate] sits right at `effectiveFrom` —
     * which is exactly the observable signature of "the ramp did not restart".
     */
    data class BridgeEntry(
        val ruleId: String,
        val session: String,
        /**
         * Peak per-occurrence µp content observed for this rule within the diffed horizon; 0 when
         * the rule never emits any content.
         */
        val peakMicropages: Long,
        /**
         * `null` when the rule never reaches nonzero content within the horizon (peak == 0) —
         * nothing to "bridge" to.
         */
        val fillDate: LocalDate?,
    )

    /**
     * Debt-ledger comparison (`EngineState.debtNewRangeCount`, D-049) as of
     * `effectiveFrom + horizonDays` — the engine exposes only this final accumulated count, not a
     * day-by-day debt curve, so "over the horizon" reads as "accumulated BY the end of the horizon".
     */
    data class Debt(val baseOutstandingRanges: Int, val candidateOutstandingRanges: Int) {
        val delta: Int get() = candidateOutstandingRanges - baseOutstandingRanges
    }

    /**
     * D-054 coverage comparison. [cursorMoved] is ALWAYS `false` — see this file's header comment
     * for the structural argument.
     */
    data class Coverage(
        val cursorMoved: Boolean,
        val baseCursor: CanonicalPosition?,
        val candidateCursor: CanonicalPosition?,
        /**
         * µp of new-hifz content each side actually schedules within the diffed window — a
         * coverage-volume comparison independent of minutes/pacing.
         */
        val baseNewMicropages: Long,
        val candidateNewMicropages: Long,
    )

    /**
     * One side's (base or candidate) completion state — kept as a 4-way sealed type specifically
     * so a UI never has to collapse two different "nothing to show" states into one ambiguous case
     * (PC-10's explicit requirement: distinguish "still going" from "structurally can't complete").
     */
    sealed interface Completion {
        /**
         * The target completes within `[effectiveFrom, effectiveFrom + horizonDays]`, on this
         * date (R-C1: the last completed/assumed new-hifz task's date).
         */
        data class Date(val date: LocalDate) : Completion

        /**
         * The plan was ALREADY complete (or its cursor already exhausted) before `effectiveFrom`;
         * the diffed window contains no new-hifz work either way.
         */
        data object AlreadyComplete : Completion

        /** Outstanding new-hifz work exists, but does not finish by `effectiveFrom + horizonDays`. */
        data object BeyondHorizon : Completion

        /**
         * The active curriculum declares NO `new_hifz`-emitting rule at all — there is no
         * completion date to report, not even a distant one.
         */
        data object NoNewHifz : Completion
    }

    data class CompletionResult(val base: Completion, val candidate: Completion)

    data class Result(
        /**
         * See this file's header comment — proven true from the arrays already in hand
         * (window-filtered by construction), never by a deeper comparison against history.
         */
        val historyUnchanged: Boolean,
        val effectiveFrom: LocalDate,
        val horizonDays: Int,
        val shape: Shape,
        /** Sorted by `ruleId` for determinism. */
        val bridge: List<BridgeEntry>,
        val debt: Debt,
        val coverage: Coverage,
        val completion: CompletionResult,
    )

    // ------------------------------------------------------------------------------- compute --

    /**
     * Computes the diff. [candidatePolicy]/[candidateCurriculum] may be combined (a curriculum
     * switch that ALSO carries a bundled policy patch, D-054's `policy_patch` field) or used
     * independently; leaving both `null` is a legitimate (if degenerate) no-op self-diff.
     *
     * @throws DiffError when `effectiveFrom <= context.today`.
     */
    fun compute(
        context: PlanGenerationContext,
        effectiveFrom: LocalDate,
        horizonDays: Int,
        candidatePolicy: PlanPolicy? = null,
        candidateCurriculum: CandidateCurriculumSwitch? = null,
    ): Result {
        if (effectiveFrom <= context.today) throw DiffError(effectiveFrom, context.today)
        val horizon = horizonDays.coerceIn(0, MAX_HORIZON_DAYS)
        val horizonEnd = effectiveFrom.plusDays(horizon)
        // PC-10: the SAME explicit window for both sides — never `context.calendar.anchorDate` —
        // is the whole correctness point.
        val window = DateRange(effectiveFrom, horizonEnd)

        val baseResult = Engine(context.curriculum).generateFull(context, window)
        val candidateCtx = candidateContext(context, effectiveFrom, candidatePolicy, candidateCurriculum)
        val candidateResult = Engine(candidateCtx.curriculum).generateFull(candidateCtx, window)

        // Regression guard, not a measurement — see header comment.
        val historyUnchanged = baseResult.tasks.all { it.date >= effectiveFrom } &&
            candidateResult.tasks.all { it.date >= effectiveFrom }

        val shape = computeShape(baseResult.tasks, candidateResult.tasks, effectiveFrom, horizonEnd)
        val bridge = computeBridge(candidateResult.tasks, context.index)
        val debt = Debt(baseResult.state.debtNewRangeCount, candidateResult.state.debtNewRangeCount)
        val coverage = computeCoverage(baseResult, candidateResult, context.index)

        val candidateCurriculumActive = candidateCurriculum?.compiled ?: context.curriculum
        val completion = CompletionResult(
            base = completionFor(baseResult, context.curriculum),
            candidate = completionFor(candidateResult, candidateCurriculumActive),
        )

        return Result(
            historyUnchanged = historyUnchanged,
            effectiveFrom = effectiveFrom,
            horizonDays = horizon,
            shape = shape,
            bridge = bridge,
            debt = debt,
            coverage = coverage,
            completion = completion,
        )
    }

    private fun computeCoverage(
        baseResult: GenerationResult,
        candidateResult: GenerationResult,
        index: ContentIndex,
    ): Coverage {
        val baseNewRanges = baseResult.tasks.filter { it.type == "new_hifz" }.flatMap { it.content }
        val candidateNewRanges = candidateResult.tasks.filter { it.type == "new_hifz" }.flatMap { it.content }
        return Coverage(
            cursorMoved = false,
            baseCursor = baseResult.state.cursor,
            candidateCursor = candidateResult.state.cursor,
            baseNewMicropages = ContentWeight.microPages(baseNewRanges, index),
            candidateNewMicropages = ContentWeight.microPages(candidateNewRanges, index),
        )
    }

    // --------------------------------------------------------------- candidate context construction --

    /**
     * PC-10: reuses `context.startingState`/`context.policy` byte-for-byte (via `.copy`, so every
     * field neither this function nor its caller names stays untouched) — see this file's header
     * comment on `coverage.cursorMoved` for why that matters. Only `curriculaByKey` and `eventLog`
     * change.
     */
    internal fun candidateContext(
        context: PlanGenerationContext,
        effectiveFrom: LocalDate,
        candidatePolicy: PlanPolicy?,
        candidateCurriculum: CandidateCurriculumSwitch?,
    ): PlanGenerationContext {
        val curriculaByKey = context.curriculaByKey.toMutableMap()
        val extraEvents = mutableListOf<PlanEvent>()
        val occurredAtLocal = "${context.today}T23:59:00+00:00"

        if (candidateCurriculum != null) {
            curriculaByKey["${candidateCurriculum.slug}@${candidateCurriculum.version}"] = candidateCurriculum.compiled
            // D-054: a `plan.curriculum_upgraded` event may bundle its own `policy_patch`, folded
            // onto the SAME effective_from — use that single-event mechanism when both are
            // supplied, rather than two independent events.
            extraEvents.add(
                PlanEvent(
                    eventId = "planchange-candidate-curriculum",
                    type = "plan.curriculum_upgraded",
                    payload = EventPayload.CurriculumUpgraded(
                        effectiveFrom = effectiveFrom,
                        slug = candidateCurriculum.slug,
                        version = candidateCurriculum.version,
                        policyPatch = candidatePolicy?.let { Forecaster.policyPatch(it) },
                    ),
                    serverSeq = null,
                    deviceId = "~masoon-planchange",
                    clientSeq = Long.MAX_VALUE,
                    occurredAtLocal = occurredAtLocal,
                ),
            )
        } else if (candidatePolicy != null) {
            extraEvents.add(
                Forecaster.policyChangedEvent(
                    context = context,
                    candidate = candidatePolicy,
                    effective = effectiveFrom,
                    eventId = "planchange-candidate-policy",
                    deviceId = "~masoon-planchange",
                ),
            )
        }

        return context.copy(curriculaByKey = curriculaByKey, eventLog = context.eventLog + extraEvents)
    }

    // ------------------------------------------------------------------------------- shape --

    internal fun minutesByDate(tasks: List<TaskInstance>): Map<LocalDate, Int> {
        val out = LinkedHashMap<LocalDate, Int>()
        for (task in tasks) out[task.date] = (out[task.date] ?: 0) + task.estimatedMinutes
        return out
    }

    internal data class AvgResult(val avg: Int, val daysCounted: Int)

    internal fun avgMinutes(byDate: Map<LocalDate, Int>, window: DateWindow, horizonEnd: LocalDate): AvgResult {
        val clippedTo = minOf(window.to, horizonEnd)
        if (window.from > clippedTo) return AvgResult(0, 0)
        var total = 0L
        var count = 0L
        var d = window.from
        while (d <= clippedTo) {
            total += (byDate[d] ?: 0).toLong()
            count += 1L
            d = d.plusDays(1)
        }
        val avg = if (count > 0) roundHalfUpDiv(total, count).toInt() else 0
        return AvgResult(avg, count.toInt())
    }

    internal fun computeShape(
        baseTasks: List<TaskInstance>,
        candidateTasks: List<TaskInstance>,
        effectiveFrom: LocalDate,
        horizonEnd: LocalDate,
    ): Shape {
        val baseByDate = minutesByDate(baseTasks)
        val candidateByDate = minutesByDate(candidateTasks)
        // PC-10's own literal sampling windows (day offsets), not re-derived.
        val rampWindow = DateWindow(effectiveFrom, effectiveFrom.plusDays(13))
        val steadyWindow = DateWindow(effectiveFrom.plusDays(28), effectiveFrom.plusDays(55))

        fun pace(window: DateWindow): Pace {
            val base = avgMinutes(baseByDate, window, horizonEnd)
            val candidate = avgMinutes(candidateByDate, window, horizonEnd)
            return Pace(window, base.avg, candidate.avg, base.daysCounted)
        }
        return Shape(pace(rampWindow), pace(steadyWindow))
    }

    // ------------------------------------------------------------------------------ bridge --

    private data class RuleSeries(val session: String, val points: MutableList<Pair<LocalDate, Long>> = mutableListOf())

    internal fun computeBridge(candidateTasks: List<TaskInstance>, index: ContentIndex): List<BridgeEntry> {
        val byRule = LinkedHashMap<String, RuleSeries>()
        for (task in candidateTasks) {
            if (task.type != "murajaah") continue
            val mp = ContentWeight.microPages(task.content, index)
            byRule.getOrPut(task.originRuleId) { RuleSeries(task.session) }.points.add(task.date to mp)
        }
        val out = mutableListOf<BridgeEntry>()
        for (ruleId in byRule.keys.sorted()) {
            val entry = byRule.getValue(ruleId)
            val sortedPoints = entry.points.sortedBy { it.first }
            val peak = sortedPoints.maxOfOrNull { it.second } ?: 0L
            val fillDate = if (peak > 0L) sortedPoints.firstOrNull { it.second == peak }?.first else null
            out.add(BridgeEntry(ruleId, entry.session, peak, fillDate))
        }
        return out
    }

    // -------------------------------------------------------------------------- completion --

    internal fun hasNewHifzRule(curriculum: CompiledCurriculum): Boolean {
        if (curriculum.rules.any { it.emit.type == "new_hifz" }) return true
        for (trigger in curriculum.triggers) {
            for (effect in trigger.effects) {
                if (effect is TriggerEffect.InsertWeek && effect.dayRules.any { it.emit.type == "new_hifz" }) {
                    return true
                }
            }
        }
        return false
    }

    /**
     * `finalState.cursor == null` (`EngineState.cursor`) iff nothing selectable remains —
     * authoritative even in the (separate, pre-existing) engine edge case where a target that was
     * ALREADY fully covered by declared hifz before `effectiveFrom` never fires a completion
     * trigger (that trigger only runs after a new-hifz PASS, which never happens when there was
     * never anything left to select) and so never actually flips `status` to `"completed"`.
     */
    internal fun completionFor(result: GenerationResult, curriculum: CompiledCurriculum): Completion {
        if (!hasNewHifzRule(curriculum)) return Completion.NoNewHifz
        val lastInWindow = result.tasks.filter { it.type == "new_hifz" }.maxOfOrNull { it.date }
        if (lastInWindow != null && result.state.status == "completed") {
            return Completion.Date(lastInWindow)
        }
        if (result.state.cursor == null) {
            return Completion.AlreadyComplete
        }
        return Completion.BeyondHorizon
    }
}
