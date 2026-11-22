package masoon.audio.playback

/** Playback controls and state supplied by the client’s media adapter. */
interface AudioTransport {
    /** Replaces the whole playlist. Synchronous — `mediaItemCount`/`currentItemIndex` reflect it immediately. */
    fun setItems(uris: List<String>)

    fun clearItems()

    fun play()

    fun pause()

    /** Pauses and empties the playlist; does not release the underlying player (see [release]). */
    fun stop()

    /** Releases the underlying player. The transport is unusable after this — a new one must be constructed. */
    fun release()

    fun seekToNextItem()

    fun seekTo(positionMs: Long)

    /** Playback rate. Setting is expected to be pre-clamped by the caller. */
    var speed: Float

    /**
     * Linear output volume, `0.0`..`1.0` — used to soften audio during a transient focus loss.
     */
    var volume: Float

    val currentItemIndex: Int

    val itemCount: Int

    val hasNextItem: Boolean

    val isPlaying: Boolean

    val currentPositionMs: Long

    /** `null` until the current item's duration has actually loaded — never estimated/interpolated. */
    val durationMs: Long?

    /** `null` unregisters. The transport holds one listener at a time. */
    fun setListener(listener: AudioTransportListener?)
}

/** Transport events include the media item index at the time of the event. */
interface AudioTransportListener {
    /** A new item became current (playlist advanced, whether by natural completion or an explicit seek). */
    fun onItemTransition(index: Int)

    /** The item at [index] failed to play (a decode/IO error reached the player). */
    fun onPlayerError(index: Int)
}
