package com.voiid.app.onboarding

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathMeasure
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.reduceMotionEnabled
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidPalette
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The success moment, after the code is accepted. Port of iOS `VerifiedScreen`.
 *
 * Onboarding is otherwise deliberately still; this screen is the exception because it happens
 * ONCE per account (the rare/first-time tier). It also has a job beyond delight: verification is
 * when login and E2E bootstrap are still settling, so the animation converts that wait into
 * confirmation.
 *
 * Choreography: ring draws → tick strokes on (overlapping the ring's tail) → both settle → copy
 * fades up. Sequenced so the eye sees the mark being MADE. Reduced motion presents the finished
 * mark instantly and keeps only the copy fade — a hard cut is its own jarring.
 */
@Composable
fun VerifiedScreen(
    onFinished: () -> Unit,
    holdAfterMs: Long = 1_100,
) {
    val haptics = LocalVoiidHaptics.current
    val reduceMotion = reduceMotionEnabled()
    // Resolve theme colours once at composition — the token getters are @Composable and cannot
    // be read inside draw lambdas.
    val groundColor = VoiidColor.background
    val primary = VoiidColor.primary
    val textPrimary = VoiidColor.textPrimary
    val textSecondary = VoiidColor.textSecondary

    // 0→1, draws the ring.
    val ring = remember { Animatable(0f) }
    // 0→1, strokes the tick.
    val tick = remember { Animatable(0f) }
    // The settle pop once the tick lands.
    val markScale = remember { Animatable(0.86f) }
    // One soft halo that expands and fades as the tick completes.
    val haloScale = remember { Animatable(0.9f) }
    val haloOpacity = remember { Animatable(0f) }
    val copyAlpha = remember { Animatable(0f) }

    LaunchedEffect(Unit) {
        if (reduceMotion) {
            // Present, but not drawn. See the header comment.
            ring.snapTo(1f)
            tick.snapTo(1f)
            markScale.snapTo(1f)
            haloOpacity.snapTo(0f)
            copyAlpha.animateTo(1f, tween(durationMillis = 300, easing = EaseOut))
        } else {
            coroutineScope {
                // 1. The ring sweeps closed. Ease-out settles at the join so the circle appears
                //    to close rather than to stop.
                launch { ring.animateTo(1f, tween(durationMillis = 450, easing = EaseOut)) }
                delay(260)

                // 2. The tick strokes on, overlapping the ring's tail — waiting for the ring to
                //    finish first would put a dead beat in the middle of the moment.
                launch { tick.animateTo(1f, tween(durationMillis = 300, easing = EaseOut)) }
                haptics.success()

                // 3. Everything settles together. Low bounce reads as confidence, not a toy.
                launch {
                    markScale.animateTo(
                        1f,
                        spring(dampingRatio = 0.72f, stiffness = Spring.StiffnessLow),
                    )
                }

                // Start visible FIRST, then animate away — assigning the final state before the
                // animation would show nothing at all.
                haloOpacity.snapTo(0.55f)
                launch { haloScale.animateTo(1.6f, tween(durationMillis = 750, easing = EaseOut)) }
                launch { haloOpacity.animateTo(0f, tween(durationMillis = 750, easing = EaseOut)) }

                delay(180)
                launch { copyAlpha.animateTo(1f, tween(durationMillis = 350, easing = EaseOut)) }
            }
        }
        delay(holdAfterMs)
        onFinished()
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(groundColor),
        contentAlignment = Alignment.Center,
    ) {
        // The pool of light, matching the splash's own. Static — it is a backdrop, not the event.
        Box(
            Modifier
                .fillMaxSize()
                .drawBehind {
                    drawRect(
                        Brush.radialGradient(
                            colors = listOf(
                                primary.copy(alpha = 0.13f),
                                primary.copy(alpha = 0.03f),
                                Color.Transparent,
                            ),
                            center = Offset(size.width * 0.5f, size.height * 0.42f),
                            radius = 320.dp.toPx(),
                        )
                    )
                }
        )

        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            VerifiedMark(primary, ring, tick, markScale, haloScale, haloOpacity)

            Text(
                "Verified",
                style = VoiidFont.rounded(30, FontWeight.Bold),
                color = textPrimary,
                modifier = Modifier.padding(top = 32.dp).copyFade(copyAlpha.value, reduceMotion),
            )
            Text(
                "Your number is confirmed.",
                style = VoiidFont.rounded(15),
                color = textSecondary,
                modifier = Modifier.padding(top = 8.dp).copyFade(copyAlpha.value, reduceMotion),
            )
        }
    }
}

/** Copy fades up 8pt as it appears; reduced motion fades in place. */
private fun Modifier.copyFade(progress: Float, reduceMotion: Boolean): Modifier =
    this
        .alpha(progress)
        .let { if (reduceMotion) it else it.offset(y = ((1f - progress) * 8).dp) }

/**
 * Ring (116dp, 4dp stroke), tick (54×40, 7dp stroke), halo pool (132dp).
 * Sizes and stroke weights are the iOS values exactly.
 */
@Composable
private fun VerifiedMark(
    primary: Color,
    ring: Animatable<Float, *>,
    tick: Animatable<Float, *>,
    markScale: Animatable<Float, *>,
    haloScale: Animatable<Float, *>,
    haloOpacity: Animatable<Float, *>,
) {
    val density = LocalDensity.current
    val brightStop = VoiidPalette.PrimaryDark   // #68B8BD — the lit edge stop in both themes

    Box(Modifier.size(132.dp).scale(markScale.value), contentAlignment = Alignment.Center) {
        Canvas(
            Modifier
                .size(132.dp)
                .scale(haloScale.value)
                .alpha(haloOpacity.value)
        ) {
            drawCircle(primary.copy(alpha = 0.16f))
        }

        Canvas(Modifier.size(116.dp)) {
            if (ring.value <= 0f) return@Canvas
            // Starts at 12 o'clock so the sweep closes at the top rather than reading arbitrary.
            drawArc(
                brush = Brush.linearGradient(
                    colors = listOf(brightStop, primary),
                    start = Offset(size.width * 0.25f, 0f),
                    end = Offset(size.width * 0.75f, size.height),
                ),
                startAngle = -90f,
                sweepAngle = 360f * ring.value,
                useCenter = false,
                style = Stroke(width = 4.dp.toPx(), cap = StrokeCap.Round),
            )
        }

        Canvas(Modifier.size(54.dp, 40.dp)) {
            if (tick.value <= 0f) return@Canvas
            // A checkmark as a PATH trimmed stroke-wise: one stroke, start to end.
            val path = Path().apply {
                moveTo(0f, size.height * 0.55f)
                lineTo(size.width * 0.34f, size.height)
                lineTo(size.width, 0f)
            }
            val measure = PathMeasure()
            measure.setPath(path, false)
            val partial = Path()
            measure.getSegment(0f, measure.length * tick.value, partial, true)
            drawPath(
                partial,
                primary,
                style = Stroke(
                    width = 7.dp.toPx(),
                    cap = StrokeCap.Round,
                    join = StrokeJoin.Round,
                ),
            )
        }
    }
}
