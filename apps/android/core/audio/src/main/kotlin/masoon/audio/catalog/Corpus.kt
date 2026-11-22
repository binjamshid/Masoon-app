package masoon.audio.catalog

/**
 * Which corpus a reciter's audio covers. `code` matches `audio-catalog-v1.schema.json`'s `Kind`
 * `$def` (`"quran"` | `"poem"`) exactly — the raw value round-trips through catalog JSON.
 */
enum class Corpus(
    val code: String,
) {
    QURAN("quran"),
    POEM("poem"),
    ;

    companion object {
        fun fromCode(code: String): Corpus? = entries.firstOrNull { it.code == code }
    }
}
