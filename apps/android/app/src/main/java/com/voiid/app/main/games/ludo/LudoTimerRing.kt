package com.voiid.app.main.games.ludo

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke

/**
 * The pod timer ring (§13). Server-timed: renders `deadlineAt − estimatedServerNow`, clamped
 * 0…30 s, starting at 100% at opensAt and depleting clockwise from 12 o'clock.
 *
 * COLOR: player hue from 30→5 s, timerWarning at 5.000 s, timerCritical at 2.000 s. The ring
 * communicates HOW LONG — never WHO (the border owns that) and never anything else.
 */
object LudoTimerRing {

    data class RingState(
        val fractionRemaining: Float,
        val secondsRemaining: Int,
    )

    /**
     * Pure math over the SMOOTHED server clock (never a raw device counter). Colors are the
     * caller's job: player hue until 5 s, timerWarning at 5 s, timerCritical at 2 s.
     */
    fun state(opensAt: Long?, deadlineAt: Long?, nowEstimatedMs: Long): RingState? {
        if (opensAt == null || deadlineAt == null) return null
        val total = (deadlineAt - opensAt).coerceAtLeast(1)
        val remaining = (deadlineAt - nowEstimatedMs).coerceIn(0L, LudoRules.TURN_WINDOW_MS.toLong())
        return RingState(
            fractionRemaining = remaining.toFloat() / total,
            secondsRemaining = (remaining / 1000).toInt(),
        )
    }

    fun DrawScope.drawRing(
        diameterPx: Float,
        strokePx: Float,
        trackColor: Color,
        arcColor: Color,
        fraction: Float,
    ) {
        val r = diameterPx / 2f - strokePx / 2f
        val c = center
        drawCircle(trackColor, radius = r, center = c, style = Stroke(strokePx))
        if (fraction <= 0f) return
        drawArc(
            color = arcColor,
            startAngle = -90f,
            sweepAngle = -360f * fraction.coerceIn(0f, 1f),   // depletes clockwise from 12
            useCenter = false,
            topLeft = Offset(c.x - r, c.y - r),
            size = Size(diameterPx - strokePx, diameterPx - strokePx),
            style = Stroke(strokePx, cap = StrokeCap.Round),
        )
    }
}
