package masoon.curriculum

import masoon.domain.ContentIndex
import masoon.domain.LocalDate
import masoon.domain.OrderSpec
import masoon.domain.PlanPolicy
import masoon.domain.RecoveryPolicy
import masoon.domain.SessionSpec
import masoon.domain.TargetRange
import masoon.domain.Weekday

/**
 * B7-C: [CurriculumSimulationGate]'s first real implementation (gate 4 of the [CurriculumValidator]
 * pipeline) — Kotlin port of `apps/ios/Packages/Sources/MasoonCurriculum/CurriculumSimulator.swift`.
 * Runs a draft's COMPILED curriculum through the real [Engine] — the SAME engine every other call
 * site uses, never a re-implementation — across the three canonical [SimulationProfile]s
 * (fresh/mid/hafiz) at two depths:
 *
 *   - PREVIEW ([PREVIEW_DAYS] = 60): fast, interactive. [simulate] — the [CurriculumSimulationGate]
 *     conformance the pipeline calls by default — runs PREVIEW depth only. A curriculum-builder UI
 *     calls this on every meaningful edit.
 *   - PUBLISH ([PUBLISH_DAYS] = 400, ×2 for a determinism proof): slow, explicit-only — [publish].
 *     Never invoked by the pipeline itself; a real authoring UI calls this once, right before
 *     actually publishing a draft, not on every edit.
 *
 * Both depths run the SAME [PlanPolicy] (synthesized generically from the curriculum's own
 * `default_pace`/session ids — [defaultPolicy] below) across all 3 profiles, with the engine's
 * `today` pinned to one day BEFORE a fixed [anchor]. `Engine`'s own rule ("dates <= `today` fold
 * actual events; dates after `today` run in projection mode") means this puts the ENTIRE simulated
 * window in projection mode: no synthetic completion events are needed, no debt accumulates, and
 * — this is the non-obvious part, ported verbatim from the Swift implementation's own finding — it
 * avoids a real duplicate-selection artifact that shows up whenever `anchor == today`: the anchor
 * day itself is still `date <= today` (fold-actual-events) with an empty event log, so it neither
 * advances the cursor nor is treated as a miss, and the very next (first projection) day
 * re-selects from the SAME un-advanced cursor, producing two calendar days of identical new-ḥifẓ
 * content. Pinning `today` one day before `anchor` sidesteps that entirely — every simulated date,
 * including the first, runs in clean projection mode.
 *
 * A fixed, literal anchor date (never the wall clock) keeps every run a pure function of the
 * curriculum alone, with no wall clock, randomness, locale, or I/O.
 * This allows [publish] to compare the output of two runs over identical inputs.
 */
class CurriculumSimulator(
    /**
     * The corpus this simulator runs curricula against — a real caller supplies the SAME
     * `ContentIndex` every other engine entry point uses.
     */
    private val index: ContentIndex,
) : CurriculumSimulationGate {

    // -- CurriculumSimulationGate conformance (gate 4 default: PREVIEW depth) -----------------

    /** The pipeline's gate 4 entry point. Deliberately PREVIEW depth, not PUBLISH — see the class doc's timing rationale. */
    override fun simulate(curriculum: CompiledCurriculum): List<CurriculumIssue> = preview(curriculum)

    // -- Preview (60 days x 3 profiles, fast) --------------------------------------------------

    /**
     * Runs all 3 profiles for [PREVIEW_DAYS] days and checks the 1440-minutes/day ceiling. No
     * determinism double-run at this depth — that is PUBLISH-only.
     */
    fun preview(curriculum: CompiledCurriculum): List<CurriculumIssue> {
        val issues = mutableListOf<CurriculumIssue>()
        for (profile in SimulationProfile.entries) {
            val result = run(curriculum, profile, PREVIEW_DAYS)
            issues += ceilingIssues(result, profile)
        }
        return issues.sortedWith(issueOrder)
    }

    // -- Per-day minutes (the builder's simulation-preview screen) -----------------------------

    /** One preview day's workload, exposed as real per-day data (not just pass/fail issues) for a chart. */
    data class DailyMinutesSummary(val date: LocalDate, val totalMinutes: Int, val taskCount: Int)

    /** Runs ONE profile at PREVIEW depth (60 days) and returns its per-day totals, sorted by date. */
    fun previewDailyMinutes(curriculum: CompiledCurriculum, profile: SimulationProfile): List<DailyMinutesSummary> {
        val result = run(curriculum, profile, PREVIEW_DAYS)
        val perDay = LinkedHashMap<LocalDate, IntArray>() // [0]=minutes, [1]=count
        for (task in result.tasks) {
            val acc = perDay.getOrPut(task.date) { intArrayOf(0, 0) }
            acc[0] += task.estimatedMinutes
            acc[1] += 1
        }
        return perDay.entries.sortedBy { it.key }.map { (date, acc) -> DailyMinutesSummary(date, acc[0], acc[1]) }
    }

    // -- Publish (400 days x 3 profiles, deep, + determinism double-run) -----------------------

    /**
     * The deeper, explicit-only check: 400 days x 3 profiles against the 1440-minutes/day
     * ceiling, PLUS the entire 400-day x 3-profile simulation run a SECOND time and diffed
     * byte-for-byte ([StreamSerializer] output) against the first — a determinism proof. Never
     * called by [CurriculumValidator]'s pipeline; a real authoring UI calls this once, right
     * before publish.
     */
    fun publish(curriculum: CompiledCurriculum): List<CurriculumIssue> {
        val runA = publishStreams(curriculum)
        val runB = publishStreams(curriculum)

        val issues = mutableListOf<CurriculumIssue>()
        for (profile in SimulationProfile.entries) {
            issues += ceilingIssues(runA.results.getValue(profile), profile)
            if (runA.streams[profile] != runB.streams[profile]) {
                // A genuine nondeterminism finding — deliberately NOT silently worked around or
                // loosened.
                issues += CurriculumIssue(
                    severity = IssueSeverity.ERROR, id = "SIM-NONDETERMINISTIC", gate = ValidationGate.SIMULATION,
                    path = JSONPointer(),
                    messageEn = "publish simulation is non-deterministic for profile '$profile': " +
                        "two runs over identical inputs produced different StreamSerializer output",
                    messageAr = "محاكاة النشر غير حتمية للملف الشخصي '$profile': " +
                        "أنتج تشغيلان بنفس المدخلات تمامًا مخرجات مختلفة",
                )
            }
        }
        return issues.sortedWith(issueOrder)
    }

    private data class PublishRun(
        val results: Map<SimulationProfile, GenerationResult>,
        val streams: Map<SimulationProfile, String>,
    )

    /** One full PUBLISH-depth pass: all 3 profiles, each serialized via the real [StreamSerializer]. */
    private fun publishStreams(curriculum: CompiledCurriculum): PublishRun {
        val results = mutableMapOf<SimulationProfile, GenerationResult>()
        val streams = mutableMapOf<SimulationProfile, String>()
        for (profile in SimulationProfile.entries) {
            val result = run(curriculum, profile, PUBLISH_DAYS)
            results[profile] = result
            streams[profile] = StreamSerializer.serialize(result)
        }
        return PublishRun(results, streams)
    }

    // -- One profile's run -----------------------------------------------------------------

    internal fun run(curriculum: CompiledCurriculum, profile: SimulationProfile, days: Int): GenerationResult {
        val policy = defaultPolicy(curriculum)
        val startingState = profile.startingState(index)
        val context = PlanGenerationContext(
            planId = planIds.getValue(profile),
            curriculum = curriculum,
            index = index,
            policy = policy,
            startingState = startingState,
            calendar = PlanCalendar(timezone = "UTC", anchorDate = anchor, orgExceptions = emptyList()),
            eventLog = emptyList(),
            today = today,
        )
        val window = DateRange(anchor, anchor.plusDays(days - 1))
        return Engine(curriculum).generateFull(context, window)
    }

    companion object {
        /** Fixed simulation anchor: a Sunday, the first day of the default study week. */
        val anchor: LocalDate = LocalDate.parse("2026-08-02")

        /** One day before [anchor], so every simulated date (including the anchor itself) runs in projection mode. */
        val today: LocalDate = anchor.minusDays(1)

        const val PREVIEW_DAYS = 60
        const val PUBLISH_DAYS = 400

        /** Maximum estimated workload in a full calendar day. */
        const val MAX_MINUTES_PER_DAY = 1440

        /**
         * `planId` per profile: fixed, arbitrary, valid UUIDs — never the wall clock or a random
         * generator (determinism). Distinct per profile only for readability; nothing downstream
         * keys behavior off `planId` beyond validating its shape.
         */
        private val planIds: Map<SimulationProfile, String> = mapOf(
            SimulationProfile.FRESH to "00000000-0000-0000-0000-0000000cb601",
            SimulationProfile.MID to "00000000-0000-0000-0000-0000000cb602",
            SimulationProfile.HAFIZ to "00000000-0000-0000-0000-0000000cb603",
        )

        // -- 1440-minutes/day ceiling ------------------------------------------------------

        internal fun ceilingIssues(result: GenerationResult, profile: SimulationProfile): List<CurriculumIssue> {
            val perDay = LinkedHashMap<LocalDate, Int>()
            for (task in result.tasks) perDay[task.date] = (perDay[task.date] ?: 0) + task.estimatedMinutes
            val issues = mutableListOf<CurriculumIssue>()
            for ((date, minutes) in perDay) {
                if (minutes <= MAX_MINUTES_PER_DAY) continue
                issues += CurriculumIssue(
                    severity = IssueSeverity.ERROR, id = "SIM-DAY-OVER-1440", gate = ValidationGate.SIMULATION,
                    path = JSONPointer(),
                    messageEn = "profile '$profile': $date totals $minutes estimated minutes, " +
                        "exceeding the $MAX_MINUTES_PER_DAY-minute (24h) sanity ceiling",
                    messageAr = "الملف الشخصي '$profile': يبلغ إجمالي دقائق $date $minutes دقيقة، " +
                        "متجاوزًا سقف الأمان البالغ $MAX_MINUTES_PER_DAY دقيقة (24 ساعة)",
                )
            }
            return issues
        }

        /**
         * Map iteration order is not guaranteed stable run-to-run — sort every issue list this
         * class returns so gate 4's own output is itself reproducible, independent of the
         * (unrelated) [StreamSerializer] determinism proof above.
         */
        private val issueOrder: Comparator<CurriculumIssue> = compareBy({ it.id }, { it.messageEn })

        // -- Policy synthesis ---------------------------------------------------------------

        /**
         * A generic, curriculum-respecting [PlanPolicy] usable across any built-in curriculum (or
         * an arbitrary authored draft): full-Quran target, mushaf-forward order, every weekday
         * active, strict-backlog recovery — except `new_amount` and `sessions`, which are computed
         * FROM the curriculum itself so this works for a curriculum whose allowed units/session
         * ids differ from Maknoon's (e.g. a `line`-unit curriculum, an `ayah`-unit curriculum).
         * Kotlin's [PlanPolicy]/`QuranAmount` are directly constructible (the amount's decimal
         * value is already a plain `String`), so — unlike the Swift port, which round-trips
         * through a synthesized `PlanPolicy(json:)` document — this builds the policy directly,
         * with no JSON intermediate.
         */
        internal fun weekdaysForEmitType(curriculum: CompiledCurriculum, emitType: String): Set<Weekday> =
            weekdaysForRules(curriculum) { it.emit.type == emitType }

        internal fun weekdaysForAnyRule(curriculum: CompiledCurriculum): Set<Weekday> =
            weekdaysForRules(curriculum) { true }

        private fun weekdaysForRules(
            curriculum: CompiledCurriculum,
            include: (RuleSpec) -> Boolean,
        ): Set<Weekday> {
            val rules = buildList {
                addAll(curriculum.rules)
                curriculum.triggers.forEach { trigger ->
                    trigger.effects.filterIsInstance<TriggerEffect.InsertWeek>().forEach { addAll(it.dayRules) }
                }
            }
            val classes = rules.filter(include).flatMap { it.whenSpec.dayClasses }.toSet()
            return classes.flatMap { curriculum.calendar.dayClasses[it].orEmpty() }.toSet()
        }

        fun defaultPolicy(curriculum: CompiledCurriculum): PlanPolicy {
            val newHifzDays = weekdaysForEmitType(curriculum, "new_hifz")
            val activeDays = newHifzDays.ifEmpty { weekdaysForAnyRule(curriculum) }
            return PlanPolicy(
                newAmount = curriculum.units.defaultPace,
                targetRange = TargetRange.FullQuran,
                memorizationOrder = OrderSpec.MushafForward,
                activeWeekdays = activeDays,
                sessions = curriculum.sessions.map { SessionSpec(it.id, it.defaultTime ?: "05:00") },
                separateSessionCompletion = false,
                listeningDays = weekdaysForEmitType(curriculum, "listening"),
                murajaahRamp = null,
                recoveryPolicy = RecoveryPolicy.StrictBacklog,
            )
        }
    }
}
