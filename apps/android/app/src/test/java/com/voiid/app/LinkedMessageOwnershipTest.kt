package com.voiid.app

import com.voiid.app.net.ChatEngine.DecryptedMessage
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class LinkedMessageOwnershipTest {
    private val mine = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private val peer = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private fun cached() = DecryptedMessage("server-message", mine, "Sent from web नमस्ते", 1000L, false,
        deliveryStatus = "read", readAt = 2000L, reactions = mapOf(peer to "❤️"),
        quotedId = "quoted-message", quotedPreview = "Earlier text")

    @Test fun repairCachedSiblingSendPreservesEveryOtherFieldAndSurvivesReload() {
        val old = Json.decodeFromString(DecryptedMessage.serializer(), Json.encodeToString(DecryptedMessage.serializer(), cached()))
        val fixed = old.resolvingOwnership(mine.uppercase())
        assertEquals(old.copy(isMine = true), fixed)
        assertEquals(fixed, Json.decodeFromString(DecryptedMessage.serializer(), Json.encodeToString(DecryptedMessage.serializer(), fixed)))
    }

    @Test fun peerAndUnknownAccountsStayIncoming() {
        for (user in listOf(peer, null, "")) assertFalse(cached().resolvingOwnership(user).isMine)
    }

    @Test fun pendingLocalSendRemainsOutgoing() {
        val local = DecryptedMessage("pending", "me", "offline", 1000L, true, pending = true)
        assertEquals(local, local.resolvingOwnership(mine))
    }

    @Test fun controlsAndDecryptFailuresKeepMetadataWithCorrectDirection() {
        for (message in listOf(cached().copy(control = true), cached().copy(failed = true))) {
            assertEquals(message.copy(isMine = true), message.resolvingOwnership(mine))
        }
    }
}
