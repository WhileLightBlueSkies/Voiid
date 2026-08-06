package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.voiid.app.net.CommunityHostThreads
import com.voiid.app.net.TokenStore
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/**
 * "Message host" — the member's end of the ONE scoped exception to 020_reachability.sql.
 *
 * A self-contained control so the community info card (wherever it ends up living) adopts it in
 * one line and inherits every rule below rather than re-deriving them:
 *
 *     MessageHostButton(communityId = card.id) { conversationId ->
 *         onDismiss(); DeepLinkRouter.open(conversationId)
 *     }
 *
 * IT RENDERS NOTHING UNLESS THE SERVER SAYS THE CALLER MAY USE IT
 * ---------------------------------------------------------------
 * The probe is `GET /communities/:id/host-thread`, which refuses for anyone who is not an ACTIVE
 * member and reports the host's user id for anyone who is. So the button's visibility is a
 * SERVER decision, not a guess made from a membership field the client happens to be holding.
 * On any refusal — not a member, still pending, left, banned, community suspended, endpoint not
 * deployed yet — this composable draws nothing at all. It never explains WHY, because the server
 * deliberately returns one message for all of those states rather than acting as an oracle for
 * moderation status, and a client that invented the distinction would undo that.
 *
 * WHO THE PEER IS, IS NOT A PARAMETER
 * -----------------------------------
 * There is no target user in this API and there must never be one. The peer is
 * `communities.owner_id`, resolved server-side. This control can open a line to a community's
 * HOST and to nobody else; it cannot be pointed at another member, because there is no argument
 * to point. Joining a space is consent to be asked questions by its members — it is not consent
 * to be messaged by every other member, and any code that reads community membership to
 * authorise a message between two ordinary members is a bug (the same rule the creator-profile
 * follow graph carries).
 *
 * The conversation it opens is an ordinary Double-Ratchet 1:1: end-to-end encrypted, zero new
 * cryptography, the server holding opaque ciphertext exactly as it does for every other chat.
 *
 * @param onOpenConversation handed the conversation id once there is one. The caller navigates;
 *        this control does not, because it does not know whether it is inside a sheet that has
 *        to dismiss first.
 */
@Composable
fun MessageHostButton(
    communityId: String,
    modifier: Modifier = Modifier,
    onOpenConversation: (String) -> Unit,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val service = remember { CommunityHostThreads(context) }
    val myUserId = remember { TokenStore.get(context).userId }

    // null = still probing, or the server said no. Either way: draw nothing.
    var probe by remember(communityId) { mutableStateOf<CommunityHostThreads.HostThread?>(null) }
    var opening by remember(communityId) { mutableStateOf(false) }
    var error by remember(communityId) { mutableStateOf<String?>(null) }

    // A GET, deliberately: a card that minted a conversation just by being LOOKED AT would make
    // every impression an act of contact and would fill a popular host's chat list with people
    // who only ever browsed. Nothing is created until the button is pressed.
    LaunchedEffect(communityId) {
        probe = runCatching { service.existing(communityId) }.getOrNull()
    }

    val p = probe ?: return
    val hostId = p.host_user_id ?: return
    // The host does not message themselves. The server refuses this with a 400 anyway; catching
    // it here keeps a pointless button off the owner's own card.
    if (hostId == myUserId) return

    Column(modifier.fillMaxWidth()) {
        Box(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(28.dp))
                .background(VoiidColor.fieldFill)
                .let { if (opening) it else it.then(Modifier.clickable { haptics.tap(); opening = true }) }
                .padding(vertical = 16.dp),
            contentAlignment = Alignment.Center,
        ) {
            if (opening) {
                CircularProgressIndicator(
                    color = VoiidColor.textPrimary,
                    modifier = Modifier.size(20.dp),
                    strokeWidth = 2.dp,
                )
            } else {
                Text(
                    // Two different promises, so they get two different labels: one opens a chat
                    // that already exists, the other starts one.
                    if (p.conversation_id.isNullOrEmpty()) "Message host" else "Open chat with host",
                    style = VoiidFont.rounded(16, FontWeight.SemiBold),
                    color = VoiidColor.textPrimary,
                )
            }
        }

        Text(
            "A private chat with the host only. Other members can't message you.",
            style = VoiidFont.rounded(12),
            color = VoiidColor.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
        )

        error?.let {
            Text(
                it,
                style = VoiidFont.rounded(13),
                color = VoiidColor.error,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            )
        }
    }

    // The request runs off `opening` so the tap stays a pure state flip and the call is cancelled
    // with the composition if the card is dismissed mid-flight.
    LaunchedEffect(opening) {
        if (!opening) return@LaunchedEffect
        error = null
        runCatching { service.open(communityId) }
            .onSuccess { thread ->
                haptics.success()
                // Refresh the probe so a re-entry says "Open chat with host" even if the caller
                // does not navigate away.
                probe = thread
                thread.conversation_id?.let(onOpenConversation)
            }
            .onFailure {
                error = when (it) {
                    is com.voiid.app.net.ApiError.Http -> it.message ?: "Couldn’t open a chat with the host."
                    is com.voiid.app.net.ApiError.NotAuthenticated -> "Sign in to message the host."
                    else -> "Couldn’t reach Voiid. Check your connection and try again."
                }
            }
        opening = false
    }
}
