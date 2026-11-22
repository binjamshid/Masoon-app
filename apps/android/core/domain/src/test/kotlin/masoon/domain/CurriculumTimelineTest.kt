package masoon.domain

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** D-054 `plan.curriculum_upgraded` parsing and folding. */
class CurriculumTimelineTest {

    private var seq = 0L

    private fun event(payloadJson: String): PlanEvent {
        seq += 1
        val json = """
            {"event_id":"e-$seq","type":"plan.curriculum_upgraded","server_seq":"$seq",
             "device_id":"d-1","client_seq":"0","occurred_at_local":"2026-07-12T06:00:00+03:00",
             "payload":$payloadJson}
        """.trimIndent()
        return PolicyJson.parseEvent(Json.parseToJsonElement(json).jsonObject)
    }

    @Test
    fun `a well-formed upgrade folds into the curriculum timeline`() {
        val fold = foldEvents(
            listOf(event("""{"slug":"tikrar","version":"1.0.0","effective_from":"2026-08-01"}"""))
        )
        assertEquals(1, fold.curriculumTimeline.size)
        assertEquals("tikrar@1.0.0", fold.curriculumTimeline.first().key)
        assertNull(fold.curriculumOn(LocalDate.parse("2026-07-31")))
        assertEquals("tikrar", fold.curriculumOn(LocalDate.parse("2026-08-01"))?.slug)
        assertEquals("tikrar", fold.curriculumOn(LocalDate.parse("2027-01-01"))?.slug)
    }

    @Test
    fun `an omitted version is empty, never fatal`() {
        val fold = foldEvents(listOf(event("""{"slug":"madinah","effective_from":"2026-08-01"}""")))
        assertEquals("", fold.curriculumTimeline.single().version)
        assertEquals("madinah@", fold.curriculumTimeline.single().key)
    }

    @Test
    fun `a missing slug or unparseable date is a deterministic no-op for BOTH timelines`() {
        val fold = foldEvents(
            listOf(
                event("""{"effective_from":"2026-08-01","policy_patch":{"takrar_count":9}}"""),
                event("""{"slug":"tikrar","effective_from":"not-a-date","policy_patch":{"takrar_count":9}}"""),
                event("""{"slug":"tikrar"}"""),
            )
        )
        assertTrue(fold.curriculumTimeline.isEmpty())
        assertTrue(fold.policyPatches.isEmpty()) // the bundled patch is skipped with its event
    }

    @Test
    fun `a bundled policy_patch rides the same effective date into the policy timeline`() {
        val fold = foldEvents(
            listOf(
                event(
                    """{"slug":"tikrar","version":"1.0.0","effective_from":"2026-08-01",
                        "policy_patch":{"takrar_count":9}}"""
                )
            )
        )
        assertEquals(1, fold.policyPatches.size)
        assertEquals(LocalDate.parse("2026-08-01"), fold.policyPatches.single().effectiveFrom)
        assertEquals(9, PolicyJson.applyPatch(basePolicy(), fold.policyPatches.single().patch).takrarCount)
    }

    @Test
    fun `at an equal effective date the later fold wins`() {
        val fold = foldEvents(
            listOf(
                event("""{"slug":"first","version":"1","effective_from":"2026-08-01"}"""),
                event("""{"slug":"second","version":"1","effective_from":"2026-08-01"}"""),
            )
        )
        assertEquals("second", fold.curriculumOn(LocalDate.parse("2026-08-01"))?.slug)
    }

    @Test
    fun `a later entry with an earlier effective date does not shadow the greater one`() {
        val fold = foldEvents(
            listOf(
                event("""{"slug":"late","version":"1","effective_from":"2026-09-01"}"""),
                event("""{"slug":"early","version":"1","effective_from":"2026-08-01"}"""),
            )
        )
        assertEquals("early", fold.curriculumOn(LocalDate.parse("2026-08-15"))?.slug)
        assertEquals("late", fold.curriculumOn(LocalDate.parse("2026-09-02"))?.slug)
    }

    private fun basePolicy(): PlanPolicy = PolicyJson.parsePolicy(
        Json.parseToJsonElement(
            """
            {"new_amount":{"unit":"page","value":"1"},"target_range":"full_quran",
             "memorization_order":{"kind":"mushaf_forward"},
             "active_weekdays":["sun","mon","tue","wed","thu"],
             "sessions":[{"id":"morning","start":"05:00"}],
             "recovery_policy":{"kind":"strict_backlog"}}
            """.trimIndent()
        ).jsonObject
    )
}
