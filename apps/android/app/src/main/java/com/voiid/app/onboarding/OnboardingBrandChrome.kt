package com.voiid.app.onboarding

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowForward
import androidx.compose.material.icons.outlined.HelpOutline
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.R
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/**
 * The shared skeleton behind the branded onboarding screens (welcome/terms, permissions).
 * Twin of iOS `Onboarding/OnboardingBrandChrome.swift` — keep the two in step.
 *
 * WHY THIS IS ONE FILE AND NOT COPIED INTO BOTH SCREENS
 * ----------------------------------------------------
 * Both screens are the same composition: glowing mark over a horizon, a card of rows, a
 * privacy footnote, a lime pill. Building that twice here and twice on iOS is four places for
 * the glow radius or the card corner to drift, and drift is what makes a designed app look
 * assembled rather than designed.
 *
 * BOTH SCREENS COMMIT TO DARK and ignore the theme override, deliberately. The glow and the
 * horizon are light bleeding onto near-black; on a white ground there is nothing to bleed into
 * and the composition collapses. First run is also the one place a fixed look is safe, because
 * the user has not chosen a theme yet.
 */
object OnboardingBrand {
    /** Voiid Black — the onboarding ground, fixed in both themes. */
    val ground = Color(0xFF0B0B0B)
    /** The card behind a group of rows. */
    val card = Color(0xFF121212)
    /** A row inside that card, one step up so it separates from the card it sits on. */
    val row = Color(0xFF181818)
    /** Hairlines: white at low alpha, so they stay correct if the surfaces are re-tuned. */
    val hairline = Color.White.copy(alpha = 0.07f)
    /** Electric Lime. */
    val lime = Color(0xFFC6FF00)
    /** The mark's lit top edge, and the pill's highlight. */
    val limeBright = Color(0xFFE4FF6B)
    /** The pill's lower stop. */
    val limeDeep = Color(0xFFB4EC00)
}

/**
 * The "V" mark with its bloom, sitting on a horizon arc.
 *
 * PLACEHOLDER geometry — two strokes meeting at a point, which is the reference mark at its
 * simplest. When the real art lands, swap the path for the asset and keep the glow passes:
 * they are what make it read as lit rather than pasted on.
 */
/** The band the mark and horizon occupy. Fixed so the three screens' headers line up. */
val OnboardingHeaderHeight = 190.dp

@Composable
fun OnboardingBrandHeader(
    markSize: Dp = 132.dp,
    appeared: Boolean = true,
    modifier: Modifier = Modifier,
) {
    val alpha by animateFloatAsState(if (appeared) 1f else 0f, tween(500), label = "markAlpha")
    val scale by animateFloatAsState(if (appeared) 1f else 0.94f, tween(500), label = "markScale")

    Box(
        modifier
            .fillMaxWidth()
            .height(OnboardingHeaderHeight),
        contentAlignment = Alignment.Center,
    ) {
        // HORIZON. An arc from a circle far wider than the screen, pushed down so only its top
        // edge crosses the layout — that is what reads as a planet curve rather than an arc
        // someone drew. The stroke fades to nothing at both ends, because a hairline that
        // stops mid-air looks like a clipping bug.
        Box(
            Modifier.fillMaxWidth().height(OnboardingHeaderHeight).drawBehind {
                val w = size.width * 2.6f
                val left = (size.width - w) / 2f
                val top = size.height * 0.86f
                drawArc(
                    brush = Brush.horizontalGradient(
                        0f to Color.Transparent,
                        0.5f to OnboardingBrand.lime.copy(alpha = 0.5f),
                        1f to Color.Transparent,
                    ),
                    startAngle = 180f,
                    sweepAngle = 180f,
                    useCenter = false,
                    topLeft = Offset(left, top),
                    size = Size(w, w),
                    style = Stroke(width = 1.5f * density),
                )
            },
        )

        VMark(
            size = markSize,
            modifier = Modifier
                .padding(bottom = 30.dp)
                .graphicsLayer {
                    this.alpha = alpha
                    scaleX = scale
                    scaleY = scale
                },
        )
    }
}

/**
 * The mark, with its bloom.
 *
 * The ART IS NOW REAL (res/drawable/voiid_logomark) — three rounded bars forming the V. The bloom
 * passes stay, because the drawable is a flat fill and the glow is what makes it read as lit
 * rather than pasted on. Blurred copies of the same image is how you bloom an asset you cannot
 * re-stroke.
 */
@Composable
fun VMark(size: Dp, modifier: Modifier = Modifier) {
    Box(modifier.size(size), contentAlignment = Alignment.Center) {
        // Three passes at widening blur. ONE reads as a drop shadow; three read as light,
        // because real bloom falls off gradually rather than in a single step.
        listOf(0.55f to 5.dp, 0.34f to 12.dp, 0.20f to 22.dp).forEach { (a, blur) ->
            Image(
                painter = painterResource(R.drawable.voiid_logomark),
                contentDescription = null,
                modifier = Modifier.size(size * 0.62f).blur(blur).alpha(a),
            )
        }
        Image(
            painter = painterResource(R.drawable.voiid_logomark),
            contentDescription = null,
            modifier = Modifier.size(size * 0.62f),
        )
    }
}

/**
 * The circled back / help pair the design puts above the mark.
 *
 * Circled outlines rather than bare glyphs: on a near-black ground with a glow behind it, a bare
 * icon at the screen edge reads as debris. The ring gives it a hit target you can see.
 */
@Composable
fun OnboardingTopBar(
    onBack: (() -> Unit)? = null,
    onHelp: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val haptics = LocalVoiidHaptics.current
    Row(
        modifier.fillMaxWidth().padding(horizontal = 20.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (onBack != null) {
            CircleIconButton(Icons.Default.ArrowBack, "Back") { haptics.tap(); onBack() }
        } else {
            // Holds the row height so the mark below does not shift between the screens that
            // have a back button and the ones that do not.
            Spacer(Modifier.size(44.dp))
        }
        Spacer(Modifier.weight(1f))
        if (onHelp != null) {
            CircleIconButton(Icons.Outlined.HelpOutline, "Help") { haptics.tap(); onHelp() }
        }
    }
}

@Composable
private fun CircleIconButton(icon: ImageVector, label: String, onClick: () -> Unit) {
    Box(
        Modifier
            .size(44.dp)
            .clip(CircleShape)
            .border(1.dp, Color.White.copy(alpha = 0.18f), CircleShape)
            .softClickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = label, tint = VoiidColor.textPrimary,
             modifier = Modifier.size(20.dp))
    }
}

/**
 * The four-up reassurance row: a lime glyph over two lines, divided by hairlines.
 *
 * Four columns of two words each. The copy is deliberately short — this is scanned, not read,
 * and a third line would turn it into a paragraph nobody finishes.
 */
@Composable
fun OnboardingTrustStrip(items: List<TrustItem>, modifier: Modifier = Modifier) {
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .background(OnboardingBrand.card)
            .border(1.dp, Color.White.copy(alpha = 0.06f), RoundedCornerShape(20.dp)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        items.forEachIndexed { index, item ->
            if (index > 0) {
                Box(
                    Modifier
                        .width(1.dp)
                        .height(52.dp)
                        .background(OnboardingBrand.hairline),
                )
            }
            Column(
                Modifier.weight(1f).padding(vertical = 16.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(item.icon, contentDescription = null, tint = OnboardingBrand.lime,
                     modifier = Modifier.size(22.dp))
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(item.line1, style = VoiidFont.rounded(13),
                         color = VoiidColor.textSecondary, textAlign = TextAlign.Center)
                    Text(item.line2, style = VoiidFont.rounded(13),
                         color = VoiidColor.textSecondary, textAlign = TextAlign.Center)
                }
            }
        }
    }
}

data class TrustItem(
    val id: String,
    val icon: ImageVector,
    val line1: String,
    val line2: String,
)

/**
 * A headline with exactly one lime run — the brand word.
 *
 * Colouring the whole line would spend the accent on a sentence and leave the brand no louder
 * than the greeting around it. Takes the parts explicitly so either order works: the design
 * uses "Welcome to **Voiid**" and "**Voiid** needs a few permissions".
 */
@Composable
fun OnboardingTitle(
    accented: String,
    leading: String = "",
    trailing: String = "",
    modifier: Modifier = Modifier,
) {
    Text(
        buildAnnotatedString {
            if (leading.isNotEmpty()) {
                withStyle(SpanStyle(color = VoiidColor.textPrimary)) { append(leading) }
            }
            withStyle(SpanStyle(color = OnboardingBrand.lime)) { append(accented) }
            if (trailing.isNotEmpty()) {
                withStyle(SpanStyle(color = VoiidColor.textPrimary)) { append(trailing) }
            }
        },
        // NEGATIVE tracking, because this is display type: letters read progressively further
        // apart as they grow, so body-copy spacing leaves a 30sp heading looking spaced out.
        // Matches iOS's -0.018em.
        style = VoiidFont.rounded(30, FontWeight.Bold).copy(letterSpacing = (-0.54).sp),
        textAlign = TextAlign.Center,
        modifier = modifier.padding(horizontal = 20.dp),
    )
}

/**
 * The rounded container a group of rows sits in.
 *
 * `flush` draws rows edge to edge with dividers (permissions) rather than as separate tiles
 * (terms). The design uses both, and the difference is only the padding.
 */
@Composable
fun OnboardingCard(
    flush: Boolean = false,
    modifier: Modifier = Modifier,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(OnboardingBrand.card)
            .border(1.dp, Color.White.copy(alpha = 0.06f), RoundedCornerShape(22.dp))
            .padding(if (flush) 0.dp else 18.dp),
        content = content,
    )
}

/**
 * A lime glyph in a rounded well — the permissions rows' leading element.
 *
 * Outlined glyph on a dark tile, never a filled lime square: at six repetitions a filled accent
 * would out-shout the button, and the accent's power on these screens is entirely in its rarity.
 */
@Composable
fun OnboardingGlyphTile(icon: ImageVector, size: Dp = 44.dp, modifier: Modifier = Modifier) {
    Box(
        modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.29f))
            .background(Color.White.copy(alpha = 0.04f))
            .border(1.dp, Color.White.copy(alpha = 0.06f), RoundedCornerShape(size * 0.29f)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = OnboardingBrand.lime,
             modifier = Modifier.size(size * 0.48f))
    }
}

/** The reassurance line above the button, with one lime run in the last line. */
@Composable
fun OnboardingPrivacyNote(
    icon: ImageVector,
    lines: List<String>,
    accentPhrase: String? = null,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(icon, contentDescription = null, tint = OnboardingBrand.lime,
             modifier = Modifier.size(22.dp))
        Column {
            lines.forEachIndexed { index, line ->
                val idx = if (index == lines.lastIndex && accentPhrase != null)
                    line.indexOf(accentPhrase) else -1
                if (idx >= 0 && accentPhrase != null) {
                    Text(
                        buildAnnotatedString {
                            withStyle(SpanStyle(color = VoiidColor.textSecondary)) {
                                append(line.substring(0, idx))
                            }
                            withStyle(SpanStyle(color = OnboardingBrand.lime)) { append(accentPhrase) }
                            withStyle(SpanStyle(color = VoiidColor.textSecondary)) {
                                append(line.substring(idx + accentPhrase.length))
                            }
                        },
                        style = VoiidFont.rounded(14),
                    )
                } else {
                    Text(line, style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
                }
            }
        }
    }
}

/**
 * The primary action. The brightest thing on the screen and the only thing that glows this
 * hard — which is what makes it unmissable without an arrow pointing at it.
 */
@Composable
fun OnboardingPrimaryButton(
    title: String,
    busy: Boolean = false,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    Box(
        modifier
            .fillMaxWidth()
            .height(62.dp)
            // The bloom, drawn behind the pill. Compose has no outer shadow with a colour, so
            // this is two blurred capsules rather than an elevation value.
            .drawBehind {
                val r = size.height / 2f
                listOf(0.42f to 22f, 0.22f to 44f).forEach { (a, blur) ->
                    drawRoundRect(
                        color = OnboardingBrand.lime.copy(alpha = a / 3f),
                        cornerRadius = androidx.compose.ui.geometry.CornerRadius(r + blur / 2f),
                        topLeft = Offset(-blur / 2f, -blur / 4f),
                        size = Size(size.width + blur, size.height + blur / 2f),
                    )
                }
            }
            .clip(CircleShape)
            .background(
                Brush.verticalGradient(
                    listOf(Color(0xFFD8FF45), OnboardingBrand.limeDeep),
                ),
            )
            .softClickable(enabled = !busy) { haptics.rigid(); onClick() },
        contentAlignment = Alignment.Center,
    ) {
        if (busy) {
            CircularProgressIndicator(
                color = Color(0xFF0B0B0B),
                modifier = Modifier.size(22.dp),
                strokeWidth = 2.dp,
            )
        } else {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 26.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Spacer(Modifier.width(1.dp))
                Text(
                    title,
                    style = VoiidFont.rounded(18, FontWeight.SemiBold),
                    // Black on lime — 16.59:1, the only correct label colour on this fill.
                    color = Color(0xFF0B0B0B),
                    modifier = Modifier.weight(1f),
                    textAlign = TextAlign.Center,
                )
                Icon(
                    Icons.Default.ArrowForward,
                    contentDescription = null,
                    tint = Color(0xFF0B0B0B),
                    modifier = Modifier.size(20.dp),
                )
            }
        }
    }
}
