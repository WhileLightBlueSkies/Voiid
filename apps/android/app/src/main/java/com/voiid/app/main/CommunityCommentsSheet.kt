package com.voiid.app.main

import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.net.ApiError
import com.voiid.app.net.CommunityService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidDetent
import com.voiid.app.ui.components.VoiidMenu
import com.voiid.app.ui.components.VoiidMenuItem
import com.voiid.app.ui.components.VoiidSheet
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.launch

/**
 * Port of iOS `CommunityCommentsSheet`: the thread under a Home post and a reply box.
 * Medium/large sheet; title counts the comments; your own comment can be deleted (long
 * press, as iOS's context menu), any comment copied; the post's count is reported back.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun CommunityCommentsSheet(
    service: CommunityService,
    communityId: String,
    post: CommunityService.Post,
    onCountChange: (Int) -> Unit,
    onDismiss: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current
    var comments by remember { mutableStateOf<List<CommunityService.PostComment>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var loadError by remember { mutableStateOf<String?>(null) }
    var draft by remember { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var sendError by remember { mutableStateOf<String?>(null) }
    var menuFor by remember { mutableStateOf<String?>(null) }
    val listState = rememberLazyListState()

    suspend fun load() {
        loading = true
        runCatching { service.postComments(communityId, post.id) }
            .onSuccess { comments = it; loadError = null }
            .onFailure { loadError = "Couldn't load comments." }
        loading = false
    }
    LaunchedEffect(post.id) { load() }
    LaunchedEffect(comments.size) { if (comments.isNotEmpty()) listState.animateScrollToItem(comments.lastIndex) }

    fun delete(c: CommunityService.PostComment) = scope.launch {
        runCatching { service.deletePostComment(communityId, post.id, c.id) }
            .onSuccess { count -> comments = comments.filterNot { it.id == c.id }; onCountChange(count) }
            .onFailure { sendError = "Couldn't delete that comment." }
    }

    VoiidSheet(
        visible = true, onDismiss = onDismiss,
        // Opened at LARGE: VoiidSheet lays its content out at the large height and slides it
        // down for Medium, so at Medium the reply box sat below the screen edge.
        detents = listOf(VoiidDetent.Large), showHandle = true,
    ) {
        Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
            Text(if (comments.isEmpty()) "Comments" else "${comments.size} comments",
                style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary,
                modifier = Modifier.align(Alignment.Center))
            TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.CenterStart)) {
                Text("Done", style = VoiidFont.rounded(16), color = VoiidColor.primary)
            }
        }
        Box(Modifier.fillMaxWidth().weight(1f)) {
            when {
                loading && comments.isEmpty() -> CircularProgressIndicator(
                    color = VoiidColor.primary, modifier = Modifier.align(Alignment.Center).size(24.dp), strokeWidth = 2.dp)
                loadError != null && comments.isEmpty() -> Column(Modifier.align(Alignment.Center),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(loadError ?: "", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
                    TextButton(onClick = { scope.launch { load() } }) { Text("Try again", color = VoiidColor.primary) }
                }
                comments.isEmpty() -> Column(Modifier.align(Alignment.Center),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Icon(Icons.Outlined.Forum, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(28.dp))
                    Text("No comments yet", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                    Text("Start the conversation.", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
                }
                else -> LazyColumn(state = listState, modifier = Modifier.fillMaxSize(),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 8.dp)) {
                    items(comments, key = { it.id }) { c ->
                        Box {
                            Row(
                                Modifier.fillMaxWidth().combinedClickable(onClick = {}, onLongClick = {
                                    haptics.rigid(); menuFor = c.id
                                }).padding(vertical = 8.dp),
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                CommunityAvatar(c.displayName, size = 32.dp)
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                                        Text(c.displayName, style = VoiidFont.rounded(13.5f, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                                        c.created_at?.let {
                                            Text(CommunityFeedDate.age(it), style = VoiidFont.rounded(11.5f), color = VoiidColor.textSecondary)
                                        }
                                    }
                                    Text(c.text, style = VoiidFont.rounded(14.5f), color = VoiidColor.textPrimary)
                                }
                            }
                            VoiidMenu(expanded = menuFor == c.id, onDismissRequest = { menuFor = null }) {
                                VoiidMenuItem("Copy", androidx.compose.material.icons.Icons.Outlined.ContentCopy) {
                                    menuFor = null; clipboard.setText(AnnotatedString(c.text))
                                }
                                if (c.mine == true) VoiidMenuItem("Delete", androidx.compose.material.icons.Icons.Outlined.Delete, destructive = true) {
                                    menuFor = null; delete(c)
                                }
                            }
                        }
                    }
                }
            }
        }
        // Reply box: 20-radius field + 40 send disc, disabled until there is text (max 1000).
        Column(Modifier.fillMaxWidth().background(VoiidColor.surfaceCard).imePadding()
            .padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            sendError?.let { Text(it, style = VoiidFont.rounded(12), color = VoiidColor.error) }
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                BasicTextField(
                    value = draft, onValueChange = { draft = it.take(1000) }, maxLines = 5,
                    textStyle = VoiidFont.rounded(15).merge(TextStyle(color = VoiidColor.textPrimary)),
                    cursorBrush = SolidColor(VoiidColor.primary),
                    modifier = Modifier.weight(1f).heightIn(min = 40.dp).clip(RoundedCornerShape(20.dp))
                        .background(VoiidColor.fieldFill).padding(horizontal = 14.dp, vertical = 10.dp),
                    decorationBox = { inner ->
                        Box { if (draft.isEmpty()) Text("Add a comment…", style = VoiidFont.rounded(15), color = VoiidColor.placeholder); inner() }
                    },
                )
                val canSend = draft.isNotBlank() && !sending
                Box(
                    Modifier.size(40.dp).clip(CircleShape).background(if (canSend) VoiidColor.accent else VoiidColor.fieldFill)
                        .softClickable(enabled = canSend) {
                            val text = draft.trim()
                            sending = true; sendError = null
                            scope.launch {
                                runCatching { service.addPostComment(communityId, post.id, text) }
                                    .onSuccess { r ->
                                        haptics.success(); draft = ""
                                        comments = comments + r.comment
                                        onCountChange(r.comment_count)
                                    }
                                    .onFailure { sendError = (it as? ApiError)?.userMessage ?: "Couldn't post that. Try again." }
                                sending = false
                            }
                        }.semantics { contentDescription = "Post comment" },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Default.ArrowUpward, null, tint = VoiidColor.textOnAccent, modifier = Modifier.size(18.dp)) }
            }
        }
    }
}
