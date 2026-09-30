package icu.ringona.musereader

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The arithmetic of the in-process decoder: what `MediaCodec` hands back has to
 * become the 16-bit samples our AudioTrack expects, at the right offset and
 * with the right frame count. Everything else in that player needs a device;
 * this part does not.
 */
class PcmConverterTest {
    private fun buffer(size: Int): ByteBuffer =
        ByteBuffer.allocate(size).order(ByteOrder.nativeOrder())

    @Test
    fun sixteenBitSamplesAreCopiedHonouringOffsetAndSize() {
        val source = buffer(32)
        source.putShort(0, 7)
        source.putShort(2, 7)
        source.putShort(4, 1)
        source.putShort(6, 2)
        source.putShort(8, 3)
        val destination = ShortArray(8) { -1 }

        val samples = PcmConverter.toPcm16(
            buffer = source,
            offset = 4,
            size = 6,
            encoding = PcmConverter.ENCODING_PCM_16BIT,
            destination = destination,
        )

        assertEquals(3, samples)
        assertEquals(1, destination[0].toInt())
        assertEquals(2, destination[1].toInt())
        assertEquals(3, destination[2].toInt())
        assertEquals("untouched past the decoded samples", -1, destination[3].toInt())
    }

    @Test
    fun floatSamplesAreConvertedAndClamped() {
        val source = buffer(32)
        source.asFloatBuffer().put(floatArrayOf(0f, 0.5f, -0.5f, 2f, -3f, Float.NaN))
        val destination = ShortArray(6)

        val samples = PcmConverter.toPcm16(
            buffer = source,
            offset = 0,
            size = 24,
            encoding = PcmConverter.ENCODING_PCM_FLOAT,
            destination = destination,
        )

        assertEquals(6, samples)
        assertEquals(0, destination[0].toInt())
        assertEquals((0.5f * Short.MAX_VALUE).roundToInt(), destination[1].toInt())
        assertEquals((-0.5f * Short.MAX_VALUE).roundToInt(), destination[2].toInt())
        assertEquals("above full scale clamps", Short.MAX_VALUE.toInt(), destination[3].toInt())
        assertEquals("below full scale clamps", Short.MIN_VALUE.toInt(), destination[4].toInt())
        assertEquals("NaN becomes silence", 0, destination[5].toInt())
    }

    @Test
    fun theDestinationStopsTheCopyInsteadOfOverrunning() {
        val source = buffer(32)
        for (index in 0 until 8) source.putShort(index * 2, index.toShort())
        val destination = ShortArray(3)

        val samples = PcmConverter.toPcm16(source, 0, 16, PcmConverter.ENCODING_PCM_16BIT, destination)

        assertEquals(3, samples)
        assertEquals(2, destination[2].toInt())
    }

    @Test
    fun anEmptySliceDecodesToNothing() {
        val source = buffer(8)
        val destination = ShortArray(4)

        assertEquals(0, PcmConverter.toPcm16(source, 0, 0, PcmConverter.ENCODING_PCM_16BIT, destination))
        assertEquals(0, PcmConverter.toPcm16(source, 0, -4, PcmConverter.ENCODING_PCM_16BIT, destination))
    }

    @Test
    fun framesComeFromTheChannelCount() {
        assertEquals(512, PcmConverter.framesFor(samples = 1024, channelCount = 2))
        assertEquals(1024, PcmConverter.framesFor(samples = 1024, channelCount = 1))
        assertEquals("a zero channel count must not divide by zero", 1024, PcmConverter.framesFor(1024, 0))
    }

    @Test
    fun encodingsReportTheirSampleSize() {
        assertEquals(2, PcmConverter.bytesPerSample(PcmConverter.ENCODING_PCM_16BIT))
        assertEquals(4, PcmConverter.bytesPerSample(PcmConverter.ENCODING_PCM_FLOAT))
    }
}
