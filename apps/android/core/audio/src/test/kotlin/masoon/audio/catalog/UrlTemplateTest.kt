package masoon.audio.catalog

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

/** Ported from `apps/ios/Packages/Tests/MasoonAudioTests/URLTemplateTests.swift`. */
class UrlTemplateTest {
    @Test
    fun `work and unit zero padded`() {
        assertEquals("009001.mp3", UrlTemplate.expand("{work:03}{unit:03}.mp3", work = 9, unit = 1))
        assertEquals("114006.mp3", UrlTemplate.expand("{work:03}{unit:03}.mp3", work = 114, unit = 6))
    }

    @Test
    fun `work and unit unpadded`() {
        assertEquals("9-1.mp3", UrlTemplate.expand("{work}-{unit}.mp3", work = 9, unit = 1))
    }

    @Test
    fun `mixed padded and unpadded in one template`() {
        assertEquals("s2/002255.mp3", UrlTemplate.expand("s{work}/{work:03}{unit:03}.mp3", work = 2, unit = 255))
    }

    @Test
    fun `value wider than three digits is not truncated`() {
        assertEquals("1234", UrlTemplate.expand("{unit:03}", work = 1, unit = 1234))
    }

    @Test
    fun `literal text around placeholders passes through`() {
        assertEquals(
            "data/Alafasy_128kbps/001001.mp3",
            UrlTemplate.expand("data/Alafasy_128kbps/{work:03}{unit:03}.mp3", work = 1, unit = 1),
        )
    }

    @Test
    fun `template with no placeholders returns itself unchanged`() {
        assertEquals("static/file.mp3", UrlTemplate.expand("static/file.mp3", work = 1, unit = 1))
    }

    @Test
    fun `zero values pad correctly`() {
        // Not a real Qur'an work/unit, but the function itself must not special-case 0.
        assertEquals("000000", UrlTemplate.expand("{work:03}{unit:03}", work = 0, unit = 0))
    }

    // MARK: - Rejection (fail loud, never a silently-wrong URL)

    @Test
    fun `unknown placeholder throws`() {
        val error =
            assertThrows(UrlTemplateException.UnknownPlaceholder::class.java) {
                UrlTemplate.expand("{surah:03}{ayah:03}.mp3", work = 9, unit = 1)
            }
        assertEquals("{surah:03}", error.token)
    }

    @Test
    fun `unknown placeholder embedded among valid ones still throws`() {
        val error =
            assertThrows(UrlTemplateException.UnknownPlaceholder::class.java) {
                UrlTemplate.expand("{work:03}/{bogus}/{unit:03}.mp3", work = 9, unit = 1)
            }
        assertEquals("{bogus}", error.token)
    }

    @Test
    fun `case sensitive placeholder is rejected`() {
        assertThrows(UrlTemplateException::class.java) {
            UrlTemplate.expand("{WORK:03}{unit:03}.mp3", work = 9, unit = 1)
        }
    }

    @Test
    fun `unterminated brace throws`() {
        assertThrows(UrlTemplateException.UnterminatedPlaceholder::class.java) {
            UrlTemplate.expand("{work:03", work = 9, unit = 1)
        }
    }

    @Test
    fun `negative work throws`() {
        assertThrows(UrlTemplateException::class.java) { UrlTemplate.expand("{work:03}", work = -1, unit = 1) }
    }

    @Test
    fun `negative unit throws`() {
        assertThrows(UrlTemplateException::class.java) { UrlTemplate.expand("{unit:03}", work = 1, unit = -1) }
    }
}
