package icu.ringona.musereader

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.max

/** Streams the bundled MuseScore FluidSynth renderer into Android's audio sink. */
class FluidScoreSynth {
    companion object {
        private const val TAG = "MuseReaderFluid"
        private const val FRAMES_PER_BLOCK = 1024
    }

    private val lock = Any()
    private var track: AudioTrack? = null
    private var worker: Thread? = null
    private var generation = 0

    /** Starts native playback, returning false when the embedded renderer is unavailable. */
    fun start(rawEvents: List<Any?>, positionUs: Long, speed: Double): Boolean {
        stop()
        val eventsJson = encodeEvents(rawEvents)
        if (eventsJson == "[]") return false
        if (!NativeMuseScoreEngine.audioIsAvailable()) return false
        if (!NativeMuseScoreEngine.audioStartJson(eventsJson, positionUs, speed)) {
            return false
        }

        val sampleRate = NativeMuseScoreEngine.audioSampleRate()
        val minBuffer = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_16BIT,
        ).let { if (it > 0) it else sampleRate / 10 * 4 }
        val bufferBytes = max(minBuffer * 2, FRAMES_PER_BLOCK * 4)
        val audio = try {
            AudioTrack(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
                AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build(),
                bufferBytes,
                AudioTrack.MODE_STREAM,
                AudioManager.AUDIO_SESSION_ID_GENERATE,
            )
        } catch (error: Throwable) {
            NativeMuseScoreEngine.audioStop()
            Log.w(TAG, "Unable to create AudioTrack", error)
            return false
        }
        if (audio.state != AudioTrack.STATE_INITIALIZED) {
            audio.release()
            NativeMuseScoreEngine.audioStop()
            Log.w(TAG, "AudioTrack was not initialized")
            return false
        }

        val localGeneration: Int
        synchronized(lock) {
            generation += 1
            localGeneration = generation
            track = audio
        }
        val thread = Thread {
            runAudio(audio, localGeneration)
        }.also {
            it.name = "MuseReaderFluidAudio"
        }
        synchronized(lock) {
            if (generation == localGeneration) worker = thread
        }
        thread.start()
        return true
    }

    fun stop() {
        val oldTrack: AudioTrack?
        val oldWorker: Thread?
        synchronized(lock) {
            generation += 1
            oldTrack = track
            oldWorker = worker
            track = null
            worker = null
        }
        NativeMuseScoreEngine.audioStop()
        try {
            oldTrack?.pause()
            oldTrack?.stop()
            oldTrack?.flush()
        } catch (_: IllegalStateException) {
        }
        oldWorker?.interrupt()
        if (oldWorker != null && oldWorker !== Thread.currentThread()) {
            try {
                oldWorker.join(250)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
    }

    private fun runAudio(audio: AudioTrack, localGeneration: Int) {
        val floatBuffer = FloatArray(FRAMES_PER_BLOCK * 2)
        val shortBuffer = ShortArray(FRAMES_PER_BLOCK * 2)
        try {
            audio.play()
            while (isCurrent(localGeneration)) {
                val frames = NativeMuseScoreEngine.audioRender(floatBuffer)
                if (frames <= 0) {
                    if (!NativeMuseScoreEngine.audioIsActive()) break
                    Thread.yield()
                    continue
                }
                val sampleCount = (frames * 2).coerceAtMost(floatBuffer.size)
                for (index in 0 until sampleCount) {
                    val sample = (floatBuffer[index] * Short.MAX_VALUE)
                        .toInt()
                        .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                    shortBuffer[index] = sample.toShort()
                }
                var offset = 0
                while (offset < sampleCount && isCurrent(localGeneration)) {
                    val written = audio.write(shortBuffer, offset, sampleCount - offset)
                    if (written <= 0) break
                    offset += written
                }
                if (offset < sampleCount && isCurrent(localGeneration)) break
            }
        } catch (error: Throwable) {
            if (isCurrent(localGeneration)) Log.w(TAG, "FluidSynth audio stream stopped", error)
        } finally {
            if (isCurrent(localGeneration)) {
                NativeMuseScoreEngine.audioStop()
            }
            try {
                audio.stop()
            } catch (_: IllegalStateException) {
            }
            audio.release()
            synchronized(lock) {
                if (track === audio) {
                    track = null
                    if (generation == localGeneration) worker = null
                }
            }
        }
    }

    private fun isCurrent(localGeneration: Int): Boolean = synchronized(lock) {
        generation == localGeneration && !Thread.currentThread().isInterrupted
    }

    private fun encodeEvents(rawEvents: List<Any?>): String {
        val array = JSONArray()
        for (raw in rawEvents) {
            val map = raw as? Map<*, *> ?: continue
            val jsonObject = JSONObject()
            for ((key, value) in map) {
                if (key is String) jsonObject.put(key, jsonValue(value))
            }
            array.put(jsonObject)
        }
        return array.toString()
    }

    private fun jsonValue(value: Any?): Any = when (value) {
        null -> JSONObject.NULL
        is Map<*, *> -> JSONObject().apply {
            for ((key, child) in value) {
                if (key is String) put(key, jsonValue(child))
            }
        }
        is Iterable<*> -> JSONArray().apply {
            for (child in value) put(jsonValue(child))
        }
        is Array<*> -> JSONArray().apply {
            for (child in value) put(jsonValue(child))
        }
        is Number, is Boolean, is String, is JSONObject, is JSONArray -> value
        else -> value.toString()
    }
}
