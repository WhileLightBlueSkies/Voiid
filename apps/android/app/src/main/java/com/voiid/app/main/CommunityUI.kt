package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.components.ColumnScopeMarker
import com.voiid.app.ui.components.VoiidDialog
import com.voiid.app.ui.components.VoiidMenu
import com.voiid.app.ui.components.VoiidMenuDivider
import com.voiid.app.ui.components.VoiidMenuItem
import com.voiid.app.ui.components.pressableClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing

/**
 * The small shared pieces every community screen draws: the icon set, the empty/error
 * treatment, pills and badges, and the confirm dialog.
 *
 * ── WHY AN ICON ENUM RATHER THAN Icons.Filled.X AT EVERY CALL SITE ───────────────
 * iOS names its glyphs as SF Symbol strings ("pin.fill", "megaphone"). Material has no
 * one-to-one equivalent for several of them, so the mapping is a decision that belongs in
 * ONE place — otherwise two screens pick different Material icons for the same iOS glyph
 * and the drift is invisible until someone puts the two screens side by side.
 */
enum class CommunityIcon {
    MEMBERS, COMPOSE, WARNING, WARNING_FILL, FLAG, PERSON_ADD, CHECK, CLOSE,
    PIN, PIN_FILL, PIN_SLASH, REPLACE, PLUS, CHEVRON_RIGHT, ELLIPSIS, BOOKMARK,
    SHARE, TRASH, HEART, HEART_FILL, COMMENT, LOCK, GLOBE, SHIELD_CHECK, SEARCH,
    CLOCK, MEGAPHONE, SPACES, LINK, INBOX, PENCIL, ARROW_UP, ARROW_DOWN, REFRESH,
    ARROW_UP_RIGHT, MINUS_CIRCLE, GEAR, ARCHIVE, ADMINS, PHOTO, CALENDAR,
}

/** The single mapping from an iOS SF Symbol to its Material counterpart. */
private fun CommunityIcon.vector(): ImageVector = when (this) {
    CommunityIcon.MEMBERS -> Icons.Filled.People
    CommunityIcon.COMPOSE -> Icons.Filled.Edit
    CommunityIcon.WARNING -> Icons.Outlined.WarningAmber
    CommunityIcon.WARNING_FILL -> Icons.Filled.Warning
    CommunityIcon.FLAG -> Icons.Filled.Flag
    CommunityIcon.PERSON_ADD -> Icons.Filled.PersonAdd
    CommunityIcon.CHECK -> Icons.Filled.Check
    CommunityIcon.CLOSE -> Icons.Filled.Close
    // Material has no outline/fill pin pair, so the pinned state is carried by the 45°
    // rotation and the colour rather than by two different glyphs.
    CommunityIcon.PIN, CommunityIcon.PIN_FILL -> Icons.Filled.PushPin
    CommunityIcon.PIN_SLASH -> Icons.Filled.LinkOff
    CommunityIcon.REPLACE -> Icons.Filled.Sync
    CommunityIcon.PLUS -> Icons.Filled.Add
    CommunityIcon.CHEVRON_RIGHT -> Icons.AutoMirrored.Filled.KeyboardArrowRight
    CommunityIcon.ELLIPSIS -> Icons.Filled.MoreHoriz
    CommunityIcon.BOOKMARK -> Icons.Outlined.BookmarkBorder
    CommunityIcon.SHARE -> Icons.Filled.IosShare
    CommunityIcon.TRASH -> Icons.Outlined.DeleteOutline
    CommunityIcon.HEART -> Icons.Outlined.FavoriteBorder
    CommunityIcon.HEART_FILL -> Icons.Filled.Favorite
    CommunityIcon.COMMENT -> Icons.Outlined.ChatBubbleOutline
    CommunityIcon.LOCK -> Icons.Filled.Lock
    CommunityIcon.GLOBE -> Icons.Filled.Public
    CommunityIcon.SHIELD_CHECK -> Icons.Filled.VerifiedUser
    CommunityIcon.SEARCH -> Icons.Filled.Search
    CommunityIcon.CLOCK -> Icons.Outlined.Schedule
    CommunityIcon.MEGAPHONE -> Icons.Filled.Campaign
    CommunityIcon.SPACES -> Icons.Outlined.ChatBubbleOutline
    CommunityIcon.LINK -> Icons.Filled.Link
    CommunityIcon.INBOX -> Icons.Filled.Inbox
    CommunityIcon.PENCIL -> Icons.Filled.Edit
    CommunityIcon.ARROW_UP -> Icons.Filled.ArrowUpward
    CommunityIcon.ARROW_DOWN -> Icons.Filled.ArrowDownward
    CommunityIcon.REFRESH -> Icons.Filled.Refresh
    CommunityIcon.ARROW_UP_RIGHT -> Icons.AutoMirrored.Filled.ArrowForward
    CommunityIcon.MINUS_CIRCLE -> Icons.Outlined.RemoveCircleOutline
    CommunityIcon.GEAR -> Icons.Filled.Settings
    CommunityIcon.ARCHIVE -> Icons.Outlined.Archive
    CommunityIcon.ADMINS -> Icons.Filled.ManageAccounts
    CommunityIcon.PHOTO -> Icons.Outlined.PhotoLibrary
    CommunityIcon.CALENDAR -> Icons.Outlined.CalendarToday
}

/**
 * A glyph at an EXACT size. `Icon` defaults to 24dp, which is wrong everywhere here — iOS
 * specifies sizes from 9dp to 28dp — so the size is always explicit and never inherited.
 */
@Composable
fun CommunityGlyph(
    icon: CommunityIcon,
    size: Dp,
    tint: Color,
    modifier: Modifier = Modifier,
    /** The pinned-Space glyph is rotated 45° on iOS. */
    rotate: Float = 0f,
) {
    Icon(
        imageVector = icon.vector(),
        contentDescription = null,
        tint = tint,
        modifier = modifier.size(size).then(if (rotate != 0f) Modifier.rotate(rotate) else Modifier),
    )
}

/**
 * The shared empty/error treatment used by every tab. Icon 28dp in `placeholder`, a
 * semibold title, a regular detail line, 32dp of vertical air. No background, no border.
 */
@Composable
fun Emptyish(icon: CommunityIcon, title: String, detail: String) {
    Column(
        Modifier.fillMaxWidth().padding(vertical = VoiidSpacing.xl),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
    ) {
        CommunityGlyph(icon, size = 28.dp, tint = VoiidColor.placeholder)
        Text(title, style = VoiidFont.rounded(15, FontWeight.SemiBold),
            color = VoiidColor.textPrimary, textAlign = TextAlign.Center)
        Text(detail, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
            textAlign = TextAlign.Center)
    }
}

@Composable
fun CenteredSpinner(vertical: Dp = VoiidSpacing.lg) {
    Box(Modifier.fillMaxWidth().padding(vertical = vertical), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(color = VoiidColor.accent, strokeWidth = 2.dp,
            modifier = Modifier.size(22.dp))
    }
}

/** A capsule label — the "Host" / "Admin" / role badges. */
@Composable
fun Pill(
    text: String,
    fill: Color,
    textColor: Color,
    fontSize: Float = 10f,
    hPad: Dp = 7.dp,
    vPad: Dp = 3.dp,
    modifier: Modifier = Modifier,
) {
    Text(
        text,
        style = VoiidFont.rounded(fontSize, FontWeight.Bold),
        color = textColor,
        modifier = modifier
            .clip(RoundedCornerShape(VoiidRadius.pill))
            .background(fill)
            .padding(horizontal = hPad, vertical = vPad),
    )
}

/**
 * The accent count badge. `defaultMinSize` rather than `size`, so a two-digit count widens
 * the badge into a stadium instead of clipping — matching how SwiftUI's `minWidth/minHeight`
 * circle behaves.
 */
@Composable
fun CountBadge(count: Int, modifier: Modifier = Modifier) {
    Box(
        modifier
            .defaultMinSize(minWidth = 19.dp, minHeight = 19.dp)
            .clip(RoundedCornerShape(VoiidRadius.pill))
            .background(VoiidColor.accent)
            .padding(horizontal = 5.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(count.toString(), style = VoiidFont.rounded(10.5f, FontWeight.Bold),
            color = VoiidColor.textOnAccent)
    }
}

/** A circular icon button — the queue row's approve/reject pair. */
@Composable
fun CircleAction(
    icon: CommunityIcon,
    tint: Color,
    background: Color,
    enabled: Boolean,
    label: String,
    onClick: () -> Unit,
    size: Dp = 28.dp,
) {
    Box(
        Modifier
            .size(size)
            .clip(CircleShape)
            .background(background)
            .pressableClickable(enabled = enabled, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        CommunityGlyph(icon, size = 11.dp, tint = tint)
    }
}

/**
 * The confirm dialog, wrapping the app's [VoiidDialog] so the community screens state their
 * copy once. Destructive confirms render in the error colour and carry the rigid haptic.
 */
@Composable
fun VoiidConfirmDialog(
    title: String,
    message: String,
    confirmLabel: String,
    destructive: Boolean,
    onCancel: () -> Unit,
    onConfirm: () -> Unit,
) {
    VoiidDialog(
        onDismissRequest = onCancel,
        title = title,
        body = message,
        confirmLabel = confirmLabel,
        onConfirm = onConfirm,
        confirmDestructive = destructive,
        cancelLabel = "Cancel",
        onCancel = onCancel,
    )
}

/** Alias so the community screens read against one menu name. */
@Composable
fun CommunityMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    content: @Composable ColumnScopeMarker.() -> Unit,
) = VoiidMenu(expanded = expanded, onDismissRequest = onDismiss, content = content)

@Composable
fun ColumnScopeMarker.CommunityMenuItem(
    text: String,
    icon: CommunityIcon,
    destructive: Boolean = false,
    enabled: Boolean = true,
    onClick: () -> Unit,
) = VoiidMenuItem(
    text = text, icon = icon.vector(), destructive = destructive,
    enabled = enabled, onClick = onClick,
)

@Composable
fun ColumnScopeMarker.CommunityMenuDivider() = VoiidMenuDivider()

/**
 * Join-policy presentation. Port of iOS `JoinPolicyOption`.
 *
 * "Paid" is carried deliberately as an UNAVAILABLE option rather than omitted: the settings
 * screen shows it greyed with a COMING SOON badge, and an unknown policy id from the server
 * resolves to "Invite only" — the safest reading, never "Open to all".
 */
data class JoinPolicyOption(
    val id: String,
    val label: String,
    val explanation: String,
    val icon: CommunityIcon,
    val available: Boolean = true,
) {
    companion object {
        val all = listOf(
            JoinPolicyOption("open", "Open to all",
                "Anyone who finds this community joins instantly.", CommunityIcon.GLOBE),
            JoinPolicyOption("approval", "Request to join",
                "People ask to join and you review each request.", CommunityIcon.SHIELD_CHECK),
            JoinPolicyOption("invite_only", "Invite only",
                "The only way in is an invite link or an invite from a member.",
                CommunityIcon.LOCK),
            JoinPolicyOption("__paid_unavailable", "Paid",
                "Paid communities aren't available yet.", CommunityIcon.CALENDAR,
                available = false),
        )

        fun find(id: String?): JoinPolicyOption? = all.firstOrNull { it.id == id }

        /** An unknown or unavailable policy reads as the most restrictive, never the least. */
        fun shortLabel(id: String?): String =
            find(id)?.takeIf { it.available }?.label ?: "Invite only"

        fun icon(id: String?): CommunityIcon =
            find(id)?.takeIf { it.available }?.icon ?: CommunityIcon.LOCK

        fun sanitised(id: String, fallback: String): String =
            if (find(id)?.available == true) id else fallback
    }
}
