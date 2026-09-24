package com.voiid.app.main

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.voiid.app.net.CommunityService
import kotlinx.coroutines.launch

internal val communityPostingPolicies = linkedMapOf(
    "everyone" to "Everyone", "managers" to "Managers only",
    "selected" to "Selected members", "none" to "Nobody",
)

@Composable
internal fun CommunityPostingPolicyPicker(value: String, enabled: Boolean = true, onChange: (String) -> Unit) {
    Column(Modifier.padding(12.dp)) {
        Text("Who can post")
        communityPostingPolicies.forEach { (key, title) ->
            Row {
                RadioButton(selected = value == key, onClick = { onChange(key) }, enabled = enabled)
                TextButton(onClick = { onChange(key) }, enabled = enabled) { Text(title) }
            }
        }
        Text(when (value) {
            "none" -> "Posting is paused for everyone, including managers."
            "selected" -> "Chosen members, the owner and admins can publish posts."
            "managers" -> "Only the owner and admins can publish posts."
            else -> "All active members can publish posts."
        })
    }
}

@Composable
internal fun CommunityPostingMembersDialog(communityId: String, channelId: String? = null, onClose: () -> Unit) {
    val context = LocalContext.current
    val service = remember { CommunityService(context) }
    val scope = rememberCoroutineScope()
    var members by remember { mutableStateOf<List<CommunityService.Member>>(emptyList()) }
    var selected by remember { mutableStateOf<Set<String>>(emptySet()) }
    var busy by remember { mutableStateOf<Set<String>>(emptySet()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var search by remember { mutableStateOf("") }
    var more by remember { mutableStateOf(true) }
    suspend fun load(reset: Boolean) {
        loading = true
        try {
            if (reset) selected = service.postingMembers(communityId, channelId).map { it.user_id }.toSet()
            val page = service.members(communityId, offset = if (reset) 0 else members.size)
            members = if (reset) page else members + page
            more = page.size == 50; error = null
        } catch (e: Exception) { error = e.message ?: "Couldn't load members." }
        loading = false
    }
    LaunchedEffect(communityId, channelId) { load(true) }
    com.voiid.app.ui.components.VoiidDialogCustom(
        onDismissRequest = { if (busy.isEmpty()) onClose() },
        backDismissable = busy.isEmpty(),
        scrimDismissable = busy.isEmpty(),
    ) {
            Text("Selected members")
            Column(Modifier.heightIn(max = 520.dp).verticalScroll(rememberScrollState())) {
                Text("Changes save immediately. Managers can already post when Selected members is active.")
                OutlinedTextField(search, { search = it }, label = { Text("Search loaded members") })
                if (loading) CircularProgressIndicator()
                error?.let { Text(it); TextButton(onClick = { scope.launch { load(true) } }) { Text("Try again") } }
                members.filter { search.isBlank() || (it.full_name ?: it.username ?: "Member").contains(search, true) }.forEach { member ->
                    Row {
                        Checkbox(checked = member.isAdmin || member.user_id in selected,
                            enabled = !member.isAdmin && !loading && error == null && member.user_id !in busy,
                            onCheckedChange = { value ->
                                scope.launch {
                                    busy = busy + member.user_id
                                    try {
                                        service.setPostingMember(communityId, member.user_id, channelId, value)
                                        selected = if (value) selected + member.user_id else selected - member.user_id
                                        error = null
                                    } catch (e: Exception) { error = e.message ?: "Couldn't save permission." }
                                    busy = busy - member.user_id
                                }
                            })
                        Column { Text(member.full_name ?: member.username ?: "Member"); if (member.isAdmin) Text("Manager") }
                    }
                }
                if (more && !loading) TextButton(onClick = { scope.launch { load(false) } }) { Text("Load more members") }
            }
            com.voiid.app.ui.components.VoiidDialogAction("Done", enabled = busy.isEmpty(), onClick = onClose)
    }
}

@Composable
internal fun CommunitySpaceSettingsDialog(communityId: String, channel: CommunityService.Channel, onSaved: () -> Unit, onClose: () -> Unit) {
    val context = LocalContext.current
    val service = remember { CommunityService(context) }
    val scope = rememberCoroutineScope()
    var posting by remember { mutableStateOf(channel.posting) }
    var purpose by remember { mutableStateOf(channel.purpose ?: "") }
    var pinned by remember { mutableStateOf(channel.pinned_at != null) }
    var choosing by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    if (choosing) CommunityPostingMembersDialog(communityId, channel.conversation_id) { choosing = false }
    com.voiid.app.ui.components.VoiidDialogCustom(
        onDismissRequest = { if (!saving) onClose() },
        backDismissable = !saving,
        scrimDismissable = !saving,
    ) {
        Text("Space settings")
        Column(Modifier.heightIn(max = 520.dp).verticalScroll(rememberScrollState())) {
            OutlinedTextField(purpose, { purpose = it.take(200) }, label = { Text("Description") }, enabled = !saving)
            Row { Checkbox(pinned, { pinned = it }, enabled = !saving); Text("Pin to top") }
            CommunityPostingPolicyPicker(posting, !saving) { posting = it }
            if (posting == "selected") TextButton(onClick = { choosing = true }, enabled = !saving) { Text("Choose members") }
            error?.let { Text(it) }
        }
        com.voiid.app.ui.components.VoiidDialogAction(if (saving) "Saving…" else "Save", enabled = !saving) { scope.launch {
            saving = true
            try { service.updateSpace(communityId, channel.conversation_id, posting, purpose, pinned); onSaved() }
            catch (e: Exception) { error = e.message ?: "Couldn't save Space." }
            saving = false
        } }
        com.voiid.app.ui.components.VoiidDialogAction("Cancel", enabled = !saving, onClick = onClose)
    }
}
