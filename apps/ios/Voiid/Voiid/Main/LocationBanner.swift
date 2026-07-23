//
//  LocationBanner.swift
//  Voiid
//
//  The persistent "you are currently sharing your location" state — designed to be
//  impossible to miss and trivial to stop (docs/LOCATION.md §8). Accent background,
//  pulsing dot, live countdown, and a one-tap Stop. Pinned below the header on the chats
//  home AND at the top of the relevant chat. With multiple active shares it offers
//  Stop all. When nothing is being shared it renders nothing (zero height).
//
//  This is the in-app counterpart to iOS's own blue background-location indicator, which
//  is also enabled while a share runs — two independent, unmissable signals.
//

import SwiftUI

struct LocationBanner: View {
    /// When set, only shares for this conversation are shown (chat-detail placement);
    /// nil shows all active shares (chats-home placement).
    var conversationId: String? = nil

    @ObservedObject private var engine = LocationShareEngine.shared
    @State private var confirmStopAll = false

    private var shares: [OutboundShare] {
        let all = engine.outboundShares
        guard let conversationId else { return all }
        return all.filter { $0.conversationId == conversationId }
    }

    var body: some View {
        if !shares.isEmpty {
            banner.transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var banner: some View {
        HStack(spacing: VoiidSpacing.sm) {
            pulse
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(VoiidFont.rounded(13, .semibold)).foregroundColor(VoiidColor.primary)
                Text(subtitle).font(VoiidFont.rounded(11, .regular)).foregroundColor(VoiidColor.textSecondary)
            }
            Spacer()
            Button {
                Haptics.rigid()
                if shares.count == 1 { stop(shares[0].id) } else { confirmStopAll = true }
            } label: {
                Text(shares.count == 1 ? "Stop" : "Stop all")
                    .font(VoiidFont.rounded(13, .semibold)).foregroundColor(.white)
                    .padding(.horizontal, VoiidSpacing.md).padding(.vertical, 6)
                    .background(VoiidColor.error).clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, VoiidSpacing.md).padding(.vertical, VoiidSpacing.sm)
        .background(VoiidColor.accent.opacity(0.5))
        .overlay(VoiidColor.fieldBorder.frame(height: 1), alignment: .bottom)
        .confirmationDialog("Stop all live shares?", isPresented: $confirmStopAll, titleVisibility: .visible) {
            Button("Stop all", role: .destructive) { Task { await engine.stopAll() } }
            Button("Cancel", role: .cancel) {}
        }
        .animation(.easeInOut(duration: 0.2), value: shares.count)
    }

    private var title: String {
        shares.count == 1 ? "Sharing live location" : "Sharing live location to \(shares.count) chats"
    }

    private var subtitle: String {
        guard let soonest = shares.min(by: { $0.expiresAt < $1.expiresAt }) else { return "" }
        let mins = Int((soonest.timeRemaining / 60).rounded(.up))
        return mins <= 1 ? "less than a minute left" : "\(mins) min left"
    }

    private func stop(_ id: String) { Task { await engine.stopLiveShare(id) } }

    private var pulse: some View {
        Circle().fill(VoiidColor.success).frame(width: 9, height: 9)
    }
}
