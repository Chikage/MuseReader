package com.musereader.muse_reader

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/** Small audible fallback for the reader while the MuseScore synth is optional. */
class SimpleScoreSynth {
    private val sampleRate = 44100
    private val lock = Any()
    private var track: AudioTrack? = null
    private var worker: Thread? = null
    private var generation = 0

    fun start(rawEvents: List<Any?>, positionUs: Long, speed: Double) {
        val events = rawEvents.mapNotNull { raw ->
            val map = raw as? Map<*, *> ?: return@mapNotNull null
            val start = (map["startUs"] as? Number)?.toDouble() ?: return@mapNotNull null
            val end = (map["endUs"] as? Number)?.toDouble() ?: return@mapNotNull null
            val pitch = (map["pitch"] as? Number)?.toInt() ?: 60
            val velocity = (map["velocity"] as? Number)?.toDouble() ?: 80.0
            ToneEvent(start, max(start + 1.0, end), pitch, velocity)
        }
        stop()
        if (events.isEmpty()) return

        val minBuffer = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        ).coerceAtLeast(2048)
        val audio = AudioTrack(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build(),
            AudioFormat.Builder()
                .setSampleRate(sampleRate)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build(),
            minBuffer * 2,
            AudioTrack.MODE_STREAM,
            AudioManager.AUDIO_SESSION_ID_GENERATE,
        )
        val localGeneration: Int
        synchronized(lock) {
            track = audio
            generation += 1
            localGeneration = generation
        }
        worker = Thread {
            val buffer = ShortArray(1024)
            var frame = 0L
            try {
                audio.play()
                while (isCurrent(localGeneration)) {
                    var hasSound = false
                    for (index in buffer.indices) {
                        val timeUs = positionUs +
                            (frame + index) * 1_000_000.0 / sampleRate * speed
                        val sample = sampleAt(events, timeUs)
                        buffer[index] = (sample * Short.MAX_VALUE).toInt()
                            .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                            .toShort()
                        if (sample != 0.0) hasSound = true
                    }
                    audio.write(buffer, 0, buffer.size)
                    frame += buffer.size
                    val lastEnd = events.maxOf { it.endUs }
                    if (positionUs +
                            frame * 1_000_000.0 / sampleRate * speed >= lastEnd &&
                        !hasSound
                    ) {
                        break
                    }
                }
            } finally {
                try {
                    audio.stop()
                } catch (_: IllegalStateException) {
                }
                audio.release()
                synchronized(lock) {
                    if (track === audio) track = null
                }
            }
        }.also {
            it.name = "MuseReaderAudio"
            it.start()
        }
    }

    fun stop() {
        synchronized(lock) {
            generation += 1
            try {
                track?.pause()
                track?.flush()
            } catch (_: IllegalStateException) {
            }
            track = null
        }
        worker?.interrupt()
        worker = null
    }

    private fun isCurrent(localGeneration: Int): Boolean = synchronized(lock) {
        generation == localGeneration && !Thread.currentThread().isInterrupted
    }

    private fun sampleAt(events: List<ToneEvent>, timeUs: Double): Double {
        var sum = 0.0
        var active = 0
        for (event in events) {
            if (timeUs < event.startUs || timeUs >= event.endUs) continue
            active += 1
            val elapsed = timeUs - event.startUs
            val duration = event.endUs - event.startUs
            val attack = min(1.0, elapsed / 12_000.0)
            val release = min(1.0, (duration - elapsed) / 35_000.0)
            val envelope = min(attack, release)
            val frequency = 440.0 * 2.0.pow((event.pitch - 69) / 12.0)
            sum += sin(2.0 * PI * frequency * elapsed / 1_000_000.0) *
                envelope * event.velocity / 127.0
        }
        return if (active == 0) {
            0.0
        } else {
            (sum / sqrt(active.toDouble()) * 0.22).coerceIn(-0.95, 0.95)
        }
    }

    private data class ToneEvent(
        val startUs: Double,
        val endUs: Double,
        val pitch: Int,
        val velocity: Double,
    )
}
