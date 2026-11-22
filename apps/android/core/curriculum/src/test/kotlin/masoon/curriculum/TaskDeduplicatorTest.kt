package masoon.curriculum

import masoon.domain.CanonicalRange
import masoon.domain.LocalDate
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Test

class TaskDeduplicatorTest {
    private fun task(
        origin: String,
        session: String = "morning",
        ordering: Int = 1,
        repetitions: Int = 3,
    ) = TaskInstance(
        taskUid = "uid-$origin", planId = "11111111-1111-1111-1111-111111111111",
        date = LocalDate.parse("2026-08-28"), dayClass = "weekday",
        session = session, ordering = ordering, occurrence = 0, type = "murajaah",
        originRuleId = origin, content = listOf(CanonicalRange(1, 1, 7)),
        targetRepetitions = repetitions, spacingMinutes = 5, listenCount = 1,
        windowOpensOn = LocalDate.parse("2026-08-28"),
        windowClosesOn = LocalDate.parse("2026-08-29"),
        estimatedMinutes = 9, evidenceCompact = "self", flags = listOf("first_active_day"),
    )

    @Test
    fun `exact execution merges presentation differences and maps every source to one uid`() {
        val result = TaskDeduplicator.deduplicate(
            listOf(task("manzil", "morning", 1), task("adaptive", "evening", 7)),
        )

        assertEquals(1, result.output.size)
        assertEquals(listOf(result.output.single().taskUid, result.output.single().taskUid),
            result.stateTasks.map { it.taskUid })
        assertEquals("adaptive+manzil", result.output.single().originRuleId)
        assertEquals(listOf("first_active_day", "source_rule:adaptive", "source_rule:manzil"),
            result.output.single().flags)
        assertNotEquals("uid-manzil", result.output.single().taskUid)
    }

    @Test
    fun `different execution requirements remain separate`() {
        val result = TaskDeduplicator.deduplicate(listOf(task("a", repetitions = 3), task("b", repetitions = 4)))
        assertEquals(2, result.output.size)
        assertEquals(listOf("uid-a", "uid-b"), result.stateTasks.map { it.taskUid })
    }
}
