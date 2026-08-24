package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.VideocamOff
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.net.GroupCallManager
import com.voiid.app.ui.theme.VoiidColor

/**
 * The participant roster for a group call (plan item 3.15, part 2). Mirrors
 * `GroupCallRosterSheet.swift`.
 *
 * ## Why the grid is not enough
 * The call grid answers "what does the call look like". It does not answer "who is here" —
 * past a handful of people the tiles are too small to read a name off, mute state is a corner
 * badge a few dp across, and someone with their camera off is a monogram. On a 1000-member
 * group the call may hold dozens of people and the grid becomes unreadable exactly when
 * knowing the roster matters most.
 *
 * ## This is a view, not a control panel
 * There are deliberately no moderation affordances here — no remote mute, no remove. Muting
 * someone else's microphone from your device is a capability this app does not have and
 * should not grow casually: it needs a permission model (who may do it, to whom) that the
 * group-roles work defines but the CALL layer does not yet consult. Shipping the button
 * before the model exists is how you get a call where anyone can silence anyone.
 *
 * Nothing here is derived from server state. Every row comes from the live LiveKit session
 * this device is already in, so the roster cannot disagree with the call it describes.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GroupCallRosterSheet(
    participants: List<GroupCallManager.Participant>,
    onDismiss: () -> Unit,
) {
    // Speakers first, then everyone else alphabetically, with YOU pinned to the top.
    //
    // Sorting by speaking state alone would make the list jump every time somebody drew
    // breath, so the ordering is stable within each bucket — a name only moves when the
    // person actually starts or stops talking, never on a re-render.
    val ordered = participants.sortedWith(
        compareByDescending<GroupCallManager.Participant> { it.isLocal }
            .thenByDescending { it.speaking }
            .thenBy { it.name.lowercase() },
    )

    com.voiid.app.ui.components.VoiidSheet(visible = true, onDismiss = onDismiss, detents = listOf(com.voiid.app.ui.components.VoiidDetent.Medium, com.voiid.app.ui.components.VoiidDetent.Large),) {
        Text(
            "On this call",
            fontSize = 17.sp,
            color = VoiidColor.textPrimary,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
        // Lazy: a call roster is bounded by who JOINED, but that is not a number this screen
        // gets to assume — 1000-member groups are a supported shape.
        LazyColumn {
            items(ordered, key = { it.identity }) { p ->
                RosterRow(p)
                HorizontalDivider(color = VoiidColor.textSecondary.copy(alpha = 0.15f))
            }
        }
        Spacer40()
    }
}

@Composable
private fun RosterRow(p: GroupCallManager.Participant) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(VoiidColor.surfaceCard)
                // The same accent ring the grid tile uses, so "who is talking" reads
                // identically in both places rather than being two visual languages.
                .border(
                    width = if (p.speaking) 2.5.dp else 0.dp,
                    color = VoiidColor.accent,
                    shape = CircleShape,
                ),
            contentAlignment = Alignment.Center,
        ) {
            Text(initials(p.name), fontSize = 15.sp, color = VoiidColor.textSecondary)
        }

        Column(modifier = Modifier.weight(1f)) {
            Text(
                if (p.isLocal) "${p.name} (you)" else p.name,
                fontSize = 15.sp,
                color = VoiidColor.textPrimary,
                maxLines = 1,
            )
            if (p.speaking) {
                Text("Speaking", fontSize = 11.sp, color = VoiidColor.accent)
            }
        }

        // Muted is shown; UNmuted deliberately is not. A row of "everyone's mic is on" icons
        // is noise — the badge exists to flag the exception.
        if (p.micMuted) {
            Icon(
                Icons.Default.MicOff,
                contentDescription = "Microphone off",
                tint = VoiidColor.textSecondary,
                modifier = Modifier.size(16.dp),
            )
        }
        Icon(
            if (p.cameraOn) Icons.Default.Videocam else Icons.Default.VideocamOff,
            contentDescription = if (p.cameraOn) "Camera on" else "Camera off",
            tint = if (p.cameraOn) VoiidColor.primary else VoiidColor.textSecondary,
            modifier = Modifier.size(16.dp),
        )
    }
}

@Composable
private fun Spacer40() {
    Box(Modifier.height(40.dp))
}

private fun initials(name: String): String {
    val s = name.split(" ").take(2).mapNotNull { it.firstOrNull() }.joinToString("")
    return if (s.isBlank()) "?" else s.uppercase()
}
