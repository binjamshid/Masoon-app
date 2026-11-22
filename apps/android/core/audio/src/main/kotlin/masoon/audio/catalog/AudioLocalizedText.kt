package masoon.audio.catalog

import kotlinx.serialization.json.JsonObject

/**
 * Bilingual display text for a catalog document (`meta.title`, `reciter.display_name`, ...) —
 * matches `audio-catalog-v1.schema.json`'s `LocalizedText` `$def`: `ar` is required, `en` is
 * optional. Ported from `apps/ios/Packages/Sources/MasoonAudio/AudioLocalizedText.swift`.
 *
 * Deliberately NOT `:core:designsystem`'s `L(ar, en)` / `MasoonDsLocale` — this module has no
 * dependency on `:core:designsystem` and stays engine-only; a future UI layer picks which string
 * to show.
 */
data class AudioLocalizedText(
    val ar: String,
    val en: String? = null,
) {
    companion object {
        fun fromJson(obj: JsonObject): AudioLocalizedText {
            val ar =
                obj.stringOrNull("ar")?.takeIf { it.isNotEmpty() }
                    ?: throw AudioCatalogException("localized text missing required non-empty 'ar'")
            val enElement = obj["en"]
            val en =
                if (enElement != null) {
                    obj.stringOrNull("en")?.takeIf { it.isNotEmpty() }
                        ?: throw AudioCatalogException(
                            "localized text 'en' must be a non-empty string when present",
                        )
                } else {
                    null
                }
            return AudioLocalizedText(ar = ar, en = en)
        }
    }
}
