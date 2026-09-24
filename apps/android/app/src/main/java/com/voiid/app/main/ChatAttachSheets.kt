package com.voiid.app.main

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ContentCut
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.SportsEsports
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.voiid.app.model.MessageStatus
import com.voiid.app.model.VMessage
import com.voiid.app.net.ChatAttachmentIntake
import com.voiid.app.net.ChatEngine
import com.voiid.app.net.ChatMediaLimit
import com.voiid.app.net.ChatOversizeFile
import com.voiid.app.net.ChatPdfCompressor
import com.voiid.app.net.ChatVideoCompressor
import com.voiid.app.net.ChatVideoPlanner
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidDetent
import com.voiid.app.ui.components.VoiidSheet
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/*
 * The chat's attach sheet, the compressor sheet a file over 25 MB opens, and the document
 * bubble. Port of iOS Main/Media/ChatAttachSheets.swift, built to the Voiid Ui reference.
 *
 * ASK ONLY WHERE THERE IS A CHOICE. A photo over the limit is compressed without a word — there
 * is no visible trade-off to weigh. The sheet appears only where the person is choosing
 * something real: how much quality to keep in a video, how much of a long video to send,
 * whether a PDF may lose selectable text. A file nothing can shrink gets one plain
 * explanation, not a disabled button.
 *
 * THE RECOMMENDED CHOICE IS ALREADY MADE. The best option is selected when the sheet opens,
 * and the button says what will happen and roughly how big it will be.
 */

enum class ChatAttachAction { PHOTOS, CAMERA, DOCUMENT, LOCATION, GAME, POLL }

@Composable
fun ChatAttachSheet(
    visible: Boolean,
    allowsPoll: Boolean,
    onDismiss: () -> Unit,
    onChoose: (ChatAttachAction) -> Unit,
) {
    VoiidSheet(visible = visible, onDismiss = onDismiss, detents = listOf(VoiidDetent.Content), showHandle = true) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 18.dp).navigationBarsPadding().padding(bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(22.dp)) {
            val actions = buildList {
                add(Triple(ChatAttachAction.PHOTOS, Icons.Default.Photo, "Photos") to VoiidColor.accent)
                add(Triple(ChatAttachAction.CAMERA, Icons.Default.CameraAlt, "Camera") to Color(0xFFF0734D))
                add(Triple(ChatAttachAction.DOCUMENT, Icons.Default.Description, "Document") to Color(0xFF548AF2))
                add(Triple(ChatAttachAction.LOCATION, Icons.Default.LocationOn, "Location") to Color(0xFF33AD70))
                add(Triple(ChatAttachAction.GAME, Icons.Default.SportsEsports, "Ludo") to Color(0xFF9B6BF2))
                if (allowsPoll) add(Triple(ChatAttachAction.POLL, Icons.Default.BarChart, "Poll") to Color(0xFFEDA829))
            }
            // Rows of four, so six actions do not squeeze into one line.
            actions.chunked(4).forEach { row ->
                Row(Modifier.fillMaxWidth()) {
                    row.forEach { (a, tint) ->
                        val (kind, icon, label) = a
                        Column(Modifier.weight(1f).softClickable(scale = 0.92f) { onChoose(kind) },
                            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Box(Modifier.size(56.dp).clip(CircleShape).background(tint), contentAlignment = Alignment.Center) {
                                Icon(icon, label, tint = Color.White, modifier = Modifier.size(24.dp))
                            }
                            Text(label, style = VoiidFont.rounded(12, FontWeight.Medium), color = VoiidColor.textPrimary, maxLines = 1)
                        }
                    }
                    repeat(4 - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Default.Lock, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(12.dp).offset(y = 2.dp))
                Text("Files up to 25 MB. Bigger ones are compressed on this phone first, then end-to-end encrypted.",
                    style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
            }
        }
    }
}

// ── Compress sheet ─────────────────────────────────────────────────────────────

private sealed interface CompressPhase {
    data object Choose : CompressPhase
    data object Working : CompressPhase
    data class Done(val bytes: Long) : CompressPhase
    data class Failed(val message: String) : CompressPhase
}

/**
 * @param onReady the file to send, its type, and its document name (null for a video).
 */
@Composable
fun ChatCompressSheet(
    file: ChatOversizeFile?,
    onDismiss: () -> Unit,
    onReady: (File, String, String?) -> Unit,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()
    var visible by remember(file?.id) { mutableStateOf(file != null) }
    var phase by remember(file?.id) { mutableStateOf<CompressPhase>(CompressPhase.Choose) }
    var progress by remember(file?.id) { mutableFloatStateOf(0f) }
    var videoChoice by remember(file?.id) { mutableStateOf("best") }
    var pdfChoice by remember(file?.id) { mutableStateOf(ChatPdfCompressor.Quality.BALANCED) }
    var thumbnail by remember(file?.id) { mutableStateOf<Bitmap?>(null) }
    var work by remember(file?.id) { mutableStateOf<Job?>(null) }

    val kind = file?.kind
    val fullSeconds = (kind as? ChatOversizeFile.Kind.Video)?.seconds ?: 0.0
    val needsTrim = kind is ChatOversizeFile.Kind.Video && ChatVideoPlanner.plans(fullSeconds, file.bytes).isEmpty()
    var trimSeconds by remember(file?.id) { mutableFloatStateOf(0f) }
    LaunchedEffect(file?.id) {
        if (file == null) return@LaunchedEffect
        if (needsTrim) trimSeconds = minOf(fullSeconds, ChatVideoPlanner.maxSeconds()).toFloat()
        thumbnail = withContext(Dispatchers.IO) {
            when (file.kind) {
                is ChatOversizeFile.Kind.Video -> file.file?.let { ChatVideoCompressor.thumbnail(it) }
                is ChatOversizeFile.Kind.Pdf -> file.file?.let { ChatPdfCompressor.thumbnail(it) }
                ChatOversizeFile.Kind.Other -> null
            }
        }
    }
    val sendSeconds = if (needsTrim) trimSeconds.toDouble() else fullSeconds
    val plans = if (file != null && fullSeconds > 0 && sendSeconds > 0)
        ChatVideoPlanner.plans(sendSeconds, (file.bytes * sendSeconds / fullSeconds).toLong()) else emptyList()
    val selectedPlan = plans.firstOrNull { it.id == videoChoice } ?: plans.firstOrNull()
    val estimate: Long? = when (kind) {
        is ChatOversizeFile.Kind.Video -> selectedPlan?.estimatedBytes
        is ChatOversizeFile.Kind.Pdf -> ChatPdfCompressor.estimate(kind.pages, pdfChoice)
        else -> null
    }
    val canCompress = when (kind) {
        is ChatOversizeFile.Kind.Video -> selectedPlan != null && file.file != null
        is ChatOversizeFile.Kind.Pdf -> file.file != null
        else -> false
    }

    fun close() {
        work?.cancel()
        visible = false
    }

    fun start() {
        val f = file ?: return
        val source = f.file ?: return
        haptics.tap()
        progress = 0f
        phase = CompressPhase.Working
        val plan = selectedPlan
        val quality = pdfChoice
        val keepMs = (sendSeconds * 1000).toLong()
        work = scope.launch {
            try {
                val report: (Float) -> Unit = { v -> scope.launch { progress = maxOf(progress, v) } }
                val (out, mime, name) = when (f.kind) {
                    is ChatOversizeFile.Kind.Video -> Triple(
                        ChatVideoCompressor.compress(context, source, plan ?: return@launch, keepMs, report),
                        "video/mp4", null)
                    is ChatOversizeFile.Kind.Pdf -> Triple(
                        ChatPdfCompressor.compress(context, source, quality, report), "application/pdf", f.name)
                    ChatOversizeFile.Kind.Other -> return@launch
                }
                haptics.success()
                progress = 1f
                phase = CompressPhase.Done(out.length())
                // A beat on the result, so the size it came to is seen, then it goes.
                delay(900)
                onReady(out, mime, name)
                visible = false
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                haptics.error()
                phase = CompressPhase.Failed(e.message ?: "Couldn't compress it.")
            }
        }
    }

    VoiidSheet(
        visible = visible && file != null,
        onDismiss = {
            work?.cancel()
            onDismiss()
        },
        detents = listOf(VoiidDetent.Large),
        showHandle = true,
        dismissOnDrag = phase != CompressPhase.Working,
        tapOutsideToDismiss = phase != CompressPhase.Working,
    ) {
        if (file == null) return@VoiidSheet
        Column(Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp)) {
                Text("Cancel", style = VoiidFont.rounded(16), color = VoiidColor.accentInk,
                    modifier = Modifier.align(Alignment.CenterStart).softClickable(scale = 0.95f) { close() }.padding(10.dp))
                Text(if (canCompress) "Compress to send" else "Too big to send",
                    style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary,
                    modifier = Modifier.align(Alignment.Center))
            }
            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                CompressHeader(file, thumbnail)
                Meter(file.bytes, (phase as? CompressPhase.Done)?.bytes ?: estimate, phase == CompressPhase.Choose)
                AnimatedContent(targetState = phase, transitionSpec = { fadeIn(tween(200)) togetherWith fadeOut(tween(150)) },
                    label = "phase") { p ->
                    when (p) {
                        CompressPhase.Working -> WorkingCard(progress)
                        is CompressPhase.Done -> DoneCard(file.bytes, p.bytes)
                        else -> Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                            if (p is CompressPhase.Failed) {
                                Notice(Icons.Default.WarningAmber, VoiidColor.warning, "Couldn't compress it", p.message)
                            }
                            when (kind) {
                                is ChatOversizeFile.Kind.Video -> {
                                    if (needsTrim) TrimCard(fullSeconds, trimSeconds) { trimSeconds = it }
                                    SectionTitle(if (needsTrim) "Then choose the quality" else "Choose the quality")
                                    plans.forEach { plan ->
                                        OptionRow(plan.title, plan.note, plan.estimatedBytes, selectedPlan?.id == plan.id) {
                                            haptics.selection(); videoChoice = plan.id
                                        }
                                    }
                                }
                                is ChatOversizeFile.Kind.Pdf -> {
                                    SectionTitle("Choose the quality")
                                    ChatPdfCompressor.Quality.entries.forEach { q ->
                                        OptionRow(q.title, q.note, ChatPdfCompressor.estimate(kind.pages, q), pdfChoice == q) {
                                            haptics.selection(); pdfChoice = q
                                        }
                                    }
                                    Note("Pages are saved as images, so text in the PDF can't be selected or searched afterwards.")
                                }
                                else -> Notice(Icons.Default.Inventory2, VoiidColor.textSecondary, "This file can't be made smaller",
                                    "It's already compressed, so shrinking it would save almost nothing. Send the parts that are needed, or split it into files under 25 MB.")
                            }
                            Note("Compressed on this phone, then end-to-end encrypted. The original stays as it is.")
                        }
                    }
                }
                Spacer(Modifier.height(12.dp))
            }

            Box(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp)) {
                when (phase) {
                    CompressPhase.Choose, is CompressPhase.Failed -> PrimaryPill(
                        if (canCompress) estimate?.let { "Compress and send · about ${ChatMediaLimit.text(it)}" } ?: "Compress and send"
                        else "OK",
                    ) { if (canCompress) start() else close() }
                    CompressPhase.Working -> Box(Modifier.fillMaxWidth().height(52.dp).clip(RoundedCornerShape(50))
                        .background(VoiidColor.fieldFill)
                        .softClickable(scale = 0.97f) {
                            haptics.tap()
                            work?.cancel()
                            phase = CompressPhase.Choose
                            progress = 0f
                        }, contentAlignment = Alignment.Center) {
                        Text("Stop", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                    }
                    is CompressPhase.Done -> Spacer(Modifier.height(52.dp))
                }
            }
        }
    }
}

@Composable
private fun CompressHeader(file: ChatOversizeFile, thumbnail: Bitmap?) {
    val icon = when (file.kind) {
        is ChatOversizeFile.Kind.Video -> Icons.Default.PlayArrow
        is ChatOversizeFile.Kind.Pdf -> Icons.Default.PictureAsPdf
        ChatOversizeFile.Kind.Other -> Icons.Default.Description
    }
    val detail = when (val k = file.kind) {
        is ChatOversizeFile.Kind.Video -> "${ChatMediaLimit.text(file.bytes)} · ${clock(k.seconds)}"
        is ChatOversizeFile.Kind.Pdf -> "${ChatMediaLimit.text(file.bytes)} · ${k.pages} page${if (k.pages == 1) "" else "s"}"
        ChatOversizeFile.Kind.Other -> ChatMediaLimit.text(file.bytes)
    }
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(VoiidColor.surfaceCard).padding(14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Box(Modifier.size(60.dp).clip(RoundedCornerShape(14.dp)).background(VoiidColor.accent.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center) {
            if (thumbnail != null) {
                Image(thumbnail.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                if (file.kind is ChatOversizeFile.Kind.Video) Icon(Icons.Default.PlayArrow, null, tint = Color.White)
            } else {
                Icon(icon, null, tint = VoiidColor.accentInk, modifier = Modifier.size(26.dp))
            }
        }
        Column(Modifier.weight(1f)) {
            Text(file.name, style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary,
                maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
            Text(detail, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
        }
    }
}

/** The limit as a line on a bar: how far over the file is, and where the choice lands. */
@Composable
private fun Meter(bytes: Long, result: Long?, estimating: Boolean) {
    val span = maxOf(bytes, ChatMediaLimit.BYTES) * 1.04f
    val resultFraction by animateFloatAsState(((result ?: 0L) / span).coerceIn(0f, 1f), label = "meter")
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(VoiidColor.surfaceCard).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        BoxWithConstraints(Modifier.fillMaxWidth().padding(top = 20.dp).height(10.dp)) {
            val w = maxWidth
            val limitX = w * (ChatMediaLimit.BYTES / span)
            Box(Modifier.fillMaxSize().clip(CircleShape).background(VoiidColor.fieldFill))
            Box(Modifier.width(w * (bytes / span)).fillMaxSize().clip(CircleShape).background(Color(0x66FF9500)))
            if (result != null) {
                Box(Modifier.width(maxOf(10.dp, w * resultFraction)).height(10.dp).clip(CircleShape).background(VoiidColor.accent))
            }
            Box(Modifier.offset(x = limitX - 1.dp, y = (-5).dp).size(width = 2.dp, height = 20.dp).clip(CircleShape)
                .background(VoiidColor.textPrimary))
            Text("25 MB", style = VoiidFont.rounded(10.5f, FontWeight.SemiBold), color = VoiidColor.textSecondary,
                modifier = Modifier.offset(x = (limitX - 17.dp).coerceIn(0.dp, w - 36.dp), y = (-21).dp))
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Legend(Color(0xFFFF9500), ChatMediaLimit.text(bytes))
            if (result != null) {
                Icon(Icons.AutoMirrored.Filled.ArrowForward, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(12.dp))
                Legend(VoiidColor.accent, (if (estimating) "about " else "") + ChatMediaLimit.text(result))
            }
        }
    }
}

@Composable
private fun Legend(color: Color, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.size(7.dp).clip(CircleShape).background(color))
        Text(text, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textPrimary)
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textSecondary,
        modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp))
}

@Composable
private fun OptionRow(title: String, note: String, bytes: Long, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(bottom = 8.dp).clip(RoundedCornerShape(16.dp)).background(VoiidColor.surfaceCard)
            .border(2.dp, if (selected) VoiidColor.accent else Color.Transparent, RoundedCornerShape(16.dp))
            .softClickable(scale = 0.98f) { if (!selected) onClick() }
            .padding(horizontal = 14.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(if (selected) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked, null,
            tint = if (selected) VoiidColor.accent else VoiidColor.textSecondary.copy(alpha = 0.5f), modifier = Modifier.size(22.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Text(note, style = VoiidFont.rounded(12.5f), color = VoiidColor.textSecondary)
        }
        Text("about ${ChatMediaLimit.text(bytes)}", style = VoiidFont.rounded(13, FontWeight.SemiBold),
            color = if (selected) VoiidColor.accentInk else VoiidColor.textSecondary)
    }
}

/** Too long for any quality: choose how much from the start to send. */
@Composable
private fun TrimCard(fullSeconds: Double, value: Float, onChange: (Float) -> Unit) {
    val maxFit = minOf(fullSeconds, ChatVideoPlanner.maxSeconds()).toFloat()
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(VoiidColor.surfaceCard).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Default.ContentCut, null, tint = VoiidColor.textPrimary, modifier = Modifier.size(16.dp))
            Text("Too long to send whole", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        }
        Text("Even at the lowest quality, ${clock(fullSeconds)} of video is over 25 MB. Send the first part of it.",
            style = VoiidFont.rounded(12.5f), color = VoiidColor.textSecondary)
        Row(verticalAlignment = Alignment.Bottom) {
            Text("First ${clock(value.toDouble())}", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Spacer(Modifier.weight(1f))
            Text("up to ${clock(maxFit.toDouble())}", style = VoiidFont.rounded(12.5f), color = VoiidColor.textSecondary)
        }
        Slider(value = value, onValueChange = { onChange(it.toInt().toFloat()) },
            valueRange = minOf(10f, maxFit)..maxFit,
            colors = SliderDefaults.colors(thumbColor = VoiidColor.accent, activeTrackColor = VoiidColor.accent))
    }
}

@Composable
private fun Notice(icon: ImageVector, tint: Color, title: String, body: String) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(VoiidColor.surfaceCard).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(icon, null, tint = tint, modifier = Modifier.size(18.dp))
            Text(title, style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        }
        Text(body, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
    }
}

@Composable
private fun Note(text: String) {
    Text(text, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary, modifier = Modifier.padding(horizontal = 4.dp))
}

@Composable
private fun WorkingCard(progress: Float) {
    val shown by animateFloatAsState(progress, tween(250), label = "progress")
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(VoiidColor.surfaceCard).padding(vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        val track = VoiidColor.fieldFill
        val ink = VoiidColor.accent
        Box(Modifier.size(104.dp), contentAlignment = Alignment.Center) {
            Canvas(Modifier.fillMaxSize()) {
                val stroke = 7.dp.toPx()
                val inset = stroke / 2
                val arc = androidx.compose.ui.geometry.Size(size.width - stroke, size.height - stroke)
                drawArc(track, 0f, 360f, false, Offset(inset, inset), arc, style = Stroke(stroke))
                drawArc(ink, -90f, 360f * shown, false, Offset(inset, inset), arc, style = Stroke(stroke, cap = StrokeCap.Round))
            }
            Text("${(progress * 100).toInt()}%", style = VoiidFont.rounded(22, FontWeight.Bold), color = VoiidColor.textPrimary)
        }
        Text("Compressing on this phone", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        Text("Keep Voiid open until it's done.", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
    }
}

@Composable
private fun DoneCard(from: Long, to: Long) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(VoiidColor.surfaceCard).padding(vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(Icons.Default.CheckCircle, null, tint = VoiidColor.success, modifier = Modifier.size(52.dp))
        Text("${ChatMediaLimit.text(from)} → ${ChatMediaLimit.text(to)}", style = VoiidFont.rounded(17, FontWeight.Bold),
            color = VoiidColor.textPrimary)
        Text("Sending…", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
    }
}

@Composable
private fun PrimaryPill(title: String, onClick: () -> Unit) {
    Box(Modifier.fillMaxWidth().height(52.dp).clip(RoundedCornerShape(50)).background(VoiidColor.accent)
        .softClickable(scale = 0.97f, onClick = onClick), contentAlignment = Alignment.Center) {
        Text(title, style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textOnAccent, maxLines = 1)
    }
}

private fun clock(s: Double): String {
    val t = s.toInt()
    return if (t >= 3600) "%d:%02d:%02d".format(t / 3600, (t / 60) % 60, t % 60) else "%d:%02d".format(t / 60, t % 60)
}

// ── Document bubble ────────────────────────────────────────────────────────────

/**
 * A document in the transcript: the kind of file, its name, and a tap that decrypts it and
 * hands it to whatever app opens that type. The name is the caption iOS sends with a document.
 */
@Composable
internal fun ChatDocumentBubble(message: VMessage) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()
    val ref = message.mediaRef
    val name = ref?.filename ?: message.text.ifBlank { "Document" }
    val ext = name.substringAfterLast('.', "").uppercase().take(4)
    var opening by remember { mutableStateOf(false) }
    val sending = message.status == MessageStatus.SENDING
    val onBubble = message.isMine

    Row(
        Modifier.widthIn(min = 220.dp, max = 280.dp).clip(RoundedCornerShape(14.dp))
            .background(if (onBubble) Color.White.copy(alpha = 0.16f) else VoiidColor.fieldFill)
            .softClickable(scale = 0.97f) {
                if (ref == null || opening) return@softClickable
                haptics.tap()
                opening = true
                scope.launch {
                    val ok = openDocument(context, ref, name)
                    opening = false
                    if (!ok) android.widget.Toast.makeText(context, "No app here can open this file.", android.widget.Toast.LENGTH_SHORT).show()
                }
            }
            .padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.size(width = 40.dp, height = 48.dp).clip(RoundedCornerShape(8.dp))
            .background(if (ext == "PDF") Color(0xFFE5483F) else Color(0xFF548AF2)), contentAlignment = Alignment.Center) {
            if (sending || opening) CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
            else Text(ext.ifEmpty { "FILE" }, style = VoiidFont.rounded(10, FontWeight.Bold), color = Color.White)
        }
        Column(Modifier.weight(1f)) {
            Text(name, style = VoiidFont.rounded(15, FontWeight.SemiBold), color = bubbleText(onBubble),
                maxLines = 2, overflow = TextOverflow.MiddleEllipsis)
            Text(if (sending) "Sending…" else "${ext.ifEmpty { "File" }} · Tap to open",
                style = VoiidFont.rounded(12), color = bubbleTextSecondary(onBubble))
        }
    }
}

/** Decrypt into the cache under its own name, then open it with a viewer app. */
private suspend fun openDocument(context: Context, ref: ChatEngine.MediaRef, name: String): Boolean {
    val file = withContext(Dispatchers.IO) {
        runCatching {
            val bytes = MediaCache.data(context, ref.mediaUrl)
                ?: ChatEngine.get(context).fetchMedia(ref).also { MediaCache.putData(context, ref.mediaUrl, it) }
            val dir = File(context.cacheDir, "chat-docs/${ref.mediaUrl.hashCode().toUInt()}").apply { mkdirs() }
            val safe = name.replace(Regex("[/\\\\:*?\"<>|]"), "_").ifBlank { "document" }
            File(dir, safe).apply { writeBytes(bytes) }
        }.getOrNull()
    } ?: return false
    val uri = androidx.core.content.FileProvider.getUriForFile(context, "${context.packageName}.chatmedia", file)
    val intent = Intent(Intent.ACTION_VIEW).apply {
        setDataAndType(uri, ref.mime.ifBlank { "application/octet-stream" })
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    return runCatching { context.startActivity(Intent.createChooser(intent, name).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true }
        .getOrDefault(false)
}

/** Remove a compressor's temporary output once it has been read for sending. */
internal fun cleanUpCompressed(context: Context, vararg files: File?) {
    files.forEach { ChatAttachmentIntake.removeTemporary(context, it) }
}
