package com.voiid.app.ui.theme

import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp

/**
 * Continuous squircle shape (superellipse) matching Apple's `RoundedRectangle(style: .continuous)`.
 *
 * Traditional [androidx.compose.foundation.shape.RoundedCornerShape] uses circular arc fillets
 * with sudden curvature transitions at tangent points. A squircle smooths the transition
 * with continuous curvature (G2 continuity approximation).
 */
class SquircleShape(
    val cornerRadius: Dp = 16.dp,
    val smoothness: Float = 0.6f,
) : Shape {
    override fun createOutline(
        size: Size,
        layoutDirection: LayoutDirection,
        density: Density
    ): Outline {
        val rPx = with(density) { cornerRadius.toPx() }.coerceAtMost(minOf(size.width, size.height) / 2f)
        if (rPx <= 0f) {
            return Outline.Rectangle(androidx.compose.ui.geometry.Rect(0f, 0f, size.width, size.height))
        }

        val path = Path().apply {
            val w = size.width
            val h = size.height
            val s = smoothness.coerceIn(0f, 1f)
            val p = rPx * (1f + s)

            reset()
            // Top edge
            moveTo(rPx, 0f)
            lineTo(w - rPx, 0f)
            // Top-right corner
            cubicTo(w - rPx + p * 0.5f, 0f, w, rPx - p * 0.5f, w, rPx)
            // Right edge
            lineTo(w, h - rPx)
            // Bottom-right corner
            cubicTo(w, h - rPx + p * 0.5f, w - rPx + p * 0.5f, h, w - rPx, h)
            // Bottom edge
            lineTo(rPx, h)
            // Bottom-left corner
            cubicTo(rPx - p * 0.5f, h, 0f, h - rPx + p * 0.5f, 0f, h - rPx)
            // Left edge
            lineTo(0f, rPx)
            // Top-left corner
            cubicTo(0f, rPx - p * 0.5f, rPx - p * 0.5f, 0f, rPx, 0f)
            close()
        }

        return Outline.Generic(path)
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is SquircleShape) return false
        return cornerRadius == other.cornerRadius && smoothness == other.smoothness
    }

    override fun hashCode(): Int {
        var result = cornerRadius.hashCode()
        result = 31 * result + smoothness.hashCode()
        return result
    }
}
