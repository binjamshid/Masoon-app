package masoon.domain

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class Uuid5Test {

    @Test
    fun `sha1 vector abc`() {
        assertEquals("a9993e364706816aba3e25717850c26c9cd0d89d", Uuid5.sha1Hex("abc"))
    }

    @Test
    fun `uuid5 dns vector`() {
        // RFC 4122 §4.3 with the DNS namespace. NOTE: this is the errata-corrected value
        // (RFC 4122 Appendix B printed a wrong output; erratum 1352). Independently verified
        // against python uuid.uuid5 and a manual SHA-1 computation.
        assertEquals(
            "2ed6657d-e927-568b-95e1-2665a8aea6a2",
            Uuid5.uuid5("6ba7b810-9dad-11d1-80b4-00c04fd430c8", "www.example.com"),
        )
    }

    @Test
    fun `task uid shape and determinism`() {
        val planId = "00000000-0000-0000-0000-000000000001"
        val name = "2026-07-12|morning|new_hifz|0"
        val a = Uuid5.uuid5(planId, name)
        val b = Uuid5.uuid5(planId, name)
        assertEquals(a, b)
        assertEquals(36, a.length)
        // version 5 and RFC variant nibbles
        assertEquals('5', a[14])
        check(a[19] in listOf('8', '9', 'a', 'b'))
        // lowercase hyphenated hex
        assertEquals(a, a.lowercase())
    }
}
