package masoon.audio.playback

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/** A fake [RepeatPauseClock] whose "now" only moves when a test explicitly advances it. */
private class FakeRepeatPauseClock(
    startingAt: Long = 0,
) : RepeatPauseClock {
    var current: Long = startingAt

    override fun nowMillis(): Long = current

    fun advance(byMillis: Long) {
        current += byMillis
    }
}

/** Ported from `apps/ios/Packages/Tests/MasoonAudioPlaybackTests/RepeatPauseControllerTests.swift`. */
class RepeatPauseControllerTest {
    // MARK: - repetitionPassEnded

    @Test
    fun `zero pause duration resumes immediately without entering paused state`() {
        val controller = RepeatPauseController(FakeRepeatPauseClock())
        assertEquals(RepeatPauseController.Action.ResumeNow, controller.repetitionPassEnded(0))
        assertEquals(RepeatPauseController.State.Idle, controller.state)
    }

    @Test
    fun `negative pause duration also resumes immediately`() {
        val controller = RepeatPauseController(FakeRepeatPauseClock())
        assertEquals(RepeatPauseController.Action.ResumeNow, controller.repetitionPassEnded(-5))
        assertEquals(RepeatPauseController.State.Idle, controller.state)
    }

    @Test
    fun `positive pause duration enters paused state and schedules resume at now plus duration`() {
        val clock = FakeRepeatPauseClock(startingAt = 100)
        val controller = RepeatPauseController(clock)
        val action = controller.repetitionPassEnded(15)
        assertEquals(RepeatPauseController.Action.PauseAndScheduleResume(115), action)
        assertEquals(RepeatPauseController.State.Paused(115), controller.state)
    }

    // MARK: - resumeTimerFired

    @Test
    fun `resume timer fired after duration elapsed resumes`() {
        val clock = FakeRepeatPauseClock(startingAt = 0)
        val controller = RepeatPauseController(clock)
        controller.repetitionPassEnded(10)
        clock.advance(10)
        assertEquals(RepeatPauseController.Action.Resume, controller.resumeTimerFired())
        assertEquals(RepeatPauseController.State.Idle, controller.state)
    }

    @Test
    fun `resume timer fired exactly at resume instant resumes`() {
        // `>=`, not `>` — a timer that fires at the precise instant must not be told to wait one more tick.
        val clock = FakeRepeatPauseClock(startingAt = 0)
        val controller = RepeatPauseController(clock)
        controller.repetitionPassEnded(10)
        clock.advance(10)
        assertEquals(RepeatPauseController.Action.Resume, controller.resumeTimerFired())
    }

    @Test
    fun `resume timer fired early does nothing and stays paused`() {
        // The load-bearing case: a coalesced/early timer must not resume playback before the
        // configured pause has actually elapsed.
        val clock = FakeRepeatPauseClock(startingAt = 0)
        val controller = RepeatPauseController(clock)
        controller.repetitionPassEnded(10)
        clock.advance(5)
        assertEquals(RepeatPauseController.Action.DoNothing, controller.resumeTimerFired())
        assertEquals(RepeatPauseController.State.Paused(10), controller.state)
    }

    @Test
    fun `resume timer fired while idle does nothing`() {
        val controller = RepeatPauseController(FakeRepeatPauseClock())
        assertEquals(RepeatPauseController.Action.DoNothing, controller.resumeTimerFired())
        assertEquals(RepeatPauseController.State.Idle, controller.state)
    }

    // MARK: - kill (the pause/resume/kill mid-loop scenario)

    @Test
    fun `kill while paused prevents a stale resume timer from ever resuming`() {
        val clock = FakeRepeatPauseClock(startingAt = 0)
        val controller = RepeatPauseController(clock)
        controller.repetitionPassEnded(10)

        assertEquals(RepeatPauseController.Action.DoNothing, controller.kill())
        assertEquals(RepeatPauseController.State.Killed, controller.state)

        // The timer that was already scheduled before the kill fires anyway — it must be a
        // no-op, never a resume.
        clock.advance(10)
        assertEquals(RepeatPauseController.Action.DoNothing, controller.resumeTimerFired())
        assertEquals(
            RepeatPauseController.State.Killed,
            controller.state,
            "a stale resume must never move a killed controller back to idle",
        )
    }

    @Test
    fun `kill is idempotent`() {
        val controller = RepeatPauseController(FakeRepeatPauseClock())
        assertEquals(RepeatPauseController.Action.DoNothing, controller.kill())
        assertEquals(RepeatPauseController.Action.DoNothing, controller.kill())
        assertEquals(RepeatPauseController.State.Killed, controller.state)
    }

    @Test
    fun `kill while idle still transitions to killed`() {
        val controller = RepeatPauseController(FakeRepeatPauseClock())
        assertEquals(RepeatPauseController.State.Idle, controller.state)
        controller.kill()
        assertEquals(RepeatPauseController.State.Killed, controller.state)
    }

    // MARK: - reset

    @Test
    fun `reset returns a killed controller to idle for reuse on a new loop`() {
        val controller = RepeatPauseController(FakeRepeatPauseClock())
        controller.kill()
        assertEquals(RepeatPauseController.State.Killed, controller.state)
        controller.reset()
        assertEquals(RepeatPauseController.State.Idle, controller.state)
    }

    @Test
    fun `reset from paused also returns to idle`() {
        val clock = FakeRepeatPauseClock(startingAt = 0)
        val controller = RepeatPauseController(clock)
        controller.repetitionPassEnded(10)
        controller.reset()
        assertEquals(RepeatPauseController.State.Idle, controller.state)
        // A resume timer fired after a reset must be a no-op — the paused state it was scheduled
        // for no longer exists.
        clock.advance(10)
        assertEquals(RepeatPauseController.Action.DoNothing, controller.resumeTimerFired())
    }

    // MARK: - a full pause/resume/kill-mid-loop sequence, end to end

    @Test
    fun `full sequence pause then resume then pause again then kill mid pause`() {
        val clock = FakeRepeatPauseClock(startingAt = 0)
        val controller = RepeatPauseController(clock)

        // Pass 1 ends: pause for 5ms.
        assertEquals(RepeatPauseController.Action.PauseAndScheduleResume(5), controller.repetitionPassEnded(5))
        clock.advance(5)
        assertEquals(RepeatPauseController.Action.Resume, controller.resumeTimerFired())

        // Pass 2 ends: pause for 5ms again, but this time killed before it elapses.
        assertEquals(RepeatPauseController.Action.PauseAndScheduleResume(10), controller.repetitionPassEnded(5))
        clock.advance(2)
        assertEquals(RepeatPauseController.Action.DoNothing, controller.kill())
        clock.advance(3)
        assertEquals(
            RepeatPauseController.Action.DoNothing,
            controller.resumeTimerFired(),
            "killed mid-pause: the scheduled resume must not fire",
        )
    }
}
