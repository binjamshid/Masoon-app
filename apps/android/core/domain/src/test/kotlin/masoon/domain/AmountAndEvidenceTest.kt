package masoon.domain

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

class AmountAndEvidenceTest {

    @Test
    fun `amount to micropages uses decimal string math`() {
        assertEquals(1_000_000L, QuranAmount(AmountUnit.PAGE, "1").microPages())
        assertEquals(500_000L, QuranAmount(AmountUnit.PAGE, "0.5").microPages())
        assertEquals(2_750_000L, QuranAmount(AmountUnit.PAGE, "2.75").microPages())
        assertEquals(20_000_000L, QuranAmount(AmountUnit.JUZ, "1").microPages())
        assertEquals(40_000_000L, QuranAmount(AmountUnit.JUZ, "2").microPages())
        assertEquals(5_000_000L, QuranAmount(AmountUnit.RUB, "2").microPages())
        assertEquals(66_666L, QuranAmount(AmountUnit.LINE, "1").microPages())
        assertEquals(33_333L, QuranAmount(AmountUnit.LINE, "0.5").microPages())
        assertThrows(IllegalArgumentException::class.java) { QuranAmount(AmountUnit.PAGE, "1,5") }
        assertThrows(IllegalArgumentException::class.java) { QuranAmount(AmountUnit.AYAH, "3").microPages() }
        assertEquals(3, QuranAmount(AmountUnit.AYAH, "3").ayahCount())
    }

    @Test
    fun `round half up`() {
        assertEquals(2L, roundHalfUpDiv(3L, 2L)) // 1.5 -> 2
        assertEquals(1L, roundHalfUpDiv(4L, 3L)) // 1.33 -> 1
        assertEquals(2L, roundHalfUpDiv(5L, 3L)) // 1.67 -> 2
        assertEquals(0L, roundHalfUpDiv(0L, 7L))
        assertEquals(1L, roundHalfUpDiv(1L, 2L)) // 0.5 -> 1
    }

    @Test
    fun `evidence compact forms`() {
        assertEquals("self", EvidenceSpec.SelfCheck.compact())
        assertEquals("timer:60", EvidenceSpec.Timer(60).compact())
        assertEquals("counter:5", EvidenceSpec.Counter(5).compact())
        assertEquals("teacher", EvidenceSpec.TeacherVerification().compact())
        assertEquals("form:f1", EvidenceSpec.Form("f1").compact())
        assertEquals(
            "composite(counter:5+teacher)",
            EvidenceSpec.Composite(listOf(EvidenceSpec.Counter(5), EvidenceSpec.TeacherVerification())).compact(),
        )
    }

    @Test
    fun `parseCompact is the exact inverse of compact for every non-composite case`() {
        assertEquals(EvidenceSpec.SelfCheck, EvidenceSpec.parseCompact("self"))
        assertEquals(EvidenceSpec.Timer(60), EvidenceSpec.parseCompact("timer:60"))
        assertEquals(EvidenceSpec.Counter(5), EvidenceSpec.parseCompact("counter:5"))
        assertEquals(EvidenceSpec.Form("f1"), EvidenceSpec.parseCompact("form:f1"))
        // The stream format has no slot for formVersionId — "teacher" always parses back null.
        assertEquals(EvidenceSpec.TeacherVerification(null), EvidenceSpec.parseCompact("teacher"))
    }

    @Test
    fun `parseCompact round-trips a nested composite`() {
        val spec = EvidenceSpec.Composite(listOf(EvidenceSpec.Counter(5), EvidenceSpec.TeacherVerification()))
        assertEquals(spec, EvidenceSpec.parseCompact(spec.compact()))

        val nested = EvidenceSpec.Composite(
            listOf(
                EvidenceSpec.Composite(listOf(EvidenceSpec.Counter(3), EvidenceSpec.Timer(30))),
                EvidenceSpec.SelfCheck,
            ),
        )
        assertEquals(nested, EvidenceSpec.parseCompact(nested.compact()))
    }

    @Test
    fun `parseCompact rejects malformed input rather than guessing`() {
        assertThrows(IllegalArgumentException::class.java) { EvidenceSpec.parseCompact("bogus") }
        assertThrows(IllegalArgumentException::class.java) { EvidenceSpec.parseCompact("timer:abc") }
        assertThrows(IllegalArgumentException::class.java) { EvidenceSpec.parseCompact("counter:") }
        assertThrows(IllegalArgumentException::class.java) { EvidenceSpec.parseCompact("form:") }
        assertThrows(IllegalArgumentException::class.java) { EvidenceSpec.parseCompact("composite()") }
    }
}
