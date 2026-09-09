package com.voiid.app.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
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
    /**
     * Dot diameter as a fraction of cap height, tuned against the rounded face's own tittle so
     * the drawn dots read as belonging to the letters rather than floating above them.
     */
    val dotSize = (sizeF * 0.165f).dp
    /**
     * How far the dots sit above the stem, measured from the glyph's TOP edge — so a SMALLER
     * number lifts the dot. At 0.30 they rested ON the stems and read as part of the letter;
     * a tittle needs visible air under it to read as its own mark.
     */
    val dotRise = (sizeF * 0.10f).dp

    val face = VoiidFont.rounded(size, FontWeight.Bold).copy(
        // Negative and proportional: letters read progressively further apart as they grow,
        // so one fixed letter-spacing is wrong at either end of the range.
        letterSpacing = (-0.02f).em,
    )

    Row(
        modifier
            // OPTICAL centring, not geometric. `V` is a diagonal that leaves open space at its
            // lower-left while `d` ends in a hard vertical stem, so the visual mass sits right
            // of the box's midpoint even when the box is perfectly centred. Typographers
            // correct this by eye; so does this.
            .offset(x = -(sizeF * 0.022f).dp)
            .clearAndSetSemantics { contentDescription = "Voiid" },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Glyph("Vo", face, color, alpha)
        StemWithDot(face, color, dotColor, dotSize, dotRise, alpha)
        StemWithDot(face, color, dotColor, dotSize, dotRise, alpha)
        Glyph("d", face, color, alpha)
    }
}

@Composable
private fun Glyph(text: String, face: TextStyle, color: Color, alpha: Float) {
    Text(text, style = face, color = color.copy(alpha = color.alpha * alpha))
}

/**
 * A dotless stem with its dot drawn above.
 *
 * The dot is positioned relative to the STEM rather than to the line, so the pair stays
 * locked to its letter when the type scales instead of drifting apart.
 */
@Composable
private fun StemWithDot(
    face: TextStyle,
    color: Color,
    dotColor: Color,
    dotSize: androidx.compose.ui.unit.Dp,
    dotRise: androidx.compose.ui.unit.Dp,
    alpha: Float,
) {
    Box(contentAlignment = Alignment.TopCenter) {
        // U+0131 LATIN SMALL LETTER DOTLESS I.
        Text("ı", style = face, color = color.copy(alpha = color.alpha * alpha))
        Box(
            Modifier
                .offset(y = dotRise)
                .size(dotSize)
                .clip(CircleShape)
                .background(dotColor.copy(alpha = dotColor.alpha * alpha))
        )
    }
}
