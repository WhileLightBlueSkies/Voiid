package com.voiid.app.main.games

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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.ui.theme.LudoDimens
import com.voiid.app.ui.theme.LudoPalette

/**
 * Player-count picker. You pick how many players sit at the table; every seat that isn't yours
 * is filled by a server-side bot. All opponents and every decision are created by the server.
 */
@Composable
fun LudoServerBotSetup(
    onStart: (players: Int) -> Unit,
    onClose: () -> Unit,
) {
    var players by remember { mutableIntStateOf(4) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(LudoPalette.screenBackground())
            .padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            "Play Ludo",
            fontWeight = FontWeight.Bold,
            fontSize = 22.sp,
            color = LudoPalette.textPrimary(),
        )
        Spacer(Modifier.height(6.dp))
        Text(
            "Pick how many players. Bots fill the rest and play on the server.",
            fontSize = 13.sp,
            color = LudoPalette.textSecondary(),
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(20.dp))

        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            listOf(2, 3, 4).forEach { count ->
                PlayerCountChip(
                    count = count,
                    selected = players == count,
                    onClick = { players = count },
                )
            }
        }

        Spacer(Modifier.height(16.dp))
        // Says the composition plainly so "3 players" is never ambiguous.
        val bots = players - 1
        Text(
            "You + $bots bot${if (bots == 1) "" else "s"}",
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = LudoPalette.textSecondary(),
        )

        Spacer(Modifier.height(20.dp))
        Button(onClick = { onStart(players) }, modifier = Modifier.fillMaxWidth()) {
            Text("Start game")
        }
        Spacer(Modifier.height(12.dp))
        OutlinedButton(onClick = onClose, modifier = Modifier.fillMaxWidth()) { Text("Cancel") }
    }
}

/**
 * One seat-count option. Selection is a filled chip; the count itself is the affordance, so no
 * separate label row is needed.
 */
@Composable
private fun PlayerCountChip(count: Int, selected: Boolean, onClick: () -> Unit) {
    val fill = if (selected) LudoPalette.timerActive() else LudoPalette.podSurface()
    val text = if (selected) Color.White else LudoPalette.textPrimary()
    Box(
        modifier = Modifier
            .size(width = 84.dp, height = 68.dp)
            .clip(RoundedCornerShape(LudoDimens.podCornerRadius))
            .background(fill)
            .clickable(onClick = onClick)
            .semantics { contentDescription = "$count players" },
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text("$count", fontSize = 24.sp, fontWeight = FontWeight.Bold, color = text)
            Text("players", fontSize = 11.sp, fontWeight = FontWeight.Medium, color = text)
        }
    }
}
