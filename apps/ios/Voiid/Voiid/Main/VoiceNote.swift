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

// MARK: - Record button (press & hold)

struct VoiceRecordButton: View {
    /// Called on release with the recorded duration (seconds).
    var onSend: (TimeInterval) -> Void

    @State private var recording = false
    @State private var seconds: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            if recording {
                HStack(spacing: VoiidSpacing.sm) {
                    Circle().fill(VoiidColor.error).frame(width: 10, height: 10)
                        .opacity(0.5).scaleEffect(recording ? 1.3 : 1)
                        .animation(.easeInOut(duration: 0.6).repeatForever(), value: recording)
                    Text(timeString).font(VoiidFont.subhead).monospacedDigit()
                        .foregroundColor(VoiidColor.textPrimary)
                    LiveWaveform()
                }
                .padding(.horizontal, VoiidSpacing.md)
                .frame(height: 44)
                .background(VoiidColor.fieldFill)
                .clipShape(Capsule())
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            Image(systemName: "mic.fill")
                .font(.system(size: 22))
                .foregroundColor(recording ? VoiidColor.error : VoiidColor.primary)
                .scaleEffect(recording ? 1.2 : 1)
                .opacity(recording ? 0 : 1)
        }
        .gesture(
            LongPressGesture(minimumDuration: 0.15)
                .onEnded { _ in start() }
                .sequenced(before: DragGesture(minimumDistance: 0).onEnded { _ in stop() })
        )
        .animation(.spring(response: 0.3), value: recording)
    }

    private var timeString: String {
        String(format: "%01d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
    private func start() {
        Haptics.rigid(); recording = true; seconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in seconds += 0.1 }
    }
    private func stop() {
        timer?.invalidate(); recording = false
        if seconds >= 0.5 { Haptics.success(); onSend(seconds) }
    }
}

// MARK: - Live waveform while recording

struct LiveWaveform: View {
    @State private var levels: [CGFloat] = (0..<14).map { _ in CGFloat.random(in: 0.2...1) }
    let t = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule().fill(VoiidColor.primary)
                    .frame(width: 2.5, height: 18 * levels[i])
            }
        }
        .frame(height: 22)
        .onReceive(t) { _ in levels = levels.map { _ in CGFloat.random(in: 0.2...1) } }
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
