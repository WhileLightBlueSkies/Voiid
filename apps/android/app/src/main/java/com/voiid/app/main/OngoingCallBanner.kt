package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Call
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.net.ApiClient
import com.voiid.app.net.GroupCallManager
import com.voiid.app.net.TokenStore
import com.voiid.app.ui.theme.VoiidColor
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.serialization.Serializable

/**
 * "Ongoing call — Join", pinned at the top of a group chat (plan item 3.15, part 3).
 *
 * ## The problem this solves
 * A group call used to be discoverable ONLY by catching the ring push. Miss the notification
 * — phone face-down, Do Not Disturb, app killed, notification swiped — and the call became
 * invisible even while everyone else sat in it. There was no state in the chat saying a call
 * was happening, so the only recovery was independently guessing to tap the call button,
 * which started a SECOND call instead of joining the first.
 *
 * ## Why polling, and why it is cheap
 * The server holds a short-TTL Redis marker per conversation that connected clients re-arm.
 * There is deliberately no "call ended" event to deliver: a call ends when everybody stops
 * heartbeating, and a TTL expresses that without anything having to notice or announce it.
 * So this polls, and only while the chat is on screen — [LaunchedEffect] cancels on leave.
 *
 * Nothing here is encrypted and nothing here needs to be: "a call is happening in this room"
 * is routing metadata the server already holds in order to route the call at all. No media,
 * no keys and no participant names cross this endpoint — only a count.
 */
@Composable
fun OngoingCallBanner(
    conversationId: String,
    modifier: Modifier = Modifier,
    /**
     * Runs the chat's normal call-start path rather than a second one of its own. Joining an
     * existing call and starting a new one are the same operation on the server — the room is
     * derived from the conversation id — so they must not diverge here.
     */
    onJoin: () -> Unit,
) {
    val ctx = LocalContext.current
    var active by remember(conversationId) { mutableStateOf(false) }
    var count by remember(conversationId) { mutableIntStateOf(0) }
    val call by GroupCallManager.state.collectAsState()

    LaunchedEffect(conversationId) {
        while (isActive) {
            // A failed poll leaves the banner as it was rather than hiding it: flapping a Join
            // button on a transient blip is worse than a banner a few seconds stale, and a 403
            // (not a member) simply never turns it on to begin with.
            runCatching {
                val api = ApiClient(TokenStore.get(ctx))
                val raw = api.request(
                    "GET", "calls/group/active?conversation_id=$conversationId")
                ApiClient.json.decodeFromString(ActiveResponse.serializer(), raw)
            }.onSuccess {
                active = it.active
                count = it.participant_count
            }
            delay(POLL_MS)
        }
    }

    // Suppressed while WE are on the call: the call UI already covers the chat, and offering
    // to "join" something you are in reads as a bug. The server's own `self_present` would lag
    // by a poll interval, so local state is what decides.
    if (!active || call?.conversationId == conversationId) return

    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(VoiidColor.surfaceCard)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            Icons.Default.Call,
            contentDescription = null,
            tint = VoiidColor.textOnPrimary,
            modifier = Modifier
                .size(26.dp)
                .clip(CircleShape)
                .background(VoiidColor.primary)
                .padding(5.dp),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text("Ongoing call", fontSize = 14.sp, color = VoiidColor.textPrimary)
            if (count > 0) {
                Text("$count on the call", fontSize = 11.sp, color = VoiidColor.textSecondary)
            }
        }
        Button(
            onClick = onJoin,
            colors = ButtonDefaults.buttonColors(containerColor = VoiidColor.primary),
        ) {
            Text("Join", fontSize = 13.sp, color = VoiidColor.textOnPrimary)
        }
    }
}

/** Long enough that an idle chat is quiet, short enough that a call appears within seconds. */
private const val POLL_MS = 8_000L

@Serializable
private data class ActiveResponse(
    // Defaults, not required fields: this is a RESPONSE model, so a field the server stops
    // sending must not become a decode failure.
    val active: Boolean = false,
    val participant_count: Int = 0,
)
