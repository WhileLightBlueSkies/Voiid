//
//  CallScreens.swift
//  Voiid
//
//  Call type picker + simulated Voice/Video call screens (1:1 + group).
//  Dummy: Ringing -> Connected with a running timer; controls toggle visually.
//  Follows the VOIID design (Peacock tokens, SF Pro Rounded).
//

import SwiftUI
import WebRTC

enum CallKind { case voice, video }

// What a call needs to render (works for 1:1 and group)
struct CallRequest: Identifiable {
    let id = UUID()
    let title: String
    let isGroup: Bool
    let members: [VMember]      // for group grids; empty for 1:1
    let photoName: String?
    let kind: CallKind
    /// The 1:1 peer's user id — required to actually place a real WebRTC call.
    /// nil for group calls (which route through LiveKit instead) or previews.
    var peerUserId: String? = nil
    /// The conversation this call belongs to. Required for a real group call: it
    /// resolves both the LiveKit room and the MLS group the E2EE key derives from.
    /// nil for 1:1 calls and previews.
    var conversationId: String? = nil
}

// MARK: - WebRTC video renderer (Metal)

/// Renders an `RTCVideoTrack` in SwiftUI via `RTCMTLVideoView`.
struct RTCVideoView: UIViewRepresentable {
    let track: RTCVideoTrack?
    var mirror: Bool = false

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView()
        v.videoContentMode = .scaleAspectFill
        v.transform = mirror ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        return v
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        if context.coordinator.track !== track {
            context.coordinator.track?.remove(uiView)
            track?.add(uiView)
            context.coordinator.track = track
        }
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var track: RTCVideoTrack? }
}

// MARK: - Voice/Video picker (small branded sheet)

struct CallTypeSheet: View {
    let title: String
    var onPick: (CallKind) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: VoiidSpacing.lg) {
            Capsule().fill(VoiidColor.divider).frame(width: 40, height: 4).padding(.top, VoiidSpacing.sm)
            Text("Call \(title)")
                .font(VoiidFont.rounded(18, .semibold)).foregroundColor(VoiidColor.textPrimary)

            HStack(spacing: VoiidSpacing.md) {
                card("Voice", "phone.fill") { onPick(.voice); dismiss() }
                card("Video", "video.fill") { onPick(.video); dismiss() }
            }
            .padding(.horizontal, VoiidSpacing.lg)

            Button("Cancel") { dismiss() }
                .font(VoiidFont.rounded(15, .regular)).foregroundColor(VoiidColor.textSecondary)
                .padding(.bottom, VoiidSpacing.lg)
        }
        .background(VoiidColor.background.ignoresSafeArea())
        .presentationDetents([.height(240)])
    }

    private func card(_ label: String, _ icon: String, _ tap: @escaping () -> Void) -> some View {
        // No haptic here: SoftPressStyle below already fires one on press-DOWN, which is
        // earlier and is the causal moment. Two per press is over-feedback.
        Button(action: tap) {
            VStack(spacing: VoiidSpacing.sm) {
                Image(systemName: icon).font(.system(size: 30)).foregroundColor(VoiidColor.textOnPrimary)
                    .frame(width: 64, height: 64).background(VoiidColor.primary).clipShape(Circle())
                Text(label).font(VoiidFont.rounded(15, .medium)).foregroundColor(VoiidColor.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, VoiidSpacing.lg)
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        }
        .buttonStyle(SoftPressStyle())
    }
}

// MARK: - Call screen (voice + video, 1:1 + group)

struct CallScreen: View {
    let request: CallRequest
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var call = CallService.shared
    /// The conference engine. Its backend has shipped with 32 guard tests; until now
    /// nothing in the UI referenced it, so escalation was unreachable.
    @ObservedObject private var conference = CallConferenceService.shared
    /// Forwarded explicitly into the sheet below. A sheet presented from inside a
    /// fullScreenCover does NOT reliably inherit the root's environment objects, and the
    /// failure is a runtime crash rather than a compile error — so it is passed by hand.
    @EnvironmentObject private var chat: ChatStore
    @State private var showAddPerson = false

    // Group calls are still simulated (a later increment); 1:1 uses CallService.
    @State private var connected = false
    @State private var seconds = 0
    @State private var muted = false
    @State private var speaker = false
    /// The peer's real photo, resolved from the directory. `request.photoName` is a bundled
    /// asset name from the dummy era and cannot name a real person's avatar.
    private var peerPhotoURL: String? {
        request.peerUserId.flatMap { UserDirectory.shared.photoURL($0) }
    }

    /// True once the call is actually up — the pulse is for RINGING, not for a live call.
    private var isConnected: Bool {
        call.active?.state == .connected
    }

    /// Drives the ringing pulse. A plain Bool toggled once in `onAppear` — a repeating
    /// animation needs a value that CHANGES to start, and `true` on appear is the cheapest
    /// one that cannot get out of sync with anything else.
    @State private var ringPulse = false
    /// Which corner the self-preview is parked in. Persisted for the life of the call only —
    /// a corner choice is about THIS call's framing, not a lasting preference.
    @State private var previewCorner: PreviewCorner = .topTrailing
    @State private var videoOn = true
    @State private var timer: Timer?

    /// A real 1:1 call is one with a peer id and not a group.
    private var isRealOneToOne: Bool { !request.isGroup && request.peerUserId != nil }

    /// A real group call is one with a conversation id, which we need to resolve the
    /// LiveKit room and derive the MLS call key. Without it we fall back to the
    /// simulated screen (previews, and call sites that don't carry the conversation).
    private var isRealGroup: Bool { request.isGroup && request.conversationId != nil }

    private var liveState: CallState? { isRealOneToOne ? call.active?.state : nil }

    /// Mid-call ICE restart in progress. Surfaced prominently because the
    /// alternative reading of a frozen call is "it's dead" — and the user hangs
    /// up on a call that was about to recover.
    private var isReconnecting: Bool {
        isRealOneToOne && call.isReconnecting
            && (liveState == .connected || liveState == .connecting)
    }

    private var statusText: String {
        if isRealOneToOne {
            switch call.active?.state {
            case .some(.connected):
                if call.isReconnecting { return "Reconnecting…" }
                if call.isOnHold { return "On hold" }
                if call.peerOnHold { return "\(request.title) is on hold" }
                return String(format: "%02d:%02d", call.connectedSeconds / 60, call.connectedSeconds % 60)
            case .some(.incomingRinging): return request.kind == .video ? "Incoming video call" : "Incoming call"
            case .some(.connecting): return call.isReconnecting ? "Reconnecting…" : "Connecting…"
            case .some(.ended), .none: return "Call ended"
            default: return request.kind == .video ? "Ringing — Video" : "Ringing…"
            }
        }
        if !connected { return request.kind == .video ? "Ringing — Video" : "Ringing…" }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        // Real group calls hand off to the LiveKit-backed screen entirely; the
        // simulated path below now only serves previews and 1:1 calls.
        if isRealGroup, let cid = request.conversationId {
            GroupCallScreen(conversationId: cid, title: request.title, kind: request.kind)
        } else {
            simulatedOrOneToOneBody
        }
    }

    private var simulatedOrOneToOneBody: some View {
        ZStack {
            background
            // Real remote video fills the screen behind the overlay (1:1 video calls).
            // Rendered through the shared sample-buffer layer rather than
            // RTCMTLVideoView — RTCMTLVideoView cannot be picture-in-picture'd, and
            // this is the same layer the system PiP window draws from.
            if isRealOneToOne, request.kind == .video, call.remoteVideoTrack != nil {
                CallRemoteVideoView().ignoresSafeArea()
            }
            // Minimize: shrink to the in-app floating window, call keeps running.
            if isRealOneToOne, liveState == .connected || liveState == .connecting {
                VStack {
                    HStack {
                        Button {
                            Haptics.tap()
                            call.minimizeCallUI()
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(request.kind == .video ? .white : VoiidColor.textPrimary)
                                .frame(width: 38, height: 38)
                                .background(request.kind == .video
                                            ? Color.white.opacity(0.2) : VoiidColor.surfaceCard)
                                .clipShape(Circle())
                        }
                        .accessibilityLabel("Minimize call")
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.top, VoiidSpacing.md)
                .zIndex(1)
            }
            VStack(spacing: 0) {
                Spacer().frame(height: 60)
                // Group call banner card
                if request.isGroup {
                    HStack(spacing: VoiidSpacing.sm) {
                        Image(systemName: request.kind == .video ? "video.fill" : "phone.fill")
                            .font(.system(size: 14)).foregroundColor(VoiidColor.textOnPrimary)
                            .frame(width: 30, height: 30).background(VoiidColor.primary).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 0) {
                            Text(request.kind == .video ? "Group video call" : "Group voice call")
                                .font(VoiidFont.rounded(13, .semibold))
                                .foregroundColor(request.kind == .video ? .white : VoiidColor.textPrimary)
                            Text("\(request.members.count) participants")
                                .font(VoiidFont.rounded(11, .regular))
                                .foregroundColor(request.kind == .video ? .white.opacity(0.8) : VoiidColor.textSecondary)
                        }
                    }
                    .padding(.horizontal, VoiidSpacing.md).padding(.vertical, VoiidSpacing.sm)
                    .background((request.kind == .video ? Color.white.opacity(0.15) : VoiidColor.surfaceCard))
                    .clipShape(Capsule())
                    .padding(.bottom, VoiidSpacing.md)
                }
                // Title + status
                VStack(spacing: 6) {
                    Text(request.title)
                        .font(VoiidFont.rounded(24, .bold))
                        .foregroundColor(request.kind == .video ? .white : VoiidColor.textPrimary)
                    Text(statusText)
                        .font(VoiidFont.rounded(14, .regular))
                        .foregroundColor(request.kind == .video ? .white.opacity(0.85) : VoiidColor.textSecondary)
                    if isReconnecting { reconnectingBadge }
                    else if isRealOneToOne, call.isOnHold || call.peerOnHold { holdBadge }
                }
                .animation(.easeInOut(duration: 0.2), value: isReconnecting)

                Spacer()
                // Center content: avatar (voice) or video grid/self
                if request.kind == .voice { voiceCenter } else { videoCenter }
                Spacer()

                controls
                    .padding(.bottom, VoiidSpacing.xxl)
            }
        }
        .onAppear {
            onAppearStart()
            if isRealOneToOne { call.setCallUIVisible(true) }
        }
        .onDisappear {
            timer?.invalidate()
            if isRealOneToOne { call.setCallUIVisible(false) }
        }
        .onChange(of: call.active?.state) { _, newState in
            // A real 1:1 call reached a terminal state → close the screen.
            if isRealOneToOne, (newState == nil || newState == .ended) {
                dismiss()
            }
        }
        .sheet(isPresented: $showAddPerson) { addPersonSheet }
    }

    private func onAppearStart() {
        if isRealOneToOne {
            // Outgoing: no active call yet → place it. Incoming: already active → just observe.
            if call.active == nil, let peer = request.peerUserId {
                call.startCall(peerUserId: peer, title: request.title,
                               isVideo: request.kind == .video,
                               conversationId: request.conversationId)
            }
        } else {
            startCall()   // group: simulated
        }
    }

    // MARK: status badges

    /// Subtle, non-alarming: the call is recovering, not failing.
    private var reconnectingBadge: some View {
        HStack(spacing: 6) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
                .tint(request.kind == .video ? .white : VoiidColor.textSecondary)
            Text("Reconnecting…")
                .font(VoiidFont.rounded(11, .medium))
                .foregroundColor(request.kind == .video ? .white.opacity(0.9) : VoiidColor.textSecondary)
        }
        .padding(.horizontal, VoiidSpacing.sm)
        .padding(.vertical, 4)
        .background(request.kind == .video ? Color.white.opacity(0.18) : VoiidColor.surfaceCard)
        .clipShape(Capsule())
        .accessibilityLabel("Reconnecting")
        .transition(.opacity)
    }

    private var holdBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle.fill").font(.system(size: 11))
            Text(call.isOnHold ? "You put this call on hold" : "On hold")
                .font(VoiidFont.rounded(11, .medium))
        }
        .foregroundColor(request.kind == .video ? .white.opacity(0.9) : VoiidColor.textSecondary)
        .padding(.horizontal, VoiidSpacing.sm)
        .padding(.vertical, 4)
        .background(request.kind == .video ? Color.white.opacity(0.18) : VoiidColor.surfaceCard)
        .clipShape(Capsule())
        .transition(.opacity)
    }

    // MARK: backgrounds
    @ViewBuilder private var background: some View {
        if request.kind == .video {
            LinearGradient(colors: [VoiidColor.primary, .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        } else {
            VoiidColor.background.ignoresSafeArea()
        }
    }

    // MARK: voice center
    @ViewBuilder private var voiceCenter: some View {
        if request.isGroup {
            participantGrid(video: false)
        } else {
            // THE PEER'S REAL FACE, not the wordmark. `VoiidAvatar(imageName:)` is a
            // BUNDLED-ASSET lookup left over from dummy data, so the one screen where knowing
            // who you are talking to matters most showed a logo for every real contact.
            // `ProfileAvatarButton` resolves the photo through the shared cache and falls
            // back to their initials, which is at least a person.
            ZStack {
                // A slow pulse behind the avatar while the call is not yet connected. A
                // ringing call is a live event and a completely static screen reads as a
                // screenshot — but this is on screen while the phone is buzzing, so it is
                // deliberately gentle rather than attention-seeking.
                if !isConnected {
                    Circle()
                        .fill(.white.opacity(0.10))
                        .frame(width: 190, height: 190)
                        .scaleEffect(ringPulse ? 1.06 : 0.94)
                        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                                   value: ringPulse)
                }
                ProfileAvatarButton(photoURL: peerPhotoURL, name: request.title, size: 160)
                    .overlay(Circle().stroke(VoiidColor.accent, lineWidth: 3))
            }
            .onAppear { ringPulse = true }
        }
    }

    // MARK: video center
    @ViewBuilder private var videoCenter: some View {
        if request.isGroup {
            participantGrid(video: true)
        } else {
            GeometryReader { geo in
                SelfPreview(
                    corner: $previewCorner,
                    isMirrored: true,
                    canFlip: isRealOneToOne,
                    onFlip: { call.switchCamera() }
                ) {
                    if isRealOneToOne, call.videoEnabled, let localTrack = call.localVideoTrack {
                        RTCVideoView(track: localTrack, mirror: true)
                    } else {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(VoiidColor.primary.opacity(0.5))
                            .overlay(Image(systemName: "video.slash.fill")
                                .font(.system(size: 26)).foregroundColor(.white.opacity(0.8)))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // group grid of participants (avatars for voice, tiles for video)
    private func participantGrid(video: Bool) -> some View {
        let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: cols, spacing: 8) {
            ForEach(request.members) { m in
                ZStack {
                    if video {
                        RoundedRectangle(cornerRadius: VoiidRadius.lg).fill(VoiidColor.primary.opacity(0.5))
                            .aspectRatio(0.8, contentMode: .fit)
                            .overlay(VoiidAvatar(size: 56).clipShape(Circle()))
                    } else {
                        VStack(spacing: 6) {
                            VoiidAvatar(size: 72).clipShape(Circle())
                            Text(m.isYou ? "You" : m.name).font(VoiidFont.rounded(12, .regular)).foregroundColor(VoiidColor.textPrimary)
                        }
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    Text(m.isYou ? "You" : m.name)
                        .font(VoiidFont.rounded(10, .medium)).foregroundColor(.white)
                        .padding(4).background(.black.opacity(0.4)).clipShape(Capsule())
                        .padding(6)
                        .opacity(video ? 1 : 0)
                }
            }
        }
        .padding(.horizontal, VoiidSpacing.lg)
    }

    // MARK: controls
    @ViewBuilder private var controls: some View {
        // Incoming 1:1 call awaiting the user's decision → Accept / Decline.
        if isRealOneToOne, liveState == .incomingRinging {
            HStack(spacing: VoiidSpacing.xxl) {
                Button { Haptics.rigid(); call.decline() } label: {
                    Image(systemName: "phone.down.fill").font(.system(size: 26)).foregroundColor(.white)
                        .frame(width: 64, height: 64).background(VoiidColor.error).clipShape(Circle())
                }
                Button { Haptics.tap(); call.accept() } label: {
                    Image(systemName: request.kind == .video ? "video.fill" : "phone.fill")
                        .font(.system(size: 26)).foregroundColor(.white)
                        .frame(width: 64, height: 64).background(Color.green).clipShape(Circle())
                }
            }
        } else {
            // Hold is only offered on a real, connected 1:1 call — there is
            // nothing to hold before that, and the group path doesn't support it.
            let showHold = isRealOneToOne && liveState == .connected
            // EVENLY DISTRIBUTED, not fixed-spacing.
            //
            // THE OVERFLOW. A video call shows mic, camera, flip, route, hold and end — six
            // 64pt controls with 16–32pt gaps, which needs 460–540pt of width. A 390pt phone
            // does not have it, so the end button ran off the right edge and the row was
            // clipped (visible in the screenshot: the red button is half off-screen).
            //
            // `maxWidth: .infinity` on each control lets them share whatever width exists,
            // so the row fits at any control count and on any device. The camera FLIP is
            // gone from here entirely — it now lives on the self-preview, where what it
            // affects is what you are looking at.
            HStack(spacing: 0) {
                let isMuted = isRealOneToOne ? call.muted : muted
                ctrl(isMuted ? "mic.slash.fill" : "mic.fill", isMuted) {
                    if isRealOneToOne { call.toggleMute() } else { muted.toggle() }
                }
                .frame(maxWidth: .infinity)

                if request.kind == .video {
                    let vOn = isRealOneToOne ? call.videoEnabled : videoOn
                    ctrl(vOn ? "video.fill" : "video.slash.fill", !vOn) {
                        if isRealOneToOne { call.toggleVideo() } else { videoOn.toggle() }
                    }
                    .frame(maxWidth: .infinity)
                }

                // Audio-route control on EVERY call, voice and video alike — a video call
                // needs to reach AirPods just as much as a voice call does.
                audioRouteControl(isRealOneToOne: isRealOneToOne)
                    .frame(maxWidth: .infinity)

                if showHold {
                    ctrl(call.isOnHold ? "play.fill" : "pause.fill", call.isOnHold) {
                        call.toggleHold()
                    }
                    .frame(maxWidth: .infinity)
                }

                // ADD SOMEONE — turns this 1:1 into a conference.
                //
                // `canEscalate` is the engine's own gate: a connected 1:1 that is not itself
                // a conference invite. Hidden rather than disabled, because the row is width
                // constrained (see the overflow note above) and a permanently dead control
                // would cost space every other button needs.
                if conference.canEscalate {
                    ctrl("person.badge.plus", false) {
                        Haptics.tap(); showAddPerson = true
                    }
                    .frame(maxWidth: .infinity)
                }

                // End
                Button { Haptics.rigid(); endTapped() } label: {
                    Image(systemName: "phone.down.fill").font(.system(size: 24)).foregroundColor(.white)
                        .frame(width: 60, height: 60).background(VoiidColor.error).clipShape(Circle())
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, VoiidSpacing.sm)
        }
    }

    /// Present the picker. A conference is keyed on the CALL, so this asks for a person,
    /// never a conversation — inviting someone must not create or imply one.
    @ViewBuilder private var addPersonSheet: some View {
        ConferenceInviteSheet { userId in
            showAddPerson = false
            Task { await conference.escalate(inviteeUserId: userId) }
        } onCancel: {
            showAddPerson = false
        }
        .environmentObject(chat)
    }

    private func endTapped() {
        if isRealOneToOne { call.hangUp() } else { dismiss() }
    }

    /// Audio-output control.
    ///
    /// With only earpiece + speaker available it is a plain speaker toggle (unchanged
    /// behaviour). The moment a Bluetooth or wired device is connected it becomes a Menu
    /// listing every route with the live one checked — so the user can send the call to
    /// their headset, or pull it back to the phone, on any call type.
    ///
    /// Group calls route through LiveKit, not CallService's session, so they keep the simple
    /// local speaker toggle.
    @ViewBuilder
    private func audioRouteControl(isRealOneToOne: Bool) -> some View {
        if isRealOneToOne {
            let routes = call.audioRoutes
            let current = call.currentRoute
            if routes.count > 2 {
                Menu {
                    ForEach(routes) { route in
                        Button {
                            Haptics.tap(); call.selectAudioRoute(route)
                        } label: {
                            Label(route.label, systemImage: route == current ? "checkmark" : route.symbol)
                        }
                    }
                } label: {
                    routeGlyph(current.symbol, active: current != .earpiece)
                }
                .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
            } else {
                ctrl(current == .speaker ? "speaker.wave.2.fill" : "speaker.fill",
                     current == .speaker) { call.toggleSpeaker() }
            }
        } else {
            ctrl(speaker ? "speaker.wave.2.fill" : "speaker.fill", speaker) { speaker.toggle() }
        }
    }

    /// The `ctrl` chrome without a Button, so it can back a Menu label.
    private func routeGlyph(_ icon: String, active: Bool) -> some View {
        Image(systemName: icon).font(.system(size: 22))
            .foregroundColor(active ? VoiidColor.primary : (request.kind == .video ? .white : VoiidColor.textPrimary))
            .frame(width: 58, height: 58)
            .background(active ? VoiidColor.textOnPrimary : (request.kind == .video ? .white.opacity(0.2) : VoiidColor.surfaceCard))
            .clipShape(Circle())
    }

    private func ctrl(_ icon: String, _ active: Bool, _ tap: @escaping () -> Void) -> some View {
        // Feedback on press-DOWN (SoftPressStyle), not on release. These reacted only when
        // the finger lifted, so a press registered as nothing at all until it ended — the
        // same treatment the group call controls now get, on the sibling screen.
        Button(action: tap) {
            Image(systemName: icon).font(.system(size: 22))
                .foregroundColor(active ? VoiidColor.primary : (request.kind == .video ? .white : VoiidColor.textPrimary))
                .frame(width: 58, height: 58)
                .background(active ? VoiidColor.textOnPrimary : (request.kind == .video ? .white.opacity(0.2) : VoiidColor.surfaceCard))
                .clipShape(Circle())
        }
        .buttonStyle(SoftPressStyle())
        // A toggled control (mute, speaker, camera) inverts its colours; springing that means
        // a rapid double-tap retargets from the current blend rather than snapping.
        .animation(.spring(response: 0.25, dampingFraction: 1.0), value: active)
    }

    private func startCall() {
        // simulate connect after ~2s, then run the timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { connected = true }
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in seconds += 1 }
        }
    }
}

// MARK: - Self preview

/// Which corner the self-view sits in.
enum PreviewCorner: CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var alignment: Alignment {
        switch self {
        case .topLeading:     return .topLeading
        case .topTrailing:    return .topTrailing
        case .bottomLeading:  return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    /// The corner nearest a point in a container of `size` — used to snap after a drag.
    static func nearest(to point: CGPoint, in size: CGSize) -> PreviewCorner {
        let left = point.x < size.width / 2
        let top = point.y < size.height / 2
        switch (top, left) {
        case (true, true):   return .topLeading
        case (true, false):  return .topTrailing
        case (false, true):  return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }
}

/// A draggable self-view that snaps to whichever corner you release it near, with the camera
/// flip on the preview itself.
///
/// WHY THE FLIP MOVED HERE. It was a sixth button in the bottom control row — a row that
/// already overflowed a 390pt screen — and it acts on the self-view, which is at the OTHER
/// end of the display. Putting it on the thing it affects means the control and its result
/// are the same object, and the bottom row loses a button it did not have room for.
///
/// WHY IT DRAGS. A fixed corner always covers something eventually: the other person's face
/// drifts, or a caption sits underneath it. Every video app solves this the same way, and
/// snapping to corners rather than free-floating keeps the layout predictable — you cannot
/// leave it half off-screen or dead-centre over the remote video.
struct SelfPreview<Content: View>: View {
    @Binding var corner: PreviewCorner
    var isMirrored: Bool
    var canFlip: Bool
    var onFlip: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var drag: CGSize = .zero
    @State private var dragging = false

    private let size = CGSize(width: 104, height: 140)
    private let margin: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            content()
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if canFlip {
                        Button {
                            Haptics.tap(); onFlip()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(.black.opacity(0.45), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                    }
                }
                // A hairline so a dark preview against a dark remote frame still has an edge.
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: dragging ? 18 : 12, y: 4)
                // Lifts while held, so the drag reads as picking the tile up.
                .scaleEffect(dragging ? 1.04 : 1)
                .offset(drag)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
                .padding(margin)
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            if !dragging { dragging = true; Haptics.tap() }
                            drag = v.translation
                        }
                        .onEnded { v in
                            // SNAP TO WHERE THE THROW WAS GOING, not to where the finger
                            // stopped. Using `translation` alone ignored velocity entirely,
                            // so a fast flick toward the far corner landed in the near one —
                            // the tile stopped dead at the fingertip instead of carrying the
                            // momentum the gesture had. `predictedEndTranslation` is UIKit's
                            // own deceleration projection (the same curve scroll views use),
                            // so the corner is chosen from the projected resting point.
                            //
                            // Still measured from the tile's CURRENT corner rather than from
                            // the touch, so a slow nudge with no momentum behaves as before
                            // and does not fling across the screen.
                            let origin = anchorPoint(for: corner, in: geo.size)
                            let projected = CGPoint(
                                x: origin.x + v.predictedEndTranslation.width,
                                y: origin.y + v.predictedEndTranslation.height)
                            let target = PreviewCorner.nearest(to: projected, in: geo.size)
                            if target != corner { Haptics.selection() }
                            // Bounce only because a THROW preceded it: momentum-carrying
                            // gestures earn overshoot, a tap-driven move does not.
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                                corner = target
                                drag = .zero
                                dragging = false
                            }
                        }
                )
        }
    }

    /// The tile's centre when parked in `corner`.
    private func anchorPoint(for corner: PreviewCorner, in container: CGSize) -> CGPoint {
        let x = corner == .topLeading || corner == .bottomLeading
            ? margin + size.width / 2
            : container.width - margin - size.width / 2
        let y = corner == .topLeading || corner == .topTrailing
            ? margin + size.height / 2
            : container.height - margin - size.height / 2
        return CGPoint(x: x, y: y)
    }
}
