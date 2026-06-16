package com.voiid.app.main

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.ChatStore
import com.voiid.app.model.ConversationType
import com.voiid.app.model.VConversation
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidWordmark
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

private enum class ChatTab(val label: String) { CHATS("Chats"), GROUPS("Groups") }

/** Chat home (Figma Screen-6/7) — port of `ChatsHomeView.swift`. */
@Composable
fun ChatsHomeView(chat: ChatStore, onOpenConversation: (VConversation) -> Unit) {
    val haptics = LocalVoiidHaptics.current
    var search by remember { mutableStateOf("") }
    var tab by remember { mutableStateOf(ChatTab.CHATS) }

    val base = if (tab == ChatTab.CHATS) chat.directConversations else chat.groupConversations
    val items = if (search.isBlank()) base.toList() else base.filter { it.title.contains(search, ignoreCase = true) }

    Column(
        Modifier
            .fillMaxSize()
            .background(VoiidColor.background)
            .statusBarsPadding(),
    ) {
        Header(haptics)
        SearchBar(search) { search = it }
        Tabs(tab) { haptics.selection(); tab = it }
        LazyVerticalGrid(
            columns = GridCells.Fixed(3),
            modifier = Modifier.fillMaxWidth().weight(1f),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 24.dp, end = 24.dp, top = 24.dp, bottom = 24.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            items(items, key = { it.id }) { conv ->
                GridCard(conv, Modifier.softClickable(scale = 0.94f) { haptics.tap(); onOpenConversation(conv) })
            }
        }
    }
}

@Composable
private fun Header(haptics: com.voiid.app.ui.components.VoiidHaptics) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("Chats", style = VoiidFont.rounded(28, FontWeight.Bold), color = VoiidColor.textPrimary)
        Spacer(Modifier.weight(1f))
        Icon(
            Icons.Default.Menu, "Menu", tint = VoiidColor.textPrimary,
            modifier = Modifier.size(24.dp).clip(CircleShape).clickable { haptics.tap() },
        )
    }
}

@Composable
private fun SearchBar(search: String, onChange: (String) -> Unit) {
    val shape = RoundedCornerShape(VoiidRadius.pill)
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp)
            .padding(top = 16.dp)
            .height(52.dp)
            .clip(shape)
            .background(VoiidColor.fieldFill)
            .border(1.dp, VoiidColor.fieldBorder, shape)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Default.Search, null, tint = VoiidColor.placeholder, modifier = Modifier.size(20.dp))
        BasicTextField(
            value = search,
            onValueChange = onChange,
            singleLine = true,
            textStyle = VoiidFont.body.merge(TextStyle(color = VoiidColor.textPrimary)),
            cursorBrush = SolidColor(VoiidColor.primary),
            modifier = Modifier.weight(1f),
            decorationBox = { inner ->
                Box(contentAlignment = Alignment.CenterStart) {
                    if (search.isEmpty()) Text("Search", style = VoiidFont.body, color = VoiidColor.placeholder)
                    inner()
                }
            },
        )
    }
}

@Composable
private fun Tabs(selected: ChatTab, onSelect: (ChatTab) -> Unit) {
    BoxWithConstraints(Modifier.fillMaxWidth().padding(top = 24.dp)) {
        val slot = maxWidth / 2
        val underlineX by animateDpAsState(
            targetValue = slot * selected.ordinal,
            animationSpec = spring(dampingRatio = 0.8f, stiffness = Spring.StiffnessMedium),
            label = "underlineX",
        )
        Column {
            Row(Modifier.fillMaxWidth()) {
                ChatTab.entries.forEach { t ->
                    Box(
                        Modifier
                            .weight(1f)
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                            ) { onSelect(t) }
                            .padding(bottom = 8.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            t.label,
                            style = VoiidFont.rounded(17, FontWeight.SemiBold),
                            color = if (selected == t) VoiidColor.primary else VoiidColor.textSecondary,
                        )
                    }
                }
            }
            // baseline divider
            Box(Modifier.fillMaxWidth().height(1.dp).background(VoiidColor.divider.copy(alpha = 0.5f)))
        }
        // animated gradient underline
        Box(
            Modifier
                .offset(x = underlineX)
                .padding(bottom = 0.dp)
                .align(Alignment.BottomStart)
                .size(width = slot, height = 3.dp)
                .background(Brush.horizontalGradient(listOf(VoiidColor.primary, VoiidColor.accent))),
        )
    }
}

@Composable
private fun GridCard(conv: VConversation, modifier: Modifier) {
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.fillMaxWidth().aspectRatio(1f)) {
            Box(
                Modifier
                    .fillMaxSize()
                    .clip(RoundedCornerShape(VoiidRadius.lg))
                    .background(VoiidColor.fieldFill),
                contentAlignment = Alignment.Center,
            ) {
                VoiidWordmark(fontSize = 28, alpha = 0.22f)
            }
            if (conv.isOnline) {
                Box(
                    Modifier
                        .align(Alignment.TopEnd)
                        .offset(x = (-6).dp, y = 6.dp)
                        .size(13.dp)
                        .clip(CircleShape)
                        .background(VoiidColor.background)
                        .padding(2.dp)
                        .clip(CircleShape)
                        .background(VoiidColor.success),
                )
            }
            if (conv.unreadCount > 0) {
                Box(
                    Modifier
                        .align(Alignment.TopEnd)
                        .offset(x = 6.dp, y = (-6).dp)
                        .size(20.dp)
                        .clip(CircleShape)
                        .background(VoiidColor.error),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("${conv.unreadCount}", style = VoiidFont.rounded(11, FontWeight.Bold), color = androidx.compose.ui.graphics.Color.White)
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        Text(conv.title, style = VoiidFont.rounded(14), color = VoiidColor.textPrimary, maxLines = 1)
    }
}
