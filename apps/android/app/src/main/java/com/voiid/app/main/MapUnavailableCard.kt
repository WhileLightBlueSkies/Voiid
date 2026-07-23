package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LocationOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/**
 * Shown wherever a map WOULD render but cannot — docs/LOCATION.md §7.
 *
 * Two causes, both of which the Maps SDK otherwise fails at SILENTLY (a blank grey tile grid +
 * a logcat auth error nobody sees), which is unacceptable:
 *   1. build-time: BuildConfig.MAPS_CONFIGURED == false (no MAPS_API_KEY in this build).
 *   2. runtime: a key exists but is restricted to the wrong package/SHA-1 — the map never
 *      reports loaded, and a watchdog swaps this card in.
 *
 * Crucially, location sharing itself KEEPS WORKING behind this card: pins, live shares and Map
 * presence all decrypt to coordinates + an Open-in-Maps handoff. The map is a nicety; the
 * privacy machinery is not gated on it.
 */
@Composable
fun MapUnavailableCard(
    headline: String,
    subline: String,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .padding(24.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(VoiidRadius.lg))
                .background(VoiidColor.fieldFill)
                .border(1.dp, VoiidColor.fieldBorder, RoundedCornerShape(VoiidRadius.lg))
                .padding(28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(
                Icons.Default.LocationOff,
                contentDescription = null,
                tint = VoiidColor.textSecondary,
                modifier = Modifier.size(40.dp),
            )
            Text(
                headline,
                style = VoiidFont.rounded(17, FontWeight.SemiBold),
                color = VoiidColor.textPrimary,
                textAlign = TextAlign.Center,
            )
            Text(
                subline,
                style = VoiidFont.rounded(13, FontWeight.Normal),
                color = VoiidColor.textSecondary,
                textAlign = TextAlign.Center,
            )
        }
    }
}
