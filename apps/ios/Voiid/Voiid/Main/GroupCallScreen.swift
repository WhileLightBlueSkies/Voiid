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

    /// Reduce Motion does not mean NO feedback — it means non-vestibular feedback. The grid
    /// is the one place here that moves large objects across the screen (every tile re-lays
    /// out when somebody joins), which is exactly the motion this setting exists to suppress.
    /// The speaking ring and the control press states are opacity/scale on small elements and
    /// stay as they are: removing them would cost information and calm nobody.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The reflow animation, or none at all when the user has asked for less movement.
    private var reflowAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.9)
    }

    private var isVideo: Bool { kind == .video }

    var body: some View {
        ZStack {
            background

            // The grid is the CONTENT and takes every point that is not chrome. The old
            // layout put `Spacer().frame(height: 60)` above the header — a guess at the
            // status bar that is wrong on every device with a Dynamic Island (too small) and
            // wrong on an SE (too large), and it fought the two flexible Spacers below it for
            // the same vertical space. Safe area insets are the real number, and `.safeAreaInset`
            // reserves room for the controls so the grid can size itself against what is left.
            VStack(spacing: VoiidSpacing.sm) {
                header
                content
            }
            .padding(.top, VoiidSpacing.sm)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                controls
                    .padding(.top, VoiidSpacing.md)
                    .padding(.bottom, VoiidSpacing.sm)
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

    /// ONE LINE OF CHROME, NOT FOUR.
    ///
    /// The header used to stack a pill ("Group video call" + "5 participants"), then the
    /// group name at 24pt bold, then a status line — roughly 120pt of vertical space, all of
    /// it taken from the grid, and most of it redundant. "Group video call" restates the
    /// video tiles; the participant count restates the tiles you can see; the group name and
    /// the duration are the only two facts the grid does not already show.
    ///
    /// So: name and status on one line, with the encryption badge beside them. The tiles get
    /// the ~90pt back, which at four rows is a meaningful amount of face.
    private var header: some View {
        HStack(spacing: VoiidSpacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(VoiidFont.rounded(17, .semibold))
                    .foregroundColor(fg)
                    .lineLimit(1)
                Text(statusText)
                    .font(VoiidFont.rounded(12, .regular))
                    .foregroundColor(fgSecondary)
                    .lineLimit(1)
                    // A duration ticking up must not shuffle the layout every second.
                    .monospacedDigit()
            }

            Spacer(minLength: 0)

            // Keying-state badge. The static lock this replaces asserted "end-to-end
            // encrypted" unconditionally; the exchange machinery (CallKeyExchange) can
            // actually FAIL to reach that state — a peer that never sends its commitment
            // tag, or tags that disagree — and an assertion the UI never checks is a
            // claim, not a feature (audit finding M5). The badge now reports what the
            // keying actually settled to for THIS call.
            if call.state == .connected {
                keyingBadge
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
    }

    /// Live verification state for THIS call's media keys, straight from the exchange.
    @ObservedObject private var keyExchange = CallKeyExchange.shared
    /// Ad-hoc (escalated 1:1) rooms key off the CALL id, which lives on the conference
    /// service; conversation-backed rooms derive from MLS and report .verified directly.
    @ObservedObject private var conference = CallConferenceService.shared

    private var keyingState: CallKeyVerification {
        if let id = conference.callId {
            return keyExchange.verificationState(callId: id)
        }
        // A conversation-backed group call is keyed from the MLS exporter: both sides
        // hold it by construction, so the honest state is verified.
        return .verified
    }

    @ViewBuilder private var keyingBadge: some View {
        let state = keyingState
        let (icon, label): (String, String) = {
            switch state {
            case .verified:
                ("lock.fill", "\(participantSummary), end-to-end encrypted, verified")
            case .pending:
                ("lock.badge.clock", "\(participantSummary), checking encryption")
            case .unverified:
                ("exclamationmark.lock", "\(participantSummary), encryption not verified — an older app version may be on the call")
            case .mismatch:
                ("exclamationmark.triangle.fill", "\(participantSummary), encryption check FAILED — verify who is on this call")
            }
        }()
        let tint: Color = {
            switch state {
            case .verified: return fgSecondary
            case .pending: return fgSecondary
            case .unverified: return .yellow
            case .mismatch: return VoiidColor.error
            }
        }()
        Label("\(call.participants.count)", systemImage: icon)
            .font(VoiidFont.rounded(12, .medium))
            .foregroundColor(state == .verified ? fgSecondary : tint)
            .padding(.horizontal, VoiidSpacing.sm)
            .padding(.vertical, 5)
            .background(isVideo ? Color.white.opacity(0.15) : VoiidColor.surfaceCard)
            .clipShape(Capsule())
            .overlay(
                // A mismatch must be findable by more than colour (never hue alone).
                state == .mismatch ? Capsule().stroke(VoiidColor.error, lineWidth: 1.5) : nil
            )
            .accessibilityLabel(label)
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

    /// Columns chosen from the ACTUAL SPACE, not from a lookup table.
    ///
    /// The old table was fixed — 3 columns for any count of 5 or more — so the row count fell
    /// out of it and tile aspect ratios went wherever they landed. On a phone that put 5
    /// people in a 3x2 grid of 122x277 slivers: a portrait video cropped to a letterbox, and
    /// an avatar marooned in a tall empty box. A 12-person call was 3x4 stamps.
    ///
    /// Choosing the column count by measuring instead: for each candidate, score how far the
    /// resulting tile is from a portrait-ish 3:4 and penalise empty slots in the last row.
    /// The same 5 people now get a 2x3 grid of 185x183 — half again as wide, and square
    /// enough for a face. It also adapts to landscape and to iPad for free, where any fixed
    /// table is wrong by construction.
    private func columnCount(for count: Int, in size: CGSize, spacing: CGFloat) -> Int {
        guard count > 1, size.width > 0, size.height > 0 else { return 1 }
        var best = 1
        var bestScore = Double.greatestFiniteMagnitude
        for cols in 1...count {
            let rows = Int(ceil(Double(count) / Double(cols)))
            let tw = (size.width - CGFloat(cols - 1) * spacing) / CGFloat(cols)
            let th = (size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
            guard tw > 0, th > 0 else { continue }
            // log-ratio so 2x too wide and 2x too tall are penalised equally.
            let aspectPenalty = abs(log(Double(tw / th) / 0.75))
            let emptySlots = Double(cols * rows - count)
            let score = aspectPenalty + 0.12 * emptySlots
            if score < bestScore { bestScore = score; best = cols }
        }
        return best
    }

    private var grid: some View {
        GeometryReader { geo in
            let count = max(call.participants.count, 1)
            let spacing: CGFloat = 6
            let cols = columnCount(for: count, in: geo.size, spacing: spacing)
            let rows = Int(ceil(Double(count) / Double(cols)))
            let tileW = (geo.size.width - CGFloat(cols - 1) * spacing) / CGFloat(cols)
            let tileH = (geo.size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)

            // The LAST ROW IS CENTRED when it is not full. With 5 people in a 3-wide grid the
            // old LazyVGrid left the final two hugging the left edge with a tile-sized hole on
            // the right, which reads as a rendering bug rather than a layout. Laying the rows
            // out by hand is the only way to centre a partial row — LazyVGrid always aligns
            // its last row to the leading edge.
            VStack(spacing: spacing) {
                ForEach(0..<rows, id: \.self) { row in
                    let start = row * cols
                    let end = min(start + cols, count)
                    HStack(spacing: spacing) {
                        ForEach(start..<end, id: \.self) { i in
                            GroupCallTile(participant: call.participants[i],
                                          isVideoCall: isVideo,
                                          compact: tileW < 130)
                                .frame(width: tileW, height: tileH)
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            // A join or a leave re-flows every tile; without this they teleport.
            //
            // A SPRING, not a fixed ease. Tiles are physical objects being repositioned, and
            // people join and leave in bursts — a second join landing mid-reflow retargets a
            // spring from wherever the tiles currently are, whereas an ease restarts from a
            // stale value and visibly jumps. Critically damped (0.9): nothing was thrown, so
            // no overshoot is earned; the app's house style for chrome (see RootTabView).
            .animation(reflowAnimation, value: call.participants.count)
        }
        .padding(.horizontal, VoiidSpacing.sm)
    }

    // MARK: - Controls

    /// THE OLD ROW DID NOT FIT ON A PHONE.
    ///
    /// Six controls at 58pt with `VoiidSpacing.xl` (32pt) between them is
    /// 6*58 + 5*32 = 508pt of content. An iPhone SE is 375pt wide and a Pro is 393pt, so on
    /// every device in the line-up the row overflowed its own screen: the end-call button was
    /// pushed off the right edge on a video call, which is the one control that must always be
    /// reachable.
    ///
    /// Now the secondary controls share the available width evenly and the end button is a
    /// fixed anchor, so the row fits at any size and the hang-up never moves.
    private var controls: some View {
        HStack(spacing: 0) {
            ctrl(call.muted ? "mic.slash.fill" : "mic.fill", call.muted,
                 label: call.muted ? "Unmute" : "Mute") {
                call.toggleMute()
            }
            .frame(maxWidth: .infinity)

            if isVideo {
                ctrl(call.videoEnabled ? "video.fill" : "video.slash.fill", !call.videoEnabled,
                     label: call.videoEnabled ? "Turn camera off" : "Turn camera on") {
                    call.toggleVideo()
                }
                .frame(maxWidth: .infinity)

                ctrl("arrow.triangle.2.circlepath.camera.fill", false, label: "Flip camera") {
                    call.switchCamera()
                }
                .frame(maxWidth: .infinity)
            }

            // SPEAKER ON EVERY GROUP CALL, voice AND video. A group video call had no audio
            // control at all — it could not be moved to the earpiece or a headset.
            ctrl(call.speakerOn ? "speaker.wave.2.fill" : "speaker.fill", call.speakerOn,
                 label: call.speakerOn ? "Speaker on" : "Speaker off") {
                call.toggleSpeaker()
            }
            .frame(maxWidth: .infinity)

            // Who is actually on the call. Past a handful of people the tiles are too small to
            // read a name off and mute state is a corner badge — the roster answers "is Priya
            // here, and can she hear us?"
            ctrl("person.2.fill", false, label: "Participants") { showRoster = true }
                .frame(maxWidth: .infinity)

            // The end button is NOT in the flexible run: it keeps a fixed size and sits at the
            // trailing edge so it lands in the same place on every call, voice or video.
            Button {
                // Kept despite the press haptic from SoftPressStyle, and deliberately: this
                // is a COMMIT, not a press. Leaving a call is irreversible from here, so the
                // heavier confirmation on the action is doing different work from the light
                // press acknowledgement — the one case where two are justified.
                Haptics.rigid()
                Task { await call.leave(); dismiss() }
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .background(VoiidColor.error)
                    .clipShape(Circle())
            }
            // Feedback on press-DOWN, not on release. A 60pt button that only reacts when
            // the finger lifts reads as dead for the whole duration of the press — the one
            // latency users feel most on the control they care most about.
            .buttonStyle(SoftPressStyle(scale: 0.92))
            .accessibilityLabel("Leave call")
            .padding(.leading, VoiidSpacing.sm)
        }
        .padding(.horizontal, VoiidSpacing.md)
    }

    private func ctrl(_ icon: String, _ active: Bool, label: String,
                      _ tap: @escaping () -> Void) -> some View {
        // NO haptic here: SoftPressStyle already fires one on press-DOWN, which is both
        // earlier and the actual causal moment. Firing another on action buzzed twice for a
        // single press — over-feedback, which trains people to ignore all of it (skill §13).
        Button(action: tap) {
            Image(systemName: icon)
                .font(.system(size: 21))
                .foregroundColor(active ? VoiidColor.primary : fg)
                .frame(width: 52, height: 52)
                .background(active ? VoiidColor.textOnPrimary
                                   : (isVideo ? Color.white.opacity(0.2) : VoiidColor.surfaceCard))
                .clipShape(Circle())
        }
        .buttonStyle(SoftPressStyle())
        // A toggled control (mute, speaker, camera) inverts its colours. Springing that
        // means double-tapping mute retargets from the current blend rather than snapping.
        .animation(.spring(response: 0.25, dampingFraction: 1.0), value: active)
        .disabled(call.state == .connecting || !call.state.isActive)
        .accessibilityLabel(label)
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
    /// True once the tile is too narrow to carry full-size chrome (a 4-wide grid on a phone).
    /// Drives the avatar size and hides the name, rather than letting both clip.
    var compact: Bool = false

    /// The participant's REAL avatar, looked up by the user half of the LiveKit identity.
    ///
    /// Every tile used to draw `VoiidAvatar()`, which takes no participant and renders the
    /// literal word "voiid" — so a voice call was a grid of identical placeholder boxes with
    /// no way to tell who was who. `ProfileAvatarButton` is the same component the 1:1 call
    /// screen uses: it presigns an R2 key, falls back to initials, and finally to a person
    /// glyph.
    private var photoURL: String? { UserDirectory.shared.photoURL(participant.userId) }

    private var avatarSize: CGFloat { compact ? 40 : 56 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .fill(VoiidColor.primary.opacity(0.5))

            if let track = participant.videoTrack, participant.hasVideo {
                // LiveKit's own renderer — it draws LiveKitWebRTC tracks, which are a
                // different type from the RTCVideoTrack that `RTCVideoView` renders.
                SwiftUIVideoView(track,
                                 layoutMode: .fill,
                                 mirrorMode: participant.isLocal ? .mirror : .auto)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            } else {
                ProfileAvatarButton(photoURL: photoURL,
                                    name: participant.displayName,
                                    size: avatarSize)
                    .allowsHitTesting(false)   // decoration here, not a button
            }
        }
        // Speaking indicator: an accent ring, matching the 1:1 avatar treatment. Inset so the
        // stroke is drawn INSIDE the tile — a centred 3pt stroke put half its width outside
        // the shape, where the neighbouring tile's clip cut it off, so the ring appeared as
        // three sides and a gap in every grid position but the last column.
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .inset(by: 1.5)
                .stroke(VoiidColor.accent, lineWidth: participant.isSpeaking ? 3 : 0)
        )
        // Critically damped and quick. This retriggers on every syllable-level change in
        // speech, so ANY overshoot would read as a pulsing ring rather than an indicator —
        // this is the one place where bounce is actively wrong.
        .animation(.spring(response: 0.22, dampingFraction: 1.0), value: participant.isSpeaking)
        .overlay(alignment: .bottomLeading) { nameplate }
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Name + mute badge.
    ///
    /// On a VOICE call the name used to be drawn twice — once under the avatar and again in
    /// this nameplate — which on a small tile stacked two copies of the same string on top of
    /// each other. There is one nameplate now, and on a tile too narrow to hold a name it
    /// degrades to the mute badge alone rather than clipping mid-word.
    @ViewBuilder private var nameplate: some View {
        if compact {
            if participant.isMuted {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.white)
                    .padding(4)
                    .background(.black.opacity(0.5), in: Circle())
                    .padding(5)
            }
        } else {
            HStack(spacing: 4) {
                if participant.isMuted {
                    Image(systemName: "mic.slash.fill").font(.system(size: 9))
                }
                Text(participant.isLocal ? "You" : participant.displayName)
                    .font(VoiidFont.rounded(10, .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.black.opacity(0.45))
            .clipShape(Capsule())
            .padding(6)
        }
    }

    private var accessibilityText: String {
        var parts = [participant.isLocal ? "You" : participant.displayName]
        if participant.isMuted { parts.append("muted") }
        if participant.isSpeaking { parts.append("speaking") }
        return parts.joined(separator: ", ")
    }
}
