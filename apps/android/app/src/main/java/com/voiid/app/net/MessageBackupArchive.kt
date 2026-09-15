package com.voiid.app.net

import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.*
import java.util.UUID

/** Versioned, account-bound archive. Timestamps are integer Unix milliseconds on both platforms. */
internal object MessageBackupArchive {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false; coerceInputValues = true }
    private val serializer = MapSerializer(String.serializer(), ListSerializer(ChatEngine.DecryptedMessage.serializer()))
    fun encode(userId: String, messages: Map<String, List<ChatEngine.DecryptedMessage>>): ByteArray {
        require(userId.isNotBlank()) { "Sign in before backing up." }
        return buildJsonObject {
            put("format", "voiid-message-backup"); put("version", 1); put("userId", userId)
            put("messages", json.encodeToJsonElement(serializer, messages))
        }.toString().encodeToByteArray()
    }
    fun decode(bytes: ByteArray, userId: String): Map<String, List<ChatEngine.DecryptedMessage>> {
        require(bytes.isNotEmpty() && bytes.size <= 50 * 1024 * 1024) { "Invalid backup size." }
        val root = json.parseToJsonElement(bytes.decodeToString(throwOnInvalidSequence = true)).jsonObject
        val versioned = root.containsKey("format")
        val messages = if (versioned) {
            require(root["format"]?.jsonPrimitive?.content == "voiid-message-backup" &&
                root["version"]?.jsonPrimitive?.intOrNull == 1 && root["userId"]?.jsonPrimitive?.content == userId) {
                "This backup belongs to another account or needs a newer app."
            }
            root.getValue("messages").jsonObject
        } else root
        val dates = messages.values.flatMap { it.jsonArray }.mapNotNull { it.jsonObject["createdAt"]?.jsonPrimitive?.doubleOrNull }
        val legacyIOS = !versioned && dates.none { kotlin.math.abs(it) >= 100_000_000_000 }
        val normalized = JsonObject(messages.mapValues { (id, rows) ->
            require(runCatching { UUID.fromString(id).toString().equals(id, ignoreCase = true) }.getOrDefault(false)) { "Invalid conversation in backup." }
            JsonArray(rows.jsonArray.map { element ->
                val row = element.jsonObject.toMutableMap()
                if (legacyIOS) for (key in listOf("createdAt", "deliveredAt", "readAt")) {
                    row[key]?.jsonPrimitive?.doubleOrNull?.let { row[key] = JsonPrimitive(kotlin.math.round((it + 978307200) * 1000).toLong()) }
                }
                if (row["location"] == null || row["location"] == JsonNull) {
                    row["locationJSON"]?.jsonPrimitive?.contentOrNull?.let { value ->
                        val location = json.parseToJsonElement(value).jsonObject
                        row["location"] = buildJsonObject {
                            put("kind", location.getValue("k"))
                            for (key in listOf("lat", "lon", "acc", "label", "expiresAt")) location[key]?.let { put(key, it) }
                            location["s"]?.let { put("shareId", it) }
                            location["cadence"]?.let { put("cadenceSeconds", it) }
                        }
                    }
                }
                JsonObject(row)
            })
        })
        return json.decodeFromJsonElement(serializer, normalized)
    }
    fun merge(local: List<ChatEngine.DecryptedMessage>, restored: List<ChatEngine.DecryptedMessage>): List<ChatEngine.DecryptedMessage> {
        val seen = local.map { it.id }.toMutableSet()
        return local + restored.filter { seen.add(it.id) }
    }
}
