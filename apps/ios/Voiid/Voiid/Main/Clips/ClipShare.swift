//
//  ClipShare.swift
//  Voiid
//
//  Sharing a clip: into a Voiid chat, or out of the app as a link — and the card a shared
//  clip becomes inside the chat.
//
//  ── A LINK, NEVER THE FILE ──────────────────────────────────────────────────────
//  Nothing here hands out the video. Inside Voiid a clip travels as its link and renders as a
//  card; outside it is only the link. Watching needs Voiid and a signed-in account: the clip
//  row (GET /clips/:id) and the short-lived playback URL are both signed-in only, and there is
//  no save or download anywhere in the player.
//

import SwiftUI

enum ClipLink {
    /// `https://voiid.app/clip/<id>`. Not `/c/` — community invites already own that path.
    static func url(for clipId: String) -> URL {
        URL(string: "https://voiid.app/clip/\(clipId.lowercased())")!
    }

    /// The clip id when `text` is exactly a clip link (what "Send in Voiid" sends).
    static func clipId(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "https://voiid.app/clip/"
        guard t.hasPrefix(prefix) else { return nil }
        let id = String(t.dropFirst(prefix.count))
        return UUID(uuidString: id) == nil ? nil : id
    }
}

// MARK: - Share sheet

/// Send in Voiid (your recent chats, one tap each) above Share outside (the link).
struct ClipShareSheet: View {
    let clip: Clip

    @EnvironmentObject private var chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    /// Chats chosen, not yet sent. Tapping a chat only SELECTS it: sending is its own button,
    /// so a stray tap on a face never sends a clip to someone.
    @State private var selected: Set<String> = []
    @State private var sentCount = 0
    @State private var copied = false

    private var chats: [VConversation] {
        (chat.directConversations + chat.groupConversations)
            .filter { $0.type != .self }
            .sorted { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
            .prefix(16)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
            Text("Share clip")
                .font(VoiidFont.rounded(17, .semibold))
                .foregroundColor(VoiidColor.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.top, VoiidSpacing.lg)

            VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                Text("Send in Voiid")
                    .font(VoiidFont.rounded(13, .semibold))
                    .foregroundColor(VoiidColor.textSecondary)
                    .padding(.horizontal, VoiidSpacing.md)
                if chats.isEmpty {
                    Text("Your chats will appear here.")
                        .font(VoiidFont.rounded(14))
                        .foregroundColor(VoiidColor.textSecondary)
                        .padding(.horizontal, VoiidSpacing.md)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: VoiidSpacing.md) {
                            ForEach(chats) { conv in chatTarget(conv) }
                        }
                        .padding(.horizontal, VoiidSpacing.md)
                    }
                    if !selected.isEmpty || sentCount > 0 {
                        sendButton
                            .padding(.horizontal, VoiidSpacing.md)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selected)
            .animation(.easeOut(duration: 0.2), value: sentCount)

            VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                Text("Share outside")
                    .font(VoiidFont.rounded(13, .semibold))
                    .foregroundColor(VoiidColor.textSecondary)
                HStack(spacing: VoiidSpacing.sm) {
                    ShareLink(item: ClipLink.url(for: clip.id),
                              message: Text("Watch \(clip.authorHandle.map { "@\($0)" } ?? clip.authorName)'s clip on Voiid")) {
                        outsideButton("square.and.arrow.up", "Share link")
                    }
                    Button {
                        UIPasteboard.general.url = ClipLink.url(for: clip.id)
                        Haptics.success()
                        withAnimation(.easeOut(duration: 0.2)) { copied = true }
                    } label: {
                        outsideButton(copied ? "checkmark" : "link", copied ? "Copied" : "Copy link")
                    }
                    .buttonStyle(.plain)
                }
                Label("Only people signed in to Voiid can watch it. Clips can't be downloaded.",
                      systemImage: "lock.fill")
                    .font(VoiidFont.rounded(12))
                    .foregroundColor(VoiidColor.textSecondary)
                    .padding(.top, 2)
            }
            .padding(.horizontal, VoiidSpacing.md)

            Spacer(minLength: 0)
        }
        .presentationDetents([.height(selected.isEmpty && sentCount == 0 ? 360 : 420)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    private func chatTarget(_ conv: VConversation) -> some View {
        let on = selected.contains(conv.id)
        return Button {
            Haptics.selection()
            if on { selected.remove(conv.id) } else { selected.insert(conv.id) }
        } label: {
            VStack(spacing: 6) {
                ProfileAvatarButton(photoURL: conv.photoURL, name: conv.title, size: 56)
                    .overlay(Circle().stroke(on ? VoiidColor.accent : .clear, lineWidth: 3).padding(-3))
                    .overlay(alignment: .bottomTrailing) {
                        if on {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.white, VoiidColor.accent)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                Text(conv.title)
                    .font(VoiidFont.rounded(11, on ? .semibold : .regular))
                    .foregroundColor(on ? VoiidColor.accentInk : VoiidColor.textPrimary)
                    .lineLimit(1)
                    .frame(width: 64)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(conv.title)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// "Send" (with how many) once someone is chosen; "Sent" for a beat after.
    private var sendButton: some View {
        Button {
            guard !selected.isEmpty else { return }
            Haptics.success()
            let link = ClipLink.url(for: clip.id).absoluteString
            for id in selected { chat.send(link, to: id) }
            sentCount = selected.count
            selected = []
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                dismiss()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: sentCount > 0 ? "checkmark" : "paperplane.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text(sentCount > 0 ? "Sent" : (selected.count == 1 ? "Send" : "Send to \(selected.count)"))
                    .font(VoiidFont.rounded(16, .semibold))
            }
            .foregroundColor(VoiidColor.textOnAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Capsule().fill(VoiidColor.accent))
        }
        .buttonStyle(.plain)
        .disabled(sentCount > 0)
    }

    private func outsideButton(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
            Text(title).font(VoiidFont.rounded(15, .semibold))
        }
        .foregroundColor(VoiidColor.textPrimary)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(VoiidColor.fieldFill, in: Capsule())
    }
}

// MARK: - Clip card in a chat

/// A clip shared into a chat: its cover and author, and a tap that plays it in the app.
struct ClipLinkCard: View {
    let clipId: String

    @EnvironmentObject private var social: SocialEngine
    @EnvironmentObject private var session: AppSession
    @State private var clip: Clip?
    @State private var unavailable = false
    @State private var playing = false

    var body: some View {
        Button {
            guard clip != nil else { return }
            Haptics.tap()
            playing = true
        } label: {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let clip {
                        ClipThumbnail(url: clip.thumbURL, localPath: clip.localThumbPath)
                    } else if unavailable {
                        VoiidColor.fieldFill.overlay(
                            Text("Clip unavailable")
                                .font(VoiidFont.rounded(13, .medium))
                                .foregroundColor(VoiidColor.textSecondary))
                    } else {
                        ClipShimmer()
                    }
                }
                .frame(width: 170, height: 260)
                .clipped()

                if let clip {
                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                    Image(systemName: "play.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                        .frame(width: 52, height: 52)
                        .background(.ultraThinMaterial, in: Circle())
                        .environment(\.colorScheme, .dark)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: 6) {
                        Image(systemName: "play.rectangle.fill").font(.system(size: 11))
                        Text(clip.authorHandle.map { "@\($0)" } ?? clip.authorName)
                            .font(VoiidFont.rounded(12, .semibold))
                            .lineLimit(1)
                    }
                    .foregroundColor(.white)
                    .padding(10)
                }
            }
            .frame(width: 170, height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(clip.map { "Clip by \($0.authorName)" } ?? "Clip")
        .task(id: clipId) { await load() }
        .fullScreenCover(isPresented: $playing) {
            if let clip {
                ClipFullscreenView(startIndex: 0,
                                   feed: .init(clips: [clip], loadMore: { _ in }))
                    .environmentObject(ClipsEngine.shared)
                    .environmentObject(social)
                    .environmentObject(session)
            }
        }
    }

    private func load() async {
        guard clip == nil else { return }
        do {
            let row = try await ClipService.shared.clip(id: clipId)
            clip = Clip(row: row)
        } catch {
            unavailable = true
        }
    }
}
