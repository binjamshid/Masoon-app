package masoon.audio.catalog

/**
 * A [PlaybackRequest] plus the two loop knobs it does not itself carry. Kept as a separate type
 * — rather than adding [pauseBetweenRepeatsMillis]/[speed] fields onto [PlaybackRequest] itself —
 * because [PlaybackRequest] is also used for the plain "play this once" path with no loop
 * semantics at all (`AudioPlayerEngine.load`); overloading it would force every existing call
 * site to reason about pause/speed defaults it has no use for.
 *
 * Like [PlaybackRequest], the primary constructor is private and reached only through the
 * companion `operator fun invoke` below, so [pauseBetweenRepeatsMillis] is always clamped to
 * `>= 0` before storage — mirrors iOS's `max(0, pauseBetweenRepeats)` (a silent clamp, not a
 * thrown precondition failure). Ported from
 * `apps/ios/Packages/Sources/MasoonAudio/RangePlaybackPlan.swift`.
 */
@ConsistentCopyVisibility
data class RangePlaybackPlan
    private constructor(
        val request: PlaybackRequest,
        /**
         * Silence between repetition passes, in milliseconds. `0` means "no pause" —
         * `masoon.audio.playback.RepeatPauseController` treats `<= 0` as "resume immediately"
         * rather than entering a paused state at all.
         */
        val pauseBetweenRepeatsMillis: Long,
        /**
         * Playback rate to apply once loaded. Clamping to `[0.5, 1.5]` happens in
         * `AudioPlayerEngine.clampRate` — this type does not duplicate that clamp, it just
         * carries the raw requested value through.
         */
        val speed: Float,
    ) {
        companion object {
            operator fun invoke(
                request: PlaybackRequest,
                pauseBetweenRepeatsMillis: Long = 0,
                speed: Float = 1.0f,
            ): RangePlaybackPlan =
                RangePlaybackPlan(
                    request = request,
                    pauseBetweenRepeatsMillis = maxOf(0, pauseBetweenRepeatsMillis),
                    speed = speed,
                )
        }
    }
