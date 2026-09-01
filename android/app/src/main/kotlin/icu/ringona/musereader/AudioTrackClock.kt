package icu.ringona.musereader

import android.media.AudioTimestamp
import android.media.AudioTrack
import kotlin.math.max
import kotlin.math.roundToLong

/**
 * Converts an AudioTrack presentation position to the score time domain.
 *
 * The Flutter side must not use a wall clock as the authoritative position:
 * AudioTrack can have a sizeable queue (and AVDs can add another resampling
 * buffer), and a slow producer can temporarily underrun.  The timestamp is
 * the best available estimate of the frame currently presented by Android;
 * playbackHeadPosition is the fallback for routes that do not expose one.
 */
internal object AudioTrackClock {
    private const val NANOS_PER_SECOND = 1_000_000_000.0
    private const val MICROS_PER_SECOND = 1_000_000.0

    fun positionUs(
        audio: AudioTrack,
        basePositionUs: Long,
        speed: Double,
        sampleRate: Int,
        lastPositionUs: Long,
    ): Long {
        val safeRate = sampleRate.coerceAtLeast(1)
        val safeSpeed = if (speed.isFinite()) speed.coerceAtLeast(0.0) else 1.0
        val frames = presentedFrames(audio, safeRate)
        val elapsedUs = (frames.toDouble() * MICROS_PER_SECOND / safeRate * safeSpeed)
            .roundToLong()
        return max(lastPositionUs, basePositionUs + elapsedUs)
    }

    private fun presentedFrames(audio: AudioTrack, sampleRate: Int): Long {
        var head = 0L
        return try {
            head = audio.playbackHeadPosition.toLong() and 0xffffffffL

            // The producer fills the track while it is paused. A timestamp
            // returned during that phase must not be extrapolated with the
            // wall clock, or the prebuffer itself would look like progress.
            if (audio.playState != AudioTrack.PLAYSTATE_PLAYING) return head

            val timestamp = AudioTimestamp()
            if (!audio.getTimestamp(timestamp)) return head

            // AudioTimestamp.nanoTime is a presentation time, not the time at
            // which the app wrote the frame. Extrapolating it to now removes
            // the output queue's fixed delay. If the timestamp is in the
            // future (a committed-but-not-yet-presented frame), this naturally
            // yields a position behind the raw playback head.
            // AudioTimestamp.framePosition is a Long; unlike the legacy
            // playback-head Int it must not be truncated to 32 bits. A few
            // routes briefly report a negative value while reconfiguring.
            val timestampFrames = timestamp.framePosition.coerceAtLeast(0L)
            if (timestamp.nanoTime <= 0L) return head
            val deltaFrames = ((System.nanoTime() - timestamp.nanoTime).toDouble() /
                    NANOS_PER_SECOND * sampleRate).roundToLong()
            max(0L, timestampFrames + deltaFrames)
        } catch (_: RuntimeException) {
            // The worker can release the track between the snapshot and this
            // query. Keep the last usable frame count instead of surfacing an
            // exception through the Flutter method channel.
            head
        }
    }
}
