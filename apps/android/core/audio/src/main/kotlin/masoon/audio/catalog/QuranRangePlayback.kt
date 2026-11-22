package masoon.audio.catalog

import masoon.domain.CanonicalRange
import masoon.domain.ContentIndex

/**
 * The range-based playback entry point. This is a PLAN, not a player — `masoon.audio.playback`
 * (which this package must never depend on; the dependency arrow points the other way) is the
 * thing that actually turns a plan into sound. [plan] does the one thing that belongs on this
 * side of the module boundary: expand a [CanonicalRange] into an ordered [PlaybackRequest] via
 * the already-existing, pure [QuranAudioMapping] (no I/O, no reciter/URL knowledge there either)
 * and attach the two knobs [PlaybackRequest] has no opinion about — inter-repeat pause and speed
 * — that the playback engine needs to actually run a loop.
 *
 * Ported from `apps/ios/Packages/Sources/MasoonAudio/RangePlaybackPlan.swift`'s
 * `QuranRangePlayback` enum.
 */
object QuranRangePlayback {
    /**
     * Builds a [RangePlaybackPlan] for one canonical range. [count] becomes
     * [PlaybackRequest.repeatCount] (already clamped to `>= 1` there); [pauseBetweenMillis]/
     * [speed] are carried alongside, unapplied here — `RepeatPauseController` and
     * `AudioPlayerEngine.rate` are what actually consume them.
     *
     * [displayTitle]/[displaySubtitle] are pre-formatted strings from the caller (a future Mushaf
     * UI layer), exactly like [PlaybackRequest]'s own doc comment requires — this function has no
     * locale/formatter dependency and never invents wording.
     */
    @Suppress("LongParameterList") // mirrors the iOS signature 1:1 — every parameter is independently meaningful
    fun plan(
        range: CanonicalRange,
        index: ContentIndex,
        reciterId: String,
        corpus: Corpus = Corpus.QURAN,
        count: Int = 1,
        pauseBetweenMillis: Long = 0,
        speed: Float = 1.0f,
        displayTitle: String,
        displaySubtitle: String? = null,
    ): RangePlaybackPlan {
        val units = QuranAudioMapping.units(range, index)
        val request =
            PlaybackRequest(
                reciterId = reciterId,
                corpus = corpus,
                units = units,
                displayTitle = displayTitle,
                displaySubtitle = displaySubtitle,
                repeatCount = count,
            )
        return RangePlaybackPlan(request = request, pauseBetweenRepeatsMillis = pauseBetweenMillis, speed = speed)
    }

    /**
     * Same as [plan] but for several ranges concatenated in order (e.g. a task whose content
     * spans more than one surah) — mirrors [QuranAudioMapping.units]'s existing multi-range
     * overload rather than making callers loop and merge [PlaybackUnit] arrays themselves.
     */
    @Suppress("LongParameterList")
    fun plan(
        ranges: List<CanonicalRange>,
        index: ContentIndex,
        reciterId: String,
        corpus: Corpus = Corpus.QURAN,
        count: Int = 1,
        pauseBetweenMillis: Long = 0,
        speed: Float = 1.0f,
        displayTitle: String,
        displaySubtitle: String? = null,
    ): RangePlaybackPlan {
        val units = QuranAudioMapping.units(ranges, index)
        val request =
            PlaybackRequest(
                reciterId = reciterId,
                corpus = corpus,
                units = units,
                displayTitle = displayTitle,
                displaySubtitle = displaySubtitle,
                repeatCount = count,
            )
        return RangePlaybackPlan(request = request, pauseBetweenRepeatsMillis = pauseBetweenMillis, speed = speed)
    }
}
