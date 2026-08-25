package com.voiid.app.main.games.ludo

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue

enum class LudoChatMode { DUEL_HUMAN, DUEL_BOT, FOUR }

/** Compact chat entry. Human candidates are still re-authorized by the API. */
@Composable
fun LudoChatSetupDialog(
    hasHumanPeer: Boolean,
    onStart: (LudoChatMode, String) -> Unit,
    onDismiss: () -> Unit,
) {
    var difficulty by remember { mutableStateOf("balanced") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Ludo") },
        text = {
            Column {
                Text("Bot difficulty")
                TextButton(onClick = { difficulty = "relaxed" }) { Text(if (difficulty == "relaxed") "✓ Relaxed" else "Relaxed") }
                TextButton(onClick = { difficulty = "balanced" }) { Text(if (difficulty == "balanced") "✓ Balanced" else "Balanced") }
                TextButton(onClick = { difficulty = "sharp" }) { Text(if (difficulty == "sharp") "✓ Sharp" else "Sharp") }
                if (hasHumanPeer) TextButton(onClick = { onStart(LudoChatMode.DUEL_HUMAN, difficulty) }) { Text("1 vs 1") }
                TextButton(onClick = { onStart(LudoChatMode.DUEL_BOT, difficulty) }) { Text("1 vs bot") }
                TextButton(onClick = { onStart(LudoChatMode.FOUR, difficulty) }) { Text("4 players · fill with bots") }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
