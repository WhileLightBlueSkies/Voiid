package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowCircleUp
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import com.voiid.app.model.AIStore
import com.voiid.app.model.VAIMessage
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/** In-app AI assistant (Figma Screen-8) — port of `AIChatView.swift`. */
@Composable
fun AIChatView(ai: AIStore) {
    val haptics = LocalVoiidHaptics.current
    var draft by remember { mutableStateOf("") }
    val listState = rememberLazyListState()

    LaunchedEffect(ai.messages.size, ai.thinking) {
        val count = ai.messages.size + if (ai.thinking) 1 else 0
        if (count > 0) listState.animateScrollToItem(count - 1)
    }

    Column(Modifier.fillMaxSize().background(VoiidColor.background)) {
        // Header
        Row(
            Modifier
                .fillMaxWidth()
                .background(VoiidColor.background)
                .statusBarsPadding()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Default.AutoAwesome, null, tint = VoiidColor.primary, modifier = Modifier.size(20.dp))
            Text("Voiid AI", style = VoiidFont.headline, color = VoiidColor.textPrimary)
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(VoiidColor.divider.copy(alpha = 0.5f)))

        // Messages
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxWidth().weight(1f),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(ai.messages, key = { it.id }) { m -> AiBubble(m) }
            if (ai.thinking) item(key = "thinking") { TypingBubble() }
        }

        // Input bar
        Box(Modifier.fillMaxWidth().height(1.dp).background(VoiidColor.divider.copy(alpha = 0.5f)))
        Row(
            Modifier
                .fillMaxWidth()
                .background(VoiidColor.background)
                .padding(horizontal = 8.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            val fieldShape = RoundedCornerShape(VoiidRadius.pill)
            Box(
                Modifier
                    .weight(1f)
                    .heightIn(min = 44.dp)
                    .clip(fieldShape)
                    .background(VoiidColor.fieldFill)
                    .border(1.dp, VoiidColor.fieldBorder, fieldShape)
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                contentAlignment = Alignment.CenterStart,
            ) {
                if (draft.isEmpty()) Text("Ask Voiid AI…", style = VoiidFont.body, color = VoiidColor.placeholder)
                BasicTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    textStyle = VoiidFont.body.merge(TextStyle(color = VoiidColor.textPrimary)),
                    cursorBrush = SolidColor(VoiidColor.primary),
                    maxLines = 4,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            Icon(
                Icons.Default.ArrowCircleUp, "Send", tint = VoiidColor.primary,
                modifier = Modifier.size(32.dp).clickable {
                    val t = draft.trim()
                    if (t.isNotEmpty()) { haptics.tap(); ai.send(t); draft = "" }
                },
            )
        }
    }
}

@Composable
private fun AiBubble(m: VAIMessage) {
    Row(Modifier.fillMaxWidth()) {
        if (m.isUser) Spacer(Modifier.weight(1f))
        Text(
            m.text,
            style = VoiidFont.body,
            color = VoiidColor.textPrimary,
            modifier = Modifier
                .widthIn(max = 300.dp)
                .clip(bubbleShape(m.isUser))
                .background(if (m.isUser) VoiidColor.bubbleSent else VoiidColor.bubbleReceived)
                .padding(horizontal = 16.dp, vertical = 8.dp),
        )
        if (!m.isUser) Spacer(Modifier.weight(1f))
    }
}
