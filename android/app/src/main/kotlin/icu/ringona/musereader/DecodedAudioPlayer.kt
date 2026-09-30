package icu.ringona.musereader

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.File

/**
 * Plays an audio file **inside the app process**: `MediaExtractor` demuxes,
 * `MediaCodec` decodes, and we write the PCM into our own [AudioTrack].
 *
 * This is the same shape as the score path (FluidSynth rendering into an
 * AudioTrack we own) and it exists for the same reason: an in-process pipeline
 * has no `MediaPlayer` session for the system — or a chat app that behaves like
 * one — to park, and nothing about it is negotiable through audio focus. If the
 * decoder or the audio track is disturbed, the state we need to carry on is
 * still in this process, so recovery costs milliseconds instead of the audible
 * gap a rebuilt `MediaPlayer` needs.
 *
 * [MediaAudioPlayer] stays in the project as the fallback for files this
 * pipeline cannot open (typically wma/aiff), and is used automatically by
 * [AudioFilePlayer].
 */
class DecodedAudioPlayer {
    companion object {
        private const val TAG = "MuseReaderDecoded"
        private const val DEQUEUE_TIMEOUT_US = 10_000L

        /**
         * How close to the file's end the *presented* position has to be before
         * end-of-stream may be reported as "the piece finished". Without this a
         * dead output (the system taking the audio away) made the decoder race
         * through the whole file unplayed and then announce a completion, which
         * advanced the reader's queue — the piece appeared to be skipped.
         */
        private const val END_TOLERANCE_US = 250_000L

        /** Consecutive failed writes that mean the output is gone, not busy. */
        private const val MAX_WRITE_FAILURES = 3

        /**
         * Whether an in-process pipeline can handle [path]: the extractor must
         * open it, expose an audio track, and a decoder must exist for its MIME
         * type. A false answer sends the file to the MediaPlayer fallback.
         */
        fun isSupported(path: String): Boolean {
            var extractor: MediaExtractor? = null
            var codec: MediaCodec? = null
            return try {
                if (!File(path).isFile) return false
                extractor = MediaExtractor()
                extractor.setDataSource(path)
                val format = audioTrackFormat(extractor) ?: return false
                val mime = format.getString(MediaFormat.KEY_MIME) ?: return false
                codec = MediaCodec.createDecoderByType(mime)
                true
            } catch (error: Throwable) {
                Log.i(TAG, "In-process decoding unavailable for $path: ${error.message}")
                false
            } finally {
                runCatching { codec?.release() }
                runCatching { extractor?.release() }
            }
        }

        private fun audioTrackFormat(extractor: MediaExtractor): MediaFormat? {
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    extractor.selectTrack(index)
                    return format
                }
            }
            return null
        }
    }

    var onCompleted: (() -> Unit)? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val gate = Object()

    private var extractor: MediaExtractor? = null
    private var codec: MediaCodec? = null
    private var audio: AudioTrack? = null
    private var worker: Thread? = null

    private var generation = 0

    @Volatile
    private var running = false

    @Volatile
    private var started = false

    @Volatile
    private var paused = false

    @Volatile
    private var ended = false

    @Volatile
    private var failure: String? = null

    @Volatile
    private var pendingSeekUs = -1L

    @Volatile
    private var sampleRate = 44_100

    @Volatile
    private var channelCount = 2

    @Volatile
    private var durationUs = 0L

    @Volatile
    private var basePositionUs = 0L

    @Volatile
    private var writtenFrames = 0L

    @Volatile
    private var lastPositionUs = 0L

    /**
     * Prepares the pipeline and reports `available`, `durationMs` and an
     * `error` when the file cannot be decoded in-process. The work happens on a
     * worker thread; the reply arrives on the main thread.
     */
    fun prepare(path: String, onResult: (Map<String, Any?>) -> Unit) {
        release()
        val localGeneration = ++generation
        val thread = Thread({ prepareOnWorker(path, localGeneration, onResult) }, "muse-decoded-prepare")
        thread.isDaemon = true
        thread.start()
    }

    private fun prepareOnWorker(
        path: String,
        localGeneration: Int,
        onResult: (Map<String, Any?>) -> Unit,
    ) {
        fun reply(payload: Map<String, Any?>) {
            mainHandler.post {
                if (generation == localGeneration) onResult(payload)
            }
        }
        try {
            if (!File(path).isFile) {
                reply(mapOf("available" to false, "error" to "音频文件不存在"))
                return
            }
            val newExtractor = MediaExtractor()
            newExtractor.setDataSource(path)
            val format = audioTrackFormat(newExtractor)
            if (format == null) {
                newExtractor.release()
                reply(mapOf("available" to false, "error" to "无法解码该音频文件（没有音频轨道）"))
                return
            }
            val mime = format.getString(MediaFormat.KEY_MIME) ?: "audio/unknown"
            val rate = format.intOr(MediaFormat.KEY_SAMPLE_RATE, 44_100)
            val channels = format.intOr(MediaFormat.KEY_CHANNEL_COUNT, 2)
            val duration = format.longOr(MediaFormat.KEY_DURATION, 0L)
            val newCodec = MediaCodec.createDecoderByType(mime)
            newCodec.configure(format, null, null, 0)
            newCodec.start()
            val newAudio = createAudioTrack(rate, channels)
            if (newAudio == null) {
                newCodec.release()
                newExtractor.release()
                reply(mapOf("available" to false, "error" to "无法创建音频输出"))
                return
            }
            extractor = newExtractor
            codec = newCodec
            audio = newAudio
            sampleRate = rate
            channelCount = channels
            durationUs = duration
            basePositionUs = 0L
            writtenFrames = 0L
            lastPositionUs = 0L
            pendingSeekUs = -1L
            ended = false
            failure = null
            paused = true
            started = false
            reply(
                mapOf(
                    "available" to true,
                    "durationMs" to (duration / 1000L),
                    "backend" to "decoded",
                ),
            )
        } catch (error: Throwable) {
            Log.w(TAG, "Unable to prepare $path in-process", error)
            reply(
                mapOf(
                    "available" to false,
                    "error" to (error.message ?: "无法解码该音频文件"),
                ),
            )
        }
    }

    private fun createAudioTrack(rate: Int, channels: Int): AudioTrack? {
        val channelMask = if (channels > 1) {
            AudioFormat.CHANNEL_OUT_STEREO
        } else {
            AudioFormat.CHANNEL_OUT_MONO
        }
        val minBuffer = AudioTrack.getMinBufferSize(
            rate,
            channelMask,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val bufferSize = if (minBuffer > 0) minBuffer * 2 else rate
        return try {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(rate)
                        .setChannelMask(channelMask)
                        .build(),
                )
                .setBufferSizeInBytes(bufferSize)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
                .also { track ->
                    if (track.state != AudioTrack.STATE_INITIALIZED) {
                        runCatching { track.release() }
                        return null
                    }
                }
        } catch (error: Throwable) {
            Log.w(TAG, "Unable to create the audio track", error)
            null
        }
    }

    fun play(): Boolean {
        val track = audio ?: return false
        if (failure != null || ended) return false
        synchronized(gate) {
            if (ended) return false
            started = true
            paused = false
            runCatching { track.play() }
            startWorkerIfNeeded()
        }
        return true
    }

    fun pause() {
        synchronized(gate) {
            paused = true
            started = false
            runCatching { audio?.pause() }
        }
    }

    fun seekTo(positionMs: Int) {
        synchronized(gate) {
            pendingSeekUs = positionMs.coerceAtLeast(0).toLong() * 1000L
            ended = false
            gate.notifyAll()
        }
    }

    /** Position currently presented by the audio track, in microseconds. */
    fun positionUs(): Long {
        val track = audio ?: return basePositionUs
        val position = AudioTrackClock.positionUs(
            audio = track,
            basePositionUs = basePositionUs,
            speed = 1.0,
            sampleRate = sampleRate,
            writtenFrames = writtenFrames,
            lastPositionUs = lastPositionUs,
        )
        if (started && !paused) lastPositionUs = position
        return position
    }

    fun positionMs(): Int? = (positionUs() / 1000L).toInt()

    fun isPlaying(): Boolean = started && !paused && !ended && failure == null

    /** Duration learned at prepare time, in microseconds. */
    fun durationUs(): Long = durationUs

    fun stop() = release()

    private fun startWorkerIfNeeded() {
        if (worker != null) return
        val localExtractor = extractor ?: return
        val localCodec = codec ?: return
        val localAudio = audio ?: return
        val localGeneration = generation
        running = true
        val thread = Thread(
            { decodeLoop(localGeneration, localExtractor, localCodec, localAudio) },
            "muse-decoded-playback",
        )
        thread.isDaemon = true
        worker = thread
        thread.start()
    }

    private fun decodeLoop(
        localGeneration: Int,
        localExtractor: MediaExtractor,
        localCodec: MediaCodec,
        localAudio: AudioTrack,
    ) {
        val info = MediaCodec.BufferInfo()
        var sawInputEos = false
        var sawOutputEos = false
        var dropBeforeUs = -1L
        var pcm = ShortArray(0)
        var writeFailures = 0
        try {
            while (running && generation == localGeneration && !sawOutputEos) {
                if (!awaitWork()) break
                val seekUs = pendingSeekUs
                if (seekUs >= 0) {
                    pendingSeekUs = -1L
                    dropBeforeUs = applySeek(localExtractor, localCodec, localAudio, seekUs)
                    sawInputEos = false
                    sawOutputEos = false
                }
                if (!sawInputEos) {
                    val inputIndex = localCodec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                    if (inputIndex >= 0) {
                        val buffer = localCodec.getInputBuffer(inputIndex)
                        val size = if (buffer == null) -1 else {
                            buffer.clear()
                            localExtractor.readSampleData(buffer, 0)
                        }
                        if (size < 0) {
                            localCodec.queueInputBuffer(
                                inputIndex,
                                0,
                                0,
                                0L,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            sawInputEos = true
                        } else {
                            localCodec.queueInputBuffer(
                                inputIndex,
                                0,
                                size,
                                localExtractor.sampleTime.coerceAtLeast(0L),
                                0,
                            )
                            localExtractor.advance()
                        }
                    }
                }
                val outputIndex = localCodec.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
                when {
                    outputIndex >= 0 -> {
                        val buffer = localCodec.getOutputBuffer(outputIndex)
                        val atEnd = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        if (buffer != null && info.size > 0) {
                            val skip = dropBeforeUs >= 0 && info.presentationTimeUs < dropBeforeUs
                            if (!skip) {
                                dropBeforeUs = -1L
                                val needed = info.size / PcmConverter.bytesPerSample(encoding())
                                if (pcm.size < needed) pcm = ShortArray(needed)
                                val samples = PcmConverter.toPcm16(
                                    buffer = buffer,
                                    offset = info.offset,
                                    size = info.size,
                                    encoding = encoding(),
                                    destination = pcm,
                                )
                                if (writeSamples(localAudio, pcm, samples, localGeneration)) {
                                    writeFailures = 0
                                } else {
                                    writeFailures += 1
                                    if (writeFailures >= MAX_WRITE_FAILURES) {
                                        throw IllegalStateException(
                                            "音频输出已失效（连续 $writeFailures 次写入失败）",
                                        )
                                    }
                                }
                            }
                        }
                        localCodec.releaseOutputBuffer(outputIndex, false)
                        if (atEnd) sawOutputEos = true
                    }
                    outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val format = localCodec.outputFormat
                        val rate = format.intOr(MediaFormat.KEY_SAMPLE_RATE, sampleRate)
                        val channels = format.intOr(MediaFormat.KEY_CHANNEL_COUNT, channelCount)
                        if (rate != sampleRate || channels != channelCount) {
                            Log.i(TAG, "Decoded format changed to $rate Hz / $channels ch")
                            sampleRate = rate
                            channelCount = channels
                            recreateAudioTrack(rate, channels)
                        }
                    }
                }
            }
            if (running && generation == localGeneration && sawOutputEos) {
                waitForDrain(localAudio, localGeneration)
                // End of stream only means the *file* was read. The piece
                // finished only if the audio was also presented to the end;
                // otherwise the output died and this is a failure to recover
                // from, never a completion that may advance the queue.
                val presented = positionUs()
                val playedToEnd = durationUs <= 0L ||
                    presented >= durationUs - END_TOLERANCE_US
                if (!playedToEnd) {
                    throw IllegalStateException(
                        "音频输出中断（播放到 ${presented / 1000} ms，共 ${durationUs / 1000} ms）",
                    )
                }
                if (running && generation == localGeneration) {
                    synchronized(gate) {
                        ended = true
                        started = false
                        paused = true
                        lastPositionUs = durationUs
                    }
                    mainHandler.post {
                        if (generation == localGeneration) onCompleted?.invoke()
                    }
                }
            }
        } catch (error: Throwable) {
            if (generation == localGeneration) {
                Log.w(TAG, "In-process playback stopped", error)
                failure = error.message ?: "播放失败"
                synchronized(gate) {
                    started = false
                    paused = true
                }
            }
        }
    }

    /** Waits while playback is paused or stopped; false means "leave the loop". */
    private fun awaitWork(): Boolean {
        synchronized(gate) {
            while (running && generation == this.generation &&
                (!started || paused) && pendingSeekUs < 0
            ) {
                gate.wait(200L)
            }
            return running && generation == this.generation
        }
    }

    private fun applySeek(
        localExtractor: MediaExtractor,
        localCodec: MediaCodec,
        localAudio: AudioTrack,
        seekUs: Long,
    ): Long {
        val target = when {
            durationUs > 0 && seekUs > durationUs -> durationUs
            seekUs < 0 -> 0L
            else -> seekUs
        }
        localExtractor.seekTo(target, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
        localCodec.flush()
        runCatching { localAudio.pause() }
        runCatching { localAudio.flush() }
        basePositionUs = target
        writtenFrames = 0L
        lastPositionUs = target
        ended = false
        if (started && !paused) runCatching { localAudio.play() }
        return target
    }

    private fun writeSamples(
        localAudio: AudioTrack,
        samples: ShortArray,
        count: Int,
        localGeneration: Int,
    ): Boolean {
        if (count <= 0) return true
        if (!started || paused) return false
        var offset = 0
        while (offset < count && running && generation == localGeneration) {
            if (!started || paused) return false
            val written = localAudio.write(samples, offset, count - offset, AudioTrack.WRITE_BLOCKING)
            if (written <= 0) return false
            offset += written
            writtenFrames += PcmConverter.framesFor(written, channelCount).toLong()
        }
        return true
    }

    /** Lets the queued audio finish before the piece is reported as ended. */
    private fun waitForDrain(localAudio: AudioTrack, localGeneration: Int) {
        val deadline = System.currentTimeMillis() + 10_000L
        while (running && generation == localGeneration) {
            val played = runCatching {
                localAudio.playbackHeadPosition.toLong() and 0xffffffffL
            }.getOrDefault(writtenFrames)
            if (played >= writtenFrames) break
            if (System.currentTimeMillis() > deadline) break
            Thread.sleep(20L)
        }
    }

    private fun recreateAudioTrack(rate: Int, channels: Int) {
        val replacement = createAudioTrack(rate, channels) ?: return
        val previous = audio
        audio = replacement
        runCatching { previous?.release() }
        if (started && !paused) runCatching { replacement.play() }
    }

    /** The codec's output encoding, as `AudioFormat` reports it. */
    private fun encoding(): Int =
        runCatching { codec?.outputFormat?.intOr(MediaFormat.KEY_PCM_ENCODING, 2) ?: 2 }
            .getOrDefault(2)

    private fun release() {
        running = false
        synchronized(gate) { gate.notifyAll() }
        val thread = worker
        worker = null
        if (thread != null) runCatching { thread.join(1500L) }
        extractor?.let { runCatching { it.release() } }
        codec?.let { runCatching { it.stop() }; runCatching { it.release() } }
        audio?.let {
            runCatching { it.pause() }
            runCatching { it.flush() }
            runCatching { it.release() }
        }
        extractor = null
        codec = null
        audio = null
        started = false
        paused = true
        ended = false
        pendingSeekUs = -1L
    }

    private fun MediaFormat.intOr(key: String, fallback: Int): Int =
        if (containsKey(key)) runCatching { getInteger(key) }.getOrDefault(fallback) else fallback

    private fun MediaFormat.longOr(key: String, fallback: Long): Long =
        if (containsKey(key)) runCatching { getLong(key) }.getOrDefault(fallback) else fallback
}
