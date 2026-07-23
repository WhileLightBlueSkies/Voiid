package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.MapContact
import com.voiid.app.model.VConversation
import com.voiid.app.store.UserDirectory
import com.voiid.app.ui.components.VoiidPrimaryButton
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/**
 * The Map audience picker — the ONLY way to become visible (docs/LOCATION.md §8).
 *
 * SAFETY BY CONSTRUCTION:
 *  - Starts from the CURRENT allow-list (empty on first use). There is no "select all", no
 *    "share with everyone", and no block-list mode — every contact is chosen explicitly.
 *  - Offers only contacts you already have a 1:1 conversation with, because the map_key control
 *    message needs a conversation_id. A "Design Team" group would EXPAND to individuals at
 *    selection time and be stored as individuals, so leaving the group never silently keeps
 *    someone visible — but group expansion is out of this v1 slice (see the report).
 *  - Names always resolve through UserDirectory; a raw user id is never shown.
 *
 * On confirm, an empty selection is a valid choice: it ghosts you (visible to no one).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MapAudienceSheet(
    directConversations: List<VConversation>,
    current: List<MapContact>,
    onConfirm: (List<MapContact>) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    // Candidate contacts = direct conversations with a resolvable peer id.
    val candidates = remember(directConversations) {
        directConversations.mapNotNull { c -> c.peerUserId?.let { MapContact(it, c.id) } }
            .distinctBy { it.userId }
    }
    var selected by remember { mutableStateOf(current.map { it.userId }.toSet()) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = VoiidColor.surfaceCard,
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 28.dp)) {
            Text(
                "Choose who can see you",
                style = VoiidFont.rounded(20, FontWeight.Bold),
                color = VoiidColor.textPrimary,
            )
            Spacer(Modifier.size(4.dp))
            Text(
                "You appear to no one until you pick people here. Each person is added individually — there is no “share with everyone”.",
                style = VoiidFont.rounded(13),
                color = VoiidColor.textSecondary,
            )
            Spacer(Modifier.size(16.dp))

            if (candidates.isEmpty()) {
                Text(
                    "You don’t have any 1:1 chats yet. Start a chat with someone first, then you can let them see you on the Map.",
                    style = VoiidFont.rounded(14),
                    color = VoiidColor.textSecondary,
                    modifier = Modifier.padding(vertical = 24.dp),
                )
            } else {
                LazyColumn(
                    Modifier.fillMaxWidth().heightIn(max = 380.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    items(candidates, key = { it.userId }) { contact ->
                        val name = UserDirectory.displayName(contact.userId)
                        val isSel = selected.contains(contact.userId)
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .clip(androidx.compose.foundation.shape.RoundedCornerShape(12.dp))
                                .clickable {
                                    selected = if (isSel) selected - contact.userId else selected + contact.userId
                                }
                                .padding(vertical = 12.dp, horizontal = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                name,
                                style = VoiidFont.rounded(16, FontWeight.Medium),
                                color = VoiidColor.textPrimary,
                                modifier = Modifier.weight(1f),
                            )
                            Box(
                                Modifier
                                    .size(24.dp)
                                    .clip(CircleShape)
                                    .background(if (isSel) VoiidColor.primary else Color(0x22000000)),
                                contentAlignment = Alignment.Center,
                            ) {
                                if (isSel) Icon(Icons.Default.Check, null, tint = Color.White, modifier = Modifier.size(16.dp))
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.size(20.dp))
            VoiidPrimaryButton(
                title = if (selected.isEmpty()) "Save — visible to no one" else "Save — visible to ${selected.size}",
                modifier = Modifier.fillMaxWidth(),
                onClick = { onConfirm(candidates.filter { selected.contains(it.userId) }) },
            )
        }
    }
}
