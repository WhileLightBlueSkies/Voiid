import SwiftUI
import Combine
import AVFoundation

/// A flexible voice player. Transport, scrubber and time each keep their own layout space.
struct AsyncVoiceNote: View {
    let ref: MediaRef?
    let label: String
    var onOwnBubble = false
    var onScrubbingChanged: (Bool) -> Void = { _ in }

    @StateObject private var playback = VoiceNotePlayback()
    @State private var retry = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var captionSize = 11.0

    private var tint: Color { onOwnBubble ? VoiidColor.textOnBubble : VoiidColor.primary }
    private var secondary: Color { onOwnBubble ? tint.opacity(0.75) : VoiidColor.textSecondary }
    private var identity: String { ref?.mediaUrl ?? label }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                if playback.failed { retry += 1 }
                else { playback.toggle() }
            } label: {
                ZStack {
                    Circle().fill(tint.opacity(onOwnBubble ? 0.16 : 0.1)).frame(width: 34, height: 34)
                    if playback.loading {
                        ProgressView().tint(tint)
                    } else {
                        Image(systemName: playback.failed ? "arrow.clockwise" : "play.fill")
                            .offset(x: playback.failed ? 0 : 1)
                            .opacity(playback.playing ? 0 : 1)
                        Image(systemName: "pause.fill")
                            .opacity(playback.playing ? 1 : 0)
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.15), value: playback.playing)
            }
            .buttonStyle(VoiceTransportStyle(reduceMotion: reduceMotion))
            .disabled(!playback.ready && !playback.failed)
            .accessibilityLabel(playback.failed ? "Retry voice message" : playback.playing ? "Pause voice message" : "Play voice message")
            .accessibilityIdentifier("voice.\(identity).play")

            waveform
                .frame(maxWidth: .infinity)
                .opacity(playback.failed ? 0.3 : 1)

            timeLabel
                .font(VoiidFont.rounded(captionSize, .medium))
                .foregroundStyle(secondary)

        }
        .frame(maxWidth: 260)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: "\(identity):\(retry)") { await playback.load(ref) }
        .onDisappear {
            playback.pause()
            onScrubbingChanged(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
                playback.pause(releaseSession: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { note in
            if (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                playback.pause()
            }
        }
    }

    private var timeLabel: some View {
        Text(playback.ready ? VoiceNotePlayback.time(max(0, playback.duration - playback.elapsed)) : "—:—")
            .monospacedDigit()
            .fixedSize()
            .accessibilityLabel("\(VoiceNotePlayback.time(max(0, playback.duration - playback.elapsed))) remaining")
            .accessibilityIdentifier("voice.\(identity).time")
    }

    private var waveform: some View {
        VoiceWaveform(seed: identity)
            .fill(tint.opacity(onOwnBubble ? 0.28 : 0.22))
            .overlay {
                VoiceWaveform(seed: identity).fill(tint)
                    .mask(alignment: .leading) {
                        Rectangle().scaleEffect(x: playback.progress, y: 1, anchor: .leading)
                    }
            }
            .padding(.horizontal, 7)
            .frame(height: 44)
            .accessibilityHidden(true)
            .overlay {
                VoiceScrubber(progress: playback.progress, duration: playback.duration,
                    isEnabled: playback.ready,
                    tint: UIColor(tint), identifier: "voice.\(identity).scrubber",
                    onSeek: playback.seek,
                    onEditing: { editing in
                        playback.scrubbing = editing
                        onScrubbingChanged(editing)
                    })
            }
    }
}

private struct VoiceTransportStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.12), value: configuration.isPressed)
    }
}

/// A stable visual track, not an audio-amplitude measurement. Geometry always fits its slot.
private struct VoiceWaveform: Shape {
    let seed: String
    func path(in rect: CGRect) -> Path {
        let count = max(1, Int(rect.width / 5))
        let spacing = rect.width / CGFloat(count)
        var value = seed.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        var path = Path()
        for index in 0..<count {
            value = value &* 6364136223846793005 &+ 1
            let height = CGFloat(6 + (value >> 32) % 21)
            let bar = CGRect(x: rect.minX + CGFloat(index) * spacing,
                             y: rect.midY - height / 2, width: min(2.5, spacing), height: height)
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: 1.25, height: 1.25))
        }
        return path
    }
}

/// Native tracking and adjustable accessibility avoid competing drag recognizers.
private struct VoiceScrubber: UIViewRepresentable {
    let progress: Double
    let duration: TimeInterval
    let isEnabled: Bool
    let tint: UIColor
    let identifier: String
    let onSeek: (Double) -> Void
    let onEditing: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> VoiceScrubberView {
        let view = VoiceScrubberView()
        let slider = view.slider
        slider.minimumTrackTintColor = .clear
        slider.maximumTrackTintColor = .clear
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return view
    }
    func updateUIView(_ view: VoiceScrubberView, context: Context) {
        let slider = view.slider
        context.coordinator.parent = self
        view.tracking.isEnabled = isEnabled
        view.tracking.onEditing = onEditing
        view.tracking.onSeek = onSeek
        slider.isEnabled = isEnabled
        if !view.tracking.isTracking {
            slider.setValue(Float(progress), animated: false)
        }
        let resolvedTint = tint.resolvedColor(with: UITraitCollection(userInterfaceStyle:
            context.environment.colorScheme == .dark ? .dark : .light))
        if context.coordinator.color != resolvedTint {
            context.coordinator.color = resolvedTint
            let image = UIGraphicsImageRenderer(size: CGSize(width: 14, height: 14)).image { _ in
                resolvedTint.setFill()
                UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 12, height: 12)).fill()
            }
            slider.setThumbImage(image, for: .normal)
            slider.setThumbImage(image, for: .highlighted)
        }
        slider.accessibilityLabel = "Voice message playback position"
        slider.accessibilityValue = "\(VoiceNotePlayback.time(progress * duration)) of \(VoiceNotePlayback.time(duration))"
        slider.accessibilityIdentifier = identifier
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: VoiceScrubberView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 180, height: 44)
    }
    final class Coordinator: NSObject {
        var parent: VoiceScrubber
        var color: UIColor?
        init(parent: VoiceScrubber) { self.parent = parent }
        @objc func changed(_ slider: UISlider) { parent.onSeek(Double(slider.value)) }
    }
}

/// Keep native adjustable accessibility and thumb rendering. A sibling UIControl
/// handles direct touch tracking so UIKit's animated slider drag cannot move the
/// playhead after release (seen with compact custom thumbs on iOS 26).
private final class VoiceScrubberView: UIView {
    let slider = UISlider()
    let tracking = VoiceTouchControl()

    override init(frame: CGRect) {
        super.init(frame: frame)
        slider.isUserInteractionEnabled = false
        tracking.slider = slider
        addSubview(slider)
        addSubview(tracking)
        accessibilityElements = [slider]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        slider.frame = bounds
        tracking.frame = bounds
    }
}

private final class VoiceTouchControl: UIControl {
    weak var slider: UISlider?
    var onSeek: (Double) -> Void = { _ in }
    var onEditing: (Bool) -> Void = { _ in }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled else { return false }
        onEditing(true)
        seek(to: touch)
        return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        seek(to: touch)
        return true
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch { seek(to: touch) }
        onEditing(false)
    }
    override func cancelTracking(with event: UIEvent?) {
        onEditing(false)
    }
    private func seek(to touch: UITouch) {
        guard let slider else { return }
        let track = slider.trackRect(forBounds: bounds)
        let start = slider.thumbRect(forBounds: bounds, trackRect: track, value: 0).midX
        let end = slider.thumbRect(forBounds: bounds, trackRect: track, value: 1).midX
        guard end > start else { return }
        let fraction = min(1, max(0, (touch.location(in: self).x - start) / (end - start)))
        slider.setValue(Float(fraction), animated: false)
        onSeek(Double(fraction))
    }
}

@MainActor
final class VoiceNotePlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing = false
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var elapsed: TimeInterval = 0
    var scrubbing = false
    private var player: AVAudioPlayer?
    private var mediaURL: String?
    private var ticker: Timer?
    private static weak var active: VoiceNotePlayback?
    var ready: Bool { player != nil }
    var progress: Double { duration > 0 ? min(1, max(0, elapsed / duration)) : 0 }

    func load(_ ref: MediaRef?) async {
        guard let ref else { return }
        if mediaURL == ref.mediaUrl, ready, !failed { return }
        let retrying = failed
        pause()
        mediaURL = ref.mediaUrl
        player = nil
        elapsed = 0
        duration = 0
        failed = false
        loading = true
        defer { loading = false }
        do {
            let bytes: Data
            if !retrying, let cached = MediaCache.shared.data(ref.mediaUrl) { bytes = cached }
            else {
                bytes = try await ChatEngine.shared.fetchMedia(ref)
                try Task.checkCancellation()
                MediaCache.shared.setData(bytes, ref.mediaUrl)
            }
            try Task.checkCancellation()
            let audio = try AVAudioPlayer(data: bytes)
            audio.delegate = self
            guard audio.duration > 0, audio.prepareToPlay() else { throw CocoaError(.fileReadCorruptFile) }
            player = audio
            duration = audio.duration
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }

    static func pauseActive() { active?.pause() }

    func toggle() {
        if playing { pause(); return }
        guard let player else { return }
        Self.active?.pause()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
            guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
            Self.active = self
            playing = true
            failed = false
            elapsed = player.currentTime
            ticker?.invalidate()
            // Follow the audio clock directly: no queued animations during a seek/pause.
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.scrubbing, let player = self.player else { return }
                    self.elapsed = player.currentTime
                    // Route changes/interruption can pause audio without a finish callback.
                    if !player.isPlaying && self.playing { self.pause() }
                }
            }
            ticker = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch {
            failed = true
            playing = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func seek(_ fraction: Double) {
        guard let player else { return }
        elapsed = min(1, max(0, fraction)) * duration
        player.currentTime = elapsed
    }

    func pause(releaseSession: Bool = true) {
        player?.pause()
        playing = false
        ticker?.invalidate()
        ticker = nil
        if Self.active === self {
            Self.active = nil
            if releaseSession {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.pause()
            self.elapsed = 0
            self.player?.currentTime = 0
            self.failed = !flag
        }
    }

    static func time(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    deinit { ticker?.invalidate() }
}
