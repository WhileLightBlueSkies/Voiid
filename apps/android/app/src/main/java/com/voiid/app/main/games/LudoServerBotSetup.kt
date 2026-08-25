package com.voiid.app.main.games

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/** Seat-count picker only. All opponents and every decision are created by the server. */
@Composable
fun LudoServerBotSetup(
    onStart: (fourSeats: Boolean) -> Unit,
    onClose: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Play Ludo", fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text("Choose the table size. Bots play on the server.")
        Spacer(Modifier.height(24.dp))
        Button(onClick = { onStart(false) }, modifier = Modifier.fillMaxWidth()) {
            Text("You vs 1 bot")
        }
        Spacer(Modifier.height(12.dp))
        Button(onClick = { onStart(true) }, modifier = Modifier.fillMaxWidth()) {
            Text("You + 3 bots")
        }
        Spacer(Modifier.height(12.dp))
        OutlinedButton(onClick = onClose, modifier = Modifier.fillMaxWidth()) { Text("Cancel") }
    }
}
