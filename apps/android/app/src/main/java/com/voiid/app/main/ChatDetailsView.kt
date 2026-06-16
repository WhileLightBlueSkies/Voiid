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
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.PermMedia
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.ReportGmailerrorred
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
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
import com.voiid.app.model.ConversationType
import com.voiid.app.model.VConversation
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/**
 * Chat details / profile — opened by tapping the name/avatar in a chat.
 * (Not present in the iOS source yet; built native + on-brand. Mute toggle has its own haptic.)
 */
@Composable
fun ChatDetailsView(conversation: VConversation, onBack: () -> Unit) {
    BackHandler { onBack() }
    val haptics = LocalVoiidHaptics.current
    var muted by remember { mutableStateOf(false) }

    val presence = when {
        conversation.type == ConversationType.GROUP -> "${conversation.memberCount} members"
        conversation.isOnline -> "Online"
        else -> "last seen recently"
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(VoiidColor.background)
            .statusBarsPadding()
            .verticalScroll(rememberScrollState()),
    ) {
        // Back bar
        Box(Modifier.fillMaxWidth().height(44.dp).padding(horizontal = 8.dp), contentAlignment = Alignment.CenterStart) {
            Icon(
                Icons.Default.ChevronLeft, "Back", tint = VoiidColor.textPrimary,
                modifier = Modifier.size(28.dp).clickable { haptics.tap(); onBack() },
            )
        }

        // Avatar + name + presence (centered)
        Column(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            VoiidAvatar(size = 96.dp)
            Spacer(Modifier.height(16.dp))
            Text(conversation.title, style = VoiidFont.rounded(22, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Spacer(Modifier.height(2.dp))
            Text(presence, style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
        }

        Spacer(Modifier.height(32.dp))

        // Settings card
        DetailsCard {
            DetailsRow(
                Icons.Default.NotificationsOff, "Mute notifications",
                trailing = {
                    Switch(
                        checked = muted,
                        onCheckedChange = { muted = it; haptics.selection() },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Color.White,
                            checkedTrackColor = VoiidColor.primary,
                            uncheckedTrackColor = VoiidColor.fieldFill,
                            uncheckedBorderColor = VoiidColor.fieldBorder,
                        ),
                    )
                },
            )
            DetailsDivider()
            DetailsRow(Icons.Default.PermMedia, "Media, links & docs", chevron = true) { haptics.tap() }
            DetailsDivider()
            DetailsRow(Icons.Default.Star, "Starred messages", chevron = true) { haptics.tap() }
            DetailsDivider()
            DetailsRow(Icons.Default.Search, "Search in chat", chevron = true) { haptics.tap() }
        }

        Spacer(Modifier.height(16.dp))

        // Danger card
        DetailsCard {
            DetailsRow(Icons.Default.Block, "Block ${conversation.title}", tint = VoiidColor.error) { haptics.tap() }
            DetailsDivider()
            DetailsRow(Icons.Outlined.ReportGmailerrorred, "Report ${conversation.title}", tint = VoiidColor.error) { haptics.tap() }
        }

        Spacer(Modifier.height(24.dp).navigationBarsPadding())
    }
}

@Composable
private fun DetailsCard(content: @Composable () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard),
    ) { content() }
}

@Composable
private fun DetailsRow(
    icon: ImageVector,
    label: String,
    tint: Color = VoiidColor.textPrimary,
    chevron: Boolean = false,
    trailing: (@Composable () -> Unit)? = null,
    onClick: (() -> Unit)? = null,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable { onClick() } else Modifier)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(22.dp))
        Text(label, style = VoiidFont.rounded(16), color = tint, modifier = Modifier.weight(1f))
        trailing?.invoke()
        if (chevron) Icon(Icons.Default.ChevronRight, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(20.dp))
    }
}

@Composable
private fun DetailsDivider() {
    Box(Modifier.fillMaxWidth().padding(start = 54.dp).height(1.dp).background(VoiidColor.divider.copy(alpha = 0.4f)))
}
