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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.CallMissed
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.voiid.app.model.ChatStore
import com.voiid.app.model.VConversation
import com.voiid.app.store.CallHistoryRow
import com.voiid.app.store.LocalStore
import com.voiid.app.store.UserDirectory
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidCircleBack
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.launch

/**
 * Recents — every call, newest first. Port of iOS `CallLogView.swift`.
 *
 * WHY THIS EXISTS. Call history was written to `call_history` from the first call the app
 * ever placed, but the only way to SEE it was to open the chat it happened in, or that
 * person's profile. So "who called me while I was out?" — the one question a call log answers
 * — had no answer anywhere in the app. The data was there; the screen was not.
 *
 * WHAT THIS IS NOT. There is no server-side call history: `call_history` is a LOCAL table,
 * written when THIS device places or receives a call. A call answered on another device does
 * not appear, and reinstalling loses the log. The empty state says so rather than implying
 * the user has never called anyone.
 */
@Composable
fun CallLogScreen(chat: ChatStore, onBack: () -> Unit, onOpenConversation: (VConversation) -> Unit) {
    BackHandler { onBack() }
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()

    var entries by remember { mutableStateOf<List<CallHistoryRow>>(emptyList()) }
    var missedOnly by remember { mutableStateOf(false) }
    var menuOpen by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { entries = LocalStore.recentCalls(context, limit = 500) }

    val visible = if (missedOnly) entries.filter { it.isMissed() } else entries

    if (confirmClear) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { confirmClear = false },
            containerColor = VoiidColor.surfaceCard,
            title = {
                Text("Clear call history?", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            },
            text = {
                // Say what is actually lost. This is device-local, so "on this device" is not
                // a hedge — it is the whole truth.
                Text(
                    "This removes every call from this device. It doesn't affect the other " +
                        "person's log.",
                    style = VoiidFont.rounded(14), color = VoiidColor.textSecondary,
                )
            },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    confirmClear = false
                    scope.launch { LocalStore.clearCallHistory(context); entries = emptyList() }
                }) { Text("Clear", color = VoiidColor.error) }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { confirmClear = false }) {
                    Text("Cancel", color = VoiidColor.textSecondary)
                }
            },
        )
    }

    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            VoiidCircleBack(onBack = onBack)
            Text(
                "Calls",
                style = VoiidFont.rounded(20, FontWeight.SemiBold),
                color = VoiidColor.textPrimary,
                modifier = Modifier.weight(1f),
            )
            if (entries.isNotEmpty()) {
                Box {
                    Icon(
                        Icons.Default.MoreVert, "More", tint = VoiidColor.textPrimary,
                        modifier = Modifier.size(40.dp).clip(CircleShape)
                            .clickable { haptics.tap(); menuOpen = true }.padding(8.dp),
                    )
                    DropdownMenu(
                        expanded = menuOpen,
                        onDismissRequest = { menuOpen = false },
                        containerColor = VoiidColor.surfaceCard,
                    ) {
                        DropdownMenuItem(
                            text = { Text("Clear call history", style = VoiidFont.rounded(15), color = VoiidColor.error) },
                            onClick = { menuOpen = false; haptics.rigid(); confirmClear = true },
                            leadingIcon = { Icon(Icons.Default.Delete, null, tint = VoiidColor.error) },
                        )
                    }
                }
            }
            Spacer(Modifier.size(8.dp))
        }

        if (entries.isNotEmpty()) {
            // All / Missed. Two options, so a segmented control rather than a menu — the
            // choice stays visible and one tap away.
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp)
                    .clip(RoundedCornerShape(VoiidRadius.md))
                    .background(VoiidColor.fieldFill)
                    .padding(3.dp),
                horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                listOf(false to "All", true to "Missed").forEach { (value, label) ->
                    val selected = missedOnly == value
                    Box(
                        Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(VoiidRadius.sm))
                            .background(if (selected) VoiidColor.primary else Color.Transparent)
                            .softClickable { haptics.selection(); missedOnly = value }
                            .padding(vertical = 9.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            label,
                            style = VoiidFont.rounded(13, if (selected) FontWeight.SemiBold else FontWeight.Medium),
                            color = if (selected) VoiidColor.textOnPrimary else VoiidColor.textSecondary,
                        )
                    }
                }
            }
        }

        when {
            entries.isEmpty() -> EmptyCallLog()
            // A filter matching nothing is NOT the same as an empty history. Saying "No calls
            // yet" here would be a lie and would read as a broken screen.
            visible.isEmpty() -> NoMissedCalls()
            else -> LazyColumn(Modifier.fillMaxSize()) {
                items(visible, key = { it.id }) { row ->
                    val conv = row.conversationId?.let { cid ->
                        (chat.directConversations + chat.groupConversations).firstOrNull { it.id == cid }
                    }
                    CallLogRow(
                        row = row,
                        name = callerName(row, conv),
                        photoUrl = row.peerUserId?.let { UserDirectory.photoUrl(it) },
                        onOpen = { conv?.let { haptics.tap(); onOpenConversation(it) } },
                    )
                    HorizontalDivider(
                        color = VoiidColor.divider.copy(alpha = 0.5f),
                        // Inset to start at the TEXT — the avatar column is a gutter and a
                        // full-width rule cuts through it.
                        modifier = Modifier.padding(start = 76.dp),
                    )
                }
            }
        }
    }
}

private fun CallHistoryRow.isMissed(): Boolean =
    direction == "incoming" && outcome != "answered" && outcome != "declined"

private fun callerName(row: CallHistoryRow, conv: VConversation?): String {
    row.peerUserId?.let { peer ->
        val resolved = UserDirectory.displayName(peer, fallback = "")
        if (resolved.isNotBlank()) return resolved
    }
    // Fall back to the conversation title before giving up — a group call has no single peer,
    // and an unknown 1:1 still has a chat with a name on it.
    return conv?.title ?: "Unknown"
}

/**
 * One call. The row answers three things at a glance: WHO, whether it was missed, and which
 * way it went. Time, duration and medium are secondary and styled that way.
 */
@Composable
private fun CallLogRow(
    row: CallHistoryRow,
    name: String,
    photoUrl: String?,
    onOpen: () -> Unit,
) {
    val missed = row.isMissed()
    // DIRECTION, not medium. Every call drawing the same phone glyph is what made incoming
    // and outgoing indistinguishable — the most useful fact about a call log.
    val icon: ImageVector = when {
        row.outcome == "declined" -> Icons.Default.CallEnd
        missed -> Icons.Default.CallMissed
        row.direction == "incoming" -> Icons.Default.ArrowDownward
        else -> Icons.Default.ArrowUpward
    }

    Row(
        Modifier
            .fillMaxWidth()
            .softClickable(onClick = onOpen)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        ProfileAvatar(photoUrl = photoUrl, name = name, size = 44.dp, modifier = Modifier.clip(CircleShape))

        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                name,
                // MISSED IS RED IN THE NAME, not only the icon. Colour alone fails for ~1 in
                // 12 men, so the glyph carries it too — but a missed call is the reason to
                // open this screen and should be findable by scanning.
                style = VoiidFont.rounded(16, FontWeight.Medium),
                color = if (missed) VoiidColor.error else VoiidColor.textPrimary,
                maxLines = 1,
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                Icon(
                    icon, null,
                    tint = if (missed) VoiidColor.error else VoiidColor.textSecondary,
                    modifier = Modifier.size(12.dp),
                )
                Text(
                    callSubtitle(row),
                    style = VoiidFont.rounded(12),
                    color = VoiidColor.textSecondary,
                    maxLines = 1,
                )
            }
        }

        // The medium doubles as the call-back button: tapping a video call returns a video
        // call. A separate control would repeat what this already says.
        Box(
            Modifier.size(36.dp).clip(CircleShape)
                .background(VoiidColor.primary.copy(alpha = 0.10f))
                .softClickable(onClick = onOpen),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (row.kind == "video") Icons.Default.Videocam else Icons.Default.Call,
                if (row.kind == "video") "Video call $name" else "Call $name",
                tint = VoiidColor.primary,
                modifier = Modifier.size(17.dp),
            )
        }
    }
}

private fun callSubtitle(row: CallHistoryRow): String {
    val parts = mutableListOf<String>()
    when (row.outcome) {
        "answered" -> {
            parts += if (row.direction == "incoming") "Incoming" else "Outgoing"
            row.endedAt?.let { end ->
                val s = ((end - row.startedAt) / 1000).coerceAtLeast(0)
                val m = s / 60
                parts += if (m >= 60) "%d:%02d:%02d".format(m / 60, m % 60, s % 60)
                         else "%d:%02d".format(m, s % 60)
            }
        }
        "declined" -> parts += if (row.direction == "incoming") "Declined" else "Call declined"
        "failed" -> parts += "Failed"
        else -> parts += if (row.direction == "incoming") "Missed" else "No answer"
    }
    parts += VoiidDate.bubbleTime(row.startedAt)
    return parts.joinToString(" · ")
}

@Composable
private fun EmptyCallLog() {
    Column(
        Modifier.fillMaxSize().padding(horizontal = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(
            Modifier.size(88.dp).clip(CircleShape).background(VoiidColor.primary.copy(alpha = 0.10f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Default.Call, null, tint = VoiidColor.primary, modifier = Modifier.size(32.dp))
        }
        Spacer(Modifier.height(16.dp))
        Text("No calls yet", style = VoiidFont.rounded(20, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        Spacer(Modifier.height(6.dp))
        // Names the LIMITATION, not only the absence: this log is written by this device, so
        // a user who has definitely called from elsewhere is not left thinking it is broken.
        Text(
            "Calls you make and receive on this device will appear here.",
            style = VoiidFont.rounded(14),
            color = VoiidColor.textSecondary,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun NoMissedCalls() {
    Column(
        Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Default.CheckCircle, null, tint = VoiidColor.success, modifier = Modifier.size(30.dp))
        Spacer(Modifier.height(8.dp))
        Text("No missed calls", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary)
    }
}
