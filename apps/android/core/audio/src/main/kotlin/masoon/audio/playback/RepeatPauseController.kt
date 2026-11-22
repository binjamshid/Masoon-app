package masoon.audio.playback

/**
 * Injectable-time seam for [RepeatPauseController] below — mirrors `:core:data`'s `WallClock`
 * shape ("real time lives only behind an interface, production code gets the real clock, tests
 * inject a fake"), but declared locally rather than imported: this package depends on
 * `masoon.audio.catalog` only and has no path to `:core:data`'s `WallClock`. Deliberately
 * narrower than `WallClock` — this only ever needs "how many milliseconds have elapsed," never
 * timezone-aware wall-clock math.
 *
 * Ported from `apps/ios/Packages/Sources/MasoonAudioPlayback/RepeatPauseController.swift`.
 */
interface RepeatPauseClock {
    /** Monotonic-ish "now", in milliseconds. Used only for pause-duration math. */
    fun nowMillis(): Long
}

/** Production clock. */
class SystemRepeatPauseClock : RepeatPauseClock {
    override fun nowMillis(): Long = System.currentTimeMillis()
}

/**
 * The inter-repeat pause state machine — a feature that DID NOT EXIST before this batch.
 * Deliberately NOT implemented by splicing silent audio files into the queue: a silence clip
 * would need to be generated/bundled per configured duration, would show up as a phantom "now
 * playing" item, and — the actual reason it is rejected — could not be paused/resumed/killed
 * with the same transport verbs as real playback, which is exactly the behavior this state
 * machine exists to make testable. Instead, the queue is genuinely paused between repetition
 * passes and a resume is scheduled, exactly like a human tapping pause and then play again later
 * — except the "later" is computed, not manual.
 *
 * Pure and clock-injected: every transition is a plain function of the current [state] and
 * `clock.nowMillis()`, so "pause -> kill mid-pause -> a stale resume must never fire" is
 * unit-testable without sleeping a real thread or driving a real coroutine delay. The ACTUAL
 * timer that turns [Action.PauseAndScheduleResume] into a real callback belongs to the
 * integration layer that owns [AudioPlayerEngine] — this type only decides WHAT should happen,
 * never WHEN a wall-clock timer literally fires.
 *
 * Ported from `apps/ios/Packages/Sources/MasoonAudioPlayback/RepeatPauseController.swift`.
 */
class RepeatPauseController(
    private val clock: RepeatPauseClock = SystemRepeatPauseClock(),
) {
    sealed interface State {
        /** No pause in flight — the queue is (or should be) playing normally. */
        data object Idle : State

        /** A repetition pass just ended; the queue is paused and due to resume once `now >= resumeAtMillis`. */
        data class Paused(
            val resumeAtMillis: Long,
        ) : State

        /**
         * The loop was killed while paused (user stopped, navigated away, etc.) — a resume that
         * was already scheduled before the kill must never be allowed to un-pause playback after
         * this.
         */
        data object Killed : State
    }

    sealed interface Action {
        /**
         * `pauseDurationMillis <= 0` (no configured pause) — resume immediately, there was never
         * anything to wait for.
         */
        data object ResumeNow : Action

        /**
         * Pause the queue now; the caller schedules a real timer for [resumeTimerFired] to be
         * called at (or after) [atMillis].
         */
        data class PauseAndScheduleResume(
            val atMillis: Long,
        ) : Action

        /** Un-pause the queue — the caller should call `AudioPlayerEngine.play()`. */
        data object Resume : Action

        /** Nothing to do — e.g. a timer fired early, or a stale event arrived after [kill]. */
        data object DoNothing : Action
    }

    var state: State = State.Idle
        private set

    /**
     * A repetition pass just finished. Enters [State.Paused] for [pauseDurationMillis]
     * milliseconds, UNLESS `pauseDurationMillis <= 0`, in which case there is nothing to pause
     * for and this returns [Action.ResumeNow] without ever touching [state] — a controller
     * configured with zero pause behaves exactly as if it were not wired in at all.
     */
    fun repetitionPassEnded(pauseDurationMillis: Long): Action {
        if (pauseDurationMillis <= 0) return Action.ResumeNow
        val resumeAt = clock.nowMillis() + pauseDurationMillis
        state = State.Paused(resumeAt)
        return Action.PauseAndScheduleResume(resumeAt)
    }

    /**
     * Called by the caller's timer when it BELIEVES the pause is over. Re-checked against
     * `clock.nowMillis()` rather than trusted blindly — a caller whose timer coalesced/fired a
     * hair early gets told to wait rather than resuming prematurely. Not [State.Paused] (already
     * idle, or killed) -> [Action.DoNothing]: a stale/duplicate timer fire is never allowed to
     * resume a loop the user has since stopped.
     */
    fun resumeTimerFired(): Action {
        val paused = state as? State.Paused
        return when {
            paused == null -> Action.DoNothing
            clock.nowMillis() < paused.resumeAtMillis -> Action.DoNothing
            else -> {
                state = State.Idle
                Action.Resume
            }
        }
    }

    /**
     * The loop is being torn down (user stopped mid-pause, navigated away, the range finished its
     * last pass, etc.). Idempotent: killing an already-killed controller is a no-op, not an error.
     */
    fun kill(): Action {
        if (state == State.Killed) return Action.DoNothing
        state = State.Killed
        return Action.DoNothing
    }

    /**
     * Returns the controller to [State.Idle] for reuse on a fresh loop — [kill] is a terminal
     * state on purpose (a stale resume must never fire after it), so starting a NEW loop with the
     * same controller instance needs an explicit reset rather than [kill] silently being
     * resumable.
     */
    fun reset() {
        state = State.Idle
    }
}
