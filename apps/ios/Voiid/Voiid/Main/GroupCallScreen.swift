//
//  GroupCallScreen.swift
//  Voiid
//
//  Real group call UI, backed by LiveKit via `GroupCallService`.
//
//  Deliberately separate from `CallScreen`: the 1:1 screen is real, working code
//  wired to `CallService` and the vendored WebRTC build, and group calls render a
//  different track type entirely (LiveKit's `VideoTrack`, not `RTCVideoTrack`).
//  Keeping them apart means group calling cannot regress 1:1 calling.
//
//  Visual conventions are shared with `CallScreen`: gradient background for video
//  and flat `VoiidColor.background` for voice, 58pt circular controls, a 64pt
//  `VoiidColor.error` end button, and SF Pro Rounded throughout.
//

import SwiftUI
import LiveKit

struct GroupCallScreen: View {
    let conversationId: String
    let title: String
    let kind: CallKind

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var call = GroupCallService.shared

    /// Presents the participant roster. Past a handful of people the tiles are too small to
    /// read a name off, so the roster — not the grid — is what answers "who is here".
    @State private var showRoster = false

    private var isVideo: Bool { kind == .video }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                Spacer().frame(height: 60)
                header
                Spacer(minLength: VoiidSpacing.md)
                content
                Spacer(minLength: VoiidSpacing.md)
                controls.padding(.bottom, VoiidSpacing.xxl)
            }
        }
        .onAppear {
            // Guard: a 1:1 call already owns the audio route.
            guard GroupCallService.canStart() || call.isActive else { return }
            if !call.isActive {
                Task { await call.join(conversationId: conversationId, title: title, isVideo: isVideo) }
            }
        }
        .sheet(isPresented: $showRoster) {
            GroupCallRosterSheet(participants: call.participants)
        }
        .onChange(of: call.state) { _, new in
            // Terminal states close the screen. `.failed` stays up so the user can
            // read why before dismissing.
            if new == .idle { dismiss() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: VoiidSpacing.sm) {
            HStack(spacing: VoiidSpacing.sm) {
                Image(systemName: isVideo ? "video.fill" : "phone.fill")
                    .font(.system(size: 14))
                    .foregroundColor(VoiidColor.textOnPrimary)
                    .frame(width: 30, height: 30)
                    .background(VoiidColor.primary)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(isVideo ? "Group video call" : "Group voice call")
                        .font(VoiidFont.rounded(13, .semibold))
                        .foregroundColor(fg)
                    Text(participantSummary)
                        .font(VoiidFont.rounded(11, .regular))
                        .foregroundColor(fgSecondary)
                }
                // End-to-end encrypted badge — the whole point of routing through
                // an SFU we can't trust with plaintext.
                if call.state == .connected {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundColor(fgSecondary)
                        .accessibilityLabel("End-to-end encrypted")
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, VoiidSpacing.sm)
            .background(isVideo ? Color.white.opacity(0.15) : VoiidColor.surfaceCard)
            .clipShape(Capsule())

            Text(title)
                .font(VoiidFont.rounded(24, .bold))
                .foregroundColor(fg)
            Text(statusText)
                .font(VoiidFont.rounded(14, .regular))
                .foregroundColor(fgSecondary)
        }
    }

    private var participantSummary: String {
        let n = call.participants.count
        return n == 1 ? "Just you" : "\(n) participants"
    }

    private var statusText: String {
        switch call.state {
        case .idle:         return "Call ended"
        case .connecting:   return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .failed(let m): return m
        case .connected:
            let s = call.connectedSeconds
            return String(format: "%02d:%02d", s / 60, s % 60)
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch call.state {
        case .failed(let message):
            failureView(message)
        case .connecting:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(isVideo ? .white : VoiidColor.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            grid
        }
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: VoiidSpacing.md) {
            Image(systemName: call.groupCallingUnavailable ? "person.2.slash" : "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundColor(fgSecondary)
            Text(message)
                .font(VoiidFont.rounded(15, .regular))
                .foregroundColor(fgSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, VoiidSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Adaptive participant grid
    //
    // 1 → single full tile; 2 → stacked halves; 3–4 → 2×2; 5+ → 3-wide, scrolling.

    private var columnCount: Int {
        switch call.participants.count {
        case 0, 1: return 1
        case 2:    return 1     // stacked, each gets full width
        case 3, 4: return 2
        default:   return 3
        }
    }

    /// The grid FILLS the space it is given, rather than scrolling a fixed-aspect list.
    ///
    /// THE OLD LAYOUT COULD NOT FIT. Each tile had a hard `aspectRatio` inside a ScrollView,
    /// so the grid's height was whatever the tiles summed to — never the height available.
    /// With three people that left a band of dead space under the tiles; with six it
    /// overflowed into a scroll, so half the call was off-screen and you had to drag to see
    /// who was talking. A call grid should never scroll: everyone on the call is the content.
    ///
    /// Now the tile size is DERIVED from the container. Rows are computed from the column
    /// count, and each tile takes an equal share of the height minus the gaps — so any
    /// participant count fills the frame exactly, and nobody is below the fold.
    private var grid: some View {
        GeometryReader { geo in
            let count = max(call.participants.count, 1)
            let cols = columnCount
            let rows = Int(ceil(Double(count) / Double(cols)))
            let spacing: CGFloat = 8
            let tileW = (geo.size.width - CGFloat(cols - 1) * spacing) / CGFloat(cols)
            let tileH = (geo.size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(tileW), spacing: spacing), count: cols),
                spacing: spacing
            ) {
                ForEach(call.participants) { p in
                    GroupCallTile(participant: p, isVideoCall: isVideo)
                        .frame(width: tileW, height: tileH)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .padding(.horizontal, VoiidSpacing.md)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: VoiidSpacing.xl) {
            ctrl(call.muted ? "mic.slash.fill" : "mic.fill", call.muted) {
                call.toggleMute()
            }

            if isVideo {
                ctrl(call.videoEnabled ? "video.fill" : "video.slash.fill", !call.videoEnabled) {
                    call.toggleVideo()
                }
                ctrl("arrow.triangle.2.circlepath.camera.fill", false) {
                    call.switchCamera()
                }
            }

            // SPEAKER ON EVERY GROUP CALL, voice AND video.
            //
            // It was voice-only, so a group VIDEO call had no audio control at all — you
            // could not move it to the earpiece, and on a phone that had just been on speaker
            // there was no way back. A video call needs to reach a headset exactly as much as
            // a voice call does; this was simply missing.
            ctrl(call.speakerOn ? "speaker.wave.2.fill" : "speaker.fill", call.speakerOn) {
                call.toggleSpeaker()
            }

            // Who is actually on the call. Past a handful of people the grid tiles get too
            // small to read a name off, and mute state is a corner badge — the roster is where
            // you go to answer "is Priya here, and can she hear us?"
            ctrl("person.2.fill", false) { showRoster = true }

            Button {
                Haptics.rigid()
                Task { await call.leave(); dismiss() }
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.white)
                    .frame(width: 64, height: 64)
                    .background(VoiidColor.error)
                    .clipShape(Circle())
            }
            .accessibilityLabel("Leave call")
        }
    }

    private func ctrl(_ icon: String, _ active: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: { Haptics.tap(); tap() }) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(active ? VoiidColor.primary : fg)
                .frame(width: 58, height: 58)
                .background(active ? VoiidColor.textOnPrimary
                                   : (isVideo ? Color.white.opacity(0.2) : VoiidColor.surfaceCard))
                .clipShape(Circle())
        }
        .disabled(call.state == .connecting || !call.state.isActive)
    }

    // MARK: - Styling helpers

    @ViewBuilder private var background: some View {
        if isVideo {
            LinearGradient(colors: [VoiidColor.primary, .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        } else {
            VoiidColor.background.ignoresSafeArea()
        }
    }

    private var fg: Color { isVideo ? .white : VoiidColor.textPrimary }
    private var fgSecondary: Color {
        isVideo ? .white.opacity(0.85) : VoiidColor.textSecondary
    }
}

// MARK: - One participant tile

private struct GroupCallTile: View {
    let participant: GroupCallParticipant
    let isVideoCall: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .fill(VoiidColor.primary.opacity(0.5))

            if let track = participant.videoTrack, participant.hasVideo {
                // LiveKit's own renderer — it draws LiveKitWebRTC tracks, which are
                // a different type from the RTCVideoTrack that `RTCVideoView` renders.
                SwiftUIVideoView(track,
                                 layoutMode: .fill,
                                 mirrorMode: participant.isLocal ? .mirror : .auto)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            } else {
                VStack(spacing: 6) {
                    VoiidAvatar(size: 56).clipShape(Circle())
                    if !isVideoCall {
                        Text(participant.displayName)
                            .font(VoiidFont.rounded(12, .regular))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                }
            }
        }
        // Speaking indicator: an accent ring, matching the 1:1 avatar treatment.
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidColor.accent, lineWidth: participant.isSpeaking ? 3 : 0)
        )
        .animation(.easeOut(duration: 0.15), value: participant.isSpeaking)
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 4) {
                if participant.isMuted {
                    Image(systemName: "mic.slash.fill").font(.system(size: 9))
                }
                Text(participant.displayName)
                    .font(VoiidFont.rounded(10, .medium))
                    .lineLimit(1)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.black.opacity(0.45))
            .clipShape(Capsule())
            .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [participant.displayName]
        if participant.isMuted { parts.append("muted") }
        if participant.isSpeaking { parts.append("speaking") }
        return parts.joined(separator: ", ")
    }
}
