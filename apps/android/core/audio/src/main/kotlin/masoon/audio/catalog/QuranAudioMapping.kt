package masoon.audio.catalog

import masoon.domain.CanonicalRange
import masoon.domain.ContentIndex

/**
 * Pure geometry: expands canonical Qur'an ranges into an ordered playlist of `(work, unit)` pairs
 * — no I/O, no reciter/URL knowledge. A [PlaybackRequest]'s [PlaybackRequest.units] array is
 * built by this, then handed to an [AudioSource] ([resolvedUrl]) per unit at the point the actual
 * URL/local file is needed — this module never fuses the two.
 *
 * Corpus-agnostic by construction ([ContentIndex], not `QuranIndex` directly), matching this
 * whole package's "generic today, only Qur'an wired up" naming discipline ([Corpus]). Still named
 * `QuranAudioMapping` because Qur'an is the only corpus with reciter audio today — a future
 * poem-corpus mapping would get its own type once poem audio (D-084, still gated) actually
 * exists, rather than this one silently growing a second responsibility.
 *
 * Ported from `apps/ios/Packages/Sources/MasoonAudio/QuranAudioMapping.swift`.
 */
class QuranAudioMappingException(
    val surah: Int,
    val ayahStart: Int,
    val ayahEnd: Int,
) : IllegalArgumentException("range $surah:$ayahStart-$ayahEnd is out of bounds for this content index")

object QuranAudioMapping {
    /**
     * Expands one canonical range into its ordered `(work, unit)` pairs. [CanonicalRange] is
     * always single-work by construction, so this never crosses a work boundary.
     */
    fun units(
        range: CanonicalRange,
        index: ContentIndex,
    ): List<PlaybackUnit> {
        val globalRange =
            index.globalRangeOf(range)
                ?: throw QuranAudioMappingException(range.surah, range.ayahStart, range.ayahEnd)
        return globalRange.map { g -> PlaybackUnit(work = index.workOfGlobal(g), unit = index.unitOfGlobal(g)) }
    }

    /**
     * Expands several ranges in order (e.g. a task's content spanning more than one surah) and
     * concatenates the results — order preserved, duplicates NOT collapsed (a range legitimately
     * repeated in [ranges] by a caller stays repeated).
     */
    fun units(
        ranges: List<CanonicalRange>,
        index: ContentIndex,
    ): List<PlaybackUnit> = ranges.flatMap { units(it, index) }
}
