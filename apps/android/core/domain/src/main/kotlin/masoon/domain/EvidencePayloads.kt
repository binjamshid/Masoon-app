package masoon.domain

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

/**
 * Evidence payload shapes for the `evidence` field of a `task.completed` event (PRD AC-1.2).
 *
 * Ported from `apps/ios/Packages/Sources/MasoonDomain/EvidencePayloads.swift`. Lives in
 * `:core:domain`, not `:feature:today`, for the same reason it does on iOS: these are the exact
 * bytes `TaskRepository.completeTask`/`PlanStore` persist and later fold (`PolicyJson.parseEvent`'s
 * `verified` detection reads `payload.evidence.kind`), so any future non-UI caller (a widget's
 * quick-complete action, a Wear-equivalent surface) must build the SAME shape, not a
 * feature-module-local approximation.
 */
object EvidencePayloads {
    fun selfCheck(): JsonElement = buildJsonObject { put("kind", JsonPrimitive("self_check")) }

    /** AC-1.2: `{kind:"counter", count, increments}`. `increments` are real "HH:mm" tap times. */
    fun counter(count: Int, increments: List<String>): JsonElement = buildJsonObject {
        put("kind", JsonPrimitive("counter"))
        put("count", JsonPrimitive(count))
        put("increments", JsonArray(increments.map { JsonPrimitive(it) }))
    }

    fun timer(seconds: Int): JsonElement = buildJsonObject {
        put("kind", JsonPrimitive("timer"))
        put("elapsed_seconds", JsonPrimitive(seconds))
    }

    fun form(
        formVersionId: String,
        assessmentId: String,
    ): JsonElement =
        buildJsonObject {
            require(formVersionId.isNotBlank())
            require(assessmentId.isNotBlank())
            put("kind", JsonPrimitive("form"))
            put("form_version_id", JsonPrimitive(formVersionId))
            put("assessment_id", JsonPrimitive(assessmentId))
        }

    fun teacherVerification(assessmentId: String): JsonElement =
        buildJsonObject {
            require(assessmentId.isNotBlank())
            put("kind", JsonPrimitive("teacher_verification"))
            put("assessment_id", JsonPrimitive(assessmentId))
        }

    fun composite(parts: List<JsonElement>): JsonElement =
        buildJsonObject {
            require(parts.isNotEmpty())
            put("kind", JsonPrimitive("composite"))
            put("parts", JsonArray(parts))
        }

    /** "HH:mm" from a [WallClock]-shaped local timestamp ("2026-07-12T06:40:00+03:00"). */
    fun hhmm(fromLocalTimestamp: String): String {
        val tIndex = fromLocalTimestamp.indexOf('T')
        if (tIndex < 0) return fromLocalTimestamp
        val time = fromLocalTimestamp.substring(tIndex + 1)
        return time.take(5)
    }
}
