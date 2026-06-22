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

/** Voice-note UI for the dummy experience — port of `VoiceNote.swift`. */

// MARK: - Record button (press & hold)

@Composable
fun VoiceRecordButton(onSend: (ByteArray, Float) -> Unit) {
    val haptics = LocalVoiidHaptics.current
    val context = LocalContext.current
    var recording by remember { mutableStateOf(false) }
    var seconds by remember { mutableFloatStateOf(0f) }
    var recorder by remember { mutableStateOf<MediaRecorder?>(null) }
    var recFile by remember { mutableStateOf<File?>(null) }

    fun startRec() {
        runCatching {
            val f = File.createTempFile("vn", ".m4a", context.cacheDir)
            @Suppress("DEPRECATION")
            val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(context) else MediaRecorder()
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setOutputFile(f.path)
            r.prepare(); r.start()
            recorder = r; recFile = f
        }
    }

    fun stopRec(): ByteArray? {
        val r = recorder ?: return null
        val bytes = runCatching { r.stop(); r.release(); recFile?.readBytes() }.getOrNull()
        recorder = null
        recFile?.delete(); recFile = null
        return bytes
    }

    androidx.compose.runtime.LaunchedEffect(recording) {
        if (recording) {
            seconds = 0f
            while (isActive) { delay(100); seconds += 0.1f }
        }
    }

    Row(verticalAlignment = Alignment.CenterVertically) {
        AnimatedVisibility(
            visible = recording,
            enter = slideInHorizontally { it } + fadeIn(),
            exit = fadeOut(),
        ) {
            Row(
                modifier = Modifier
                    .height(44.dp)
                    .clip(CircleShape)
                    .background(VoiidColor.fieldFill)
                    .padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                val blink = rememberInfiniteTransition(label = "recDot")
                val dotScale by blink.animateFloat(
                    1f, 1.3f, infiniteRepeatable(tween(600), RepeatMode.Reverse), label = "dotScale",
                )
                Box(Modifier.size(10.dp).scale(dotScale).alpha(0.5f).clip(CircleShape).background(VoiidColor.error))
                Text(timeString(seconds), style = VoiidFont.subhead, color = VoiidColor.textPrimary)
                LiveWaveform()
            }
        }
        Box(
            modifier = Modifier
                .size(44.dp)
                .pointerInput(Unit) {
                    awaitPointerEventScope {
                        while (true) {
                            awaitFirstDown(requireUnconsumed = false)
                            recording = true
                            haptics.rigid()
                            startRec()
                            // wait for release / cancel
                            var released = false
                            while (!released) {
                                val event = awaitPointerEvent()
                                if (event.changes.all { !it.pressed }) released = true
                            }
                            recording = false
                            val dur = seconds
                            val bytes = stopRec()
                            if (dur >= 0.5f && bytes != null) { haptics.success(); onSend(bytes, dur) }
                        }
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Default.Mic, "Record voice",
                tint = if (recording) VoiidColor.error else VoiidColor.primary,
                modifier = Modifier.size(22.dp).scale(if (recording) 1.2f else 1f).alpha(if (recording) 0f else 1f),
            )
        }
    }
}

private fun timeString(seconds: Float): String {
    val s = seconds.toInt()
    return "%d:%02d".format(s / 60, s % 60)
}

// MARK: - Live waveform while recording

@Composable
fun LiveWaveform() {
    val levels = remember { mutableStateListOf<Float>().apply { repeat(14) { add((0.2f + Math.random().toFloat() * 0.8f)) } } }
    androidx.compose.runtime.LaunchedEffect(Unit) {
        while (isActive) {
            delay(120)
            for (i in levels.indices) levels[i] = 0.2f + Math.random().toFloat() * 0.8f
        }
    }
    Row(
        modifier = Modifier.height(22.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        levels.forEach { level ->
            Box(Modifier.width(2.5.dp).height((18 * level).dp).clip(CircleShape).background(VoiidColor.primary))
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
