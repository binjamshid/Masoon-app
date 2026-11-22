package masoon.domain

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * E-4b/D-046 `task.completed` verified detection — all three honored signals, aligned with the
 * Swift/TS engines (`Fold.swift:141-151`). The third (nested `evidence.verified`) is the
 * 2026-07-31 tasmeeʿ-ijāza-attestation founder ruling; it shipped on iOS alongside
 * `TasmeeAttestation` but had never been ported here until `:feature:today` (WP-15) needed it —
 * see the matching comment on [PolicyJson.parseEvent].
 */
class PolicyJsonVerifiedTest {

    private fun completedEvent(payload: JsonObject) = buildJsonObject {
        put("event_id", "e-1")
        put("type", "task.completed")
        put("occurred_at_local", "2026-07-20T06:00:00+03:00")
        put("payload", payload)
    }

    private fun verifiedOf(payload: JsonObject): Boolean =
        (PolicyJson.parseEvent(completedEvent(payload)).payload as EventPayload.TaskCompleted).verified

    @Test
    fun `plain self_check completion is not verified`() {
        assertFalse(
            verifiedOf(
                buildJsonObject {
                    put("task_uid", "t-1")
                    put("evidence", buildJsonObject { put("kind", "self_check") })
                },
            ),
        )
    }

    @Test
    fun `evidence kind teacher_verification is verified`() {
        assertTrue(
            verifiedOf(
                buildJsonObject {
                    put("task_uid", "t-1")
                    put("evidence", buildJsonObject { put("kind", "teacher_verification") })
                },
            ),
        )
    }

    @Test
    fun `top-level verified true is verified regardless of evidence kind`() {
        assertTrue(
            verifiedOf(
                buildJsonObject {
                    put("task_uid", "t-1")
                    put("evidence", buildJsonObject { put("kind", "counter") })
                    put("verified", true)
                },
            ),
        )
    }

    @Test
    fun `a filled tasmee attestation with nested evidence verified true is verified`() {
        val attestation = TasmeeAttestation("Ahmad", "06:40", 95, 1).evidenceJson() as JsonObject
        assertTrue(
            verifiedOf(
                buildJsonObject {
                    put("task_uid", "t-1")
                    put("evidence", attestation)
                },
            ),
        )
    }

    @Test
    fun `named_listener_attestation kind alone, without nested verified, is not verified`() {
        assertFalse(
            verifiedOf(
                buildJsonObject {
                    put("task_uid", "t-1")
                    put(
                        "evidence",
                        buildJsonObject {
                            put("kind", TasmeeAttestation.EVIDENCE_KIND)
                            put("verified", false)
                        },
                    )
                },
            ),
        )
    }
}
