package com.voiid.app.main.clips

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Build
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.core.content.res.ResourcesCompat
import com.voiid.app.R
import com.voiid.app.ui.theme.VoiidFont
import java.util.UUID
import kotlin.math.ceil

/**
 * Text placed on a clip in the editor, and the one drawing of it the export burns in — so the
 * words land in the uploaded video where they sat on screen. Port of iOS ClipTextOverlay.swift.
 *
 * ONE LAYOUT, TWO RENDERERS. Everything is measured against the VIDEO's width, never the
 * screen's: the size is a fraction of the frame width and the position a fraction of the
 * frame. The editor lays the text out over the video's on-screen rect with those fractions;
 * the export draws the same fractions into the full-resolution frame, so a 1080-wide export
 * and a 390dp-wide phone agree.
 */
data class ClipTextOverlay(
    val id: String = UUID.randomUUID().toString(),
    val text: String,
    val color: Int = 0,
    val pill: Boolean = false,
    /** Centre of the text, 0…1 of the video frame, y down. */
    val x: Float = 0.5f,
    val y: Float = 0.4f,
) {
    val fill: Int get() = PALETTE[color.coerceIn(0, PALETTE.lastIndex)]
    /** The letters' colour: the palette colour, or on a pill the colour that reads on it. */
    val ink: Int get() = if (pill) (if (color == 0) android.graphics.Color.BLACK else android.graphics.Color.WHITE) else fill

    companion object {
        /** Font size as a fraction of the frame width: 28 on a 390-wide frame. */
        const val FONT_FRACTION = 28f / 390f
        /** Longest line before wrapping, as a fraction of the frame width. */
        const val WRAP_FRACTION = 300f / 390f
        const val MAX_LENGTH = 120

        val PALETTE = intArrayOf(
            android.graphics.Color.WHITE,
            android.graphics.Color.BLACK,
            android.graphics.Color.rgb(19, 130, 140),
            android.graphics.Color.rgb(255, 214, 51),
            android.graphics.Color.rgb(255, 97, 140),
            android.graphics.Color.rgb(89, 153, 255),
        )
    }
}

/** Draws the overlays into a transparent frame-sized bitmap for the exporter. */
object ClipTextRenderer {
    private fun typeface(context: Context): Typeface {
        val base = runCatching { ResourcesCompat.getFont(context, R.font.nunito_variable) }.getOrNull()
            ?: Typeface.DEFAULT
        return if (Build.VERSION.SDK_INT >= 28) Typeface.create(base, 700, false)
        else Typeface.create(base, Typeface.BOLD)
    }

    /** Null when there is nothing to draw. */
    fun overlay(context: Context, texts: List<ClipTextOverlay>, width: Int, height: Int): Bitmap? {
        val visible = texts.filter { it.text.isNotBlank() }
        if (visible.isEmpty() || width <= 0 || height <= 0) return null
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val face = typeface(context)
        visible.forEach { draw(canvas, it, width, height, face) }
        return bitmap
    }

    private fun draw(canvas: Canvas, item: ClipTextOverlay, width: Int, height: Int, face: Typeface) {
        val size = width * ClipTextOverlay.FONT_FRACTION
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = face
            textSize = size
            color = item.ink
            if (!item.pill) setShadowLayer(size * 0.14f, 0f, size * 0.035f, android.graphics.Color.argb(115, 0, 0, 0))
        }
        val wrap = (width * ClipTextOverlay.WRAP_FRACTION).toInt()
        // Measure the widest line so the pill hugs the text instead of spanning the wrap width.
        val probe = StaticLayout.Builder.obtain(item.text, 0, item.text.length, paint, wrap)
            .setAlignment(Layout.Alignment.ALIGN_CENTER).build()
        val lineWidth = (0 until probe.lineCount).maxOf { probe.getLineWidth(it) }
        val layoutWidth = ceil(lineWidth).toInt().coerceIn(1, wrap)
        val layout = StaticLayout.Builder.obtain(item.text, 0, item.text.length, paint, layoutWidth)
            .setAlignment(Layout.Alignment.ALIGN_CENTER).build()

        val cx = item.x * width
        val cy = item.y * height
        val left = cx - layout.width / 2f
        val top = cy - layout.height / 2f

        if (item.pill) {
            val padX = size * 0.5f
            val padY = size * 0.21f
            val r = size * 0.36f
            val bg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = item.fill }
            canvas.drawRoundRect(RectF(left - padX, top - padY, left + layout.width + padX,
                top + layout.height + padY), r, r, bg)
        }
        canvas.save()
        canvas.translate(left, top)
        layout.draw(canvas)
        canvas.restore()
    }
}

/** The same text in Compose, sized for a video that is [frameWidth] wide on screen. */
@Composable
fun ClipTextLabel(item: ClipTextOverlay, frameWidth: Dp, modifier: Modifier = Modifier) {
    val density = LocalDensity.current
    val sizeDp = frameWidth * ClipTextOverlay.FONT_FRACTION
    // Pinned to the frame, not the user's font scale: the export has no font scale.
    val sizeSp = with(density) { (sizeDp.toPx() / (density.density * density.fontScale)) }
    val style = VoiidFont.rounded(sizeSp, FontWeight.Bold).let {
        if (item.pill) it else it.copy(shadow = Shadow(Color(0x73000000),
            Offset(0f, with(density) { (sizeDp * 0.035f).toPx() }), with(density) { (sizeDp * 0.14f).toPx() }))
    }
    Text(
        item.text,
        style = style,
        color = Color(item.ink),
        textAlign = TextAlign.Center,
        modifier = modifier
            .widthIn(max = frameWidth * ClipTextOverlay.WRAP_FRACTION + if (item.pill) sizeDp else Dp(0f))
            .then(
                if (item.pill) Modifier
                    .background(Color(item.fill), RoundedCornerShape(sizeDp * 0.36f))
                    .padding(horizontal = sizeDp * 0.5f, vertical = sizeDp * 0.21f)
                else Modifier
            ),
    )
}
