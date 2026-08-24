package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PersonAddAlt
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Group
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.MapContact
import com.voiid.app.model.VConversation
import com.voiid.app.store.UserDirectory
import com.voiid.app.ui.components.VoiidPrimaryButton
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/**
 * The Map audience picker — the ONLY way to become visible (docs/LOCATION.md §8).
 *
 * SCOPE, NOT A BARE CHECKLIST. This screen mirrors iOS `MapAudienceSheet.swift`: you pick a
 * SCOPE — Everyone / My Contacts / Only selected people — and each scope resolves to a
 * concrete allow-list of individuals.
 *
 * "Everyone" is still a BOUNDED set, never the whole world: the map_key control message rides
 * an existing 1:1 ratchet, so the only reachable people are those you already have a direct
 * conversation with. That constraint is what makes an "everyone" option safe to offer here —
 * it cannot exceed people you have already chosen to talk to. There is still NO block-list
 * ("everyone except…") mode, which is the Snapchat failure this design refuses.
 *
 * The scope is a CLIENT-SIDE way to compute `target_user_ids`; the backend has no scope field
 * and both platforms post the same flat array. Confirming REPLACES the audience with exactly
 * the resolved set (see [MapPresenceEngine.setAudience], which revokes whoever dropped out),
 * so switching Everyone → My Contacts genuinely shrinks who can see you.
 *
 * Names always resolve through UserDirectory; a raw user id is never shown.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MapAudienceSheet(
    directConversations: List<VConversation>,
    current: List<MapContact>,
    onConfirm: (List<MapContact>) -> Unit,
    onDismiss: () -> Unit,
    /** Manage mode ([MapAudienceMode.MANAGE]) lists who can see you now, with per-person
     *  Remove and the kill switch, instead of the scope chooser. */
    mode: MapAudienceMode = MapAudienceMode.CHOOSE,
    isVisible: Boolean = false,
    onRemove: (String) -> Unit = {},
    /** Manage-mode "Add people": flips the presenting surface back to CHOOSE so new people
     *  can be selected, then persisted through [onConfirm]. Mirrors iOS. */
    onAddPeople: () -> Unit = {},
    onStopAll: () -> Unit = {},
) {

    // Candidate contacts = direct conversations with a resolvable peer id, name-sorted so the
    // list does not reshuffle between openings (iOS sorts the same way).
    val candidates = remember(directConversations) {
        directConversations.mapNotNull { c -> c.peerUserId?.let { MapContact(it, c.id) } }
            .distinctBy { it.userId }
            .sortedBy { UserDirectory.displayName(it.userId).lowercase() }
    }
    // "In my contacts" == the address book gave us a saved name for them. Same predicate as
    // iOS (`directory.user(id)?.savedName?.isEmpty == false`).
    val contactsOnly = remember(candidates) {
        candidates.filter { !UserDirectory.user(it.userId)?.savedName.isNullOrBlank() }
    }

    var selected by remember { mutableStateOf(current.map { it.userId }.toSet()) }
    // Infer which scope the CURRENT audience matches so re-opening shows the truth rather than
    // always defaulting. Mirrors the iOS onAppear inference.
    var scope by remember {
        val cur = current.map { it.userId }.toSet()
        mutableStateOf(
            when {
                cur.isEmpty() -> MapAudienceScope.CONTACTS
                cur == candidates.map { it.userId }.toSet() -> MapAudienceScope.EVERYONE
                cur == contactsOnly.map { it.userId }.toSet() -> MapAudienceScope.CONTACTS
                else -> MapAudienceScope.SELECTED
            },
        )
    }

    // What the chosen scope resolves to — the exact list handed to setAudience().
    val resolved: List<MapContact> = when (scope) {
        MapAudienceScope.EVERYONE -> candidates
        MapAudienceScope.CONTACTS -> contactsOnly
        MapAudienceScope.SELECTED -> candidates.filter { selected.contains(it.userId) }
    }

    com.voiid.app.ui.components.VoiidSheet(
        visible = true,
        onDismiss = onDismiss,
        detents = listOf(com.voiid.app.ui.components.VoiidDetent.Medium, com.voiid.app.ui.components.VoiidDetent.Large),
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 28.dp)) {
            if (mode == MapAudienceMode.MANAGE) {
                ManageBody(
                    current = current,
                    isVisible = isVisible,
                    onRemove = onRemove,
                    onAddPeople = onAddPeople,
                    onStopAll = onStopAll,
                )
                return@Column
            }

            Text(
                "Who can see me",
                style = VoiidFont.rounded(20, FontWeight.Bold),
                color = VoiidColor.textPrimary,
            )
            Spacer(Modifier.size(4.dp))
            Text(
                "They see your approximate location on the Map until you turn Ghost Mode on. You can change this or stop anytime.",
                style = VoiidFont.rounded(13),
                color = VoiidColor.textSecondary,
            )
            Spacer(Modifier.size(16.dp))

            if (candidates.isEmpty()) {
                Text(
                    "You don’t have any 1:1 chats yet. Start a chat with someone first, then you can let them see you on the Map.",
                    style = VoiidFont.rounded(14),
                    color = VoiidColor.textSecondary,
                    modifier = Modifier.padding(vertical = 24.dp),
                )
            } else {
                ScopeCard(
                    icon = Icons.Default.Public,
                    title = "Everyone",
                    subtitle = "Everyone you’ve chatted with can see you",
                    count = candidates.size,
                    isSelected = scope == MapAudienceScope.EVERYONE,
                    showCount = true,
                ) { scope = MapAudienceScope.EVERYONE }
                Spacer(Modifier.size(8.dp))
                ScopeCard(
                    icon = Icons.Default.Group,
                    title = "My Contacts",
                    subtitle = "Only people saved in your contacts",
                    count = contactsOnly.size,
                    isSelected = scope == MapAudienceScope.CONTACTS,
                    showCount = true,
                ) { scope = MapAudienceScope.CONTACTS }
                Spacer(Modifier.size(8.dp))
                ScopeCard(
                    icon = Icons.Default.Person,
                    title = "Only selected people",
                    subtitle = "Pick exactly who can see you",
                    count = selected.size,
                    isSelected = scope == MapAudienceScope.SELECTED,
                    showCount = false,
                ) { scope = MapAudienceScope.SELECTED }

                // The per-person checklist appears inline ONLY under "Only selected people",
                // so the sheet stays a three-choice decision until you ask for the detail.
                if (scope == MapAudienceScope.SELECTED) {
                    Spacer(Modifier.size(12.dp))
                    LazyColumn(
                        Modifier.fillMaxWidth().heightIn(max = 300.dp),
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        items(candidates, key = { it.userId }) { contact ->
                            PersonRow(
                                userId = contact.userId,
                                isSelected = selected.contains(contact.userId),
                            ) {
                                selected = if (selected.contains(contact.userId)) {
                                    selected - contact.userId
                                } else {
                                    selected + contact.userId
                                }
                            }
                        }
                    }
                    Spacer(Modifier.size(4.dp))
                    Text(
                        "Only people you’ve chatted with appear here — the Map share needs an existing conversation.",
                        style = VoiidFont.rounded(11),
                        color = VoiidColor.textSecondary,
                    )
                }

                Spacer(Modifier.size(20.dp))
                VoiidPrimaryButton(
                    title = if (isVisible) "Update who can see me" else "Share my location",
                    modifier = Modifier.fillMaxWidth(),
                    enabled = resolved.isNotEmpty(),
                    onClick = { onConfirm(resolved) },
                )
                Spacer(Modifier.size(6.dp))
                Text(
                    when {
                        resolved.isNotEmpty() -> "You appear to no one until you tap this."
                        scope == MapAudienceScope.CONTACTS -> "No saved contacts you’ve chatted with yet."
                        else -> "Pick at least one person."
                    },
                    style = VoiidFont.rounded(11),
                    color = VoiidColor.textSecondary,
                )
            }
        }
    }
}

/** Which surface the sheet presents: the scope chooser, or the current-audience manager. */
enum class MapAudienceMode { CHOOSE, MANAGE }

/**
 * Who your location goes to. Every scope resolves to a concrete allow-list of people you can
 * actually reach (the map key rides a 1:1 conversation), so EVERYONE is bounded to everyone
 * you have chatted with — never the whole world.
 */
enum class MapAudienceScope { EVERYONE, CONTACTS, SELECTED }

/** A single tappable scope card (radio-style), mirroring the iOS `scopeRow`. */
@Composable
private fun ScopeCard(
    icon: ImageVector,
    title: String,
    subtitle: String,
    count: Int,
    isSelected: Boolean,
    showCount: Boolean,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .border(
                1.dp,
                if (isSelected) VoiidColor.primary else VoiidColor.fieldBorder,
                RoundedCornerShape(VoiidRadius.lg),
            )
            .clickable(onClick = onClick)
            .padding(vertical = 14.dp, horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = VoiidColor.primary, modifier = Modifier.size(22.dp))
        Spacer(Modifier.size(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Text(
                // The live count is shown on the selected card, so the consequence of the
                // choice ("· 12 people") is visible before you commit to it.
                if (isSelected && showCount) {
                    "$subtitle · $count ${if (count == 1) "person" else "people"}"
                } else {
                    subtitle
                },
                style = VoiidFont.rounded(12),
                color = VoiidColor.textSecondary,
            )
        }
        Spacer(Modifier.size(10.dp))
        Box(
            Modifier
                .size(22.dp)
                .clip(CircleShape)
                .border(2.dp, if (isSelected) VoiidColor.primary else VoiidColor.fieldBorder, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (isSelected) {
                Box(Modifier.size(12.dp).clip(CircleShape).background(VoiidColor.primary))
            }
        }
    }
}

/** One person in the inline checklist / manage list. */
@Composable
private fun PersonRow(userId: String, isSelected: Boolean, onToggle: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onToggle)
            .padding(vertical = 10.dp, horizontal = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AvatarPin(userId = userId, stale = false, size = 36.dp)
        Spacer(Modifier.size(12.dp))
        Text(
            UserDirectory.displayName(userId),
            style = VoiidFont.rounded(16, FontWeight.Medium),
            color = VoiidColor.textPrimary,
            modifier = Modifier.weight(1f),
        )
        Box(
            Modifier
                .size(24.dp)
                .clip(CircleShape)
                .background(if (isSelected) VoiidColor.primary else VoiidColor.fieldFill),
            contentAlignment = Alignment.Center,
        ) {
            if (isSelected) Icon(Icons.Default.Check, null, tint = Color.White, modifier = Modifier.size(16.dp))
        }
    }
}

/**
 * Manage mode: exactly who can see you right now, per-person Remove, and the kill switch.
 * The iOS counterpart additionally offers "Add people"; on Android the same sheet reopens in
 * CHOOSE mode from the pill, so a separate re-entry row would be a second path to one place.
 */
@Composable
private fun ManageBody(
    current: List<MapContact>,
    isVisible: Boolean,
    onRemove: (String) -> Unit,
    onAddPeople: () -> Unit,
    onStopAll: () -> Unit,
) {
    Text(
        "Your Map audience",
        style = VoiidFont.rounded(20, FontWeight.Bold),
        color = VoiidColor.textPrimary,
    )
    Spacer(Modifier.size(4.dp))
    if (current.isEmpty()) {
        Text(
            if (isVisible) "You’re visible to no one." else "Ghost Mode is on — you’re hidden from everyone.",
            style = VoiidFont.rounded(13),
            color = VoiidColor.textSecondary,
        )
    } else {
        Text(
            "Removing someone rotates your Map key and stops sending them new locations. It can’t un-see a location they already saw.",
            style = VoiidFont.rounded(13),
            color = VoiidColor.textSecondary,
        )
        Spacer(Modifier.size(12.dp))
        LazyColumn(
            Modifier.fillMaxWidth().heightIn(max = 340.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            items(current, key = { it.userId }) { c ->
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 10.dp, horizontal = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    AvatarPin(userId = c.userId, stale = false, size = 36.dp)
                    Spacer(Modifier.size(12.dp))
                    Text(
                        UserDirectory.displayName(c.userId),
                        style = VoiidFont.rounded(16, FontWeight.Medium),
                        color = VoiidColor.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        "Remove",
                        style = VoiidFont.rounded(13, FontWeight.SemiBold),
                        color = VoiidColor.error,
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .clickable { onRemove(c.userId) }
                            .padding(horizontal = 8.dp, vertical = 6.dp),
                    )
                }
            }
        }
    }

    Spacer(Modifier.size(20.dp))
    // "Add people" — the missing re-entry into the chooser. Without it the audience could
    // only ever shrink after the initial share. Mirrors iOS.
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .border(1.dp, VoiidColor.fieldBorder, RoundedCornerShape(VoiidRadius.lg))
            .clickable(onClick = onAddPeople)
            .padding(vertical = 14.dp, horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.PersonAddAlt, null, tint = VoiidColor.primary, modifier = Modifier.size(20.dp))
        Spacer(Modifier.size(12.dp))
        Text("Add people", style = VoiidFont.rounded(16, FontWeight.Medium), color = VoiidColor.primary)
    }

    Spacer(Modifier.size(12.dp))
    Box(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .border(1.dp, VoiidColor.error.copy(alpha = 0.5f), RoundedCornerShape(VoiidRadius.lg))
            .clickable(onClick = onStopAll)
            .padding(vertical = 16.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            "Stop all location sharing",
            style = VoiidFont.rounded(16, FontWeight.SemiBold),
            color = VoiidColor.error,
        )
    }
    Spacer(Modifier.size(6.dp))
    Text(
        "Ends every share and turns Ghost Mode on. Your location stops being taken at all.",
        style = VoiidFont.rounded(11),
        color = VoiidColor.textSecondary,
    )
}
