//
//  CommunityInboxView.swift
//  Voiid
//
//  A host's queue of member→host threads, across every community they own.
//
//  ── WHY THIS SCREEN HAD TO EXIST ────────────────────────────────────────────────
//  The whole feature was unreachable before it. `CommunityHostThreadService.all()` was written
//  and never called, and `MessageHostButton` appeared only inside a comment — so a member had
//  no way to start a thread and a host had nowhere to read one. The table, the three routes
//  and the service layer were all already built; nothing joined them to a screen.
//
//  ── STATUS IS A LIFECYCLE, NOT A FLAG ───────────────────────────────────────────
//  Unread → Open → Resolved (045). A host needs to tell "nobody has looked at this" from
//  "someone is handling it" from "done", and an is-read Bool collapses the middle state —
//  which is exactly the state where a message gets forgotten.
//
//  It is SERVER state, not a per-device unread count: a moderation queue is shared, so a host
//  who resolves on their phone must see it resolved on their iPad, and a co-host must see what
//  the owner already handled.
//
//  ── THE THREAD IS AN ORDINARY CONVERSATION ──────────────────────────────────────
//  Opening one hands off to `ChatDetailView` with the real `VConversation`, so the host thread
//  gets the same ratchet, receipts, retry and media the rest of the app has. Nothing about
//  moderation leaks into the chat engine; the community context lives here and stops here.
//

import SwiftUI

struct CommunityInboxView: View {
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var threads: [CommunityHostThreadService.HostThreadSummary] = []
    @State private var filter: CommunityHostThreadService.ThreadStatus? = nil
    @State private var loading = true
    @State private var loadError: String?
    @State private var openConversation: VConversation?
    /// The row being opened, so its spinner is on THAT row rather than the whole list.
    @State private var opening: String?

    /// Host rows only. A member's own threads reach them through Chats like any other
    /// conversation — this screen is the queue, and a queue of one's own complaints is noise.
    private var hosted: [CommunityHostThreadService.HostThreadSummary] {
        threads.filter { $0.amHost && $0.conversation_id != nil }
    }

    private var visible: [CommunityHostThreadService.HostThreadSummary] {
        guard let filter else { return hosted }
        return hosted.filter { $0.threadStatus == filter }
    }

    private func count(_ s: CommunityHostThreadService.ThreadStatus) -> Int {
        hosted.filter { $0.threadStatus == s }.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidColor.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Host inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(item: $openConversation) { ChatDetailView(conversation: $0) }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    @ViewBuilder private var content: some View {
        // Error beats empty: rendering "no messages" for a request that failed is a lie the
        // user cannot act on. Same rule ChatsHome and the Clips feed follow.
        if let loadError, hosted.isEmpty {
            VStack(spacing: VoiidSpacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30)).foregroundColor(VoiidColor.textSecondary)
                Text(loadError)
                    .font(VoiidFont.subhead).foregroundColor(VoiidColor.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await load() } }
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.accentInk)
            }
            .padding(VoiidSpacing.xl)
        } else if loading && hosted.isEmpty {
            ProgressView().tint(VoiidColor.accent)
        } else if hosted.isEmpty {
            VStack(spacing: VoiidSpacing.sm) {
                Image(systemName: "tray")
                    .font(.system(size: 34)).foregroundColor(VoiidColor.placeholder)
                Text("No messages yet")
                    .font(VoiidFont.rounded(17, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                Text("When a member messages you about a community you host, it lands here.")
                    .font(VoiidFont.subhead).foregroundColor(VoiidColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(VoiidSpacing.xl)
        } else {
            VStack(spacing: 0) {
                filters
                list
            }
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: VoiidSpacing.sm) {
                chip(nil, "All", hosted.count)
                ForEach(CommunityHostThreadService.ThreadStatus.allCases, id: \.self) { s in
                    chip(s, s.label, count(s))
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, VoiidSpacing.sm)
        }
    }

    private func chip(_ s: CommunityHostThreadService.ThreadStatus?, _ label: String, _ n: Int) -> some View {
        let selected = filter == s
        return Button {
            Haptics.tap()
            filter = s
        } label: {
            HStack(spacing: 5) {
                Text(label)
                if n > 0 {
                    Text("\(n)").font(VoiidFont.rounded(11, .semibold))
                }
            }
            .font(VoiidFont.rounded(13, .medium))
            // A selected chip is a FILLED accent, so its label carries the contrast — the rule
            // the palette documents, and what keeps this readable after the move off the lime.
            .foregroundColor(selected ? VoiidColor.textOnAccent : VoiidColor.textSecondary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(selected ? VoiidColor.accent : VoiidColor.fieldFill)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: VoiidSpacing.sm) {
                ForEach(visible) { t in
                    ThreadRow(thread: t, busy: opening == t.id) {
                        Task { await open(t) }
                    } onStatus: { next in
                        Task { await setStatus(t, next) }
                    }
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.top, VoiidSpacing.xs)
            .padding(.bottom, session.bottomInset)
        }
    }

    // MARK: - Actions

    private func load() async {
        loading = true
        do {
            threads = try await CommunityHostThreadService.shared.all()
            loadError = nil
        } catch {
            loadError = (error as? APIError)?.errorDescription ?? "Couldn’t load your inbox."
        }
        loading = false
    }

    /// Opening a thread moves it out of `unread` — the host has now looked at it. Fire and
    /// forget: a failed status write must not block reading the message, and the next refresh
    /// re-reads the truth from the server anyway.
    private func open(_ t: CommunityHostThreadService.HostThreadSummary) async {
        guard let convId = t.conversation_id else { return }
        opening = t.id
        defer { opening = nil }

        if t.threadStatus == .unread { await setStatus(t, .open, silent: true) }

        // Same lookup ChatsHome uses for a notification deep-link: the conversation may not be
        // in memory yet, so load the list before giving up on it.
        let present = chat.directConversations.contains { $0.id == convId }
        if !present { await chat.loadConversations() }
        if let conv = chat.directConversations.first(where: { $0.id == convId }) {
            openConversation = conv
        } else {
            loadError = "That conversation isn’t available on this device yet."
        }
    }

    private func setStatus(_ t: CommunityHostThreadService.HostThreadSummary,
                           _ next: CommunityHostThreadService.ThreadStatus,
                           silent: Bool = false) async {
        guard let communityId = t.community_id, let memberId = t.member_user_id else { return }
        // Optimistic: the queue reorders under the finger. The refresh below reconciles.
        if let i = threads.firstIndex(where: { $0.id == t.id }) {
            threads[i].status = next.rawValue
        }
        do {
            try await CommunityHostThreadService.shared.setStatus(
                communityId: communityId, memberUserId: memberId, status: next)
            if !silent { Haptics.success() }
        } catch {
            // Put it back — an optimistic update that silently sticks is worse than none.
            if let i = threads.firstIndex(where: { $0.id == t.id }) {
                threads[i].status = t.status
            }
            if !silent {
                loadError = (error as? APIError)?.errorDescription ?? "Couldn’t update that thread."
            }
        }
    }
}

// MARK: - Row

private struct ThreadRow: View {
    let thread: CommunityHostThreadService.HostThreadSummary
    let busy: Bool
    let onOpen: () -> Void
    let onStatus: (CommunityHostThreadService.ThreadStatus) -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: VoiidSpacing.md) {
                ClipThumbnail(url: nil)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(thread.community_name ?? "@\(thread.community_handle ?? "community")")
                        .font(VoiidFont.rounded(16, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                        .lineLimit(1)

                    // NO MESSAGE PREVIEW, and there cannot be one: the messages are E2EE and
                    // the server does not hold plaintext to summarise. The row says who and
                    // when; the content is behind the tap, which is the honest version.
                    Text("A member messaged you")
                        .font(VoiidFont.footnote)
                        .foregroundColor(VoiidColor.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if busy {
                    ProgressView().tint(VoiidColor.accent)
                } else {
                    StatusPill(status: thread.threadStatus)
                }
            }
            .padding(VoiidSpacing.md)
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        // The queue actions, hidden until asked for so the row stays readable.
        .contextMenu {
            ForEach(CommunityHostThreadService.ThreadStatus.allCases, id: \.self) { s in
                if s != thread.threadStatus {
                    Button("Mark \(s.label.lowercased())") { onStatus(s) }
                }
            }
        }
    }
}

private struct StatusPill: View {
    let status: CommunityHostThreadService.ThreadStatus

    var body: some View {
        Text(status.label)
            .font(VoiidFont.rounded(10, .semibold))
            .foregroundColor(fg)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(bg)
            .clipShape(Capsule())
    }

    // Unread is the one that must be SEEN, so it is the filled accent; the other two recede.
    private var fg: Color {
        switch status {
        case .unread:   return VoiidColor.textOnAccent
        case .open:     return VoiidColor.accentInk
        case .resolved: return VoiidColor.textSecondary
        }
    }

    private var bg: Color {
        switch status {
        case .unread:   return VoiidColor.accent
        case .open:     return VoiidColor.accentTint
        case .resolved: return VoiidColor.fieldFill
        }
    }
}
