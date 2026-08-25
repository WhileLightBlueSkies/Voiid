package com.voiid.app

import com.voiid.app.main.games.ludo.LudoBoardGeometry
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.double
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Cross-platform geometry fixture parity (LUDO_GAME_SPEC.md §19).
 *
 * The ONE checked-in fixture — packages/design-tokens/fixtures/ludo_board_v3.json, generated
 * from the backend's own tables and synced into app/src/test/resources by
 * tools/sync-ludo-fixture.sh — pins every cell of the 225-node board. If this test fails, a
 * client has drifted from the shared geometry: centers would disagree between iOS, Android and
 * the server's route tables.
 *
 * Uses kotlinx.serialization instead of org.json: local JVM unit tests have no android.jar
 * implementations, so the parity test stays runnable on CI without Robolectric.
 */
class LudoGeometryFixtureTest {

    private fun loadFixture() =
        Json.parseToJsonElement(
            javaClass.classLoader!!
                .getResourceAsStream("ludo_board_v3.json")!!
                .bufferedReader().readText()
        ).jsonObject

    @Test
    fun `fixture holds 225 keyed cells matching the generated model`() {
        val fixture = loadFixture()
        assertEquals(15, fixture["boardSide"]!!.jsonPrimitive.int)
        val cells = fixture["cells"]!!.jsonArray
        assertEquals(225, cells.size)

        val fixtureCells = cells.map { el ->
            val o = el.jsonObject
            mapOf<String, Any?>(
                "id" to o["id"]!!.jsonPrimitive.content,
                "x" to o["x"]!!.jsonPrimitive.int,
                "y" to o["y"]!!.jsonPrimitive.int,
                "role" to o["role"]!!.jsonPrimitive.content,
                "seat" to o["seat"]?.jsonPrimitive?.let { if (it.content == "null") null else it.int },
                "trackIndex" to o["trackIndex"]?.jsonPrimitive?.let { if (it.content == "null") null else it.int },
                "homeStep" to o["homeStep"]?.jsonPrimitive?.let { if (it.content == "null") null else it.int },
                "isSafe" to o["isSafe"]!!.jsonPrimitive.boolean,
                "decoration" to o["decoration"]!!.jsonPrimitive.content,
            )
        }
        assertTrue(
            "generated 15×15 model must equal the committed fixture cell-for-cell",
            LudoBoardGeometry.selfCheck(fixtureCells),
        )
    }

    @Test
    fun `track coords round-trip against cell nodes`() {
        val track = loadFixture()["trackCoords"]!!.jsonArray
        assertEquals(52, track.size)
        for ((i, el) in track.withIndex()) {
            val o = el.jsonObject
            val node = LudoBoardGeometry.cell(o["x"]!!.jsonPrimitive.int, o["y"]!!.jsonPrimitive.int)
            assertEquals(LudoBoardGeometry.Role.SHARED_TRACK, node.role)
            assertEquals(i, node.trackIndex)
        }
    }

    @Test
    fun `home lanes and yard slots match per seat`() {
        val fixture = loadFixture()
        for (seat in 0..3) {
            val lane = fixture["homeLaneCoords"]!!.jsonArray[seat].jsonArray
            assertEquals(5, lane.size)
            for ((step, el) in lane.withIndex()) {
                val c = el.jsonObject
                val node = LudoBoardGeometry.cell(c["x"]!!.jsonPrimitive.int, c["y"]!!.jsonPrimitive.int)
                assertEquals(LudoBoardGeometry.Role.HOME_LANE, node.role)
                assertEquals(seat, node.seat)
                assertEquals(step, node.homeStep)
            }
            assertEquals(4, fixture["yardSlots"]!!.jsonArray[seat].jsonArray.size)
        }
    }

    @Test
    fun `border anchors are the normalized clockwise fractions`() {
        val anchors = loadFixture()["borderAnchors"]!!.jsonArray
        for ((i, el) in anchors.withIndex()) {
            assertEquals(
                el.jsonObject["fraction"]!!.jsonPrimitive.double,
                LudoBoardGeometry.BORDER_ANCHORS[i].toDouble(),
                1e-9,
            )
        }
    }
}

private operator fun kotlinx.serialization.json.JsonElement.get(key: String) =
    jsonObject[key]
