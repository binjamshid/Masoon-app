package masoon.curriculum

import masoon.domain.CanonicalPosition
import masoon.domain.CanonicalRange
import masoon.domain.ContentIndex
import masoon.domain.LearnerStartingState
import masoon.domain.LocalDate
import masoon.domain.PlanEvent
import masoon.domain.PlanPolicy

/** Generated task (PRD §7.4). Derived cache only — always regenerable (E-2). */
data class TaskInstance(
    val taskUid: String,
    val planId: String,
    val date: LocalDate,
    val dayClass: String,
    val session: String,
    val ordering: Int,
    val occurrence: Int,
    val type: String,
    val originRuleId: String,
    val content: List<CanonicalRange>,
    val targetRepetitions: Int? = null,
    val spacingMinutes: Int? = null,
    val listenCount: Int? = null,
    val windowOpensOn: LocalDate? = null,
    val windowClosesOn: LocalDate? = null,
    val estimatedMinutes: Int,
    val evidenceCompact: String,
    val flags: List<String> = emptyList(),
)

data class OrgException(val date: LocalDate, val clazz: String)

data class PlanCalendar(
    val timezone: String,
    val anchorDate: LocalDate,
    val orgExceptions: List<OrgException> = emptyList(),
)

data class DateRange(val from: LocalDate, val to: LocalDate) {
    init { require(from <= to) { "invalid window: $from..$to" } }
    operator fun contains(d: LocalDate): Boolean = d >= from && d <= to
}

/** Engine inputs (PRD §7.2). Pure data; `today` is injected, never read from a clock. */
data class PlanGenerationContext(
    val planId: String,
    /**
     * The BASE curriculum — the one in force before any `plan.curriculum_upgraded` event. Every
     * date-dependent read inside the engine goes through the per-date resolver, never through
     * this field directly (PC-4/D-054).
     */
    val curriculum: CompiledCurriculum,
    /**
     * Corpus-agnostic content index (Batch 3 Stage 2): `QuranIndex` for every Qurʾān plan,
     * `PoemIndex` for a manẓūma corpus. The engine never branches on which one it holds.
     */
    val index: ContentIndex,
    val policy: PlanPolicy,
    val startingState: LearnerStartingState,
    val calendar: PlanCalendar,
    val eventLog: List<PlanEvent>,
    val today: LocalDate,
    /**
     * PC-4 / ENGINE_PARITY §4.2 — extra compiled curricula this plan may switch INTO, keyed
     * `"{slug}@{version}"` (`CurriculumChange.key`). Empty for every plan that never upgraded, in
     * which case the base curriculum applies on every date. A timeline entry naming a key absent
     * here falls back to [curriculum] rather than failing: an event log may reference a curriculum
     * the caller did not load, and a hard failure there would take down the whole generation.
     */
    val curriculaByKey: Map<String, CompiledCurriculum> = emptyMap(),
    /**
     * L12 (App Store/Play compliance remediation — ported from
     * `apps/ios/Packages/Sources/MasoonCurriculum/GenerationContext.swift`'s `hasAssignedTeacher`,
     * D-182/D-183): does this learner have a teacher/supervisor who can act on
     * `teacher_verification` evidence? Defaults to `true` so every existing caller — every
     * fixture, every future org-enrolled/teacher-supervised plan — resolves evidence exactly as it
     * always has; only a caller that explicitly knows the learner has no assigned teacher (an
     * individual-mode learner with no org/teacher link) passes `false`. [Engine]'s evidence
     * resolution uses this to fall back a NON-gating `teacher_verification` default (e.g.
     * Maknoon's/Wifaq's `tasmee`) to `self_check` for such a learner, while leaving any
     * curriculum's genuine `require_verified` advancement gate (Deobandi's maqbūl/mardūd sabaq,
     * D-041/D-046 — deliberately still uncompletable by a solo learner, by founder ruling)
     * untouched. Without this, a solo Android learner on a bundled curriculum whose core-task
     * evidence default is `teacher_verification` cannot complete that task at all — the same gap
     * D-182 found unwired in iOS's shipped app before D-183 closed it. Real production call sites
     * (`Regenerator.context`, `OnboardingForecast.generate`) pass `false` explicitly today: no
     * client-side org/teacher-enrollment signal exists anywhere in this build (confirmed:
     * `org_id`/`payer_org` appear only on org-billing rows, never on `account`/`plan`), so every
     * real plan this build can produce IS teacherless, mirroring D-183's own stated honest-today
     * ruling for iOS exactly.
     */
    val hasAssignedTeacher: Boolean = true,
)

/** State checkpoint for the `#STATE` stream line (ENGINE_PARITY §3). */
data class EngineState(
    /** Next new-hifz start; null when the walk is exhausted (plan completed). */
    val cursor: CanonicalPosition?,
    val juzDone: Int,
    val cycleWeeks: Int,
    val debtNewRangeCount: Int,
    val status: String, // active | paused | completed
)

data class GenerationResult(val tasks: List<TaskInstance>, val state: EngineState)
