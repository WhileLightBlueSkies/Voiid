//
//  VoiceNote.swift
//  Voiid
//
//  Voice-note UI for the dummy experience: press-and-hold to record (timer + live waveform),
//  release to send; tap to play back with an animated waveform. No real audio engine wired —
//  this is the interaction/feel; real AVAudioRecorder/Player slots in here later.
//

import SwiftUI
import Combine
import AVFoundation

// MARK: - Record button (press & hold)

struct VoiceRecordButton: View {
    /// Called on release with the recorded audio bytes (.m4a) + duration (seconds).
    var onSend: (Data, TimeInterval) -> Void
    /// Told when recording starts/stops, so the composer can hand over its whole row. The
    /// recording UI CANNOT live inside this button: it needs the full width, and a 44pt
    /// capsule rendered inside a 32pt slot is what made the old one look broken.
    var onRecordingChange: (Bool) -> Void = { _ in }
    /// Live horizontal drag while recording, so the composer can draw slide-to-cancel.
    var onDrag: (CGFloat) -> Void = { _ in }
    /// Ticking duration, so the bar can show it without owning the recorder.
    var onTick: (TimeInterval) -> Void = { _ in }

    @State private var recording = false
    @State private var seconds: TimeInterval = 0
    @State private var timer: Timer?
    @State private var recorder: AVAudioRecorder?
    @State private var fileURL: URL?
    @State private var tooShort = false
    /// Times the press-and-hold. A bare DragGesture fires on touch-down, so the "hold" is
    /// enforced here rather than by a LongPressGesture — see the gesture comment.
    @State private var holdTimer: Timer?

    var body: some View {
        // A 46pt CIRCLE, matching send — the two now SHARE one slot in the composer and
        // swap, so any size difference would show as a jump the moment you type a character.
        // (It was 32 to match the older, smaller send button; both moved to the reference's
        // 46 together.)
        //
        // It was a bare `mic.fill` glyph — no shape, no bounds — so it sat visually
        // misaligned next to the filled send button and had a vague tap target.
        Image(systemName: "mic.fill")
            .font(.system(size: 19, weight: .semibold))
            .foregroundColor(VoiidColor.primary)
            .frame(width: 46, height: 46)
            .background(VoiidColor.primary.opacity(0.12))
            .clipShape(Circle())
            .overlay(alignment: .top) {
                // "Hold to record" — the one thing a mic icon does not communicate. Shown
                // only after a too-short tap, so it teaches on failure rather than nagging.
                if tooShort {
                    Text("Hold to record")
                        .font(VoiidFont.rounded(11, .medium))
                        .foregroundColor(VoiidColor.textOnPrimary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(VoiidColor.textPrimary.opacity(0.9)))
                        .fixedSize()
                        .offset(y: -34)
                        .transition(.opacity.combined(with: .scale))
                }
            }
            .contentShape(Circle())
            // ONE DragGesture with minimumDistance 0, not a LongPress `.sequenced(before:)`.
            //
            // The sequenced form did not work: it wraps the inner drag in a
            // SequenceGesture.Value, so `.onChanged`/`.onEnded` attached to that inner drag are
            // never delivered. The drag callbacks simply never fired, which is why slide-to-
            // cancel did nothing — the bar never saw the finger move and the release always
            // took the send path.
            //
            // A bare drag fires from touch-down, so the hold is timed here instead: a 0.25s
            // timer starts recording, and a release before it fires is a tap.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !recording && holdTimer == nil {
                            // Touch down: arm the hold. Cancelled on an early release below.
                            armHold()
                        }
                        guard recording else { return }
                        // Only leftward travel matters; rightward is noise from the thumb
                        // rolling on the glass.
                        onDrag(min(0, value.translation.width))
                    }
                    .onEnded { value in
                        holdTimer?.invalidate()
                        holdTimer = nil
                        guard recording else {
                            // Released before the hold armed — a tap, not a recording.
                            showTooShort()
                            return
                        }
                        finish(cancelled: value.translation.width <= RecordingBar.cancelThreshold)
                    }
            )
            .animation(.spring(response: 0.3), value: tooShort)
    }

    /// Start the hold countdown. Recording begins only if the finger is still down at 0.25s.
    private func armHold() {
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { _ in
            Task { @MainActor in
                holdTimer = nil
                start()
            }
        }
    }

    /// "Hold to record" — the one thing a mic glyph cannot say. Shown on a too-short tap so it
    /// teaches on failure rather than nagging permanently.
    private func showTooShort() {
        Haptics.tap()
        withAnimation { tooShort = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { tooShort = false }
        }
    }

    private func start() {
        AVAudioApplication.requestRecordPermission { granted in
            guard granted else { return }
            DispatchQueue.main.async { beginRecording() }
        }
    }

    /// Ends the take. `cancelled` discards; otherwise it sends if long enough.
    private func finish(cancelled: Bool) {
        timer?.invalidate()
        recording = false
        onRecordingChange(false)
        onDrag(0)
        RecordingLevel.shared.reset()
        recorder?.stop()
        let dur = seconds
        let url = fileURL
        recorder = nil
        fileURL = nil

        defer { if let url { try? FileManager.default.removeItem(at: url) } }
        guard !cancelled else { Haptics.tap(); return }

        // Under half a second is a mis-tap, not a message. It used to fail SILENTLY, so the
        // user pressed the mic, nothing happened, and nothing explained why.
        guard dur >= 0.5 else { showTooShort(); return }
        guard let url, let data = try? Data(contentsOf: url) else { return }
        Haptics.success()
        onSend(data, dur)
    }

    private func beginRecording() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default)
        try? session.setActive(true)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiid_vn_\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let rec = try? AVAudioRecorder(url: url, settings: settings) else { return }
        // METERING ON: the waveform reads real input level. It used to animate random numbers,
        // which looks convincing until you realise it wiggles identically in silence — so it
        // told the user nothing about whether the mic was actually picking them up.
        rec.isMeteringEnabled = true
        recorder = rec; fileURL = url
        rec.record()
        Haptics.rigid()
        recording = true
        seconds = 0
        onRecordingChange(true)
        RecordingLevel.shared.reset()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            seconds += 0.05
            onTick(seconds)
            rec.updateMeters()
            // averagePower is dBFS: -160 (silence) to 0 (peak). Normalised against a -50dB
            // floor, which is roughly room tone on a phone mic.
            let db = rec.averagePower(forChannel: 0)
            let level = max(0, min(1, (db + 50) / 50))
            RecordingLevel.shared.push(CGFloat(level))
        }
    }

}

// MARK: - Live input level

/// Real mic levels, published from the recorder's meter so the waveform reflects what the mic
/// is actually hearing. A shared singleton because the recorder lives in the button while the
/// waveform is drawn by the composer — they are siblings, not parent and child.
@MainActor
final class RecordingLevel: ObservableObject {
    static let shared = RecordingLevel()
    private init() {}

    /// Newest last. Fixed width so the bar scrolls rather than growing.
    @Published private(set) var levels: [CGFloat] = Array(repeating: 0.05, count: 34)

    func push(_ level: CGFloat) {
        levels.removeFirst()
        levels.append(max(0.05, level))
    }

    func reset() {
        levels = Array(repeating: 0.05, count: 34)
    }
}

/// Waveform driven by real input.
struct LiveWaveform: View {
    @ObservedObject private var source = RecordingLevel.shared
    var tint: Color = VoiidColor.primary

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(source.levels.indices, id: \.self) { i in
                    Capsule()
                        .fill(tint)
                        // Newer bars are more opaque, so the eye reads direction of travel —
                        // a flat wall of identical bars looks static even while animating.
                        .opacity(0.35 + 0.65 * (Double(i) / Double(source.levels.count)))
                        .frame(width: 2.5, height: max(3, geo.size.height * source.levels[i]))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .trailing)
            .animation(.linear(duration: 0.05), value: source.levels)
        }
        .frame(height: 22)
    }
}

// MARK: - Voice note playback bubble

struct VoiceNotePlayer: View {
    let label: String
    @State private var playing = false
    @State private var progress: CGFloat = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Button {
                Haptics.tap(); togglePlay()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 18)).foregroundColor(VoiidColor.primary)
            }
            // static waveform with playback progress fill
            HStack(spacing: 2) {
                ForEach(0..<22, id: \.self) { i in
                    Capsule()
                        .fill(CGFloat(i) / 22 <= progress ? VoiidColor.primary : VoiidColor.textSecondary.opacity(0.4))
                        .frame(width: 2.5, height: barHeight(i))
                }
            }
            Text(label.contains("·") ? String(label.split(separator: "·").last ?? "") : "0:03")
                .font(VoiidFont.rounded(10, .regular)).foregroundColor(VoiidColor.textSecondary)
        }
        .frame(minWidth: 180)
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let pattern: [CGFloat] = [8, 14, 20, 12, 18, 10, 22, 16, 9, 15, 21]
        return pattern[i % pattern.count]
    }
    private func togglePlay() {
        playing.toggle()
        if playing {
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                progress += 0.01
                if progress >= 1 { progress = 0; playing = false; timer?.invalidate() }
            }
        } else { timer?.invalidate() }
    }
}

// MARK: - Recording bar

/// The full-width bar that REPLACES the composer row while recording.
///
/// It cannot live inside the mic button. A 44pt capsule rendered inside a 32pt slot is what
/// made the old one look broken — it overflowed its container and fought the text field for
/// space. Recording is a modal state, so it takes the whole row.
///
/// SLIDE LEFT TO CANCEL is the standard gesture everywhere else and was entirely missing:
/// once you started, releasing ALWAYS sent, with no way out but sending something you did not
/// want.
struct RecordingBar: View {
    let seconds: TimeInterval
    /// 0 = at rest, negative = dragged left toward cancel.
    let dragX: CGFloat
    var onCancel: () -> Void

    /// Past this the release discards. Matched by the button's own threshold.
    static let cancelThreshold: CGFloat = -90

    private var willCancel: Bool { dragX <= Self.cancelThreshold }

    /// 0…1 across the cancel travel, for anything that should respond CONTINUOUSLY rather
    /// than flipping at the threshold. A gesture that only shows its outcome once it is
    /// decided gives the user no chance to change their mind.
    private var cancelProgress: CGFloat {
        min(1, max(0, dragX / Self.cancelThreshold))
    }

    private var timeString: String {
        String(format: "%01d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    var body: some View {
        HStack(spacing: VoiidSpacing.sm) {
            // A pulsing dot reads as "live" the way a static icon cannot.
            Circle()
                .fill(VoiidColor.error)
                .frame(width: 9, height: 9)
                .opacity(0.55)
                .scaleEffect(1.25)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: seconds)

            Text(timeString)
                .font(VoiidFont.rounded(14, .semibold))
                .monospacedDigit()
                .foregroundColor(willCancel ? VoiidColor.error : VoiidColor.textPrimary)

            LiveWaveform(tint: willCancel ? VoiidColor.error : VoiidColor.primary)
                .frame(maxWidth: .infinity)

            // The affordance has to be VISIBLE — a hidden gesture is not a feature. It flips
            // to "Release to cancel" past the threshold so the outcome is never a guess.
            HStack(spacing: 4) {
                Image(systemName: willCancel ? "trash.fill" : "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text(willCancel ? "Release to cancel" : "Slide to cancel")
                    .font(VoiidFont.rounded(12, .medium))
            }
            .foregroundColor(willCancel ? VoiidColor.error : VoiidColor.textSecondary)
            .fixedSize()
            // Follows the finger, damped — 1:1 tracking over-travels and looks loose.
            .offset(x: max(dragX * 0.35, -26))
        }
        .padding(.horizontal, VoiidSpacing.md)
        // 52pt, the reference's height — the bar replaces a 46pt mic and a pill, so at 40
        // the composer visibly SHRANK the moment recording began.
        .frame(height: 52)
        .background(VoiidColor.fieldFill)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.pill, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.pill)
                // The stroke DEEPENS with the drag rather than flipping at the threshold.
                // A binary change gives no warning: you learn you are about to cancel at the
                // moment it is already decided. Progressive tint makes the gesture legible
                // while it is still reversible.
                .stroke(VoiidColor.error.opacity(0.15 + cancelProgress * 0.75), lineWidth: 1.5)
        )
        .animation(.easeOut(duration: 0.15), value: willCancel)
        .accessibilityLabel("Recording, \(timeString). Slide left to cancel.")
        .accessibilityAction(named: "Cancel recording") { onCancel() }
    }
}
