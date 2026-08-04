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
                Text(title).font(VoiidFont.rounded(13, .semibold)).foregroundColor(VoiidColor.textOnPrimary)
                Text(subtitle).font(VoiidFont.rounded(11, .regular))
                    .foregroundColor(VoiidColor.textOnPrimary.opacity(0.8))
            }
            Spacer()
            Button {
                Haptics.rigid()
                if shares.count == 1 { stop(shares[0].id) } else { confirmStopAll = true }
            } label: {
                Text(shares.count == 1 ? "Stop" : "Stop all")
                    .font(VoiidFont.rounded(13, .semibold)).foregroundColor(VoiidColor.textOnPrimary)
                    .padding(.horizontal, VoiidSpacing.md).padding(.vertical, 6)
                    .background(VoiidColor.error).clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, VoiidSpacing.md).padding(.vertical, VoiidSpacing.sm)
        // PURPLE, not gold — matching Android, which already had this right.
        //
        // The banner was `accent` at 50 %, a washed-out gold that read as a WARNING rather
        // than as an active feature, and it clashed with the brand everywhere else on screen.
        // Accent is Voiid's attention colour (unread counts, the live dot); using it as a
        // full-width background made a normal state look like a problem.
        //
        // Solid primary also fixes a contrast bug: the title was `primary` ON the gold, which
        // is dark-on-mid and hard to read. On a solid primary fill the text is textOnPrimary,
        // which is what that token exists for.
        .background(VoiidColor.primary)
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
        // ACCENT, matching Android. Gold is Voiid's attention colour and it belongs HERE — a
        // small live dot — rather than as the banner's whole background. On the purple fill
        // it is the one thing that draws the eye, which is exactly what a "this is running
        // right now" indicator should do.
        Circle().fill(VoiidColor.accent).frame(width: 9, height: 9)
    }
}
