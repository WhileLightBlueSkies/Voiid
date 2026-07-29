package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AlternateEmail
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.net.ApiError
import com.voiid.app.net.ContactPinService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidCircleBack
import com.voiid.app.ui.components.VoiidPrimaryButton
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.launch

/**
 * Reach someone by @username. Mirrors iOS `FindByUsernameView.swift`.
 *
 * A SEPARATE screen from "New chat", deliberately. New chat browses people you already have —
 * your address book, already matched. This is the opposite: someone you may never have met,
 * found by a handle they gave you. Mixing the two would put strangers in the same list as your
 * contacts, which is the boundary the whole reachability design exists to protect.
 *
 * THE FLOW:
 *   1. type a handle          — resolves to a PUBLIC profile only, never a phone number
 *   2. mutual contacts        — send straight away, acquaintance already proved
 *   3. otherwise, 6-digit PIN — proof they actually gave you their handle
 *   4. lands as a REQUEST     — they still choose whether to accept
 *
 * Two independent gates, so a leaked PIN alone is never enough to reach someone.
 */
@Composable
fun FindByUsernameScreen(
    onClose: () -> Unit,
    /** (conversationId, pending) once a chat is opened. */
    onOpen: (String, Boolean) -> Unit,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()

    var handle by remember { mutableStateOf("") }
    var profile by remember { mutableStateOf<ContactPinService.PublicProfile?>(null) }
    var pin by remember { mutableStateOf("") }
    var looking by remember { mutableStateOf(false) }
    var sending by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    val cleanHandle = handle.trim().lowercase().removePrefix("@")

    fun lookup() {
        if (cleanHandle.isEmpty()) return
        looking = true; error = null; profile = null
        scope.launch {
            runCatching { ContactPinService(context).lookup(cleanHandle) }
                .onSuccess { profile = it }
                // Do NOT distinguish "no such handle" from other failures — a precise message
                // would help someone enumerate which handles exist.
                .onFailure { error = "No one found with that username." }
            looking = false
        }
    }

    fun send(p: ContactPinService.PublicProfile) {
        sending = true; error = null
        scope.launch {
            runCatching {
                ContactPinService(context).requestChat(
                    p.username ?: cleanHandle,
                    if (p.requires_pin) pin else null,
                )
            }.onSuccess { (id, pending) -> onOpen(id, pending) }
                .onFailure { e ->
                    // 403 is a wrong PIN, 429 the throttle. Both are actionable, so they are
                    // surfaced rather than flattened into "try again".
                    error = when ((e as? ApiError.Http)?.status) {
                        403 -> "That PIN isn't correct."
                        429 -> "Too many attempts. Try again later."
                        else -> "Couldn't send that request. Check your connection."
                    }
                }
            sending = false
        }
    }

    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
        VoiidCircleBack(onBack = onClose)
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("Find by username", style = VoiidFont.rounded(26, FontWeight.Bold), color = VoiidColor.textPrimary)
            Text(
                "Ask for someone's Voiid handle, then their PIN if you're not already in each other's contacts.",
                style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
            )

            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(VoiidRadius.pill))
                    .background(VoiidColor.fieldFill)
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("@", style = VoiidFont.rounded(17, FontWeight.Medium), color = VoiidColor.textSecondary)
                Spacer(Modifier.width(6.dp))
                BasicTextField(
                    value = handle,
                    // A new handle invalidates whatever we resolved before — otherwise you
                    // could look one person up, retype, and send to the first.
                    onValueChange = { handle = it; profile = null; error = null; pin = "" },
                    singleLine = true,
                    textStyle = TextStyle(fontSize = 17.sp, color = VoiidColor.textPrimary),
                    cursorBrush = SolidColor(VoiidColor.primary),
                    modifier = Modifier.weight(1f),
                )
                if (looking) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = VoiidColor.primary)
                } else {
                    Text(
                        "Find",
                        style = VoiidFont.rounded(15, FontWeight.SemiBold),
                        color = if (cleanHandle.isEmpty()) VoiidColor.placeholder else VoiidColor.primary,
                        modifier = Modifier.clickable(enabled = cleanHandle.isNotEmpty()) { haptics.tap(); lookup() },
                    )
                }
            }

            profile?.let { p ->
                Column(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg))
                        .background(VoiidColor.surfaceCard).padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        ProfileAvatar(p.photo_url, p.full_name ?: p.username, 48.dp, Modifier.clip(CircleShape))
                        Spacer(Modifier.width(12.dp))
                        Column {
                            Text(
                                p.full_name?.takeIf { it.isNotBlank() } ?: p.username ?: "Unknown",
                                style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary,
                            )
                            p.username?.let {
                                Text("@$it", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                            }
                        }
                    }

                    if (!p.reachable_by_username) {
                        // They never set a PIN. Say so rather than letting the user type six
                        // digits that could never work.
                        Text(
                            "This person can't be reached by username.",
                            style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
                        )
                    } else {
                        if (p.requires_pin) {
                            BasicTextField(
                                value = pin,
                                // Digits only, capped at 6 — a paste of "418 302" still works.
                                onValueChange = { pin = it.filter(Char::isDigit).take(6) },
                                singleLine = true,
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                                textStyle = TextStyle(fontSize = 20.sp, color = VoiidColor.textPrimary, fontWeight = FontWeight.SemiBold),
                                cursorBrush = SolidColor(VoiidColor.primary),
                                decorationBox = { inner ->
                                    Box(
                                        Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.md))
                                            .background(VoiidColor.fieldFill).padding(horizontal = 14.dp, vertical = 12.dp),
                                    ) {
                                        if (pin.isEmpty()) {
                                            Text("6-digit PIN", style = VoiidFont.rounded(16), color = VoiidColor.placeholder)
                                        }
                                        inner()
                                    }
                                },
                            )
                        }
                        VoiidPrimaryButton(
                            title = if (p.is_mutual_contact) "Message" else "Send request",
                            modifier = Modifier.fillMaxWidth(),
                            enabled = !sending && (!p.requires_pin || pin.length == 6),
                            onClick = { haptics.rigid(); send(p) },
                        )
                        Text(
                            if (p.is_mutual_contact)
                                "You're both in each other's contacts, so this opens a normal chat."
                            else
                                "They'll get a request to accept before your message appears in their chats.",
                            style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
                        )
                    }
                }
            }

            error?.let {
                Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
            }
        }
    }
}

/**
 * Inbound message requests — people who reached you by @username and are waiting to be
 * accepted. Mirrors iOS `MessageRequestsView.swift`.
 *
 * These are deliberately NOT in the chat list: `GET /conversations` filters to
 * `request_state = 'accepted'`, so a stranger's first message cannot appear among real
 * conversations. That separation is the point of the gate, and this screen is where the
 * held-back ones live.
 *
 * DECLINE TELLS THE SENDER NOTHING. If "declined" were distinguishable from "not opened yet",
 * a request would become a presence oracle telling a stranger whether an account is live.
 */
@Composable
fun MessageRequestsScreen(
    onClose: () -> Unit,
    onAccepted: (String) -> Unit,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()

    var requests by remember { mutableStateOf<List<ContactPinService.PendingRequest>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf<Set<String>>(emptySet()) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        requests = runCatching { ContactPinService(context).pending() }.getOrDefault(emptyList())
        loading = false
    }

    fun act(r: ContactPinService.PendingRequest, accept: Boolean) {
        busy = busy + r.conversation_id
        error = null
        scope.launch {
            runCatching {
                val svc = ContactPinService(context)
                if (accept) svc.accept(r.conversation_id) else svc.decline(r.conversation_id)
            }.onSuccess {
                // Remove locally rather than re-fetching: the row is gone either way, and a
                // round-trip would make the list flicker.
                requests = requests.filterNot { it.conversation_id == r.conversation_id }
                if (accept) onAccepted(r.conversation_id)
            }.onFailure {
                error = if (accept) "Couldn't accept that request." else "Couldn't decline that request."
            }
            busy = busy - r.conversation_id
        }
    }

    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
        VoiidCircleBack(onBack = onClose)
        Text(
            "Message requests",
            style = VoiidFont.rounded(26, FontWeight.Bold), color = VoiidColor.textPrimary,
            modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
        )

        when {
            loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = VoiidColor.primary)
            }
            requests.isEmpty() -> Column(
                Modifier.fillMaxSize().padding(horizontal = 32.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box(
                    Modifier.size(64.dp).clip(CircleShape).background(VoiidColor.primary.copy(alpha = 0.08f)),
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Default.Inbox, null, tint = VoiidColor.primary.copy(alpha = 0.65f), modifier = Modifier.size(26.dp)) }
                Spacer(Modifier.height(12.dp))
                Text("No requests", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                Spacer(Modifier.height(6.dp))
                Text(
                    "When someone finds you by your username, their first message waits here until you accept it.",
                    style = VoiidFont.rounded(13), color = VoiidColor.textSecondary, textAlign = TextAlign.Center,
                )
            }
            else -> LazyColumn(
                Modifier.fillMaxSize().padding(horizontal = 20.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(requests, key = { it.conversation_id }) { r ->
                    Column(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg))
                            .background(VoiidColor.surfaceCard).padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            ProfileAvatar(r.photo_url, r.full_name ?: r.username, 44.dp, Modifier.clip(CircleShape))
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(
                                    r.full_name?.takeIf { it.isNotBlank() } ?: r.username ?: "Unknown",
                                    style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary,
                                )
                                // How they reached you is load-bearing: "found you by @username"
                                // is a different trust signal from "has your number".
                                Text(
                                    if (r.opened_via == "username") "Found you by @${r.username ?: "username"}"
                                    else "Has your number",
                                    style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
                                )
                            }
                            if (busy.contains(r.conversation_id)) {
                                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = VoiidColor.primary)
                            }
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Box(
                                Modifier.weight(1f).clip(RoundedCornerShape(VoiidRadius.pill))
                                    .background(VoiidColor.primary)
                                    .clickable(enabled = !busy.contains(r.conversation_id)) { haptics.tap(); act(r, true) }
                                    .padding(vertical = 10.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                Text("Accept", style = VoiidFont.rounded(14, FontWeight.SemiBold), color = VoiidColor.textOnPrimary)
                            }
                            Box(
                                Modifier.weight(1f).clip(RoundedCornerShape(VoiidRadius.pill))
                                    .background(VoiidColor.fieldFill)
                                    .clickable(enabled = !busy.contains(r.conversation_id)) { haptics.tap(); act(r, false) }
                                    .padding(vertical = 10.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                Text("Decline", style = VoiidFont.rounded(14, FontWeight.SemiBold), color = VoiidColor.textSecondary)
                            }
                        }
                    }
                }
                error?.let {
                    item { Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error) }
                }
            }
        }
    }
}
