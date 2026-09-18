package com.voiid.app.main.games.ludobot

import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

/**
 * Design tokens for the luxury wood and brass Ludo board.
 *
 * Port of iOS `Games/Ludo/LudoTheme.swift`. The hex values are shared verbatim so a
 * screenshot of one platform is a screenshot of the other.
 */
object LudoTheme {

    // Surfaces
    val ink = Color(0xFF0E1620)
    val ink2 = Color(0xFF16212E)
    val ink3 = Color(0xFF1E2C3C)
    val hairline = Color(0xFF263547)

    val board = Color(0xFFF3E9D6)
    val board2 = Color(0xFFE8DAC0)
    val line = Color(0xFFB9A484)
    val brass = Color(0xFFC9A227)
    val brassLo = Color(0xFF8A6E15)
    val cream = Color(0xFFFFF8EA)
    val muted = Color(0xFF9DAFC2)
    val faint = Color(0xFF5C6E80)

    // Seats
    private val seatColours = listOf(
        Color(0xFFE0503F),  // Red
        Color(0xFF2FA36B),  // Green
        Color(0xFFE8A72E),  // Amber
        Color(0xFF3B7DD8),  // Blue
    )

    fun seat(i: Int): Color = seatColours[i % 4]

    val backdrop: Brush = Brush.radialGradient(
        colors = listOf(Color(0xFF1B2836), ink, Color(0xFF080D13)),
        radius = 1800f,
    )
}
