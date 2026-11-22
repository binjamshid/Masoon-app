package masoon.domain

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class FoldTest {

    private fun ev(
        id: String,
        type: String,
        payload: EventPayload,
        serverSeq: Long? = null,
        deviceId: String = "d-1",
        clientSeq: Long = 0,
        supersededBy: String? = null,
    ) = PlanEvent(
        eventId = id, type = type, payload = payload, serverSeq = serverSeq,
        deviceId = deviceId, clientSeq = clientSeq,
        occurredAtLocal = "2026-07-12T06:00:00+03:00", supersededBy = supersededBy,
    )

    @Test
    fun `fold is deterministic under input shuffle with same server_seq order`() {
        val events = listOf(
            ev("e1", "task.completed", EventPayload.TaskCompleted("uid-1"), serverSeq = 1),
            ev("e2", "task.uncompleted", EventPayload.TaskUncompleted("uid-1"), serverSeq = 2),
            ev("e3", "task.completed", EventPayload.TaskCompleted("uid-1"), serverSeq = 3),
            ev("e4", "task.completed", EventPayload.TaskCompleted("uid-2"), serverSeq = 4),
            ev("e5", "task.excused", EventPayload.TaskExcused("uid-3"), serverSeq = 5),
            ev("e6", "task.completed", EventPayload.TaskCompleted("uid-4"), deviceId = "d-2", clientSeq = 2),
            ev("e7", "task.uncompleted", EventPayload.TaskUncompleted("uid-4"), deviceId = "d-2", clientSeq = 3),
        )
        val base = foldEvents(events)
        // deterministic shuffles (fixed permutations, no RNG)
        for (perm in listOf(events.reversed(), events.shuffledDeterministic())) {
            assertEquals(base, foldEvents(perm))
        }
        assertTrue(base.completed.contains("uid-1")) // re-completed after uncompletion
        assertTrue(base.completed.contains("uid-2"))
        assertFalse(base.completed.contains("uid-4")) // local uncompletion wins in (device, client_seq) order
        assertTrue(base.excused.contains("uid-3"))
    }

    private fun <T> List<T>.shuffledDeterministic(): List<T> {
        // fixed interleave permutation — no RNG in tests either
        val evens = filterIndexed { i, _ -> i % 2 == 0 }
        val odds = filterIndexed { i, _ -> i % 2 == 1 }
        return odds + evens
    }

    @Test
    fun `superseded events fold as no-ops`() {
        val events = listOf(
            ev("e1", "task.completed", EventPayload.TaskCompleted("uid-1"), serverSeq = 1, supersededBy = "e9"),
        )
        assertFalse(foldEvents(events).completed.contains("uid-1"))
    }

    @Test
    fun `acked events fold before local-unacked regardless of list position`() {
        val events = listOf(
            // local (unacked) completion listed first, acked uncompletion after
            ev("e2", "task.uncompleted", EventPayload.TaskUncompleted("uid-1"), deviceId = "d-9", clientSeq = 1),
            ev("e1", "task.completed", EventPayload.TaskCompleted("uid-1"), serverSeq = 7),
        )
        // fold order: acked completed (seq 7), then local uncompleted -> net not completed
        assertFalse(foldEvents(events).completed.contains("uid-1"))
    }

    @Test
    fun `policy patches sort by effective_from`() {
        val p1 = JsonObject(mapOf("takrar_count" to JsonPrimitive(7)))
        val p2 = JsonObject(mapOf("takrar_count" to JsonPrimitive(3)))
        val events = listOf(
            ev("e1", "plan.policy_changed", EventPayload.PolicyChanged(LocalDate.parse("2026-08-01"), p1), serverSeq = 1),
            ev("e2", "override.applied", EventPayload.OverrideApplied(LocalDate.parse("2026-07-20"), p2), serverSeq = 2),
        )
        val fold = foldEvents(events)
        assertEquals(LocalDate.parse("2026-07-20"), fold.policyPatches[0].effectiveFrom)
        assertEquals(LocalDate.parse("2026-08-01"), fold.policyPatches[1].effectiveFrom)
    }

    @Test
    fun `pause spans and status derivation`() {
        val events = listOf(
            ev("e1", "plan.paused", EventPayload.Paused(LocalDate.parse("2026-07-20")), serverSeq = 1),
            ev("e2", "plan.resumed", EventPayload.Resumed(LocalDate.parse("2026-07-25")), serverSeq = 2),
        )
        val fold = foldEvents(events)
        assertFalse(fold.isPaused(LocalDate.parse("2026-07-19")))
        assertTrue(fold.isPaused(LocalDate.parse("2026-07-20")))
        assertTrue(fold.isPaused(LocalDate.parse("2026-07-24")))
        assertFalse(fold.isPaused(LocalDate.parse("2026-07-25"))) // resume anchor day generates again

        val today = LocalDate.parse("2026-07-30")
        assertEquals(TaskStatus.MISSED, deriveStatus("x", LocalDate.parse("2026-07-19"), today, fold))
        assertEquals(TaskStatus.PENDING, deriveStatus("x", today, today, fold))
    }

    @Test
    fun `policy patch application is typed and field-wise`() {
        val base = PlanPolicy(
            newAmount = QuranAmount(AmountUnit.PAGE, "1"),
            targetRange = TargetRange.FullQuran,
            memorizationOrder = OrderSpec.MushafForward,
            activeWeekdays = setOf(Weekday.SUN, Weekday.MON, Weekday.TUE, Weekday.WED, Weekday.THU),
            sessions = listOf(SessionSpec("morning", "05:30"), SessionSpec("evening", "19:30")),
            separateSessionCompletion = true,
            listeningDays = setOf(Weekday.SAT, Weekday.SUN, Weekday.MON, Weekday.TUE, Weekday.WED),
            listeningCount = 2,
            takrarCount = 5,
            takrarSpacingMinutes = 15,
            murajaahDailyCeiling = QuranAmount(AmountUnit.JUZ, "2"),
            murajaahRamp = RampSpec(QuranAmount(AmountUnit.PAGE, "5"), QuranAmount(AmountUnit.RUB, "2")),
            recoveryPolicy = RecoveryPolicy.StrictBacklog,
        )
        val patched = PolicyJson.applyPatch(
            base,
            JsonObject(
                mapOf(
                    "takrar_count" to JsonPrimitive(7),
                    "new_amount" to JsonObject(mapOf("unit" to JsonPrimitive("page"), "value" to JsonPrimitive("0.5"))),
                )
            ),
        )
        assertEquals(7, patched.takrarCount)
        assertEquals(500_000L, patched.newAmount.microPages())
        assertEquals(base.listeningCount, patched.listeningCount)
    }
}
