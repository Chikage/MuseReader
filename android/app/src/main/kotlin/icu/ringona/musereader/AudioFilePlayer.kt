package icu.ringona.musereader

import android.content.Context
import android.util.Log

/**
 * The audio-file player the platform channel talks to.
 *
 * Backends:
 *
 *  * [MediaAudioPlayer] — `MediaPlayer`. The active backend: it pauses briefly
 *    when the system disturbs the audio and continues, which is the behaviour
 *    the reader expects today.
 *  * [DecodedAudioPlayer] — `MediaExtractor` + `MediaCodec` decoding into an
 *    `AudioTrack` we own. Implemented and unit tested, but not invoked while
 *    [USE_IN_PROCESS_DECODER] is false; see that constant for why.
 *
 * The channel contract is unchanged, so the Dart layer, its tests and the
 * reader page know nothing about the swap.
 */
class AudioFilePlayer(private val context: Context) {
    companion object {
        private const val TAG = "MuseReaderAudioFile"

        /**
         * Whether audio files are decoded in-process.
         *
         * **Off**: on the test device (NZONE S7, Android 12) opening a chat
         * window in QQ disturbs the audio output, and the in-process pipeline —
         * although it survives the disturbance better than MediaPlayer — reacts
         * to it in ways that are still being characterised. MediaPlayer is the
         * known-good path: it pauses briefly and continues.
         *
         * Flip this to true to route files through [DecodedAudioPlayer]; the
         * pipeline is complete, unit tested, and no longer reports a completion
         * unless the audio was actually presented.
         */
        private const val USE_IN_PROCESS_DECODER = false
    }

    private var decoded: DecodedAudioPlayer? = null
    private var fallback: MediaAudioPlayer? = null

    /**
     * Files the in-process pipeline refused. They keep using the MediaPlayer
     * path for the rest of the session instead of failing again on every play.
     */
    private val unsupported = HashSet<String>()

    /** Invoked when the current file plays to its end. */
    var onCompleted: (() -> Unit)? = null

    /** No audio focus is requested anywhere: see the class comment. */
    fun load(path: String, onResult: (Map<String, Any?>) -> Unit) {
        release()
        if (USE_IN_PROCESS_DECODER &&
            path !in unsupported &&
            DecodedAudioPlayer.isSupported(path)
        ) {
            val player = DecodedAudioPlayer()
            player.onCompleted = { onCompleted?.invoke() }
            decoded = player
            player.prepare(path) { result ->
                if (result["available"] == true) {
                    Log.i(TAG, "Playing $path in-process (no MediaPlayer session)")
                    onResult(result)
                } else {
                    // The extractor opened it but the decoder did not: remember
                    // that and take the MediaPlayer path instead.
                    Log.i(TAG, "In-process decoding failed for $path; using MediaPlayer")
                    unsupported += path
                    decoded = null
                    runCatching { player.stop() }
                    loadViaMediaPlayer(path, onResult)
                }
            }
            return
        }
        loadViaMediaPlayer(path, onResult)
    }

    private fun loadViaMediaPlayer(path: String, onResult: (Map<String, Any?>) -> Unit) {
        val player = MediaAudioPlayer(context)
        player.onCompleted = { onCompleted?.invoke() }
        fallback = player
        player.load(path, onResult)
    }

    fun play(): Boolean {
        decoded?.let { return it.play() }
        return fallback?.play() ?: false
    }

    fun pause() {
        decoded?.pause()
        fallback?.pause()
    }

    fun seekTo(positionMs: Int) {
        decoded?.seekTo(positionMs)
        fallback?.seekTo(positionMs)
    }

    fun positionMs(): Int? = decoded?.positionMs() ?: fallback?.positionMs()

    fun isPlaying(): Boolean = decoded?.isPlaying() ?: (fallback?.isPlaying() ?: false)

    /** Releases the current backend; a later load() picks one again. */
    fun stop() = release()

    private fun release() {
        decoded?.stop()
        decoded = null
        fallback?.stop()
        fallback = null
    }
}
