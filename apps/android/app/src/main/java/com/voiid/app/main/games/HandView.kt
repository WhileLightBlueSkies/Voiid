package com.voiid.app.main.games

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import kotlin.math.min

/**
 * Draws a [HandRig.Pose] (docs/games/VISUALS_AUDIO_AND_PARITY.md §3.4).
 *
 * TWO COLOURS AND ONE OUTLINE. Skin fill, dark ink outline, one soft highlight on the palm — the
 * flat pop-art look of the reference, not a rendered hand. Shading the fingers individually was
 * tried and muddies at the size these run at; the silhouette is what carries the read.
 *
 * LAYER ORDER IS LOAD-BEARING (§3.4): shadow, forearm, back fingers, palm, front fingers, thumb.
 * Ring and pinky pass BEHIND the palm in a fist, and drawing them in front is the single thing
 * that makes a closed hand look like a mitten.
 *
 * Ported from iOS `HandView.swift`.
 */
private val Skin = Color(0.98f, 0.82f, 0.69f)
private val SkinShade = Color(0.93f, 0.72f, 0.58f)
private val HandInk = Color(0.16f, 0.12f, 0.14f)

@Composable
fun HandView(
    pose: HandRig.Pose,
    modifier: Modifier = Modifier,
    /** Forearm rotation in degrees, from the pump choreography. */
    forearm: Float = 0f,
    /** The hand's own rotation, which LAGS the forearm — see HandRig.WRIST_FOLLOW. */
    wrist: Float = 0f,
    /** Mirrored for the opponent, so the two hands face each other. */
    mirrored: Boolean = false,
    /** Rock's knuckles pop on reveal. */
    knucklePop: Float = 1f,
) {
    Canvas(modifier.fillMaxSize().aspectRatio(1f)) {
        // Palm width is the unit everything in HandRig is expressed in.
        val unit = min(size.width, size.height) * 0.42f
        val origin = Offset(size.width / 2f, size.height * 0.60f)
        val direction = if (mirrored) -1f else 1f

        rotate(if (mirrored) -wrist else wrist, pivot = Offset(origin.x, size.height)) {
            drawHand(pose, unit, origin, direction, forearm, knucklePop)
        }
    }
}

private fun DrawScope.drawHand(
    pose: HandRig.Pose,
    unit: Float,
    origin: Offset,
    direction: Float,
    forearm: Float,
    knucklePop: Float,
) {
    fun place(p: Offset) = Offset(origin.x + p.x * unit, origin.y + p.y * unit)

    // Contact shadow on the panel. Shrinks and softens as the hand lifts, which is most of what
    // sells the pump as the hand actually moving rather than the image rotating.
    val lift = (-forearm).coerceAtLeast(0f) / 24f
    val shadowW = unit * (1.5f - lift * 0.35f)
    drawOval(
        color = Color.Black.copy(alpha = (0.22f - lift * 0.07f).coerceAtLeast(0f)),
        topLeft = Offset(origin.x - shadowW / 2f, origin.y + unit * 0.92f),
        size = Size(shadowW, unit * 0.22f),
    )

    // Forearm: a tapered capsule entering from the panel edge.
    val arm = Path().apply {
        val a = place(Offset(-0.32f * direction, 0.55f))
        val b = place(Offset(0.32f * direction, 0.55f))
        val c = place(Offset(0.40f * direction, 1.85f))
        val d = place(Offset(-0.40f * direction, 1.85f))
        moveTo(a.x, a.y); lineTo(b.x, b.y); lineTo(c.x, c.y); lineTo(d.x, d.y); close()
    }
    drawPath(arm, Skin)
    drawPath(arm, HandInk, style = Stroke(width = unit * 0.055f))

    // BACK FINGERS FIRST — ring and pinky pass behind the palm in a fist.
    for (finger in listOf(2, 3)) {
        strokeFinger(pose, finger, unit, ::place, direction, 1f)
    }

    // The palm: a rounded quad with a slight barrel on the outer edge.
    val palm = Path().apply {
        addRoundRect(
            androidx.compose.ui.geometry.RoundRect(
                Rect(
                    Offset(origin.x - unit * 0.52f, origin.y - unit * 0.10f),
                    Size(unit * 1.04f, unit * 0.78f),
                ),
                androidx.compose.ui.geometry.CornerRadius(unit * 0.26f),
            )
        )
    }
    drawPath(palm, Skin)
    drawPath(palm, HandInk, style = Stroke(width = unit * 0.055f))

    // One soft top-left highlight, matching the app-wide light direction.
    drawOval(
        color = Color.White.copy(alpha = 0.22f),
        topLeft = Offset(origin.x - unit * 0.34f, origin.y + unit * 0.02f),
        size = Size(unit * 0.42f, unit * 0.30f),
    )

    // FRONT FINGERS AND THUMB.
    for (finger in listOf(0, 1)) {
        strokeFinger(pose, finger, unit, ::place, direction, knucklePop)
    }
    strokeThumb(pose, unit, ::place, direction)
}

private fun DrawScope.strokeFinger(
    pose: HandRig.Pose,
    finger: Int,
    unit: Float,
    place: (Offset) -> Offset,
    direction: Float,
    scale: Float,
) {
    val joints = HandRig.fingerJoints(
        finger,
        pose.curls[finger.coerceAtMost(pose.curls.size - 1)],
        pose.splay,
        direction,
    )
    // Three strokes at three widths rather than one — the taper is what reads as a finger.
    for (i in 0 until joints.size - 1) {
        val a = place(Offset(joints[i].x * scale, joints[i].y * scale))
        val b = place(Offset(joints[i + 1].x * scale, joints[i + 1].y * scale))
        // Outline first, fill over it — one pass, and the stroke's round cap gives the knuckle
        // its curve for free.
        drawLine(HandInk, a, b, strokeWidth = unit * (HandRig.segmentWidth(i) + 0.055f),
            cap = StrokeCap.Round)
        drawLine(if (i == 2) SkinShade else Skin, a, b,
            strokeWidth = unit * HandRig.segmentWidth(i), cap = StrokeCap.Round)
    }
}

private fun DrawScope.strokeThumb(
    pose: HandRig.Pose,
    unit: Float,
    place: (Offset) -> Offset,
    direction: Float,
) {
    val joints = HandRig.thumbJoints(pose.thumbCurl, pose.thumbAdduction, direction)
    for (i in 0 until joints.size - 1) {
        val a = place(joints[i])
        val b = place(joints[i + 1])
        drawLine(HandInk, a, b, strokeWidth = unit * 0.38f, cap = StrokeCap.Round)
        drawLine(Skin, a, b, strokeWidth = unit * 0.32f, cap = StrokeCap.Round)
    }
}
