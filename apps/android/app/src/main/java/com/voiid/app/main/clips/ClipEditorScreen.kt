@file:androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])

package com.voiid.app.main.clips

import android.graphics.Bitmap
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FilterVintage
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material.icons.filled.ContentCut
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.abs
import kotlin.math.roundToInt

/** The trays the editor opens from the bottom. */
enum class ClipEditPanel { TRIM, FILTERS, COVER }

/**
 * Step 2 of posting a clip: the editor. Port of iOS ClipEditorScreen.swift, built to the Voiid
 * Ui reference (Chat/ClipEditScreen.swift).
 *
 * THE CLIP IS THE SCREEN. Same frame as the recorder: the clip plays full-bleed and loops, and
 * the tools sit in the same right-hand column — Text, Trim, Filters, Cover, Sound. Trim,
 * Filters and Cover open as a tray from the bottom with the clip still in view above it; text
 * is typed over the clip, dragged where it goes, and dragged onto the bin to delete.
 *
 * TEXT IS LAID OUT ON THE VIDEO, NOT THE SCREEN. The video fills the screen, so its edges are
 * cropped off. Text positions are fractions of the VIDEO frame, placed here inside the video's
 * on-screen rect, so what you see is where the export burns it in.
 */
@Composable
fun ClipEditorScreen(
    sourceFile: File,
    edit: ClipEdit,
    onEditChange: (ClipEdit) -> Unit,
    /** Set by Post's "Edit cover" so the editor opens straight on the cover tray. */
    openPanel: ClipEditPanel?,
    onPanelOpened: () -> Unit,
    onBack: () -> Unit,
    onNext: () -> Unit,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    // The drag and tap handlers below outlive recompositions; they read the edit through this.
    val current by rememberUpdatedState(edit)

    var durationMs by remember { mutableStateOf(0L) }
    var videoSize by remember { mutableStateOf(1080 to 1920) }
    var loaded by remember { mutableStateOf(false) }
    var playing by remember { mutableStateOf(true) }
    var positionMs by remember { mutableStateOf(0L) }
    val filmstrip = remember { mutableStateListOf<Bitmap>() }
    val filterThumbs = remember { mutableStateMapOf<ClipFilter, Bitmap>() }
    var coverPreview by remember { mutableStateOf<Bitmap?>(null) }

    var panel by remember { mutableStateOf<ClipEditPanel?>(null) }
    var toast by remember { mutableStateOf<String?>(null) }
    var typing by remember { mutableStateOf<ClipTextOverlay?>(null) }
    var draggingText by remember { mutableStateOf<String?>(null) }
    var dragOffset by remember { mutableStateOf(Offset.Zero) }
    var overBin by remember { mutableStateOf(false) }

    val player = remember {
        ExoPlayer.Builder(context).build().apply {
            repeatMode = Player.REPEAT_MODE_ONE
            playWhenReady = true
        }
    }
    DisposableEffect(Unit) { onDispose { player.release() } }
    DisposableEffect(player) {
        val l = object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) { playing = isPlaying }
        }
        player.addListener(l)
        onDispose { player.removeListener(l) }
    }
    // A player left running behind a backgrounded app keeps decoding for nothing.
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_PAUSE -> player.pause()
                Lifecycle.Event.ON_RESUME -> if (panel != ClipEditPanel.COVER && typing == null) player.play()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // The range the player loops. Separate from edit.trim*: a clipping change rebuilds the
    // media item, so it is committed when a trim handle is RELEASED, not on every pixel.
    var loopRange by remember { mutableStateOf<Pair<Long, Long>?>(null) }

    LaunchedEffect(sourceFile) {
        durationMs = withContext(Dispatchers.IO) { ClipExporter.durationMs(sourceFile) }
        val (w, h) = withContext(Dispatchers.IO) { ClipExporter.uprightSize(sourceFile) }
        if (w > 0 && h > 0) videoSize = w to h
        val end = if (edit.trimEndMs <= 0L || edit.trimEndMs > durationMs)
            minOf(durationMs, edit.trimStartMs + ClipCaps.MAX_DURATION_MS) else edit.trimEndMs
        if (end != edit.trimEndMs) onEditChange(edit.copy(trimEndMs = end))
        loopRange = edit.trimStartMs to end
        loaded = true

        val frames = withContext(Dispatchers.IO) {
            (0 until 12).mapNotNull { i ->
                ClipExporter.frameBitmap(sourceFile, durationMs * i / 12)?.let { downscale(it) }
            }
        }
        filmstrip.clear()
        filmstrip.addAll(frames)
        // One decode, every look applied to it.
        val base = withContext(Dispatchers.IO) {
            ClipExporter.frameBitmap(sourceFile, edit.trimStartMs.coerceAtLeast(100))?.let { downscale(it) }
        }
        if (base != null) ClipFilter.entries.forEach { f -> filterThumbs[f] = f.applyToBitmap(base) }
    }

    LaunchedEffect(loopRange, edit.filter) {
        val range = loopRange ?: return@LaunchedEffect
        // Effects before prepare(): media3 wires the effect chain in at preparation. This is
        // the same chain the exporter bakes in, so the preview is the look you post.
        player.setVideoEffects(edit.filter.effects())
        player.setMediaItem(
            MediaItem.Builder()
                .setUri(android.net.Uri.fromFile(sourceFile))
                .setClippingConfiguration(
                    MediaItem.ClippingConfiguration.Builder()
                        .setStartPositionMs(range.first)
                        .setEndPositionMs(range.second)
                        .build()
                )
                .build()
        )
        player.prepare()
        if (panel == ClipEditPanel.COVER || typing != null) player.pause() else player.play()
    }

    LaunchedEffect(edit.muted) { player.volume = if (edit.muted) 0f else 1f }

    // Playback progress for the line above the bottom bar.
    LaunchedEffect(player) {
        while (true) {
            positionMs = player.currentPosition
            delay(50)
        }
    }

    LaunchedEffect(edit.coverMs, edit.filter) {
        delay(60) // only the newest request lands while the cover is being dragged
        coverPreview = withContext(Dispatchers.IO) {
            ClipExporter.frameBitmap(sourceFile, edit.coverMs)?.let { edit.filter.applyToBitmap(downscale(it)) }
        }
    }

    val customCover = remember(edit.customCoverJpeg) {
        edit.customCoverJpeg?.let { android.graphics.BitmapFactory.decodeByteArray(it, 0, it.size) }
    }

    val coverPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        scope.launch {
            val jpeg = withContext(Dispatchers.IO) { loadCustomCover(context, uri) }
            if (jpeg != null) {
                onEditChange(current.copy(customCoverJpeg = jpeg))
                haptics.success()
            }
        }
    }

    fun flash(text: String) {
        toast = text
        scope.launch {
            delay(1300)
            if (toast == text) toast = null
        }
    }

    fun open(p: ClipEditPanel) {
        panel = p
        // The cover is a still: hold the video on it. The other trays keep it playing.
        if (p == ClipEditPanel.COVER) player.pause()
    }

    fun closePanel() {
        panel = null
        if (typing == null) player.play()
    }

    LaunchedEffect(openPanel, loaded) {
        if (openPanel != null && loaded) {
            open(openPanel)
            onPanelOpened()
        }
    }

    fun finishTyping(done: ClipTextOverlay) {
        val text = done.text.trim()
        val list = current.texts.toMutableList()
        val i = list.indexOfFirst { it.id == done.id }
        if (i >= 0) {
            if (text.isEmpty()) list.removeAt(i) else list[i] = done
        } else if (text.isNotEmpty()) {
            list.add(done)
        }
        onEditChange(current.copy(texts = list))
        typing = null
        player.play()
    }

    BackHandler(enabled = typing != null || panel != null) {
        typing?.let { finishTyping(it) } ?: closePanel()
    }

    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black)) {
        val screenW = constraints.maxWidth.toFloat()
        val screenH = constraints.maxHeight.toFloat()
        // Where the aspect-filled video actually sits on screen, overflow included.
        val scale = maxOf(screenW / videoSize.first, screenH / videoSize.second)
        val rectW = videoSize.first * scale
        val rectH = videoSize.second * scale
        val rectX = (screenW - rectW) / 2
        val rectY = (screenH - rectH) / 2
        val frameWidthDp = with(density) { rectW.toDp() }

        AndroidView(
            factory = { ctx ->
                PlayerView(ctx).apply {
                    useController = false
                    this.player = player
                    resizeMode = AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                    setShutterBackgroundColor(android.graphics.Color.BLACK)
                }
            },
            modifier = Modifier.fillMaxSize(),
        )

        // Choosing a cover shows THE COVER, still, as the grid will.
        val still = customCover ?: coverPreview
        if (panel == ClipEditPanel.COVER && still != null) {
            Image(still.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
        if (!loaded) ClipShimmer(Modifier.fillMaxSize())

        Box(Modifier.fillMaxSize().pointerInput(Unit) {
            detectTapGestures {
                if (panel != null) { closePanel(); return@detectTapGestures }
                haptics.tap()
                if (player.isPlaying) player.pause() else player.play()
            }
        })

        // Text sits on the video frame, where it will be burned in.
        edit.texts.forEach { item ->
            val isDragging = draggingText == item.id
            key(item.id) {
                ClipTextLabel(
                    item, frameWidthDp,
                    modifier = Modifier
                        .layout { measurable, c ->
                            val p = measurable.measure(c.copy(minWidth = 0, minHeight = 0))
                            layout(p.width, p.height) {
                                val cx = rectX + item.x * rectW + if (isDragging) dragOffset.x else 0f
                                val cy = rectY + item.y * rectH + if (isDragging) dragOffset.y else 0f
                                p.place((cx - p.width / 2f).roundToInt(), (cy - p.height / 2f).roundToInt())
                            }
                        }
                        .scale(if (isDragging && overBin) 0.6f else 1f)
                        .alpha(if (typing?.id == item.id) 0f else if (isDragging && overBin) 0.5f else 1f)
                        .pointerInput(item.id, panel) {
                            if (panel != null) return@pointerInput
                            detectTapGestures {
                                haptics.tap()
                                player.pause()
                                typing = item
                            }
                        }
                        .pointerInput(item.id, panel, rectW, rectH) {
                            if (panel != null) return@pointerInput
                            val binReach = 50.dp.toPx()
                            val binTop = screenH - 150.dp.toPx()
                            detectDragGestures(
                                onDragStart = {
                                    player.pause()
                                    draggingText = item.id
                                    dragOffset = Offset.Zero
                                },
                                onDrag = { change, amount ->
                                    change.consume()
                                    dragOffset += amount
                                    val live = current.texts.firstOrNull { it.id == item.id } ?: return@detectDragGestures
                                    val cx = rectX + live.x * rectW + dragOffset.x
                                    val cy = rectY + live.y * rectH + dragOffset.y
                                    val near = abs(cx - screenW / 2) < binReach && cy > binTop
                                    if (near != overBin) {
                                        overBin = near
                                        if (near) haptics.selection()
                                    }
                                },
                                onDragEnd = {
                                    val live = current.texts.firstOrNull { it.id == item.id }
                                    if (overBin) {
                                        haptics.tap()
                                        onEditChange(current.copy(texts = current.texts.filterNot { it.id == item.id }))
                                    } else if (live != null && rectW > 0) {
                                        // Kept inside the part of the video that is on screen.
                                        val lowX = maxOf(0f, -rectX / rectW) + 0.05f
                                        val highX = minOf(1f, (screenW - rectX) / rectW) - 0.05f
                                        val lowY = maxOf(0f, -rectY / rectH) + 0.06f
                                        val highY = minOf(1f, (screenH - rectY) / rectH) - 0.08f
                                        val nx = (live.x + dragOffset.x / rectW).coerceIn(lowX, highX)
                                        val ny = (live.y + dragOffset.y / rectH).coerceIn(lowY, highY)
                                        onEditChange(current.copy(texts = current.texts.map {
                                            if (it.id == item.id) it.copy(x = nx, y = ny) else it
                                        }))
                                    }
                                    draggingText = null
                                    dragOffset = Offset.Zero
                                    overBin = false
                                    player.play()
                                },
                                onDragCancel = {
                                    draggingText = null
                                    dragOffset = Offset.Zero
                                    overBin = false
                                    player.play()
                                },
                            )
                        },
                )
            }
        }

        if (loaded && !playing && panel == null && typing == null && draggingText == null) {
            Box(Modifier.align(Alignment.Center).size(76.dp).clip(CircleShape)
                .background(Color.Black.copy(alpha = 0.4f)), contentAlignment = Alignment.Center) {
                Icon(Icons.Default.PlayArrow, "Play", tint = Color.White, modifier = Modifier.size(40.dp))
            }
        }

        if (typing == null) {
            // ── Top: back and the kept length ──────────────────────────────────
            Box(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 14.dp, vertical = 8.dp)) {
                GlassCircle(Icons.AutoMirrored.Filled.ArrowBack, "Back to camera") {
                    player.pause()
                    onBack()
                }
                Text(shortDuration(edit.durationMs), style = VoiidFont.rounded(13, FontWeight.SemiBold),
                    color = Color.White,
                    modifier = Modifier.align(Alignment.Center).clip(RoundedCornerShape(50))
                        .background(Color.Black.copy(alpha = 0.4f)).padding(horizontal = 12.dp, vertical = 6.dp))
            }

            // ── Right: tools ────────────────────────────────────────────────────
            if (panel == null) {
                Column(Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(top = 70.dp, end = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                    horizontalAlignment = Alignment.CenterHorizontally) {
                    EditTool(Icons.Default.TextFields, "Text") {
                        player.pause()
                        typing = ClipTextOverlay(text = "")
                    }
                    val trimmed = durationMs > 0 && edit.durationMs < minOf(durationMs, ClipCaps.MAX_DURATION_MS) - 50
                    EditTool(Icons.Default.ContentCut, "Trim", active = trimmed) { open(ClipEditPanel.TRIM) }
                    EditTool(Icons.Default.FilterVintage,
                        if (edit.filter == ClipFilter.NONE) "Filters" else edit.filter.label,
                        active = edit.filter != ClipFilter.NONE) { open(ClipEditPanel.FILTERS) }
                    EditTool(Icons.Default.Image, "Cover", active = edit.customCoverJpeg != null) { open(ClipEditPanel.COVER) }
                    EditTool(if (edit.muted) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp,
                        if (edit.muted) "Muted" else "Sound", active = edit.muted) {
                        onEditChange(current.copy(muted = !current.muted))
                        flash(if (!current.muted) "Sound off" else "Sound on")
                    }
                }

                // ── Bottom: progress, cover, Next ───────────────────────────────
                Column(
                    Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                        .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.55f))))
                        .navigationBarsPadding()
                        .padding(start = 16.dp, end = 16.dp, top = 50.dp, bottom = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    val t = if (edit.durationMs > 0) positionMs.toFloat() / edit.durationMs else 0f
                    Box(Modifier.fillMaxWidth().height(3.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.25f))) {
                        Box(Modifier.fillMaxHeight().fillMaxWidth(t.coerceIn(0.01f, 1f)).background(Color.White))
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Row(
                            Modifier.clip(RoundedCornerShape(50)).background(Color.Black.copy(alpha = 0.4f))
                                .softClickable(scale = 0.95f) { haptics.tap(); open(ClipEditPanel.COVER) }
                                .padding(start = 6.dp, end = 14.dp, top = 6.dp, bottom = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            Box(Modifier.size(width = 34.dp, height = 48.dp).clip(RoundedCornerShape(7.dp))
                                .border(1.dp, Color.White.copy(alpha = 0.8f), RoundedCornerShape(7.dp))) {
                                if (still != null) Image(still.asImageBitmap(), null, contentScale = ContentScale.Crop,
                                    modifier = Modifier.fillMaxSize())
                                else ClipShimmer(Modifier.fillMaxSize())
                            }
                            Column {
                                Text("Cover", style = VoiidFont.rounded(13, FontWeight.SemiBold), color = Color.White)
                                Text("Tap to change", style = VoiidFont.rounded(11), color = Color.White.copy(alpha = 0.7f))
                            }
                        }
                        Spacer(Modifier.weight(1f))
                        val ready = loaded && edit.durationMs >= 500
                        Row(
                            Modifier.height(48.dp).clip(RoundedCornerShape(50)).background(VoiidColor.accent)
                                .alpha(if (ready) 1f else 0.5f)
                                .softClickable(scale = 0.95f) {
                                    if (!ready) return@softClickable
                                    haptics.success()
                                    player.pause()
                                    onNext()
                                }
                                .padding(horizontal = 24.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Text("Next", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = Color.White)
                            Icon(Icons.Default.ChevronRight, null, tint = Color.White, modifier = Modifier.size(18.dp))
                        }
                    }
                }
            }

            // ── Tray ────────────────────────────────────────────────────────────
            AnimatedVisibility(
                visible = panel != null,
                modifier = Modifier.align(Alignment.BottomCenter),
                enter = slideInVertically { it } + fadeIn(),
                exit = slideOutVertically { it } + fadeOut(),
            ) {
                Column(
                    Modifier.fillMaxWidth()
                        .clip(RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp))
                        .background(Color(0xE6161A1C))
                        .pointerInput(Unit) { detectTapGestures { } }
                        .navigationBarsPadding()
                        .padding(bottom = 8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Spacer(Modifier.height(4.dp))
                    Box(Modifier.size(width = 36.dp, height = 4.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.35f)))
                    Text(when (panel) {
                        ClipEditPanel.TRIM -> "Trim"
                        ClipEditPanel.FILTERS -> "Filters"
                        ClipEditPanel.COVER -> "Choose a cover"
                        null -> ""
                    }, style = VoiidFont.rounded(15, FontWeight.SemiBold), color = Color.White)

                    when (panel) {
                        ClipEditPanel.TRIM -> if (durationMs > 0) Column(Modifier.padding(horizontal = 24.dp),
                            verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            TrimStrip(
                                frames = filmstrip,
                                durationMs = durationMs,
                                startMs = edit.trimStartMs,
                                endMs = edit.trimEndMs,
                                onChange = { start, end -> onEditChange(current.copy(trimStartMs = start, trimEndMs = end)) },
                                onCommit = {
                                    haptics.selection()
                                    val e = current
                                    // Keep the cover inside what will actually be posted.
                                    val cover = e.coverMs.coerceIn(e.trimStartMs, (e.trimEndMs - 100).coerceAtLeast(e.trimStartMs))
                                    if (cover != e.coverMs) onEditChange(e.copy(coverMs = cover))
                                    loopRange = e.trimStartMs to e.trimEndMs
                                },
                            )
                            Row(Modifier.fillMaxWidth()) {
                                Text(clock(edit.trimStartMs), style = VoiidFont.rounded(12, FontWeight.Medium),
                                    color = Color.White.copy(alpha = 0.7f))
                                Spacer(Modifier.weight(1f))
                                Text("${shortDuration(edit.durationMs)} selected", style = VoiidFont.rounded(12, FontWeight.SemiBold),
                                    color = Color.White)
                                Spacer(Modifier.weight(1f))
                                Text(clock(edit.trimEndMs), style = VoiidFont.rounded(12, FontWeight.Medium),
                                    color = Color.White.copy(alpha = 0.7f))
                            }
                        }

                        ClipEditPanel.FILTERS -> LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp),
                            contentPadding = PaddingValues(horizontal = 16.dp)) {
                            items(ClipFilter.entries.toList()) { f ->
                                val on = edit.filter == f
                                Column(Modifier.softClickable(scale = 0.95f) {
                                    haptics.selection()
                                    onEditChange(current.copy(filter = f))
                                }, horizontalAlignment = Alignment.CenterHorizontally) {
                                    Box(Modifier.size(width = 60.dp, height = 80.dp).clip(RoundedCornerShape(12.dp))
                                        .border(if (on) 3.dp else 1.dp, if (on) VoiidColor.accent else Color.White.copy(alpha = 0.25f),
                                            RoundedCornerShape(12.dp))) {
                                        filterThumbs[f]?.let {
                                            Image(it.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                                        } ?: ClipShimmer(Modifier.fillMaxSize())
                                    }
                                    Spacer(Modifier.height(6.dp))
                                    Text(f.label, style = VoiidFont.rounded(11, if (on) FontWeight.Bold else FontWeight.Medium),
                                        color = Color.White.copy(alpha = if (on) 1f else 0.8f))
                                }
                            }
                        }

                        ClipEditPanel.COVER -> Column(Modifier.padding(horizontal = 24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(14.dp)) {
                            if (durationMs > 0) {
                                Box(Modifier.alpha(if (edit.customCoverJpeg == null) 1f else 0.35f)) {
                                    CoverStrip(
                                        frames = filmstrip,
                                        durationMs = durationMs,
                                        coverMs = edit.coverMs,
                                        startMs = edit.trimStartMs,
                                        endMs = edit.trimEndMs,
                                        onChange = { onEditChange(current.copy(coverMs = it, customCoverJpeg = null)) },
                                    )
                                }
                            }
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                TrayChip(if (edit.customCoverJpeg == null) "From gallery" else "Change photo") {
                                    haptics.tap()
                                    coverPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                                }
                                if (edit.customCoverJpeg != null) {
                                    TrayChip("Use a frame") {
                                        haptics.tap()
                                        onEditChange(current.copy(customCoverJpeg = null))
                                    }
                                }
                            }
                        }

                        null -> Unit
                    }

                    Box(Modifier.clip(RoundedCornerShape(50)).background(Color.White)
                        .softClickable(scale = 0.95f) { haptics.tap(); closePanel() }
                        .padding(horizontal = 28.dp, vertical = 11.dp)) {
                        Text("Done", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = Color.Black)
                    }
                }
            }
        }

        // The bin, while a text is being dragged.
        if (draggingText != null) {
            val binSize by animateDpAsState(if (overBin) 64.dp else 52.dp, label = "bin")
            Box(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 40.dp)
                .size(binSize).clip(CircleShape)
                .background(if (overBin) VoiidColor.error else Color.Black.copy(alpha = 0.45f))
                .border(1.dp, Color.White.copy(alpha = 0.6f), CircleShape),
                contentAlignment = Alignment.Center) {
                Icon(Icons.Default.Delete, "Delete text", tint = Color.White, modifier = Modifier.size(22.dp))
            }
        }

        typing?.let { item ->
            ClipTextComposer(item, frameWidthDp, onChange = { typing = it }, onDone = { finishTyping(it) })
        }

        toast?.let {
            Text(it, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = Color.White,
                modifier = Modifier.align(Alignment.Center).clip(RoundedCornerShape(50))
                    .background(Color.Black.copy(alpha = 0.55f)).padding(horizontal = 14.dp, vertical = 8.dp))
        }
    }
}

/** Typing over a dimmed clip, the text large and centred; colour and background below. */
@Composable
private fun ClipTextComposer(
    item: ClipTextOverlay,
    frameWidth: androidx.compose.ui.unit.Dp,
    onChange: (ClipTextOverlay) -> Unit,
    onDone: (ClipTextOverlay) -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val density = LocalDensity.current
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    val sizeDp = frameWidth * ClipTextOverlay.FONT_FRACTION
    val sizeSp = with(density) { sizeDp.toPx() / (density.density * density.fontScale) }

    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f))
        .pointerInput(Unit) { detectTapGestures { onDone(item) } }) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(40.dp).clip(CircleShape)
                .background(if (item.pill) Color.White else Color.Black.copy(alpha = 0.4f))
                .softClickable(scale = 0.9f) { haptics.tap(); onChange(item.copy(pill = !item.pill)) },
                contentAlignment = Alignment.Center) {
                Text("A", style = VoiidFont.rounded(17, FontWeight.Bold), color = if (item.pill) Color.Black else Color.White)
            }
            Spacer(Modifier.weight(1f))
            Box(Modifier.clip(RoundedCornerShape(50)).background(Color.White)
                .softClickable(scale = 0.95f) { haptics.tap(); onDone(item) }
                .padding(horizontal = 20.dp, vertical = 9.dp)) {
                Text("Done", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = Color.Black)
            }
        }

        BasicTextField(
            value = item.text,
            onValueChange = { onChange(item.copy(text = it.take(ClipTextOverlay.MAX_LENGTH))) },
            textStyle = VoiidFont.rounded(sizeSp, FontWeight.Bold).copy(color = Color(item.ink), textAlign = TextAlign.Center),
            cursorBrush = SolidColor(VoiidColor.accent),
            modifier = Modifier.align(Alignment.Center).padding(horizontal = 32.dp).focusRequester(focus),
            decorationBox = { inner ->
                Box(
                    (if (item.pill) Modifier.background(Color(item.fill), RoundedCornerShape(sizeDp * 0.36f))
                        .padding(horizontal = sizeDp * 0.5f, vertical = sizeDp * 0.21f) else Modifier),
                    contentAlignment = Alignment.Center,
                ) {
                    if (item.text.isEmpty()) {
                        Text("Type something", style = VoiidFont.rounded(sizeSp, FontWeight.Bold),
                            color = Color.White.copy(alpha = 0.5f), textAlign = TextAlign.Center)
                    }
                    inner()
                }
            },
        )

        Row(Modifier.align(Alignment.BottomCenter).imePadding().navigationBarsPadding().padding(bottom = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            ClipTextOverlay.PALETTE.forEachIndexed { i, c ->
                val on = item.color == i
                Box(Modifier.size(if (on) 32.dp else 28.dp).clip(CircleShape).background(Color(c))
                    .border(if (on) 3.dp else 1.5.dp, Color.White, CircleShape)
                    .softClickable(scale = 0.9f) { haptics.selection(); onChange(item.copy(color = i)) })
            }
        }
    }
}

@Composable
private fun EditTool(icon: ImageVector, label: String, active: Boolean = false, onClick: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    Column(Modifier.width(60.dp).softClickable(scale = 0.9f) { haptics.tap(); onClick() },
        horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(42.dp).clip(CircleShape).background(if (active) Color.White else Color.Black.copy(alpha = 0.35f)),
            contentAlignment = Alignment.Center) {
            Icon(icon, label, tint = if (active) Color.Black else Color.White, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.height(3.dp))
        Text(label, style = VoiidFont.rounded(10, FontWeight.SemiBold), color = Color.White, maxLines = 1)
    }
}

@Composable
private fun GlassCircle(icon: ImageVector, label: String, onClick: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    Box(Modifier.size(40.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.4f))
        .softClickable(scale = 0.9f) { haptics.tap(); onClick() }, contentAlignment = Alignment.Center) {
        Icon(icon, label, tint = Color.White, modifier = Modifier.size(20.dp))
    }
}

@Composable
private fun TrayChip(label: String, onClick: () -> Unit) {
    Box(Modifier.clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.15f))
        .softClickable(scale = 0.95f, onClick = onClick).padding(horizontal = 14.dp, vertical = 9.dp)) {
        Text(label, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = Color.White)
    }
}

private fun clock(ms: Long): String = "%d:%02d".format(ms / 60000, (ms / 1000) % 60)

/** "18s", "1m 05s". */
internal fun shortDuration(ms: Long): String {
    val whole = (ms / 1000.0).roundToInt()
    return if (whole < 60) "${whole}s" else "%dm %02ds".format(whole / 60, whole % 60)
}
