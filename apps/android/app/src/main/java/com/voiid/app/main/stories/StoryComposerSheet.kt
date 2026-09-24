package com.voiid.app.main.stories

import android.content.Context
import android.graphics.Bitmap
import com.voiid.app.main.ChatImageDecoder
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.People
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.StoriesStore
import com.voiid.app.ui.components.VoiidPrimaryButton
import com.voiid.app.ui.components.VoiidTextField
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

/** Prepared, capped media ready to post. */
internal data class ComposerMedia(
    val bytes: ByteArray, val mime: String, val width: Int?, val height: Int?,
    val durationMs: Long?, val preview: ImageBitmap?,
)

/**
 * Story composer: capture-or-pick → preview + caption → audience chip → Share.
 *
 * HARD CAPS enforced here (non-negotiable — `encrypt_media` holds the whole blob in memory twice
 * and there is no streaming encryption): images re-encoded to JPEG, long edge ≤1920, quality 0.8,
 * ≤10 MB; video ≤30 s and ≤50 MB, rejected (not silently trimmed) beyond that. Video is NOT
 * transcoded here (no MediaCodec pipeline in v1) — oversize/over-length selections are refused.
 */
@Composable
fun StoryComposerSheet(
    stories: StoriesStore,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var media by remember { mutableStateOf<ComposerMedia?>(null) }
    var caption by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var showCamera by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }

    // Who it goes to is ONE setting (Moments settings), shown here and changed there.
    var people by remember { mutableStateOf<com.voiid.app.model.MomentSettings.People?>(null) }
    androidx.compose.runtime.LaunchedEffect(showSettings) {
        if (showSettings) return@LaunchedEffect
        com.voiid.app.model.MomentSettings.load(context)
        people = com.voiid.app.model.MomentSettings.people(context)
    }
    val mode = com.voiid.app.model.MomentSettings.audienceMode
    val audience = people?.let { com.voiid.app.model.MomentSettings.resolved(it) }
    val isPrivate = mode == com.voiid.app.model.MomentAudience.NOBODY
    val audienceLabel = when {
        isPrivate -> "Only you"
        audience == null -> mode.title
        else -> "${mode.title} · ${audience.size}"
    }

    val galleryPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        busy = true
        scope.launch {
            val (m, err) = withContext(Dispatchers.IO) { prepareFromUri(context, uri) }
            media = m; error = err; busy = false
        }
    }

    Box(Modifier.fillMaxSize().background(VoiidColor.background)) {

        when {
            showCamera -> StoryCameraView(
                onCaptured = { photo, video ->
                    showCamera = false
                    when {
                        // A camera take arrives as a file URI and runs through the SAME
                        // preparation as a gallery pick (duration/size caps enforced).
                        video != null -> {
                            busy = true
                            scope.launch {
                                val (m, err) = withContext(Dispatchers.IO) { prepareFromUri(context, video) }
                                media = m; error = err; busy = false
                            }
                        }
                        photo != null -> {
                            busy = true
                            scope.launch {
                                val m = withContext(Dispatchers.IO) { runCatching { prepareImage(photo) }.getOrNull() }
                                media = m; error = when {
                                    m == null -> "Couldn’t read that photo."
                                    m.bytes.size > MAX_IMAGE_BYTES -> "That photo is too large to share."
                                    else -> null
                                }
                                busy = false
                            }
                        }
                        else -> {}
                    }
                },
                onClose = { showCamera = false },
            )

            media == null -> SourceChooser(
                onCamera = { showCamera = true },
                onGallery = { galleryPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)) },
                onClose = onDismiss,
                busy = busy,
                error = error,
            )

            else -> {
                val m = media!!
                Column(Modifier.fillMaxSize()) {
                    // Preview
                    Box(Modifier.fillMaxWidth().weight(1f).background(Color.Black), contentAlignment = Alignment.Center) {
                        m.preview?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit) }
                        Box(
                            Modifier.align(Alignment.TopStart).statusBarsPadding().padding(16.dp)
                                .size(40.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.35f))
                                .softClickable(scale = 0.9f) { media = null; caption = "" },
                            contentAlignment = Alignment.Center,
                        ) { Icon(Icons.Default.Close, "Discard", tint = Color.White) }
                    }
                    // Controls
                    Column(
                        Modifier.fillMaxWidth().background(VoiidColor.background)
                            .navigationBarsPadding().padding(20.dp),
                        verticalArrangement = Arrangement.spacedBy(14.dp),
                    ) {
                        VoiidTextField(placeholder = "Add a caption…", value = caption, onValueChange = { caption = it })
                        Row(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(999.dp))
                                .background(VoiidColor.fieldFill).softClickable { showSettings = true }
                                .padding(horizontal = 16.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Icon(if (isPrivate) Icons.Default.Lock else Icons.Default.People, null,
                                tint = VoiidColor.primary, modifier = Modifier.size(18.dp))
                            Text(audienceLabel, style = VoiidFont.rounded(14, FontWeight.SemiBold), color = VoiidColor.textPrimary,
                                modifier = Modifier.weight(1f))
                            Text("Change", style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.accentInk)
                        }
                        error?.let { Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error) }
                        if (!isPrivate && audience != null && audience.isEmpty()) {
                            Text("No one is in this audience yet. Change who can see your moments, or choose Nobody to keep it for yourself.",
                                style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                        }
                        VoiidPrimaryButton(
                            title = if (isPrivate) "Save for me" else "Share",
                            enabled = !busy && (isPrivate || !audience.isNullOrEmpty()),
                        ) {
                            if (isPrivate) {
                                stories.savePrivately(m.bytes, m.mime, caption.trim(), m.width, m.height, m.durationMs)
                            } else {
                                stories.post(
                                    m.bytes, m.mime, caption.trim(), m.width, m.height, m.durationMs,
                                    allowsReplies = true, audienceUserIds = audience.orEmpty(),
                                )
                            }
                            onDismiss()
                        }
                    }
                }
            }
        }

        if (busy && !showCamera && media == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = VoiidColor.primary)
            }
        }
    }

    if (showSettings) MomentsSettingsScreen(onClose = { showSettings = false })
}

@Composable
private fun SourceChooser(
    onCamera: () -> Unit,
    onGallery: () -> Unit,
    onClose: () -> Unit,
    busy: Boolean,
    error: String?,
) {
    Column(Modifier.fillMaxSize().statusBarsPadding().padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("New moment", style = VoiidFont.rounded(22, FontWeight.Bold), color = VoiidColor.textPrimary)
            Spacer(Modifier.weight(1f))
            Icon(Icons.Default.Close, "Close", tint = VoiidColor.textPrimary, modifier = Modifier.size(26.dp).softClickable(scale = 0.9f) { onClose() })
        }
        error?.let { Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error) }
        Row(Modifier.fillMaxWidth().weight(1f), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            SourceCard(Icons.Default.CameraAlt, "Camera", Modifier.weight(1f), onCamera)
            SourceCard(Icons.Default.PhotoLibrary, "Gallery", Modifier.weight(1f), onGallery)
        }
        if (busy) CircularProgressIndicator(color = VoiidColor.primary, modifier = Modifier.align(Alignment.CenterHorizontally))
    }
}

@Composable
private fun SourceCard(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, modifier: Modifier, onClick: () -> Unit) {
    Column(
        modifier.fillMaxSize().clip(RoundedCornerShape(20.dp)).background(VoiidColor.fieldFill)
            .softClickable(scale = 0.97f, onClick = onClick),
        verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(icon, null, tint = VoiidColor.primary, modifier = Modifier.size(48.dp))
        Spacer(Modifier.size(10.dp))
        Text(label, style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
    }
}

// MARK: - Media preparation (off the main thread)

private const val MAX_IMAGE_BYTES = 10 * 1024 * 1024
private const val MAX_VIDEO_BYTES = 50 * 1024 * 1024
private const val MAX_VIDEO_MS = 30_000L

private fun prepareFromUri(context: Context, uri: Uri): Pair<ComposerMedia?, String?> {
    val mime = context.contentResolver.getType(uri) ?: "application/octet-stream"
    val bytes = runCatching { context.contentResolver.openInputStream(uri)?.use { com.voiid.app.net.StoryMediaLimits.readBounded(it, com.voiid.app.net.StoryMediaLimits.MAX_SOURCE_BYTES) } }.getOrNull()
        ?: return null to "Couldn’t read that file. Choose media under 50 MB."
    return when {
        mime.startsWith("image/") -> runCatching { prepareImage(bytes) to null }
            .getOrElse { null to "Couldn’t read that photo." }
        mime.startsWith("video/") -> prepareVideo(context, uri, bytes, mime)
        else -> null to "Unsupported file type."
    }
}

/** Re-encode an image to JPEG, long edge ≤1920, quality 0.8, and RE-CHECK the 10MB cap after
 *  encoding — stepping quality down until the encoded bytes fit (or giving up at q0.3, where
 *  the caller reports the size honestly instead of uploading an oversized blob). */
internal fun prepareImage(input: ByteArray): ComposerMedia {
    // Bake EXIF/HEIF orientation into the pixels before JPEG encoding removes metadata.
    val src = requireNotNull(ChatImageDecoder.decode(input)) { "Couldn’t read that photo." }
    val longEdge = maxOf(src.width, src.height)
    val scale = if (longEdge > 1920) 1920f / longEdge else 1f
    val scaled = if (scale < 1f) {
        Bitmap.createScaledBitmap(src, (src.width * scale).toInt(), (src.height * scale).toInt(), true)
    } else src
    if (scaled !== src) src.recycle()
    var bytes = ByteArrayOutputStream().also { scaled.compress(Bitmap.CompressFormat.JPEG, 80, it) }.toByteArray()
    var quality = 80
    while (bytes.size > MAX_IMAGE_BYTES && quality > 30) {
        quality -= 10
        bytes = ByteArrayOutputStream().also { scaled.compress(Bitmap.CompressFormat.JPEG, quality, it) }.toByteArray()
    }
    return ComposerMedia(bytes, "image/jpeg", scaled.width, scaled.height, null, scaled.asImageBitmap())
}

private fun prepareVideo(context: Context, uri: Uri, bytes: ByteArray, mime: String): Pair<ComposerMedia?, String?> {
    if (bytes.size > MAX_VIDEO_BYTES) return null to "That video is too large (max 50 MB)."
    val retriever = MediaMetadataRetriever()
    return runCatching {
        retriever.setDataSource(context, uri)
        val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        if (durationMs > MAX_VIDEO_MS) return null to "Moments can be up to 30 seconds."
        val w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
        val h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
        val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
        val swapAxes = rotation % 180 != 0
        val frame = retriever.getFrameAtTime(0)
        // Keep the original video rotation metadata; only report its displayed dimensions.
        ComposerMedia(bytes, mime, if (swapAxes) h else w, if (swapAxes) w else h, durationMs, frame?.asImageBitmap()) to null
    }.getOrElse { null to "Couldn't read that video." }.also { runCatching { retriever.release() } }
}
