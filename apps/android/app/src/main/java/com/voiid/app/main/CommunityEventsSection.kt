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
fun CommunityEventsSection(communityId: String, modifier: Modifier = Modifier, isOwner: Boolean = false, isManager: Boolean = false, managementContext: Boolean = false) {
    var showCreate by remember(communityId) { mutableStateOf(false) }
    var showTickets by remember(communityId) { mutableStateOf(false) }
    var managing by remember(communityId) { mutableStateOf<EventService.Event?>(null) }
    var refresh by remember(communityId) { mutableStateOf(0) }
    if(showCreate) EventEditorDialog(communityId=communityId,isOwner=isOwner,onDismiss={showCreate=false},onSaved={showCreate=false;refresh++})
    if (showTickets) EventTicketWallet { showTickets = false }
    managing?.let { e -> EventManagerDialog(e, isManager || e.can_manage, canAssign = isManager, onDismiss = { managing = null }, onChanged = { refresh++ }) }
    val ctx = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val service = remember { EventService(ApiClient(TokenStore.get(ctx))) }

    var events by remember(communityId) { mutableStateOf<List<EventService.Event>>(emptyList()) }
    var loaded by remember(communityId) { mutableStateOf(false) }
    var loadError by remember(communityId) { mutableStateOf<String?>(null) }
    var booking by remember { mutableStateOf<EventService.Event?>(null) }
    booking?.let { e -> EventGroupBooking(e, onDismiss={booking=null}, onBooked={booking=null;showTickets=true;refresh++}) }


    suspend fun reload() {
        try { events=service.list(communityId);loadError=null }
        catch(e:kotlinx.coroutines.CancellationException){throw e}
        catch(_:Exception){loadError="Unable to load events."}
        loaded = true
    }

    LaunchedEffect(communityId, refresh) { reload() }

    Column(modifier = modifier.fillMaxWidth()) {
        if(isManager && managementContext) androidx.compose.material3.TextButton(onClick={showCreate=true}){Text("Create event")}
        if(!managementContext) Text("Events", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        EventStaffInvitations(communityId) { refresh++ }
        if(!managementContext) androidx.compose.material3.TextButton(onClick = { showTickets = true }) { Text("My tickets") }
        Spacer(Modifier.height(8.dp))

        loadError?.let{Text(it);androidx.compose.material3.TextButton(onClick={refresh++}){Text("Retry")}}
        if (loaded && loadError==null && events.isEmpty()) {
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
                    if (isManager || e.can_manage || e.can_checkin) androidx.compose.material3.TextButton(onClick = { managing = e }) { Text(if (isManager || e.can_manage) "Manage event" else "Check in") }
                    Text(subtitle(e), style = VoiidFont.rounded(11), color = VoiidColor.textSecondary)
                    e.location_text?.takeIf { it.isNotBlank() }?.let {
                        Text(it, style = VoiidFont.rounded(11), color = VoiidColor.textSecondary, maxLines = 1)
                    }
                }

                when {
                    isManager || e.can_manage -> Unit
                    e.your_order_status == "paid" ->
                        Text("Going", style = VoiidFont.rounded(12, FontWeight.SemiBold), color = VoiidColor.primary)

                    // Draft and cancelled events take no orders; the server 409s. Say which.
                    e.status != "published" ->
                        Text(
                            if (e.status == "cancelled") "Cancelled" else "Not open",
                            style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
                        )

                    else -> Text(
                        if (e.free) "RSVP" else "Book tickets",
                        style = VoiidFont.rounded(13, FontWeight.SemiBold),
                        color = VoiidColor.textOnPrimary,
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(VoiidColor.primary)
                            .softClickable {
                                haptics.tap(); booking = e
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


@Composable
internal fun CommunityEarningsDialog(communityId: String, onDismiss: () -> Unit) {
    val ctx = LocalContext.current
    val service = remember { EventService(ApiClient(TokenStore.get(ctx))) }
    var earnings by remember(communityId) { mutableStateOf<EventService.Earnings?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var retry by remember { mutableStateOf(0) }
    var loading by remember { mutableStateOf(false) }
    LaunchedEffect(communityId, retry) {
        loading = true; error = null
        try { earnings = service.earnings(communityId) }
        catch (e: kotlinx.coroutines.CancellationException) { throw e }
        catch (e: com.voiid.app.net.ApiError.Http) {
            if (e.status == 401 || e.status == 403) earnings = null
            error = when (e.status) {
                401 -> "Please sign in again."
                403 -> "Only the community owner can view earnings."
                429 -> "Please wait a moment before refreshing again."
                else -> if (earnings == null) "Unable to load earnings. Please try again." else "Couldn’t refresh. Showing the last loaded earnings."
            }
        }
        catch (_: Exception) { error = if (earnings == null) "Unable to load earnings. Check your connection and owner access." else "Couldn’t refresh. Showing the last loaded earnings." }
        finally { loading = false }
    }
    EventControlPage("Earnings",onDismiss) {
        androidx.compose.foundation.lazy.LazyColumn(contentPadding=androidx.compose.foundation.layout.PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(24.dp)) {
            item { Text("Your earnings",style=androidx.compose.material3.MaterialTheme.typography.headlineLarge);Text("Event sales and your organiser share") }
            item { androidx.compose.material3.TextButton(enabled = !loading, onClick = { retry++ }) { Text(if (loading) "Refreshing…" else "Refresh") } }
            if (error != null) item { Text(error!!); androidx.compose.material3.TextButton(enabled = !loading, onClick = { retry++ }) { Text("Retry") } }
            if (loading) item { androidx.compose.material3.CircularProgressIndicator() }
            earnings?.let { data ->
                item { androidx.compose.material3.Surface(shape=RoundedCornerShape(24.dp),color=VoiidColor.surfaceCard) {
                    Column(Modifier.fillMaxWidth().padding(22.dp),verticalArrangement=Arrangement.spacedBy(16.dp)) {
                        Text("Your split",style=androidx.compose.material3.MaterialTheme.typography.titleLarge)
                        Text("${java.math.BigDecimal(10000-data.commission_bps).movePointLeft(2)}%",style=androidx.compose.material3.MaterialTheme.typography.headlineLarge)
                        androidx.compose.material3.LinearProgressIndicator(progress={ (10000-data.commission_bps)/10000f },modifier=Modifier.fillMaxWidth())
                        Text("Voiid ${java.math.BigDecimal(data.commission_bps).movePointLeft(2)}% · Applies to new orders")
                    }
                } }
                if (data.totals.isEmpty()) item { Text("No earnings yet. Your event orders will appear here.") }
                data.totals.forEach { t -> item {
                    fun amount(v: String?) = v?.let { "${t.currency} ${java.math.BigDecimal(it).movePointLeft(2).toPlainString()}" } ?: "Not recorded"
                    androidx.compose.material3.Surface(shape=RoundedCornerShape(24.dp),color=VoiidColor.surfaceCard) {
                        Column(Modifier.fillMaxWidth().padding(22.dp),verticalArrangement=Arrangement.spacedBy(16.dp)) {
                            Text("${t.status.replaceFirstChar{it.uppercase()}} · ${t.orders} orders",style=androidx.compose.material3.MaterialTheme.typography.titleMedium)
                            Text(amount(t.organiser_minor),style=androidx.compose.material3.MaterialTheme.typography.headlineLarge)
                            Text("Your share")
                            androidx.compose.material3.HorizontalDivider()
                            Text("Gross sales: ${amount(t.gross_minor)}")
                            Text("Voiid commission: ${amount(t.commission_minor)}")
                            if(t.unpriced_orders>0)Text("Some older orders have no recorded commission.")
                        }
                    }
                } }
                item { androidx.compose.material3.Surface(shape=RoundedCornerShape(24.dp),color=VoiidColor.surfaceCard) {
                    Column(Modifier.fillMaxWidth().padding(22.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
                        Text("Bank settlements",style=androidx.compose.material3.MaterialTheme.typography.titleLarge)
                        Text("Bank account setup will be available after organiser onboarding is connected.")
                        Text("Order totals are before processing fees and taxes. They are not a withdrawable balance.",style=androidx.compose.material3.MaterialTheme.typography.bodySmall)
                    }
                } }
            }
        }
    }
}
