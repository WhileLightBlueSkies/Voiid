package com.voiid.app.main.clips

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.MediaStore
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.core.net.toUri
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.voiid.app.model.ClipsStore
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

/**
 * The clip upload flow — a full-screen, multi-step flow with a real back stack:
 *
 *     [1] Source  ->  [2] Capture / Pick  ->  [3] Edit  ->  [4] Details & Post
 *
 * Port of iOS `ClipComposerFlow.swift`. Deliberately NOT a bottom sheet: the old
 * `ClipsSheets.kt` composer was a popup that discarded the picked video, and a sheet
 * cannot host a trim scrubber and a filter strip without becoming a scroll-fight.
 */
enum class ClipComposerStep { SOURCE, EDIT, DETAILS }

/** Mirrors MAX_DURATION_MS / MAX_BYTE_SIZE in backend/api/src/routes/clips.ts. */
object ClipCaps {
    const val MAX_DURATION_MS = 90_000L
    const val MAX_BYTES = 100L * 1024 * 1024
}

@Composable
fun ClipComposerFlow(
    clips: ClipsStore,
    myUserId: String,
    myName: String,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val haptics = LocalVoiidHaptics.current

    var step by remember { mutableStateOf(ClipComposerStep.SOURCE) }
    var sourceFile by remember { mutableStateOf<File?>(null) }
    var edit by remember { mutableStateOf(ClipEdit()) }
    var preparing by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }

    fun accept(uri: Uri) {
        scope.launch {
            preparing = true
            errorText = null
            val result = withContext(Dispatchers.IO) { copyAndProbe(context, uri) }
            preparing = false
            when {
                result == null -> errorText = "Couldn't read that video."
                result.durationMs > ClipCaps.MAX_DURATION_MS + 1000 ->
                    // Validate BEFORE the user invests time in the editor — telling
                    // someone their 4-minute video is too long only at Post is the
                    // wrong order.
                    errorText = "Clips can be up to 90 seconds. Trim it and try again."
                else -> {
                    sourceFile = result.file
                    edit = ClipEdit(
                        trimStartMs = 0,
                        trimEndMs = minOf(result.durationMs, ClipCaps.MAX_DURATION_MS),
                    )
                    step = ClipComposerStep.EDIT
                }
            }
        }
    }

    val galleryPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia()
    ) { uri -> uri?.let { accept(it) } }

    // Recording now happens IN-APP via ClipCameraView (CameraX VideoCapture), replacing the
    // system camera intent this used to launch. The intent worked, but it is somebody else's
    // UI: no timer we control, no cap indication, no multi-take, and no route to ever put the
    // filter strip in the live preview. It also had to survive process death mid-capture,
    // which is the whole reason the old target URI was rememberSaveable.
    var showCamera by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
        // Header with a real back stack.
        Row(
            Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Default.ArrowBack, "Back", tint = VoiidColor.textPrimary,
                modifier = Modifier.size(24.dp).softClickable(scale = 0.9f) {
                    when (step) {
                        ClipComposerStep.SOURCE -> onClose()
                        ClipComposerStep.EDIT -> step = ClipComposerStep.SOURCE
                        ClipComposerStep.DETAILS -> step = ClipComposerStep.EDIT
                    }
                },
            )
            Spacer(Modifier.weight(1f))
            Text(
                when (step) {
                    ClipComposerStep.SOURCE -> "New clip"
                    ClipComposerStep.EDIT -> "Edit"
                    ClipComposerStep.DETAILS -> "Details"
                },
                style = VoiidFont.rounded(17, FontWeight.SemiBold),
                color = VoiidColor.textPrimary,
            )
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.size(24.dp))
        }

        when (step) {
            ClipComposerStep.SOURCE -> SourceScreen(
                preparing = preparing,
                errorText = errorText,
                onCamera = {
                    haptics.tap()
                    errorText = null
                    showCamera = true
                },
                onGallery = {
                    haptics.tap()
                    galleryPicker.launch(
                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly)
                    )
                },
            )

            ClipComposerStep.EDIT -> sourceFile?.let { file ->
                ClipEditorView(
                    sourceFile = file,
                    edit = edit,
                    onEditChange = { edit = it },
                    onNext = { step = ClipComposerStep.DETAILS },
                )
            }

            ClipComposerStep.DETAILS -> sourceFile?.let { file ->
                ClipDetailsView(
                    sourceFile = file,
                    edit = edit,
                    onPost = { caption ->
                        haptics.success()
                        // Hand the work to the STORE first, then dismiss. The store owns it on
                        // viewModelScope, which outlives this composable — the previous version
                        // launched the export on this composable's own scope and then called
                        // onClose(), cancelling the export a frame later, so nothing ever
                        // uploaded. Never start work on a composable scope that has to survive
                        // that composable's dismissal.
                        clips.post(
                            sourceFile = file,
                            edit = edit,
                            caption = caption.trim().ifEmpty { null },
                            authorId = myUserId,
                            authorName = myName,
                        )
                        onClose()
                    },
                )
            }
        }
    }

    // Full-screen overlay above the flow, not a step in it: the camera has its own back
    // behaviour (discard takes) and must not land in the SOURCE -> EDIT -> DETAILS stack.
    if (showCamera) {
        ClipCameraView(
            maxSeconds = (ClipCaps.MAX_DURATION_MS / 1000).toInt(),
            onDone = { takes ->
                showCamera = false
                scope.launch {
                    preparing = true
                    // Multi-take recordings are joined into the one file the rest of the
                    // composer expects. Single-take returns as-is, no transcode.
                    val joined = withContext(Dispatchers.IO) {
                        ClipSegments.concatenate(context, takes)
                    }
                    preparing = false
                    if (joined == null) errorText = "Couldn't save that recording."
                    else accept(Uri.fromFile(joined))
                }
            },
            onClose = { showCamera = false },
        )
    }
}

@Composable
private fun SourceScreen(
    preparing: Boolean,
    errorText: String?,
    onCamera: () -> Unit,
    onGallery: () -> Unit,
) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Column(Modifier.fillMaxWidth().padding(bottom = 4.dp)) {
            Text(
                "Create a clip",
                style = VoiidFont.rounded(28, FontWeight.Bold),
                color = VoiidColor.textPrimary,
            )
            Text(
                "Record something new, or pick a video you already have.",
                style = VoiidFont.rounded(15),
                color = VoiidColor.textSecondary,
            )
        }
        SourceCard(
            Icons.Default.Videocam, "Camera", "Record up to 90 seconds",
            listOf(VoiidColor.primary, VoiidColor.primary.copy(alpha = 0.72f)), onCamera,
        )
        SourceCard(
            Icons.Default.PhotoLibrary, "Gallery", "Choose an existing video",
            listOf(VoiidColor.accent, VoiidColor.accent.copy(alpha = 0.72f)), onGallery,
        )

        if (preparing) {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = VoiidColor.primary)
            }
        }
        if (errorText != null) {
            Text(
                errorText,
                style = VoiidFont.rounded(12),
                color = VoiidColor.error,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/**
 * A tall gradient tile rather than a plain list row. The two sources are the entire first
 * screen of the flow, so they should read as the choice — a thin row with a chevron reads
 * as settings. Mirrors the iOS `sourceCardLabel`.
 */
@Composable
private fun SourceCard(
    icon: ImageVector,
    title: String,
    subtitle: String,
    tint: List<Color>,
    onTap: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .height(168.dp)
            .clip(RoundedCornerShape(22.dp))
            .background(Brush.linearGradient(tint))
            .softClickable(scale = 0.98f) { onTap() }
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            Modifier
                .size(56.dp)
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.22f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, null, tint = Color.White, modifier = Modifier.size(26.dp))
        }
        Spacer(Modifier.weight(1f))
        Text(title, style = VoiidFont.rounded(20, FontWeight.Bold), color = Color.White)
        Text(
            subtitle,
            style = VoiidFont.rounded(12),
            color = Color.White.copy(alpha = 0.85f),
        )
    }
}

/** Copy the picked/captured content into app storage and read its duration. */
private data class Probed(val file: File, val durationMs: Long)

private fun copyAndProbe(context: Context, uri: Uri): Probed? = runCatching {
    val out = File(context.cacheDir, "clip_src_${UUID.randomUUID()}.mp4")
    context.contentResolver.openInputStream(uri)?.use { input ->
        out.outputStream().use { input.copyTo(it) }
    } ?: return null

    val retriever = MediaMetadataRetriever()
    retriever.setDataSource(out.absolutePath)
    val duration = retriever
        .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
    retriever.release()
    if (duration <= 0L) return null
    Probed(out, duration)
}.getOrNull()
