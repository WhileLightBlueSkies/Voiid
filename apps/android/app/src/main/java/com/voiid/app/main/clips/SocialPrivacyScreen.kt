package com.voiid.app.main.clips

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Numbers
import androidx.compose.material.icons.outlined.People
import androidx.compose.material.icons.outlined.PersonAddAlt
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import com.voiid.app.main.BackupScaffold
import com.voiid.app.model.SocialStore
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidCardSection
import com.voiid.app.ui.components.VoiidRowDivider
import com.voiid.app.ui.components.VoiidSettingsRow
import com.voiid.app.ui.components.VoiidToggle
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/**
 * Port of iOS `SocialPrivacyView`: privacy controls for the PUBLIC creator profile.
 *
 * Every control saves immediately — no Save button, because a privacy screen with an unsaved
 * state can leave someone believing they are hidden when they are not. Each change PATCHes
 * only its own field and reverts visibly if the server refuses.
 */
@Composable
fun SocialPrivacyScreen(creators: SocialStore, onBack: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()

    var gridVisibility by remember { mutableStateOf("everyone") }
    var showCounts by remember { mutableStateOf(true) }
    var discoverable by remember { mutableStateOf(true) }
    var allowFollows by remember { mutableStateOf(true) }
    var allowComments by remember { mutableStateOf(true) }
    var errorText by remember { mutableStateOf<String?>(null) }

    suspend fun seed() {
        val p = creators.ensureMeLoaded() ?: return
        gridVisibility = p.grid_visibility ?: "everyone"
        showCounts = p.show_counts ?: true
        discoverable = p.discoverable ?: true
        allowFollows = p.allow_follows ?: true
        allowComments = p.allow_comments ?: true
    }
    LaunchedEffect(Unit) { seed() }

    fun save(
        grid: String? = null, counts: Boolean? = null, disc: Boolean? = null,
        follows: Boolean? = null, comments: Boolean? = null,
    ) {
        errorText = null
        scope.launch {
            try {
                creators.updatePrivacy(grid, counts, disc, follows, comments)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // Put the switch back: a privacy control that silently fails leaves someone
                // believing they are hidden when they are not.
                errorText = "Couldn’t save that. Check your connection and try again."
                creators.refreshMe()
                seed()
            }
        }
    }

    BackupScaffold(title = "Profile privacy", onBack = onBack) {
        Column(Modifier.fillMaxWidth().padding(vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
            errorText?.let {
                Text(it, style = VoiidFont.rounded(12), color = VoiidColor.error, modifier = Modifier.padding(horizontal = 16.dp))
            }

            VoiidCardSection("Your clips", footer = when (gridVisibility) {
                "followers" -> "People can still find your profile and see your bio — but only followers see your clips."
                "nobody" -> "Your clips stay on your profile for you alone. They remain in the main feed unless you delete them."
                else -> "Anyone on Voiid can see your clips on your profile."
            }) {
                GridChoice.entries.forEachIndexed { i, choice ->
                    if (i > 0) VoiidRowDivider()
                    VoiidSettingsRow(choice.icon, choice.title, onClick = {
                        haptics.selection()
                        gridVisibility = choice.id
                        save(grid = choice.id)
                    }) {
                        if (gridVisibility == choice.id) {
                            Icon(Icons.Default.Check, "Selected", tint = VoiidColor.primary, modifier = Modifier.size(18.dp))
                        }
                    }
                }
            }

            VoiidCardSection(
                "Your audience",
                footer = "Turning off follows keeps the people who already follow you — it only stops new ones. " +
                    "Comments are hidden, not deleted, so turning them back on restores the conversation.",
            ) {
                VoiidSettingsRow(Icons.Outlined.PersonAddAlt, "Allow new followers") {
                    VoiidToggle(allowFollows) { allowFollows = it; save(follows = it) }
                }
                VoiidRowDivider()
                VoiidSettingsRow(Icons.Outlined.ChatBubbleOutline, "Allow comments") {
                    VoiidToggle(allowComments) { allowComments = it; save(comments = it) }
                }
                VoiidRowDivider()
                VoiidSettingsRow(Icons.Outlined.Numbers, "Show follower counts") {
                    VoiidToggle(showCounts) { showCounts = it; save(counts = it) }
                }
            }

            VoiidCardSection(
                "Discovery",
                footer = "When this is off you won’t appear in search or suggestions. Anyone with a direct link " +
                    "to your profile can still open it — this makes you unlisted, not unreachable.",
            ) {
                VoiidSettingsRow(Icons.Outlined.Search, "Show in search") {
                    VoiidToggle(discoverable) { discoverable = it; save(disc = it) }
                }
            }
        }
    }
}

private enum class GridChoice(val id: String, val title: String, val icon: ImageVector) {
    EVERYONE("everyone", "Everyone", Icons.Outlined.Public),
    FOLLOWERS("followers", "Followers only", Icons.Outlined.People),
    NOBODY("nobody", "Only me", Icons.Outlined.Lock),
}
