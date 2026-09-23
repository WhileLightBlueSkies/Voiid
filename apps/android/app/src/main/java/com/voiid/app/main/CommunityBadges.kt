package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountBalance
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/**
 * The two marks Voiid grants from the admin panel (087), drawn the same way everywhere.
 * Port of iOS `CommunityBadges.swift`.
 *
 * Both are the SERVER'S claim — a host cannot give either — and `author_badge` is a word from a
 * vocabulary the server may grow: this build draws the words it knows and nothing for one it
 * does not, because an unlabelled pill would be a claim with no content.
 */
@Composable
fun CommunityAuthorTag(badge: String?) {
    val label = when (badge) {
        "community_moderator" -> "Community moderator"
        else -> return
    }
    Row(
        Modifier
            .clip(RoundedCornerShape(50))
            .background(VoiidColor.accentTint)
            .padding(horizontal = 6.dp, vertical = 2.dp)
            .semantics(mergeDescendants = true) { contentDescription = "$label, verified by Voiid" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Icon(Icons.Filled.VerifiedUser, null, tint = VoiidColor.accentInk, modifier = Modifier.size(10.dp))
        Text(label, style = VoiidFont.rounded(10.5f, FontWeight.SemiBold), color = VoiidColor.accentInk, maxLines = 1)
    }
}

/** "🏛 Northstar University ✓" under a community's name. Nothing for an ordinary community. */
@Composable
fun InstitutionMark(name: String?, compact: Boolean = false) {
    if (name.isNullOrBlank()) return
    val size = if (compact) 11.dp else 12.dp
    Row(
        Modifier.semantics(mergeDescendants = true) { contentDescription = "Verified institution: $name" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(Icons.Filled.AccountBalance, null, tint = VoiidColor.accentInk, modifier = Modifier.size(size))
        Text(name, style = VoiidFont.rounded(if (compact) 11.5f else 12.5f, FontWeight.SemiBold),
            color = VoiidColor.accentInk, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Icon(Icons.Filled.Verified, null, tint = VoiidColor.accentInk, modifier = Modifier.size(size))
    }
}
