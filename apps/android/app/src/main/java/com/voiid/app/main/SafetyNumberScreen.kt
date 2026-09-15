package com.voiid.app.main

import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.KeyOff
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.net.ChatEngine
import com.voiid.app.net.E2EManager
import com.voiid.app.net.TokenStore
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing

/**
 * VERIFY THAT NOBODY IS IN THE MIDDLE.
 *
 * End-to-end encryption guarantees that only the holder of the other private key can read your
 * messages. It does NOT, by itself, tell you WHOSE key that is. If the server handed you an
 * attacker's key instead of your contact's, every message would still be encrypted — to the
 * attacker, who would relay it on and read everything in between. That is the machine-in-the-middle
 * attack, and it is the one thing encryption alone cannot rule out.
 *
 * The safety number closes it. Both sides derive the SAME 60-digit number from the two identity
 * keys (see packages/e2e-core/src/verify.rs — iterated SHA-512, sorted so both parties compute an
 * identical string regardless of who is "us"). If your number matches theirs, read aloud or checked
 * in person, the keys you each hold are genuinely each other's and there is nobody in between.
 *
 * WHY THIS IS COMPARED OUT OF BAND. The number is only meaningful over a channel the attacker does
 * not control — in person, or on a call where you recognise the voice. Sending it through Voiid
 * itself proves nothing: an attacker relaying your messages would simply rewrite it in transit. The
 * screen says so, because a verification ritual performed over the compromised channel is worse
 * than none — it manufactures confidence.
 *
 * MULTI-DEVICE. A safety number is per DEVICE PAIR, not per person: each device has its own
 * identity key. A contact with a phone and a tablet has two numbers, and both must match.
 *
 * Mirrors iOS `SafetyNumberView.swift`.
 */
@Composable
fun SafetyNumberScreen(
    peerUserId: String,
    peerName: String,
    onClose: () -> Unit,
) {
    val context = LocalContext.current

    /** One device pair: the peer device, and the number we share with it. */
    data class Entry(val deviceId: String, val number: String)

    var entries by remember { mutableStateOf<List<Entry>>(emptyList()) }
    // loading | loaded | failed | noKeys
    var state by remember { mutableStateOf("loading") }
    var reload by remember { mutableIntStateOf(0) }
    var scanningNumber by remember(peerUserId) { mutableStateOf<String?>(null) }
    scanningNumber?.let { number ->
        SafetyCodeScanner(expected = number, peerName = peerName, onClose = { scanningNumber = null })
    }

    LaunchedEffect(peerUserId, reload) {
        state = "loading"
        // OUR fingerprint comes from the LOCAL identity — never from the server. Asking the server
        // for our own key would let a malicious server feed us a number matching whatever it told
        // the peer, which is exactly the attack this screen exists to detect.
        val identity = E2EManager.get(context).identity
        val myId = TokenStore.get(context).userId
        if (identity == null || myId.isNullOrBlank()) {
            state = "failed"
            return@LaunchedEffect
        }
        val myFingerprint = identity.fingerprint()

        runCatching { ChatEngine.get(context).peerIdentities(peerUserId) }
            .onSuccess { peers ->
                if (peers.isEmpty()) {
                    state = "noKeys"
                } else {
                    entries = peers.map { peer ->
                        Entry(
                            deviceId = peer.id,
                            number = uniffi.voiid.safetyNumber(
                                myId.toByteArray(),
                                myFingerprint,
                                peerUserId.toByteArray(),
                                peer.identityKey,
                            ),
                        )
                    }
                    state = "loaded"
                }
            }
            .onFailure {
                android.util.Log.w("VOIID", "safety number load failed: ${it.message}")
                state = "failed"
            }
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(VoiidColor.background)
            .statusBarsPadding()
            .navigationBarsPadding(),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = VoiidSpacing.md, vertical = VoiidSpacing.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "Verify encryption",
                color = VoiidColor.textPrimary,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            Text(
                "Done",
                color = VoiidColor.primary,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clickable { onClose() }.padding(VoiidSpacing.xs),
            )
        }

        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = VoiidSpacing.lg),
            verticalArrangement = Arrangement.spacedBy(VoiidSpacing.lg),
        ) {
            // FOUR STATES THAT USED TO HARD-CUT. Reading keys is fast on a warm cache and
            // slow on a cold one, so this screen frequently flashes from spinner to content
            // in a single frame — which reads as a glitch, on the one screen in the app where
            // a glitch undermines the very thing being asserted.
            //
            // Opacity only, so it is safe under Reduce Motion with no gate.
            //
            // The scannable QR (iOS CIQRCodeGenerator equivalent) renders inside each
            // NumberCard below alongside the digits. ZXing renders it at 600px with a
            // four-module quiet zone so the white border remains readable in either theme.
            androidx.compose.animation.Crossfade(
                targetState = state,
                animationSpec = tween(220),
                label = "safetyNumberState",
            ) { state ->
            when (state) {
                "loading" -> Column(
                    Modifier.fillMaxWidth().padding(top = VoiidSpacing.xxl),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
                ) {
                    CircularProgressIndicator(color = VoiidColor.primary)
                    Text("Reading keys…", color = VoiidColor.textSecondary, fontSize = 14.sp)
                }

                "failed" -> StateMessage(
                    icon = Icons.Outlined.WifiOff,
                    title = "Couldn't load keys",
                    body = "Check your connection and try again.",
                    actionLabel = "Retry",
                    onAction = { reload++ },
                )

                // A peer with no registered device keys. Real: an account that signed up but never
                // completed key setup, or one that logged out everywhere.
                "noKeys" -> StateMessage(
                    icon = Icons.Outlined.KeyOff,
                    title = "No keys to verify yet",
                    body = "$peerName hasn't set up encryption keys on any device. There is " +
                        "nothing to compare until they do.",
                    actionLabel = null,
                    onAction = {},
                )

                else -> Column(
                    Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(peerName, color = VoiidColor.textPrimary, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
                        Text("Compare your security code", color = VoiidColor.textSecondary, fontSize = 14.sp)
                    }
                    entries.forEachIndexed { index, entry ->
                        Column(verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                            // Only labelled when there is more than one — "Device 1 of 1" is noise.
                            if (entries.size > 1) {
                                Text(
                                    "Device ${index + 1} of ${entries.size}",
                                    color = VoiidColor.textSecondary,
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    modifier = Modifier.padding(horizontal = VoiidSpacing.xs),
                                )
                            }
                            NumberCard(entry.number)
                            androidx.compose.material3.Button(onClick = { scanningNumber = entry.number }) { Text("Scan QR code") }
                        }
                    }
                    Instructions(peerName)
                }
            }
            }
        }
    }
}

/**
 * The digits.
 *
 * MONOSPACED and in 5-digit groups, because this number exists to be READ ALOUD and checked
 * character by character. Proportional digits make 1, 7 and 4 similar widths and the eye loses its
 * place; the grouping is what lets two people stay in sync while reading.
 */
@Composable
private fun NumberCard(number: String) {
    val bitmap = remember(number) {
        runCatching {
            val hints = mapOf<com.google.zxing.EncodeHintType, Any>(
                com.google.zxing.EncodeHintType.ERROR_CORRECTION to com.google.zxing.qrcode.decoder.ErrorCorrectionLevel.H,
                com.google.zxing.EncodeHintType.MARGIN to 4,
            )
            val matrix = com.google.zxing.qrcode.QRCodeWriter().encode(number, com.google.zxing.BarcodeFormat.QR_CODE, 600, 600, hints)
            android.graphics.Bitmap.createBitmap(600, 600, android.graphics.Bitmap.Config.ARGB_8888).also { out ->
                for (x in 0 until 600) for (y in 0 until 600) out.setPixel(x, y, if (matrix.get(x, y)) android.graphics.Color.BLACK else android.graphics.Color.WHITE)
            }
        }.getOrNull()
    }
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(VoiidColor.surfaceCard).padding(20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        if (bitmap != null) {
            Image(bitmap = bitmap.asImageBitmap(), contentDescription = "Security code QR",
                modifier = Modifier.widthIn(max = 240.dp).fillMaxWidth().aspectRatio(1f))
        } else {
            Text("QR unavailable. Compare the digits below.", color = VoiidColor.textSecondary, fontSize = 13.sp)
        }
        Text(number.filter(Char::isDigit).chunked(5).chunked(4).joinToString("\n") { it.joinToString(" ") },
            color = VoiidColor.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.Medium,
            fontFamily = FontFamily.Monospace, lineHeight = 27.sp, textAlign = TextAlign.Center)
        Text("Compare this code on both devices.", color = VoiidColor.textSecondary, fontSize = 12.sp, textAlign = TextAlign.Center)
    }
}

@Composable
private fun Instructions(peerName: String) {
    Column(verticalArrangement = Arrangement.spacedBy(VoiidSpacing.md)) {
        Step(1, "Compare in person or on a call",
            "Ask $peerName to open this same screen. Read the numbers to each other, or check " +
                "them side by side.")
        Step(2, "Check that every digit matches",
            "Matching codes confirm the identity keys for this pair of devices. If there are " +
                "multiple devices, compare each device's code.")
        Step(3, "If the codes differ",
            "Codes can change after reinstalling or changing devices. Confirm the change with " +
                "$peerName through a trusted channel before sharing sensitive information.")

        // THE LOAD-BEARING CAVEAT. Comparing the number inside Voiid proves nothing — an attacker
        // relaying your messages would rewrite it in transit. Saying this plainly is the difference
        // between a real check and a reassuring ritual.
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(VoiidRadius.md))
                .background(VoiidColor.warning.copy(alpha = 0.10f))
                .padding(VoiidSpacing.md),
            horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
        ) {
            Icon(
                Icons.Filled.Warning,
                contentDescription = null,
                tint = VoiidColor.warning,
                modifier = Modifier.size(14.dp).padding(top = 2.dp),
            )
            Text(
                "Don't send this number over Voiid or any other chat. It only proves something " +
                    "if you compare it somewhere an attacker can't change it.",
                color = VoiidColor.textSecondary,
                fontSize = 12.sp,
            )
        }
    }
}

@Composable
private fun Step(n: Int, title: String, body: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md)) {
        Box(
            Modifier.size(24.dp).clip(CircleShape).background(VoiidColor.primary),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                "$n",
                color = VoiidColor.textOnPrimary,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, color = VoiidColor.textPrimary, fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold)
            Text(body, color = VoiidColor.textSecondary, fontSize = 13.sp)
        }
    }
}

@Composable
private fun StateMessage(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    body: String,
    actionLabel: String?,
    onAction: () -> Unit,
) {
    Column(
        Modifier.fillMaxWidth().padding(top = VoiidSpacing.xl),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
    ) {
        Icon(icon, contentDescription = null, tint = VoiidColor.textSecondary,
            modifier = Modifier.size(30.dp))
        Text(title, color = VoiidColor.textPrimary, fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold)
        Text(body, color = VoiidColor.textSecondary, fontSize = 14.sp,
            textAlign = TextAlign.Center)
        if (actionLabel != null) {
            Text(
                actionLabel,
                color = VoiidColor.primary,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clickable { onAction() }.padding(top = 4.dp),
            )
        }
    }
}
