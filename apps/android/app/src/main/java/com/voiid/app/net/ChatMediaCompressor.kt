package com.voiid.app.net

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import com.google.common.collect.ImmutableList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.OutputStream
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/*
 * The 25 MB chat limit, and the on-device compressor that makes a bigger file fit.
 * Port of iOS Networking/ChatMediaCompressor.swift; the screens are main/ChatAttachSheets.kt.
 *
 * ONE LIMIT FOR EVERYTHING. Anything sent in a chat — photo, video, document — is at most
 * 25 MB. Over it, the file is not refused: it is compressed HERE, on the phone, before it is
 * encrypted. Voiid never sees the file, compressed or not. The server enforces the same limit
 * on the upload (routes/media.ts, CHAT_MEDIA_MAX_PLAINTEXT).
 *
 * WHAT SHRINKS, AND HOW
 *  • Photos: re-encoded as JPEG, quietly — there is no visible trade-off to ask about.
 *  • Video: re-encoded to a bitrate computed from the length, so the result lands under the
 *    limit by design, and retried once lower if it does not. H.264, which every phone plays.
 *  • PDF: pages re-drawn as JPEG images. Text stops being selectable — the sheet says so.
 *  • Anything else (zip, docx…) is already compressed. The sheet says it cannot be made
 *    smaller rather than promising a size it cannot reach.
 */

object ChatMediaLimit {
    /** Decimal megabytes, as file managers show sizes. */
    const val BYTES: Long = 25_000_000

    fun text(b: Long): String {
        val mb = b / 1_000_000.0
        return when {
            mb >= 100 -> "%.0f MB".format(mb)
            mb >= 1 -> "%.1f MB".format(mb).replace(".0 MB", " MB")
            else -> "%.0f KB".format(max(1.0, b / 1000.0))
        }
    }
}

/** A picked file that is over the limit. [file] is our own copy in the cache, or null. */
data class ChatOversizeFile(
    val id: String = UUID.randomUUID().toString(),
    val file: File?,
    val name: String,
    val bytes: Long,
    val kind: Kind,
) {
    sealed interface Kind {
        data class Video(val seconds: Double) : Kind
        data class Pdf(val pages: Int) : Kind
        /** Nothing useful can be done to it. */
        data object Other : Kind
    }
}

/** A way to make a video fit, and what it is expected to come out at. */
data class ChatVideoPlan(
    val id: String,
    val title: String,
    val note: String,
    val longEdge: Int,
    val videoBitrate: Int,
    val audioBitrate: Int,
    val seconds: Double,
) {
    val estimatedBytes: Long get() = ((videoBitrate + audioBitrate) * seconds / 8 * 1.02).toLong()
}

object ChatVideoPlanner {
    /** Aim under the limit: the container, keyframes and rate control all add a little. */
    private val budgetBits = ChatMediaLimit.BYTES * 8 * 0.92
    /** Media3 1.4 has no audio-bitrate setting, so budget for its AAC default. */
    private const val AUDIO_BITRATE = 128_000

    private data class Tier(val edge: Int, val label: String, val min: Double, val max: Double)

    private val tiers = listOf(
        Tier(1920, "1080p", 3_500_000.0, 8_000_000.0),
        Tier(1280, "720p", 1_600_000.0, 4_000_000.0),
        Tier(960, "540p", 900_000.0, 2_200_000.0),
        Tier(640, "360p", 450_000.0, 1_100_000.0),
    )

    /** Best first. Empty when even the lowest tier will not fit — the sheet offers a trim. */
    fun plans(seconds: Double, sourceBytes: Long): List<ChatVideoPlan> {
        if (seconds <= 0) return emptyList()
        val fit = budgetBits / seconds - AUDIO_BITRATE
        // Never spend more than the source had: re-encoding cannot add detail.
        val sourceBitrate = sourceBytes * 8 / seconds
        val bestIndex = tiers.indexOfFirst { fit >= it.min }
        if (bestIndex < 0) return emptyList()
        val best = tiers[bestIndex]
        val bestRate = minOf(fit, best.max, sourceBitrate * 0.9)
        val out = mutableListOf(
            ChatVideoPlan("best", "Best quality that fits", "${best.label} — looks sharp full-screen",
                best.edge, bestRate.toInt(), AUDIO_BITRATE, seconds)
        )
        if (bestIndex + 1 < tiers.size) {
            val next = tiers[bestIndex + 1]
            val rate = min(bestRate * 0.5, next.max)
            if (rate >= next.min) {
                out += ChatVideoPlan("small", "Smaller", "${next.label} — quicker to send on mobile data",
                    next.edge, rate.toInt(), AUDIO_BITRATE, seconds)
            }
        }
        return out
    }

    /** For a video too long for any tier: the longest stretch that fits at the lowest one. */
    fun maxSeconds(): Double = kotlin.math.floor(budgetBits / (tiers.last().min + AUDIO_BITRATE))
}

class ChatCompressException(message: String) : Exception(message) {
    companion object {
        fun stillTooBig(b: Long) =
            ChatCompressException("It's still ${ChatMediaLimit.text(b)} after compressing. Try a smaller option.")
        val unreadable get() = ChatCompressException("Couldn't read that file.")
    }
}

// ── Video ─────────────────────────────────────────────────────────────────────────

object ChatVideoCompressor {
    /** Re-encode [source] to the plan, keeping its first [keepMs]. Retries once lower if over. */
    suspend fun compress(
        context: Context,
        source: File,
        plan: ChatVideoPlan,
        keepMs: Long,
        progress: (Float) -> Unit,
    ): File {
        val first = transcode(context, source, plan, keepMs) { progress(it * 0.95f) }
        val size = first.length()
        if (size <= ChatMediaLimit.BYTES) { progress(1f); return first }

        first.delete()
        val lower = plan.copy(
            videoBitrate = (plan.videoBitrate * 0.8 * ChatMediaLimit.BYTES / size).toInt()
                .coerceAtLeast(200_000),
        )
        val second = transcode(context, source, lower, keepMs) { progress(0.95f + it * 0.05f) }
        if (second.length() > ChatMediaLimit.BYTES) {
            val b = second.length()
            second.delete()
            throw ChatCompressException.stillTooBig(b)
        }
        progress(1f)
        return second
    }

    private suspend fun transcode(
        context: Context,
        source: File,
        plan: ChatVideoPlan,
        keepMs: Long,
        progress: (Float) -> Unit,
    ): File {
        val (w, h) = uprightSize(source)
        if (w <= 0 || h <= 0) throw ChatCompressException.unreadable
        // Fit the long edge to the plan, never upscale, and keep both sides even.
        val scale = min(1.0, plan.longEdge.toDouble() / max(w, h))
        val outW = ((w * scale) / 2).roundToInt() * 2
        val outH = ((h * scale) / 2).roundToInt() * 2

        val out = File(context.cacheDir, "chat_video_${UUID.randomUUID()}.mp4")
        val item = MediaItem.Builder()
            .setUri(Uri.fromFile(source))
            .setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder().setEndPositionMs(keepMs).build()
            )
            .build()
        val edited = EditedMediaItem.Builder(item)
            .setEffects(Effects(ImmutableList.of(),
                ImmutableList.of<androidx.media3.common.Effect>(Presentation.createForWidthAndHeight(outW, outH, Presentation.LAYOUT_SCALE_TO_FIT))))
            .build()

        // Transformer is thread-confined to the Looper it was built on: build, start, poll and
        // cancel all happen on Main. The encode itself runs on Transformer's own threads.
        val ok = withContext(Dispatchers.Main) {
            suspendCancellableCoroutine { cont ->
                val encoder = DefaultEncoderFactory.Builder(context)
                    .setRequestedVideoEncoderSettings(
                        VideoEncoderSettings.Builder().setBitrate(plan.videoBitrate).build()
                    )
                    .build()
                val transformer = Transformer.Builder(context)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .setAudioMimeType(MimeTypes.AUDIO_AAC)
                    .setEncoderFactory(encoder)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, result: ExportResult) {
                            if (cont.isActive) cont.resume(true)
                        }

                        override fun onError(composition: Composition, result: ExportResult, exception: ExportException) {
                            android.util.Log.w("VOIID", "chat video compress failed: ${exception.message}")
                            if (cont.isActive) cont.resume(false)
                        }
                    })
                    .build()
                transformer.start(edited, out.absolutePath)
                val poller = CoroutineScope(Dispatchers.Main.immediate).launch {
                    val holder = ProgressHolder()
                    while (cont.isActive) {
                        if (transformer.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) {
                            progress(holder.progress / 100f)
                        }
                        delay(200)
                    }
                }
                cont.invokeOnCancellation {
                    CoroutineScope(Dispatchers.Main.immediate).launch {
                        poller.cancel()
                        transformer.cancel()
                        out.delete()
                    }
                }
            }
        }
        if (!ok || !out.exists()) {
            out.delete()
            throw ChatCompressException("Couldn't compress this video.")
        }
        return out
    }

    fun uprightSize(file: File): Pair<Int, Int> = runCatching {
        val r = MediaMetadataRetriever()
        r.setDataSource(file.absolutePath)
        val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
        val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
        val rot = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
        r.release()
        if (rot == 90 || rot == 270) h to w else w to h
    }.getOrDefault(0 to 0)

    fun durationSeconds(file: File): Double = runCatching {
        val r = MediaMetadataRetriever()
        r.setDataSource(file.absolutePath)
        val d = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        r.release()
        d / 1000.0
    }.getOrDefault(0.0)

    fun thumbnail(file: File): Bitmap? = runCatching {
        val r = MediaMetadataRetriever()
        r.setDataSource(file.absolutePath)
        val b = r.getFrameAtTime(500_000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        r.release()
        b?.let { Bitmap.createScaledBitmap(it, 240, (240f * it.height / it.width).toInt().coerceAtLeast(1), true) }
    }.getOrNull()
}

// ── PDF ───────────────────────────────────────────────────────────────────────────

object ChatPdfCompressor {
    enum class Quality(val title: String, val note: String, val dpi: Int, val jpegQuality: Int, val bytesPerPage: Long) {
        BALANCED("Balanced", "Sharp enough to print", 144, 62, 190_000),
        SMALLEST("Smallest", "Clear on screen, lightest to send", 96, 50, 95_000),
    }

    fun estimate(pages: Int, quality: Quality): Long = pages * quality.bytesPerPage + 20_000

    fun pageCount(file: File): Int = runCatching {
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
            PdfRenderer(fd).use { it.pageCount }
        }
    }.getOrDefault(0)

    fun thumbnail(file: File): Bitmap? = runCatching {
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
            PdfRenderer(fd).use { r ->
                r.openPage(0).use { page ->
                    val w = 180
                    val h = (w.toFloat() * page.height / page.width).toInt().coerceAtLeast(1)
                    val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                    bmp.eraseColor(Color.WHITE)
                    page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    bmp
                }
            }
        }
    }.getOrNull()

    /**
     * Every page re-drawn as a JPEG image at the quality's resolution, in a new PDF of the same
     * page sizes. Android's PdfDocument would re-encode those bitmaps losslessly (and bigger),
     * so the PDF is written here directly with the JPEG bytes embedded as they are (DCTDecode).
     */
    suspend fun compress(context: Context, source: File, quality: Quality, progress: (Float) -> Unit): File =
        withContext(Dispatchers.IO) {
            val out = File(context.cacheDir, "chat_pdf_${UUID.randomUUID()}.pdf")
            try {
                ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
                    PdfRenderer(fd).use { renderer ->
                        if (renderer.pageCount == 0) throw ChatCompressException.unreadable
                        JpegPdfWriter(out.outputStream().buffered()).use { writer ->
                            for (i in 0 until renderer.pageCount) {
                                ensureActive()
                                renderer.openPage(i).use { page ->
                                    // PdfRenderer reports page sizes in points (1/72 inch).
                                    val pw = page.width
                                    val ph = page.height
                                    val px = (pw * quality.dpi / 72f).roundToInt().coerceAtLeast(1)
                                    val py = (ph * quality.dpi / 72f).roundToInt().coerceAtLeast(1)
                                    val bmp = Bitmap.createBitmap(px, py, Bitmap.Config.ARGB_8888)
                                    bmp.eraseColor(Color.WHITE)
                                    page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_PRINT)
                                    val jpeg = ByteArrayOutputStream().use { bos ->
                                        bmp.compress(Bitmap.CompressFormat.JPEG, quality.jpegQuality, bos)
                                        bos.toByteArray()
                                    }
                                    bmp.recycle()
                                    writer.addPage(jpeg, px, py, pw.toFloat(), ph.toFloat())
                                }
                                progress((i + 1f) / renderer.pageCount)
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                out.delete()
                if (e is ChatCompressException || e is kotlinx.coroutines.CancellationException) throw e
                throw ChatCompressException("Couldn't read this PDF.")
            }
            if (out.length() > ChatMediaLimit.BYTES) {
                val b = out.length()
                out.delete()
                throw ChatCompressException.stillTooBig(b)
            }
            out
        }
}

/**
 * The smallest PDF writer that does the job: one full-page JPEG image per page. Objects are
 * streamed as they are made; the catalog, page tree and cross-reference table close it.
 */
private class JpegPdfWriter(private val out: OutputStream) : AutoCloseable {
    private val offsets = mutableListOf<Long>()
    private var position = 0L
    private val pageIds = mutableListOf<Int>()
    // 1 = catalog, 2 = pages; everything else is allocated from 3.
    private var nextId = 3

    init {
        write("%PDF-1.4\n%âãÏÓ\n".toByteArray(Charsets.ISO_8859_1))
    }

    private fun write(bytes: ByteArray) { out.write(bytes); position += bytes.size }
    private fun write(s: String) = write(s.toByteArray(Charsets.ISO_8859_1))

    private fun begin(id: Int) {
        while (offsets.size < id) offsets.add(0)
        offsets[id - 1] = position
        write("$id 0 obj\n")
    }

    fun addPage(jpeg: ByteArray, pixelW: Int, pixelH: Int, pageW: Float, pageH: Float) {
        val imageId = nextId++
        val contentId = nextId++
        val pageId = nextId++
        begin(imageId)
        write("<< /Type /XObject /Subtype /Image /Width $pixelW /Height $pixelH /ColorSpace /DeviceRGB " +
            "/BitsPerComponent 8 /Filter /DCTDecode /Length ${jpeg.size} >>\nstream\n")
        write(jpeg)
        write("\nendstream\nendobj\n")
        val content = "q ${fmt(pageW)} 0 0 ${fmt(pageH)} 0 0 cm /Im0 Do Q"
        begin(contentId)
        write("<< /Length ${content.length} >>\nstream\n$content\nendstream\nendobj\n")
        begin(pageId)
        write("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${fmt(pageW)} ${fmt(pageH)}] " +
            "/Resources << /XObject << /Im0 $imageId 0 R >> >> /Contents $contentId 0 R >>\nendobj\n")
        pageIds += pageId
    }

    override fun close() {
        begin(1)
        write("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
        begin(2)
        write("<< /Type /Pages /Kids [${pageIds.joinToString(" ") { "$it 0 R" }}] /Count ${pageIds.size} >>\nendobj\n")
        val xref = position
        write("xref\n0 ${offsets.size + 1}\n0000000000 65535 f \n")
        offsets.forEach { write("%010d 00000 n \n".format(it)) }
        write("trailer\n<< /Size ${offsets.size + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n")
        out.close()
    }

    private fun fmt(v: Float) = if (v == v.toInt().toFloat()) v.toInt().toString() else "%.2f".format(java.util.Locale.US, v)
}

// ── Photos ────────────────────────────────────────────────────────────────────────

object ChatPhotoCompressor {
    /**
     * A photo over the limit, as a JPEG under it: full size at falling quality, then smaller
     * sizes. Upright — the EXIF rotation is applied, since the re-encode drops EXIF. Null only
     * when the data is not an image.
     */
    fun fit(data: ByteArray): ByteArray? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        // Decode no larger than 6000 on the long edge: a 200 MP original would not fit in memory.
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= 6000) sample *= 2
        val decoded = BitmapFactory.decodeByteArray(data, 0, data.size,
            BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
        val upright = applyExif(decoded, data)

        val longest = max(upright.width, upright.height)
        for (edge in listOf(longest, 6000, 4096, 3000)) {
            if (edge > longest) continue
            val resized = resize(upright, edge)
            for (q in listOf(85, 72, 60)) {
                val jpeg = encode(resized, q)
                if (jpeg.size <= ChatMediaLimit.BYTES) return jpeg
            }
        }
        return encode(resize(upright, 2048), 60)
    }

    private fun encode(b: Bitmap, q: Int): ByteArray = ByteArrayOutputStream().use {
        b.compress(Bitmap.CompressFormat.JPEG, q, it)
        it.toByteArray()
    }

    private fun resize(b: Bitmap, longEdge: Int): Bitmap {
        val scale = min(1f, longEdge.toFloat() / max(b.width, b.height))
        if (scale >= 1f) return b
        return Bitmap.createScaledBitmap(b, (b.width * scale).roundToInt(), (b.height * scale).roundToInt(), true)
    }

    private fun applyExif(b: Bitmap, data: ByteArray): Bitmap {
        val orientation = runCatching {
            android.media.ExifInterface(data.inputStream())
                .getAttributeInt(android.media.ExifInterface.TAG_ORIENTATION, android.media.ExifInterface.ORIENTATION_NORMAL)
        }.getOrDefault(android.media.ExifInterface.ORIENTATION_NORMAL)
        val degrees = when (orientation) {
            android.media.ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            android.media.ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            android.media.ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> 0f
        }
        if (degrees == 0f) return b
        return Bitmap.createBitmap(b, 0, 0, b.width, b.height, Matrix().apply { postRotate(degrees) }, true)
    }
}

// ── Intake ────────────────────────────────────────────────────────────────────────

/** What a picked file is: its name, size and type, read without loading it. */
data class ChatPickedFile(val uri: Uri, val name: String, val bytes: Long, val mime: String)

object ChatAttachmentIntake {
    fun describe(context: Context, uri: Uri): ChatPickedFile {
        var name = "File"
        var size = -1L
        runCatching {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
                ?.use { c ->
                    if (c.moveToFirst()) {
                        c.getString(0)?.let { name = it }
                        if (!c.isNull(1)) size = c.getLong(1)
                    }
                }
        }
        if (size < 0) {
            size = runCatching {
                context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length }
            }.getOrNull() ?: -1L
        }
        val mime = context.contentResolver.getType(uri)
            ?: android.webkit.MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
            ?: "application/octet-stream"
        return ChatPickedFile(uri, name, size, mime)
    }

    /** Copy [uri] into the cache, where the compressor reads it. */
    fun copyToCache(context: Context, uri: Uri, ext: String): File? = runCatching {
        val out = File(context.cacheDir, "chat_pick_${UUID.randomUUID()}.$ext")
        context.contentResolver.openInputStream(uri)?.use { input -> out.outputStream().use { input.copyTo(it) } }
            ?: return null
        out
    }.getOrNull()

    /** A picked file over the limit, ready for the compress sheet. */
    fun oversize(context: Context, picked: ChatPickedFile): ChatOversizeFile {
        return when {
            picked.mime.startsWith("video/") -> {
                val copy = copyToCache(context, picked.uri, "mp4")
                    ?: return ChatOversizeFile(file = null, name = picked.name, bytes = picked.bytes, kind = ChatOversizeFile.Kind.Other)
                val seconds = ChatVideoCompressor.durationSeconds(copy)
                ChatOversizeFile(file = copy, name = picked.name, bytes = picked.bytes,
                    kind = if (seconds > 0) ChatOversizeFile.Kind.Video(seconds) else ChatOversizeFile.Kind.Other)
            }
            picked.mime == "application/pdf" || picked.name.endsWith(".pdf", ignoreCase = true) -> {
                val copy = copyToCache(context, picked.uri, "pdf")
                val pages = copy?.let { ChatPdfCompressor.pageCount(it) } ?: 0
                ChatOversizeFile(file = copy, name = picked.name, bytes = picked.bytes,
                    kind = if (pages > 0) ChatOversizeFile.Kind.Pdf(pages) else ChatOversizeFile.Kind.Other)
            }
            // Only a video or PDF is worth copying: nothing else can be made smaller, and a
            // 2 GB archive should not be duplicated just to be told so.
            else -> ChatOversizeFile(file = null, name = picked.name, bytes = picked.bytes, kind = ChatOversizeFile.Kind.Other)
        }
    }

    /** Deletes [file] only if it is one of our own copies in the cache. */
    fun removeTemporary(context: Context, file: File?) {
        file ?: return
        if (file.canonicalPath.startsWith(context.cacheDir.canonicalPath + File.separator)) file.delete()
    }
}
