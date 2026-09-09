package com.voiid.app.main.stories

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.voiid.app.main.bubbleAccent
import com.voiid.app.main.bubbleTextSecondary
import com.voiid.app.model.VMessage
import com.voiid.app.net.TokenStore
import com.voiid.app.store.StoryLocalStore
import com.voiid.app.store.UserDirectory
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.delay

/** Resolve only an existing local Moment; a chat reply never downloads or retains its media. */
@Composable
internal fun StoryQuoteView(message: VMessage) {
    val id = message.storyQuoteId ?: return
    val context = LocalContext.current
    val flow = remember(context, id) { StoryLocalStore.observeStory(context, id) }
    val stored by flow.collectAsState(initial = null)
    // A reference in peer-supplied text must not resolve another author's local media.
    val story = stored?.takeIf { it.authorId.equals(message.storyQuoteAuthorId, ignoreCase = true) }
    val expiresAt = story?.expiresAt ?: message.storyQuoteCreatedAt?.takeIf {
        it > 0 && it <= Long.MAX_VALUE - 86_400_000L
    }?.plus(86_400_000L)
    var expired by remember(id, expiresAt) { mutableStateOf(expiresAt != null && expiresAt <= System.currentTimeMillis()) }
    LaunchedEffect(id, expiresAt) {
        expiresAt ?: return@LaunchedEffect
        delay((expiresAt - System.currentTimeMillis()).coerceAtLeast(0))
        expired = true
    }
    val pixels = with(LocalDensity.current) { 44.dp.roundToPx() }
    val thumbnail = rememberStoryThumbnail(if (expired) null else story?.localPath, story?.isVideo == true, pixels, pixels)
    val mine = message.isMine
    val accent = bubbleAccent(mine)
    val secondary = bubbleTextSecondary(mine)
    val ownMoment = message.storyQuoteAuthorId?.equals(TokenStore.get(context).userId, ignoreCase = true) == true
    val author = if (ownMoment) "Your moment" else message.storyQuoteAuthorId?.let { UserDirectory.displayName(it) } ?: "Moment"
    val description = when {
        expired -> "Moment expired"
        story == null -> "Moment unavailable"
        story.isVideo -> "Video moment"
        else -> "Photo moment"
    }
    Row(
        Modifier.clip(RoundedCornerShape(8.dp))
            .background(if (mine) Color.White.copy(alpha = 0.16f) else VoiidColor.fieldFill.copy(alpha = 0.7f))
            .padding(6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(3.dp).height(44.dp).clip(RoundedCornerShape(2.dp)).background(accent))
        if (LocalDensity.current.fontScale < 1.5f) {
            Box(Modifier.size(44.dp).clip(RoundedCornerShape(5.dp)).background(accent.copy(alpha = 0.1f)), contentAlignment = Alignment.Center) {
                if (thumbnail != null && !expired) Image(thumbnail, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                else Icon(if (story?.isVideo == true) Icons.Default.Videocam else Icons.Default.Image, null, Modifier.size(20.dp), tint = secondary)
            }
        }
        Column(Modifier.weight(1f, fill = false)) {
            Text(author, style = VoiidFont.rounded(11, FontWeight.SemiBold), color = accent, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(description, style = VoiidFont.rounded(12), color = secondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}
