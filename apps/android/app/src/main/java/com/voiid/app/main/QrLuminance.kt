package com.voiid.app.main

import java.nio.ByteBuffer

/** ZXing needs packed rows; camera Y planes can contain row and pixel padding. */
internal fun packQrLuminance(buffer: ByteBuffer, width: Int, height: Int, rowStride: Int, pixelStride: Int): ByteArray {
    require(width > 0 && height > 0 && pixelStride > 0 && rowStride > 0)
    require((width - 1L) * pixelStride < rowStride)
    val start = buffer.position()
    val last = start + (height - 1L) * rowStride + (width - 1L) * pixelStride
    require(last < buffer.limit() && width.toLong() * height <= Int.MAX_VALUE)
    return ByteArray(width * height) { index ->
        buffer.get(start + (index / width) * rowStride + (index % width) * pixelStride)
    }
}
