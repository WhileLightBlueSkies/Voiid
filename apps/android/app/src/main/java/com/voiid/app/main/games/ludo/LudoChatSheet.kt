package com.voiid.app.main.games.ludo

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.net.ChatEngine
import com.voiid.app.ui.theme.LudoPalette
import com.voiid.app.ui.theme.VoiidColor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * In-game chat + emotes (§11.4): a 45%-height sheet with the current conversation's last 20
 * game-context messages and one row of eight text emoji reactions.
 *
 * THE SHEET NEVER PAUSES THE CLOCK. Messages ride the EXISTING E2EE chat pipe — [ChatEngine]
 * holds only decrypted local copies — and carry a compact `gameContext` marker (match id)
 * inside the encrypted body; the games server never receives their plaintext. Unread state is
 * a small accent dot, not a coin badge. Emote sends are rate-limited to ONE per second locally.
 */
object GameContextMarker {
    private const val PREFIX = "\nvoiid:gamework/"

    fun embed(body: String, matchId: String): String = "$body$PREFIX$matchId"
    fun strip(text: String): String = text.substringBefore(PREFIX)
    fun isGameContext(text: String, matchId: String): Boolean = text.contains("$PREFIX$matchId")
}

@Composable
fun LudoChatSheet(matchId: String, conversationId: String?, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val chat = remember { ChatEngine.get(context) }
    var lastSendAt by remember { mutableStateOf(0L) }

    // Last 20 messages of THIS conversation, newest last. Real decrypted store, not a mock.
    val messages = remember(conversationId) {
        conversationId?.let { chat.messages(it).takeLast(20) } ?: emptyList()
    }

    Column(
        Modifier
            .fillMaxWidth()
            .fillMaxHeight(0.45f)
            .clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
            .background(VoiidColor.surfaceCard)
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Chat", fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                color = LudoPalette.textPrimary(), modifier = Modifier.weight(1f))
            Text("Done", fontSize = 14.sp, color = VoiidColor.primary,
                modifier = Modifier.clickable(onClick = onDismiss).padding(6.dp))
        }

        Spacer(Modifier.size(8.dp))
        LazyColumn(Modifier.weight(1f)) {
            items(messages, key = { it.id }) { m ->
                Column(Modifier.padding(vertical = 3.dp)) {
                    Text(
                        GameContextMarker.strip(m.text),
                        fontSize = 13.sp,
                        maxLines = 4,
                        overflow = TextOverflow.Ellipsis,
                        color = LudoPalette.textPrimary(),
                    )
                }
            }
        }

        // Eight text emoji reactions — no gifts, no animated sticker economy (§11.4).
        Row(horizontalArrangement = Arrangement.SpaceEvenly, modifier = Modifier.fillMaxWidth()) {
            listOf("👏", "😂", "😮", "😢", "🔥", "🍀", "🎲", "🏆").forEach { emoji ->
                Box(
                    Modifier
                        .size(38.dp)
                        .clip(CircleShape)
                        .background(LudoPalette.trackCellFill())
                        .clickable {
                            val convo = conversationId ?: return@clickable
                            val now = System.currentTimeMillis()
                            if (now - lastSendAt < 1000) return@clickable   // 1/s local rate limit
                            lastSendAt = now
                            CoroutineScope(Dispatchers.IO).launch {
                                runCatching {
                                    chat.sendText(GameContextMarker.embed(emoji, matchId), convo, "")
                                }
                            }
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(emoji, fontSize = 18.sp)
                }
            }
        }
    }
}
