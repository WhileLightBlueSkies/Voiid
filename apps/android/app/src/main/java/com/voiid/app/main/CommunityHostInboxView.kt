package com.voiid.app.main

import kotlinx.coroutines.launch
import androidx.lifecycle.repeatOnLifecycle

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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.Icon
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
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.clickable
import com.voiid.app.net.CommunityHostThreads
import com.voiid.app.store.UserDirectory
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/**
 * The Community inbox — every host thread the caller is on, FROM BOTH ENDS: threads they opened
 * as a member, and threads opened with them as the host. Port of iOS `CommunityInboxView`.
 *
 * Rows carry IDS ONLY (the server cannot describe encrypted content), so names resolve through
 * UserDirectory and everything else lives in the local chat store. Tapping opens that
 * conversation in the Chats tab.
 */
@Composable
fun CommunityHostInboxView(
    onOpenConversation: (String) -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    var threads by remember { mutableStateOf<List<CommunityHostThreads.HostThreadSummary>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        runCatching { CommunityHostThreads(context).all() }
            .onSuccess { threads = it }
            .onFailure { error = "Couldn't load your community chats." }
    }

    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("← Back", style = VoiidFont.rounded(15, FontWeight.Medium),
                 color = VoiidColor.primary, modifier = Modifier.softClickable(onClick = onClose))
            Spacer(Modifier.weight(1f))
        }
        Text("Community", style = VoiidFont.rounded(22, FontWeight.Bold), color = VoiidColor.textPrimary,
             modifier = Modifier.padding(horizontal = 16.dp))
        Text("Private lines between members and hosts.",
             style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
             modifier = Modifier.padding(horizontal = 16.dp).padding(top = 2.dp))
        Spacer(Modifier.height(10.dp))

        when {
            error != null -> InboxNote(error!!)
            threads == null -> InboxNote("Loading…")
            threads!!.isEmpty() -> InboxNote("No community chats yet. Message a host — or have someone message you.")
            else -> LazyColumn(contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp)) {
                items(threads!!, key = { it.conversation_id }) { t ->
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg))
                            .background(VoiidColor.surfaceCard)
                            .clickable { haptics.tap(); onOpenConversation(t.conversation_id) }
                            .padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        VoiidAvatar(size = 44.dp, modifier = Modifier.clip(CircleShape))
                        Column(Modifier.weight(1f)) {
                            Text(
                                t.community_name ?: t.community_handle?.let { "@$it" } ?: "Community",
                                style = VoiidFont.rounded(15, FontWeight.SemiBold),
                                color = VoiidColor.textPrimary,
                            )
                            val peer = t.member_user_id?.takeIf { it.isNotBlank() }?.let { UserDirectory.displayName(it) }
                            Text(
                                if (t.amHost) peer?.let { "From $it" } ?: "Member thread" else "With the host",
                                style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
                            )
                        }
                        if (t.amHost) {
                            Text("host", style = VoiidFont.rounded(11, FontWeight.SemiBold),
                                 color = VoiidColor.primary,
                                 modifier = Modifier.clip(CircleShape)
                                     .background(VoiidColor.primary.copy(alpha = 0.1f))
                                     .padding(horizontal = 7.dp, vertical = 2.dp))
                        }
                        Icon(Icons.Default.ChevronRight, null, tint = VoiidColor.placeholder, modifier = Modifier.size(18.dp))
                    }
                    Spacer(Modifier.height(8.dp))
                }
            }
        }
    }
}

@Composable
private fun InboxNote(text: String) {
    Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        Text(text, style = VoiidFont.rounded(14), color = VoiidColor.textSecondary, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}

@androidx.compose.runtime.Composable
internal fun CommunityRequestInbox(communityId: String, onClose: () -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val service = androidx.compose.runtime.remember { com.voiid.app.net.CommunityService(context) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var rows by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<List<com.voiid.app.net.CommunityService.QueueItem>>(emptyList()) }
    var loading by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
    var busy by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
    var error by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<String?>(null) }
    suspend fun load() {
        if (loading) return
        loading = true
        try { rows = service.moderationQueue(communityId); error = null }
        catch (e: kotlinx.coroutines.CancellationException) { throw e }
        catch (_: Exception) { error = "Couldn’t load community inbox." }
        finally { loading = false }
    }
    val lifecycle = androidx.compose.ui.platform.LocalLifecycleOwner.current.lifecycle
    androidx.compose.runtime.LaunchedEffect(communityId, lifecycle) {
        lifecycle.repeatOnLifecycle(androidx.lifecycle.Lifecycle.State.STARTED) {
            while (true) { load(); kotlinx.coroutines.delay(10000) }
        }
    }
    EventControlPage("Community Inbox", onClose) {
        androidx.compose.foundation.lazy.LazyColumn(contentPadding = androidx.compose.foundation.layout.PaddingValues(20.dp)) {
            item { androidx.compose.material3.TextButton(enabled = !loading, onClick = { scope.launch { load() } }) { Text(if (loading) "Loading…" else "Refresh") } }
            error?.let { item { Text(it) } }
            if (!loading && error == null && rows.isEmpty()) item { Text("No pending requests or reports.") }
            items(rows, key = { it.id }) { row ->
                androidx.compose.foundation.layout.Column(Modifier.padding(vertical = 12.dp)) {
                    Text(if (row.kind == "join_request") "Join request" else "Reported post")
                    Text(row.username?.let { "@$it" } ?: row.subject ?: "Someone")
                    row.detail?.let { Text(it) }
                    if (row.kind == "join_request" && row.user_id != null) {
                        androidx.compose.foundation.layout.Row {
                            listOf(true, false).forEach { approve ->
                                androidx.compose.material3.TextButton(enabled = !busy, onClick = {
                                    if (!busy) { busy = true; scope.launch {
                                        try { if (approve) service.approveMember(communityId, row.user_id) else service.removeMember(communityId, row.user_id); load() }
                                        catch (e: kotlinx.coroutines.CancellationException) { throw e }
                                        catch (_: Exception) { error = "Couldn’t update this request. Refresh and try again." }
                                        finally { busy = false }
                                    } }
                                }) { Text(if (approve) "Approve" else "Decline") }
                            }
                        }
                    } else { Text("Review this report in Admin panel.") }
                }
            }
        }
    }
}
