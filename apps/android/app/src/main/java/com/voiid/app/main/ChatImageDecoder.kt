package com.voiid.app.main

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.Build
import java.io.ByteArrayInputStream
import java.io.File
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

    /** Bounded file decoding for Moments thumbnails and fullscreen media. */
    fun decodeFile(file: File, targetWidth: Int, targetHeight: Int): Bitmap? = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.setTargetSampleSize(sampleSize(info.size.width, info.size.height, targetWidth, targetHeight))
            }
        } else {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.path, bounds)
            val orientation = runCatching { ExifInterface(file.path).getAttributeInt(
                ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
            val swap = orientation in 5..8
            val options = BitmapFactory.Options().apply {
                inSampleSize = sampleSize(if (swap) bounds.outHeight else bounds.outWidth,
                    if (swap) bounds.outWidth else bounds.outHeight, targetWidth, targetHeight)
            }
            BitmapFactory.decodeFile(file.path, options)?.let { orient(it, orientation) }
        }
    }.getOrNull()

    private fun sampleSize(width: Int, height: Int, targetWidth: Int, targetHeight: Int): Int {
        if (targetWidth <= 0 || targetHeight <= 0) return 1
        var sample = 1
        while (width / (sample * 2) >= targetWidth || height / (sample * 2) >= targetHeight) sample *= 2
        return sample
    }

    /** Android 7/8 BitmapFactory ignores EXIF, so apply all eight orientations explicitly. */
    internal fun decodeLegacy(bytes: ByteArray): Bitmap? {
        val original = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
        val orientation = runCatching {
            ExifInterface(ByteArrayInputStream(bytes)).getAttributeInt(
                ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
        return orient(original, orientation)
    }

    private fun orient(original: Bitmap, orientation: Int): Bitmap {
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
