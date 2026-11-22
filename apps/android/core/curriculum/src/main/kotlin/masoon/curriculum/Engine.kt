package masoon.curriculum

import masoon.domain.AmountResolution
import masoon.domain.ContentIndex
import masoon.domain.EvidenceSpec
import masoon.domain.LocalDate
import masoon.domain.MICRO_PAGES_PER_PAGE
import masoon.domain.OrderSpec
import masoon.domain.QuranAmount
import masoon.domain.RecoveryPolicy
import masoon.domain.Selection
import masoon.domain.Strength
import masoon.domain.Uuid5
import masoon.domain.VarValue
import masoon.domain.Weekday
import masoon.domain.buildOrder
import masoon.domain.buildWalk
import masoon.domain.coalesceInTraversalOrder
import masoon.domain.curriculumOn
import masoon.domain.foldEvents
import masoon.domain.isPaused
import masoon.domain.nextNew
import masoon.domain.nextNewByAyahCount
import masoon.domain.roundHalfUpDiv
import masoon.domain.splitNearEqual
import masoon.domain.PlanPolicy
import masoon.domain.PolicyJson

/**
 * Deterministic Maknoon curriculum engine (PRD §7, ENGINE_SEMANTICS, ENGINE_PARITY).
 * Pure: no clocks, RNG, locale, or I/O; `today` and all reference data are inputs.
 * All scheduling math is integer micropages.
 */
class Engine(private val curriculum: CompiledCurriculum) {

    fun generate(context: PlanGenerationContext, window: DateRange): List<TaskInstance> =
        generateFull(context, window).tasks

    fun generateFull(context: PlanGenerationContext, window: DateRange): GenerationResult =
        Simulation(curriculum, context, window).run()
}

// ---------------------------------------------------------------------------

private const val WORKLOAD_DENOMINATOR = 1_000_000_000L // µp (10^6) × scaled strength (10^3)
private const val TOMORROW_NEW_LOOKAHEAD_DAYS = 14
private const val NEXT_ACTIVE_DAY_SEARCH_LIMIT = 1000

/** Base ordering for trigger-scheduled and inserted-week tasks (ENGINE_SEMANTICS §10/§11.2). */
private const val TRIGGER_ORDERING_BASE = 90

private fun sessionRank(session: String): Int = when (session) {
    "morning" -> 0
    "evening" -> 1
    "anytime" -> 2
    else -> 3
}

private class Simulation(
    /** The BASE curriculum. Every date-dependent read goes through [curOn], never through this. */
    private val curriculum: CompiledCurriculum,
    private val context: PlanGenerationContext,
    private val window: DateRange,
) {
    private val index: ContentIndex = context.index

    /**
     * Per-unit µp weights and boundary numbers, materialized once at construction.
     * [ContentIndex] exposes these as methods ([QuranIndex] stores them, [PoemIndex] derives
     * them); the day loop reads them many times per emitted task, so they are flattened here.
     * Same values as the pre-generalization `index.weightMicro` / `index.juzOfAyah` arrays — no
     * arithmetic is introduced, only an indirection removed.
     */
    private val totalUnits: Int = index.totalUnits
    private val weightMicro = LongArray(totalUnits) { index.weightOfGlobal(it) }
    private val uniformUnitMicroPages: Long? = weightMicro.firstOrNull()?.takeIf { first ->
        weightMicro.all { it == first }
    }
    private val boundaryOfUnit = IntArray(totalUnits) { index.boundaryOfGlobal(it) }

    private val fold = foldEvents(context.eventLog)
    private val startingState = fold.declaredStartingState ?: context.startingState
    private val anchor = context.calendar.anchorDate
    private val today = context.today
    private val exceptions: Map<LocalDate, String> =
        context.calendar.orgExceptions.associate { it.date to it.clazz }

    // Policy timeline (ENGINE_SEMANTICS §9): base at anchor + patches ascending by effective_from.
    private val policyTimeline: List<Pair<LocalDate, PlanPolicy>> = buildList {
        var current = context.policy
        add(anchor to current)
        for (p in fold.policyPatches) {
            current = PolicyJson.applyPatch(current, p.patch)
            add(p.effectiveFrom to current)
        }
    }

    private fun policyAt(d: LocalDate): PlanPolicy =
        policyTimeline.lastOrNull { it.first <= d }?.second ?: policyTimeline.first().second

    // ------------------------------------------------ curriculum per date (PC-4/PC-5, D-054) --

    private val curriculaByKey = context.curriculaByKey

    /** True only for a plan carrying at least one `plan.curriculum_upgraded` event. */
    private val hasCurriculumSwitch = fold.curriculumTimeline.isNotEmpty()

    /** PC-5: the `effective_from` dates at which the hard-boundary sweep must run. */
    private val curriculumBoundaryDates: Set<LocalDate> =
        fold.curriculumTimeline.mapTo(HashSet()) { it.effectiveFrom }

    /**
     * PC-4 (D-054): the curriculum active on [d]. With an empty curriculum timeline — every
     * single-curriculum plan, and 21 of the 23 fixtures — this is the base curriculum on every
     * date, so behaviour is bit-for-bit unchanged. A timeline entry naming a `slug@version` this
     * run was never given falls back to the base rather than throwing: an event log may reference
     * a curriculum the caller did not load, and failing hard there would take down generation.
     */
    private fun curOn(d: LocalDate): CompiledCurriculum {
        if (!hasCurriculumSwitch) return curriculum
        val change = fold.curriculumOn(d) ?: return curriculum
        return curriculaByKey[change.key] ?: curriculum
    }

    /**
     * PC-5 (D-054 hard-boundary sweep): curricula have near-disjoint session and day-class
     * vocabularies, so machinery scheduled under the OLD curriculum would silently emit nothing
     * (or misclassify) under the new one. On a switch's `effective_from`, drop every consolidation
     * week whose span has not fully elapsed, every distribution slice and scheduled review on or
     * after that date, and reset EVERY murājaʿah rotation cursor — a new curriculum's rule ids
     * generally name different pools, so a carried-over position is meaningless even on an id
     * collision. Cursor, ledger and debt are untouched.
     *
     * Runs BEFORE the day's consolidation week is resolved, so the sweep cannot suppress the very
     * boundary day it exists to unblock. Inert whenever the curriculum timeline is empty.
     */
    private fun sweepAtCurriculumBoundary(d: LocalDate) {
        if (d !in curriculumBoundaryDates) return
        consolidationWeeks.removeAll { it.end >= d }
        distributionByDate.keys.retainAll { it < d }
        pendingScheduled.keys.retainAll { it < d }
        rotationCursors.clear()
    }

    /** Day classes on which [cur] emits `new_hifz` — its "active"/"valid weekday" classes. */
    private fun newHifzDayClasses(cur: CompiledCurriculum): Set<String> =
        cur.rules.filter { it.emit.type == "new_hifz" }.flatMapTo(HashSet()) { it.whenSpec.dayClasses }

    /** The DSL amount of [cur]'s new-ḥifẓ `next_new` selector (`$pace` in Maknoon). */
    private fun newAmountSpec(cur: CompiledCurriculum): VarOr<QuranAmount>? =
        cur.rules.firstOrNull { it.emit.type == "new_hifz" }?.emit?.select?.let { sel ->
            val spec = when (sel) {
                is SelectorRef.Named -> cur.selectors[sel.name]
                is SelectorRef.Inline -> sel.spec
            }
            (spec as? SelectorSpec.NextNew)?.amount
        }

    // Memorization order & walk are fixed from the anchor policy (order changes mid-plan are a
    // plan-upgrade flow, not an engine concern).
    private val basePolicy = context.policy
    private val fullOrder = buildOrder(basePolicy.memorizationOrder, index)
    private val walk = buildWalk(fullOrder, basePolicy.targetRange, index)

    /** Order position used for pool ordering; ayahs outside a custom order sort after it, by mushaf index. */
    private fun orderPos(ayah: Int): Int {
        val p = fullOrder.pos[ayah]
        return if (p >= 0) p else fullOrder.seq.size + ayah
    }

    // Declared prior hifz
    private val declaredAyah = BooleanArray(totalUnits)
    private val strengthScaled = LongArray(totalUnits) { defaultStrengthScaled() }
    private val slicingWeight = LongArray(totalUnits) { weightMicro[it] }

    private fun defaultStrengthScaled(): Long =
        curriculum.forecast.strengthFactorsScaled["strong"] ?: Strength.STRONG.factorScaled

    init {
        for (dr in startingState.memorizedRanges) {
            val factor = curriculum.forecast.strengthFactorsScaled[dr.strength.code] ?: dr.strength.factorScaled
            val globals = index.globalRangeOf(dr.range)
                ?: throw CurriculumValidationException("declared range outside the corpus: ${dr.range}")
            for (i in globals) {
                if (!declaredAyah[i]) {
                    declaredAyah[i] = true
                    strengthScaled[i] = factor
                    if (dr.strength == Strength.WEAK) {
                        // D-012/D-029: weak ayahs rotate at half slicing-weight (≈2× frequency),
                        // full weight for workload estimates.
                        slicingWeight[i] = weightMicro[i] / 2
                    }
                }
            }
        }
    }

    // ---- mutable simulation state (PlanState fold) ----
    private var cursorIdx: Int = initialCursorIdx()
    private val completedAyah = BooleanArray(totalUnits) // in-plan completions only
    private val ledger = HashMap<LocalDate, IntArray>() // completed new-hifz per date (walk order)
    // E-1 (D-038): each murājaʿah layer (rule) keeps its own rotation cursor
    // (order-position space), keyed by rule id, so layers over different pools coexist.
    private val rotationCursors = mutableMapOf<String, Int>()
    private val boundaryCount = index.boundaryCount
    private val juzRemaining = IntArray(boundaryCount) { j -> boundaryGlobals(j + 1).count() }
    private val juzFired = BooleanArray(boundaryCount)
    private var juzDoneCount = 0
    private val completedJuzList = mutableListOf<Int>()
    private val pendingScheduled = HashMap<LocalDate, MutableList<ScheduledTask>>()

    /** §11.22: distributed slices pre-assigned to calendar days at fire time; no compaction. */
    private val distributionByDate = HashMap<LocalDate, DistSlice>()
    private var lastDistributionDate: LocalDate? = null
    private val consolidationWeeks = mutableListOf<ConsWeek>()
    private var cyclesFired = 0
    private var planCompleted = false
    private val debtNew = mutableListOf<DebtEntry>()

    /** ENGINE_SEMANTICS §11.1: first_active_day = calendar.anchor_date. */
    private val firstActiveDay: LocalDate = anchor
    private var redistribution: Redistribution? = null
    private val pendingRecoveryDates = ArrayDeque(fold.recoveryDates)

    private val tasks = mutableListOf<TaskInstance>()

    private data class ScheduledTask(
        val type: String,
        val origin: String, // "{trigger_id}.{task_type}" (§11.2)
        val session: String,
        val ordering: Int, // 90 + effect index within the trigger (§11.2)
        val ayahs: IntArray,
        /** B:CB-2 — `ScheduleEffect.est_minutes`; null for every built-in curriculum. */
        val estMinutesOverride: Int? = null,
    )

    private data class DistSlice(
        val type: String,
        val origin: String,
        val session: String,
        val ordering: Int,
        val ayahs: IntArray,
        val sizeMicro: Long,
        /** B:CB-2 — `ScheduleEffect.est_minutes`; null for every built-in curriculum. */
        val estMinutesOverride: Int? = null,
    )
    private data class ConsWeek(
        val start: LocalDate,
        val end: LocalDate,
        val triggerId: String,
        val mode: String,
        val dayRules: List<RuleSpec>,
    ) {
        operator fun contains(d: LocalDate): Boolean = d >= start && d <= end
    }

    /**
     * D-049: ONE lost advancement slot — a closed day that owed new ḥifẓ and did
     * not pass, carrying the µp it owed. [owedMicro] is fixed when the slot is
     * lost and discharged ONLY by catch-up work (redistribute extras), NOT by
     * completing the content later: doing that day's work a day late still
     * leaves you a slot behind.
     */
    private data class DebtEntry(
        val date: LocalDate,
        val ranges: List<masoon.domain.CanonicalRange>,
        var owedMicro: Long,
    )
    private class Redistribution(
        val appliedOn: LocalDate, // extras land on weekday-class days STRICTLY after this (§11.10)
        // §11.28: null until the first boosted day — debt is fixed lazily there
        // so the effective day's own miss is included (matches TS/Swift).
        var remainingMicro: Long?,
        var remainingDays: Int,
        val maxExtraMicro: Long?,
    )

    private class Emitted(
        val session: String,
        val ordering: Int,
        val originRuleId: String,
        val type: String,
        val ayahs: IntArray,
        val reps: Int? = null,
        val spacing: Int? = null,
        val listenCount: Int? = null,
        val windowOpens: LocalDate? = null,
        val windowCloses: LocalDate? = null,
        val infoOnly: Boolean = false,
        val advancesCursor: Selection? = null,
        val murajaahCursorAfter: Int? = null,
        /** B:CB-2 — authored `est_minutes`; wins ahead of the `prep_dhikr` zero-out and rates. */
        val estMinutesOverride: Int? = null,
    )

    private fun initialCursorIdx(): Int {
        val g = index.globalIndexOf(startingState.placementCursor)
            ?: throw CurriculumValidationException(
                "placement cursor ${startingState.placementCursor} is outside the corpus"
            )
        val p = fullOrder.pos[g]
        require(p >= 0 || walk.isEmpty()) { "placement cursor ${startingState.placementCursor} is outside the memorization order" }
        // exact walk position, else the first walk ayah at-or-after the cursor's order position
        var lo = 0
        var found = walk.size
        while (lo < walk.size) {
            if (fullOrder.pos[walk[lo]] >= p) { found = lo; break }
            lo++
        }
        return found
    }

    // ---------------------------------------------------------------- run --

    fun run(): GenerationResult {
        var d = anchor
        while (d <= window.to) {
            processDay(d)
            d = d.plusDays(1)
        }
        val status = when {
            planCompleted -> "completed"
            fold.isPaused(window.to) -> "paused"
            else -> "active"
        }
        // §11.15: cursor = next SELECTABLE new-ḥifẓ ayah, null (`-`) when
        // exhausted. Skip already-memorized (declared or in-plan-completed)
        // positions so a full-ḥāfiẓ maintenance plan reports `-` (2026-07-16
        // multi-curriculum hardening; walk is already target-filtered, and
        // frontier plans are unchanged — cursorIdx already sits on the first
        // unmemorized position).
        var selIdx = cursorIdx
        val isTilawahPlan = context.curriculum.rules.any { it.emit.type == "tilawah" }
        while (!isTilawahPlan && selIdx < walk.size &&
            (declaredAyah[walk[selIdx]] || completedAyah[walk[selIdx]])) selIdx++
        return GenerationResult(
            tasks = tasks.toList(),
            state = EngineState(
                cursor = if (selIdx < walk.size) index.positionOfGlobal(walk[selIdx]) else null,
                juzDone = juzDoneCount,
                cycleWeeks = cyclesFired,
                // D-049: debt_new = count of ranges in still-OWED lost slots. A
                // slot's content may well be memorized by now — that does not
                // give the lost day back.
                debtNewRangeCount = debtNew.sumOf { entry ->
                    if (entry.owedMicro > 0L) entry.ranges.size else 0
                },
                status = status,
            ),
        )
    }

    private fun processDay(d: LocalDate) {
        // paused: no tasks, no misses, distribution queue not consumed (ENGINE_SEMANTICS §8)
        if (fold.isPaused(d)) return
        // PC-5: the hard-boundary sweep runs BEFORE the day's consolidation week is resolved, so
        // it cannot suppress the very boundary day it exists to unblock.
        sweepAtCurriculumBoundary(d)
        // org exception day: Maknoon defines no exception rules -> no emission; slices push forward
        if (exceptions.containsKey(d)) return

        val pol = policyAt(d)
        val cur = curOn(d) // PC-4: every curriculum read below is date-resolved, never the base
        activateRecoveryIfDue(d, pol)

        val dayClass = cur.dayClassOfWeekday[d.weekday]
            ?: throw CurriculumValidationException("no day class for ${d.weekday.code}")
        val consWeek = consolidationWeeks.firstOrNull { d in it }
        val suppressNew = consWeek != null && consWeek.mode == "pause_new"

        val emitted = mutableListOf<Emitted>()

        // -- trigger-scheduled tasks (juz_review at next active day; one distributed slice/day) --
        pendingScheduled.remove(d)?.forEach { st ->
            emitted.add(
                Emitted(
                    st.session, st.ordering, st.origin, st.type, st.ayahs,
                    estMinutesOverride = st.estMinutesOverride,
                )
            )
        }
        // §11.22: distributed slices are pre-assigned to calendar days at fire time
        var sliceMicro = 0L
        distributionByDate.remove(d)?.let { slice ->
            emitted.add(
                Emitted(
                    slice.session, slice.ordering, slice.origin, slice.type, slice.ayahs,
                    estMinutesOverride = slice.estMinutesOverride,
                )
            )
            sliceMicro = slice.sizeMicro
        }

        // -- daily rules --
        var dayNewSelection: Selection? = null
        var dayNewComputed = false
        // the selection actually emitted as a new_hifz task today (null on weekends /
        // consolidation weeks) — the tomorrow_new projection cursor advances past it only
        var emittedNewSelection: Selection? = null
        fun newSelection(): Selection? {
            if (!dayNewComputed) {
                dayNewComputed = true
                // §11.19: new hifz respects policy.active_weekdays even on weekday-class days
                dayNewSelection = if (planCompleted || d.weekday !in pol.activeWeekdays) {
                    null
                } else {
                    selectNew(cursorIdx, d, pol, cur, includeExtra = true)
                }
            }
            return dayNewSelection
        }

        val activeRules = cur.rules + (consWeek?.dayRules ?: emptyList())
        for (rule in activeRules) {
            val isWeekRule = consWeek != null && consWeek.dayRules.contains(rule)
            if (dayClass !in rule.whenSpec.dayClasses) continue
            if (suppressNew && rule.suppressedBy.contains(consWeek!!.triggerId)) {
                // D-048: a FAILURE week (inserted by a task_failed trigger) costs
                // advancement slots the learner did not choose to give up, so each
                // suppressed new-ḥifẓ day owes debt — slot-based per D-035. A
                // PLANNED pause (a juzʾ-boundary consolidation week) is the
                // curriculum working as designed and owes nothing.
                if (rule.emit.type == "new_hifz" && d < today && isFailureWeek(consWeek, cur) &&
                    pol.activeWeekdays.contains(d.weekday) && exceptions[d] == null && !fold.isPaused(d)
                ) {
                    val sel = newSelection()
                    if (sel != null && sel.ayahs.isNotEmpty()) {
                        debtNew.add(
                            DebtEntry(d, coalesceInTraversalOrder(sel.ayahs, index), sel.ayahs.sumOf { weightMicro[it] })
                        )
                    }
                }
                continue
            }
            if ("first_active_day" in rule.whenSpec.not && d == firstActiveDay) continue
            if ("in_consolidation_week" in rule.whenSpec.not && consWeek != null) continue
            if (rule.whenSpec.enabled != null && !varBool(rule.whenSpec.enabled, pol, cur)) continue
            if (rule.whenSpec.dayIn != null && d.weekday !in varWeekdaySet(rule.whenSpec.dayIn, pol, cur)) continue

            var advancing: Selection? = null
            var murajaahAfter: Int? = null
            val ayahs: IntArray = when (val sel = rule.emit.select) {
                null -> IntArray(0)
                else -> {
                    val spec = when (sel) {
                        is SelectorRef.Named -> cur.selectors[sel.name]
                            ?: throw CurriculumValidationException("unknown selector ${sel.name}")
                        is SelectorRef.Inline -> sel.spec
                    }
                    when (spec) {
                        is SelectorSpec.NextContent -> {
                            val amount = resolveAmount(spec.amount, pol, cur)
                            val s = when (val resolved = index.amountMicroPages(amount)) {
                                is AmountResolution.CountUnit -> nextNewByAyahCount(walk, cursorIdx, resolved.value, index)
                                is AmountResolution.MicroPages -> nextNew(walk, cursorIdx, resolved.value, index)
                                AmountResolution.Unsupported -> throw CurriculumValidationException(
                                    "next_content amount unit '${amount.unit.code}' is not defined for this corpus"
                                )
                            }
                            if (rule.emit.type == "tilawah") advancing = s
                            s?.ayahs ?: IntArray(0)
                        }
                        is SelectorSpec.NextNew -> {
                            val s = newSelection()
                            if (rule.emit.type == "new_hifz") {
                                advancing = s
                                emittedNewSelection = s
                            }
                            s?.ayahs ?: IntArray(0)
                        }
                        is SelectorSpec.LedgerWindow -> ledgerWindowAyahs(d, spec, pol, cur)
                        is SelectorSpec.LedgerOffset -> {
                            // E-2 (D-039): the new-ḥifẓ ledger of exactly one prior day.
                            val k = resolveInt(spec.daysAgo, pol, cur)
                            ledgerUnion(d.minusDays(k), d.minusDays(k))
                        }
                        SelectorSpec.WeekToDate -> weekToDateAyahs(d, cur)
                        is SelectorSpec.PoolRotation -> {
                            val r = murajaahSlice(d, spec, pol, cur, sliceMicro, dayClass, consWeek, rule.id)
                            murajaahAfter = r?.second
                            r?.first ?: IntArray(0)
                        }
                        SelectorSpec.TomorrowNew -> tomorrowNewAyahs(d, emittedNewSelection)
                        is SelectorSpec.CompletedJuz -> completedJuzList.lastOrNull()
                            ?.let { juzAyahsOrdered(it) } ?: IntArray(0)
                        is SelectorSpec.Block -> blockAyahs(resolveInt(spec.juzCount, pol, cur))
                        is SelectorSpec.BlockSlice -> blockSliceAyahs(spec, d, dayClass, consWeek, pol, cur)
                        is SelectorSpec.PriorHifzSplit -> priorHifzAyahs(excludeJuz = null)
                        is SelectorSpec.Fixed -> spec.ranges.flatMap { fixedGlobals(it).toList() }.toIntArray()
                        is SelectorSpec.IntersectPriorHifz -> {
                            val inner = when (val ref = spec.of) {
                                is SelectorRef.Named -> cur.selectors[ref.name]
                                    ?: throw CurriculumValidationException("unknown selector ${ref.name}")
                                is SelectorRef.Inline -> ref.spec
                            }
                            val selected = when (inner) {
                                is SelectorSpec.Fixed -> inner.ranges.flatMap { fixedGlobals(it).toList() }.toIntArray()
                                else -> throw CurriculumValidationException(
                                    "intersect_prior_hifz currently requires a fixed selector"
                                )
                            }
                            selected.filter { declaredAyah[it] || completedAyah[it] }.toIntArray()
                        }
                    }
                }
            }

            // empty-content rule: content-bearing tasks with an empty selector are not emitted
            if (rule.emit.select != null && ayahs.isEmpty()) continue

            val weekStartDate = weekStart(d, cur)
            emitted.add(
                Emitted(
                    session = rule.whenSpec.session,
                    // §11.2: inserted-week rules keep their ids, ordering = 90 + declared ordering
                    ordering = if (isWeekRule) TRIGGER_ORDERING_BASE + rule.emit.ordering else rule.emit.ordering,
                    originRuleId = rule.id,
                    type = rule.emit.type,
                    ayahs = ayahs,
                    reps = rule.emit.repetitions?.let { resolveInt(it, pol, cur) },
                    spacing = rule.emit.spacingMinutes?.let { resolveInt(it, pol, cur) },
                    listenCount = rule.emit.listenCount?.let { resolveInt(it, pol, cur) },
                    windowOpens = rule.emit.window?.let { weekStartDate.plusDays(dayOffsetInWeek(it.opens, cur)) },
                    windowCloses = rule.emit.window?.let { weekStartDate.plusDays(dayOffsetInWeek(it.closes, cur)) },
                    infoOnly = rule.emit.infoOnly,
                    advancesCursor = advancing,
                    murajaahCursorAfter = murajaahAfter,
                    estMinutesOverride = rule.emit.estMinutes,
                )
            )
        }

        // -- deterministic ordering, occurrence, uid (ENGINE_PARITY §1/§2) --
        // Session order follows the curriculum's DECLARED session sequence (so
        // a custom "midday" sits between morning and evening); Maknoon's
        // morning<evening is the special case (2026-07-16 multi-curriculum
        // parity fix). Unknown ids last.
        val sessionOrder = cur.sessions.map { it.id }
        fun sessRank(id: String): Int = sessionOrder.indexOf(id).let { if (it >= 0) it else 999 }
        val sorted = emitted.sortedWith(
            compareBy({ sessRank(it.session) }, { it.ordering }, { it.originRuleId })
        )
        val occ = HashMap<Pair<String, String>, Int>()
        val flagsBase = buildList {
            if (d == firstActiveDay) add("first_active_day")
            if (consWeek != null) add("consolidation_week")
        }

        val projection = d > today
        var extraConsumedThisDay: Long? = null
        var newCompletedToday = false

        val rawDayTasks = sorted.map { e ->
            val k = e.session to e.originRuleId
            val o = occ.getOrDefault(k, 0)
            occ[k] = o + 1
            val uid = Uuid5.uuid5(context.planId, "$d|${e.session}|${e.originRuleId}|$o")
            val flags = (flagsBase + if (e.infoOnly) listOf("info_only") else emptyList()).sorted()
            TaskInstance(
                taskUid = uid,
                planId = context.planId,
                date = d,
                dayClass = dayClass,
                session = e.session,
                ordering = e.ordering,
                occurrence = o,
                type = e.type,
                originRuleId = e.originRuleId,
                content = coalesceInTraversalOrder(e.ayahs, index),
                targetRepetitions = e.reps,
                spacingMinutes = e.spacing,
                listenCount = e.listenCount,
                windowOpensOn = e.windowOpens,
                windowClosesOn = e.windowCloses,
                estimatedMinutes = estMinutes(
                    e.type, e.ayahs, e.reps, e.listenCount, e.estMinutesOverride, cur,
                ),
                // §11.5: info_only tasks serialize an empty evidence field
                evidenceCompact = if (e.infoOnly) "" else evidenceFor(e.type, pol, cur),
                flags = flags,
            )
        }
        val deduplicated = if (cur.taskDeduplication == TaskDeduplicationMode.EXACT_EXECUTION) {
            TaskDeduplicator.deduplicate(rawDayTasks)
        } else {
            TaskDeduplicationResult(rawDayTasks, rawDayTasks)
        }
        if (d in window) tasks.addAll(deduplicated.output)

        for ((emissionIndex, e) in sorted.withIndex()) {
            val uid = deduplicated.stateTasks[emissionIndex].taskUid

            // -- state advancement --
            val contentBearing = e.ayahs.isNotEmpty()
            val done = if (projection) contentBearing else fold.completed.contains(uid)
            // E-4b (D-046): under require_verified a completed-but-UNVERIFIED
            // portion is a teacher REJECTION (mardūd) and must not advance.
            // Projection assumes every day passes (else a forecast could never
            // progress).
            val pass = if (cur.requireVerified && !projection) {
                fold.verifiedCompleted.contains(uid)
            } else {
                done
            }

            if (e.advancesCursor != null) {
                if (pass) {
                    if (e.type == "tilawah") {
                        cursorIdx = e.advancesCursor.nextCursor
                    } else {
                        onNewCompleted(d, e.advancesCursor, pol, cur)
                        newCompletedToday = true
                        extraConsumedThisDay = currentDayExtra
                    }
                } else if (!projection && d < today && !fold.excused.contains(uid)) {
                    if (e.type != "tilawah") {
                        // D-048: a fail becomes debt — missed, unmastered or mardūd alike.
                        debtNew.add(DebtEntry(d, coalesceInTraversalOrder(e.ayahs, index), e.ayahs.sumOf { weightMicro[it] }))
                    }
                }
            }
            if (e.murajaahCursorAfter != null && done) {
                rotationCursors[e.originRuleId] = e.murajaahCursorAfter
            }

            // E-5 (D-047): a task_failed trigger fires when the task its rule
            // emitted today was NOT verified. Only on a CLOSED day — an open
            // day's test has not been sat yet, and a projected day is assumed to
            // pass (§8/D-043, the same principle as debt).
            if (d < today) {
                for (t in cur.triggers) {
                    if (t.on.taskFailed != e.originRuleId) continue
                    if (fold.verifiedCompleted.contains(uid) || fold.excused.contains(uid)) continue
                    for ((effIndex, eff) in t.effects.withIndex()) {
                        applyEffect(eff, effIndex, t.id, 0, d, pol, cur)
                    }
                }
            }
        }

        // redistribution bookkeeping: each valid redistribution day consumes one of the N days
        redistribution?.let { r ->
            if (currentDayExtra != null) {
                r.remainingDays -= 1
                if (newCompletedToday && extraConsumedThisDay != null) {
                    r.remainingMicro = maxOf(0L, (r.remainingMicro ?: 0L) - extraConsumedThisDay)
                    dischargeDebt(extraConsumedThisDay) // D-049: the extra IS the catch-up
                }
                if (r.remainingDays <= 0 || (r.remainingMicro ?: Long.MAX_VALUE) <= 0L) redistribution = null
            }
        }
        currentDayExtra = null
    }

    // ------------------------------------------------------- new selection --

    /** Extra µp applied to today's new amount under an active redistribute recovery. */
    private var currentDayExtra: Long? = null

    private fun selectNew(
        cursor: Int,
        d: LocalDate,
        pol: PlanPolicy,
        cur: CompiledCurriculum,
        includeExtra: Boolean,
    ): Selection? {
        val amount = paceAmount(pol, cur)
        // PCC-3: the corpus resolves the DSL amount. A count-based amount (`ayah`/`custom`) walks
        // by unit count and — §11.27, incommensurable units — never receives a µp redistribute
        // extra; a unit this corpus cannot resolve at all is a thrown, typed error, never a
        // silent zero.
        when (val resolved = index.amountMicroPages(amount)) {
            is AmountResolution.CountUnit ->
                return nextNewByAyahCount(walk, cursor, resolved.value, index)
            is AmountResolution.MicroPages -> {
                var micro = resolved.value
                if (includeExtra) {
                    val extra = redistributionExtra(d, pol, cur)
                    if (extra != null) {
                        currentDayExtra = extra
                        micro += extra
                    }
                }
                return nextNew(walk, cursor, micro, index)
            }
            AmountResolution.Unsupported -> throw CurriculumValidationException(
                "amount unit '${amount.unit.code}' is not defined for this corpus " +
                    "(boundary kind '${index.boundaryKind}')"
            )
        }
    }

    private fun paceAmount(pol: PlanPolicy, cur: CompiledCurriculum): QuranAmount =
        newAmountSpec(cur)?.let { resolveAmount(it, pol, cur) } ?: pol.newAmount

    /**
     * PCC-3 µp resolution of a DSL amount against the plan's corpus. A count-based amount is exact
     * only when every atomic unit has the same µp weight (the poem corpus); nonuniform Qurʾān ayah
     * counts remain incommensurable with a µp ramp/ceiling.
     */
    private fun amountMicro(amount: QuranAmount, where: String): Long =
        when (val resolved = index.amountMicroPages(amount)) {
            is AmountResolution.MicroPages -> resolved.value
            is AmountResolution.CountUnit -> uniformUnitMicroPages
                ?.let { Math.multiplyExact(resolved.value.toLong(), it) }
                ?: throw CurriculumValidationException(
                    "$where: unit '${amount.unit.code}' is count-based and this corpus has nonuniform unit weights"
                )
            AmountResolution.Unsupported -> throw CurriculumValidationException(
                "$where: unit '${amount.unit.code}' is not defined for this corpus " +
                    "(boundary kind '${index.boundaryKind}')"
            )
        }

    private fun redistributionExtra(d: LocalDate, pol: PlanPolicy, cur: CompiledCurriculum): Long? {
        val r = redistribution ?: return null
        if (r.remainingDays <= 0) return null
        if (d <= r.appliedOn) return null // §11.10: strictly after the application date
        // only valid memorization weekdays — never Fri/Sat/exception days (§7.9);
        // §11.19: redistribute targets respect policy.active_weekdays
        val dayClass = cur.dayClassOfWeekday[d.weekday] ?: return null
        if (dayClass !in newHifzDayClasses(cur)) return null
        if (d.weekday !in pol.activeWeekdays) return null
        // §11.28: debt fixed lazily on the first boosted day — Σ over accumulated
        // missed-new entries of their still-uncovered ayah weight (slot-based;
        // identical re-selected ranges count once per missed day).
        val remaining = r.remainingMicro ?: debtNew.sumOf { it.owedMicro }.also { r.remainingMicro = it }
        if (remaining <= 0L) return null
        var extra = roundHalfUpDiv(remaining, r.remainingDays.toLong())
        r.maxExtraMicro?.let { extra = minOf(extra, it) }
        return extra
    }

    private fun activateRecoveryIfDue(d: LocalDate, pol: PlanPolicy) {
        // §11.10: the latest plan.recovery_applied wins
        while (pendingRecoveryDates.isNotEmpty() && pendingRecoveryDates.first() <= d) {
            val appliedOn = pendingRecoveryDates.removeFirst()
            val rp = pol.recoveryPolicy
            if (rp is RecoveryPolicy.Redistribute) {
                redistribution = Redistribution(
                    appliedOn = appliedOn,
                    remainingMicro = null, // §11.28: fixed lazily on the first boosted day
                    remainingDays = rp.days,
                    maxExtraMicro = rp.maxExtra?.let { amountMicro(it, "recovery_policy.max_extra") },
                )
            }
            // strict_backlog / pause_and_resume: no schedule mutation here
        }
    }

    private fun onNewCompleted(d: LocalDate, sel: Selection, pol: PlanPolicy, cur: CompiledCurriculum) {
        for (a in sel.ayahs) {
            if (!completedAyah[a]) {
                completedAyah[a] = true
                juzRemaining[boundaryOfUnit[a] - 1] -= 1
            }
        }
        ledger[d] = sel.ayahs
        cursorIdx = sel.nextCursor

        // juz boundary triggers: fire on the completion that covers a full juz (in-plan only)
        for (j in 1..boundaryCount) {
            if (!juzFired[j - 1] && juzRemaining[j - 1] == 0) fireJuzCompleted(j, d, pol, cur)
        }
        // target completion (R-C1)
        if (cursorIdx >= walk.size && !planCompleted) {
            for (t in cur.triggers) {
                if (t.on.boundary == "target" && t.effects.any { it is TriggerEffect.CompletePlan }) {
                    planCompleted = true
                }
            }
        }
    }

    // ------------------------------------------------------------ triggers --

    /**
     * D-049: discharge [mp] of catch-up work against the OLDEST lost slots first.
     * Only work BEYOND a day's base amount repays a slot — one day's normal ḥifẓ
     * cannot repay a day that was lost.
     */
    private fun dischargeDebt(mp: Long) {
        var left = mp
        for (entry in debtNew) {
            if (left <= 0L) break
            val take = minOf(entry.owedMicro, left)
            entry.owedMicro -= take
            left -= take
        }
        debtNew.removeAll { it.owedMicro <= 0L }
    }

    /**
     * D-048: was this week inserted because the learner FAILED something (a
     * task_failed trigger), rather than by the curriculum's own design (a juzʾ
     * boundary)? A failure week costs advancement slots the learner did not
     * choose to give up, so those slots owe debt; a planned one does not.
     */
    private fun isFailureWeek(week: ConsWeek, cur: CompiledCurriculum): Boolean =
        cur.triggers.firstOrNull { it.id == week.triggerId }?.on?.taskFailed != null

    private fun fireJuzCompleted(j: Int, d: LocalDate, pol: PlanPolicy, cur: CompiledCurriculum) {
        juzFired[j - 1] = true
        juzDoneCount += 1
        completedJuzList.add(j)

        for (t in cur.triggers) {
            if (t.on.boundary != "juz") continue
            val every = t.on.every?.let { resolveInt(it, pol, cur) } ?: 1
            if (every <= 0 || juzDoneCount % every != 0) continue
            for ((effIndex, eff) in t.effects.withIndex()) applyEffect(eff, effIndex, t.id, j, d, pol, cur)
        }
    }

    private fun applyEffect(
        eff: TriggerEffect,
        effIndex: Int,
        triggerId: String,
        juz: Int,
        d: LocalDate,
        pol: PlanPolicy,
        cur: CompiledCurriculum,
    ) {
        when (eff) {
            is TriggerEffect.Schedule -> {
                val spec = when (val s = eff.select) {
                    is SelectorRef.Named -> cur.selectors.getValue(s.name)
                    is SelectorRef.Inline -> s.spec
                }
                // §11.2: origin = "{trigger_id}.{task_type}", ordering = 90 + effect index
                val origin = "$triggerId.${eff.type}"
                val ordering = TRIGGER_ORDERING_BASE + effIndex
                val session = eff.intoSession ?: "morning"
                if (eff.distributeOverDays != null) {
                    // §11.22: slice k (1-based) lands on fire_date + k. Empty slices emit
                    // nothing and their day stays empty (no compaction). Pause/exception days
                    // and already-occupied days skip forward (occupied-day rule §11.11).
                    val parts = when (spec) {
                        is SelectorSpec.PriorHifzSplit -> resolveInt(spec.parts, pol, cur)
                        else -> eff.distributeOverDays
                    }
                    val pool = priorHifzAyahs(excludeJuz = juz)
                    if (pool.isNotEmpty()) {
                        val weights = LongArray(pool.size) { weightMicro[pool[it]] }
                        val slices = splitNearEqual(pool, weights, parts)
                        for (k in 1..parts) {
                            val slice = slices[k - 1]
                            if (slice.isEmpty()) continue // day stays empty
                            var day = d.plusDays(k)
                            var guard = 0
                            while ((fold.isPaused(day) || exceptions.containsKey(day) ||
                                    distributionByDate.containsKey(day)) &&
                                guard < NEXT_ACTIVE_DAY_SEARCH_LIMIT
                            ) {
                                day = day.plusDays(1)
                                guard++
                            }
                            distributionByDate[day] = DistSlice(
                                eff.type, origin, session, ordering, slice,
                                slice.sumOf { weightMicro[it] },
                                estMinutesOverride = eff.estMinutes,
                            )
                            val last = lastDistributionDate
                            if (last == null || day > last) lastDistributionDate = day
                        }
                    }
                } else {
                    val ayahs = when (spec) {
                        is SelectorSpec.CompletedJuz -> juzAyahsOrdered(juz)
                        is SelectorSpec.Block -> blockAyahs(resolveInt(spec.juzCount, pol, cur))
                        is SelectorSpec.Fixed -> spec.ranges.flatMap { fixedGlobals(it).toList() }.toIntArray()
                        else -> throw CurriculumValidationException("unsupported schedule selector for ${eff.type}")
                    }
                    val startDay = nextActiveDay(d) // starting: next_active_day (D-028 (5))
                    pendingScheduled.getOrPut(startDay) { mutableListOf() }
                        .add(ScheduledTask(eff.type, origin, session, ordering, ayahs, eff.estMinutes))
                }
            }

            is TriggerEffect.InsertWeek -> {
                val mode = eff.modeVar?.let { varEnum(it, pol, cur) } ?: "pause_new"
                // D-017: the consolidation week is the next full week AFTER any pending
                // distribution finishes; overlapping weeks defer by whole weeks.
                val drainEnd = lastDistributionDate ?: d
                var candidate = nextWeekStart(d, cur)
                while (candidate <= drainEnd) candidate = candidate.plusDays(7)
                consolidationWeeks.add(ConsWeek(candidate, candidate.plusDays(6), triggerId, mode, eff.dayRules))
                cyclesFired += 1
            }

            TriggerEffect.CompletePlan -> planCompleted = true

            // §11.24: parsed but inert in v1 engines
            is TriggerEffect.SetFlag -> Unit
            is TriggerEffect.ClearFlag -> Unit
        }
    }

    private fun nextWeekStart(d: LocalDate, cur: CompiledCurriculum): LocalDate {
        val ws = cur.calendar.weekStart
        val offset = ((ws.ordinal - d.weekday.ordinal + 6).mod(7)) + 1 // 1..7 days strictly after d
        return d.plusDays(offset.toLong())
    }

    private fun nextActiveDay(d: LocalDate): LocalDate {
        var e = d
        var guard = 0
        while (guard < NEXT_ACTIVE_DAY_SEARCH_LIMIT) {
            e = e.plusDays(1)
            guard++
            if (fold.isPaused(e) || exceptions.containsKey(e)) continue
            // PC-4: "active" is judged against the curriculum in force on the CANDIDATE day.
            val curE = curOn(e)
            val cls = curE.dayClassOfWeekday[e.weekday] ?: continue
            // §11.19: "next active day" respects policy.active_weekdays and day-class
            if (cls in newHifzDayClasses(curE) && e.weekday in policyAt(e).activeWeekdays) return e
        }
        throw IllegalStateException("no active day found after $d")
    }

    // ----------------------------------------------------------- selectors --

    private fun weekStart(d: LocalDate, cur: CompiledCurriculum): LocalDate {
        val ws = cur.calendar.weekStart
        val back = (d.weekday.ordinal - ws.ordinal + 7).mod(7)
        return d.minusDays(back)
    }

    private fun dayOffsetInWeek(w: Weekday, cur: CompiledCurriculum): Long {
        val ws = cur.calendar.weekStart
        return ((w.ordinal - ws.ordinal + 7).mod(7)).toLong()
    }

    /** Global unit ids of a `fixed` selector range; out-of-corpus is a hard, named failure. */
    private fun fixedGlobals(range: masoon.domain.CanonicalRange): IntRange =
        index.globalRangeOf(range)
            ?: throw CurriculumValidationException("fixed selector range outside the corpus: $range")

    /** Global unit ids of structural boundary [n] (juzʾ for the Qurʾān, work for a poem corpus). */
    private fun boundaryGlobals(n: Int): IntRange =
        index.boundaryGlobalRange(n)
            ?: throw CurriculumValidationException("boundary $n is outside the corpus")

    /** Union of ledger over [d-days, d-1], in TRAVERSAL order of the plan's
     *  memorization order (ENGINE_PARITY §3; 2026-07-13 audit AX-04 — a
     *  mushaf-ascending sort here diverged from Swift/TS on backward plans). */
    private fun ledgerUnion(fromDate: LocalDate, toDate: LocalDate): IntArray {
        val set = sortedSetOf<Int>()
        var d = fromDate
        while (d <= toDate) {
            ledger[d]?.let { for (a in it) set.add(a) }
            d = d.plusDays(1)
        }
        return set.sortedBy { orderPos(it) }.toIntArray()
    }

    private fun ledgerWindowAyahs(
        d: LocalDate,
        spec: SelectorSpec.LedgerWindow,
        pol: PlanPolicy,
        cur: CompiledCurriculum,
    ): IntArray {
        val days = if (d.weekday == cur.calendar.weekStart && spec.sundayDays != null) {
            resolveInt(spec.sundayDays, pol, cur)
        } else {
            resolveInt(spec.days, pol, cur)
        }
        return ledgerUnion(d.minusDays(days), d.minusDays(1))
    }

    /** H-5 (2026-07-16): union of every warm-up window whose rule EMITS today —
     *  the murājaʿah pool subtracts what warm-up actually covers today
     *  (§4 "no double coverage"), not one hardcoded window. Empty on days with
     *  no warm-up. Mirrors the daily rule-match gate. */
    private fun warmupSubtractAyahs(
        d: LocalDate,
        dayClass: String?,
        consWeek: ConsWeek?,
        pol: PlanPolicy,
        cur: CompiledCurriculum,
    ): IntArray {
        val set = sortedSetOf<Int>()
        for (rule in cur.rules) {
            if (rule.emit.type != "warmup") continue
            if (dayClass == null || dayClass !in rule.whenSpec.dayClasses) continue
            if ("first_active_day" in rule.whenSpec.not && d == firstActiveDay) continue
            if ("in_consolidation_week" in rule.whenSpec.not && consWeek != null) continue
            if (rule.whenSpec.enabled != null && !varBool(rule.whenSpec.enabled, pol, cur)) continue
            if (rule.whenSpec.dayIn != null && d.weekday !in varWeekdaySet(rule.whenSpec.dayIn, pol, cur)) continue
            val spec = when (val sel = rule.emit.select) {
                is SelectorRef.Named -> cur.selectors[sel.name]
                is SelectorRef.Inline -> sel.spec
                null -> null
            }
            if (spec is SelectorSpec.LedgerWindow) for (a in ledgerWindowAyahs(d, spec, pol, cur)) set.add(a)
        }
        return set.sortedBy { orderPos(it) }.toIntArray()
    }

    private fun weekToDateAyahs(d: LocalDate, cur: CompiledCurriculum): IntArray =
        ledgerUnion(weekStart(d, cur), d.minusDays(1))

    /** Prior-hifz pool: in-plan completed ∪ declared, optionally excluding one juz, in memorization order. */
    private fun priorHifzAyahs(excludeJuz: Int?): IntArray {
        val exclude = excludeJuz?.let { boundaryGlobals(it) }
        val out = mutableListOf<Int>()
        for (a in 0 until totalUnits) {
            if (!completedAyah[a] && !declaredAyah[a]) continue
            if (exclude != null && a in exclude) continue
            out.add(a)
        }
        out.sortBy { orderPos(it) }
        return out.toIntArray()
    }

    private fun juzAyahsOrdered(j: Int): IntArray =
        boundaryGlobals(j).sortedBy { orderPos(it) }.toIntArray()

    /** Last-N-juz block, block juz in memorization-order (completion) sequence. */
    private fun blockAyahs(juzCount: Int): IntArray {
        val block = completedJuzList.takeLast(juzCount)
        val out = mutableListOf<Int>()
        for (j in block) out.addAll(juzAyahsOrdered(j).toList())
        return out.toIntArray()
    }

    /**
     * Consolidation-week weekday slice (ENGINE_SEMANTICS §6/§11.8): slice k of the last-cycle
     * block, where k = count of same-day-class days since the inserted week began. When the
     * block has exactly `parts` juz, slice k is exactly the k-th block juz; otherwise a
     * near-equal µp split.
     */
    private fun blockSliceAyahs(
        spec: SelectorSpec.BlockSlice,
        d: LocalDate,
        dayClass: String,
        consWeek: ConsWeek?,
        pol: PlanPolicy,
        cur: CompiledCurriculum,
    ): IntArray {
        val ofSpec = cur.selectors.getValue(spec.of)
        val juzCount = when (ofSpec) {
            is SelectorSpec.Block -> resolveInt(ofSpec.juzCount, pol, cur)
            else -> throw CurriculumValidationException("block_slice.of must reference a block selector")
        }
        val block = completedJuzList.takeLast(juzCount)
        if (block.isEmpty()) return IntArray(0)
        // slot index = same-day-class days since the week began, before today (§11.8)
        val weekBegin = consWeek?.start ?: weekStart(d, cur)
        var k = 0
        var e = weekBegin
        while (e < d) {
            if (!fold.isPaused(e) && !exceptions.containsKey(e) &&
                curOn(e).dayClassOfWeekday[e.weekday] == dayClass
            ) {
                k++
            }
            e = e.plusDays(1)
        }
        if (k >= spec.parts) return IntArray(0)
        return if (block.size == spec.parts) {
            juzAyahsOrdered(block[k])
        } else {
            val all = blockAyahs(juzCount)
            val weights = LongArray(all.size) { weightMicro[all[it]] }
            val slices = splitNearEqual(all, weights, spec.parts)
            if (k < slices.size) slices[k] else IntArray(0)
        }
    }

    /** Completed weeks since the first active day: week-start days after it and ≤ d (D-029). */
    private fun completedWeeks(d: LocalDate, cur: CompiledCurriculum): Long {
        val firstWs = nextWeekStart(firstActiveDay, cur)
        if (d < firstWs) return 0L
        return (d.epochDay - firstWs.epochDay) / 7L + 1L
    }

    /**
     * R-M1 murajaah rotation slice (ENGINE_SEMANTICS §4). Returns (ayahs, cursor-after) or null.
     * `sliceMicro` = today's distributed-review slice size; it takes ceiling priority (GX-09).
     */
    /** E-1 (D-038): resolve a murājaʿah pool window to ayah indices, order-sorted.
     *  prior_hifz = all memorized minus today's warm-up windows; a recent window
     *  = the most-recently-memorized N pages/juz by memorization order (does NOT
     *  subtract warm-up). */
    private fun murajaahPoolPositions(
        pool: SelectorSpec.PoolWindow,
        d: LocalDate,
        dayClass: String?,
        consWeek: ConsWeek?,
        pol: PlanPolicy,
        cur: CompiledCurriculum,
    ): List<Int> = when (pool) {
        is SelectorSpec.PoolWindow.PriorHifz -> {
            val inWindow = warmupSubtractAyahs(d, dayClass, consWeek, pol, cur).toHashSet()
            (0 until totalUnits)
                .filter { (completedAyah[it] || declaredAyah[it]) && it !in inWindow }
                .sortedBy { orderPos(it) }
        }
        // E-1b (D-043): the complement pools derive from the SAME backwards walk
        // as the recent window, so the two can never drift apart.
        is SelectorSpec.PoolWindow.RecentPages, is SelectorSpec.PoolWindow.RecentJuz,
        is SelectorSpec.PoolWindow.AllExceptRecentPages, is SelectorSpec.PoolWindow.AllExceptRecentJuz -> {
            val unitMp = when (pool) {
                is SelectorSpec.PoolWindow.RecentPages, is SelectorSpec.PoolWindow.AllExceptRecentPages ->
                    MICRO_PAGES_PER_PAGE
                // PCC-3: a "recent N boundaries" window needs a fixed per-boundary µp size. A
                // corpus that has none (a poem collection, whose works vary widely) must fail by
                // name here, never silently borrow the Qurʾān's 20 pages per juzʾ.
                else -> index.boundaryUnitMicroPages ?: throw CurriculumValidationException(
                    "pool window 'recent boundaries' is undefined for this corpus " +
                        "(boundary kind '${index.boundaryKind}' has no fixed micropage size)"
                )
            }
            val count = when (pool) {
                is SelectorSpec.PoolWindow.RecentPages -> resolveInt(pool.count, pol, cur)
                is SelectorSpec.PoolWindow.RecentJuz -> resolveInt(pool.count, pol, cur)
                is SelectorSpec.PoolWindow.AllExceptRecentPages -> resolveInt(pool.count, pol, cur)
                is SelectorSpec.PoolWindow.AllExceptRecentJuz -> resolveInt(pool.count, pol, cur)
                else -> 0
            }
            val complement = pool is SelectorSpec.PoolWindow.AllExceptRecentPages ||
                pool is SelectorSpec.PoolWindow.AllExceptRecentJuz
            val target = count.toLong() * unitMp
            val mem = (0 until totalUnits)
                .filter { completedAyah[it] || declaredAyah[it] }
                .sortedBy { orderPos(it) }
            var cut = mem.size // first index INSIDE the recent window
            var acc = 0L
            for (i in mem.indices.reversed()) {
                if (acc >= target) break
                cut = i; acc += weightMicro[mem[i]]
            }
            if (!complement) {
                mem.subList(cut, mem.size).sortedBy { orderPos(it) }
            } else {
                // Rolled-off material is an "old material" layer, so — like
                // PriorHifz — it subtracts today's warm-up union.
                val inWindow = warmupSubtractAyahs(d, dayClass, consWeek, pol, cur).toHashSet()
                mem.subList(0, cut).filter { it !in inWindow }.sortedBy { orderPos(it) }
            }
        }
    }

    private fun murajaahSlice(
        d: LocalDate,
        spec: SelectorSpec.PoolRotation,
        pol: PlanPolicy,
        cur: CompiledCurriculum,
        sliceMicro: Long,
        dayClass: String?,
        consWeek: ConsWeek?,
        ruleId: String,
    ): Pair<IntArray, Int>? {
        val pool = murajaahPoolPositions(spec.pool, d, dayClass, consWeek, pol, cur)
        if (pool.isEmpty()) return null
        val rotationCursorPos = rotationCursors[ruleId] ?: 0  // E-1: per-layer cursor

        var poolSlicing = 0L
        for (a in pool) poolSlicing += slicingWeight[a]

        val m = when (val pd = spec.perDay) {
            is SelectorSpec.PerDay.CycleDays -> {
                // E-3a (D-045): cover the WHOLE pool every N days. The amount derives
                // from the POOL, so the per-item interval stays fixed as the corpus
                // grows. Ceil ⇒ "at least once every N days". No ceiling exists in
                // this mode, so the GX-09 distributed-slice clamp does not apply, and
                // the policy ramp override does not either.
                val n = resolveInt(pd.days, pol, cur).toLong()
                if (n < 1L) throw CurriculumValidationException(
                    "pool_rotation.per_day.cycle_days must be >= 1 (got $n)"
                )
                minOf((poolSlicing + n - 1L) / n, poolSlicing)
            }
            is SelectorSpec.PerDay.Ramp -> {
                val ceiling = amountMicro(resolveAmount(pd.ceiling, pol, cur), "pool_rotation.ramp.ceiling")
                val effCeiling = maxOf(0L, ceiling - sliceMicro)
                // §11.7: ramp start from policy.murajaah_ramp.start when present, else the DSL literal;
                // the pool-size clamp uses SLICING-weight totals so "whole pool once" holds under weak-boost
                val start = amountMicro(
                    pol.murajaahRamp?.start ?: resolveAmount(pd.start, pol, cur),
                    "pool_rotation.ramp.start",
                )
                val step = amountMicro(
                    pol.murajaahRamp?.step ?: resolveAmount(pd.step, pol, cur),
                    "pool_rotation.ramp.step",
                )
                val ramp = start + step * completedWeeks(d, cur)
                minOf(effCeiling, ramp, poolSlicing)
            }
        }
        if (m <= 0L) return null

        // whole pool at most once
        if (poolSlicing <= m) {
            val arr = pool.toIntArray()
            return Pair(arr, orderPos(pool.last()) + 1)
        }

        // find start: first pool ayah at-or-after the rotation cursor (wrap to pool start)
        var startIdx = pool.indexOfFirst { orderPos(it) >= rotationCursorPos }
        if (startIdx < 0) startIdx = 0

        val out = mutableListOf<Int>()
        var acc = 0L
        var i = startIdx
        while (acc < m) {
            val a = pool[i % pool.size]
            out.add(a)
            acc += slicingWeight[a]
            i++
        }
        // Cursor advances past the traversal-last ayah; the CONTENT serializes
        // in memorization order (ENGINE_PARITY §3) — a wrapped slice must not
        // leak rotation order into the stream (2026-07-13 audit AX-01).
        val next = orderPos(out.last()) + 1
        out.sortBy { orderPos(it) }
        return Pair(out.toIntArray(), next)
    }

    /**
     * R-L1 `tomorrow_new` (ENGINE_SEMANTICS §7): the new-hifz content of the next day E > D where
     * R-N1 will actually emit (skip weekends, exception days, consolidation weeks; look ahead
     * ≤ 14 days), projected assuming D's new material completes.
     */
    private fun tomorrowNewAyahs(d: LocalDate, todayNew: Selection?): IntArray {
        if (planCompleted) return IntArray(0)
        val cursorAfterToday = todayNew?.nextCursor ?: cursorIdx
        var e = d
        for (k in 1..TOMORROW_NEW_LOOKAHEAD_DAYS) {
            e = e.plusDays(1)
            if (fold.isPaused(e) || exceptions.containsKey(e)) continue
            // §7/§11.9: the look-ahead is evaluated against the curriculum AND policy in force on
            // E, not on D — a curriculum switch between the two changes both which rule fires and
            // how much it takes.
            val curE = curOn(e)
            val cls = curE.dayClassOfWeekday[e.weekday] ?: continue
            if (cls !in newHifzDayClasses(curE)) continue
            val polE = policyAt(e)
            // §11.19: R-N1 emission days respect active_weekdays
            if (e.weekday !in polE.activeWeekdays) continue
            val week = consolidationWeeks.firstOrNull { e in it }
            if (week != null && week.mode == "pause_new") continue
            // §11.9: effective policy at E, ignoring redistribute-extras and unscheduled weeks
            val sel = selectNewAt(cursorAfterToday, polE, curE)
            return sel?.ayahs ?: IntArray(0)
        }
        return IntArray(0)
    }

    /** Projected next-new at another day (base amount; no redistribution extra). */
    private fun selectNewAt(cursor: Int, pol: PlanPolicy, cur: CompiledCurriculum): Selection? {
        val amount = paceAmount(pol, cur)
        return when (val resolved = index.amountMicroPages(amount)) {
            is AmountResolution.CountUnit -> nextNewByAyahCount(walk, cursor, resolved.value, index)
            is AmountResolution.MicroPages -> nextNew(walk, cursor, resolved.value, index)
            AmountResolution.Unsupported -> throw CurriculumValidationException(
                "amount unit '${amount.unit.code}' is not defined for this corpus " +
                    "(boundary kind '${index.boundaryKind}')"
            )
        }
    }

    // ------------------------------------------------- variables & amounts --

    /**
     * §11.21 resolution precedence: `variable_overrides` ▸ named policy field ▸ the DSL default of
     * the curriculum in force on the day being generated (PC-4 — a switched-to curriculum declares
     * its own variables, so the default must come from IT, not from the base).
     */
    private fun varValue(name: String, pol: PlanPolicy, cur: CompiledCurriculum): VarValue? =
        pol.variableOverrides[name]
            ?: policyBoundVar(name, pol)
            ?: cur.variables[name]?.let { defaultToValue(it.default) }

    /** Engine bindings of curriculum variables to explicit PlanPolicy fields. */
    private fun policyBoundVar(name: String, pol: PlanPolicy): VarValue? = when (name) {
        "takrar_count" -> pol.takrarCount?.let { VarValue.IntV(it) }
        "takrar_spacing_min" -> pol.takrarSpacingMinutes?.let { VarValue.IntV(it) }
        "listening_days" -> pol.listeningDays?.let { VarValue.WeekdaySetV(it) }
        "listening_count" -> pol.listeningCount?.let { VarValue.IntV(it) }
        "murajaah_ceiling" -> pol.murajaahDailyCeiling?.let { VarValue.AmountV(it) }
        "murajaah_ramp_step" -> pol.murajaahRamp?.let { VarValue.AmountV(it.step) }
        "cycle_week_mode" -> pol.cycleWeekMode?.let { VarValue.StrV(it) }
        else -> null
    }

    private fun defaultToValue(d: VarDefault): VarValue = when (d) {
        is VarDefault.IntD -> VarValue.IntV(d.value)
        is VarDefault.BoolD -> VarValue.BoolV(d.value)
        is VarDefault.StrD -> VarValue.StrV(d.value)
        is VarDefault.AmountD -> VarValue.AmountV(d.value)
        is VarDefault.WeekdaySetD -> VarValue.WeekdaySetV(d.value)
    }

    private fun varInt(name: String, pol: PlanPolicy, cur: CompiledCurriculum): Int =
        (varValue(name, pol, cur) as? VarValue.IntV)?.value
            ?: throw CurriculumValidationException("variable $name is not an int")

    private fun varBool(name: String, pol: PlanPolicy, cur: CompiledCurriculum): Boolean =
        (varValue(name, pol, cur) as? VarValue.BoolV)?.value
            ?: throw CurriculumValidationException("variable $name is not a bool")

    private fun varEnum(name: String, pol: PlanPolicy, cur: CompiledCurriculum): String =
        (varValue(name, pol, cur) as? VarValue.StrV)?.value
            ?: throw CurriculumValidationException("variable $name is not an enum")

    private fun varWeekdaySet(name: String, pol: PlanPolicy, cur: CompiledCurriculum): Set<Weekday> =
        (varValue(name, pol, cur) as? VarValue.WeekdaySetV)?.value
            ?: throw CurriculumValidationException("variable $name is not a weekday_set")

    private fun varAmount(name: String, pol: PlanPolicy, cur: CompiledCurriculum): QuranAmount {
        if (name == CurriculumLoader.RESERVED_PACE_VAR) {
            // D-028 (1): $pace binds to PlanPolicy.new_amount, falling back to units.default_pace
            return pol.newAmount
        }
        return (varValue(name, pol, cur) as? VarValue.AmountV)?.value
            ?: throw CurriculumValidationException("variable $name is not an amount")
    }

    private fun resolveInt(v: VarOr<Int>, pol: PlanPolicy, cur: CompiledCurriculum): Int = when (v) {
        is VarOr.Lit -> v.value
        is VarOr.Ref -> varInt(v.name, pol, cur)
    }

    private fun resolveAmount(
        v: VarOr<QuranAmount>,
        pol: PlanPolicy,
        cur: CompiledCurriculum,
    ): QuranAmount = when (v) {
        is VarOr.Lit -> v.value
        is VarOr.Ref -> varAmount(v.name, pol, cur)
    }

    // -------------------------------------------------- workload & evidence --

    /**
     * Workload model (ENGINE_SEMANTICS §1, D-015): per-unit strength-weighted micropage math,
     * round-half-up at the single division point. Listening is flat per lesson.
     *
     * Evaluation order, matching Swift and TypeScript exactly (B:CB-0 findings 2 and 4):
     *   1. an authored `est_minutes` override (B:CB-2) — ahead of everything, including the
     *      `prep_dhikr` zero-out;
     *   2. `prep_dhikr` ⇒ 0 (§11.3);
     *   3. `rates[type]` ▸ `rates[fallbackKey]` ▸ 0 — a missing rate is a defined zero, never a
     *      crash and never a silently different rate.
     */
    private fun estMinutes(
        type: String,
        ayahs: IntArray,
        reps: Int?,
        listenCount: Int?,
        estMinutesOverride: Int?,
        cur: CompiledCurriculum,
    ): Int {
        if (estMinutesOverride != null) return estMinutesOverride
        if (type == "prep_dhikr") return 0
        val rates = cur.forecast.workloadRates
        if (type == "listening") {
            // §11.16: rate[listening_lesson] × listen_count
            val rate = rates["listening_lesson"] ?: rates[type] ?: 0L
            return (rate * (listenCount ?: 1).toLong()).toInt()
        }
        if (ayahs.isEmpty()) return 0
        val rateKey = when (type) {
            "new_hifz" -> "new_hifz"
            "warmup" -> "warmup"
            "murajaah" -> "murajaah"
            "takrar", "weekend_consolidation" -> "takrar_rep"
            // review-class types have no dedicated rate in the DSL; murajaah rate is the
            // deterministic stand-in (flagged as a semantic gap)
            else -> "murajaah"
        }
        var rate = rates[type] ?: rates[rateKey] ?: 0L
        if (rateKey == "takrar_rep") rate *= (reps ?: 1).toLong()
        var weighted = 0L
        for (a in ayahs) weighted += weightMicro[a] * strengthScaled[a]
        return roundHalfUpDiv(rate * weighted, WORKLOAD_DENOMINATOR).toInt()
    }

    private fun evidenceFor(type: String, pol: PlanPolicy, cur: CompiledCurriculum): String {
        val resolved =
            pol.evidencePolicy[type] ?: run {
                val spec = cur.evidenceDefaults[type]
                    ?: cur.evidenceDefaults["default"]
                    ?: EvidenceDefaultSpec.SelfCheck
                resolveEvidence(spec, pol, cur)
            }
        return teacherlessFallback(resolved, type, cur).compact()
    }

    private fun resolveEvidence(
        spec: EvidenceDefaultSpec,
        pol: PlanPolicy,
        cur: CompiledCurriculum,
    ): EvidenceSpec = when (spec) {
        EvidenceDefaultSpec.SelfCheck -> EvidenceSpec.SelfCheck
        is EvidenceDefaultSpec.Timer -> EvidenceSpec.Timer(resolveInt(spec.minSeconds, pol, cur))
        is EvidenceDefaultSpec.Counter -> EvidenceSpec.Counter(resolveInt(spec.target, pol, cur))
        is EvidenceDefaultSpec.TeacherVerification -> EvidenceSpec.TeacherVerification(spec.formVersionId)
        is EvidenceDefaultSpec.Form -> EvidenceSpec.Form(spec.formVersionId)
        is EvidenceDefaultSpec.Composite ->
            EvidenceSpec.Composite(spec.parts.map { resolveEvidence(it, pol, cur) })
    }

    /**
     * L12 (D-182/D-183, ported from `Engine.swift`'s own `teacherlessFallback`): a solo learner
     * with no assigned teacher ([PlanGenerationContext.hasAssignedTeacher] `== false`) has no
     * in-app affordance to satisfy `teacher_verification` evidence. Two categories:
     *
     * (a) `new_hifz` under `cur.requireVerified` (only Deobandi ships this) is the teacher's
     *     maqbūl/mardūd accept/reject call — the curriculum's ONE non-negotiable,
     *     founder-adjudicated gate (D-041/D-046): a self-check cannot advance a maktab student.
     *     Left untouched even when teacherless — deliberately still blocked there.
     * (b) every OTHER `teacher_verification` default in the bundled curricula (Maknoon's/Wifaq's
     *     `tasmee`) carries NO such advancement gate, so for a teacherless learner it is simply an
     *     uncompletable task, not a pedagogical requirement — substitutes `self_check`.
     *
     * [PlanGenerationContext.hasAssignedTeacher] defaults to `true`, so every existing fixture
     * (which never sets it) and every org-enrolled/teacher-supervised context resolves evidence
     * exactly as before this fallback existed; only an explicit teacherless context changes.
     */
    private fun teacherlessFallback(spec: EvidenceSpec, type: String, cur: CompiledCurriculum): EvidenceSpec {
        if (context.hasAssignedTeacher || spec !is EvidenceSpec.TeacherVerification) return spec
        val isNonNegotiableGate = type == "new_hifz" && cur.requireVerified
        return if (isNonNegotiableGate) spec else EvidenceSpec.SelfCheck
    }
}
