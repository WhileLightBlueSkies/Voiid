package com.voiid.app.main.games

import android.content.Context

/**
 * Per-device game preferences (docs/games/CROSS_CUTTING.md §12).
 *
 * There were no game settings at all. `GameAudio.isMuted` existed and persisted and simply had
 * no UI — so the only way to silence a match was to silence the phone. That was liveable while
 * the palette was a handful of synthesised bleeps; with a stadium crowd running under every
 * cricket match it is not.
 *
 * SOUND LIVES IN GameAudio, not here, because it was already there and moving it would orphan
 * the existing preference key. This object owns the HAPTICS toggle and is the single place the
 * settings sheet reads and writes both.
 *
 * Both default ON. Feedback is part of the product, not an opt-in — the value is stored as
 * "enabled" and a missing key therefore reads as enabled on a fresh install, which is why the
 * default argument below is `true` rather than relying on Kotlin's boolean zero value.
 */
object GameSettings {
    private const val PREFS = "voiid_game_settings"
    private const val KEY_HAPTICS = "haptics_enabled_v1"

    fun hapticsEnabled(context: Context): Boolean =
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_HAPTICS, true)

    fun setHapticsEnabled(context: Context, enabled: Boolean) {
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_HAPTICS, enabled)
            .apply()
    }

    /**
     * Sound is [GameAudio]'s own persisted flag, wrapped here so the settings sheet has one
     * place to talk to rather than two. Note the inversion: GameAudio stores `isMuted`, and
     * every UI in this app phrases the control positively ("Sound on").
     */
    fun soundEnabled(context: Context): Boolean {
        GameAudio.preload(context, "ui")   // binds GameAudio's app context before reading
        return !GameAudio.isMuted
    }

    fun setSoundEnabled(context: Context, enabled: Boolean) {
        GameAudio.preload(context, "ui")
        GameAudio.isMuted = !enabled
        if (!enabled) GameAudio.stopAll()   // silence anything already ringing out
    }
}
