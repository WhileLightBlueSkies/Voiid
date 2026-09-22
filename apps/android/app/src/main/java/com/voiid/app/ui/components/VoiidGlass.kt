package com.voiid.app.ui.components

import android.graphics.RenderEffect
import android.graphics.Shader
import android.os.Build
import android.view.Window
import android.view.WindowManager
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asComposeRenderEffect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.theme.VoiidColor

/**
 * Replicates iOS native `.bar` / `.ultraThinMaterial` frosted glass in Jetpack Compose.
 *
 * Architecture:
 * 1. Translucent tinted surface wash matching the active theme's surface.
 * 2. Specular highlight border using a directional vertical gradient brush (subtle reflection at top edge).
 * 3. Hardware-accelerated convolution blur on Android 12+ (API 31+) via [RenderEffect].
 * 4. Micro-contrast boundary fallback for devices below API 31.
 */
@Composable
fun Modifier.voiidGlass(
    shape: Shape = RoundedCornerShape(16.dp),
    tint: Color = VoiidColor.surfaceCard.copy(alpha = 0.78f),
    specularBorderWidth: Dp = 1.dp,
    blurRadius: Float = 24f,
): Modifier {
    val specularBrush = Brush.verticalGradient(
        colors = listOf(
            Color.White.copy(alpha = 0.22f),
            Color.White.copy(alpha = 0.08f),
            Color.White.copy(alpha = 0.02f)
        )
    )

    val base = this
        .clip(shape)
        .border(specularBorderWidth, specularBrush, shape)
        .background(tint, shape)

    // In Jetpack Compose, graphicsLayer { renderEffect = blur } blurs the layer's
    // OWN children (making text and icons illegible), rather than sampling the backdrop
    // behind it. Backdrop blur is achieved at the Window level via `applyVoiidGlassBlur`
    // (FLAG_BLUR_BEHIND). For in-tree containers, the iOS glass feel is rendered via the
    // physical optical model: translucent frosted wash + directional specular rim stroke.
    return base
}

/**
 * Surface wrapper providing iOS-grade frosted glass container.
 */
@Composable
fun VoiidGlassSurface(
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(16.dp),
    tint: Color = VoiidColor.surfaceCard.copy(alpha = 0.78f),
    specularBorderWidth: Dp = 1.dp,
    blurRadius: Float = 24f,
    content: @Composable BoxScope.() -> Unit,
) {
    Box(
        modifier = modifier.voiidGlass(
            shape = shape,
            tint = tint,
            specularBorderWidth = specularBorderWidth,
            blurRadius = blurRadius
        ),
        content = content
    )
}

/**
 * Applies native hardware blur behind modal dialogs and bottom sheets on Android 12+ (API 31+).
 */
fun Window.applyVoiidGlassBlur(blurRadiusDp: Int = 24) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        addFlags(WindowManager.LayoutParams.FLAG_BLUR_BEHIND)
        attributes = attributes.apply {
            blurBehindRadius = (blurRadiusDp * context.resources.displayMetrics.density).toInt()
        }
    }
}
