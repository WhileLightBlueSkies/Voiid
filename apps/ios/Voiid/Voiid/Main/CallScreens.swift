//
//  CallScreens.swift
//  Voiid
//
//  Call type picker + simulated Voice/Video call screens (1:1 + group).
//  Dummy: Ringing -> Connected with a running timer; controls toggle visually.
//  Follows the VOIID design (background #DFDFDF, SF Pro Rounded, plum/pink palette).
//

import SwiftUI

enum CallKind { case voice, video }

// What a call needs to render (works for 1:1 and group)
struct CallRequest: Identifiable {
    let id = UUID()
    let title: String
    let isGroup: Bool
    let members: [VMember]      // for group grids; empty for 1:1
    let photoName: String?
    let kind: CallKind
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

    @State private var connected = false
    @State private var seconds = 0
    @State private var muted = false
    @State private var speaker = false
    @State private var videoOn = true
    @State private var timer: Timer?

    private var statusText: String {
        if !connected { return request.kind == .video ? "Ringing — Video" : "Ringing…" }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        ZStack {
            background
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
                }

                Spacer()
                // Center content: avatar (voice) or video grid/self
                if request.kind == .voice { voiceCenter } else { videoCenter }
                Spacer()

                controls
                    .padding(.bottom, VoiidSpacing.xxl)
            }
        }
        .onAppear { startCall() }
        .onDisappear { timer?.invalidate() }
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
                // remote "video"
                RoundedRectangle(cornerRadius: 0).fill(.clear)
                // self preview
                RoundedRectangle(cornerRadius: VoiidRadius.lg)
                    .fill(VoiidColor.primary.opacity(0.5))
                    .frame(width: 110, height: 150)
                    .overlay(Image(systemName: videoOn ? "person.fill" : "video.slash.fill")
                        .font(.system(size: 30)).foregroundColor(.white.opacity(0.8)))
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
    private var controls: some View {
        HStack(spacing: VoiidSpacing.xl) {
            ctrl(muted ? "mic.slash.fill" : "mic.fill", muted) { muted.toggle() }
            if request.kind == .video {
                ctrl(videoOn ? "video.fill" : "video.slash.fill", !videoOn) { videoOn.toggle() }
                ctrl("arrow.triangle.2.circlepath.camera.fill", false) {}   // flip camera
            } else {
                ctrl(speaker ? "speaker.wave.2.fill" : "speaker.fill", speaker) { speaker.toggle() }
            }
            // End
            Button { Haptics.rigid(); dismiss() } label: {
                Image(systemName: "phone.down.fill").font(.system(size: 26)).foregroundColor(.white)
                    .frame(width: 64, height: 64).background(VoiidColor.error).clipShape(Circle())
            }
        }
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
