package com.voiid.app.main

import android.Manifest
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.voiid.app.model.ChatStore
import com.voiid.app.model.VConversation
import com.voiid.app.net.ApiError
import com.voiid.app.net.ContactsService
import com.voiid.app.net.VContact
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.launch

/**
 * "New group" builder — discovers VOIID contacts, lets you name the group + multi-select
 * members, then creates a REAL end-to-end encrypted MLS group via [ChatStore.createGroup]
 * (server container + MLS group build + Welcome/Commit distribution).
 */
/** One short of the server's 1000-member cap: the creator takes the last seat. */
private const val MAX_GROUP_OTHERS = 999

@Composable
fun NewGroupScreen(
    chat: ChatStore,
    onClose: () -> Unit,
    onOpen: (VConversation) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var matches by remember { mutableStateOf<List<VContact>>(emptyList()) }
    var creating by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    val selected = remember { mutableStateListOf<String>() }   // selected user ids
    var atCapacity by remember { mutableStateOf(false) }

    fun runDiscovery(force: Boolean = false) {
        scope.launch {
            loading = true; error = null
            try {
                matches = ContactsService(context).discover(forceRefresh = force).matches
            } catch (e: Exception) {
                error = (e as? ApiError)?.message ?: "Couldn’t access contacts."
            }
            loading = false
        }
    }

    val permLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) runDiscovery()
        else { loading = false; error = "Contacts permission is needed to add members." }
    }

    LaunchedEffect(Unit) {
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) runDiscovery() else permLauncher.launch(Manifest.permission.READ_CONTACTS)
    }

    val canCreate = name.trim().isNotEmpty() && selected.isNotEmpty() && !creating

    Column(Modifier.fillMaxSize().background(VoiidColor.background)) {
        // Top bar: close + title + Create
        Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Default.Close, "Close", tint = VoiidColor.textPrimary,
                modifier = Modifier.size(24.dp).clip(CircleShape).clickable { onClose() },
            )
            Spacer(Modifier.width(16.dp))
            Text("New group", style = VoiidFont.rounded(20, FontWeight.Bold), color = VoiidColor.textPrimary)
            Spacer(Modifier.weight(1f))
            Text(
                if (creating) "Creating…" else "Create",
                style = VoiidFont.rounded(16, FontWeight.SemiBold),
                color = if (canCreate) VoiidColor.primary else VoiidColor.textSecondary.copy(alpha = 0.5f),
                modifier = Modifier.clickable(enabled = canCreate) {
                    creating = true
                    scope.launch {
                        val conv = chat.createGroup(name.trim(), selected.toList())
                        creating = false
                        if (conv != null) onOpen(conv)
                    }
                },
            )
        }

        // Group name field
        Box(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp).height(50.dp)
                .clip(RoundedCornerShape(14.dp)).background(VoiidColor.fieldFill).padding(horizontal = 16.dp),
            contentAlignment = Alignment.CenterStart,
        ) {
            if (name.isEmpty()) Text("Group name", style = VoiidFont.rounded(16), color = VoiidColor.placeholder)
            BasicTextField(
                value = name, onValueChange = { name = it }, singleLine = true,
                textStyle = VoiidFont.rounded(16).merge(TextStyle(color = VoiidColor.textPrimary)),
                cursorBrush = SolidColor(VoiidColor.primary), modifier = Modifier.fillMaxWidth(),
            )
        }
        Spacer(Modifier.height(8.dp))
        Text(
            "${selected.size} selected", style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 6.dp),
        )

        when {
            loading -> Box(Modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator(color = VoiidColor.primary) }
            error != null -> Box(Modifier.fillMaxSize().padding(32.dp), Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(error!!, style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
                    Spacer(Modifier.height(12.dp))
                    Text("Try again", style = VoiidFont.rounded(14, FontWeight.SemiBold),
                        color = VoiidColor.primary, modifier = Modifier.clickable { runDiscovery(force = true) })
                }
            }
            else -> LazyColumn(Modifier.fillMaxSize()) {
                items(matches, key = { it.userId }) { c ->
                    val isSel = selected.contains(c.userId)
                    Row(
                        Modifier.fillMaxWidth().clickable {
                            if (isSel) {
                                selected.remove(c.userId)
                            } else if (selected.size >= MAX_GROUP_OTHERS) {
                                // 999 OTHERS, because the creator is the thousandth. The
                                // server enforces 1000 (036_group_roles.sql); refusing here
                                // means the user learns while choosing rather than after
                                // tapping Create and losing the whole selection to a 400.
                                atCapacity = true
                            } else {
                                selected.add(c.userId)
                            }
                        }.padding(horizontal = 20.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(
                            Modifier.size(40.dp).clip(CircleShape).background(VoiidColor.fieldFill),
                            Alignment.Center,
                        ) { Text(c.displayName.take(1).uppercase(), style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.primary) }
                        Spacer(Modifier.width(12.dp))
                        Text(c.displayName, style = VoiidFont.rounded(16, FontWeight.Medium), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
                        Icon(
                            if (isSel) Icons.Default.CheckCircle else Icons.Outlined.Circle, null,
                            tint = if (isSel) VoiidColor.primary else VoiidColor.textSecondary.copy(alpha = 0.5f),
                            modifier = Modifier.size(22.dp),
                        )
                    }
                }
                if (matches.isEmpty()) {
                    item {
                        Box(Modifier.fillMaxWidth().padding(32.dp), Alignment.Center) {
                            Text("No contacts on VOIID yet.", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
                        }
                    }
                }
            }
        }
    }
    if (atCapacity) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { atCapacity = false },
            containerColor = VoiidColor.surfaceCard,
            title = { Text("That's the limit", color = VoiidColor.textPrimary) },
            text = {
                Text(
                    "A group can have up to ${MAX_GROUP_OTHERS + 1} people, including you.",
                    color = VoiidColor.textSecondary,
                )
            },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = { atCapacity = false }) {
                    Text("OK", color = VoiidColor.primary)
                }
            },
        )
    }

}
