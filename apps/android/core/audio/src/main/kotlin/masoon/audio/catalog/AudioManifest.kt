package masoon.audio.catalog

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Thrown for a malformed `audio-manifest-v1` document (`contracts/json-schema/
 * audio-manifest-v1.schema.json`). Ported from `AudioManifestError.malformed` in
 * `apps/ios/Packages/Sources/MasoonAudio/AudioManifest.swift`.
 */
class AudioManifestException(
    message: String,
) : IllegalArgumentException("audio manifest malformed: $message")

/** `obj[key]`'s string content, or null when absent/JSON-null. Throws if present but not a primitive. */
internal fun JsonObject.stringOrNull(key: String): String? = this[key]?.jsonPrimitive?.contentOrNull

/**
 * Which source implementation a manifest/catalog source entry describes. Matches `Provider` in
 * both schemas exactly (`"everyayah"` | `"vps"`).
 */
enum class AudioProvider(
    val code: String,
) {
    EVERYAYAH("everyayah"),
    VPS("vps"),
    ;

    companion object {
        fun fromCode(code: String): AudioProvider? = entries.firstOrNull { it.code == code }
    }
}

/**
 * `License.commercial_use` is `boolean | "unknown"` in the schema — never collapsed to a bare
 * `Boolean?`, because "unknown" and "false" are meaningfully different claims (D-053 R-2:
 * everyayah's is a documented `false`; a not-yet-cleared VPS source is honestly `unknown`, never
 * defaulted to `true`).
 */
sealed interface CommercialUse {
    data class Allowed(
        val value: Boolean,
    ) : CommercialUse

    data object Unknown : CommercialUse

    companion object {
        /**
         * `isString` is checked explicitly (not the looser `content == "true"/"false"` a bare
         * `JsonPrimitive.booleanOrNull` extension would use) so a schema-invalid quoted string
         * `"true"`/`"false"` is correctly rejected rather than silently accepted as a boolean —
         * only an unquoted JSON `true`/`false` literal or the exact quoted string `"unknown"` is
         * legal here (`audio-manifest-v1.schema.json`'s `License.commercial_use`:
         * `boolean | "unknown"`).
         */
        fun fromJson(element: JsonElement): CommercialUse {
            val primitive =
                element as? JsonPrimitive
                    ?: throw AudioManifestException("license.commercial_use must be a boolean or \"unknown\"")
            if (!primitive.isString && (primitive.content == "true" || primitive.content == "false")) {
                return Allowed(primitive.content.toBooleanStrict())
            }
            if (primitive.isString && primitive.content == "unknown") {
                return Unknown
            }
            throw AudioManifestException("license.commercial_use must be a boolean or \"unknown\"")
        }
    }
}

data class AudioLicense(
    val name: String? = null,
    val url: String? = null,
    val termsUrl: String? = null,
    val commercialUse: CommercialUse,
    val notes: String? = null,
) {
    companion object {
        fun fromJson(obj: JsonObject): AudioLicense {
            val commercialUseJson =
                obj["commercial_use"] ?: throw AudioManifestException("license.commercial_use missing")
            return AudioLicense(
                name = obj.stringOrNull("name"),
                url = obj.stringOrNull("url"),
                termsUrl = obj.stringOrNull("terms_url"),
                commercialUse = CommercialUse.fromJson(commercialUseJson),
                notes = obj.stringOrNull("notes"),
            )
        }
    }
}

/**
 * Audio manifest specifying a reciter, a base URL, and a per-unit URL template.
 */
data class AudioManifest(
    val reciterId: String,
    val provider: AudioProvider,
    val baseUrl: String,
    val urlTemplate: String,
    val license: AudioLicense? = null,
    val notes: String? = null,
) {
    companion object {
        // Report the specific required field that is missing or malformed.
        @Suppress("ThrowsCount")
        fun fromJson(obj: JsonObject): AudioManifest {
            val reciterId =
                obj.stringOrNull("reciter_id")?.takeIf { it.isNotEmpty() }
                    ?: throw AudioManifestException("reciter_id missing")
            val providerCode = obj.stringOrNull("provider")
            val provider =
                providerCode?.let { AudioProvider.fromCode(it) }
                    ?: throw AudioManifestException("provider missing or unknown")
            val baseUrl =
                obj.stringOrNull("base_url")?.takeIf { it.isNotEmpty() }
                    ?: throw AudioManifestException("base_url missing")
            val urlTemplate =
                obj.stringOrNull("url_template")?.takeIf { it.isNotEmpty() }
                    ?: throw AudioManifestException("url_template missing")
            val license = obj["license"]?.jsonObject?.let { AudioLicense.fromJson(it) }
            return AudioManifest(
                reciterId = reciterId,
                provider = provider,
                baseUrl = baseUrl,
                urlTemplate = urlTemplate,
                license = license,
                notes = obj.stringOrNull("notes"),
            )
        }
    }
}
