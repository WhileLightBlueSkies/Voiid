package com.voiid.app.main.games.ludo

import android.content.Context
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

/**
 * Parsing for the schema-v2 wire envelope (§7.2):
 *   { type, match_id, game:"ludo", schema_version:2, seq, server_now, payload:{ ludoV2:{...} } }
 *
 * The payload is built per recipient by the games service — `displayName` is already the
 * viewer's projection. This parser never sees a raw user id and must never invent one.
 */
object LudoWire {

    fun parseState(seq: Int, payload: JsonObject): LudoGameState? {
        val v2 = payload["ludoV2"] as? JsonObject ?: return null
        val seats = v2.arr("seats")?.mapNotNull { s ->
            val o = s as? JsonObject ?: return@mapNotNull null
            LudoSeatView(
                seat = o.int("seat") ?: return@mapNotNull null,
                seatId = o.str("seatId") ?: "",
                color = when (o.str("color")) {
                    "green" -> LudoSeatColor.GREEN
                    "yellow" -> LudoSeatColor.YELLOW
                    "blue" -> LudoSeatColor.BLUE
                    else -> LudoSeatColor.RED
                },
                displayName = o.str("displayName") ?: "",
                participation = o.str("participation") ?: "waiting",
                connection = o.str("connection") ?: "disconnected",
                timeoutStreak = o.int("timeoutStreak") ?: 0,
                finishedPawns = o.int("finishedPawns") ?: 0,
                captures = o.int("captures") ?: 0,
            )
        } ?: return null

        val tokens = v2.arr("tokens")?.map { row ->
            (row as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.intOrNull } ?: emptyList()
        } ?: return null

        val turn = (v2["turn"] as? JsonObject)?.let { t ->
            LudoTurnView(
                seat = t.int("seat") ?: return@let null,
                serial = t.int("serial") ?: 0,
                phase = t.str("phase") ?: "awaitingRoll",
                opensAt = t.long("opensAt") ?: 0L,
                deadlineAt = t.long("deadlineAt") ?: 0L,
                sixStreak = t.int("sixStreak") ?: 0,
                rollId = t.str("rollId"),
                value = t.int("value"),
                legalTokenIds = t.arr("legalTokenIds")?.mapNotNull {
                    (it as? JsonPrimitive)?.intOrNull
                } ?: emptyList(),
                automated = t.bool("automated") ?: false,
            )
        }

        val lastAction = (v2["lastAction"] as? JsonObject)?.let { a ->
            LudoAction(
                id = a.str("id") ?: return@let null,
                type = a.str("type") ?: "move",
                committedAt = a.long("committedAt") ?: 0L,
                presentationEndsAt = a.long("presentationEndsAt") ?: 0L,
                actorSeat = a.int("actorSeat") ?: -1,
                fromSeat = a.int("fromSeat"),
                roll = (a["roll"] as? JsonObject)?.let { r ->
                    LudoAction.RollInfo(
                        rollId = r.str("rollId") ?: "",
                        value = r.int("value") ?: 0,
                        auto = r.bool("auto") ?: false,
                    )
                },
                move = (a["move"] as? JsonObject)?.let { m ->
                    LudoMovePayload(
                        tokenId = m.int("tokenId") ?: return@let null,
                        from = m.int("from") ?: 0,
                        to = m.int("to") ?: 0,
                        path = m.arr("path")?.mapNotNull { (it as? JsonPrimitive)?.intOrNull } ?: emptyList(),
                        captured = (m["captured"] as? JsonObject)?.let { c ->
                            LudoMovePayload.CapturedPawn(
                                seat = c.int("seat") ?: return@let null,
                                tokenId = c.int("tokenId") ?: 0,
                                from = c.int("from") ?: 0,
                                to = c.int("to") ?: 0,
                            )
                        },
                    )
                },
            )
        }

        return LudoGameState(
            schemaVersion = v2.int("schemaVersion") ?: LudoRules.SCHEMA_VERSION,
            rulesVersion = v2.str("rulesVersion") ?: LudoRules.RULES_VERSION,
            mode = v2.str("mode") ?: "four",
            status = v2.str("status") ?: "active",
            serverNow = v2.long("serverNow") ?: System.currentTimeMillis(),
            viewerSeat = v2.int("viewerSeat"),
            seats = seats,
            tokensPerSeat = v2.int("tokensPerSeat") ?: 4,
            tokens = tokens,
            turn = turn,
            lastAction = lastAction,
            winnerSeat = v2.int("winnerSeat"),
            endReason = v2.str("endReason"),
            seedCommitment = v2.str("seedCommitment"),
            seq = seq,
        )
    }

    private fun JsonObject.str(k: String): String? =
        (this[k] as? JsonPrimitive)?.contentOrNull

    private fun JsonObject.int(k: String): Int? =
        (this[k] as? JsonPrimitive)?.intOrNull

    private fun JsonObject.long(k: String): Long? =
        (this[k] as? JsonPrimitive)?.contentOrNull?.toLongOrNull()

    private fun JsonObject.bool(k: String): Boolean? =
        (this[k] as? JsonPrimitive)?.booleanOrNull

    private fun JsonObject.arr(k: String): JsonArray? = this[k] as? JsonArray
}
