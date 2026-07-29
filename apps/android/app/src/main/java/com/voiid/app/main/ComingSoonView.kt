package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/**
 * The placeholder for a tab that exists in the bar but has no feature behind it yet
 * (Communities, Games).
 *
 * DELIBERATELY NOT a bare "Coming soon" centred on an empty screen. A tab a user can reach and
 * tap is a promise; the screen has to say what the thing WILL be, or tapping it feels like a
 * bug. So: the tab's own icon, its name, one honest sentence about the feature, and a quiet
 * status chip. Nothing that pretends to be interactive — no fake buttons, no waitlist field
 * that goes nowhere.
 *
 * Mirrors iOS `ComingSoonView.swift`.
 */
@Composable
fun ComingSoonView(icon: ImageVector, title: String, blurb: String) {
    Column(
        Modifier
            .fillMaxSize()
            .background(VoiidColor.background)
            .statusBarsPadding()
            .padding(horizontal = 32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // The tab's own glyph, held in a soft brand-tinted disc so the screen reads as
        // designed-but-empty rather than unfinished.
        Box(
            Modifier
                .size(84.dp)
                .clip(CircleShape)
                .background(VoiidColor.primary.copy(alpha = 0.10f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, null, tint = VoiidColor.primary, modifier = Modifier.size(38.dp))
        }

        Spacer(Modifier.size(22.dp))

        Text(
            title,
            style = VoiidFont.rounded(26, FontWeight.Bold),
            color = VoiidColor.textPrimary,
        )

        Spacer(Modifier.size(10.dp))

        Text(
            blurb,
            style = VoiidFont.rounded(14),
            color = VoiidColor.textSecondary,
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.size(24.dp))

        // Status, stated plainly. "In development" rather than a date — a date we might miss
        // is worse than no date at all.
        Box(
            Modifier
                .clip(RoundedCornerShape(VoiidRadius.pill))
                .background(VoiidColor.fieldFill)
                .padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            Text(
                "In development",
                style = VoiidFont.rounded(12, FontWeight.SemiBold),
                color = VoiidColor.textSecondary,
            )
        }
    }
}
