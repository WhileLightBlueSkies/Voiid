package com.voiid.app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.media.ExifInterface
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.voiid.app.main.ChatImageDecoder
import com.voiid.app.main.MediaCache
import com.voiid.app.main.loadMediaBitmap
import com.voiid.app.net.ChatEngine
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class ChatImageOrientationTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val colors = intArrayOf(Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW)
    private val corners = arrayOf(
        intArrayOf(0, 1, 2, 3), intArrayOf(1, 0, 3, 2),
        intArrayOf(3, 2, 1, 0), intArrayOf(2, 3, 0, 1),
        intArrayOf(0, 2, 1, 3), intArrayOf(2, 0, 3, 1),
        intArrayOf(3, 1, 2, 0), intArrayOf(1, 3, 0, 2),
    )

    private fun fixture(orientation: Int): ByteArray {
        val file = File.createTempFile("orientation-", ".jpg", context.cacheDir)
        val bitmap = Bitmap.createBitmap(80, 60, Bitmap.Config.ARGB_8888)
        return try {
            for (y in 0 until 60) for (x in 0 until 80) {
                bitmap.setPixel(x, y, colors[(if (y >= 30) 2 else 0) + (if (x >= 40) 1 else 0)])
            }
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 100, it) }
            ExifInterface(file.path).apply {
                setAttribute(ExifInterface.TAG_ORIENTATION, orientation.toString()); saveAttributes()
            }
            file.readBytes()
        } finally { bitmap.recycle(); file.delete() }
    }

    private fun assertOrientation(bitmap: Bitmap, orientation: Int) {
        assertEquals(if (orientation >= 5) 60 else 80, bitmap.width)
        assertEquals(if (orientation >= 5) 80 else 60, bitmap.height)
        val actual = intArrayOf(
            bitmap.getPixel(bitmap.width / 4, bitmap.height / 4),
            bitmap.getPixel(bitmap.width * 3 / 4, bitmap.height / 4),
            bitmap.getPixel(bitmap.width / 4, bitmap.height * 3 / 4),
            bitmap.getPixel(bitmap.width * 3 / 4, bitmap.height * 3 / 4),
        )
        actual.forEachIndexed { i, value ->
            val expected = colors[corners[orientation - 1][i]]
            for (shift in intArrayOf(0, 8, 16)) assertTrue("EXIF $orientation corner $i",
                kotlin.math.abs((value shr shift and 255) - (expected shr shift and 255)) < 25)
        }
    }

    @Test fun nativeDecoderRespectsAllEightOrientations() {
        for (orientation in 1..8) {
            val bitmap = requireNotNull(ChatImageDecoder.decode(fixture(orientation)))
            try { assertOrientation(bitmap, orientation) } finally { bitmap.recycle() }
        }
    }

    @Test fun androidSevenAndEightFallbackRespectsAllEightOrientations() {
        for (orientation in 1..8) {
            val bitmap = requireNotNull(ChatImageDecoder.decodeLegacy(fixture(orientation)))
            try { assertOrientation(bitmap, orientation) } finally { bitmap.recycle() }
        }
    }

    @Test fun cachedPhotoAndViewerResolveTheSameUprightPixels() = runBlocking {
        val key = "orientation-check-" + UUID.randomUUID()
        val bytes = fixture(6)
        // Prove this fixture catches the original BitmapFactory-only implementation.
        val raw = requireNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size))
        assertEquals(80, raw.width); raw.recycle()
        try {
            MediaCache.putData(context, key, bytes)
            val cached = requireNotNull(MediaCache.image(context, key))
            assertOrientation(cached.asAndroidBitmap(), 6)
            val viewer = requireNotNull(loadMediaBitmap(context,
                ChatEngine.MediaRef(key, "image/jpeg", "fixture", "fixture", "fixture")))
            assertSame(cached, viewer)
            assertOrientation(viewer.asAndroidBitmap(), 6)
        } finally { MediaCache.playbackFile(context, key).delete() }
    }
}
