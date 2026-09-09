package com.voiid.app.main

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.Delete
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import kotlinx.coroutines.launch
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import android.media.MediaRecorder
import android.os.Build
import java.io.File
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

/**
 * Voice-note recording — port of `VoiceNote.swift`.
 *
 * TWO REAL DEFECTS THIS FIXES, both of which shipped:
 *
 * 1. RELEASE ALWAYS SENT. There was no slide-to-cancel and no cancel path of any kind — the
 *    gesture watched only for `!pressed`. Once you started recording, the only way out was
 *    sending something you did not want. iOS had the same bug and fixed it; this is the port.
 *
 * 2. THE WAVEFORM WAS `Math.random()`. It looks convincing until you notice it wiggles
 *    identically in silence, so it told the user nothing about whether the mic was picking
 *    them up. It now reads `MediaRecorder.maxAmplitude`.
 */

// MARK: - Live input level

/**
 * Real mic levels, published from the recorder's meter so the waveform reflects what the mic
 * actually hears.
 *
 * A shared object because the recorder lives in the button while the waveform is drawn by the
 * composer's recording bar — they are siblings, not parent and child.
 */
object RecordingLevel {
    /** Newest last. Fixed width so the bar SCROLLS rather than growing. */
    val levels = mutableStateListOf<Float>().apply { repeat(BAR_COUNT) { add(FLOOR) } }

    fun push(level: Float) {
        levels.removeAt(0)
        levels.add(level.coerceIn(FLOOR, 1f))
    }

    fun reset() {
        for (i in levels.indices) levels[i] = FLOOR
    }

    const val BAR_COUNT = 34
    private const val FLOOR = 0.05f
}

// MARK: - Record button (press & hold)

/**
 * @param onSend           release with a long-enough take: audio bytes (.m4a) + duration.
 * @param onRecordingChange told when recording starts/stops, so the composer can hand over its
 *                         WHOLE ROW. The recording UI cannot live inside this button — a 44dp
 *                         capsule rendered inside a 32dp slot is what made the old one look
 *                         broken.
 * @param onDrag           live horizontal drag while recording, so the composer can draw
 *                         slide-to-cancel.
 * @param onTick           ticking duration, so the bar shows it without owning the recorder.
 */
@Composable
fun VoiceRecordButton(
    onSend: (ByteArray, Float) -> Unit,
    onRecordingChange: (Boolean) -> Unit = {},
    onDrag: (Float) -> Unit = {},
    onTick: (Float) -> Unit = {},
    cancelRequest: Int = 0,
    enabled: Boolean = true,
    onDiscard: () -> Unit = {},
    onError: (String) -> Unit = {},
) {
    val haptics = LocalVoiidHaptics.current
    val context = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val send by androidx.compose.runtime.rememberUpdatedState(onSend)
    val changed by androidx.compose.runtime.rememberUpdatedState(onRecordingChange)
    val dragged by androidx.compose.runtime.rememberUpdatedState(onDrag)
    val tick by androidx.compose.runtime.rememberUpdatedState(onTick)
    val discard by androidx.compose.runtime.rememberUpdatedState(onDiscard)
    val error by androidx.compose.runtime.rememberUpdatedState(onError)
    val canRecord by androidx.compose.runtime.rememberUpdatedState(enabled)
    val density = androidx.compose.ui.platform.LocalDensity.current.density
    var recording by remember { mutableStateOf(false) }
    val capture = remember { VoiceCapture(context) }
    var startedAt by remember { mutableStateOf(0L) }
    var tooShort by remember { mutableStateOf(false) }
    val permission = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission()
    ) { granted ->
        // The permission dialog ends the original touch. Require a fresh hold.
        if (granted) tooShort = true
        else error("Allow microphone access in Settings to record a voice message.")
    }
    fun finish(cancelled: Boolean) {
        if (!recording) return
        val duration = (android.os.SystemClock.elapsedRealtime() - startedAt) / 1000f
        recording = false
        val bytes = capture.finish(discard = cancelled || duration < 0.5f)
        if (cancelled) { haptics.tap(); discard() }
        changed(false)
        when {
            cancelled -> Unit
            duration < 0.5f -> tooShort = true
            bytes == null -> error("Couldn’t save this recording. Please try again.")
            else -> { haptics.success(); send(bytes, duration) }
        }
    }
    androidx.compose.runtime.LaunchedEffect(cancelRequest) {
        if (cancelRequest > 0) finish(true)
    }
    androidx.compose.runtime.LaunchedEffect(tooShort) {
        if (tooShort) { delay(1600); tooShort = false }
    }
    androidx.compose.runtime.DisposableEffect(capture) {
        onDispose { capture.finish(discard = true) }
    }
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    androidx.compose.runtime.DisposableEffect(lifecycle) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_STOP) finish(true)
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    androidx.compose.runtime.LaunchedEffect(recording) {
        if (!recording) return@LaunchedEffect
        var lastSecond = -1
        while (isActive) {
            val seconds = (android.os.SystemClock.elapsedRealtime() - startedAt) / 1000f
            if (seconds.toInt() != lastSecond) { lastSecond = seconds.toInt(); tick(seconds) }
            RecordingLevel.push(capture.level())
            delay(50)
        }
    }
    Box(
        Modifier.size(46.dp).pointerInput(Unit) {
            awaitPointerEventScope {
                while (true) {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    if (!canRecord) continue
                    down.consume()
                    val pointer = down.id
                    val startX = down.position.x
                    var drag = 0f
                    var held = false
                    val holdJob = scope.launch {
                        delay(250)
                        held = true
                        if (androidx.core.content.ContextCompat.checkSelfPermission(context,
                                android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                            permission.launch(android.Manifest.permission.RECORD_AUDIO)
                        } else {
                            try {
                                capture.start()
                                startedAt = android.os.SystemClock.elapsedRealtime()
                                RecordingLevel.reset(); dragged(0f); tick(0f)
                                recording = true; changed(true); haptics.rigid()
                            } catch (_: Exception) {
                                error("Microphone unavailable. End any active call and try again.")
                            }
                        }
                    }
                    try {
                        while (true) {
                            val change = awaitPointerEvent().changes.firstOrNull { it.id == pointer } ?: break
                            drag = ((change.position.x - startX) / density).coerceAtMost(0f)
                            if (recording) dragged(drag)
                            change.consume()
                            if (!change.pressed) break
                        }
                        holdJob.cancel()
                        if (recording) finish(drag <= CANCEL_THRESHOLD_DP)
                        else if (!held) { haptics.tap(); tooShort = true }
                    } finally {
                        holdJob.cancel()
                        if (recording) finish(true)
                    }
                }
            }
        }, contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.size(40.dp).clip(CircleShape).background(VoiidColor.primary.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center) {
            Icon(Icons.Default.Mic, "Hold to record voice", tint = VoiidColor.primary,
                modifier = Modifier.size(21.dp).alpha(if (recording) 0f else 1f))
        }
        AnimatedVisibility(tooShort, enter = fadeIn(), exit = fadeOut(), modifier = Modifier.offset(y = (-44).dp)) {
            Text("Hold to record", style = VoiidFont.rounded(11), color = VoiidColor.textOnPrimary,
                modifier = Modifier.clip(CircleShape).background(VoiidColor.textPrimary).padding(8.dp))
        }
    }
}

/** Owns the recorder and file together so every error/cancel path releases both. */
internal class VoiceCapture(private val context: android.content.Context) {
    private var recorder: MediaRecorder? = null
    private var file: File? = null
    fun start() {
        finish(discard = true)
        try {
            file = File.createTempFile("voice-", ".m4a", context.cacheDir)
            @Suppress("DEPRECATION")
            val r = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else MediaRecorder()
            recorder = r
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioSamplingRate(44100)
            r.setAudioEncodingBitRate(64000)
            r.setOutputFile(file!!.path)
            r.prepare(); r.start()
        } catch (e: Exception) { finish(discard = true); throw e }
    }
    fun finish(discard: Boolean): ByteArray? {
        val r = recorder
        recorder = null
        return try {
            if (r == null) null else {
                r.stop()
                if (discard) null else file?.readBytes()
            }
        } catch (_: Exception) { null }
        finally {
            runCatching { r?.release() }
            file?.delete(); file = null
        }
    }
    fun level(): Float = runCatching {
        kotlin.math.sqrt((recorder?.maxAmplitude ?: 0) / 32767f).coerceIn(0f, 1f)
    }.getOrDefault(0f)
}

const val CANCEL_THRESHOLD_DP = -90f

private fun timeString(seconds: Float): String {
    val s = seconds.toInt()
    return "%d:%02d".format(s / 60, s % 60)
}

// MARK: - Live waveform while recording

/** Waveform driven by REAL input level (see [RecordingLevel]), not random numbers. */
@Composable
fun LiveWaveform(tint: androidx.compose.ui.graphics.Color = VoiidColor.primary) {
    androidx.compose.foundation.Canvas(Modifier.height(20.dp).fillMaxWidth()) {
        val levels = RecordingLevel.levels
        val step = size.width / levels.size
        levels.forEachIndexed { i, level ->
            val height = (3.dp.toPx() + (size.height - 3.dp.toPx()) * level).coerceAtMost(size.height)
            val x = step * (i + 0.5f)
            drawLine(tint.copy(alpha = 0.35f + 0.65f * i / levels.size),
                androidx.compose.ui.geometry.Offset(x, (size.height - height) / 2),
                androidx.compose.ui.geometry.Offset(x, (size.height + height) / 2),
                strokeWidth = minOf(2.5.dp.toPx(), step * 0.6f), cap = androidx.compose.ui.graphics.StrokeCap.Round)
        }
    }
}

@Composable
fun RecordingBar(seconds: Float, dragX: Float, isDiscarding: Boolean = false, onCancel: () -> Unit) {
    val willCancel = dragX <= CANCEL_THRESHOLD_DP || isDiscarding
    val tint = if (willCancel) VoiidColor.error else VoiidColor.primary
    val fade by androidx.compose.animation.core.animateFloatAsState(
        if (isDiscarding) 0f else 1f, tween(180), label = "discard")
    val rotation by androidx.compose.animation.core.animateFloatAsState(
        if (isDiscarding) -18f else 0f, tween(180), label = "trash")
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).clip(RoundedCornerShape(28.dp))
        .background(VoiidColor.fieldFill)
        .border(1.dp, if (willCancel) tint.copy(alpha = 0.5f) else VoiidColor.fieldBorder, RoundedCornerShape(28.dp))
        .padding(horizontal = 6.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        androidx.compose.material3.IconButton(onClick = onCancel, enabled = !isDiscarding, modifier = Modifier.size(44.dp)) {
            Icon(Icons.Default.Delete, "Delete recording", tint = tint,
                modifier = Modifier.size(21.dp).graphicsLayer { rotationZ = rotation })
        }
        Text(timeString(seconds), style = VoiidFont.rounded(14, androidx.compose.ui.text.font.FontWeight.SemiBold),
            color = VoiidColor.textPrimary, maxLines = 1)
        androidx.compose.foundation.layout.Column(Modifier.weight(1f).padding(end = 12.dp)
            .graphicsLayer { alpha = fade; translationX = (1 - fade) * -16.dp.toPx() },
            verticalArrangement = Arrangement.spacedBy(3.dp)) {
            LiveWaveform(tint)
            Text(if (isDiscarding) "Recording deleted" else if (willCancel) "Release to delete" else "Slide left to delete · release to send",
                style = VoiidFont.rounded(10), color = VoiidColor.textSecondary, maxLines = 1,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
        }
    }
}

// MARK: - Voice note playback bubble

@Composable
fun VoiceNotePlayer(label: String) {
    val haptics = LocalVoiidHaptics.current
    var playing by remember { mutableStateOf(false) }
    var progress by remember { mutableFloatStateOf(0f) }

    androidx.compose.runtime.LaunchedEffect(playing) {
        if (playing) {
            while (isActive && progress < 1f) { delay(50); progress += 0.01f }
            if (progress >= 1f) { progress = 0f; playing = false }
        }
    }

    Row(
        modifier = Modifier.widthIn(min = 180.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            modifier = Modifier.size(28.dp).clip(CircleShape).pointerInput(Unit) {
                detectTapToggle { haptics.tap(); playing = !playing }
            },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (playing) Icons.Default.Pause else Icons.Default.PlayArrow, "Play",
                tint = VoiidColor.primary, modifier = Modifier.size(18.dp),
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            for (i in 0 until 22) {
                val filled = i.toFloat() / 22f <= progress
                Box(
                    Modifier
                        .width(2.5.dp)
                        .height(barHeight(i).dp)
                        .clip(CircleShape)
                        .background(if (filled) VoiidColor.primary else VoiidColor.textSecondary.copy(alpha = 0.4f)),
                )
            }
        }
        Text(
            if (label.contains("·")) label.substringAfterLast("·").trim() else "0:03",
            style = VoiidFont.rounded(10), color = VoiidColor.textSecondary,
        )
    }
}

private fun barHeight(i: Int): Int {
    val pattern = intArrayOf(8, 14, 20, 12, 18, 10, 22, 16, 9, 15, 21)
    return pattern[i % pattern.size]
}

// simple tap detector used by the play button
private suspend fun androidx.compose.ui.input.pointer.PointerInputScope.detectTapToggle(onTap: () -> Unit) {
    awaitPointerEventScope {
        while (true) {
            awaitFirstDown(requireUnconsumed = false)
            var released = false
            while (!released) {
                val e = awaitPointerEvent()
                if (e.changes.all { !it.pressed }) released = true
            }
            onTap()
        }
    }
}
