package masoon.audio.catalog

/**
 * Thrown by [UrlTemplate.expand] for a malformed template or a negative `work`/`unit`. Ported
 * from `URLTemplateError` in `apps/ios/Packages/Sources/MasoonAudio/URLTemplate.swift`.
 */
sealed class UrlTemplateException(
    message: String,
) : IllegalArgumentException(message) {
    data class UnknownPlaceholder(
        val token: String,
    ) : UrlTemplateException(
            "unknown url_template placeholder '$token' (closed set: {work:03} {unit:03} {work} {unit})",
        )

    data object UnterminatedPlaceholder : UrlTemplateException("unterminated '{' in url_template")

    data class NegativeValue(
        val which: String,
    ) : UrlTemplateException("url_template expansion given a negative $which")
}

/**
 * Pure, allocation-cheap expansion of a `url_template` string (`audio-catalog-v1.schema.json` /
 * `audio-manifest-v1.schema.json`'s `UrlTemplate` `$def`) against a concrete `work`/`unit` pair.
 * No network, no locale-dependent formatting APIs (this is filename math, not display text).
 *
 * The placeholder set is CLOSED, matching the schema's own regex exactly:
 *  - `{work:03}`  3-digit zero-padded work number   (surah, e.g. "009")
 *  - `{unit:03}`  3-digit zero-padded unit number    (ayah,  e.g. "001")
 *  - `{work}`     unpadded work number
 *  - `{unit}`     unpadded unit number
 * Any other `{...}` token — a typo, a future placeholder never added here, or an unterminated
 * `{` — THROWS. A silently-wrong audio URL is a shipped correctness bug, not a lint nit, so this
 * fails loud rather than emitting the literal unexpanded token or dropping it.
 *
 * Ported from `apps/ios/Packages/Sources/MasoonAudio/URLTemplate.swift`.
 */
object UrlTemplate {
    /**
     * Expands [template] for one `(work, unit)` pair. `base_url + expand(url_template, ...)` is
     * the entire URL-resolution algorithm (`contracts/audio/README.md`, "How URL resolution
     * works") — no other path in the app builds a playable audio URL any other way.
     *
     * Four distinct failure modes (negative work, negative unit, unterminated brace, unknown
     * placeholder) each throw their own [UrlTemplateException] case naming exactly what went
     * wrong — collapsing them into fewer throw sites would blur which one fired.
     */
    @Suppress("ThrowsCount")
    fun expand(
        template: String,
        work: Int,
        unit: Int,
    ): String {
        if (work < 0) throw UrlTemplateException.NegativeValue("work")
        if (unit < 0) throw UrlTemplateException.NegativeValue("unit")

        val result = StringBuilder(template.length)
        var index = 0
        while (index < template.length) {
            val brace = template.indexOf('{', index)
            if (brace < 0) {
                result.append(template, index, template.length)
                break
            }
            result.append(template, index, brace)
            val close = template.indexOf('}', brace + 1)
            if (close < 0) throw UrlTemplateException.UnterminatedPlaceholder
            val token = template.substring(brace, close + 1) // includes braces, e.g. "{work:03}"
            when (token) {
                "{work:03}" -> result.append(pad3(work))
                "{unit:03}" -> result.append(pad3(unit))
                "{work}" -> result.append(work)
                "{unit}" -> result.append(unit)
                else -> throw UrlTemplateException.UnknownPlaceholder(token)
            }
            index = close + 1
        }
        return result.toString()
    }

    /** 3-digit zero-padded decimal, e.g. `9 -> "009"`, `114 -> "114"`, `1234 -> "1234"` (never truncates). */
    private fun pad3(n: Int): String {
        val s = n.toString()
        return if (s.length >= 3) s else "0".repeat(3 - s.length) + s
    }
}
