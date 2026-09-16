package com.voiid.app.net

import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/** Durable intent storage, separated from HTTP so retries retain their original boundary. */
class ConversationReadQueue(
    private val load: (String) -> String?,
    private val save: (String, String) -> Boolean,
) {
    @Serializable data class Intent(val through: Long, val disclose: Boolean) {
        fun shouldDisclose(currentConsent: Boolean) = disclose && currentConsent
    }
    private val codec = MapSerializer(String.serializer(), Intent.serializer())
    private val json = Json { ignoreUnknownKeys = true }
    private fun key(account: String) = "read_intents_$account"

    @Synchronized fun snapshot(account: String): Map<String, Intent> =
        json.decodeFromString(codec, load(key(account)) ?: "{}")

    @Synchronized fun enqueue(account: String, conversation: String, intent: Intent): Boolean {
        val pending = snapshot(account).toMutableMap()
        val old = pending[conversation]
        if (old == null || intent.through >= old.through) pending[conversation] = intent
        return save(key(account), json.encodeToString(codec, pending))
    }

    @Synchronized fun acknowledge(account: String, conversation: String, sent: Intent): Boolean {
        val pending = snapshot(account).toMutableMap()
        if (pending[conversation] != sent) return true // a newer intent still needs its own POST
        pending.remove(conversation)
        return save(key(account), json.encodeToString(codec, pending))
    }
}
