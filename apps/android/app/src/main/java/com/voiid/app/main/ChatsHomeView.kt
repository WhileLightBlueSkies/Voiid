package com.voiid.app.main

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.voiid.app.model.ChatStore
import com.voiid.app.model.ConversationType
import com.voiid.app.model.DummyData
import com.voiid.app.model.VConversation
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidWordmark
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlin.math.hypot

private enum class ChatTab(val label: String) { CHATS("Chats"), GROUPS("Groups") }

/** Chat home (Figma Screen-6/7) — port of `ChatsHomeView.swift` + `DraggableChatGrid.swift`. */
@Composable
fun ChatsHomeView(
    chat: ChatStore,
    onOpenConversation: (VConversation) -> Unit,
    onStartCall: (CallRequest) -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    var search by remember { mutableStateOf("") }
    var tab by remember { mutableStateOf(ChatTab.CHATS) }
    var deleteTarget by remember { mutableStateOf<VConversation?>(null) }
    var callTarget by remember { mutableStateOf<VConversation?>(null) }

    val list: SnapshotStateList<VConversation> = if (tab == ChatTab.CHATS) chat.directConversations else chat.groupConversations
    val filtered = if (search.isBlank()) list.toList() else list.filter { it.title.contains(search, ignoreCase = true) }

    Column(
        Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding(),
    ) {
        Header(haptics)
        SearchBar(search) { search = it }
        Tabs(tab) { haptics.selection(); tab = it }
        if (search.isBlank()) {
            DraggableChatGrid(
                items = list,
                onOpen = { haptics.tap(); onOpenConversation(it) },
                onCall = { callTarget = it },
                onDelete = { deleteTarget = it },
                modifier = Modifier.fillMaxWidth().weight(1f),
            )
        } else {
            // Search results — simple grid
            LazyVerticalGrid(
                columns = GridCells.Fixed(3),
                modifier = Modifier.fillMaxWidth().weight(1f),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(24.dp),
                horizontalArrangement = Arrangement.spacedBy(24.dp),
                verticalArrangement = Arrangement.spacedBy(24.dp),
            ) {
                items(filtered, key = { it.id }) { conv ->
                    GridCard(conv, Modifier.softClickable(scale = 0.94f) { haptics.tap(); onOpenConversation(conv) })
                }
            }
        }
    }

    // Delete confirmation
    deleteTarget?.let { c ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            containerColor = VoiidColor.surfaceCard,
            title = { Text("Delete chat?", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary) },
            text = { Text("This chat will be deleted from your list.", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary) },
            confirmButton = { TextButton(onClick = { chat.deleteConversation(c.id); deleteTarget = null }) { Text("Delete", color = VoiidColor.error) } },
            dismissButton = { TextButton(onClick = { deleteTarget = null }) { Text("Cancel", color = VoiidColor.primary) } },
        )
    }

    // Call type picker
    callTarget?.let { c ->
        CallTypeSheet(
            title = c.title,
            onPick = { kind ->
                onStartCall(
                    CallRequest(
                        title = c.title,
                        isGroup = c.type == ConversationType.GROUP,
                        members = if (c.type == ConversationType.GROUP) DummyData.groupMembers else emptyList(),
                        photoName = c.photoName,
                        kind = kind,
                    ),
                )
                callTarget = null
            },
            onDismiss = { callTarget = null },
        )
    }
}

// MARK: - Draggable, home-screen-style grid

private enum class DropZone { CALL, DELETE }

@Composable
private fun DraggableChatGrid(
    items: SnapshotStateList<VConversation>,
    onOpen: (VConversation) -> Unit,
    onCall: (VConversation) -> Unit,
    onDelete: (VConversation) -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptics = LocalVoiidHaptics.current
    val density = LocalDensity.current
    val centers = remember { mutableStateMapOfCenters() }
    var rootOrigin by remember { mutableStateOf(Offset.Zero) }
    var containerWidthPx by remember { mutableStateOf(0f) }

    var dragItem by remember { mutableStateOf<VConversation?>(null) }
    var dragStart by remember { mutableStateOf(Offset.Zero) }
    var dragTranslation by remember { mutableStateOf(Offset.Zero) }
    var hoverZone by remember { mutableStateOf<DropZone?>(null) }
    var armedId by remember { mutableStateOf<String?>(null) }

    val gutterPx = with(density) { 70.dp.toPx() }
    val reorderPx = with(density) { 60.dp.toPx() }
    val cardPx = with(density) { 96.dp.toPx() }

    Box(
        modifier
            .onGloballyPositioned {
                rootOrigin = it.positionInRoot()
                containerWidthPx = it.size.width.toFloat()
            }
            // Container-level long-press drag: independent of item composables, so live reorder
            // never cancels the gesture (mirrors iOS DraggableChatGrid pick-up + drag).
            .pointerInput(items.size) {
                detectDragGesturesAfterLongPress(
                    onDragStart = { offset ->
                        val picked = centers.entries.minByOrNull {
                            hypot((it.value.x - offset.x).toDouble(), (it.value.y - offset.y).toDouble())
                        }?.key?.let { id -> items.firstOrNull { it.id == id } }
                        if (picked != null) {
                            haptics.rigid()
                            armedId = picked.id
                            dragItem = picked
                            dragStart = centers[picked.id] ?: offset
                            dragTranslation = Offset.Zero
                        }
                    },
                    onDrag = { change, amount ->
                        change.consume()
                        val conv = dragItem ?: return@detectDragGesturesAfterLongPress
                        dragTranslation += amount
                        val p = dragStart + dragTranslation
                        hoverZone = when {
                            p.x < gutterPx -> DropZone.CALL
                            p.x > containerWidthPx - gutterPx -> DropZone.DELETE
                            else -> null
                        }
                        if (hoverZone == null) {
                            val target = centers.entries
                                .filter { it.key != conv.id }
                                .minByOrNull { hypot((it.value.x - p.x).toDouble(), (it.value.y - p.y).toDouble()) }
                            if (target != null &&
                                hypot((target.value.x - p.x).toDouble(), (target.value.y - p.y).toDouble()) < reorderPx
                            ) {
                                val from = items.indexOfFirst { it.id == conv.id }
                                val to = items.indexOfFirst { it.id == target.key }
                                if (from >= 0 && to >= 0 && from != to) {
                                    val m = items.removeAt(from)
                                    items.add(to, m)
                                    dragStart = centers[conv.id] ?: dragStart
                                    dragTranslation = p - dragStart
                                }
                            }
                        }
                    },
                    onDragEnd = {
                        val d = dragItem
                        val zone = hoverZone
                        dragItem = null; dragTranslation = Offset.Zero; hoverZone = null; armedId = null
                        if (d != null) when (zone) {
                            DropZone.CALL -> { haptics.success(); onCall(d) }
                            DropZone.DELETE -> { haptics.rigid(); onDelete(d) }
                            null -> {}
                        }
                    },
                    onDragCancel = {
                        dragItem = null; dragTranslation = Offset.Zero; hoverZone = null; armedId = null
                    },
                )
            },
    ) {
        // Grid (3 columns) inside a scroll container; scroll locks while dragging.
        val scroll = rememberScrollState()
        Column(
            Modifier
                .fillMaxSize()
                .then(if (dragItem == null) Modifier.verticalScroll(scroll) else Modifier)
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            items.chunked(3).forEach { row ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                    row.forEach { conv ->
                        Box(
                            Modifier
                                .weight(1f)
                                .onGloballyPositioned { coords ->
                                    val p = coords.positionInRoot()
                                    centers[conv.id] = Offset(
                                        p.x - rootOrigin.x + coords.size.width / 2f,
                                        p.y - rootOrigin.y + coords.size.height / 2f,
                                    )
                                }
                                .scale(if (armedId == conv.id) 1.08f else 1f)
                                .alpha(if (dragItem?.id == conv.id) 0.001f else 1f)
                                .clickable(
                                    interactionSource = remember { MutableInteractionSource() },
                                    indication = null,
                                ) { if (dragItem == null) onOpen(conv) },
                        ) {
                            GridCard(conv, Modifier.fillMaxWidth())
                        }
                    }
                    // pad incomplete rows so cards keep their column width
                    repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
            Spacer(Modifier.height(90.dp))
        }

        // Side drop zones (only while dragging)
        AnimatedVisibility(
            visible = dragItem != null,
            enter = scaleIn() + fadeIn(),
            exit = scaleOut() + fadeOut(),
            modifier = Modifier.fillMaxSize(),
        ) {
            Row(
                Modifier.fillMaxSize().padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                DropZoneView(DropZone.CALL, Icons.Default.Call, "Call", VoiidColor.primary, hoverZone == DropZone.CALL)
                Spacer(Modifier.weight(1f))
                DropZoneView(DropZone.DELETE, Icons.Default.Delete, "Delete", VoiidColor.error, hoverZone == DropZone.DELETE)
            }
        }

        // Floating dragged card
        dragItem?.let { d ->
            val p = dragStart + dragTranslation
            Box(
                Modifier
                    .zIndex(10f)
                    .offset {
                        androidx.compose.ui.unit.IntOffset(
                            (p.x - cardPx / 2f).toInt(),
                            (p.y - cardPx * 1.1f / 2f).toInt(),
                        )
                    }
                    .width(96.dp)
                    .scale(1.12f)
                    .shadow(14.dp, RoundedCornerShape(VoiidRadius.lg)),
            ) {
                GridCard(d, Modifier.fillMaxWidth())
            }
        }
    }
}

private fun mutableStateMapOfCenters() = androidx.compose.runtime.mutableStateMapOf<String, Offset>()

@Composable
private fun DropZoneView(zone: DropZone, icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, color: Color, active: Boolean) {
    val scale by animateFloatAsState(if (active) 1.2f else 1f, label = "zoneScale")
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.scale(scale).alpha(if (active) 1f else 0.85f),
    ) {
        Box(
            Modifier.size(60.dp).shadow(if (active) 14.dp else 8.dp, CircleShape).clip(CircleShape).background(color),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, label, tint = VoiidColor.textOnPrimary, modifier = Modifier.size(24.dp)) }
        Text(label, style = VoiidFont.rounded(12, FontWeight.SemiBold), color = color)
    }
}

@Composable
private fun Header(haptics: com.voiid.app.ui.components.VoiidHaptics) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("Chats", style = VoiidFont.rounded(24, FontWeight.Bold), color = VoiidColor.textPrimary)
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
                            style = VoiidFont.rounded(15, FontWeight.SemiBold),
                            color = if (selected == t) VoiidColor.primary else VoiidColor.textSecondary,
                        )
                    }
                }
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(VoiidColor.divider.copy(alpha = 0.5f)))
        }
        Box(
            Modifier
                .offset(x = underlineX)
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
                // iOS renders the wordmark image at width 56pt (~52% of card), very faint.
                VoiidWordmark(fontSize = 23, alpha = 0.15f)
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
                    Text("${conv.unreadCount}", style = VoiidFont.rounded(11, FontWeight.Bold), color = Color.White)
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        Text(conv.title, style = VoiidFont.rounded(13), color = VoiidColor.textPrimary, maxLines = 1)
    }
}
