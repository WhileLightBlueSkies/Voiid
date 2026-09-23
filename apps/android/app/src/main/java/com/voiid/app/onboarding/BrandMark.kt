package com.voiid.app.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import androidx.compose.material3.Text
import com.voiid.app.ui.theme.VoiidFont

/**
 * The Voiid wordmark. Port of iOS `BrandWordmark` in `DesignSystem/BrandMark.swift`.
 *
 * ── WHY THE DOTS ARE DRAWN RATHER THAN COLOURED ──────────────────────────────────
 * You cannot recolour part of a glyph. `Text("voiid")` is one run, and a tittle is baked
 * into the `i` outline — there is no way to reach it. So the two `i`s are set with the
 * DOTLESS form (U+0131, "ı") and the dots are drawn as circles on top. Same trick the web
 * wordmark uses, for the same reason.
 *
 * Android previously drew `Text("voiid")` in the logo face with no accent dots at all — and
 * the dots ARE the wordmark. A white "voiid" with no tittles is not the mark in a different
 * colour; it is a word.
 *
 * Every measurement is derived from [size] rather than fixed, so the mark holds together at
 * 14sp in a toolbar and 48sp in a lockup. A fixed 4dp dot looks like a full stop at one end
 * of that range and a bullet at the other.
 */
@Composable
fun BrandWordmark(
    size: Int,
    modifier: Modifier = Modifier,
    color: Color = Color.White,
    /** The two i-dots. Always the accent — that IS the wordmark. */
    dotColor: Color = VoiidBrand.lime,
    alpha: Float = 1f,
) {
    val sizeF = size.toFloat()
    val density = androidx.compose.ui.platform.LocalDensity.current
    val fontPx = with(density) { size.sp.toPx() }
    var layout by androidx.compose.runtime.remember {
        androidx.compose.runtime.mutableStateOf<androidx.compose.ui.text.TextLayoutResult?>(null)
    }
    // Shape the entire word together: separate Text boxes lose tracking at the i/i boundary.
    // Place each dot over its actual glyph and relative to the baseline, not the line-box top.
    Text(
        "Vo\u0131\u0131d",
        style = VoiidFont.rounded(size, FontWeight.Bold).copy(
            letterSpacing = (-0.02f).em,
            platformStyle = androidx.compose.ui.text.PlatformTextStyle(includeFontPadding = false),
        ),
        color = color.copy(alpha = color.alpha * alpha),
        maxLines = 1,
        softWrap = false,
        onTextLayout = { layout = it },
        modifier = modifier
            .offset(x = -(sizeF * 0.022f).dp)
            .clearAndSetSemantics { contentDescription = "Voiid" }
            .drawWithContent {
                drawContent()
                layout?.let { measured ->
                    for (index in 2..3) {
                        val glyph = measured.getBoundingBox(index)
                        drawCircle(
                            color = dotColor.copy(alpha = dotColor.alpha * alpha),
                            radius = fontPx * 0.0825f,
                            center = androidx.compose.ui.geometry.Offset(
                                glyph.center.x,
                                measured.firstBaseline - fontPx * 0.65f,
                            ),
                        )
                    }
                }
            },
    )
}
