@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.voiid.app.main.clips

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.Player
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.Presentation
import androidx.media3.effect.TextureOverlay
import androidx.media3.effect.RgbFilter
import androidx.media3.effect.RgbMatrix
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.google.common.collect.ImmutableList
import com.voiid.app.net.ClipQuality
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidPrimaryButton
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.math.roundToInt

/**
 * The edit description, the looks and the exporter behind ClipEditorScreen. Port of iOS `ClipEditor.swift`.
 *
 * ON "ALL THE FILTERS ON THE PHONE": Android has no public API that enumerates the
 * system gallery's own filter list either. The correct equivalent — and what this uses —
 * is Media3's `Effect` pipeline (`RgbFilter` / `RgbMatrix`), applied on export by
 * `Transformer`. The filter list is defined as data in the SAME ORDER as iOS's
 * `ClipFilter` so both platforms present an identical strip (docs/CLIPS.md §5.3).
 *
 * The editor only ever produces an EDIT DESCRIPTION ([ClipEdit]); nothing is re-encoded
 * until export. Re-encoding per tweak would make the strip unusable.
 */
data class ClipEdit(
    val trimStartMs: Long = 0,
    val trimEndMs: Long = 0,
    val filter: ClipFilter = ClipFilter.NONE,
    val muted: Boolean = false,
    /** Ms into the SOURCE (not the trimmed range) for the grid cover frame. */
    val coverMs: Long = 0,
    /**
     * A separate image the author picked instead of a video frame. When set, this WINS
     * over [coverMs] — see [coverSource].
     */
    val customCoverJpeg: ByteArray? = null,
    /** Words placed on the clip, burned in on export (ClipTextOverlay). */
    val texts: List<ClipTextOverlay> = emptyList(),
) {
    val durationMs: Long get() = (trimEndMs - trimStartMs).coerceAtLeast(0)

    /**
     * What the grid tile will actually show. The grid is ENTIRELY cover images, so this
     * is the highest-leverage choice in the whole composer.
     */
    val coverSource: String get() = if (customCoverJpeg == null) "frame" else "upload"

    // ByteArray breaks data-class equality (identity, not contents), which would make
    // Compose recompose forever on an unchanged cover. Compare by content instead.
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is ClipEdit) return false
        return trimStartMs == other.trimStartMs &&
            trimEndMs == other.trimEndMs &&
            filter == other.filter &&
            muted == other.muted &&
            coverMs == other.coverMs &&
            texts == other.texts &&
            customCoverJpeg.contentEquals(other.customCoverJpeg)
    }

    override fun hashCode(): Int {
        var result = trimStartMs.hashCode()
        result = 31 * result + trimEndMs.hashCode()
        result = 31 * result + filter.hashCode()
        result = 31 * result + muted.hashCode()
        result = 31 * result + coverMs.hashCode()
        result = 31 * result + (customCoverJpeg?.contentHashCode() ?: 0)
        result = 31 * result + texts.hashCode()
        return result
    }
}

/** Keep names/order identical to the iOS list. */
enum class ClipFilter(val label: String) {
    NONE("Original"),
    VIVID("Vivid"),
    DRAMATIC("Dramatic"),
    MONO("Mono"),
    NOIR("Noir"),
    FADE("Fade"),
    CHROME("Chrome"),
    PROCESS("Process"),
    TRANSFER("Transfer"),
    INSTANT("Instant");

    /**
     * The Media3 effect chain, or empty for the untouched original.
     *
     * ANDROID HAS NO SYSTEM FILTER LIBRARY. iOS gets these looks from Apple's own
     * CIPhotoEffect set (the filters Photos uses); there is no OS-provided equivalent here —
     * Google Photos' filters are private to that app. Media3 gives primitives (RgbMatrix,
     * RgbFilter) and the LOOKS have to be authored. So each entry below reproduces its iOS
     * counterpart with an explicit colour matrix.
     *
     * PREVIOUSLY EVERY NON-MONO FILTER WAS ONLY A SATURATION CHANGE, which made Chrome,
     * Process, Transfer and Instant near-indistinguishable washes of each other rather than
     * different looks — and DRAMATIC was grayscale here but colour on iOS, so the same clip
     * filtered the same way looked different on the two platforms.
     */
    fun effects(): List<Effect> = when (this) {
        NONE -> emptyList()
        // True monochrome.
        MONO -> listOf(RgbFilter.createGrayscaleFilter())
        // Mono, then crushed contrast — the high-contrast black and white of CIPhotoEffectNoir.
        NOIR -> listOf(RgbFilter.createGrayscaleFilter(), contrast(1.4f, -0.06f))
        // COLOUR, not mono: matches the iOS .dramatic branch exactly.
        DRAMATIC -> listOf(colorMatrix(saturationMatrix(0.85f)), contrast(1.35f, -0.05f))
        VIVID -> listOf(colorMatrix(saturationMatrix(1.45f)), contrast(1.05f, 0f))
        // Lifted blacks and low saturation — the washed-out look of CIPhotoEffectFade.
        FADE -> listOf(colorMatrix(saturationMatrix(0.65f)), contrast(0.85f, 0.08f))
        // Cool, bright, punchy.
        CHROME -> listOf(colorMatrix(channelMatrix(0.98f, 1.02f, 1.10f)), contrast(1.15f, 0f))
        // Cross-processed: green/blue push with a magenta shadow cast.
        PROCESS -> listOf(colorMatrix(channelMatrix(1.05f, 1.08f, 0.92f)), contrast(1.2f, -0.02f))
        // Warm, faded, low contrast — the aged-print look.
        TRANSFER -> listOf(colorMatrix(channelMatrix(1.12f, 0.98f, 0.88f)), contrast(0.95f, 0.04f))
        // Polaroid: warm highlights, lifted blacks, muted colour.
        INSTANT -> listOf(colorMatrix(saturationMatrix(0.75f)), contrast(0.9f, 0.06f))
    }

    /**
     * The same look for the still preview, the filter-strip thumbnails and the cover frame.
     *
     * This MUST track effects() above. The strip is how the author picks a filter, so if it
     * shows a different transform than export applies, every choice is made against a
     * preview that lies — and the mismatch only surfaces after upload.
     */
    fun applyToBitmap(src: Bitmap): Bitmap {
        val matrix = colorMatrix() ?: return src
        val out = src.copy(Bitmap.Config.ARGB_8888, true)
        val canvas = android.graphics.Canvas(out)
        val paint = android.graphics.Paint()
        paint.colorFilter = android.graphics.ColorMatrixColorFilter(matrix)
        canvas.drawBitmap(src, 0f, 0f, paint)
        return out
    }

    /**
     * The look as a single [android.graphics.ColorMatrix], or null for the untouched original.
     *
     * Split out of [applyToBitmap] so the LIVE viewfinder can wear the same look without a
     * second copy of the numbers: the camera preview is a TextureView, and its composite takes
     * a ColorMatrixColorFilter directly (see ClipCameraView). One definition, three surfaces —
     * strip thumbnails, cover frame, viewfinder — so they cannot drift apart.
     */
    fun colorMatrix(): android.graphics.ColorMatrix? {
        if (this == NONE) return null
        // ColorMatrix.postConcat composes in the same order effects() chains them.
        val matrix = android.graphics.ColorMatrix()
        when (this) {
            MONO -> matrix.setSaturation(0f)
            NOIR -> {
                matrix.setSaturation(0f)
                matrix.postConcat(contrastColorMatrix(1.4f, -0.06f))
            }
            DRAMATIC -> {
                matrix.setSaturation(0.85f)
                matrix.postConcat(contrastColorMatrix(1.35f, -0.05f))
            }
            VIVID -> {
                matrix.setSaturation(1.45f)
                matrix.postConcat(contrastColorMatrix(1.05f, 0f))
            }
            FADE -> {
                matrix.setSaturation(0.65f)
                matrix.postConcat(contrastColorMatrix(0.85f, 0.08f))
            }
            CHROME -> {
                matrix.postConcat(channelColorMatrix(0.98f, 1.02f, 1.10f))
                matrix.postConcat(contrastColorMatrix(1.15f, 0f))
            }
            PROCESS -> {
                matrix.postConcat(channelColorMatrix(1.05f, 1.08f, 0.92f))
                matrix.postConcat(contrastColorMatrix(1.2f, -0.02f))
            }
            TRANSFER -> {
                matrix.postConcat(channelColorMatrix(1.12f, 0.98f, 0.88f))
                matrix.postConcat(contrastColorMatrix(0.95f, 0.04f))
            }
            INSTANT -> {
                matrix.setSaturation(0.75f)
                matrix.postConcat(contrastColorMatrix(0.9f, 0.06f))
            }
            NONE -> Unit
        }
        return matrix
    }

    /**
     * Standard luminance-preserving saturation matrix (Rec. 709 weights) — the same transform
     * ColorMatrix.setSaturation applies, in the column-major 4x4 the GL pipeline wants.
     */
    private fun saturationMatrix(value: Float): FloatArray {
        val lr = 0.2126f; val lg = 0.7152f; val lb = 0.0722f
        val inv = 1f - value
        return floatArrayOf(
            lr * inv + value, lr * inv, lr * inv, 0f,
            lg * inv, lg * inv + value, lg * inv, 0f,
            lb * inv, lb * inv, lb * inv + value, 0f,
            0f, 0f, 0f, 1f,
        )
    }

    /** Per-channel gain — how a look gets a colour CAST rather than just more/less colour. */
    private fun channelMatrix(r: Float, g: Float, b: Float): FloatArray = floatArrayOf(
        r, 0f, 0f, 0f,
        0f, g, 0f, 0f,
        0f, 0f, b, 0f,
        0f, 0f, 0f, 1f,
    )

    private fun colorMatrix(m: FloatArray): RgbMatrix = RgbMatrix { _, _ -> m }

    /**
     * The android.graphics.ColorMatrix twins of contrast()/channelMatrix() above, for the
     * bitmap preview path.
     *
     * NOT the same array layout as the GL versions, and this is an easy place to get it
     * wrong: android.graphics.ColorMatrix is ROW-major 4x5 and its translation column is in
     * 0..255 units, while RgbMatrix is column-major 4x4 in 0..1. The same brightness offset
     * therefore has to be multiplied by 255 here to mean the same thing.
     */
    private fun contrastColorMatrix(amount: Float, brightness: Float): android.graphics.ColorMatrix {
        val t = ((1f - amount) * 0.5f + brightness) * 255f
        return android.graphics.ColorMatrix(
            floatArrayOf(
                amount, 0f, 0f, 0f, t,
                0f, amount, 0f, 0f, t,
                0f, 0f, amount, 0f, t,
                0f, 0f, 0f, 1f, 0f,
            )
        )
    }

    private fun channelColorMatrix(r: Float, g: Float, b: Float): android.graphics.ColorMatrix =
        android.graphics.ColorMatrix(
            floatArrayOf(
                r, 0f, 0f, 0f, 0f,
                0f, g, 0f, 0f, 0f,
                0f, 0f, b, 0f, 0f,
                0f, 0f, 0f, 1f, 0f,
            )
        )

    /**
     * Contrast about mid-grey, plus a brightness offset. Pivoting at 0.5 is what keeps a
     * contrast boost from also brightening the whole frame: scaling around 0 would push every
     * value up, which reads as "washed out and too bright" rather than "punchy".
     */
    private fun contrast(amount: Float, brightness: Float): RgbMatrix {
        val t = (1f - amount) * 0.5f + brightness
        return RgbMatrix { _, _ ->
            floatArrayOf(
                amount, 0f, 0f, 0f,
                0f, amount, 0f, 0f,
                0f, 0f, amount, 0f,
                t, t, t, 1f,
            )
        }
    }
}

/** Long edge of a filmstrip / filter thumb, in px. */
private const val THUMB_EDGE = 240

/**
 * Re-encode the picked image to a bounded JPEG. An 8 MB HEIC straight from the gallery
 * would be a 200x heavier grid tile than the frames it sits beside.
 */
internal fun loadCustomCover(context: Context, uri: android.net.Uri): ByteArray? = runCatching {
    val source = context.contentResolver.openInputStream(uri).use {
        android.graphics.BitmapFactory.decodeStream(it)
    } ?: return null

    val maxEdge = 1080f
    val scale = minOf(1f, maxEdge / maxOf(source.width, source.height).toFloat())
    val resized = if (scale < 1f) {
        Bitmap.createScaledBitmap(
            source,
            (source.width * scale).toInt(),
            (source.height * scale).toInt(),
            true,
        )
    } else {
        source
    }
    ByteArrayOutputStream().use { bos ->
        resized.compress(Bitmap.CompressFormat.JPEG, 80, bos)
        bos.toByteArray()
    }
}.getOrNull()

/**
 * Shrink a decoded video frame to thumbnail size, recycling the original.
 *
 * Ten filmstrip frames plus ten filter thumbnails at full 1080p ARGB would be ~160 MB of
 * bitmap held live, for images drawn a few dp wide — an OOM on any mid-range device.
 */
internal fun downscale(src: Bitmap): Bitmap {
    val longEdge = maxOf(src.width, src.height)
    if (longEdge <= THUMB_EDGE) return src
    val scale = THUMB_EDGE.toFloat() / longEdge
    val out = Bitmap.createScaledBitmap(
        src, (src.width * scale).toInt().coerceAtLeast(1),
        (src.height * scale).toInt().coerceAtLeast(1), true,
    )
    if (out !== src) src.recycle()
    return out
}

/** The strip of frames itself, shared by the trim and cover scrubbers. */
@Composable
private fun FilmstripRow(frames: List<Bitmap>, modifier: Modifier = Modifier) {
    Row(
        modifier
            .clip(RoundedCornerShape(VoiidRadius.sm))
            .background(VoiidColor.surfaceCard),
    ) {
        if (frames.isEmpty()) {
            ClipShimmer(Modifier.fillMaxSize())
        } else {
            frames.forEach { frame ->
                androidx.compose.foundation.Image(
                    bitmap = frame.asImageBitmap(),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.weight(1f).fillMaxHeight(),
                )
            }
        }
    }
}

/**
 * Trim with real frames under two draggable handles.
 *
 * The two abstract labelled sliders this replaces gave no clue WHERE in the clip a start or
 * end landed — you set a number, then scrolled up to a still that may not even have changed.
 */
@Composable
internal fun TrimStrip(
    frames: List<Bitmap>,
    durationMs: Long,
    startMs: Long,
    endMs: Long,
    onChange: (start: Long, end: Long) -> Unit,
    onCommit: () -> Unit,
) {
    val density = LocalDensity.current
    BoxWithConstraints(Modifier.fillMaxWidth().height(64.dp)) {
        val widthPx = with(density) { maxWidth.toPx() }
        if (widthPx <= 0f) return@BoxWithConstraints
        val msPerPx = durationMs / widthPx

        FilmstripRow(frames, Modifier.matchParentSize())

        val startX = startMs.toFloat() / durationMs * widthPx
        val endX = endMs.toFloat() / durationMs * widthPx

        // What the trim throws away, dimmed rather than hidden: the discarded frames are the
        // context that tells you whether the cut is in the right place.
        Box(
            Modifier.matchParentSize().drawWithContent {
                drawContent()
                val scrim = Color.Black.copy(alpha = 0.55f)
                drawRect(scrim, size = androidx.compose.ui.geometry.Size(startX, size.height))
                drawRect(
                    scrim,
                    topLeft = androidx.compose.ui.geometry.Offset(endX, 0f),
                    size = androidx.compose.ui.geometry.Size(
                        (size.width - endX).coerceAtLeast(0f), size.height,
                    ),
                )
            }
        )

        TrimHandle(startX, onCommit) { delta ->
            val moved = (startMs + delta * msPerPx).toLong()
            onChange(moved.coerceIn(0L, (endMs - 500).coerceAtLeast(0L)), endMs)
        }
        TrimHandle(endX, onCommit) { delta ->
            val moved = (endMs + delta * msPerPx).toLong()
            // Clamped to the 90s cap here as well as at intake, so a long source can be
            // trimmed DOWN into range rather than rejected outright.
            val ceiling = minOf(durationMs, startMs + ClipCaps.MAX_DURATION_MS)
            onChange(startMs, moved.coerceIn((startMs + 500).coerceAtMost(ceiling), ceiling))
        }
    }
}

/** A 6dp bar inside a 44dp grab area — thin enough to aim with, wide enough to hit. */
@Composable
private fun BoxScope.TrimHandle(x: Float, onCommit: () -> Unit, onDelta: (Float) -> Unit) {
    val touch = 44.dp
    val touchPx = with(LocalDensity.current) { touch.toPx() }
    Box(
        Modifier
            .offset { IntOffset((x - touchPx / 2f).roundToInt(), 0) }
            .width(touch)
            .fillMaxHeight()
            .draggable(
                orientation = Orientation.Horizontal,
                state = rememberDraggableState { onDelta(it) },
                onDragStopped = { onCommit() },
            ),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .width(6.dp)
                .fillMaxHeight()
                .clip(RoundedCornerShape(VoiidRadius.sm))
                .background(VoiidColor.primary)
        )
    }
}

/**
 * The cover scrubber: the same filmstrip with a SINGLE handle — exactly Instagram's "Edit
 * cover". The handle is confined to the trimmed range because a cover frame outside it is one
 * the published clip never shows.
 */
@Composable
internal fun CoverStrip(
    frames: List<Bitmap>,
    durationMs: Long,
    coverMs: Long,
    startMs: Long,
    endMs: Long,
    onChange: (Long) -> Unit,
) {
    val density = LocalDensity.current
    BoxWithConstraints(Modifier.fillMaxWidth().height(64.dp)) {
        val widthPx = with(density) { maxWidth.toPx() }
        if (widthPx <= 0f) return@BoxWithConstraints
        val msPerPx = durationMs / widthPx

        FilmstripRow(frames, Modifier.matchParentSize())

        val clamped = coverMs.coerceIn(startMs, (endMs - 100).coerceAtLeast(startMs))
        val x = clamped.toFloat() / durationMs * widthPx
        val touch = 44.dp
        val touchPx = with(density) { touch.toPx() }
        Box(
            Modifier
                .offset { IntOffset((x - touchPx / 2f).roundToInt(), 0) }
                .width(touch)
                .fillMaxHeight()
                .draggable(
                    orientation = Orientation.Horizontal,
                    state = rememberDraggableState { d ->
                        onChange(
                            (clamped + d * msPerPx).toLong()
                                .coerceIn(startMs, (endMs - 100).coerceAtLeast(startMs))
                        )
                    },
                ),
            contentAlignment = Alignment.Center,
        ) {
            Box(
                Modifier
                    .width(34.dp)
                    .fillMaxHeight()
                    .clip(RoundedCornerShape(VoiidRadius.sm))
                    .border(2.dp, VoiidColor.accent, RoundedCornerShape(VoiidRadius.sm))
            )
        }
    }
}

// ── Export ────────────────────────────────────────────────────────────────────────

object ClipExporter {
    data class Output(
        val file: File,
        val thumbnailJpeg: ByteArray,
        val durationMs: Long,
        val width: Int,
        val height: Int,
    )

    fun durationMs(file: File): Long = runCatching {
        val r = MediaMetadataRetriever()
        r.setDataSource(file.absolutePath)
        val d = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        r.release()
        d
    }.getOrDefault(0L)

    fun frameBitmap(file: File, atMs: Long): Bitmap? = runCatching {
        val r = MediaMetadataRetriever()
        r.setDataSource(file.absolutePath)
        // OPTION_CLOSEST_SYNC (not OPTION_CLOSEST): seeking to an exact non-keyframe on
        // long-GOP H.264 is slow and frequently returns null.
        val bmp = r.getFrameAtTime(atMs * 1000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        r.release()
        bmp
    }.getOrNull()

    /** The full ladder plus the cover, produced in one pass. */
    data class LadderOutput(
        val baseline: File,
        val baselineSize: Long,
        val renditions: Map<ClipQuality, Pair<File, Long>>,
        val thumbnailJpeg: ByteArray,
        val coverSource: String,
        val durationMs: Long,
        val width: Int,
        val height: Int,
    )

    /** The source's upright size — width and height with its rotation applied. */
    fun uprightSize(file: File): Pair<Int, Int> = runCatching {
        val r = MediaMetadataRetriever()
        r.setDataSource(file.absolutePath)
        val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
        val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
        val rot = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
        r.release()
        if (rot == 90 || rot == 270) h to w else w to h
    }.getOrDefault(0 to 0)

    /** The source's long edge, used to skip rungs that would only upscale. */
    private fun sourceLongEdge(file: File): Int = runCatching {
        val r = MediaMetadataRetriever()
        r.setDataSource(file.absolutePath)
        val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
        val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
        r.release()
        maxOf(w, h)
    }.getOrDefault(0)

    /**
     * Encode one rendition. Returns null when the source is already smaller than this
     * rung — UPSCALING is never worth it: it costs upload bytes and encode time to
     * produce a file that looks no better than the one below it.
     */
    private suspend fun encode(
        context: Context,
        source: File,
        edit: ClipEdit,
        quality: ClipQuality,
        sourceEdge: Int,
    ): Pair<File, Long>? {
        // 10% tolerance so a 1920x1080 source still satisfies FHD rather than being
        // rejected by a rounding difference. SD is always produced as the floor.
        if (quality != ClipQuality.SD && sourceEdge < quality.longEdge * 0.9) return null

        val out = File(context.cacheDir, "clip_${quality.wire}_${UUID.randomUUID()}.mp4")

        val clipped = MediaItem.Builder()
            .setUri(android.net.Uri.fromFile(source))
            .setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionMs(edit.trimStartMs)
                    .setEndPositionMs(edit.trimEndMs)
                    .build()
            )
            .build()

        // Scale to the rung, then apply the filter. Order matters: scaling first means
        // the (more expensive) colour pass runs on fewer pixels.
        //
        // `createForHeight` preserves aspect ratio and is the right axis here because
        // clips are portrait — height IS the long edge, which is what ClipQuality.longEdge
        // describes. (There is no createForShortSide in Media3; the alternatives are
        // createForHeight / createForWidthAndHeight / createForAspectRatio.)
        val videoEffects = buildList {
            add(Presentation.createForHeight(quality.longEdge))
            addAll(edit.filter.effects())
            // Text goes on LAST, over the filtered frame, so a look never tints the words.
            // The overlay is drawn at this rung's exact output size; Media3 places a bitmap
            // overlay at its pixel size, so frame-sized means it maps 1:1 onto the frame.
            if (edit.texts.any { it.text.isNotBlank() }) {
                val (w, h) = uprightSize(source)
                if (w > 0 && h > 0) {
                    val outW = (w.toLong() * quality.longEdge / h).toInt()
                    ClipTextRenderer.overlay(context, edit.texts, outW, quality.longEdge)?.let { bmp ->
                        add(OverlayEffect(ImmutableList.of<TextureOverlay>(
                            BitmapOverlay.createStaticBitmapOverlay(bmp))))
                    }
                }
            }
        }

        val editedItem = EditedMediaItem.Builder(clipped)
            .setRemoveAudio(edit.muted)
            .setEffects(Effects(ImmutableList.of(), ImmutableList.copyOf(videoEffects)))
            .build()

        // Transformer MUST be built, started and cancelled on ONE thread — the one whose
        // Looper it captured at build time — and it enforces that with
        // `verifyApplicationThread()`. Calling start() from Dispatchers.IO threw
        // `IllegalStateException: Transformer is accessed on the wrong thread` and killed the
        // process, which is why Android clip upload never worked at all. withContext(Main)
        // pins the whole lifecycle to the main thread; the actual transcode still runs on
        // Transformer's own internal worker threads, so this does NOT block the UI.
        val ok = withContext(Dispatchers.Main) {
            suspendCancellableCoroutine { cont ->
                val transformer = Transformer.Builder(context)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, result: ExportResult) {
                            if (cont.isActive) cont.resume(true)
                        }

                        override fun onError(
                            composition: Composition,
                            result: ExportResult,
                            exception: ExportException,
                        ) {
                            android.util.Log.w(
                                "VOIID",
                                "clip export ${quality.wire} failed: ${exception.message}",
                            )
                            if (cont.isActive) cont.resume(false)
                        }
                    })
                    .build()
                transformer.start(editedItem, out.absolutePath)
                cont.invokeOnCancellation {
                    // cancel() is thread-confined too — hop back to Main rather than calling
                    // it from whatever thread cancelled the coroutine.
                    CoroutineScope(Dispatchers.Main.immediate).launch { transformer.cancel() }
                }
            }
        }
        if (!ok || !out.exists()) return null

        // A rendition over the cap is dropped rather than failing the whole post — the
        // ladder still has smaller rungs.
        if (out.length() > ClipCaps.MAX_BYTES) {
            out.delete()
            return null
        }
        return out to out.length()
    }

    /**
     * Apply the whole edit list and produce the full rendition ladder.
     *
     * The BASELINE is the best rung that actually encoded; the others ride along. At
     * least one must succeed or the post fails — a clip with no video is not a clip.
     */
    suspend fun exportLadder(context: Context, source: File, edit: ClipEdit): LadderOutput? {
        val sourceEdge = sourceLongEdge(source)

        // Sequential, not concurrent: three simultaneous hardware encodes contend for the
        // same MediaCodec resources and on many devices simply fail.
        val renditions = mutableMapOf<ClipQuality, Pair<File, Long>>()
        for (quality in ClipQuality.entries) {
            encode(context, source, edit, quality, sourceEdge)?.let { renditions[quality] = it }
        }
        if (renditions.isEmpty()) return null

        // Baseline = the highest rung produced, so a client that ignores renditions
        // entirely still gets the best available file.
        val baselineQuality = listOf(ClipQuality.FHD, ClipQuality.HD, ClipQuality.SD)
            .first { renditions[it] != null }
        val (baselineFile, baselineSize) = renditions.getValue(baselineQuality)

        // An uploaded cover WINS over the frame picker and is deliberately NOT filtered:
        // the filter applies to the video, and silently tinting a photo the author chose
        // would be a surprise they cannot undo.
        val custom = edit.customCoverJpeg
        val coverAt = edit.coverMs
            .coerceIn(edit.trimStartMs, (edit.trimEndMs - 100).coerceAtLeast(edit.trimStartMs))
        val raw = frameBitmap(source, coverAt)
        val cover = raw?.let { edit.filter.applyToBitmap(it) }
        val jpeg = custom ?: cover?.let {
            ByteArrayOutputStream().use { bos ->
                it.compress(Bitmap.CompressFormat.JPEG, 80, bos)
                bos.toByteArray()
            }
        } ?: return null

        return LadderOutput(
            baseline = baselineFile,
            baselineSize = baselineSize,
            renditions = renditions,
            thumbnailJpeg = jpeg,
            coverSource = edit.coverSource,
            durationMs = edit.durationMs,
            width = cover?.width ?: 0,
            height = cover?.height ?: 0,
        )
    }
}
