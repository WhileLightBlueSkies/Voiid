package com.voiid.app.main

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AccountBox
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.voiid.app.main.clips.CreatorEditSheet
import com.voiid.app.main.clips.SocialSetupSheet
import com.voiid.app.model.SocialStore
import com.voiid.app.ui.components.VoiidCardSection
import com.voiid.app.ui.components.VoiidChevron
import com.voiid.app.ui.components.VoiidRowDivider
import com.voiid.app.ui.components.VoiidSettingsHeader
import com.voiid.app.ui.components.VoiidSettingsRow
import com.voiid.app.ui.theme.VoiidColor
import kotlinx.coroutines.launch

/** Port of iOS `AccountCenterScreen` (Settings → Account center). */
@Composable
fun AccountCenterScreen(
    creators: SocialStore,
    onBack: () -> Unit,
    onChatProfile: () -> Unit,
    onViewSocialProfile: () -> Unit,
    onProfileSettings: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var loadingProfile by remember { mutableStateOf(true) }
    var showEdit by remember { mutableStateOf(false) }
    var showSetup by remember { mutableStateOf(false) }

    suspend fun loadProfile() {
        loadingProfile = true
        creators.ensureMeLoaded()
        loadingProfile = false
    }
    LaunchedEffect(Unit) { loadProfile() }

    BackupScaffold(title = "Account Center", onBack = onBack) {
        Column(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
            VoiidSettingsHeader("Account Center", subtitle = "Manage your chat and social profiles.")

            VoiidCardSection("Chat profile") {
                VoiidSettingsRow(Icons.Outlined.AccountCircle, "Chat profile",
                    detail = "Your name, photo and chat username", onClick = onChatProfile) { VoiidChevron() }
            }

            VoiidCardSection("Social profile", footer = "Your social identity and privacy are separate from your chats.") {
                val profile = creators.me
                when {
                    profile != null -> {
                        VoiidSettingsRow(Icons.Outlined.AccountBox, "View profile",
                            detail = "@${profile.handle}", onClick = onViewSocialProfile) { VoiidChevron() }
                        VoiidRowDivider()
                        VoiidSettingsRow(Icons.Outlined.Edit, "Edit profile",
                            detail = "Photo, username, bio and link", onClick = { showEdit = true }) { VoiidChevron() }
                        VoiidRowDivider()
                        VoiidSettingsRow(Icons.Outlined.Tune, "Profile settings",
                            detail = "Visibility, followers and comments", onClick = onProfileSettings) { VoiidChevron() }
                    }
                    loadingProfile || creators.meLoading ->
                        VoiidSettingsRow(Icons.Outlined.AccountBox, "Social profile", detail = "Loading your profile…") {
                            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = VoiidColor.textSecondary)
                        }
                    creators.hasLoadedMe ->
                        VoiidSettingsRow(Icons.Outlined.AccountBox, "Social profile",
                            detail = "Set up your social identity", onClick = { showSetup = true }) { VoiidChevron() }
                    else ->
                        VoiidSettingsRow(Icons.Outlined.AccountBox, "Social profile",
                            detail = "Couldn’t load your profile. Tap to retry.",
                            onClick = { scope.launch { loadProfile() } }) {
                            Icon(Icons.Outlined.Refresh, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(18.dp))
                        }
                }
            }
        }
    }

    if (showEdit) creators.me?.let { CreatorEditSheet(profile = it, creators = creators, onDismiss = { showEdit = false }) }
    if (showSetup) SocialSetupSheet(
        creators = creators,
        onCreated = { creators.profileCreated(it); showSetup = false },
        onDismiss = { showSetup = false },
    )
}
