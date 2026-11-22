package masoon.domain

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class EvidencePayloadsTest {
    @Test
    fun `timer uses canonical elapsed seconds key`() {
        assertEquals(
            """{"kind":"timer","elapsed_seconds":61}""",
            EvidencePayloads.timer(61).toString(),
        )
    }

    @Test
    fun `form binds pinned version and authorized assessment`() {
        assertEquals(
            """{"kind":"form","form_version_id":"version-2","assessment_id":"attempt-1"}""",
            EvidencePayloads.form("version-2", "attempt-1").toString(),
        )
    }

    @Test
    fun `teacher verification carries only the authorized assessment id`() {
        assertEquals(
            """{"kind":"teacher_verification","assessment_id":"attempt-1"}""",
            EvidencePayloads.teacherVerification("attempt-1").toString(),
        )
    }

    @Test
    fun `composite preserves nested evidence order`() {
        assertEquals(
            """{"kind":"composite","parts":[{"kind":"self_check"},""" +
                """{"kind":"timer","elapsed_seconds":30}]}""",
            EvidencePayloads.composite(
                listOf(EvidencePayloads.selfCheck(), EvidencePayloads.timer(30)),
            ).toString(),
        )
    }
}
