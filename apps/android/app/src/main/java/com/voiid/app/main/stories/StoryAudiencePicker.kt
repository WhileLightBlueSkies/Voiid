package com.voiid.app.main.stories

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.main.ProfileAvatar
import com.voiid.app.model.StoriesStore
import com.voiid.app.ui.components.VoiidPrimaryButton
import com.voiid.app.ui.components.noRippleClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/**
 * Audience picker. Opens pre-selected with EVERYONE you can reach — the one audience model in v1
 * is a flat list of recipient user ids, chosen per story (no named lists, no block-lists). The
 * label reads "My Contacts (N)" until you deselect anyone, then "Custom (N)".
 *
 * THE HONEST NOTE (spec §2.3) is shown here and must not be softened: Voiid can't read your story,
 * but it does see who you send it to — the fan-out is addressed to real device ids and there is no
 * sealed sender to hide that.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StoryAudiencePicker(
    candidates: List<StoriesStore.AudienceEntry>,
    initialSelection: Set<String>,
    onConfirm: (Set<String>) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val selected = remember { mutableStateMapOf<String, Boolean>().apply { candidates.forEach { put(it.userId, it.userId in initialSelection) } } }
    val chosen = selected.filterValues { it }.keys
    val isAll = candidates.isNotEmpty() && chosen.size == candidates.size
    val label = if (isAll) "My Contacts (${chosen.size})" else "Custom (${chosen.size})"

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = VoiidColor.background) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Send to", style = VoiidFont.rounded(20, FontWeight.Bold), color = VoiidColor.textPrimary)
            Text(label, style = VoiidFont.rounded(14, FontWeight.SemiBold), color = VoiidColor.primary)

            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Default.Lock, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(14.dp))
                Text(
                    "Voiid can't read your moment, but it does see who you send it to.",
                    style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
                )
            }

            if (candidates.isEmpty()) {
                Text(
                    "No contacts yet. Start a chat with someone and they'll appear here.",
                    style = VoiidFont.rounded(14), color = VoiidColor.textSecondary,
                )
            }

            Column(
                Modifier.fillMaxWidth().heightIn(max = 380.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                for (c in candidates) {
                    val on = selected[c.userId] == true
                    Row(
                        Modifier.fillMaxWidth()
                            .noRippleClickable { selected[c.userId] = !on }
                            .padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        ProfileAvatar(photoUrl = c.photoUrl, name = c.name, size = 40.dp)
                        Text(c.name, style = VoiidFont.rounded(16), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
                        Box(
                            Modifier.size(24.dp).clip(CircleShape)
                                .noRippleClickable { selected[c.userId] = !on },
                            contentAlignment = Alignment.Center,
                        ) {
                            if (on) {
                                Box(Modifier.size(24.dp).clip(CircleShape).padding(1.dp), contentAlignment = Alignment.Center) {
                                    Icon(Icons.Default.Check, null, tint = VoiidColor.primary)
                                }
                            } else {
                                Box(Modifier.size(20.dp).clip(CircleShape).padding(1.dp)) {
                                    Icon(Icons.Default.Check, null, tint = Color.Transparent)
                                }
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.size(4.dp))
            VoiidPrimaryButton(title = "Done", enabled = chosen.isNotEmpty()) { onConfirm(chosen) }
        }
    }
}
