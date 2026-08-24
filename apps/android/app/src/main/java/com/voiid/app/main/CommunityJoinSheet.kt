package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
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
import coil.compose.AsyncImage
import com.voiid.app.net.ApiError
import com.voiid.app.net.CommunityLink
import com.voiid.app.net.CommunityService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/**
 * What a community invite link opens: the PUBLIC INFO CARD, plus a Join button.
 *
 * Port of iOS `CommunityJoinSheet.swift`; the two must show the same states, because the same
 * link is going to be opened on both phones by people comparing notes.
 *
 * WHY A SHEET AND NOT A SCREEN IN THE COMMUNITIES TAB
 * --------------------------------------------------
 * The link can arrive while the user is anywhere — mid-chat, on the Map, on a cold launch that
 * has not painted a tab yet. A modal is the only presentation that is correct from all of those
 * places, and it means this feature does not have to agree with whatever the Communities tab
 * eventually becomes.
 *
 * THE LINK IS NOT AN ANSWER, IT IS A QUESTION
 * -------------------------------------------
 * Everything below the header is what the SERVER said when asked about this handle, with this
 * caller's session attached. Nothing is derived from the fact that a link opened. That is the
 * property that stops a forwarded URL from leaking membership: whoever holds the link gets the
 * same public card a stranger gets, and "are you in this community" is answered — per caller —
 * by `membership_state`, which the server computes from the roster it already owns.
 *
 * Nothing here touches E2EE state. Joining inserts server-side membership rows; the MLS Welcome
 * that actually lets this device READ the channels is a separate client-driven step over the
 * existing /mls routes, exactly as group conversations already work.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CommunityJoinSheet(link: CommunityLink, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val service = remember { CommunityService(context) }

    var card by remember(link) { mutableStateOf<CommunityService.CommunityCard?>(null) }
    var joined by remember(link) { mutableStateOf<String?>(null) }
    var alreadyIn by remember(link) { mutableStateOf(false) }
    var error by remember(link) { mutableStateOf<String?>(null) }
    var busy by remember(link) { mutableStateOf(false) }

    // Keyed on the link, so a SECOND link tapped while this sheet is open re-resolves instead
    // of showing the first community's card under the second community's name.
    LaunchedEffect(link) {
        error = null
        card = null
        runCatching { service.resolve(link) }
            .onSuccess { card = it }
            .onFailure { error = messageFor(it, handle = link.handle) }
    }

    com.voiid.app.ui.components.VoiidSheet(
        visible = true,
        onDismiss = onDismiss,
        detents = listOf(com.voiid.app.ui.components.VoiidDetent.Medium, com.voiid.app.ui.components.VoiidDetent.Large),
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .padding(bottom = 24.dp)
                .navigationBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            val c = card
            when {
                c == null && error == null -> {
                    Spacer(Modifier.height(24.dp))
                    CircularProgressIndicator(color = VoiidColor.primary)
                    Text(
                        "Looking up @${link.handle}…",
                        style = VoiidFont.rounded(14),
                        color = VoiidColor.textSecondary,
                    )
                    Spacer(Modifier.height(24.dp))
                }

                c == null -> {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Can’t open this link",
                        style = VoiidFont.rounded(20, FontWeight.SemiBold),
                        color = VoiidColor.textPrimary,
                    )
                    Text(
                        error.orEmpty(),
                        style = VoiidFont.rounded(14),
                        color = VoiidColor.textSecondary,
                        textAlign = TextAlign.Center,
                    )
                    SheetButton("Close", filled = false) { onDismiss() }
                }

                else -> {
                    CommunityHeader(c)

                    // The join outcome, once there is one. 'pending' is a REAL outcome and not
                    // an error: an approval-gated community accepted the request and an admin
                    // now has to act, and saying "joined" there would be a lie the user
                    // discovers later when no channels appear.
                    when (joined) {
                        // `existed` is the server saying "you were already in" — the join is
                        // idempotent, and two devices (or two taps) must not both claim credit
                        // for a membership only one of them created.
                        "active" -> Notice(
                            if (alreadyIn) "You’re already a member of this community."
                            else "You’re in. The community’s channels will sync to this device shortly.",
                        )
                        "pending" -> Notice(
                            "Request sent. You’ll get in once an admin approves it.",
                        )
                        null -> JoinArea(
                            card = c,
                            busy = busy,
                            error = error,
                            onJoin = {
                                haptics.rigid()
                                busy = true
                                error = null
                            },
                        )
                    }

                    if (joined != null) SheetButton("Done", filled = false) { onDismiss() }
                }
            }
        }
    }

    // The join call itself, driven off `busy` so the button stays a pure state flip and the
    // request is cancelled with the composition if the sheet is dismissed mid-flight.
    LaunchedEffect(busy) {
        if (!busy) return@LaunchedEffect
        val c = card ?: return@LaunchedEffect
        // The id comes from the RESOLVED CARD, never from the URL. Handles can be released and
        // re-registered (030_communities.sql keeps them in one pool with usernames and creator
        // handles), so redeeming against the id the server just handed us is what stops a stale
        // poster from enrolling someone into whatever community inherited the handle.
        runCatching { service.join(c.id, link.inviteToken) }
            .onSuccess { joined = it.state; alreadyIn = it.existed; haptics.success() }
            .onFailure { error = messageFor(it, handle = link.handle) }
        busy = false
    }
}

/** Name, handle, avatar, member count — the public card and nothing more. */
@Composable
private fun CommunityHeader(card: CommunityService.CommunityCard) {
    val url = card.avatar_url
    if (url != null && url.startsWith("http")) {
        // A PLAINTEXT avatar, like creator profiles (029) — deliberately NOT the E2EE profile
        // photo from 021. An outsider deciding whether to join has to be able to see it, and
        // an encrypted image is unreadable to exactly the people this card exists for.
        AsyncImage(
            model = url,
            contentDescription = null,
            modifier = Modifier.size(72.dp).clip(RoundedCornerShape(20.dp)),
        )
    } else {
        VoiidAvatar(size = 72.dp)
    }
    Text(
        card.name,
        style = VoiidFont.rounded(22, FontWeight.Bold),
        color = VoiidColor.textPrimary,
        textAlign = TextAlign.Center,
    )
    Text(
        "@${card.handle} · ${memberCount(card.member_count)}",
        style = VoiidFont.rounded(13),
        color = VoiidColor.textSecondary,
    )
    val description = card.description
    if (!description.isNullOrBlank()) {
        Text(
            description,
            style = VoiidFont.rounded(15),
            color = VoiidColor.textSecondary,
            textAlign = TextAlign.Center,
        )
    }
}

/**
 * The button, and the sentence explaining what pressing it will actually do.
 *
 * Every refusal is stated BEFORE the tap rather than after it. A user who taps Join and gets an
 * error has learned the same fact one round trip later and one disappointment worse.
 */
@Composable
private fun JoinArea(
    card: CommunityService.CommunityCard,
    busy: Boolean,
    error: String?,
    onJoin: () -> Unit,
) {
    val blocked = when {
        card.suspended -> "This community is suspended and can’t be joined."
        card.isBanned -> "You can’t rejoin this community."
        card.isMember -> "You’re already a member."
        card.isPending -> "Your request is waiting for an admin to approve it."
        // A dead token is only FATAL for invite_only — an open or approval community is
        // joinable without one, so a stale poster still works and the note below the button
        // is where the expired link gets mentioned.
        card.join_policy == "invite_only" && card.invite_valid != true -> DEAD_INVITE
        else -> null
    }

    if (blocked != null) {
        Notice(blocked)
        return
    }

    SheetButton(
        text = when (card.join_policy) {
            "approval" -> "Request to join"
            else -> "Join community"
        },
        filled = true,
        busy = busy,
        onClick = onJoin,
    )

    Text(
        when {
            // A dead token on a community that does not require one. Said out loud, because the
            // user is about to succeed with a link they were told is broken, and silence here
            // reads as the app ignoring the part of the URL they were given.
            card.invite_valid == false -> "$DEAD_INVITE You can still join this community without one."
            // Said plainly because it is the surprising one: nothing happens immediately.
            card.join_policy == "approval" -> "An admin reviews requests before you’re let in."
            card.join_policy == "invite_only" ->
                "You’re joining with an invite link. Links can be revoked or expire."
            else -> "Anyone with the link can join."
        },
        style = VoiidFont.rounded(12),
        color = VoiidColor.textSecondary,
        textAlign = TextAlign.Center,
    )

    // JOINING IS NOT A MESSAGING RIGHT — and the sheet says so, because every other social app
    // has trained people to expect otherwise. 020_reachability.sql defines the only three ways
    // to open a 1:1, and a membership row is not one of them.
    Text(
        "Joining doesn’t let members message you privately. Messages in the community stay end-to-end encrypted.",
        style = VoiidFont.rounded(12),
        color = VoiidColor.textSecondary,
        textAlign = TextAlign.Center,
    )

    if (error != null) {
        Text(
            error,
            style = VoiidFont.rounded(13),
            color = VoiidColor.error,
            textAlign = TextAlign.Center,
        )
    }
}

/** Flat informational block — an outcome or a refusal, never an action. */
@Composable
private fun Notice(text: String) {
    Text(
        text,
        style = VoiidFont.rounded(14),
        color = VoiidColor.textSecondary,
        textAlign = TextAlign.Center,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(VoiidColor.fieldFill)
            .padding(16.dp),
    )
}

@Composable
private fun SheetButton(
    text: String,
    filled: Boolean,
    busy: Boolean = false,
    onClick: () -> Unit,
) {
    Box(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(28.dp))
            .background(if (filled) VoiidColor.primary else VoiidColor.fieldFill)
            // Not merely greyed out while busy: an enabled-looking button that fires a second
            // join is how a max_uses invite gets spent twice by one impatient person.
            .clickable(enabled = !busy, onClick = onClick)
            .padding(vertical = 16.dp),
        contentAlignment = Alignment.Center,
    ) {
        if (busy) {
            CircularProgressIndicator(
                color = VoiidColor.textOnPrimary,
                modifier = Modifier.size(20.dp),
                strokeWidth = 2.dp,
            )
        } else {
            Text(
                text,
                style = VoiidFont.rounded(16, FontWeight.SemiBold),
                color = if (filled) VoiidColor.textOnPrimary else VoiidColor.textPrimary,
            )
        }
    }
}

/** "1 member" / "482 members" — plural handled rather than "1 members". */
private fun memberCount(n: Int): String = if (n == 1) "1 member" else "$n members"

/**
 * ONE sentence for every way an invite can be dead, because the server gives one answer for all
 * of them on purpose: revoked, expired, used up and never-existed all come back as the same 404,
 * since an endpoint that distinguished them would be an oracle for guessing tokens. The user's
 * next move is identical in every case anyway — ask the host for a new link.
 */
private const val DEAD_INVITE = "This invite link isn’t valid any more — ask the host for a new one."

/**
 * Server errors, turned into something worth reading.
 *
 * A 404 deliberately reads as "no such community" and NOT as "you're not allowed to see it".
 * The server returns the same 404 for a community that does not exist and one the caller may
 * not see, and the client must not invent a distinction the server was careful not to make —
 * that distinction is itself the membership leak.
 */
private fun messageFor(t: Throwable, handle: String): String = when {
    t is ApiError.Http && t.status == 404 -> "No community called @$handle."
    t is ApiError.Http && t.status == 403 -> t.message ?: "You can’t join this community."
    t is ApiError.Http && t.status == 409 -> t.message ?: "This community is full."
    t is ApiError.NotAuthenticated -> "Sign in to open this link."
    t is ApiError -> t.message ?: "Something went wrong."
    else -> "Couldn’t reach Voiid. Check your connection and try again."
}
