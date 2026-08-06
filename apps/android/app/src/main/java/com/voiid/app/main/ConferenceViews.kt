package com.voiid.app.main

import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.ChatStore
import com.voiid.app.model.ConversationType
import com.voiid.app.net.ConferenceManager
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/**
 * The UI for turning a 1:1 call into a small conference. Port of iOS `ConferenceViews.swift`.
 *
 * ── A SHARED CALL IS NOT AN INTRODUCTION ─────────────────────────────────────────
 * Nothing here may create or imply a conversation. The backend guarantees it structurally —
 * 32 guard tests in `callConference.test.ts` assert that no write to `conversations` or
 * `conversation_members` happens anywhere in the call path — and the UI holds the same line:
 * the roster below has no tap target at all, and the picker offers only people you can
 * already reach.
 *
 * ── WHAT AN UNKNOWN PARTICIPANT MAY SEE ──────────────────────────────────────────
 * Someone you do not already know renders as `@username` and nothing else: no full name, no
 * photo, no number. Reaching them afterwards still takes their contact PIN. That rule lives
 * in `CallRosterEntry.displayName` and `UserDirectory.callRosterName`; these composables
 * never resolve a name themselves, so there is exactly one place it can be got wrong.
 */

/**
 * Pick someone to add to the live call.
 *
 * Sourced from EXISTING CONVERSATIONS rather than the address book: adding someone to a call
 * is a reachability action and the server accepts exactly that set, so an address-book list
 * would be mostly taps that fail with a 403.
 */
@Composable
fun ConferenceInviteSheet(
    chat: ChatStore,
    excludeUserId: String?,
    onPick: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val candidates = chat.directConversations.filter {
        it.peerUserId != null && it.peerUserId != excludeUserId && it.type != ConversationType.SELF
    }

    Column(
        Modifier
            .fillMaxWidth()
            .background(VoiidColor.surfaceCard, RoundedCornerShape(VoiidRadius.lg))
            .padding(vertical = 16.dp),
    ) {
        Text(
            "Add to call",
            style = VoiidFont.rounded(17, FontWeight.SemiBold),
            color = VoiidColor.textPrimary,
            modifier = Modifier.padding(horizontal = 20.dp),
        )
        Spacer(Modifier.height(12.dp))

        if (candidates.isEmpty()) {
            Text(
                "You can add people you already have a chat with.",
                style = VoiidFont.rounded(14),
                color = VoiidColor.textSecondary,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 24.dp),
            )
        } else {
            LazyColumn(Modifier.fillMaxWidth()) {
                items(candidates, key = { it.id }) { conv ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .softClickable {
                                haptics.tap()
                                conv.peerUserId?.let(onPick)
                            }
                            .padding(horizontal = 20.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        VoiidAvatar(size = 40.dp)
                        Text(
                            conv.title,
                            style = VoiidFont.rounded(16),
                            color = VoiidColor.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        Icon(
                            Icons.Default.PersonAdd, contentDescription = null,
                            tint = VoiidColor.primary, modifier = Modifier.size(20.dp),
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(8.dp))
        Text(
            "Cancel",
            style = VoiidFont.rounded(15, FontWeight.Medium),
            color = VoiidColor.primary,
            modifier = Modifier
                .fillMaxWidth()
                .softClickable { onDismiss() }
                .padding(vertical = 12.dp),
        )
    }
}

/**
 * Who is on the call, drawn over the call surface.
 *
 * Deliberately spare — a name, and whether they have joined yet. There is NO tap target:
 * no profile, no message, no add-contact. Each of those would be a path from "we were briefly
 * on a call together" to "I can now reach you", which is precisely what this design refuses.
 */
@Composable
fun ConferenceRoster(modifier: Modifier = Modifier) {
    val state by ConferenceManager.state.collectAsState()
    val roster = state?.roster.orEmpty()
    if (roster.size <= 1) return

    Column(
        modifier
            .clip(RoundedCornerShape(VoiidRadius.md))
            .background(Color.Black.copy(alpha = 0.35f))
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            "ON THIS CALL",
            style = VoiidFont.rounded(11, FontWeight.SemiBold),
            color = Color.White.copy(alpha = 0.6f),
        )
        roster.forEach { entry ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Box(
                    Modifier
                        .size(6.dp)
                        .clip(CircleShape)
                        .background(if (entry.isJoined) VoiidColor.success else VoiidColor.accent),
                )
                // `displayName` is the roster entry's OWN identity surface: a saved contact
                // reads as their name, a stranger as @handle, and never a uuid. Resolved
                // there rather than here so there is one place it can be got wrong.
                Text(
                    entry.displayName(),
                    style = VoiidFont.rounded(13, FontWeight.Medium),
                    color = Color.White,
                )
                if (!entry.isJoined) {
                    Text(
                        "ringing",
                        style = VoiidFont.rounded(11),
                        color = Color.White.copy(alpha = 0.6f),
                    )
                }
            }
        }
    }
}

/**
 * The full-screen prompt shown while this device is ringing for a CONFERENCE invite.
 *
 * Separate from the 1:1 incoming screen because the decision is different: you are not being
 * called by one person, you are being pulled into a call that already exists. The inviter is
 * named; the people already on it are NOT, because you may not know them and listing them
 * would leak exactly what the identity rule protects.
 */
@Composable
fun ConferenceInviteScreen(
    callId: String,
    inviterUserId: String,
    kind: CallKind,
    onAccept: () -> Unit,
    onDecline: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    Column(
        Modifier.fillMaxSize().background(VoiidColor.background),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(120.dp))
        Text(
            "CALL INVITATION",
            style = VoiidFont.rounded(12, FontWeight.SemiBold),
            color = VoiidColor.textSecondary,
        )
        Spacer(Modifier.height(12.dp))
        Text(
            com.voiid.app.store.UserDirectory.callRosterName(inviterUserId, null),
            style = VoiidFont.rounded(26, FontWeight.Bold),
            color = VoiidColor.textPrimary,
        )
        Spacer(Modifier.weight(1f))
        Row(
            Modifier.fillMaxWidth().padding(bottom = 64.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
        ) {
            Box(
                Modifier.size(72.dp).clip(CircleShape).background(VoiidColor.error)
                    .softClickable { haptics.rigid(); onDecline() },
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Default.CallEnd, "Decline", tint = Color.White, modifier = Modifier.size(30.dp)) }

            Box(
                Modifier.size(72.dp).clip(CircleShape).background(VoiidColor.success)
                    .softClickable { haptics.tap(); onAccept() },
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Default.Call, "Accept", tint = Color.White, modifier = Modifier.size(30.dp)) }
        }
    }
}
