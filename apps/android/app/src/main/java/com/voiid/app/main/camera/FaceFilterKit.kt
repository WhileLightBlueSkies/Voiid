package com.voiid.app.main.camera

import android.graphics.Bitmap
import androidx.camera.view.PreviewView
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import com.voiid.app.main.clips.ClipFaceDetector
import com.voiid.app.main.clips.ClipFaceEffect
import com.voiid.app.main.clips.ClipFaceRenderer
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidFont
import java.io.ByteArrayOutputStream

/**
 * The face-filter pieces every Voiid camera shares — clips, Moments, chat and the profile
 * photo — so a filter looks and behaves the same wherever the camera opens. Port of iOS
 * `FaceLensRail.swift`.
 */

/** Two-stop gradient behind each lens, matching iOS `ClipFaceEffect.lensColors`. */
val ClipFaceEffect.lensColors: List<Color>
    get() = when (this) {
        ClipFaceEffect.NONE -> listOf(Color.White.copy(alpha = 0.22f), Color.White.copy(alpha = 0.10f))
        ClipFaceEffect.DOG -> listOf(Color(0xFFD69460), Color(0xFF8C542E))
        ClipFaceEffect.TIGER -> listOf(Color(0xFFFF9E29), Color(0xFFCC4D0D))
        ClipFaceEffect.PARTY -> listOf(Color(0xFFFF5CB3), Color(0xFF8C4DFF))
        ClipFaceEffect.CYBER -> listOf(Color(0xFF1AF2E6), Color(0xFF3359FF))
        ClipFaceEffect.BUNNY -> listOf(Color(0xFFFFC7DB), Color(0xFFED7AA8))
        ClipFaceEffect.KOALA -> listOf(Color(0xFFB8C2D1), Color(0xFF6B758A))
        ClipFaceEffect.CAT -> listOf(Color(0xFFFAD173), Color(0xFFE68538))
        ClipFaceEffect.SUNGLASSES -> listOf(Color(0xFF4D4D57), Color(0xFF14141A))
        ClipFaceEffect.CROWN -> listOf(Color(0xFFFFE059), Color(0xFFDB9914))
        ClipFaceEffect.HALO -> listOf(Color(0xFFFFF7CC), Color(0xFFFAD666))
        ClipFaceEffect.DEVIL -> listOf(Color(0xFFFF4D3D), Color(0xFF9E0D1A))
    }

/**
 * A carousel of round lenses. The selected one grows, gets a white ring and centres itself,
 * and its name floats above the rail — one label reads cleanly, twelve do not.
 */
@Composable
fun FaceLensRail(
    selected: ClipFaceEffect,
    onSelect: (ClipFaceEffect) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val haptics = LocalVoiidHaptics.current
    val listState = rememberLazyListState()
    val effects = ClipFaceEffect.entries

    LaunchedEffect(selected) {
        // Centre the chosen lens: scroll it to the front, then back off by half the viewport.
        val index = effects.indexOf(selected)
        val info = listState.layoutInfo
        val viewport = info.viewportEndOffset - info.viewportStartOffset
        val item = info.visibleItemsInfo.firstOrNull()?.size ?: 0
        listState.animateScrollToItem(index, -(viewport / 2 - item / 2).coerceAtLeast(0))
    }

    Column(
        modifier.fillMaxWidth().alpha(if (enabled) 1f else 0.4f),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            if (selected == ClipFaceEffect.NONE) "No filter" else selected.label,
            style = VoiidFont.rounded(13, FontWeight.SemiBold),
            color = Color.White,
            modifier = Modifier
                .clip(CircleShape)
                .background(Color.Black.copy(alpha = 0.35f))
                .padding(horizontal = 10.dp, vertical = 3.dp),
        )
        LazyRow(
            state = listState,
            modifier = Modifier.fillMaxWidth().height(74.dp),
            contentPadding = PaddingValues(horizontal = 20.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            itemsIndexed(effects) { _, effect ->
                val on = effect == selected
                val scale by animateFloatAsState(
                    targetValue = if (on) 1.12f else 0.92f,
                    animationSpec = spring(dampingRatio = 0.7f, stiffness = Spring.StiffnessMediumLow),
                    label = "lensScale",
                )
                Box(
                    Modifier
                        .size(54.dp)
                        .graphicsLayer { scaleX = scale; scaleY = scale }
                        .shadow(6.dp, CircleShape)
                        .clip(CircleShape)
                        .background(Brush.linearGradient(effect.lensColors))
                        .border(
                            width = if (on) 3.dp else 1.dp,
                            color = Color.White.copy(alpha = if (on) 1f else 0.35f),
                            shape = CircleShape,
                        )
                        .softClickable(scale = 0.9f, enabled = enabled) {
                            if (effect != selected) {
                                haptics.selection()
                                onSelect(effect)
                            }
                        }
                        .semantics {
                            contentDescription =
                                if (effect == ClipFaceEffect.NONE) "No filter" else "${effect.label} filter"
                            this.selected = on
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        if (effect == ClipFaceEffect.NONE) "⊘" else effect.icon,
                        style = VoiidFont.rounded(24),
                        color = Color.White,
                    )
                }
            }
        }
    }
}

/** The tracked sprites, drawn over a PreviewView of the same size. */
@Composable
fun FaceFilterOverlay(detector: ClipFaceDetector, effect: ClipFaceEffect, modifier: Modifier = Modifier) {
    if (effect == ClipFaceEffect.NONE) return
    val face = detector.trackedFace ?: return
    Canvas(modifier.fillMaxSize()) {
        // Keeping the detector's idea of the view size in step with what is drawn means the
        // mapping cannot drift after a resize.
        detector.viewWidth = size.width
        detector.viewHeight = size.height
        with(ClipFaceRenderer) {
            drawFaceEffect(
                face = face,
                effect = effect,
                previewWidth = size.width,
                previewHeight = size.height,
                cameraSourceWidth = detector.sourceWidth,
                cameraSourceHeight = detector.sourceHeight,
            )
        }
    }
}

/**
 * A JPEG of exactly what the viewfinder shows, filter included.
 *
 * ImageCapture never sees the face filter — it is drawn over the preview, not into the
 * stream — so a photo from it would come back without the ears the person was looking at.
 * The preview's own bitmap is already in view space (cropped, rotated and, on the front
 * lens, mirrored), which is the same space the detector publishes faces in, so the sprites
 * land where they were on screen with no extra mapping.
 *
 * Needs the PreviewView in COMPATIBLE mode: a SurfaceView preview has no readable bitmap.
 */
fun captureFilteredStill(
    previewView: PreviewView,
    detector: ClipFaceDetector,
    effect: ClipFaceEffect,
    squareCrop: Boolean = false,
): ByteArray? {
    val frame = previewView.bitmap ?: return null
    var out = frame.copy(Bitmap.Config.ARGB_8888, true)
    frame.recycle()
    val face = detector.trackedFace
    if (effect != ClipFaceEffect.NONE && face != null) {
        val canvas = androidx.compose.ui.graphics.Canvas(out.asImageBitmap())
        CanvasDrawScope().draw(
            Density(previewView.resources.displayMetrics.density),
            LayoutDirection.Ltr,
            canvas,
            Size(out.width.toFloat(), out.height.toFloat()),
        ) {
            with(ClipFaceRenderer) {
                drawFaceEffect(
                    face = face,
                    effect = effect,
                    previewWidth = size.width,
                    previewHeight = size.height,
                    cameraSourceWidth = detector.sourceWidth,
                    cameraSourceHeight = detector.sourceHeight,
                )
            }
        }
    }
    if (squareCrop) {
        val side = minOf(out.width, out.height)
        val x = (out.width - side) / 2
        // Biased to where the selfie guide sits (42% down), matching iOS.
        val y = ((out.height * 0.42f).toInt() - side / 2).coerceIn(0, out.height - side)
        val cropped = Bitmap.createBitmap(out, x, y, side, side)
        if (cropped !== out) out.recycle()
        out = cropped
    }
    return ByteArrayOutputStream().use { stream ->
        out.compress(Bitmap.CompressFormat.JPEG, 88, stream)
        out.recycle()
        stream.toByteArray()
    }
}
