package icu.ringona.musereader

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Converts the PCM that `MediaCodec` hands back into the 16-bit samples our
 * `AudioTrack` is configured for.
 *
 * Deliberately free of Android imports: the arithmetic (byte order, offsets,
 * float clamping, frame counting) is the part of the in-process player that can
 * be tested on the JVM, and it is also the part most likely to be wrong.
 *
 * The two encodings are the `android.media.AudioFormat` values, repeated here
 * so this file stays loadable outside a device:
 * `ENCODING_PCM_16BIT = 2`, `ENCODING_PCM_FLOAT = 4`.
 */
internal object PcmConverter {
    const val ENCODING_PCM_16BIT = 2
    const val ENCODING_PCM_FLOAT = 4

    /** Bytes per sample for the encodings a decoder can produce. */
    fun bytesPerSample(encoding: Int): Int = when (encoding) {
        ENCODING_PCM_FLOAT -> 4
        else -> 2
    }

    /**
     * Copies [info]'s slice of [buffer] into [destination] as 16-bit samples.
     *
     * Returns the number of samples written. [destination] must be large
     * enough; callers size it from the codec's maximum output size.
     */
    fun toPcm16(
        buffer: ByteBuffer,
        offset: Int,
        size: Int,
        encoding: Int,
        destination: ShortArray,
    ): Int {
        if (size <= 0) return 0
        val source = buffer.duplicate().order(ByteOrder.nativeOrder())
        val samples = when (encoding) {
            ENCODING_PCM_FLOAT -> floatSamples(source, offset, size, destination)
            else -> shortSamples(source, offset, size, destination)
        }
        return samples
    }

    private fun shortSamples(
        source: ByteBuffer,
        offset: Int,
        size: Int,
        destination: ShortArray,
    ): Int {
        val count = (size / 2).coerceAtMost(destination.size)
        source.position(offset)
        val view = source.asShortBuffer()
        view.get(destination, 0, count)
        return count
    }

    private fun floatSamples(
        source: ByteBuffer,
        offset: Int,
        size: Int,
        destination: ShortArray,
    ): Int {
        val count = (size / 4).coerceAtMost(destination.size)
        source.position(offset)
        val view = source.asFloatBuffer()
        for (index in 0 until count) {
            val value = view.get(index)
            destination[index] = when {
                value.isNaN() -> 0
                value >= 1f -> Short.MAX_VALUE
                value <= -1f -> Short.MIN_VALUE
                else -> (value * Short.MAX_VALUE).roundToInt().toShort()
            }
        }
        return count
    }

    /** Frames contained in [samples] samples of a [channelCount]-channel stream. */
    fun framesFor(samples: Int, channelCount: Int): Int =
        samples / max(1, channelCount)
}
