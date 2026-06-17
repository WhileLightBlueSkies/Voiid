package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.bouncyClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/** Full emoji picker with search + categories (iOS `EmojiPickerSheet`). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EmojiPickerSheet(onPick: (String) -> Unit, onDismiss: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var query by remember { mutableStateOf("") }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = VoiidColor.background, dragHandle = null) {
        Column(Modifier.fillMaxHeight(0.9f)) {
            Text(
                "Choose emoji", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary,
                modifier = Modifier.align(Alignment.CenterHorizontally).padding(top = 16.dp, bottom = 8.dp),
            )
            // search
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 24.dp)
                    .height(44.dp)
                    .clip(CircleShape)
                    .background(VoiidColor.fieldFill)
                    .padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(Icons.Default.Search, null, tint = VoiidColor.placeholder, modifier = Modifier.size(20.dp))
                Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                    if (query.isEmpty()) Text("Search emoji", style = VoiidFont.rounded(16), color = VoiidColor.placeholder)
                    BasicTextField(
                        value = query, onValueChange = { query = it }, singleLine = true,
                        textStyle = VoiidFont.rounded(16).merge(TextStyle(color = VoiidColor.textPrimary)),
                        cursorBrush = SolidColor(VoiidColor.primary), modifier = Modifier.fillMaxWidth(),
                    )
                }
            }

            LazyVerticalGrid(
                columns = GridCells.Fixed(8),
                modifier = Modifier.fillMaxWidth().weight(1f).padding(horizontal = 16.dp, vertical = 12.dp),
            ) {
                EmojiData.categories.forEach { cat ->
                    val items = EmojiData.filtered(cat, query)
                    if (items.isNotEmpty()) {
                        item(span = { GridItemSpan(maxLineSpan) }) {
                            Text(
                                cat.name, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textSecondary,
                                modifier = Modifier.fillMaxWidth().background(VoiidColor.background).padding(vertical = 4.dp),
                            )
                        }
                        items.forEach { e ->
                            item(key = "${cat.name}-$e") {
                                Box(
                                    Modifier.size(40.dp).bouncyClickable { haptics.tap(); onPick(e); onDismiss() },
                                    contentAlignment = Alignment.Center,
                                ) { Text(e, fontSize = 28.sp) }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Curated emoji dataset (Android can't introspect emoji names, so categories are hand-listed). */
object EmojiData {
    data class Category(val name: String, val emojis: List<String>)

    val categories: List<Category> = listOf(
        Category("Smileys & People", listOf(
            "😀","😃","😄","😁","😆","😅","😂","🤣","😊","😇","🙂","🙃","😉","😌","😍","🥰","😘","😗","😙","😚",
            "😋","😛","😝","😜","🤪","🤨","🧐","🤓","😎","🥳","🤩","😏","😒","😞","😔","😟","😕","🙁","😣","😖",
            "😫","😩","🥺","😢","😭","😤","😠","😡","🤬","🤯","😳","🥵","🥶","😱","😨","😰","😥","😓","🤗","🤔",
            "🤭","🤫","🤥","😶","😐","😑","😬","🙄","😯","😦","😧","😮","😲","🥱","😴","🤤","😪","😵","🤐","🥴",
            "🤢","🤮","🤧","😷","🤒","🤕","🤑","🤠","😈","👿","👻","💀","👽","🤖","🎃","😺","😸","😹","😻","😼",
        )),
        Category("Gestures & Body", listOf(
            "👋","🤚","🖐️","✋","🖖","👌","🤌","🤏","✌️","🤞","🤟","🤘","🤙","👈","👉","👆","🖕","👇","👍","👎",
            "✊","👊","🤛","🤜","👏","🙌","👐","🤲","🤝","🙏","💪","🦾","✍️","💅","🤳","👀","👁️","👅","👄","🧠",
        )),
        Category("Animals & Nature", listOf(
            "🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐨","🐯","🦁","🐮","🐷","🐸","🐵","🐔","🐧","🐦","🐤","🦆",
            "🦅","🦉","🐺","🐗","🐴","🦄","🐝","🐛","🦋","🐌","🐞","🐢","🐍","🐙","🦑","🦀","🐠","🐟","🐬","🐳",
            "🌱","🌳","🌴","🌵","🌷","🌹","🌺","🌸","🌼","🌻","🍁","🍂","🍃","⭐","🌟","✨","⚡","🔥","🌈","☀️",
        )),
        Category("Food & Drink", listOf(
            "🍏","🍎","🍐","🍊","🍋","🍌","🍉","🍇","🍓","🫐","🍒","🍑","🥭","🍍","🥥","🥝","🍅","🍆","🥑","🥦",
            "🌽","🥕","🍞","🥐","🧀","🥚","🍳","🥞","🍔","🍟","🍕","🌭","🌮","🌯","🍜","🍣","🍦","🍩","🍪","🎂",
            "🍰","🧁","🍫","🍬","🍭","☕","🍵","🍺","🍻","🍷","🍸","🍹","🥤","🧃",
        )),
        Category("Activities & Sports", listOf(
            "⚽","🏀","🏈","⚾","🎾","🏐","🏉","🎱","🏓","🏸","🥅","🏒","🏑","🏏","⛳","🏹","🎣","🥊","🥋","🎽",
            "⛸️","🎿","🛷","🥌","🎯","🎮","🕹️","🎲","🎰","🎳","🎭","🎨","🎬","🎤","🎧","🎼","🎵","🎸","🎹","🥁",
        )),
        Category("Travel & Places", listOf(
            "🚗","🚕","🚙","🚌","🚎","🏎️","🚓","🚑","🚒","🚐","🚚","🚛","🛵","🏍️","🚲","✈️","🚀","🛸","🚁","⛵",
            "🚤","🛳️","⛴️","🚢","🗺️","🗽","🗼","🏰","🏯","🎡","🎢","🎠","⛲","🏖️","🏝️","🏔️","🗻","🏕️","🏠","🏡",
        )),
        Category("Objects", listOf(
            "💡","🔦","🕯️","📱","💻","⌨️","🖥️","🖨️","📷","📸","📹","🎥","📞","☎️","📺","📻","⏰","⌚","💰","💵",
            "💳","💎","🔑","🔒","🔓","🔨","🪛","🔧","⚙️","🧰","🧲","🔋","🔌","📦","📬","📚","📖","✏️","📌","🎁",
        )),
        Category("Symbols", listOf(
            "❤️","🧡","💛","💚","💙","💜","🖤","🤍","🤎","💔","❣️","💕","💞","💓","💗","💖","💘","💝","💯","✅",
            "❌","⭕","❗","❓","💢","💤","🔔","🔕","🎵","🎶","➕","➖","✖️","♻️","✔️","🆗","🆕","🔝","🔆","⚠️",
        )),
    )

    /** Curated keyword search for common emojis. */
    private val keywords: Map<String, List<String>> = mapOf(
        "😀" to listOf("smile", "happy"), "😂" to listOf("laugh", "lol", "funny"), "🤣" to listOf("rofl", "laugh"),
        "😊" to listOf("smile", "blush"), "😍" to listOf("love", "heart eyes"), "😘" to listOf("kiss"),
        "😎" to listOf("cool", "sunglasses"), "🤔" to listOf("think"), "😢" to listOf("sad", "cry"), "😭" to listOf("cry", "sob"),
        "😡" to listOf("angry", "mad"), "🥳" to listOf("party", "celebrate"), "😴" to listOf("sleep", "tired"),
        "👍" to listOf("thumbs up", "like", "yes", "ok"), "👎" to listOf("thumbs down", "dislike", "no"),
        "👏" to listOf("clap", "applause"), "🙏" to listOf("pray", "thanks", "please"), "🙌" to listOf("celebrate", "praise"),
        "💪" to listOf("strong", "muscle"), "👋" to listOf("wave", "hi", "bye"), "✌️" to listOf("peace"), "🤝" to listOf("handshake", "deal"),
        "❤️" to listOf("heart", "love", "red"), "🔥" to listOf("fire", "lit", "hot"), "✨" to listOf("sparkle", "stars"),
        "⭐" to listOf("star"), "🎉" to listOf("party", "celebrate", "tada"), "🐶" to listOf("dog", "puppy"), "🐱" to listOf("cat"),
        "🍕" to listOf("pizza", "food"), "🍔" to listOf("burger", "food"), "☕" to listOf("coffee"), "🍺" to listOf("beer"),
        "⚽" to listOf("football", "soccer"), "🏀" to listOf("basketball"), "🎮" to listOf("game", "gaming"), "🎵" to listOf("music", "note"),
        "🚗" to listOf("car"), "✈️" to listOf("plane", "flight", "travel"), "🚀" to listOf("rocket", "launch"), "🏠" to listOf("home", "house"),
        "📱" to listOf("phone", "mobile"), "💻" to listOf("laptop", "computer"), "💰" to listOf("money", "cash"), "🎁" to listOf("gift", "present"),
    )

    fun filtered(cat: Category, query: String): List<String> {
        if (query.isBlank()) return cat.emojis
        val q = query.lowercase()
        return cat.emojis.filter { e ->
            cat.name.lowercase().contains(q) || (keywords[e]?.any { it.contains(q) } ?: false)
        }
    }
}
