package com.voiid.app

import com.voiid.app.main.packQrLuminance
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test

class QrLuminanceTest {
    @Test fun paddedRowsAndShortLastRow() {
        val input = ByteBuffer.wrap(byteArrayOf(1,2,3,99,99,4,5,6))
        assertArrayEquals(byteArrayOf(1,2,3,4,5,6), packQrLuminance(input, 3,2,5,1))
        assertEquals(0,input.position())
    }
    @Test fun pixelStrideAndBufferOffset() {
        val input = ByteBuffer.wrap(byteArrayOf(99,1,99,2,99,3,99,4))
        input.position(1)
        assertArrayEquals(byteArrayOf(1,2,3,4), packQrLuminance(input,2,2,4,2))
        assertEquals(1,input.position())
    }
    @Test fun packedFrame() {
        val bytes = byteArrayOf(1,2,3,4,5,6)
        assertArrayEquals(bytes, packQrLuminance(ByteBuffer.wrap(bytes),3,2,3,1))
    }
    @Test(expected = IllegalArgumentException::class) fun truncatedPlaneRejected() {
        packQrLuminance(ByteBuffer.wrap(byteArrayOf(1,2,3)),2,2,2,1)
    }
    @Test(expected = IllegalArgumentException::class) fun overlappingRowsRejected() {
        packQrLuminance(ByteBuffer.allocate(32),4,2,3,1)
    }
}
