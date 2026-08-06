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
import com.voiid.app.net.TokenStore
import com.voiid.app.net.TournamentService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.launch

/**
 * Tournaments inside a community (plan item 3.22). Mirrors
 * `CommunityTournamentsSection.swift`.
 *
 * The backend for this shipped complete and neither app referenced it, so no user could tell
 * a tournament existed. This section is what makes it reachable, and it is deliberately
 * small: list, status, register/withdraw. Creating and running a bracket is an ADMIN flow
 * with its own screens; this is the member's view of one.
 *
 * ## Why it only renders for members
 * The endpoint 403s a non-member rather than returning an empty list — a roster is visible to
 * the space it belongs to and not outside it. Rendering a permanently-empty section to a
 * non-member would read as "this community has no tournaments", which is a different and
 * false statement.
 */
@Composable
fun CommunityTournamentsSection(communityId: String, modifier: Modifier = Modifier) {
    val ctx = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()
    val service = remember { TournamentService(ApiClient(TokenStore.get(ctx))) }

    var tournaments by remember(communityId) {
        mutableStateOf<List<TournamentService.Tournament>>(emptyList())
    }
    var loaded by remember(communityId) { mutableStateOf(false) }
    var busyId by remember { mutableStateOf<String?>(null) }

    suspend fun reload() {
        // A 403 means "not a member", which the caller already knows — it only renders this
        // section for members. Any other failure leaves the last good list in place.
        runCatching { service.list(communityId) }.onSuccess { tournaments = it }
        loaded = true
    }

    LaunchedEffect(communityId) { reload() }

    Column(modifier = modifier.fillMaxWidth()) {
        Text(
            "Tournaments",
            style = VoiidFont.rounded(17, FontWeight.SemiBold),
            color = VoiidColor.textPrimary,
        )
        Spacer(Modifier.height(8.dp))

        if (loaded && tournaments.isEmpty()) {
            Text("No tournaments yet.", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
        }

        tournaments.forEach { t ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 4.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(VoiidColor.surfaceCard)
                    .padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        t.name,
                        style = VoiidFont.rounded(15, FontWeight.SemiBold),
                        color = VoiidColor.textPrimary,
                        maxLines = 1,
                    )
                    Text(subtitle(t), style = VoiidFont.rounded(11), color = VoiidColor.textSecondary)
                }

                // Registration is only offered while the server would actually accept it.
                // Every other state gets no button rather than a button that 409s — an
                // affordance that always fails is worse than no affordance.
                if (t.status == "registering") {
                    Text(
                        if (t.registered) "Withdraw" else "Register",
                        style = VoiidFont.rounded(13, FontWeight.SemiBold),
                        color = if (t.registered) VoiidColor.textSecondary else VoiidColor.textOnPrimary,
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(if (t.registered) VoiidColor.background else VoiidColor.primary)
                            .softClickable {
                                if (busyId != null) return@softClickable
                                haptics.tap(); busyId = t.id
                                scope.launch {
                                    // Capacity and the registration window belong to the
                                    // server — several people may be racing for the last slot
                                    // — so the result is re-read rather than assumed.
                                    runCatching {
                                        if (t.registered) service.withdraw(t.id)
                                        else service.register(t.id)
                                    }
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

private fun subtitle(t: TournamentService.Tournament): String {
    val parts = buildList {
        t.game_name?.let { add(it) }
        t.player_count?.let { n ->
            add(t.max_players?.let { "$n/$it players" } ?: "$n players")
        }
        t.status?.let { add(label(it)) }
    }
    return parts.joinToString(" · ")
}

/**
 * The server's status vocabulary is a state machine, not display copy. Translating it here
 * keeps the API free to name states for what they ARE rather than how they read.
 */
private fun label(status: String): String = when (status) {
    "draft" -> "Not open yet"
    "registering" -> "Open for entries"
    "running" -> "In progress"
    "finished" -> "Finished"
    "cancelled" -> "Cancelled"
    else -> status
}
