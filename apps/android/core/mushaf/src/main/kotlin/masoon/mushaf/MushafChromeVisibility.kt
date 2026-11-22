package masoon.mushaf

/**
 * Pure auto-hiding chrome state machine. Owns only the visibility bit and an elapsed-time
 * counter — the UI owns driving [elapsed] from a periodic tick and calling [interacted] /
 * [toggle] from gestures.
 *
 * Dependency-free (no coroutines, no Compose state) so it is exhaustively testable as a plain
 * value. Immutable with `copy`-style transitions rather than iOS's `mutating` methods, which is
 * what lets it live directly in a `MutableStateFlow` without a lock.
 */
data class MushafChromeVisibility(
    val isVisible: Boolean = true,
    private val secondsSinceLastInteraction: Float = 0f,
) {
    /** A deliberate interaction: chrome shows immediately and the auto-hide clock resets. */
    fun interacted(): MushafChromeVisibility =
        MushafChromeVisibility(isVisible = true, secondsSinceLastInteraction = 0f)

    /** An explicit user toggle (a centre-zone tap), independent of the auto-hide timer. */
    fun toggle(): MushafChromeVisibility =
        MushafChromeVisibility(isVisible = !isVisible, secondsSinceLastInteraction = 0f)

    /**
     * Advances the clock. Hides the chrome once [autoHideDelay] has elapsed since the last
     * interaction; a no-op while already hidden, since there is no clock worth advancing once
     * there is nothing left to hide.
     */
    fun elapsed(
        seconds: Float,
        autoHideDelay: Float,
    ): MushafChromeVisibility {
        if (!isVisible || seconds <= 0f) return this
        val total = secondsSinceLastInteraction + seconds
        return if (total >= autoHideDelay) {
            MushafChromeVisibility(isVisible = false, secondsSinceLastInteraction = total)
        } else {
            copy(secondsSinceLastInteraction = total)
        }
    }
}
