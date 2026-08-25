package com.voiid.app.main.games.ludo

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.graphics.Color
import com.voiid.app.ui.theme.LudoDimens
import com.voiid.app.ui.theme.LudoPalette
import com.voiid.app.ui.theme.ludoPaletteFor

/**
 * A player pod (§11.2): EXACTLY two visible elements — the timer-ring/color-chip assembly at
 * its outer edge and one username line. No avatar, badge, level, rank, gift, coin, completion
 * dots, scores or status icons; finished pawns stay visible in the center triangle instead.
 *
 * USERNAME RULES: one line, tail-truncated at 18 clusters, never below 12sp, never marquee.
 * The viewer's own pod shows their username, not "You". A waiting seat shows an outlined chip
 * and "Waiting…". A dropped seat keeps position, desaturated chip, 55% name, no timer.
 */
@Composable
fun LudoPlayerPod(
    seatView: LudoSeatView?,
    isSeatAssigned: Boolean,
    active: Boolean,
    ringFraction: Float?,
    ringColorOverride: androidx.compose.ui.graphics.Color?,   // null → player hue
    compact: Boolean,
    modifier: Modifier = Modifier,
) {
    val width = if (compact) LudoDimens.podWidthCompact else LudoDimens.podWidthStandard
    val height = if (compact) LudoDimens.podHeightCompact else LudoDimens.podHeightStandard
    val chip = if (compact) LudoDimens.podChipCompact else LudoDimens.podChipStandard
    val ring = if (compact) LudoDimens.timerRingCompact else LudoDimens.timerRingStandard

    Row(
        modifier = modifier
            .size(width, height)
            .clip(RoundedCornerShape(LudoDimens.podCornerRadius))
            .background(LudoPalette.podSurface()),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Start,
    ) {
        Box(Modifier.padding(start = (height - ring) / 2)) {
            // Ring surrounds the color chip rather than adding a third ornament (§11.2).
            val darkNow = !com.voiid.app.ui.theme.isLightTheme()
            val resolvedColors = ludoPaletteFor(darkNow)
            PodRing(
                diameter = ring,
                stroke = LudoDimens.timerRingStroke,
                fraction = if (active && ringFraction != null) ringFraction else 1f,
                arcColor = when {
                    !active -> resolvedColors.c(resolvedColors.timerTrack)
                    ringColorOverride != null -> ringColorOverride
                    else -> seatView?.let { resolvedColors.hue(it.seat) }
                        ?: resolvedColors.c(resolvedColors.timerTrack)
                },
                trackColor = resolvedColors.c(resolvedColors.timerTrack),
                chipSize = chip,
                chipColor = seatView?.let { resolvedColors.hue(it.seat) } ?: Color.Transparent,
                outlined = chipOutlined(seatView),
            )
        }
        Text(
            text = usernameLine(seatView),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = TextStyle(
                fontFamily = androidx.compose.ui.text.font.FontFamily.SansSerif,
                fontWeight = FontWeight.SemiBold,
                fontSize = 13.sp,
            ),
            color = LudoPalette.textPrimary(),
            modifier = Modifier
                .padding(start = 8.dp)
                .weight(1f, fill = false)
                .padding(end = 8.dp),
        )
    }
}

private fun chipOutlined(seatView: LudoSeatView?): Boolean =
    seatView == null || seatView.isWaiting

@Composable
private fun usernameLine(seatView: LudoSeatView?): String = when {
    seatView == null -> ""
    seatView.isWaiting -> "Waiting…"
    else -> (seatView.displayName + if (seatView.isBot) "  BOT" else "").take(22)
}

@Composable
private fun PodRing(
    diameter: Dp,
    stroke: Dp,
    fraction: Float,
    arcColor: androidx.compose.ui.graphics.Color,
    trackColor: androidx.compose.ui.graphics.Color,
    chipSize: Dp,
    chipColor: androidx.compose.ui.graphics.Color,
    outlined: Boolean,
) {
    Box(contentAlignment = Alignment.Center) {
        androidx.compose.foundation.Canvas(modifier = Modifier.size(diameter)) {
            drawCircle(trackColor, style = androidx.compose.ui.graphics.drawscope.Stroke(stroke.toPx()))
            val f = fraction.coerceIn(0f, 1f)
            if (f > 0f) {
                drawArc(
                    color = arcColor,
                    startAngle = -90f,
                    sweepAngle = -360f * f,
                    useCenter = false,
                    style = androidx.compose.ui.graphics.drawscope.Stroke(
                        stroke.toPx(), cap = androidx.compose.ui.graphics.StrokeCap.Round,
                    ),
                )
            }
        }
        Box(
            Modifier
                .size(chipSize)
                .then(
                    if (outlined) Modifier.border(1.dp, LudoPalette.yardPocketBorder(), CircleShape)
                    else Modifier
                )
                .clip(CircleShape)
                .background(chipColor)
        )
    }
}
