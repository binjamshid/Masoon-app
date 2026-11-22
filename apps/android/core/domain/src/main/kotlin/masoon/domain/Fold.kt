package masoon.domain

import kotlinx.serialization.json.JsonObject

/** Sentinel "beginning of plan" date for overrides without effective_from (§11.20/D-032.5). */
val BEGINNING_OF_PLAN: LocalDate = LocalDate(1, 1, 1)

/** A policy patch effective from a date (PRD §7.3 effective_policy_timeline). */
data class PolicyPatchEntry(val effectiveFrom: LocalDate, val patch: JsonObject)

/** Pause span; open (still paused) when resumeAnchor is null. */
data class PauseSpan(val from: LocalDate, val resumeAnchor: LocalDate?)

/**
 * One `plan.curriculum_upgraded` fold (D-054): the plan switches to `slug@version` from
 * [effectiveFrom] (inclusive) onward. [version] is empty when the event omitted it.
 */
data class CurriculumChange(val effectiveFrom: LocalDate, val slug: String, val version: String) {
    /** `CurriculumSet` lookup key. */
    val key: String get() = "$slug@$version"
}

/**
 * Deterministic fold of the event log (ENGINE_SEMANTICS §9).
 * Task status truth: completed iff a non-superseded task.completed exists and no later
 * (fold-order) task.uncompleted negates it.
 */
data class FoldResult(
    val completed: Set<String>,
    /**
     * E-4b (D-046): task_uids whose live completion was VERIFIED (teacher
     * verification evidence, or an explicit `verified: true`). A subset of
     * [completed]; an uncompleted task is never verified.
     */
    val verifiedCompleted: Set<String>,
    val started: Set<String>,
    val excused: Set<String>,
    val policyPatches: List<PolicyPatchEntry>,
    val pauses: List<PauseSpan>,
    val recoveryDates: List<LocalDate>,
    val declaredStartingState: LearnerStartingState?,
    /**
     * Curriculum-switch timeline folded from `plan.curriculum_upgraded` (D-054): append-only in
     * fold order, one entry per well-formed event. Resolve a date with [curriculumOn]. Defaulted
     * so every existing construction site is unaffected — the base curriculum applies whenever
     * this is empty, which is every frozen fixture today.
     */
    val curriculumTimeline: List<CurriculumChange> = emptyList(),
)

/**
 * Fold order: all acked events by server_seq, then local-unacked by (device_id, client_seq).
 * Superseded events fold as no-ops for state.
 */
fun foldOrder(events: List<PlanEvent>): List<PlanEvent> =
    events.sortedWith(
        compareBy<PlanEvent> { it.serverSeq == null }
            .thenBy { it.serverSeq ?: 0L }
            .thenBy { it.deviceId }
            .thenBy { it.clientSeq }
    )

fun foldEvents(events: List<PlanEvent>): FoldResult {
    val completed = LinkedHashSet<String>()
    val verifiedCompleted = LinkedHashSet<String>()
    val started = LinkedHashSet<String>()
    val excused = LinkedHashSet<String>()
    val policyPatches = mutableListOf<PolicyPatchEntry>()
    val pauses = mutableListOf<PauseSpan>()
    val recoveryDates = mutableListOf<LocalDate>()
    val curriculumTimeline = mutableListOf<CurriculumChange>()
    var startingState: LearnerStartingState? = null

    for (e in foldOrder(events)) {
        if (e.supersededBy != null) continue // no-op for state (I-2), retained for history
        when (val p = e.payload) {
            is EventPayload.TaskStarted -> started.add(p.taskUid)
            is EventPayload.TaskCompleted -> {
                completed.add(p.taskUid)
                // Last live completion wins, so a re-completion can flip verified
                // either way (teacher accepts, then rejects and re-marks).
                if (p.verified) verifiedCompleted.add(p.taskUid) else verifiedCompleted.remove(p.taskUid)
            }
            is EventPayload.TaskUncompleted -> {
                completed.remove(p.taskUid)
                verifiedCompleted.remove(p.taskUid)
            }
            is EventPayload.TaskExcused -> excused.add(p.taskUid)
            is EventPayload.PolicyChanged -> policyPatches.add(PolicyPatchEntry(p.effectiveFrom, p.patch))
            is EventPayload.OverrideApplied ->
                policyPatches.add(PolicyPatchEntry(p.effectiveFrom ?: BEGINNING_OF_PLAN, p.patch))
            is EventPayload.CurriculumUpgraded -> {
                curriculumTimeline.add(CurriculumChange(p.effectiveFrom, p.slug, p.version))
                // A bundled policy_patch rides the SAME effective_from into the existing policy
                // timeline — NOT a supervisor override, so it uses the plain policy-change append.
                p.policyPatch?.let { policyPatches.add(PolicyPatchEntry(p.effectiveFrom, it)) }
            }
            is EventPayload.RecoveryApplied -> recoveryDates.add(p.date)
            is EventPayload.Paused -> pauses.add(PauseSpan(p.from, null))
            is EventPayload.Resumed -> {
                val open = pauses.indexOfLast { it.resumeAnchor == null }
                if (open >= 0) pauses[open] = pauses[open].copy(resumeAnchor = p.anchor)
            }
            is EventPayload.StartingStateDeclared -> startingState = p.state
            is EventPayload.DayClosed -> Unit // bookkeeping marker; misses are derived, not stored
            is EventPayload.Opaque -> Unit // I-4: preserved opaquely
        }
    }

    return FoldResult(
        completed = completed,
        verifiedCompleted = verifiedCompleted,
        started = started,
        excused = excused,
        policyPatches = policyPatches.sortedBy { it.effectiveFrom },
        pauses = pauses,
        recoveryDates = recoveryDates.sorted(),
        declaredStartingState = startingState,
        curriculumTimeline = curriculumTimeline.toList(),
    )
}

/**
 * The curriculum in force on [d] (D-054): the entry with the greatest `effectiveFrom <= d`, ties
 * broken by fold order (the later fold wins, mirroring how a later [policyPatches] entry at the
 * same date wins). Null means "no switch applies" — the plan's base curriculum stands.
 */
fun FoldResult.curriculumOn(d: LocalDate): CurriculumChange? {
    var best: CurriculumChange? = null
    for (c in curriculumTimeline) {
        if (c.effectiveFrom > d) continue
        if (best == null || c.effectiveFrom >= best.effectiveFrom) best = c
    }
    return best
}

/** Is date D inside a pause span (no tasks, no misses — ENGINE_SEMANTICS §8)? */
fun FoldResult.isPaused(d: LocalDate): Boolean =
    pauses.any { span -> d >= span.from && (span.resumeAnchor == null || d < span.resumeAnchor) }

/** Derived task status (DOMAIN_MODEL §3 invariants; never stored as truth). */
enum class TaskStatus { PENDING, IN_PROGRESS, COMPLETED, MISSED, EXCUSED }

fun deriveStatus(taskUid: String, taskDate: LocalDate, today: LocalDate, fold: FoldResult): TaskStatus = when {
    fold.completed.contains(taskUid) -> TaskStatus.COMPLETED
    fold.excused.contains(taskUid) -> TaskStatus.EXCUSED
    taskDate < today -> TaskStatus.MISSED
    fold.started.contains(taskUid) -> TaskStatus.IN_PROGRESS
    else -> TaskStatus.PENDING
}
