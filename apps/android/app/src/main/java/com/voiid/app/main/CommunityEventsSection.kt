package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.net.ApiClient
import com.voiid.app.net.EventService
import com.voiid.app.net.TokenStore
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * Events inside a community (plan item 3.23). Mirrors `CommunityEventsSection.swift`.
 *
 * The member's view of an event: when, where, and a way to claim a ticket. Creating,
 * publishing and checking people in are ADMIN flows with their own screens; this is not those.
 *
 * ## Paid events say so instead of pretending
 * `POST /events/:id/orders` answers 501 for a paid event because no payment provider is wired
 * up. So a paid event shows its price and states that ticketing is not open, rather than
 * offering an RSVP button whose only possible outcome is an error. The moment the server can
 * take money, this branch is what changes.
 */
@Composable
fun CommunityEventsSection(communityId: String, modifier: Modifier = Modifier) {
    val ctx = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()
    val service = remember { EventService(ApiClient(TokenStore.get(ctx))) }

    var events by remember(communityId) { mutableStateOf<List<EventService.Event>>(emptyList()) }
    var loaded by remember(communityId) { mutableStateOf(false) }
    var busyId by remember { mutableStateOf<String?>(null) }

    suspend fun reload() {
        runCatching { service.list(communityId) }.onSuccess { events = it }
        loaded = true
    }

    LaunchedEffect(communityId) { reload() }

    Column(modifier = modifier.fillMaxWidth()) {
        Text("Events", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        Spacer(Modifier.height(8.dp))

        if (loaded && events.isEmpty()) {
            Text("No events yet.", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
        }

        events.forEach { e ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 4.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(VoiidColor.surfaceCard)
                    .padding(12.dp),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        e.title,
                        style = VoiidFont.rounded(15, FontWeight.SemiBold),
                        color = VoiidColor.textPrimary,
                        maxLines = 2,
                    )
                    Text(subtitle(e), style = VoiidFont.rounded(11), color = VoiidColor.textSecondary)
                    e.location_text?.takeIf { it.isNotBlank() }?.let {
                        Text(it, style = VoiidFont.rounded(11), color = VoiidColor.textSecondary, maxLines = 1)
                    }
                }

                when {
                    e.your_order_status == "paid" ->
                        Text("Going", style = VoiidFont.rounded(12, FontWeight.SemiBold), color = VoiidColor.primary)

                    // Draft and cancelled events take no orders; the server 409s. Say which.
                    e.status != "published" ->
                        Text(
                            if (e.status == "cancelled") "Cancelled" else "Not open",
                            style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
                        )

                    // The one honest thing to render: the server answers 501 here.
                    !e.free ->
                        Text("Ticketing soon", style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)

                    else -> Text(
                        "RSVP",
                        style = VoiidFont.rounded(13, FontWeight.SemiBold),
                        color = VoiidColor.textOnPrimary,
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(VoiidColor.primary)
                            .softClickable {
                                if (busyId != null) return@softClickable
                                haptics.tap(); busyId = e.id
                                scope.launch {
                                    // Capacity is the server's to enforce and people may be
                                    // racing for the last seat, so the list is re-read rather
                                    // than optimistically marked "Going".
                                    runCatching { service.rsvp(e.id) }
                                    reload()
                                    busyId = null
                                }
                            }
                            .padding(horizontal = 14.dp, vertical = 6.dp),
                    )
                }
            }
        }
    }
}

private fun subtitle(e: EventService.Event): String {
    val parts = buildList {
        e.starts_at?.let { displayDate(it) }?.let { add(it) }
        add(if (e.free) "Free" else price(e))
    }
    return parts.joinToString(" · ")
}

/**
 * Minor units are an integer count of the currency's smallest unit, so this is a divide by
 * 100 — NOT a locale-formatted currency string, which would need the currency's real exponent
 * (not every currency has two decimal places).
 */
private fun price(e: EventService.Event): String {
    val minor = e.price_minor ?: 0
    val code = e.currency ?: "INR"
    return String.format("%s %.2f", code, minor / 100.0)
}

private val DATE_OUT: DateTimeFormatter =
    DateTimeFormatter.ofPattern("d MMM, h:mm a").withZone(ZoneId.systemDefault())

private fun displayDate(iso: String): String? =
    runCatching { DATE_OUT.format(Instant.parse(iso)) }.getOrNull()
