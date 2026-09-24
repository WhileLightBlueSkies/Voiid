package com.voiid.app.main.games.ludo

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.components.VoiidDetent
import com.voiid.app.ui.components.VoiidSheet
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

enum class LudoChatMode { DUEL_HUMAN, DUEL_BOT, FOUR }

/** Compact chat entry. Human candidates are still re-authorized by the API. */
@Composable
fun LudoChatSetupDialog(
    hasHumanPeer: Boolean,
    onStart: (LudoChatMode, String) -> Unit,
    onDismiss: () -> Unit,
) {
    var difficulty by remember { mutableStateOf("balanced") }
    var visible by remember { mutableStateOf(true) }
    VoiidSheet(
        visible = visible,
        onDismiss = onDismiss,
        detents = listOf(VoiidDetent.Content),
        showHandle = true,
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
            Text("Ludo", style = VoiidFont.title, color = VoiidColor.textPrimary)
            Spacer(Modifier.height(12.dp))
            Text("Bot difficulty", style = VoiidFont.body, color = VoiidColor.textSecondary)
            TextButton(onClick = { difficulty = "relaxed" }) { Text(if (difficulty == "relaxed") "✓ Relaxed" else "Relaxed") }
            TextButton(onClick = { difficulty = "balanced" }) { Text(if (difficulty == "balanced") "✓ Balanced" else "Balanced") }
            TextButton(onClick = { difficulty = "sharp" }) { Text(if (difficulty == "sharp") "✓ Sharp" else "Sharp") }
            if (hasHumanPeer) TextButton(onClick = { onStart(LudoChatMode.DUEL_HUMAN, difficulty) }) { Text("1 vs 1") }
            TextButton(onClick = { onStart(LudoChatMode.DUEL_BOT, difficulty) }) { Text("1 vs bot") }
            TextButton(onClick = { onStart(LudoChatMode.FOUR, difficulty) }) { Text("4 players · fill with bots") }
            TextButton(onClick = { visible = false }) { Text("Cancel") }
            Spacer(Modifier.height(8.dp))
        }
    }
}
