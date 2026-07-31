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
) {
    val haptics = LocalVoiidHaptics.current
    val context = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()

    var recording by remember { mutableStateOf(false) }
    var seconds by remember { mutableFloatStateOf(0f) }
    var recorder by remember { mutableStateOf<MediaRecorder?>(null) }
    var recFile by remember { mutableStateOf<File?>(null) }
    var tooShort by remember { mutableStateOf(false) }

    fun startRec(): Boolean = runCatching {
        val f = File.createTempFile("vn", ".m4a", context.cacheDir)
        @Suppress("DEPRECATION")
        val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(context) else MediaRecorder()
        r.setAudioSource(MediaRecorder.AudioSource.MIC)
        r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        r.setOutputFile(f.path)
        r.prepare(); r.start()
        recorder = r; recFile = f
        true
    }.getOrDefault(false)

    /** Stop and return the bytes, or null. Always releases the recorder and temp file. */
    fun stopRec(): ByteArray? {
        val r = recorder ?: return null
        val bytes = runCatching { r.stop(); r.release(); recFile?.readBytes() }.getOrNull()
        recorder = null
        recFile?.delete(); recFile = null
        return bytes
    }

    /** "Hold to record" — the one thing a mic glyph cannot say. Shown on a too-short tap, so
     *  it teaches on failure rather than nagging permanently. */
    fun showTooShort() {
        haptics.tap()
        tooShort = true
        scope.launch { delay(1600); tooShort = false }
    }

    // Timer + meter pump. 50ms matches iOS: fast enough that the waveform reads as live.
    androidx.compose.runtime.LaunchedEffect(recording) {
        if (!recording) return@LaunchedEffect
        seconds = 0f
        RecordingLevel.reset()
        while (isActive) {
            delay(50)
            seconds += 0.05f
            onTick(seconds)
            // maxAmplitude is 0..32767 and resets on each read. sqrt-shaped because raw
            // linear amplitude spends almost all its range near the floor, so speech barely
            // moves the bars.
            val amp = runCatching { recorder?.maxAmplitude ?: 0 }.getOrDefault(0)
            RecordingLevel.push(kotlin.math.sqrt(amp / 32767f).coerceIn(0f, 1f))
        }
    }

    Box(
        modifier = Modifier
            .size(44.dp)
            .pointerInput(Unit) {
                awaitPointerEventScope {
                    while (true) {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        val startX = down.position.x
                        var armed = false
                        var dragX = 0f

                        // HOLD ARMING. Recording begins only if the finger is still down at
                        // 250ms — otherwise a stray tap on the mic starts a take the user
                        // never asked for. Matches iOS's holdTimer.
                        val holdJob = scope.launch {
                            delay(250)
                            if (startRec()) {
                                armed = true
                                recording = true
                                seconds = 0f
                                haptics.rigid()
                                onRecordingChange(true)
                            }
                        }

                        var released = false
                        while (!released) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull()
                            if (change != null && armed) {
                                // Only LEFTWARD travel counts; rightward is the thumb rolling
                                // on the glass.
                                dragX = (change.position.x - startX).coerceAtMost(0f)
                                onDrag(dragX)
                            }
                            if (event.changes.all { !it.pressed }) released = true
                        }

                        holdJob.cancel()
                        if (!armed) {
                            // Released before the hold armed — a tap, not a recording.
                            showTooShort()
                            continue
                        }

                        recording = false
                        onRecordingChange(false)
                        onDrag(0f)
                        RecordingLevel.reset()
                        val dur = seconds
                        val cancelled = dragX <= CANCEL_THRESHOLD_PX
                        val bytes = stopRec()

                        when {
                            // Dragged past the threshold: discard, and say so with a tap
                            // rather than a success cue.
                            cancelled -> haptics.tap()
                            // Under half a second is a mis-tap, not a message. It used to
                            // fail SILENTLY — the user pressed the mic, nothing happened,
                            // and nothing explained why.
                            dur < 0.5f || bytes == null -> showTooShort()
                            else -> { haptics.success(); onSend(bytes, dur) }
                        }
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        // A 32dp CIRCLE, matching send and the other composer actions — it was a bare glyph
        // with no shape and a vague tap target, visually misaligned next to filled send.
        Box(
            Modifier
                .size(32.dp)
                .clip(CircleShape)
                .background(VoiidColor.primary.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Default.Mic, "Record voice",
                tint = VoiidColor.primary,
                modifier = Modifier.size(17.dp).alpha(if (recording) 0f else 1f),
            )
        }
        androidx.compose.animation.AnimatedVisibility(
            visible = tooShort,
            enter = fadeIn(), exit = fadeOut(),
            modifier = Modifier.offset(y = (-34).dp),
        ) {
            Text(
                "Hold to record",
                style = VoiidFont.rounded(11, androidx.compose.ui.text.font.FontWeight.Medium),
                color = VoiidColor.textOnPrimary,
                modifier = Modifier
                    .clip(CircleShape)
                    .background(VoiidColor.textPrimary.copy(alpha = 0.9f))
                    .padding(horizontal = 10.dp, vertical = 5.dp),
            )
        }
    }
}

/** Past this leftward travel the release DISCARDS. Shared by the button and the bar so the
 *  visual threshold and the behavioural one cannot drift apart. */
const val CANCEL_THRESHOLD_PX = -240f

private fun timeString(seconds: Float): String {
    val s = seconds.toInt()
    return "%d:%02d".format(s / 60, s % 60)
}

// MARK: - Live waveform while recording

/** Waveform driven by REAL input level (see [RecordingLevel]), not random numbers. */
@Composable
fun LiveWaveform(tint: androidx.compose.ui.graphics.Color = VoiidColor.primary) {
    Row(
        modifier = Modifier.height(22.dp).fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp, Alignment.End),
    ) {
        RecordingLevel.levels.forEachIndexed { i, level ->
            val animated by androidx.compose.animation.core.animateFloatAsState(
                targetValue = level, animationSpec = tween(50), label = "lvl",
            )
            Box(
                Modifier
                    .width(2.5.dp)
                    .height((3 + 19 * animated).dp)
                    .clip(CircleShape)
                    // Newer bars more opaque, so the eye reads direction of travel — a flat
                    // wall of identical bars looks static even while animating.
                    .alpha(0.35f + 0.65f * (i.toFloat() / RecordingLevel.BAR_COUNT))
                    .background(tint),
            )
        }
    }
}

// MARK: - Recording bar

/**
 * The full-width bar that REPLACES the composer row while recording.
 *
 * It cannot live inside the mic button: a 44dp capsule rendered inside a 32dp slot overflowed
 * its container and fought the text field for space, which is what made the old one look
 * broken. Recording is a modal state, so it takes the whole row.
 *
 * @param dragX 0 at rest, negative when dragged left toward cancel.
 */
@Composable
fun RecordingBar(seconds: Float, dragX: Float, onCancel: () -> Unit) {
    val willCancel = dragX <= CANCEL_THRESHOLD_PX
    val tint = if (willCancel) VoiidColor.error else VoiidColor.primary

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(40.dp)
            .clip(RoundedCornerShape(20.dp))
            .background(VoiidColor.fieldFill)
            .border(
                1.dp,
                if (willCancel) VoiidColor.error.copy(alpha = 0.6f) else VoiidColor.fieldBorder,
                RoundedCornerShape(20.dp),
            )
            .padding(horizontal = 16.dp)
            .semantics {
                contentDescription = "Recording, ${timeString(seconds)}. Slide left to cancel."
            },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // A pulsing dot reads as "live" the way a static icon cannot.
        val blink = rememberInfiniteTransition(label = "recDot")
        val dotScale by blink.animateFloat(
            1f, 1.25f, infiniteRepeatable(tween(700), RepeatMode.Reverse), label = "dotScale",
        )
        Box(Modifier.size(9.dp).scale(dotScale).alpha(0.55f).clip(CircleShape).background(VoiidColor.error))

        Text(
            timeString(seconds),
            style = VoiidFont.rounded(14, androidx.compose.ui.text.font.FontWeight.SemiBold),
            color = if (willCancel) VoiidColor.error else VoiidColor.textPrimary,
        )

        Box(Modifier.weight(1f)) { LiveWaveform(tint = tint) }

        // The affordance has to be VISIBLE — a hidden gesture is not a feature. It flips to
        // "Release to cancel" past the threshold so the outcome is never a guess.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            // Follows the finger, damped: 1:1 tracking over-travels and looks loose.
            modifier = Modifier.offset(x = (dragX * 0.35f).coerceAtLeast(-26f).dp),
        ) {
            Icon(
                if (willCancel) Icons.Default.Delete else Icons.Default.ChevronLeft,
                contentDescription = null,
                tint = if (willCancel) VoiidColor.error else VoiidColor.textSecondary,
                modifier = Modifier.size(13.dp),
            )
            Text(
                if (willCancel) "Release to cancel" else "Slide to cancel",
                style = VoiidFont.rounded(12, androidx.compose.ui.text.font.FontWeight.Medium),
                color = if (willCancel) VoiidColor.error else VoiidColor.textSecondary,
                maxLines = 1,
            )
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
