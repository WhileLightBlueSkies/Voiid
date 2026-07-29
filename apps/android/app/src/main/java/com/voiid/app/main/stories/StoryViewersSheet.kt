package com.voiid.app.main.stories

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.RemoveRedEye
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.main.ProfileAvatar
import com.voiid.app.model.StoryViewer
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/**
 * Viewer list for one of YOUR stories. When receipts are OFF (the default), this shows the
 * reciprocity copy instead of names — the opt-out is reciprocal, and the local viewer list is not
 * even read. When ON, it lists who viewed, name-resolved through UserDirectory (never a raw id).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StoryViewersSheet(
    viewers: List<StoryViewer>,
    receiptsEnabled: Boolean,
    deliveredCount: Int,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = VoiidColor.background) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            if (!receiptsEnabled) {
                // Reciprocity copy, verbatim from the spec.
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(Icons.Default.VisibilityOff, null, tint = VoiidColor.textSecondary)
                    Text("Views hidden", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                }
                Text(
                    "If you turn this off, people won't know when you've viewed their moment — and you " +
                        "won't see who viewed yours.",
                    style = VoiidFont.rounded(14), color = VoiidColor.textSecondary,
                )
                if (deliveredCount > 0) {
                    Text(
                        "Delivered to $deliveredCount ${if (deliveredCount == 1) "device" else "devices"}.",
                        style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
                    )
                }
                return@Column
            }

            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(Icons.Default.RemoveRedEye, null, tint = VoiidColor.primary)
                Text(
                    if (viewers.isEmpty()) "No views yet" else "${viewers.size} ${if (viewers.size == 1) "view" else "views"}",
                    style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary,
                )
            }
            Column(
                Modifier.fillMaxWidth().heightIn(max = 420.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                for (v in viewers) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        ProfileAvatar(photoUrl = null, name = v.name, size = 40.dp)
                        Text(v.name, style = VoiidFont.rounded(16), color = VoiidColor.textPrimary)
                        Spacer(Modifier.weight(1f))
                        Text(relativeTime(v.viewedAtMs), style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
                    }
                }
            }
        }
    }
}
