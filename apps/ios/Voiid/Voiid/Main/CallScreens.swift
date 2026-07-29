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
        Button(action: { Haptics.tap(); tap() }) {
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

    // Group calls are still simulated (a later increment); 1:1 uses CallService.
    @State private var connected = false
    @State private var seconds = 0
    @State private var muted = false
    @State private var speaker = false
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
            VoiidAvatar(size: 160, imageName: request.photoName).clipShape(Circle())
                .overlay(Circle().stroke(VoiidColor.accent, lineWidth: 3))
        }
    }

    // MARK: video center
    @ViewBuilder private var videoCenter: some View {
        if request.isGroup {
            participantGrid(video: true)
        } else {
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                // Self preview: real local camera for a live 1:1 call, else placeholder.
                Group {
                    if isRealOneToOne, call.videoEnabled, let localTrack = call.localVideoTrack {
                        RTCVideoView(track: localTrack, mirror: true)
                    } else {
                        RoundedRectangle(cornerRadius: VoiidRadius.lg)
                            .fill(VoiidColor.primary.opacity(0.5))
                            .overlay(Image(systemName: "video.slash.fill")
                                .font(.system(size: 30)).foregroundColor(.white.opacity(0.8)))
                    }
                }
                .frame(width: 110, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg))
                .padding(VoiidSpacing.lg)
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
            HStack(spacing: showHold ? VoiidSpacing.md : VoiidSpacing.xl) {
                let isMuted = isRealOneToOne ? call.muted : muted
                ctrl(isMuted ? "mic.slash.fill" : "mic.fill", isMuted) {
                    if isRealOneToOne { call.toggleMute() } else { muted.toggle() }
                }
                if request.kind == .video {
                    let vOn = isRealOneToOne ? call.videoEnabled : videoOn
                    ctrl(vOn ? "video.fill" : "video.slash.fill", !vOn) {
                        if isRealOneToOne { call.toggleVideo() } else { videoOn.toggle() }
                    }
                    ctrl("arrow.triangle.2.circlepath.camera.fill", false) {
                        if isRealOneToOne { call.switchCamera() }
                    }
                }
                // Audio-route control on EVERY call, voice and video alike — a video call
                // needs to reach AirPods just as much as a voice call does.
                audioRouteControl(isRealOneToOne: isRealOneToOne)
                if showHold {
                    ctrl(call.isOnHold ? "play.fill" : "pause.fill", call.isOnHold) {
                        call.toggleHold()
                    }
                }
                // End
                Button { Haptics.rigid(); endTapped() } label: {
                    Image(systemName: "phone.down.fill").font(.system(size: 26)).foregroundColor(.white)
                        .frame(width: 64, height: 64).background(VoiidColor.error).clipShape(Circle())
                }
            }
        }
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
        Button(action: { Haptics.tap(); tap() }) {
            Image(systemName: icon).font(.system(size: 22))
                .foregroundColor(active ? VoiidColor.primary : (request.kind == .video ? .white : VoiidColor.textPrimary))
                .frame(width: 58, height: 58)
                .background(active ? VoiidColor.textOnPrimary : (request.kind == .video ? .white.opacity(0.2) : VoiidColor.surfaceCard))
                .clipShape(Circle())
        }
    }

    private func startCall() {
        // simulate connect after ~2s, then run the timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { connected = true }
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in seconds += 1 }
        }
    }
}
