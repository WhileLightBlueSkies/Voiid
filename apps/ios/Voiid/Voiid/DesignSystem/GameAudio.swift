//
//  GameAudio.swift
//  Voiid
//
//  Sound playback for in-match game events (docs/GAMES_AUDIO.md). Sits next to
//  GameHaptics.swift the same way that file sits next to Haptics.swift: a dedicated layer for
//  game feedback, not a repurposing of the call/message audio code.
//
//  WHY AVAudioEngine, NOT AVAudioPlayer. AVAudioPlayer (used elsewhere in this app for call
//  tones and voice notes) is file-oriented, allocates per instance, and has unpredictable
//  start latency — fine for a ringback tone, wrong for Snake's `eat`, which can fire several
//  times a second. AVAudioEngine with pre-decoded PCM buffers and a pool of player nodes gives
//  sub-frame trigger latency and per-voice pitch control (docs/GAMES_AUDIO.md §4).
//
//  THE ONE HARD RULE (docs/GAMES_AUDIO.md §2): a game sound must never play over a call. On
//  iOS the audio session category is PROCESS-GLOBAL — calling setCategory while a call is
//  live would reconfigure the call's own session and can drop the mic. Every entry point here
//  checks CallService/GroupCallService first and no-ops if either is active.
//

import AVFoundation

final class GameAudio {
    static let shared = GameAudio()

    // MARK: - Shared vocabulary (docs/games/SOUND_DESIGN.md §3)

    /// THE ONE SHARED SOUND. Played unmodified at the moment a player's attempt is
    /// intercepted or ended by the opponent, in all four games:
    ///
    ///   Hand Cricket    a wicket falls — the pick was matched
    ///   Tic Tac Toe     your winning threat gets blocked
    ///   RPS             your throw is countered
    ///   Snake           you are killed by another snake (NOT by the border)
    ///
    /// A shared sound across four games builds a vocabulary: the player learns in one game
    /// what it means and it carries. Four unrelated "you lost that one" sounds teach nothing
    /// and make the games feel like four apps stapled to a tab.
    ///
    /// PLAY IT UNMODIFIED — no per-game pitch offset. The varispeed exists for Snake's `eat`;
    /// using it here would fork the identity, which is the one thing that destroys the point.
    /// Gain may vary per game so it sits correctly in each mix; that is mastering, not
    /// identity.
    ///
    /// The file is `catch_shared`, not `catch`: Android turns resource names into Java fields
    /// and `R.raw.catch` does not compile — aapt2 rejects the name outright. One file, one
    /// name, spelled around a language keyword.
    static let catchShared = "catch_shared"

    /// The three X variants — TWO STROKES each, with an audible gap.
    /// Picked at random per placement by `playAny`.
    static let chalkX = ["chalk_x_1", "chalk_x_2", "chalk_x_3"]
    /// The three O variants — ONE CONTINUOUS SWEEP each.
    ///
    /// That X and O sound structurally different is the point of the chalk set, not a detail:
    /// a player learns to hear whose turn resolved without looking, which is an accessibility
    /// win as much as a texture one.
    static let chalkO = ["chalk_o_1", "chalk_o_2", "chalk_o_3"]

    /// Persisted mute toggle (docs/GAMES_AUDIO.md §12). Default on — sound is part of the
    /// product, not an opt-in.
    static var isMuted: Bool {
        get { !UserDefaults.standard.bool(forKey: "voiid.gameSoundEnabled_v1_default_on") ? false : true }
        set { UserDefaults.standard.set(!newValue, forKey: "voiid.gameSoundEnabled_v1_default_on") }
    }

    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()

    private struct Voice {
        let player: AVAudioPlayerNode
        let speed: AVAudioUnitVarispeed
    }
    private static let voiceCount = 16
    private var voices: [Voice] = []
    /// Round-robins voices rather than searching for a free one — simpler, and at 16 voices
    /// against Snake's own polyphony caps (§8's "eat capped at 3 concurrent") starvation
    /// never happens in practice; the oldest voice is always the safest one to steal.
    private var nextVoice = 0

    /// A voice DEDICATED to looping sounds (boost_loop, border_warn — §8.4/§8.9's "single-
    /// instance loops with ramped gain, never retriggered"), kept OUT of the round-robin pool
    /// above. A loop that could be silently stolen mid-match by an unrelated one-shot would be
    /// a bug that only shows up as "the boost sound randomly cuts out," which is exactly the
    /// kind of thing worth a dedicated voice to make structurally impossible.
    private var loopVoice: Voice?
    private var currentLoopName: String?

    /// Decoded buffers, keyed by filename without extension. Loaded once per game on
    /// `preload`, never per-play — decoding on first play is a 10-50ms hitch at exactly the
    /// moment something exciting happened (§3's "preload, never load on demand").
    private var buffers: [String: AVAudioPCMBuffer] = [:]

    /// Per-sound wall-clock floor, so a caller never has to remember its own cooldown — same
    /// reasoning as GameHaptics.eat()'s internal throttle. Values are the "min gap" column
    /// from docs/GAMES_AUDIO.md §8-10; sounds not listed here have no floor.
    private var lastPlayedAt: [String: TimeInterval] = [:]
    private static let minGap: [String: TimeInterval] = [
        "eat_1": 0.06, "eat_2": 0.06, "eat_3": 0.06, "eat_4": 0.06, "eat_big": 0.08,
        "kill": 0.15, "rank_up": 0.5,
    ]

    private var configuredSession = false

    /// Bumped by `stopAll`, so a delayed one-shot scheduled before a match exit does not fire
    /// after it. See `play(_:after:)`.
    private var generation: UInt64 = 0

    /// The format every generated sound actually is (tools/gamesounds/synth.py: 16-bit mono
    /// WAV, 44.1kHz — docs/GAMES_AUDIO.md §6). Connecting the graph with `format: nil` wires
    /// each node using the ENGINE's format at connect time — which, before any file has been
    /// loaded, defaults to the hardware output format and is virtually always STEREO. A mono
    /// buffer later scheduled onto a bus wired for stereo is a hard AVAudioEngine crash: an
    /// Objective-C NSException, not a throwing Swift call, so `try?` around `scheduleBuffer`
    /// cannot catch it and the process dies. THIS WAS THE SNAKE-SCREEN CRASH. Connecting every
    /// node explicitly with the real format, up front, is what makes every later
    /// `scheduleBuffer` call format-compatible with the bus it lands on.
    private static let pcmFormat = AVAudioFormat(
        standardFormatWithSampleRate: 44100, channels: 1)!

    private init() {
        engine.attach(mixer)
        engine.connect(mixer, to: engine.mainMixerNode, format: Self.pcmFormat)

        for _ in 0..<Self.voiceCount {
            let player = AVAudioPlayerNode()
            let speed = AVAudioUnitVarispeed()
            engine.attach(player)
            engine.attach(speed)
            engine.connect(player, to: speed, format: Self.pcmFormat)
            engine.connect(speed, to: mixer, format: Self.pcmFormat)
            voices.append(Voice(player: player, speed: speed))
        }

        let loopPlayer = AVAudioPlayerNode()
        let loopSpeed = AVAudioUnitVarispeed()
        engine.attach(loopPlayer)
        engine.attach(loopSpeed)
        engine.connect(loopPlayer, to: loopSpeed, format: Self.pcmFormat)
        engine.connect(loopSpeed, to: mixer, format: Self.pcmFormat)
        loopVoice = Voice(player: loopPlayer, speed: loopSpeed)

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleConfigChange),
            name: .AVAudioEngineConfigurationChange, object: nil)
    }

    /// Load every sound this game needs. Idempotent — call again on re-entering the same
    /// game screen and it no-ops for names already resolved. `game` is a name filter matching
    /// the file prefix groups in tools/gamesounds/synth.py (e.g. "snake" loads eat/kill/death/
    /// spawn/boost*, not the board-game or shared-UI sounds a match will never touch).
    func preload(for game: String) {
        let names = Self.soundNames(for: game)
        var needsStart = false
        for name in names where buffers[name] == nil {
            guard let buffer = Self.loadBuffer(named: name) else { continue }
            buffers[name] = buffer
            needsStart = true
        }
        if needsStart { ensureEngineRunning() }
    }

    /// Play `name` (the file's base name, e.g. "eat_1", "kill", "boost_loop") at `pitch`
    /// (1.0 = recorded pitch) and `gain` (0-1, applied on top of the file's own §11 mix trim
    /// — the file itself is already normalized, this is the CALLER's relative emphasis).
    func play(_ name: String, pitch: Float = 1.0, gain: Float = 1.0) {
        guard !Self.isMuted else { return }
        guard !callIsActive else { return }
        guard let buffer = buffers[name] else { return }

        let now = CACurrentMediaTime()
        if let floor = Self.minGap[name] {
            if let last = lastPlayedAt[name], now - last < floor { return }
            lastPlayedAt[name] = now
        }

        guard configureSessionIfNeeded() else { return }
        ensureEngineRunning()

        let voice = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count

        // ±3% random jitter on top of the caller's pitch — §3's "automatic pitch jitter...
        // removes most of the machine-gun effect" for a sound like `eat` that retriggers
        // rapidly and would otherwise sound identical every time.
        voice.speed.rate = pitch * Float.random(in: 0.97...1.03)
        voice.player.volume = gain

        voice.player.stop()
        voice.player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        voice.player.play()
    }

    /// Play `name` after `delay` seconds.
    ///
    /// Exists for ONE reason worth stating: a real crowd reacts *after* the event. The wicket
    /// stack is `catch` + `wicket_timber` at 0 ms and `crowd_roar` at 120 ms
    /// (docs/games/SOUND_DESIGN.md §4.1), and that delay is what sells it — fired together
    /// the three read as one mushy noise and the impact is lost entirely.
    ///
    /// The mute/call checks deliberately run when the sound FIRES, not when it is scheduled:
    /// a call that starts inside the delay window must silence the reaction, and `play`
    /// already makes exactly that check.
    func play(_ name: String, after delay: TimeInterval, pitch: Float = 1.0, gain: Float = 1.0) {
        let scheduled = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == scheduled else { return }
            self.play(name, pitch: pitch, gain: gain)
        }
    }

    /// Pick one of `names` at random and play it.
    ///
    /// For sounds that fire repeatedly in quick succession — chalk marks land up to nine
    /// times in thirty seconds, the most repetition-exposed sound in the app. Chalk is never
    /// identical twice, and a single file plus pitch jitter still reads as one file; three
    /// genuinely different scrapes do not. `play`'s own ±3% jitter applies on top.
    func playAny(_ names: [String], gain: Float = 1.0) {
        guard let name = names.randomElement() else { return }
        play(name, gain: gain)
    }

    /// Start (or update the gain of) a looping sound. Idempotent for the SAME name — calling
    /// this every frame while a state is true (e.g. boost held) does not restart the loop,
    /// only adjusts gain, so a caller can call it unconditionally rather than tracking its
    /// own "did I already start this" edge.
    func startLoop(_ name: String, gain: Float = 1.0) {
        guard !Self.isMuted, !callIsActive, let buffer = buffers[name], let loopVoice else { return }
        if currentLoopName == name {
            loopVoice.player.volume = gain
            return
        }
        guard configureSessionIfNeeded() else { return }
        ensureEngineRunning()
        currentLoopName = name
        loopVoice.player.volume = gain
        loopVoice.player.stop()
        loopVoice.player.scheduleBuffer(buffer, at: nil, options: .loops)
        loopVoice.player.play()
    }

    /// Stop the current loop, if `name` matches what's playing (a stale stop call — e.g. from
    /// a screen that no longer owns the loop it thinks it does — must not silence a loop some
    /// other caller just started).
    func stopLoop(_ name: String) {
        guard currentLoopName == name, let loopVoice else { return }
        loopVoice.player.stop()
        currentLoopName = nil
    }

    /// Stop everything immediately — used on match exit so a lingering loop doesn't keep
    /// playing into the next screen.
    ///
    /// `generation` also invalidates any pending delayed one-shot: a wicket's crowd reaction
    /// landing 120 ms after the player left the match is exactly what this call exists to
    /// make impossible.
    func stopAll() {
        generation &+= 1
        for voice in voices { voice.player.stop() }
        loopVoice?.player.stop()
        currentLoopName = nil
    }

    /// Release this game's buffers on screen exit. Not strictly required (16 voices x a few
    /// KB of PCM is nothing), but keeps memory scoped to "sounds for the game currently open"
    /// rather than accumulating every game's set for the life of the app.
    func release(for game: String) {
        stopAll()
        for name in Self.soundNames(for: game) { buffers.removeValue(forKey: name) }
    }

    // MARK: - Session

    private var callIsActive: Bool {
        CallService.shared.active != nil || GroupCallService.shared.isActive
    }

    /// Configure the session ONCE, and never while a call is live — see this file's header.
    /// `.ambient` (not `.playback`) is what makes the hardware silent switch work; a casual
    /// game must respect it, unlike a ringtone.
    private func configureSessionIfNeeded() -> Bool {
        guard !callIsActive else { return false }
        guard !configuredSession else { return true }
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            configuredSession = true
            return true
        } catch {
            return false
        }
    }

    private func ensureEngineRunning() {
        guard !engine.isRunning else { return }
        try? engine.start()
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            stopAll()
        case .ended:
            // Only resume if nothing else (a call) claimed the session in the meantime.
            if !callIsActive { ensureEngineRunning() }
        @unknown default:
            break
        }
    }

    @objc private func handleConfigChange(_ note: Notification) {
        // Headphones plugged/unplugged mid-match tears down the graph's route; rebuild it.
        ensureEngineRunning()
    }

    // MARK: - Loading

    private static func loadBuffer(named name: String) -> AVAudioPCMBuffer? {
        // WAV FIRST, THEN .m4a. docs/GAMES_AUDIO.md §6's format table has always said
        // one-shots over 500 ms ship as AAC, and this only ever looked for .wav — so the
        // long sounds' .m4a copies sat in the bundle unread, and the crowd bed (22 s, AAC
        // only, because as a WAV it is 1.9 MB against a 4 MB budget) could not load at all.
        // Order matters: .wav wins where both exist, which keeps every previously-loading
        // sound loading from exactly the same file it did before.
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav")
                ?? Bundle.main.url(forResource: name, withExtension: "m4a") else { return nil }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }

        // MUST match the graph's wired format exactly (pcmFormat above) or scheduling this
        // buffer onto a voice is the crash this whole property exists to prevent — see
        // pcmFormat's doc comment. Every file synth.py and physical.py generate is
        // mono/44.1kHz by construction and tools/gamesounds/verify.py asserts it across both
        // platforms' asset folders, so this should never fire; it exists so a future sound
        // generated at the wrong rate fails LOUDLY as "silent, sound missing" instead of
        // taking the whole app down the next time GameAudio.play() is called.
        guard file.processingFormat.channelCount == pcmFormat.channelCount,
              file.processingFormat.sampleRate == pcmFormat.sampleRate else {
            assertionFailure(
                "GameAudio: \(name).wav is \(file.processingFormat) — expected \(pcmFormat). " +
                "Regenerate with tools/gamesounds/synth.py.")
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(file.length)
        ) else { return nil }
        do {
            try file.read(into: buffer)
            return buffer
        } catch {
            return nil
        }
    }

    /// File-name groups per game, matching the catalogues in tools/gamesounds/synth.py
    /// (abstract) and tools/gamesounds/physical.py (physical). Android's identical table is
    /// in GameAudio.kt — the two must not drift, or a sound plays on one platform only.
    ///
    /// `catch` is in EVERY game's list on purpose: it is the one shared sound
    /// (docs/games/SOUND_DESIGN.md §3), played unmodified at the moment a player's attempt is
    /// intercepted, and a vocabulary that only exists in three of the four games teaches
    /// nothing.
    private static func soundNames(for game: String) -> [String] {
        switch game {
        case "snake":
            return ["eat_1", "eat_2", "eat_3", "eat_4", "eat_big",
                    "boost_start", "boost_loop", "boost_end",
                    "kill", "death", "spawn", "border_warn", "rank_up", "match_end",
                    Self.catchShared]
        case "tictactoe":
            return ["chalk_x_1", "chalk_x_2", "chalk_x_3",
                    "chalk_o_1", "chalk_o_2", "chalk_o_3",
                    "chalk_line", "chalk_stub", "chalk_erase",
                    "mark_invalid", "win_line", "draw", Self.catchShared]
        case "rps":
            return ["countdown_1", "countdown_2", "countdown_3",
                    "hand_pump", "hand_reveal", "reveal",
                    "round_win", "round_lose", "round_tie", Self.catchShared]
        case "cricket":
            return ["pick", "reveal", "innings",
                    "bat_soft", "bat_crack", "bat_block",
                    "wicket_timber", Self.catchShared,
                    "crowd_base", "crowd_cheer", "crowd_roar", "crowd_gasp",
                    "crowd_groan", "crowd_applause"]
        case "seabattle":
            // Three variants of splash and hit_metal, chosen at random with the existing ±4%
            // varispeed: a match contains 40–90 of these, and SOUND_DESIGN.md §4.3 makes exactly
            // this argument for chalk — without variation "it becomes machine-like by move four".
            return ["fire_launch",
                    "splash_1", "splash_2", "splash_3",
                    "hit_metal_1", "hit_metal_2", "hit_metal_3",
                    "sink_groan", "your_turn", "place_thud", "error",
                    Self.catchShared]
        case "ludo":
            // hop is the most-triggered sound in the game — four variants plus the engine's own
            // pitch jitter, per SOUND_DESIGN.md §4.3's chalk argument.
            return ["die_roll", "die_settle",
                    "hop_1", "hop_2", "hop_3", "hop_4",
                    "enter", "capture", "home", "extra_turn", "three_sixes", "pass",
                    "your_turn", "rank_up", "match_end",
                    Self.catchShared]
        case "ui":
            return ["tap", "sheet_open", "sheet_close", "match_found", "invite_arrive", "error"]
        default:
            return []
        }
    }
}
