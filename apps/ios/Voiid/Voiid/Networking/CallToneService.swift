//
//  CallToneService.swift
//  Voiid
//
//  Call-state audio for 1:1 calls: ringback (caller side), busy/declined
//  feedback, and a short end-of-call cue.
//
//  THE SILENT-SWITCH RULE (docs/CALL_RELIABILITY.md → "P0.5 — call audio &
//  ringing behavior"). There are two different sounds with deliberately
//  different behaviour, and mixing them up is the classic bug:
//
//    * The CALLEE's incoming ringtone is played by the SYSTEM via CallKit's
//      reportNewIncomingCall. It follows the ring/silent switch, exactly like a
//      native phone call. That is correct and is NOT touched anywhere in this
//      file.
//    * The CALLER's RINGBACK — this file — must be audible EVEN ON SILENT,
//      because the user just tapped "call" and is holding the phone to their
//      ear. The only thing that decides this is the AVAudioSession category:
//      `.playAndRecord` and `.playback` ignore the ring/silent switch;
//      `.ambient`/`.soloAmbient` obey it. So the tone is played through the
//      CALL'S OWN session (`.playAndRecord` + mode `.voiceChat`, falling back
//      to `.playback` if the mic isn't available), never through
//      AudioServicesPlaySystemSound — which always obeys the switch and is
//      precisely the bug this replaces.
//
//  SESSION OWNERSHIP. WebRTC runs in manual-audio mode and normally receives an
//  already-activated session from CallKit's `provider(_:didActivate:)`. But
//  that only fires when the call CONNECTS, and ringback by definition plays
//  before that. So we activate the shared RTCAudioSession ourselves if it isn't
//  live yet, remember that we were the one who did it, and stand down the
//  moment WebRTC takes over (`noteWebRTCTookOverSession()` from the CallKit
//  didActivate handler). Because we go through RTCAudioSession's own
//  lock/configure API rather than AVAudioSession directly, there is never a
//  moment where two owners are configuring the session behind each other's
//  back. Activating the session does NOT start WebRTC's audio unit — that is
//  gated separately on `isAudioEnabled` — so the handoff is clean.
//
//  Tones are synthesised in memory (a WAV built sample by sample) rather than
//  shipped as a binary asset: a two-frequency call-progress tone is a handful
//  of lines of arithmetic and keeps a blob out of the repo.
//
//  EVERYTHING HERE IS BEST-EFFORT. A tone is a nicety; a call is not. Every
//  failure path logs and returns — nothing in this file may ever throw into,
//  crash, or tear down a call.
//
//  RUNTIME CAVEAT: audio ROUTING and silent-switch behaviour cannot be verified
//  in the simulator. This is compile-verified plus session-configuration
//  review; it needs two real devices to confirm.
//

import Foundation
import AVFoundation
import WebRTC

@MainActor
final class CallToneService: NSObject {
    static let shared = CallToneService()

    /// The looping ringback player (nil when not ringing).
    private var ringbackPlayer: AVAudioPlayer?
    /// One-shot players (busy / declined / failed / end cue) kept alive until done.
    private var oneShotPlayer: AVAudioPlayer?
    /// Cancels the deferred session release for whatever one-shot is playing.
    private var oneShotReleaseTask: Task<Void, Never>?

    /// True when WE activated the audio session (rather than CallKit). Only then
    /// may we deactivate it — tearing down a session CallKit owns would cut the
    /// call's own audio.
    private var ownsSessionActivation = false

    /// Cached synthesised tones — built once, reused for the life of the process.
    private var toneCache: [String: Data] = [:]

    private override init() { super.init() }

    // MARK: - Public API

    /// Start the looping ringback tone. Called when `call_ringing` arrives from
    /// the callee — i.e. their device is genuinely alerting — never optimistically
    /// when the offer is sent, so we can't ring for a phone that never rang.
    func startRingback() {
        guard ringbackPlayer == nil else { return }   // already ringing
        guard activateCallSession() else {
            NSLog("[VOIID] ringback: no audio session — skipping tone (call unaffected)")
            return
        }
        guard let data = tone(.ringback) else { return }
        do {
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = -1          // until answered/declined/failed
            player.volume = 0.8
            player.prepareToPlay()
            guard player.play() else {
                NSLog("[VOIID] ringback: play() refused")
                return
            }
            ringbackPlayer = player
            NSLog("[VOIID] ringback started")
        } catch {
            NSLog("[VOIID] ringback failed: \(error.localizedDescription)")
        }
    }

    /// Stop ringback immediately. MUST be called the instant the call is
    /// answered, declined, busy, failed or times out — ringback bleeding into
    /// connected audio is worse than no ringback at all.
    func stopRingback() {
        guard let player = ringbackPlayer else { return }
        player.stop()
        ringbackPlayer = nil
        NSLog("[VOIID] ringback stopped")
        releaseSessionIfOwnedAndIdle()
    }

    /// Peer is busy in another call.
    func playBusy() { playOneShot(.busy) }

    /// Peer actively declined.
    func playDeclined() { playOneShot(.declined) }

    /// Call setup or the connection failed — an audible "that didn't work".
    func playFailed() { playOneShot(.failed) }

    /// Short cue when a connected call ends normally.
    func playEndCue() { playOneShot(.endCall) }

    /// Stop everything. Used on teardown paths that don't want any cue at all.
    func stopAll() {
        oneShotReleaseTask?.cancel(); oneShotReleaseTask = nil
        ringbackPlayer?.stop(); ringbackPlayer = nil
        oneShotPlayer?.stop(); oneShotPlayer = nil
        releaseSessionIfOwnedAndIdle()
    }

    /// CallKit handed the activated session to WebRTC. From here on the session
    /// is WebRTC's, not ours: drop our claim so we never deactivate it out from
    /// under a live call. (Any ringback still playing is stopped by CallService
    /// on connect; this only transfers ownership.)
    func noteWebRTCTookOverSession() {
        ownsSessionActivation = false
    }

    // MARK: - Audio session

    /// Bring the call's own audio session up so tones are audible with the
    /// ring/silent switch ON.
    ///
    /// `.playAndRecord` + `.voiceChat` is the same category/mode WebRTC will use
    /// for the call itself (see `CallManager.configureAudioSessionForCalls`), so
    /// when media starts there is no category change and no route glitch — the
    /// tone and the call share one session configuration end to end.
    ///
    /// The `.playback` fallback exists for the case where `.playAndRecord`
    /// activation fails (microphone permission not granted / mic held by another
    /// app). `.playback` also ignores the silent switch, so the ringback stays
    /// audible; we just can't record — which doesn't matter yet at ringback time.
    @discardableResult
    private func activateCallSession() -> Bool {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }

        let options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP, .duckOthers]
        do {
            try rtc.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        } catch {
            NSLog("[VOIID] tone: .playAndRecord unavailable (\(error.localizedDescription)) — falling back to .playback")
            do {
                // Still ignores the silent switch, which is the whole point.
                try rtc.setCategory(.playback, mode: .voiceChat, options: [])
            } catch {
                NSLog("[VOIID] tone: no usable audio category: \(error.localizedDescription)")
                return false
            }
        }

        // Already live — CallKit (or a previous tone) activated it. Don't claim
        // ownership of a session we didn't bring up.
        if rtc.isActive { return true }

        do {
            try rtc.setActive(true)
            ownsSessionActivation = true
            return true
        } catch {
            NSLog("[VOIID] tone: session activation failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Give the session back, but only if we activated it, nothing of ours is
    /// still playing, and WebRTC hasn't started its audio unit. Any of those
    /// being true means deactivating would cut real audio.
    private func releaseSessionIfOwnedAndIdle() {
        guard ownsSessionActivation else { return }
        guard ringbackPlayer == nil, oneShotPlayer == nil else { return }
        let rtc = RTCAudioSession.sharedInstance()
        guard !rtc.isAudioEnabled else {
            // WebRTC is running on this session now — hand it over, don't kill it.
            ownsSessionActivation = false
            return
        }
        ownsSessionActivation = false
        rtc.lockForConfiguration()
        do { try rtc.setActive(false) }
        catch { NSLog("[VOIID] tone: session deactivate failed: \(error.localizedDescription)") }
        rtc.unlockForConfiguration()
    }

    // MARK: - One-shot playback

    private func playOneShot(_ kind: ToneKind) {
        // A cue never competes with ringback; the caller stops ringback first,
        // but be defensive in case a path forgets.
        stopRingback()
        oneShotReleaseTask?.cancel(); oneShotReleaseTask = nil
        oneShotPlayer?.stop(); oneShotPlayer = nil

        guard activateCallSession() else { return }
        guard let data = tone(kind) else { return }
        do {
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = 0
            player.volume = 0.7
            player.prepareToPlay()
            guard player.play() else { return }
            oneShotPlayer = player
            let seconds = player.duration + 0.25
            oneShotReleaseTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self else { return }
                self.oneShotPlayer = nil
                self.releaseSessionIfOwnedAndIdle()
            }
        } catch {
            NSLog("[VOIID] tone \(kind.rawValue) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Tone synthesis
    //
    // Classic call-progress tones: a pair of summed sine waves gated on and off.
    // Frequencies/cadences below are the North-American (and de-facto
    // international) conventions users already recognise.

    private enum ToneKind: String {
        /// 440 + 480 Hz, 2s on / 4s off — the "brrring … brrring" of a ringing line.
        case ringback
        /// 480 + 620 Hz, 0.5s on / 0.5s off — busy signal.
        case busy
        /// Same pair, faster and shorter — "they said no", distinct from busy.
        case declined
        /// Descending pair — something broke.
        case failed
        /// Two soft descending blips — the call is over.
        case endCall
    }

    private struct Segment {
        let freqs: [Double]
        let seconds: Double
        static func silence(_ s: Double) -> Segment { Segment(freqs: [], seconds: s) }
    }

    private func tone(_ kind: ToneKind) -> Data? {
        if let cached = toneCache[kind.rawValue] { return cached }
        let segments: [Segment]
        switch kind {
        case .ringback:
            segments = [Segment(freqs: [440, 480], seconds: 2.0), .silence(4.0)]
        case .busy:
            let cycle: [Segment] = [Segment(freqs: [480, 620], seconds: 0.5), .silence(0.5)]
            segments = cycle + cycle + cycle
        case .declined:
            let cycle: [Segment] = [Segment(freqs: [480, 620], seconds: 0.25), .silence(0.25)]
            segments = cycle + cycle
        case .failed:
            segments = [Segment(freqs: [480], seconds: 0.35),
                        .silence(0.08),
                        Segment(freqs: [400], seconds: 0.35),
                        .silence(0.08),
                        Segment(freqs: [330], seconds: 0.5)]
        case .endCall:
            segments = [Segment(freqs: [520], seconds: 0.13),
                        .silence(0.06),
                        Segment(freqs: [420], seconds: 0.18)]
        }
        guard let data = Self.makeWAV(segments) else { return nil }
        toneCache[kind.rawValue] = data
        return data
    }

    /// Render segments to 16-bit mono PCM wrapped in a WAV container, which
    /// `AVAudioPlayer(data:)` accepts directly. 16 kHz is plenty for tones in
    /// this frequency range and keeps the buffers small.
    private static func makeWAV(_ segments: [Segment], sampleRate: Double = 16_000) -> Data? {
        var samples: [Int16] = []
        samples.reserveCapacity(Int(segments.reduce(0) { $0 + $1.seconds } * sampleRate) + 1)

        for segment in segments {
            let frames = max(0, Int(segment.seconds * sampleRate))
            guard frames > 0 else { continue }
            if segment.freqs.isEmpty {
                samples.append(contentsOf: repeatElement(0, count: frames))
                continue
            }
            // Keep the summed amplitude inside range regardless of tone count.
            let amplitude = 0.45 / Double(segment.freqs.count)
            // ~8ms raised-cosine edges: without them each gate boundary is a step
            // discontinuity, which is audible as a click on every cadence.
            let ramp = min(Int(0.008 * sampleRate), frames / 2)
            for i in 0..<frames {
                var value = 0.0
                for f in segment.freqs {
                    value += sin(2.0 * Double.pi * f * Double(i) / sampleRate)
                }
                value *= amplitude
                if ramp > 0 {
                    if i < ramp {
                        value *= 0.5 * (1 - cos(Double.pi * Double(i) / Double(ramp)))
                    } else if i >= frames - ramp {
                        let j = frames - 1 - i
                        value *= 0.5 * (1 - cos(Double.pi * Double(j) / Double(ramp)))
                    }
                }
                let clamped = max(-1.0, min(1.0, value))
                samples.append(Int16(clamped * 32_767.0))
            }
        }
        guard !samples.isEmpty else { return nil }

        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataBytes = UInt32(samples.count * 2)

        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataBytes)
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                 // PCM fmt chunk size
        append(UInt16(1))                  // format = PCM
        append(channels)
        append(UInt32(sampleRate))
        append(byteRate)
        append(blockAlign)
        append(bitsPerSample)
        wav.append(contentsOf: Array("data".utf8))
        append(dataBytes)
        // Every Apple platform we ship on is little-endian, which is also WAV's
        // byte order, so the Int16 buffer maps straight across.
        let little = samples.map { $0.littleEndian }
        little.withUnsafeBufferPointer { wav.append(Data(buffer: $0)) }
        return wav
    }
}
