package com.voiid.app.main.games

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.SoundPool
import android.os.SystemClock
import com.voiid.app.net.CallManager
import com.voiid.app.net.GroupCallManager

/**
 * Sound playback for in-match game events (docs/GAMES_AUDIO.md). Sits next to
 * GameHaptics.kt the same way that file sits next to VoiidHaptics: a dedicated layer for game
 * feedback, not a repurposing of the call/notification audio in net/CallTones.kt.
 *
 * WHY SoundPool, NOT MediaPlayer. MediaPlayer is one instance per sound with real start
 * latency — fine for a ringtone, wrong for Snake's `eat`, which can fire several times a
 * second. SoundPool decodes once and plays with per-call pitch/volume and near-zero trigger
 * latency (docs/GAMES_AUDIO.md §5).
 *
 * THE ONE HARD RULE (docs/GAMES_AUDIO.md §2): a game sound must never play over a call.
 * `AudioAttributes.USAGE_GAME` — never `USAGE_VOICE_COMMUNICATION` — plus an explicit check
 * against [CallManager]/[GroupCallManager] before every play call, mirroring how
 * [com.voiid.app.net.CallTones] keeps call audio on its own dedicated stream.
 */
object GameAudio {
    private const val MAX_STREAMS = 16
    private const val PREFS_NAME = "voiid_game_audio"
    private const val PREF_KEY = "sound_enabled_v1"

    private var appContext: Context? = null

    private val pool = SoundPool.Builder()
        .setMaxStreams(MAX_STREAMS)
        .setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_GAME)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
        )
        .build()

    /** resource-name -> SoundPool id. */
    private val soundIds = HashMap<String, Int>()
    /** SoundPool.load() is ASYNC — playing an id before OnLoadCompleteListener fires is
     * silently a no-op. Track which ids have actually finished loading. */
    private val loadedIds = HashSet<Int>()
    /** The one currently-looping stream (boost_loop / border_warn), so it can be stopped by
     * name rather than by a caller having to hold onto a raw stream id. */
    private var loopStreamId: Int? = null
    private var loopSoundName: String? = null

    private val lastPlayedAt = HashMap<String, Long>()
    /** Per-sound wall-clock floor in ms, matching iOS GameAudio.swift's identical table
     * (docs/GAMES_AUDIO.md §8-10's "min gap" column). */
    private val minGapMs = mapOf(
        "eat_1" to 60L, "eat_2" to 60L, "eat_3" to 60L, "eat_4" to 60L, "eat_big" to 80L,
        "kill" to 150L, "rank_up" to 500L,
    )

    init {
        pool.setOnLoadCompleteListener { _, sampleId, status ->
            if (status == 0) loadedIds.add(sampleId)
        }
    }

    var isMuted: Boolean
        get() = appContext?.let {
            !it.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getBoolean(PREF_KEY, true)
        } ?: false
        set(value) {
            appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                ?.edit()?.putBoolean(PREF_KEY, !value)?.apply()
        }

    /** Load every sound this game needs. Idempotent — safe to call again on re-entering the
     * same game screen; resource names already loaded are skipped. */
    fun preload(context: Context, game: String) {
        appContext = context.applicationContext
        val ctx = appContext ?: return
        val resources = ctx.resources
        for (name in soundNames(game)) {
            if (soundIds.containsKey(name)) continue
            val resId = resources.getIdentifier(name, "raw", ctx.packageName)
            if (resId == 0) continue
            val soundId = pool.load(ctx, resId, 1)
            soundIds[name] = soundId
        }
    }

    /** Play [name] (the raw resource base name, e.g. "eat_1", "kill") at [pitch] (1.0 =
     * recorded pitch, SoundPool clamps to 0.5-2.0) and [gain] (0-1, on top of the file's own
     * §11 mix trim). */
    fun play(name: String, pitch: Float = 1f, gain: Float = 1f) {
        if (isMuted || callIsActive() || !ringerAllowsSound()) return
        val id = soundIds[name] ?: return
        if (id !in loadedIds) return

        val floor = minGapMs[name]
        if (floor != null) {
            val now = SystemClock.elapsedRealtime()
            val last = lastPlayedAt[name]
            if (last != null && now - last < floor) return
            lastPlayedAt[name] = now
        }

        // +/-3% random jitter on top of the caller's pitch — §3's "automatic pitch jitter"
        // removes most of the machine-gun effect on a sound like eat that retriggers rapidly.
        val jittered = (pitch * (0.97f + kotlin.random.Random.nextFloat() * 0.06f))
            .coerceIn(0.5f, 2.0f)
        pool.play(id, gain, gain, /* priority */ 1, /* loop */ 0, jittered)
    }

    /** Start (or update the gain of) a looping sound — boost_loop / border_warn
     * (docs/GAMES_AUDIO.md §8.4/§8.9's "single-instance loops, never retriggered"). Calling
     * this repeatedly for the SAME name while a state is held (e.g. boost) does not restart
     * the loop, only adjusts gain — a caller can call it unconditionally every frame rather
     * than tracking its own "did I already start this" edge. */
    fun startLoop(name: String, gain: Float = 1f) {
        if (isMuted || callIsActive() || !ringerAllowsSound()) return
        val id = soundIds[name] ?: return
        if (id !in loadedIds) return

        if (loopSoundName == name && loopStreamId != null) {
            pool.setVolume(loopStreamId!!, gain, gain)
            return
        }
        stopCurrentLoop()
        val streamId = pool.play(id, gain, gain, 1, -1, 1f)   // loop = -1: infinite
        if (streamId != 0) {
            loopStreamId = streamId
            loopSoundName = name
        }
    }

    /** Stop the current loop, IF [name] matches what's playing — a stale stop call from a
     * screen that no longer owns the loop must not silence one some other caller just
     * started. */
    fun stopLoop(name: String) {
        if (loopSoundName == name) stopCurrentLoop()
    }

    private fun stopCurrentLoop() {
        loopStreamId?.let { pool.stop(it) }
        loopStreamId = null
        loopSoundName = null
    }

    /** Stop everything — used on match exit so a lingering loop doesn't play into the next
     * screen. SoundPool has no "stop all" call, so this stops every id this game loaded. */
    fun stopAll() {
        stopCurrentLoop()
    }

    /** Release this game's loaded sounds on screen exit — bounds memory to "sounds for the
     * game currently open" rather than accumulating every game's set for the app's life. */
    fun release(game: String) {
        stopAll()
        for (name in soundNames(game)) {
            soundIds.remove(name)?.let { id ->
                loadedIds.remove(id)
                pool.unload(id)
            }
        }
    }

    private fun callIsActive(): Boolean =
        CallManager.state.value != null || GroupCallManager.isActive

    /** Mirrors CallTones' silent/vibrate check — games must respect ringer mode exactly like
     * every other non-call sound in this app (docs/GAMES_AUDIO.md §5's "mirror CallTones.kt"). */
    private fun ringerAllowsSound(): Boolean {
        val ctx = appContext ?: return true
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return true
        return runCatching { am.ringerMode }.getOrDefault(AudioManager.RINGER_MODE_NORMAL) ==
            AudioManager.RINGER_MODE_NORMAL
    }

    /** File-name groups per game, matching tools/gamesounds/synth.py's catalogue and iOS
     * GameAudio.swift's identical table. */
    private fun soundNames(game: String): List<String> = when (game) {
        "snake" -> listOf(
            "eat_1", "eat_2", "eat_3", "eat_4", "eat_big",
            "boost_start", "boost_loop", "boost_end",
            "kill", "death", "spawn", "border_warn", "rank_up", "match_end",
        )
        "tictactoe" -> listOf("mark_x", "mark_o", "mark_invalid", "win_line", "draw")
        "rps" -> listOf(
            "countdown_1", "countdown_2", "countdown_3", "reveal",
            "round_win", "round_lose", "round_tie",
        )
        "cricket" -> listOf(
            "pick", "runs_1", "runs_2", "runs_3", "runs_4", "runs_5", "runs_6",
            "four", "six", "wicket", "innings",
        )
        "ui" -> listOf("tap", "sheet_open", "sheet_close", "match_found", "invite_arrive", "error")
        else -> emptyList()
    }
}
