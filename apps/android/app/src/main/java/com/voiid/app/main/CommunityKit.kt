package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material3.Text
import com.voiid.app.ui.theme.VoiidFont
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs

/**
 * Shared pieces behind the community screens. Port of the render half of iOS
 * `CommunityHomeModels.swift` plus `CommunityFeedDate` from `CommunityHomeTab.swift`.
 *
 * NOTHING HERE IS MOCK DATA. The iOS file still carries `CommunitySpace.samples` and friends
 * because a few of its decorations (a Space's purpose/unread, a member's display name) have no
 * route behind them yet. Those samples are deliberately NOT ported: a sample array on Android
 * would be a second fake to keep in step with the first, and the Android screens read the
 * service types directly. Where a field has no endpoint, the UI omits it rather than inventing
 * it — see `CommunitySpacesSection`.
 */

// ══════════════════════════════════════════════════════════════════════════════════
//  AVATARS
// ══════════════════════════════════════════════════════════════════════════════════

/**
 * The palette AVOIDS LIME. Lime is the brand's ACTION colour — unread badges, the compose
 * button — and an avatar wearing it competes with the controls the user is meant to press.
 * Same eight colours as iOS `AvatarPalette`, in the same order, so a given name lands on the
 * same colour on both platforms.
 */
object AvatarPalette {
    private val colors = listOf(
        Color(0xFF7862A6),   // aubergine
        Color(0xFF3B82F6),   // blue
        Color(0xFFA855F7),   // violet
        Color(0xFFE8A33D),   // amber
        Color(0xFF22C55E),   // green
        Color(0xFFEF4444),   // red
        Color(0xFF14B8A6),   // teal
        Color(0xFFEC4899),   // pink
    )

    /**
     * A simple deterministic sum over code points. `hashCode()` is NOT used — Kotlin/JVM does
     * not seed String.hashCode per process, but iOS's `hashValue` DOES, and the iOS side had to
     * avoid it for that reason. Both platforms use this same sum so the colour matches across
     * devices as well as across launches.
     */
    fun colorFor(name: String): Color {
        val sum = name.sumOf { it.code }
        return colors[abs(sum) % colors.size]
    }

    /** One or two initials, skipping anything that is not a letter, so "🌱 Plant" gives "P". */
    fun initialsFor(name: String): String {
        val letters = name.split(" ")
            .mapNotNull { word -> word.firstOrNull { it.isLetter() } }
            .take(2)
        return if (letters.isEmpty()) "?" else letters.joinToString("").uppercase(Locale.ROOT)
    }
}

/**
 * A name-derived avatar, used wherever the roster has a display name but no photo.
 *
 * Marked [clearAndSetSemantics] with no label — decorative, and the name it encodes is always
 * already on screen as text beside it. Mirrors `.accessibilityHidden(true)` on iOS.
 */
@Composable
fun CommunityAvatar(
    name: String,
    size: Dp = 64.dp,
    modifier: Modifier = Modifier,
) {
    val base = AvatarPalette.colorFor(name)
    Box(
        modifier
            .size(size)
            .clip(CircleShape)
            .background(
                Brush.linearGradient(
                    colors = listOf(base, base.copy(alpha = 0.72f)),
                    // topLeading → bottomTrailing, matching the iOS LinearGradient.
                    start = Offset.Zero,
                    end = Offset.Infinite,
                )
            )
            .clearAndSetSemantics {},
        contentAlignment = Alignment.Center,
    ) {
        Text(
            AvatarPalette.initialsFor(name),
            // Scales with the circle so it reads at 26dp in a face pile and 64dp in a card.
            style = VoiidFont.rounded((size.value * 0.38f), FontWeight.SemiBold),
            color = Color.White,
        )
    }
}

// ══════════════════════════════════════════════════════════════════════════════════
//  DATES
// ══════════════════════════════════════════════════════════════════════════════════

/**
 * Relative ages for the feed. Port of iOS `CommunityFeedDate`, thresholds identical so the two
 * platforms never disagree about whether something is "3h ago" or "yesterday".
 */
object CommunityFeedDate {
    private val dayFormat = DateTimeFormatter.ofPattern("d MMM", Locale.getDefault())

    /**
     * Postgres `timestamptz` serialises with fractional seconds on some rows and without on
     * others; both spellings arrive from this API. `Instant.parse` handles both, so unlike iOS
     * this needs no second parser — but it throws rather than returning null, hence the catch.
     */
    private fun parse(iso: String): Instant? = runCatching { Instant.parse(iso) }.getOrNull()

    fun age(iso: String?): String {
        val date = iso?.let(::parse) ?: return ""
        val secs = (System.currentTimeMillis() - date.toEpochMilli()) / 1000
        // A clock-skewed FUTURE timestamp reads as "now" rather than as a negative age.
        return when {
            secs < 60 -> "now"
            secs < 3_600 -> "${secs / 60}m ago"
            secs < 86_400 -> "${secs / 3_600}h ago"
            secs < 604_800 -> "${secs / 86_400}d ago"
            else -> dayFormat.format(date.atZone(ZoneId.systemDefault()))
        }
    }

    /** "May 2024" — the join date on a member row. */
    private val monthFormat = DateTimeFormatter.ofPattern("MMM yyyy", Locale.getDefault())

    fun joinedMonth(iso: String?): String {
        val date = iso?.let(::parse) ?: return ""
        return monthFormat.format(date.atZone(ZoneId.systemDefault()))
    }
}

// ══════════════════════════════════════════════════════════════════════════════════
//  COUNTS
// ══════════════════════════════════════════════════════════════════════════════════

/**
 * 48_200 → "48.2K". Mirrors `CommunitySpace.membersText` on iOS.
 *
 * Deliberately stops at K. The app has no community anywhere near a million members, and a
 * formatter that can print "1.2M" is a formatter someone will trust for a number it has never
 * actually been given.
 */
fun compactCount(n: Int): String =
    if (n >= 1_000) String.format(Locale.ROOT, "%.1fK", n / 1_000.0) else n.toString()

/** "1 member" / "24 members" — the pluralisation the header and the roster both need. */
fun memberCountText(n: Int): String = "$n member" + if (n == 1) "" else "s"
