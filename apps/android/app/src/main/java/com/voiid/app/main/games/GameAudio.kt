package com.voiid.app.main.games

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.SoundPool
import android.os.Handler
import android.os.Looper
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
    // ---- shared vocabulary (docs/games/SOUND_DESIGN.md §3) --------------------------------

    /**
     * THE ONE SHARED SOUND. Played unmodified at the moment a player's attempt is intercepted
     * or ended by the opponent, in all four games:
     *
     *   Hand Cricket    a wicket falls — the pick was matched
     *   Tic Tac Toe     your winning threat gets blocked
     *   RPS             your throw is countered
     *   Snake           you are killed by another snake (NOT by the border)
     *
     * A shared sound across four games builds a vocabulary: the player learns in one game what
     * it means and it carries. Four unrelated "you lost that one" sounds teach nothing and make
     * the games feel like four apps stapled to a tab.
     *
     * PLAY IT UNMODIFIED — no per-game pitch offset. Gain may vary per game so it sits
     * correctly in each mix; that is mastering, not identity.
     *
     * Named `catch_shared`, not `catch`: resource names become Java fields and `R.raw.catch`
     * does not compile — aapt2 rejects it as a reserved keyword. One file, one name, spelled
     * around a language keyword.
     */
    const val CATCH = "catch_shared"

    /** The three X variants — TWO STROKES each, with an audible gap. */
    val CHALK_X = listOf("chalk_x_1", "chalk_x_2", "chalk_x_3")
    /**
     * The three O variants — ONE CONTINUOUS SWEEP each.
     *
     * That X and O sound structurally different is the point of the chalk set, not a detail: a
     * player learns to hear whose turn resolved without looking, which is an accessibility win
     * as much as a texture one.
     */
    val CHALK_O = listOf("chalk_o_1", "chalk_o_2", "chalk_o_3")

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

    /** The crowd bed — MediaPlayer, not SoundPool. See [startBed] for why. */
    private var bedPlayer: MediaPlayer? = null
    private var bedName: String? = null

    /** For delayed one-shots (the wicket's 120 ms crowd reaction). See [play]. */
    private val handler = Handler(Looper.getMainLooper())

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

    /**
     * Play [name] after [delayMs].
     *
     * Exists for ONE reason worth stating: a real crowd reacts *after* the event. The wicket
     * stack is `catch` + `wicket_timber` at 0 ms and `crowd_roar` at 120 ms
     * (docs/games/SOUND_DESIGN.md §4.1), and that delay is what sells it — fired together the
     * three read as one mushy noise and the impact is lost entirely.
     *
     * The mute/call/ringer checks run when the sound FIRES, not when it is scheduled: a call
     * that starts inside the delay window must silence the reaction, and [play] already makes
     * exactly that check.
     */
    fun play(name: String, delayMs: Long, pitch: Float = 1f, gain: Float = 1f) {
        handler.postDelayed({ play(name, pitch, gain) }, delayMs)
    }

    /**
     * Pick one of [names] at random and play it.
     *
     * For sounds that fire repeatedly in quick succession — chalk marks land up to nine times
     * in thirty seconds, the most repetition-exposed sound in the app. Chalk is never
     * identical twice, and a single file plus pitch jitter still reads as one file; three
     * genuinely different scrapes do not. [play]'s own +/-3% jitter applies on top.
     */
    fun playAny(names: List<String>, gain: Float = 1f) {
        if (names.isEmpty()) return
        play(names.random(), gain = gain)
    }

    // ---- the crowd bed -------------------------------------------------------------------

    /**
     * The looping stadium bed, on MediaPlayer rather than SoundPool.
     *
     * NOT A SOUNDPOOL SOUND, and this is not a style preference. SoundPool decodes each
     * sample fully into memory and is documented for short clips; the practical ceiling is
     * around 1 MB of decoded PCM per sample on most devices, and the bed is 22 seconds —
     * 1.9 MB decoded. It would load on some phones, fail silently on others, and "the crowd
     * is missing on exactly one device" is the worst possible shape of bug.
     *
     * MediaPlayer streams from the resource and loops natively, which is precisely the job.
     * It costs one extra object and gives seamless looping with a per-call volume that the
     * intensity curve in CricketScreen ramps as the chase tightens.
     *
     * iOS does not need any of this: its bed rides the dedicated `loopVoice` that already
     * exists for Snake's boost_loop.
     */
    fun startBed(context: Context, name: String, gain: Float) {
        if (isMuted || callIsActive() || !ringerAllowsSound()) return
        appContext = context.applicationContext
        val ctx = appContext ?: return

        val existing = bedPlayer
        if (bedName == name && existing != null) {
            runCatching { existing.setVolume(gain, gain) }
            return
        }
        stopBed()

        val resId = ctx.resources.getIdentifier(name, "raw", ctx.packageName)
        if (resId == 0) return
        bedPlayer = runCatching {
            MediaPlayer.create(ctx, resId)?.apply {
                isLooping = true
                setVolume(gain, gain)
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_GAME)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                start()
            }
        }.getOrNull()
        bedName = if (bedPlayer != null) name else null
    }

    /** Adjust the bed's gain without restarting it — the intensity curve calls this per ball. */
    fun setBedGain(gain: Float) {
        bedPlayer?.let { runCatching { it.setVolume(gain, gain) } }
    }

    fun stopBed() {
        bedPlayer?.let { p ->
            runCatching { p.stop() }
            runCatching { p.release() }
        }
        bedPlayer = null
        bedName = null
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
     * screen. SoundPool has no "stop all" call, so this stops every id this game loaded.
     * The bed and any pending delayed one-shot go with it: a crowd still roaring over the
     * Games tab, or a wicket reaction landing 120 ms after the player left, are exactly the
     * kind of thing a "stop everything" call exists to make impossible. */
    fun stopAll() {
        stopCurrentLoop()
        stopBed()
        handler.removeCallbacksAndMessages(null)
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

    /**
     * File-name groups per game, matching the catalogues in tools/gamesounds/synth.py
     * (abstract) and tools/gamesounds/physical.py (physical), and iOS GameAudio.swift's
     * identical table. The two platform tables must not drift, or a sound plays on one only.
     *
     * `catch` is in EVERY game's list on purpose: it is the one shared sound
     * (docs/games/SOUND_DESIGN.md §3), played unmodified at the moment a player's attempt is
     * intercepted, and a vocabulary that only exists in three of the four games teaches
     * nothing.
     *
     * `crowd_base` is absent — it is not a SoundPool sound. See [startBed].
     */
    private fun soundNames(game: String): List<String> = when (game) {
        "snake" -> listOf(
            "eat_1", "eat_2", "eat_3", "eat_4", "eat_big",
            "boost_start", "boost_loop", "boost_end",
            "kill", "death", "spawn", "border_warn", "rank_up", "match_end",
            CATCH,
        )
        "tictactoe" -> listOf(
            "chalk_x_1", "chalk_x_2", "chalk_x_3",
            "chalk_o_1", "chalk_o_2", "chalk_o_3",
            "chalk_line", "chalk_stub", "chalk_erase",
            "mark_invalid", "win_line", "draw", CATCH,
        )
        "rps" -> listOf(
            "countdown_1", "countdown_2", "countdown_3",
            "hand_pump", "hand_reveal", "reveal",
            "round_win", "round_lose", "round_tie", CATCH,
        )
        "cricket" -> listOf(
            "pick", "reveal", "innings",
            "bat_soft", "bat_crack", "bat_block",
            "wicket_timber", CATCH,
            "crowd_cheer", "crowd_roar", "crowd_gasp", "crowd_groan", "crowd_applause",
        )
        // Three variants of splash and hit_metal, chosen at random with the existing varispeed:
        // a match contains 40–90 of these, and SOUND_DESIGN.md §4.3 makes exactly this argument
        // for chalk — without variation "it becomes machine-like by move four".
        "seabattle" -> listOf(
            "fire_launch",
            "splash_1", "splash_2", "splash_3",
            "hit_metal_1", "hit_metal_2", "hit_metal_3",
            "sink_groan", "your_turn", "place_thud", "error",
            CATCH,
        )
        // hop is the most-triggered sound in the game — four variants plus the engine's own
        // pitch jitter, per SOUND_DESIGN.md §4.3's chalk argument.
        "ludo" -> listOf(
            "die_roll", "die_settle",
            "hop_1", "hop_2", "hop_3", "hop_4",
            "enter", "capture", "home", "extra_turn", "three_sixes", "pass",
            "your_turn", "rank_up", "match_end",
            CATCH,
        )
        "ui" -> listOf("tap", "sheet_open", "sheet_close", "match_found", "invite_arrive", "error")
        else -> emptyList()
    }
}
