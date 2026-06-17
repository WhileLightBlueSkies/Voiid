package com.voiid.app.main

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.R
import com.voiid.app.model.AIStore
import com.voiid.app.model.ChatStore
import com.voiid.app.model.ClipsStore
import com.voiid.app.model.VClip
import com.voiid.app.model.VConversation
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

private enum class Tab(val asset: Int, val label: String) {
    AI(R.drawable.tab_ai, "AI"),
    CHAT(R.drawable.tab_chats, "Chats"),
    CLIPS(R.drawable.tab_clips, "Clips"),
}

/**
 * Main app surface — the custom bottom nav (AI · Chats · Clips) plus the overlays that cover it
 * (chat detail, clip fullscreen). Port of `RootTabView.swift` + iOS navigation behaviour.
 */
@Composable
fun MainScreen(chat: ChatStore, ai: AIStore, clips: ClipsStore) {
    var tab by remember { mutableStateOf(Tab.CHAT) }
    var openConversation by remember { mutableStateOf<VConversation?>(null) }
    var openClip by remember { mutableStateOf<VClip?>(null) }
    var showNewClip by remember { mutableStateOf(false) }
    var activeCall by remember { mutableStateOf<CallRequest?>(null) }

    Box(Modifier.fillMaxSize().background(VoiidColor.background)) {

        Column(Modifier.fillMaxSize().imePadding()) {
            Box(Modifier.fillMaxWidth().weight(1f)) {
                when (tab) {
                    Tab.CHAT -> ChatsHomeView(chat, onOpenConversation = { openConversation = it }, onStartCall = { activeCall = it })
                    Tab.AI -> AIChatView(ai)
                    Tab.CLIPS -> ClipsFeedView(clips, onOpenClip = { openClip = it }, onNewClip = { showNewClip = true })
                }
            }
            TabBar(tab) { tab = it }
        }

        // Chat detail — slides in over everything (covers the tab bar), like the iOS push.
        AnimatedVisibility(
            visible = openConversation != null,
            enter = slideInHorizontally { it } + fadeIn(),
            exit = slideOutHorizontally { it } + fadeOut(),
        ) {
            openConversation?.let { conv ->
                ChatDetailView(
                    conversation = conv, chat = chat,
                    onBack = { openConversation = null },
                    onStartCall = { activeCall = it },
                )
            }
        }

        // Clip fullscreen — full-screen cover.
        AnimatedVisibility(
            visible = openClip != null,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
        ) {
            openClip?.let { clip ->
                ClipFullscreenView(clip = clip, clips = clips, onClose = { openClip = null })
            }
        }

        // Call screen — full-screen cover on top of everything.
        AnimatedVisibility(
            visible = activeCall != null,
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            activeCall?.let { req ->
                CallScreen(request = req, onEnd = { activeCall = null })
            }
        }
    }

    if (showNewClip) {
        NewClipSheet(onDismiss = { showNewClip = false })
    }
}

@Composable
private fun TabBar(selected: Tab, onSelect: (Tab) -> Unit) {
    val haptics = LocalVoiidHaptics.current
    Column(
        Modifier
            .fillMaxWidth()
            .background(VoiidColor.background.copy(alpha = 0.98f))
            .navigationBarsPadding(),
    ) {
        Box(Modifier.fillMaxWidth().height(1.dp).background(VoiidColor.divider.copy(alpha = 0.5f)))
        BoxWithConstraints(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 8.dp, bottom = 4.dp),
        ) {
            val slot = maxWidth / 3
            val pillW = 54.dp
            val activeIndex = selected.ordinal
            val pillX by animateDpAsState(
                targetValue = slot * activeIndex + (slot - pillW) / 2,
                animationSpec = spring(dampingRatio = 0.55f, stiffness = Spring.StiffnessLow),
                label = "tabPillX",
            )
            // Elastic pill indicator
            Box(
                Modifier
                    .offset(x = pillX)
                    .size(width = pillW, height = 40.dp)
                    .clip(RoundedCornerShape(999.dp))
                    .background(VoiidColor.accent.copy(alpha = 0.55f)),
            )
            Row(Modifier.fillMaxWidth()) {
                Tab.entries.forEach { t ->
                    TabItem(t, active = selected == t, modifier = Modifier.weight(1f)) {
                        haptics.selection(); onSelect(t)
                    }
                }
            }
        }
    }
}

@Composable
private fun TabItem(t: Tab, active: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val iconScale by animateFloatAsState(if (active) 1.12f else 1f, spring(dampingRatio = 0.55f), label = "tabIcon")
    Column(
        modifier = modifier.clickable(
            interactionSource = remember { MutableInteractionSource() },
            indication = null,
            onClick = onClick,
        ),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.height(40.dp), contentAlignment = Alignment.Center) {
            Image(
                painter = painterResource(t.asset),
                contentDescription = t.label,
                modifier = Modifier.size(24.dp).scale(iconScale),
                contentScale = ContentScale.Fit,
                colorFilter = ColorFilter.tint(if (active) VoiidColor.primary else VoiidColor.textSecondary),
            )
        }
        Spacer(Modifier.height(6.dp))
        androidx.compose.material3.Text(
            t.label,
            style = VoiidFont.rounded(11, FontWeight.Medium),
            color = if (active) VoiidColor.primary else VoiidColor.textSecondary,
        )
    }
}
