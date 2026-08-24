package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
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
import coil.compose.AsyncImage
import com.voiid.app.net.BlockService
import com.voiid.app.net.BlockedUser
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.launch

/**
 * Settings -> Privacy -> Blocked contacts. Twin of iOS `BlockedContactsView.swift`.
 *
 * The list of people this account has blocked, and the only place to unblock them. Blocking
 * happens on a person's profile; unblocking needs a home that does not require finding the
 * person you have been avoiding, which is the entire reason this screen exists.
 *
 * THE FOOTER IS LOAD-BEARING
 * --------------------------
 * Blocking is SYMMETRIC on the server: neither party can message or call the other. A user
 * who assumes Block is a one-way mute will read their own failed sends as a bug, so the
 * screen says it plainly rather than leaving them to find out.
 *
 * It also says what blocking does NOT do. Blocking is not deletion — history stays, shared
 * groups stay, and nothing is announced to the other person. Each of those is a reasonable
 * and wrong assumption, and the cost of getting one wrong is someone believing a
 * conversation is gone when it is not.
 *
 * Rows use `forEach` inside [BackupScaffold]'s already-scrollable column rather than a
 * LazyColumn, which would crash on an infinite-height constraint. Blocked lists are short.
 */import com.voiid.app.ui.components.voiidPullRefresh
import com.voiid.app.ui.components.rememberVoiidPullRefresh

@Composable
fun BlockedContactsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    val blocked by BlockService.blocked.collectAsState()
    val didLoad by BlockService.didLoad.collectAsState()
    val pending by BlockService.pending.collectAsState()

    var confirmUnblock by remember { mutableStateOf<BlockedUser?>(null) }
    var failure by remember { mutableStateOf<String?>(null) }

    val pull = com.voiid.app.ui.components.rememberVoiidPullRefresh { scope.launch { BlockService.refresh(context) } }
    LaunchedEffect(Unit) { BlockService.loadIfNeeded(context) }

    BackupScaffold(
        title = "Blocked Contacts",
        onBack = onBack,
        modifier = Modifier.voiidPullRefresh(pull, VoiidColor.primary),
    ) {
        when {
            // Distinct from the empty state on purpose: "you have blocked nobody" is a
            // claim, and making it before the list has loaded is making it up.
            !didLoad -> {
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 24.dp),
                    horizontalArrangement = Arrangement.Center,
                ) {
                    CircularProgressIndicator(color = VoiidColor.primary)
                }
            }

            blocked.isEmpty() -> {
                Text(
                    "You haven't blocked anyone.",
                    style = VoiidFont.rounded(15),
                    color = VoiidColor.textSecondary,
                    modifier = Modifier.padding(vertical = 12.dp),
                )
            }

            else -> {
                Column(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(VoiidRadius.lg))
                        .background(VoiidColor.surfaceCard),
                ) {
                    blocked.forEachIndexed { index, user ->
                        if (index > 0) {
                            HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.4f))
                        }
                        BlockedRow(
                            user = user,
                            busy = pending.contains(user.id),
                            onUnblock = { confirmUnblock = user },
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(12.dp))
        Text(
            "Blocked people can't message or call you — and you can't message or call them. "
                + "They're never told. Your past messages and any groups you share stay "
                + "where they are.",
            style = VoiidFont.rounded(12),
            color = VoiidColor.textSecondary,
        )
    }

    confirmUnblock?.let { user ->
        com.voiid.app.ui.components.VoiidDialog(
            onDismissRequest = { confirmUnblock = null },
            title = "Unblock ${user.displayName}?",
            body = "They'll be able to message and call you again.",
            confirmLabel = "Unblock",
            onConfirm = {
                confirmUnblock = null
                scope.launch {
                    val ok = BlockService.unblock(context, user.id)
                    if (!ok) {
                        failure = "Check your connection and try again. " +
                            "${user.displayName} is still blocked."
                    }
                }
            },
        )
    }

    failure?.let { message ->
        com.voiid.app.ui.components.VoiidDialog(
            onDismissRequest = { failure = null },
            title = "Couldn't unblock",
            body = message,
            confirmLabel = "OK",
            onConfirm = { failure = null },
            cancelLabel = null,
        )
    }
}

@Composable
private fun BlockedRow(user: BlockedUser, busy: Boolean, onUnblock: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Avatar(user)
        Spacer(Modifier.size(12.dp))

        Column(Modifier.weight(1f)) {
            Text(user.displayName,
                 style = VoiidFont.rounded(16, FontWeight.Medium),
                 color = VoiidColor.textPrimary)
            // Only when it adds something — repeating the display name as "@name"
            // underneath itself is noise.
            val handle = user.username
            if (!handle.isNullOrEmpty() && user.displayName != "@$handle") {
                Text("@$handle",
                     style = VoiidFont.rounded(13),
                     color = VoiidColor.textSecondary)
            }
        }

        if (busy) {
            CircularProgressIndicator(
                color = VoiidColor.textSecondary,
                modifier = Modifier.size(18.dp),
                strokeWidth = 2.dp,
            )
        } else {
            Text(
                "Unblock",
                style = VoiidFont.rounded(15, FontWeight.Medium),
                color = VoiidColor.primary,
                modifier = Modifier.softClickable { onUnblock() },
            )
        }
    }
}

/** Remote photo with a single-letter fallback, for accounts with no avatar. */
@Composable
private fun Avatar(user: BlockedUser) {
    Box(
        Modifier.size(38.dp).clip(CircleShape).background(VoiidColor.fieldFill),
        contentAlignment = Alignment.Center,
    ) {
        val url = user.photo_url
        if (!url.isNullOrEmpty()) {
            AsyncImage(model = url, contentDescription = null, modifier = Modifier.size(38.dp))
        } else {
            Text(
                user.displayName.trimStart('@').take(1).uppercase(),
                style = VoiidFont.rounded(16, FontWeight.SemiBold),
                color = VoiidColor.textSecondary,
            )
        }
    }
}
