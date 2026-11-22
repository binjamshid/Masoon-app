package masoon.domain

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * §11.26 regression (2026-07-13 audit F-006): `plan.recovery_applied` reads
 * `effective_from` and falls back to occurred_at_local's date. A `date` key on
 * this event type is NOT read — an earlier Kotlin revision honored it ahead of
 * `effective_from`, diverging from the Swift/TS engines.
 */
class PolicyJsonRecoveryTest {

    private fun event(payload: kotlinx.serialization.json.JsonObject) = buildJsonObject {
        put("event_id", "e-r1")
        put("type", "plan.recovery_applied")
        put("occurred_at_local", "2026-07-20T06:00:00+03:00")
        put("payload", payload)
    }

    @Test
    fun `effective_from wins even when a date key is present`() {
        val parsed = PolicyJson.parseEvent(
            event(
                buildJsonObject {
                    put("date", "2026-07-01")
                    put("effective_from", "2026-07-15")
                }
            )
        )
        val p = parsed.payload as EventPayload.RecoveryApplied
        assertEquals(LocalDate.parse("2026-07-15"), p.date)
    }

    @Test
    fun `date key alone is ignored - falls back to occurred_at_local`() {
        val parsed = PolicyJson.parseEvent(event(buildJsonObject { put("date", "2026-07-01") }))
        val p = parsed.payload as EventPayload.RecoveryApplied
        assertEquals(LocalDate.parse("2026-07-20"), p.date)
    }
}
