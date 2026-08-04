package com.voiid.app.main.clips

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.effect.Presentation
import androidx.media3.effect.RgbFilter
import androidx.media3.effect.RgbMatrix
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
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

/**
 * Step 3 of the composer: trim, filter, cover frame. Port of iOS `ClipEditor.swift`.
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
            customCoverJpeg.contentEquals(other.customCoverJpeg)
    }

    override fun hashCode(): Int {
        var result = trimStartMs.hashCode()
        result = 31 * result + trimEndMs.hashCode()
        result = 31 * result + filter.hashCode()
        result = 31 * result + muted.hashCode()
        result = 31 * result + coverMs.hashCode()
        result = 31 * result + (customCoverJpeg?.contentHashCode() ?: 0)
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
        if (this == NONE) return src
        val out = src.copy(Bitmap.Config.ARGB_8888, true)
        val canvas = android.graphics.Canvas(out)
        val paint = android.graphics.Paint()
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
        paint.colorFilter = android.graphics.ColorMatrixColorFilter(matrix)
        canvas.drawBitmap(src, 0f, 0f, paint)
        return out
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

@Composable
fun ClipEditorView(
    sourceFile: File,
    edit: ClipEdit,
    onEditChange: (ClipEdit) -> Unit,
    onNext: () -> Unit,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current

    var durationMs by remember { mutableStateOf(0L) }
    var preview by remember { mutableStateOf<Bitmap?>(null) }
    var scrubMs by remember { mutableStateOf(0L) }
    val filterThumbs = remember { mutableStateMapOf<ClipFilter, Bitmap>() }
    val scope = rememberCoroutineScope()

    val coverPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia()
    ) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        scope.launch {
            val jpeg = withContext(Dispatchers.IO) { loadCustomCover(context, uri) }
            if (jpeg != null) {
                onEditChange(edit.copy(customCoverJpeg = jpeg))
                haptics.success()
            }
        }
    }

    LaunchedEffect(sourceFile) {
        durationMs = withContext(Dispatchers.IO) { ClipExporter.durationMs(sourceFile) }
        if (edit.trimEndMs <= 0L) {
            onEditChange(edit.copy(trimEndMs = minOf(durationMs, ClipCaps.MAX_DURATION_MS)))
        }
        // One decode, N filter applications — decoding per filter would make the strip
        // take ten times as long to populate.
        val base = withContext(Dispatchers.IO) {
            ClipExporter.frameBitmap(sourceFile, edit.trimStartMs.coerceAtLeast(100))
        }
        if (base != null) {
            ClipFilter.entries.forEach { f -> filterThumbs[f] = f.applyToBitmap(base) }
        }
    }

    LaunchedEffect(scrubMs, edit.filter) {
        val bmp = withContext(Dispatchers.IO) { ClipExporter.frameBitmap(sourceFile, scrubMs) }
        preview = bmp?.let { edit.filter.applyToBitmap(it) }
    }

    Column(
        Modifier.fillMaxSize().padding(16.dp).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        // Preview
        Box(
            Modifier
                .fillMaxWidth()
                .height(320.dp)
                .clip(RoundedCornerShape(VoiidRadius.lg))
                .background(Color.Black),
            contentAlignment = Alignment.Center,
        ) {
            preview?.let {
                androidx.compose.foundation.Image(
                    bitmap = it.asImageBitmap(),
                    contentDescription = null,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxSize(),
                )
            } ?: ClipShimmer(Modifier.fillMaxSize())
        }

        // Trim
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Trim", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Spacer(Modifier.weight(1f))
            Text(
                String.format("%.1fs", edit.durationMs / 1000f),
                style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
            )
        }
        if (durationMs > 0) {
            LabeledSlider("Start", edit.trimStartMs.toFloat(), 0f, durationMs.toFloat()) { v ->
                val start = v.toLong().coerceAtMost((edit.trimEndMs - 500).coerceAtLeast(0))
                onEditChange(edit.copy(trimStartMs = start))
                scrubMs = start
            }
            LabeledSlider("End", edit.trimEndMs.toFloat(), 0f, durationMs.toFloat()) { v ->
                // Clamp to the 90s cap here as well as at intake: a long source can be
                // trimmed DOWN into range rather than rejected.
                val capped = v.toLong().coerceAtMost(edit.trimStartMs + ClipCaps.MAX_DURATION_MS)
                onEditChange(edit.copy(trimEndMs = capped.coerceAtLeast(edit.trimStartMs + 500)))
                scrubMs = capped
            }
        }

        // Cover — the grid is entirely cover images, so this is the highest-leverage
        // control in the whole flow. Never cut it. Two ways to set it: scrub to a frame,
        // or upload a separate image. An uploaded image WINS over the scrubber (and
        // clearing it returns to the frame), so the two can never disagree.
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Cover", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Spacer(Modifier.weight(1f))
            if (edit.customCoverJpeg != null) {
                Text(
                    "Use a video frame",
                    style = VoiidFont.rounded(12),
                    color = VoiidColor.primary,
                    modifier = Modifier.softClickable(scale = 0.95f) {
                        haptics.tap()
                        onEditChange(edit.copy(customCoverJpeg = null))
                    },
                )
            }
        }

        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // Live preview of exactly what the grid tile will be.
            Box(
                Modifier
                    .size(width = 54.dp, height = 72.dp)
                    .clip(RoundedCornerShape(VoiidRadius.sm)),
            ) {
                val customBitmap = remember(edit.customCoverJpeg) {
                    edit.customCoverJpeg?.let {
                        android.graphics.BitmapFactory.decodeByteArray(it, 0, it.size)
                    }
                }
                val shown = customBitmap ?: preview
                shown?.let {
                    androidx.compose.foundation.Image(
                        bitmap = it.asImageBitmap(),
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                } ?: ClipShimmer(Modifier.fillMaxSize())
            }

            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                if (edit.customCoverJpeg == null) {
                    Text(
                        "Use current frame",
                        style = VoiidFont.rounded(15),
                        color = VoiidColor.primary,
                        modifier = Modifier.softClickable(scale = 0.95f) {
                            haptics.tap()
                            onEditChange(edit.copy(coverMs = scrubMs))
                        },
                    )
                } else {
                    Text(
                        "Custom image",
                        style = VoiidFont.rounded(15),
                        color = VoiidColor.textPrimary,
                    )
                }
                Text(
                    if (edit.customCoverJpeg == null) "Upload an image" else "Change image",
                    style = VoiidFont.rounded(15),
                    color = VoiidColor.primary,
                    modifier = Modifier.softClickable(scale = 0.95f) {
                        haptics.tap()
                        coverPicker.launch(
                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                        )
                    },
                )
            }
        }

        // The scrubber is meaningless while a custom image is in force — hide it rather
        // than leave a control that silently does nothing.
        if (durationMs > 0 && edit.customCoverJpeg == null) {
            Slider(
                value = scrubMs.toFloat(),
                onValueChange = { scrubMs = it.toLong() },
                valueRange = 0f..durationMs.toFloat(),
                colors = SliderDefaults.colors(
                    thumbColor = VoiidColor.accent,
                    activeTrackColor = VoiidColor.accent,
                ),
            )
        }

        // Filters
        Text("Filters", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(ClipFilter.entries.toList()) { f ->
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                    modifier = Modifier.softClickable(scale = 0.95f) {
                        haptics.tap()
                        onEditChange(edit.copy(filter = f))
                    },
                ) {
                    Box(
                        Modifier
                            .size(width = 54.dp, height = 72.dp)
                            .clip(RoundedCornerShape(VoiidRadius.sm))
                            .border(
                                width = if (edit.filter == f) 2.dp else 0.dp,
                                color = if (edit.filter == f) VoiidColor.primary else Color.Transparent,
                                shape = RoundedCornerShape(VoiidRadius.sm),
                            ),
                    ) {
                        filterThumbs[f]?.let {
                            androidx.compose.foundation.Image(
                                bitmap = it.asImageBitmap(),
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize(),
                            )
                        } ?: ClipShimmer(Modifier.fillMaxSize())
                    }
                    Text(
                        f.label,
                        style = VoiidFont.rounded(10, FontWeight.Medium),
                        color = if (edit.filter == f) VoiidColor.primary else VoiidColor.textSecondary,
                    )
                }
            }
        }

        Spacer(Modifier.height(8.dp))
        VoiidPrimaryButton(title = "Next", enabled = edit.durationMs >= 500) { onNext() }
        Spacer(Modifier.height(24.dp))
    }
}

/**
 * Re-encode the picked image to a bounded JPEG. An 8 MB HEIC straight from the gallery
 * would be a 200x heavier grid tile than the frames it sits beside.
 */
private fun loadCustomCover(context: Context, uri: android.net.Uri): ByteArray? = runCatching {
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

@Composable
private fun LabeledSlider(
    label: String,
    value: Float,
    min: Float,
    max: Float,
    onChange: (Float) -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            label,
            style = VoiidFont.rounded(12),
            color = VoiidColor.textSecondary,
            modifier = Modifier.width(40.dp),
        )
        Slider(
            value = value.coerceIn(min, max.coerceAtLeast(min + 1f)),
            onValueChange = onChange,
            valueRange = min..max.coerceAtLeast(min + 1f),
            colors = SliderDefaults.colors(
                thumbColor = VoiidColor.primary,
                activeTrackColor = VoiidColor.primary,
            ),
            modifier = Modifier.weight(1f),
        )
    }
}

/** Details & Post — caption, the public-content notice, and the Post button. */
@Composable
fun ClipDetailsView(
    sourceFile: File,
    edit: ClipEdit,
    onPost: (String) -> Unit,
) {
    var caption by remember { mutableStateOf("") }
    var cover by remember { mutableStateOf<Bitmap?>(null) }

    LaunchedEffect(sourceFile, edit.coverMs, edit.filter, edit.customCoverJpeg) {
        // Mirror the exporter's precedence exactly: an uploaded image wins over the frame
        // picker, so what the author confirms here is what the grid will show.
        val custom = edit.customCoverJpeg
        cover = if (custom != null) {
            withContext(Dispatchers.IO) {
                android.graphics.BitmapFactory.decodeByteArray(custom, 0, custom.size)
            }
        } else {
            withContext(Dispatchers.IO) { ClipExporter.frameBitmap(sourceFile, edit.coverMs) }
                ?.let { edit.filter.applyToBitmap(it) }
        }
    }

    Column(
        Modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(VoiidRadius.lg))
                .background(VoiidColor.surfaceCard)
                .padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Box(
                Modifier
                    .size(width = 84.dp, height = 112.dp)
                    .clip(RoundedCornerShape(VoiidRadius.md)),
            ) {
                cover?.let {
                    androidx.compose.foundation.Image(
                        bitmap = it.asImageBitmap(),
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                } ?: ClipShimmer(Modifier.fillMaxSize())
            }
            androidx.compose.foundation.text.BasicTextField(
                value = caption,
                onValueChange = { caption = it },
                textStyle = VoiidFont.rounded(16).copy(color = VoiidColor.textPrimary),
                cursorBrush = androidx.compose.ui.graphics.SolidColor(VoiidColor.primary),
                modifier = Modifier.weight(1f),
                decorationBox = { inner ->
                    if (caption.isEmpty()) {
                        Text(
                            "Write a caption…",
                            style = VoiidFont.rounded(16),
                            color = VoiidColor.placeholder,
                        )
                    }
                    inner()
                },
            )
        }

        // Clips are public and NOT encrypted (docs/CLIPS.md §0). Say so here rather than
        // letting a user assume the messaging guarantee carries over.
        Text(
            "Clips are public. Unlike your chats and moments, they aren't end-to-end encrypted.",
            style = VoiidFont.rounded(12),
            color = VoiidColor.textSecondary,
        )

        Spacer(Modifier.weight(1f))
        VoiidPrimaryButton(title = "Post", enabled = true) { onPost(caption) }
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
