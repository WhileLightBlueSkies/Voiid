package com.voiid.app.main.clips

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
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
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
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
 *     [1] Camera (or an import from it)  ->  [2] Edit  ->  [3] Details & Post
 *
 * Port of iOS `ClipComposerFlow.swift`. Deliberately NOT a bottom sheet: the old
 * `ClipsSheets.kt` composer was a popup that discarded the picked video, and a sheet
 * cannot host a trim scrubber and a filter strip without becoming a scroll-fight.
 *
 * CAMERA FIRST. There used to be a SOURCE step — two big Camera/Gallery tiles — before
 * anything could happen. That is a whole screen and a decision charged to every clip, when the
 * answer is "camera" almost every time; the gallery now lives as a corner tile inside the
 * viewfinder, which is where the alternative belongs. So the camera is not a step in this
 * stack: it is the front door, and EDIT backs out to it.
 */
enum class ClipComposerStep { EDIT, DETAILS }

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

    var step by remember { mutableStateOf(ClipComposerStep.EDIT) }
    var sourceFile by remember { mutableStateOf<File?>(null) }
    var edit by remember { mutableStateOf(ClipEdit()) }
    var preparing by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }

    // Recording happens IN-APP via ClipCameraView (CameraX VideoCapture), replacing the system
    // camera intent this used to launch. The intent worked, but it is somebody else's UI: no
    // timer we control, no cap indication, no multi-take, and no route to ever put the filter
    // strip in the live preview. It also had to survive process death mid-capture, which is the
    // whole reason the old target URI was rememberSaveable.
    var showCamera by remember { mutableStateOf(true) }

    /**
     * The single door into the editor, whether the video was just recorded or picked from the
     * gallery — so duration validation and the cap check cannot diverge between the two.
     * [filter] carries the look the author was already watching in the viewfinder.
     */
    fun accept(uri: Uri, filter: ClipFilter = ClipFilter.NONE) {
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
                        // Pre-populated, NOT baked: the camera preview is filtered for display
                        // only and the recording is clean, so the exporter applies the look
                        // exactly once — and the editor's strip can still change its mind.
                        filter = filter,
                    )
                    step = ClipComposerStep.EDIT
                    showCamera = false
                }
            }
        }
    }

    val galleryPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia()
    ) { uri -> uri?.let { accept(it) } }

    if (showCamera) {
        Box(Modifier.fillMaxSize()) {
            ClipCameraView(
                maxSeconds = (ClipCaps.MAX_DURATION_MS / 1000).toInt(),
                onDone = { takes, filter ->
                    scope.launch {
                        preparing = true
                        // Multi-take recordings are joined into the one file the rest of the
                        // composer expects. A single take at 1x returns as-is, no transcode.
                        val joined = withContext(Dispatchers.IO) {
                            ClipSegments.concatenate(context, takes)
                        }
                        preparing = false
                        // The camera stays on screen until the join lands, so a failure drops
                        // the user back into a live viewfinder with their takes still there
                        // rather than onto an empty screen with no way forward.
                        if (joined == null) errorText = "Couldn't save that recording."
                        else accept(Uri.fromFile(joined), filter)
                    }
                },
                // The camera IS the first screen, so closing it closes the composer.
                onClose = onClose,
                onPickGallery = {
                    errorText = null
                    galleryPicker.launch(
                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly)
                    )
                },
            )

            errorText?.let {
                Text(
                    it,
                    style = VoiidFont.rounded(13),
                    color = Color.White,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.align(Alignment.BottomCenter)
                        .navigationBarsPadding()
                        .padding(bottom = 180.dp, start = 32.dp, end = 32.dp)
                        .clip(RoundedCornerShape(VoiidRadius.sm))
                        .background(Color.Black.copy(alpha = 0.7f))
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                )
            }

            if (preparing) {
                Box(
                    Modifier
                        .fillMaxSize()
                        .background(Color.Black.copy(alpha = 0.6f))
                        // A scrim that does not swallow input is a lie: the shutter is still
                        // under it, and tapping it mid-join would start a take whose file lands
                        // after the takes it was meant to follow.
                        .pointerInput(Unit) {
                            awaitPointerEventScope {
                                while (true) {
                                    awaitPointerEvent(PointerEventPass.Initial)
                                        .changes.forEach { it.consume() }
                                }
                            }
                        },
                    contentAlignment = Alignment.Center,
                ) { CircularProgressIndicator(color = Color.White) }
            }
        }
    } else {
        ComposerSteps(
            step = step,
            sourceFile = sourceFile,
            edit = edit,
            onEditChange = { edit = it },
            onStep = { step = it },
            onBackToCamera = {
                errorText = null
                showCamera = true
            },
            onPost = { file, caption ->
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

/** Everything after capture: the header back-stack, the editor and the details screen. */
@Composable
private fun ComposerSteps(
    step: ClipComposerStep,
    sourceFile: File?,
    edit: ClipEdit,
    onEditChange: (ClipEdit) -> Unit,
    onStep: (ClipComposerStep) -> Unit,
    onBackToCamera: () -> Unit,
    onPost: (File, String) -> Unit,
) {
    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
        // Header with a real back stack. EDIT backs out to the camera, which is where the
        // clip came from — there is no source step to return to any more.
        Row(
            Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Default.ArrowBack, "Back", tint = VoiidColor.textPrimary,
                modifier = Modifier.size(24.dp).softClickable(scale = 0.9f) {
                    when (step) {
                        ClipComposerStep.EDIT -> onBackToCamera()
                        ClipComposerStep.DETAILS -> onStep(ClipComposerStep.EDIT)
                    }
                },
            )
            Spacer(Modifier.weight(1f))
            Text(
                when (step) {
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
            ClipComposerStep.EDIT -> sourceFile?.let { file ->
                ClipEditorView(
                    sourceFile = file,
                    edit = edit,
                    onEditChange = onEditChange,
                    onNext = { onStep(ClipComposerStep.DETAILS) },
                )
            }

            ClipComposerStep.DETAILS -> sourceFile?.let { file ->
                ClipDetailsView(
                    sourceFile = file,
                    edit = edit,
                    onPost = { caption -> onPost(file, caption) },
                )
            }
        }
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
