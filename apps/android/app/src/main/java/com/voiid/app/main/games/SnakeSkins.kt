package com.voiid.app.main.games

import androidx.compose.ui.graphics.Color

/**
 * Snake skin catalogue (docs/GAMES_SNAKE_VISUALS.md §2).
 *
 * THE SERVER SENDS AN ID, NOTHING ELSE. What a skin looks like lives here, so adding a
 * colourway is a client release and never a server one — and a client meeting an id it has
 * never heard of falls back to the plain palette colour rather than to nothing.
 *
 * MUST STAY IN SYNC WITH iOS `SnakeSkins.swift`. Band colours and band lengths are the values
 * that decide whether two players see the same arena, so they are duplicated deliberately and
 * identically rather than derived.
 */
data class SnakeSkin(
    /** Colours repeated along the body, head-first. */
    val bands: List<Color>,
    /** World units per band. Roughly one segment (14) unless a pattern wants finer stripes. */
    val bandLength: Float,
    /** Additive halo tint, or null for the body colour's own glow. */
    val glow: Color? = null,
    /** Face glyph drawn on the head, or null to keep the default eyes. */
    val face: String? = null,
)

object SnakeSkins {
    /** The launch set. Five are pure colour data; four carry a face. */
    private val catalogue: Map<String, SnakeSkin> = mapOf(
        "rainbow" to SnakeSkin(
            bands = listOf(
                Color(0xFFFF3B47), Color(0xFFFF8A2B), Color(0xFFFFD93D),
                Color(0xFF5CE65C), Color(0xFF4DA8FF), Color(0xFF5A5AF2),
                Color(0xFF9B5CFF),
            ),
            bandLength = 14f),

        "candy" to SnakeSkin(
            bands = listOf(Color.White, Color(0xFFFF70B8)),
            bandLength = 10f),

        "lava" to SnakeSkin(
            bands = listOf(Color(0xFFFF3B00), Color(0xFFFF8A2B), Color(0xFFFFD93D)),
            bandLength = 12f, glow = Color(0xFFFF731A)),

        "frost" to SnakeSkin(
            bands = listOf(Color(0xFF8DF7C8), Color(0xFF4DA8FF), Color.White),
            bandLength = 16f, glow = Color(0xFF66D9FF)),

        "shadow" to SnakeSkin(
            bands = listOf(Color(0xFF2B2B3F), Color(0xFF4A4A6A)),
            bandLength = 18f, glow = Color(0xFF7359BF)),

        "bunny" to SnakeSkin(
            bands = listOf(Color.White, Color(0xFFF5F5FF)),
            bandLength = 13f, face = "bunny"),

        "corgi" to SnakeSkin(
            bands = listOf(Color(0xFFE8A15C), Color(0xFFFFF1DC)),
            bandLength = 13f, face = "corgi"),

        "lion" to SnakeSkin(
            bands = listOf(Color(0xFFD9913F), Color(0xFFB4762E)),
            bandLength = 15f, face = "lion"),

        "unicorn" to SnakeSkin(
            bands = listOf(
                Color(0xFFFFBFD9), Color(0xFFD9CCFF),
                Color(0xFFBFF2FF), Color(0xFFFFF2BF),
            ),
            bandLength = 12f, glow = Color(0xFFFF73D9), face = "unicorn"),
    )

    /**
     * Resolve a skin id, falling back to a single-band skin in the snake's palette colour.
     *
     * The fallback is what lets an old client meet a new skin without breaking: it still draws
     * a snake, just a plain one.
     */
    fun resolve(id: String?, fallback: Color): SnakeSkin =
        catalogue[id] ?: SnakeSkin(bands = listOf(fallback), bandLength = 14f)
}
