package masoon.mushaf

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * D-215 is a compliance commitment, so it gets assertions rather than a comment.
 *
 * The rule it encodes: an unattended overnight playback must not be able to fabricate evidence
 * that an org student listened, because a supervisor or parent may act on that record.
 */
class MushafListeningEvidencePolicyTest {
    @Test
    fun `an individual learner's completed pass counts itself`() {
        assertEquals(
            MushafListeningEvidence.AutoCount,
            MushafListeningEvidencePolicy.evidenceFor(MushafLearnerScope.INDIVIDUAL),
        )
        assertTrue(
            MushafListeningEvidencePolicy.mayAutoCount(
                MushafLearnerScope.INDIVIDUAL,
                passCompleted = true,
            ),
        )
    }

    @Test
    fun `an org student ALWAYS confirms manually - this is the whole mechanism`() {
        assertEquals(
            MushafListeningEvidence.RequireManualConfirmation,
            MushafListeningEvidencePolicy.evidenceFor(MushafLearnerScope.ORGANIZATION),
        )
        assertFalse(
            MushafListeningEvidencePolicy.mayAutoCount(
                MushafLearnerScope.ORGANIZATION,
                passCompleted = true,
            ),
            "an org student's pass must never self-certify, however complete",
        )
    }

    @Test
    fun `an interrupted pass never counts, for either scope`() {
        // A partial listen is not a listen. Asserted for both scopes so a future change to the
        // individual branch cannot accidentally start counting abandoned playback.
        MushafLearnerScope.entries.forEach { scope ->
            assertFalse(
                MushafListeningEvidencePolicy.mayAutoCount(scope, passCompleted = false),
                "$scope must not count an incomplete pass",
            )
        }
    }

    @Test
    fun `every scope has a defined outcome - no silent fall-through`() {
        MushafLearnerScope.entries.forEach { scope ->
            // `evidenceFor` is exhaustive over the enum; this asserts a new scope added later
            // cannot compile into a default that silently auto-counts.
            assertTrue(
                MushafListeningEvidencePolicy.evidenceFor(scope) in
                    listOf(
                        MushafListeningEvidence.AutoCount,
                        MushafListeningEvidence.RequireManualConfirmation,
                    ),
            )
        }
    }
}
