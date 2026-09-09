//
//  VoiceNote.swift
//  Voiid
//
//  Hold-to-record controls and live input visualization.
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

    var cancelRequest: Int = 0
    var onDiscard: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fingerDown = false
    @State private var cancelledGesture = false
    @State private var gestureID = UUID()
    @State private var recordingError: String?
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
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !fingerDown {
                            fingerDown = true
                            cancelledGesture = false
                            gestureID = UUID()
                            // Touch down: arm the hold. Cancelled on an early release below.
                            armHold()
                        }
                        guard recording else { return }
                        // Only leftward travel matters; rightward is noise from the thumb
                        // rolling on the glass.
                        onDrag(min(0, value.translation.width))
                    }
                    .onEnded { value in
                        fingerDown = false
                        gestureID = UUID()
                        holdTimer?.invalidate()
                        holdTimer = nil
                        guard recording else {
                            // Released before the hold armed — a tap, not a recording.
                            if !cancelledGesture { showTooShort() }
                            return
                        }
                        finish(cancelled: value.translation.width <= RecordingBar.cancelThreshold)
                    }
            )
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.15), value: tooShort)
            .scaleEffect(recording && !reduceMotion ? 1.06 : 1)
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.12), value: recording)
            .accessibilityIdentifier("voice.record")
            .accessibilityLabel("Record voice message")
            .accessibilityHint("Hold to record. Slide left and release to delete.")
            .onChange(of: cancelRequest) { _, _ in
                cancelledGesture = true
                holdTimer?.invalidate()
                holdTimer = nil
                gestureID = UUID()
                if recording { finish(cancelled: true) }
            }
            .onDisappear {
                fingerDown = false
                gestureID = UUID()
                holdTimer?.invalidate()
                holdTimer = nil
                if recording { finish(cancelled: true) }
            }
            .alert("Couldn’t record", isPresented: Binding(
                get: { recordingError != nil }, set: { if !$0 { recordingError = nil } }
            )) {
                Button("OK", role: .cancel) { recordingError = nil }
            } message: { Text(recordingError ?? "") }
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
        let requestID = gestureID
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard fingerDown, gestureID == requestID else { return }
                guard granted else {
                    recordingError = "Allow microphone access for Voiid in Settings to record voice messages."
                    return
                }
                beginRecording()
            }
        }
    }

    /// Ends the take. `cancelled` discards; otherwise it sends if long enough.
    private func finish(cancelled: Bool) {
        guard recording else { return }
        timer?.invalidate()
        timer = nil
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard !cancelled else { Haptics.tap(); onDiscard(); return }

        // Under half a second is a mis-tap, not a message. It used to fail SILENTLY, so the
        // user pressed the mic, nothing happened, and nothing explained why.
        guard dur >= 0.5 else { showTooShort(); return }
        guard let url, let data = try? Data(contentsOf: url) else { return }
        Haptics.success()
        onSend(data, dur)
    }

    private func beginRecording() {
        let session = AVAudioSession.sharedInstance()
        VoiceNotePlayback.pauseActive()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {
            recordingError = "The microphone is unavailable. Please try again."
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiid_vn_\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let rec = try? AVAudioRecorder(url: url, settings: settings) else {
            recordingError = "Couldn’t prepare the recording. Please try again."
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        // METERING ON: the waveform reads real input level. It used to animate random numbers,
        // which looks convincing until you realise it wiggles identically in silence — so it
        // told the user nothing about whether the mic was actually picking them up.
        rec.isMeteringEnabled = true
        guard rec.record() else {
            try? FileManager.default.removeItem(at: url)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            recordingError = "Couldn’t start recording. Please try again."
            return
        }
        recorder = rec; fileURL = url
        Haptics.rigid()
        recording = true
        seconds = 0
        onRecordingChange(true)
        RecordingLevel.shared.reset()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            let current = rec.currentTime
            let secondChanged = Int(current) != Int(seconds)
            seconds = current
            // Only the meter needs 20 Hz. Do not rebuild the entire chat 20 times/second.
            if secondChanged { onTick(seconds) }
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
        Canvas { context, size in
            let count = min(source.levels.count, max(1, Int(size.width / 4.5)))
            let levels = Array(source.levels.suffix(count))
            let step = size.width / CGFloat(count)
            for (index, level) in levels.enumerated() {
                let height = max(3, size.height * level)
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2,
                                  width: min(2.5, step), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.25),
                             with: .color(tint.opacity(0.35 + 0.65 * Double(index + 1) / Double(count))))
            }
        }
        .frame(height: 22)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
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
    let dragX: CGFloat
    var isDiscarding = false
    var onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var captionSize = 12.0
    static let cancelThreshold: CGFloat = -90
    private var willCancel: Bool { dragX <= Self.cancelThreshold }
    private var cancelProgress: CGFloat { min(1, max(0, dragX / Self.cancelThreshold)) }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Image(systemName: isDiscarding ? "trash.fill" : "trash")
                    .symbolEffect(.bounce, value: isDiscarding && !reduceMotion)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(VoiidColor.error)
                    .rotationEffect(.degrees(reduceMotion ? 0 : -12 * cancelProgress))
                    .scaleEffect(reduceMotion ? 1 : 1 + 0.1 * cancelProgress)
                    .frame(width: 44, height: 44)
                    .background(VoiidColor.error.opacity(0.08 + 0.1 * cancelProgress), in: Circle())
                    .overlay {
                        Circle().trim(from: 0, to: cancelProgress)
                            .stroke(VoiidColor.error, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .allowsHitTesting(false)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete recording")
            .accessibilityIdentifier("voice.recording.delete")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(VoiidColor.error).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(VoiceNotePlayback.time(seconds))
                        .font(VoiidFont.rounded(14, .semibold)).monospacedDigit().fixedSize()
                    LiveWaveform(tint: willCancel ? VoiidColor.error : VoiidColor.primary)
                        .frame(maxWidth: .infinity)
                }
                Text(willCancel ? "Release to delete" : "Slide left to delete · release to send")
                    .font(VoiidFont.rounded(captionSize, .medium))
                    .foregroundStyle(willCancel ? VoiidColor.error : VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.15), value: willCancel)
            }
            .opacity(isDiscarding ? 0 : 1)
            .scaleEffect(isDiscarding && !reduceMotion ? 0.85 : 1, anchor: .leading)
            .offset(x: isDiscarding && !reduceMotion ? -16 : 0)
            .animation(.easeOut(duration: 0.18), value: isDiscarding)
        }
        .allowsHitTesting(!isDiscarding)
        .padding(.horizontal, 12).padding(.vertical, 4)
        .frame(minHeight: 52)
        .background(VoiidColor.fieldFill, in: RoundedRectangle(cornerRadius: 26))
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .stroke(VoiidColor.error.opacity(cancelProgress * 0.6), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onChange(of: willCancel) { _, _ in Haptics.selection() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice.recording.bar")
    }
}
