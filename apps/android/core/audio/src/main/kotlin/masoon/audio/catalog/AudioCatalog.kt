package masoon.audio.catalog

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Thrown for a malformed `audio-catalog-v1` document (`contracts/json-schema/
 * audio-catalog-v1.schema.json`, D:AD-1). Ported from `AudioCatalogError.malformed` in
 * `apps/ios/Packages/Sources/MasoonAudio/AudioCatalog.swift`.
 */
class AudioCatalogException(
    message: String,
) : IllegalArgumentException("audio catalog malformed: $message")

/**
 * Typed model of an `audio-catalog-v1` document. Mirrors `masoon.domain.PoemIndex.fromJson`'s
 * discipline exactly: parse schema-shaped JSON into typed Kotlin, throw on malformed input, never
 * silently default a required field. This loader does NOT re-validate the deeper regex patterns
 * the JSON Schema already enforces (identifier shape, `url_template` placeholder set, https-only
 * `base_url`) — those are validated once, authoritatively, by `tooling/contracts-check` (ajv)
 * against every committed catalog document; this loader's job is structural well-formedness or a
 * thrown error. [masoon.audio.catalog.UrlTemplate.expand] DOES enforce the placeholder set at
 * runtime, because that boundary is genuinely load-bearing (a silently-wrong URL is a shipped
 * bug, not just a lint failure). Ported from
 * `apps/ios/Packages/Sources/MasoonAudio/AudioCatalog.swift`.
 */
data class AudioCatalogMeta(
    val slug: String,
    val title: AudioLocalizedText,
    val description: AudioLocalizedText? = null,
    val version: String = "1.0.0",
    val generatedAt: String? = null,
) {
    companion object {
        fun fromJson(obj: JsonObject): AudioCatalogMeta {
            val slug =
                obj.stringOrNull("slug")?.takeIf { it.isNotEmpty() }
                    ?: throw AudioCatalogException("meta.slug missing")
            val titleJson = obj["title"]?.jsonObject ?: throw AudioCatalogException("meta.title missing")
            val title = AudioLocalizedText.fromJson(titleJson)
            val description = obj["description"]?.jsonObject?.let { AudioLocalizedText.fromJson(it) }
            val version = obj.stringOrNull("version") ?: "1.0.0"
            return AudioCatalogMeta(
                slug = slug,
                title = title,
                description = description,
                version = version,
                generatedAt = obj.stringOrNull("generated_at"),
            )
        }
    }
}

/** One entry in [AudioReciterEntry.sources] — a place this reciter's audio can be streamed from. */
data class AudioCatalogSource(
    val id: String,
    val provider: AudioProvider,
    val baseUrl: String,
    val urlTemplate: String,
    val notes: String? = null,
) {
    companion object {
        // Exhaustive per-field validation (see AudioManifest.fromJson's own comment on this
        // pattern) — each throw names exactly which field was missing/invalid.
        @Suppress("ThrowsCount")
        fun fromJson(obj: JsonObject): AudioCatalogSource {
            val id =
                obj.stringOrNull("id")?.takeIf { it.isNotEmpty() }
                    ?: throw AudioCatalogException("source.id missing")
            val providerCode = obj.stringOrNull("provider")
            val provider =
                providerCode?.let { AudioProvider.fromCode(it) }
                    ?: throw AudioCatalogException("source $id: provider missing or unknown")
            val baseUrl =
                obj.stringOrNull("base_url")?.takeIf { it.isNotEmpty() }
                    ?: throw AudioCatalogException("source $id: base_url missing")
            val urlTemplate =
                obj.stringOrNull("url_template")?.takeIf { it.isNotEmpty() }
                    ?: throw AudioCatalogException("source $id: url_template missing")
            return AudioCatalogSource(
                id = id,
                provider = provider,
                baseUrl = baseUrl,
                urlTemplate = urlTemplate,
                notes = obj.stringOrNull("notes"),
            )
        }
    }
}

/**
 * One reciter's catalog entry. [unitCounts] is REQUIRED when `kind == Corpus.POEM` and FORBIDDEN
 * when `kind == Corpus.QURAN` at the schema level (`if`/`then`/`else` in
 * `audio-catalog-v1.schema.json`) — this loader mirrors that as a thrown error, not a silent
 * default.
 */
data class AudioReciterEntry(
    val id: String,
    val kind: Corpus,
    val displayName: AudioLocalizedText,
    val sources: List<AudioCatalogSource>,
    val unitCounts: List<Int>? = null,
) {
    /** The first source for a given provider, in declaration order. */
    fun source(provider: AudioProvider): AudioCatalogSource? = sources.firstOrNull { it.provider == provider }

    companion object {
        // Exhaustive per-field validation (see AudioManifest.fromJson's own comment on this
        // pattern) — each throw names exactly which field was missing/invalid.
        @Suppress("ThrowsCount")
        fun fromJson(obj: JsonObject): AudioReciterEntry {
            val id =
                obj.stringOrNull("id")?.takeIf { it.isNotEmpty() }
                    ?: throw AudioCatalogException("reciter entry missing id")
            val kindCode = obj.stringOrNull("kind")
            val kind =
                kindCode?.let { Corpus.fromCode(it) }
                    ?: throw AudioCatalogException("reciter $id: kind missing or unknown")
            val nameJson =
                obj["display_name"]?.jsonObject ?: throw AudioCatalogException("reciter $id: display_name missing")
            val displayName = AudioLocalizedText.fromJson(nameJson)
            val sourcesJson =
                obj["sources"]?.jsonArray?.takeIf { it.isNotEmpty() }
                    ?: throw AudioCatalogException("reciter $id: sources missing or empty")
            val sources = sourcesJson.map { AudioCatalogSource.fromJson(it.jsonObject) }

            val unitCounts =
                when (kind) {
                    Corpus.QURAN -> {
                        if (obj["unit_counts"] != null) {
                            throw AudioCatalogException(
                                "reciter $id: kind=quran must not declare unit_counts " +
                                    "(ayah counts come from the app's own Quran index)",
                            )
                        }
                        null
                    }
                    Corpus.POEM -> {
                        val arr =
                            obj["unit_counts"]?.jsonArray?.takeIf { it.isNotEmpty() }
                                ?: throw AudioCatalogException("reciter $id: kind=poem requires non-empty unit_counts")
                        arr.map { it.jsonPrimitive.intOrThrow(id) }
                    }
                }

            return AudioReciterEntry(
                id = id,
                kind = kind,
                displayName = displayName,
                sources = sources,
                unitCounts = unitCounts,
            )
        }
    }
}

private fun JsonPrimitive.intOrThrow(reciterId: String): Int =
    content.toIntOrNull()
        ?: throw AudioCatalogException("reciter $reciterId: unit_counts contains a non-integer entry")

/** The full catalog document. */
data class AudioCatalog(
    val meta: AudioCatalogMeta,
    val reciters: List<AudioReciterEntry>,
) {
    /** Looks up a reciter by id, in corpus declaration order. */
    fun reciter(id: String): AudioReciterEntry? = reciters.firstOrNull { it.id == id }

    /** Every reciter whose `kind` matches [corpus], in declaration order. */
    fun reciters(corpus: Corpus): List<AudioReciterEntry> = reciters.filter { it.kind == corpus }

    companion object {
        // Exhaustive per-field validation (see AudioManifest.fromJson's own comment on this
        // pattern) — each throw names exactly which field was missing/invalid.
        @Suppress("ThrowsCount")
        fun fromJson(obj: JsonObject): AudioCatalog {
            val metaJson = obj["meta"]?.jsonObject ?: throw AudioCatalogException("meta missing")
            val meta = AudioCatalogMeta.fromJson(metaJson)
            val recitersJson =
                obj["reciters"]?.jsonArray?.takeIf { it.isNotEmpty() }
                    ?: throw AudioCatalogException("reciters missing or empty")
            val reciters = mutableListOf<AudioReciterEntry>()
            val seenIds = HashSet<String>()
            for (item in recitersJson) {
                val entry = AudioReciterEntry.fromJson(item.jsonObject)
                if (!seenIds.add(entry.id)) {
                    throw AudioCatalogException("duplicate reciter id '${entry.id}'")
                }
                reciters.add(entry)
            }
            return AudioCatalog(meta = meta, reciters = reciters)
        }

        /** Parses raw JSON text (a bundled asset or a fetched document) into a validated [AudioCatalog]. */
        fun parse(text: String): AudioCatalog = fromJson(Json.parseToJsonElement(text).jsonObject)
    }
}
