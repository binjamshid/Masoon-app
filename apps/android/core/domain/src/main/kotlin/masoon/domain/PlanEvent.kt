package masoon.domain

import kotlinx.serialization.json.JsonObject

/**
 * PlanEvent — the sync unit and single source of truth for plan state (DOMAIN_MODEL §3).
 * Events are immutable; superseded events fold as no-ops for state but remain visible for
 * history/status derivation.
 */
data class PlanEvent(
    val eventId: String,
    val type: String,
    val payload: EventPayload,
    /** Server-assigned canonical order; null = local-unacked. */
    val serverSeq: Long? = null,
    val deviceId: String = "",
    /** Per-device monotonic sequence. */
    val clientSeq: Long = 0L,
    /** ISO8601 with offset; the date part is the plan-local calendar date of the action. */
    val occurredAtLocal: String = "",
    val schemaVersion: Int = 1,
    val supersededBy: String? = null,
) {
    /** Plan-local calendar date of the event (prefix of occurred_at_local). */
    fun localDate(): LocalDate = LocalDate.parse(occurredAtLocal.substring(0, 10))
}

sealed interface EventPayload {
    // D-032: every task.* payload carries `date` — the TASK INSTANCE's plan-LocalDate (the day
    // the task belongs to), which may differ from occurred_at_local under D-021 backdating.
    // Parsers fall back to the local-date part of occurred_at_local for legacy events.
    data class TaskStarted(val taskUid: String, val date: LocalDate? = null) : EventPayload
    /**
     * E-4b (D-046): [verified] is true when the evidence is a teacher
     * verification OR the payload carries an explicit `verified: true` (a teacher
     * accepting other evidence kinds — e.g. marking a counter-evidenced sabaq
     * maqbūl). Mirrors the TS and Swift folds exactly.
     */
    data class TaskCompleted(
        val taskUid: String,
        val date: LocalDate? = null,
        val verified: Boolean = false,
    ) : EventPayload
    data class TaskUncompleted(val taskUid: String, val date: LocalDate? = null, val reason: String? = null) : EventPayload
    data class TaskExcused(
        val taskUid: String,
        val date: LocalDate? = null,
        val by: String? = null,
        val reason: String? = null,
    ) : EventPayload

    data class PolicyChanged(val effectiveFrom: LocalDate, val patch: JsonObject) : EventPayload

    /**
     * Supervisor/teacher override; wins for effective_from >= its date (I-2).
     * `effectiveFrom == null` = effective from the beginning of the plan (D-032.5, §11.20) —
     * supervisor authority is never silently narrowed.
     */
    data class OverrideApplied(
        val effectiveFrom: LocalDate?,
        val patch: JsonObject,
        val reason: String? = null,
        val supersedes: List<String> = emptyList(),
    ) : EventPayload

    /**
     * D-054 `plan.curriculum_upgraded`: the plan switches to `slug@version` from [effectiveFrom]
     * (inclusive) onward. [version] is the empty string when the event omits it — never fatal;
     * the engine falls back to the base curriculum when the resulting `slug@version` key resolves
     * to nothing. An optional [policyPatch] rides the SAME effective date into the policy
     * timeline (not a supervisor override).
     */
    data class CurriculumUpgraded(
        val effectiveFrom: LocalDate,
        val slug: String,
        val version: String,
        val policyPatch: JsonObject? = null,
    ) : EventPayload

    data class RecoveryApplied(val date: LocalDate) : EventPayload
    data class Paused(val from: LocalDate) : EventPayload
    data class Resumed(val anchor: LocalDate) : EventPayload
    data class DayClosed(val date: LocalDate, val missedTaskUids: List<String> = emptyList()) : EventPayload
    data class StartingStateDeclared(val state: LearnerStartingState) : EventPayload

    /** Unknown type/schema_version: preserved opaquely (I-4); folds as a no-op. */
    data class Opaque(val type: String) : EventPayload
}
