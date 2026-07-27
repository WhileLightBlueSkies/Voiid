package com.voiid.app.main

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Directions
import androidx.compose.material.icons.filled.Map
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.net.ChatEngine
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/**
 * Full-screen location detail (docs/LOCATION.md §4): the map, Open in Maps and Directions
 * handoffs. No in-app routing — we hand off to the system map app (§10.10).
 */
@Composable
fun LocationDetailView(ref: ChatEngine.LocationRef, onClose: () -> Unit) {
    val context = LocalContext.current
    BackHandler { onClose() }
    // A live share with no fix yet has no coordinate — the bubble only opens this when it does,
    // but guard for safety (and to satisfy the nullable type).
    val lat = ref.lat ?: run { onClose(); return }
    val lon = ref.lon ?: run { onClose(); return }
    Column(Modifier.fillMaxSize().background(VoiidColor.background)) {
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(Icons.Default.Close, "Close", tint = VoiidColor.textPrimary, modifier = Modifier.size(26.dp).clickable { onClose() })
            Text(
                ref.label?.ifBlank { null } ?: if (ref.kind == com.voiid.app.model.LocationEnvelope.K_LIVE_START) "Live location" else "Location",
                style = VoiidFont.rounded(18, FontWeight.SemiBold), color = VoiidColor.textPrimary,
            )
        }

        // Interactive (non-lite) map, or the coordinate card when Maps isn't configured.
        LocationMap(lat = lat, lon = lon, lite = false, modifier = Modifier.fillMaxWidth().weight(1f))

        Column(
            Modifier.fillMaxWidth().background(VoiidColor.surfaceCard).navigationBarsPadding().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("%.5f, %.5f".format(lat, lon), style = VoiidFont.rounded(13, FontWeight.Medium), color = VoiidColor.textSecondary)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                DetailAction(Icons.Default.Map, "Open in Maps", Modifier.weight(1f)) { openInMaps(context, lat, lon, ref.label) }
                DetailAction(Icons.Default.Directions, "Directions", Modifier.weight(1f)) {
                    // Directions is just Open in Maps with a nav intent the system map app resolves.
                    runCatching {
                        context.startActivity(
                            android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse("google.navigation:q=$lat,$lon"))
                                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                    }.onFailure { openInMaps(context, lat, lon, ref.label) }
                }
            }
        }
    }
}

@Composable
private fun DetailAction(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, modifier: Modifier, onClick: () -> Unit) {
    Row(
        modifier
            .clip(RoundedCornerShape(VoiidRadius.pill))
            .background(VoiidColor.fieldFill)
            .clickable { onClick() }
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(icon, null, tint = VoiidColor.primary, modifier = Modifier.size(18.dp))
        Text(label, style = VoiidFont.rounded(14, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        Spacer(Modifier.height(0.dp))
    }
}
