package masoon.audio.catalog

/**
 * One atomic content unit to play — `(work, unit)` in the corpus-agnostic vocabulary
 * (`masoon.domain.ContentIndex`); for the Qur'an, `(surah, ayah)`. Produced by
 * [QuranAudioMapping], consumed by [masoon.audio.playback.AudioAssetResolver] and
 * [masoon.audio.playback.AudioPlayerEngine]'s queue builder.
 */
data class PlaybackUnit(
    val work: Int,
    val unit: Int,
)

/**
 * Everything needed to play one ordered stretch of content once a reciter is chosen — the request
 * a future UI layer builds and hands to the playback engine. [displayTitle]/[displaySubtitle] are
 * PRE-FORMATTED strings injected by that future UI layer: this module itself has no locale/
 * formatter dependency (no `:core:designsystem` import anywhere — see [AudioLocalizedText]'s doc
 * comment) and stays engine-only, so it never decides "Arabic vs. mixed vs. English" wording
 * itself.
 *
 * The primary constructor is private and reached only through the companion `operator fun
 * invoke` below, so every call site keeps the ordinary `PlaybackRequest(...)` call syntax while
 * [repeatCount] is always clamped to `>= 1` before the value is ever stored — mirroring iOS's
 * `max(1, repeatCount)` (a silent clamp, not a thrown precondition failure).
 *
 * Ported from `apps/ios/Packages/Sources/MasoonAudio/PlaybackRequest.swift`.
 */
@ConsistentCopyVisibility
data class PlaybackRequest
    private constructor(
        val reciterId: String,
        val corpus: Corpus,
        /** Ordered playlist for this request, already expanded by [QuranAudioMapping]. */
        val units: List<PlaybackUnit>,
        val displayTitle: String,
        val displaySubtitle: String?,
        /**
         * How many times the whole [units] playlist repeats, concatenated
         * (`AudioPlayerEngine.buildQueueUrls` builds `repeatCount` back-to-back copies of the
         * queue — never a seek-back-on-end loop). Always `>= 1`.
         */
        val repeatCount: Int,
    ) {
        companion object {
            operator fun invoke(
                reciterId: String,
                corpus: Corpus,
                units: List<PlaybackUnit>,
                displayTitle: String,
                displaySubtitle: String? = null,
                repeatCount: Int = 1,
            ): PlaybackRequest =
                PlaybackRequest(
                    reciterId = reciterId,
                    corpus = corpus,
                    units = units,
                    displayTitle = displayTitle,
                    displaySubtitle = displaySubtitle,
                    repeatCount = maxOf(1, repeatCount),
                )
        }
    }
