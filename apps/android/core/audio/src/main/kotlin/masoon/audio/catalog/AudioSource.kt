package masoon.audio.catalog

/**
 * Errors any [AudioSource] conformer may throw resolving a manifest or URL. Ported from
 * `AudioSourceError` in `apps/ios/Packages/Sources/MasoonAudio/AudioSource.swift`.
 */
sealed class AudioSourceException(
    message: String,
) : Exception(message) {
    data class UnknownReciter(
        val reciterId: String,
    ) : AudioSourceException("no catalog entry for reciter '$reciterId'")

    data class NoSource(
        val reciterId: String,
        val provider: AudioProvider,
    ) : AudioSourceException("reciter '$reciterId' has no ${provider.code} source")

    data class InsecureBaseUrl(
        val url: String,
    ) : AudioSourceException("audio source base_url must be https:// (got '$url')")

    data class Network(
        val detail: String,
    ) : AudioSourceException("audio source network error: $detail")

    data class HttpStatus(
        val code: Int,
    ) : AudioSourceException("audio source returned unexpected HTTP status $code")

    data class MalformedManifest(
        val detail: String,
    ) : AudioSourceException("audio source returned malformed manifest: $detail")
}

/** Supplies reciter manifests to the playback client. The caller chooses the source. */
interface AudioSource {
    /**
     * Resolves a reciter id to its playable manifest (`base_url` + `url_template`,
     * `audio-manifest-v1` shape). Throws [AudioSourceException.UnknownReciter] /
     * [AudioSourceException.NoSource] when this source has no entry for [reciterId] — never
     * returns a manifest for a reciter it cannot actually serve.
     */
    suspend fun manifest(reciterId: String): AudioManifest
}

/**
 * Resolves the playable URL for exactly one `(work, unit)` — `manifest.baseUrl +
 * UrlTemplate.expand(manifest.urlTemplate, ...)`. Shared by every conformer so a source swap
 * changes zero call sites.
 */
suspend fun AudioSource.resolvedUrl(
    reciterId: String,
    work: Int,
    unit: Int,
): String {
    val manifest = manifest(reciterId)
    val expanded = UrlTemplate.expand(manifest.urlTemplate, work = work, unit = unit)
    return manifest.baseUrl + expanded
}
