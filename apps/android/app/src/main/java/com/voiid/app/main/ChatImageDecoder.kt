package com.voiid.app.main

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.Build
import java.io.ByteArrayInputStream
import java.nio.ByteBuffer

/** Decode the displayed orientation, including mirrored photos, before caching pixels. */
internal object ChatImageDecoder {
    fun decode(bytes: ByteArray): Bitmap? = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            // Native decoding handles JPEG EXIF and HEIF orientation exactly once.
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) { decoder, _, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        } else decodeLegacy(bytes)
    }.getOrNull()

    /** Android 7/8 BitmapFactory ignores EXIF, so apply all eight orientations explicitly. */
    internal fun decodeLegacy(bytes: ByteArray): Bitmap? {
        val original = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
        val orientation = runCatching {
            ExifInterface(ByteArrayInputStream(bytes)).getAttributeInt(
                ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
        val transform = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> transform.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> transform.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> transform.setScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { transform.setRotate(90f); transform.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_ROTATE_90 -> transform.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> { transform.setRotate(90f); transform.postScale(1f, -1f) }
            ExifInterface.ORIENTATION_ROTATE_270 -> transform.setRotate(270f)
            else -> return original
        }
        return try {
            Bitmap.createBitmap(original, 0, 0, original.width, original.height, transform, true)
                .also { if (it !== original) original.recycle() }
        } catch (e: Exception) { original.recycle(); throw e }
    }
}
