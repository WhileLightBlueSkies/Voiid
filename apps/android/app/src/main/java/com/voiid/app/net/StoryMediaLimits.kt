package com.voiid.app.net

import java.io.ByteArrayOutputStream
import java.io.InputStream

internal object StoryMediaLimits {
    const val MAX_SOURCE_BYTES = 50 * 1024 * 1024
    const val MAX_CIPHERTEXT_BYTES = MAX_SOURCE_BYTES + 1024

    /** Enforce the actual stream size, even when a provider omits or lies about its length. */
    fun readBounded(input: InputStream, limit: Int): ByteArray {
        require(limit >= 0)
        val output = ByteArrayOutputStream(minOf(limit, 64 * 1024))
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val count = input.read(buffer, 0, minOf(buffer.size.toLong(), limit.toLong() - output.size() + 1).toInt())
            if (count < 0) return output.toByteArray()
            require(count <= limit - output.size()) { "This Moment is too large (max 50 MB)." }
            output.write(buffer, 0, count)
        }
    }
}
