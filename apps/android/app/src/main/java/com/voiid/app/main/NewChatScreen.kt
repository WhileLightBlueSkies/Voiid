package com.voiid.app.main

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.voiid.app.model.ChatStore
import com.voiid.app.model.VConversation
import com.voiid.app.net.ApiError
import com.voiid.app.net.ContactsService
import com.voiid.app.net.InviteContact
import com.voiid.app.net.VContact
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.launch

/**
 * "New chat" picker — discovers which contacts are on VOIID (hashed on-device via
 * ContactsService), lists them to start an E2EE 1:1 chat, and offers an invite
 * share-intent for the rest. Port of iOS NewChatView.
 */
@Composable
fun NewChatScreen(
    chat: ChatStore,
    onClose: () -> Unit,
    onOpen: (VConversation) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var matches by remember { mutableStateOf<List<VContact>>(emptyList()) }
    var invites by remember { mutableStateOf<List<InviteContact>>(emptyList()) }
    var starting by remember { mutableStateOf(false) }

    fun runDiscovery() {
        scope.launch {
            loading = true; error = null
            try {
                val result = ContactsService(context).discover()
                matches = result.matches
                invites = result.invites
            } catch (e: Exception) {
                error = (e as? ApiError)?.message
                    ?: "Couldn’t access contacts. Enable Contacts access in Settings."
            }
            loading = false
        }
    }

    val permLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) runDiscovery()
        else { loading = false; error = "Contacts permission is needed to find friends on VOIID." }
    }

    LaunchedEffect(Unit) {
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) runDiscovery() else permLauncher.launch(Manifest.permission.READ_CONTACTS)
    }

    Column(Modifier.fillMaxSize().background(VoiidColor.background)) {
        // Top bar
        Row(
            Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Default.Close, "Close", tint = VoiidColor.textPrimary,
                modifier = Modifier.size(24.dp).clip(CircleShape).clickable { onClose() },
            )
            Spacer(Modifier.width(16.dp))
            Text("New chat", style = VoiidFont.rounded(20, FontWeight.Bold), color = VoiidColor.textPrimary)
        }

        when {
            loading -> Box(Modifier.fillMaxSize(), Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(color = VoiidColor.primary)
                    Spacer(Modifier.height(12.dp))
                    Text("Finding your contacts on VOIID…",
                        style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                }
            }
            error != null -> Box(Modifier.fillMaxSize().padding(32.dp), Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(error!!, style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
                    Spacer(Modifier.height(12.dp))
                    Text("Try again", style = VoiidFont.rounded(14, FontWeight.SemiBold),
                        color = VoiidColor.primary, modifier = Modifier.clickable { runDiscovery() })
                }
            }
            else -> LazyColumn(Modifier.fillMaxSize()) {
                if (matches.isNotEmpty()) {
                    item { SectionHeader("On VOIID") }
                    items(matches, key = { it.userId }) { c ->
                        ContactRow(c.displayName, "Tap to chat", onVoiid = true, enabled = !starting) {
                            starting = true
                            scope.launch {
                                val conv = chat.startDirectChat(c)
                                starting = false
                                if (conv != null) onOpen(conv)
                            }
                        }
                    }
                }
                if (invites.isNotEmpty()) {
                    item { SectionHeader("Invite to VOIID") }
                    items(invites, key = { it.number }) { c ->
                        ContactRow(c.name, c.number, onVoiid = false, enabled = true) {
                            val text = "Hey ${c.name}, let's chat privately on VOIID — end-to-end encrypted messaging. https://voiid.app"
                            val send = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"; putExtra(Intent.EXTRA_TEXT, text)
                            }
                            context.startActivity(Intent.createChooser(send, "Invite to VOIID"))
                        }
                    }
                }
                if (matches.isEmpty() && invites.isEmpty()) {
                    item {
                        Box(Modifier.fillMaxWidth().padding(32.dp), Alignment.Center) {
                            Text("No contacts found.", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        title, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textSecondary,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 10.dp),
    )
}

@Composable
private fun ContactRow(name: String, subtitle: String, onVoiid: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(enabled = enabled) { onClick() }
            .padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(40.dp).clip(CircleShape).background(VoiidColor.fieldFill),
            Alignment.Center,
        ) { Text(name.take(1).uppercase(), style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.primary) }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(name, style = VoiidFont.rounded(16, FontWeight.Medium), color = VoiidColor.textPrimary)
            Text(subtitle, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
        }
        if (!onVoiid) {
            Text("Invite", style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.primary)
        }
    }
}
