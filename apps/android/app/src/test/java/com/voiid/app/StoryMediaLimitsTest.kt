package com.voiid.app

import com.voiid.app.net.StoryMediaLimits
import org.junit.Assert.*
import org.junit.Test

class StoryMediaLimitsTest {
    @Test fun acceptsEmptyAndExactLimitStreams() {
        assertArrayEquals(byteArrayOf(), StoryMediaLimits.readBounded(byteArrayOf().inputStream(), 0))
        val bytes = ByteArray(70_000) { (it % 251).toByte() }
        assertArrayEquals(bytes, StoryMediaLimits.readBounded(bytes.inputStream(), bytes.size))
    }
    @Test(expected = IllegalArgumentException::class)
    fun rejectsTheFirstByteBeyondTheLimit() {
        StoryMediaLimits.readBounded(ByteArray(70_001).inputStream(), 70_000)
    }
}
