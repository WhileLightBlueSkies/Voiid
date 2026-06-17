package com.voiid.app.main

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import com.voiid.app.model.ClipsStore
import com.voiid.app.model.VClip
import com.voiid.app.model.VClipComment
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/** Instagram-Reels-style fullscreen player with inline shrink-to-comments (iOS `ClipFullscreenView`). */
@Composable
fun ClipFullscreenView(clip: VClip, clips: ClipsStore, onClose: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    var liked by remember { mutableStateOf(false) }
    var showComments by remember { mutableStateOf(false) }
    var commentDraft by remember { mutableStateOf("") }

    BackHandler { if (showComments) showComments = false else onClose() }

    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black)) {
        val totalH = maxHeight
        val reelFraction by animateFloatAsState(
            targetValue = if (showComments) 0.42f else 1f,
            animationSpec = spring(dampingRatio = 0.85f, stiffness = Spring.StiffnessLow),
            label = "reelHeight",
        )
        Column(Modifier.fillMaxSize()) {
            // Reel — full height normally; shrinks to a top box when comments open.
            Box(Modifier.fillMaxWidth().height(totalH * reelFraction)) {
                Box(
                    Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(VoiidColor.primary, Color.Black))),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Default.PlayCircle, null, tint = Color.White.copy(alpha = 0.85f), modifier = Modifier.size(64.dp))
                }
                // top bar
                Row(Modifier.fillMaxWidth().statusBarsPadding().padding(16.dp)) {
                    Icon(
                        if (showComments) Icons.Default.KeyboardArrowDown else Icons.Default.ChevronLeft, "Back",
                        tint = Color.White,
                        modifier = Modifier.size(28.dp).clickable { if (showComments) showComments = false else onClose() },
                    )
                }
                // bottom author + caption + actions (hidden when comments open)
                if (!showComments) {
                    Row(
                        Modifier.fillMaxWidth().align(Alignment.BottomStart).navigationBarsPadding().padding(16.dp),
                        verticalAlignment = Alignment.Bottom,
                    ) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                VoiidAvatar(size = 44.dp, modifier = Modifier.clip(CircleShape))
                                Text(clip.authorName, style = VoiidFont.rounded(15, FontWeight.SemiBold), color = Color.White)
                            }
                            Text(clip.heading, style = VoiidFont.rounded(14), color = Color.White)
                            Text(
                                clip.caption, style = VoiidFont.rounded(12), color = Color.White.copy(alpha = 0.85f),
                                textDecoration = TextDecoration.Underline,
                                modifier = Modifier.clickable { haptics.tap(); showComments = true },
                            )
                        }
                        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(24.dp)) {
                            ClipAction(
                                icon = if (liked) Icons.Default.Favorite else Icons.Outlined.FavoriteBorder,
                                label = "${clip.likes + if (liked) 1 else 0}",
                                tint = if (liked) VoiidColor.error else Color.White,
                            ) { haptics.tap(); liked = !liked; if (liked) clips.toggleLike(clip) }
                            ClipAction(Icons.AutoMirrored.Outlined.Chat, "${clip.comments}", Color.White) { haptics.tap(); showComments = true }
                            ClipAction(Icons.AutoMirrored.Filled.Send, "Share", Color.White) {}
                        }
                    }
                }
            }

            // Comments panel slides up below the shrunken reel.
            AnimatedVisibility(visible = showComments) {
                CommentsPanel(
                    clips = clips,
                    draft = commentDraft,
                    onDraftChange = { commentDraft = it },
                    onClose = { showComments = false },
                    onSend = {
                        val t = commentDraft.trim()
                        if (t.isNotEmpty()) { haptics.tap(); clips.addComment(t); commentDraft = "" }
                    },
                    modifier = Modifier.fillMaxWidth().height(totalH * 0.58f),
                )
            }
        }
    }
}

@Composable
private fun CommentsPanel(
    clips: ClipsStore,
    draft: String,
    onDraftChange: (String) -> Unit,
    onClose: () -> Unit,
    onSend: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier.clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp)).background(VoiidColor.background),
    ) {
        Box(
            Modifier.fillMaxWidth().padding(vertical = 8.dp), contentAlignment = Alignment.Center,
        ) { Box(Modifier.width(40.dp).height(4.dp).clip(CircleShape).background(VoiidColor.divider)) }
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("${clips.comments.size} comments", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Spacer(Modifier.weight(1f))
            Icon(Icons.Default.Close, "Close", tint = VoiidColor.textSecondary, modifier = Modifier.size(20.dp).clickable { onClose() })
        }
        HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.5f))

        LazyColumn(Modifier.fillMaxWidth().weight(1f), contentPadding = androidx.compose.foundation.layout.PaddingValues(24.dp)) {
            items(clips.comments, key = { it.id }) { c -> CommentRow(c) }
        }

        HorizontalDivider(color = VoiidColor.divider.copy(alpha = 0.5f))
        Row(
            Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                Modifier.weight(1f).height(44.dp).clip(CircleShape).background(VoiidColor.fieldFill).padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                    if (draft.isEmpty()) Text("Add a comment…", style = VoiidFont.rounded(15), color = VoiidColor.placeholder)
                    BasicTextField(
                        value = draft, onValueChange = onDraftChange, singleLine = true,
                        textStyle = VoiidFont.rounded(15).merge(TextStyle(color = VoiidColor.textPrimary)),
                        cursorBrush = SolidColor(VoiidColor.primary), modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
            Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = VoiidColor.primary, modifier = Modifier.size(22.dp).clickable { onSend() })
        }
    }
}

@Composable
private fun CommentRow(c: VClipComment) {
    Row(
        Modifier.fillMaxWidth().padding(bottom = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        VoiidAvatar(size = 32.dp, modifier = Modifier.clip(CircleShape))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(c.authorName, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Text(c.text, style = VoiidFont.rounded(14), color = VoiidColor.textPrimary)
        }
        Icon(Icons.Outlined.FavoriteBorder, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(13.dp))
    }
}

@Composable
private fun ClipAction(icon: ImageVector, label: String, tint: Color, onClick: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier.clickable(
            interactionSource = remember { MutableInteractionSource() }, indication = null,
        ) { onClick() },
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(28.dp))
        Text(label, style = VoiidFont.caption, color = Color.White)
    }
}
