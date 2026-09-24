//
//  ClipCommentsSheet.swift
//  Voiid
//
//  Comments on a Clip, opened from the player's action rail. Built to the Voiid Ui reference
//  (Chat/ClipCommentsSheet.swift), over the real comment engine.
//
//  ── HALF HEIGHT, NOT FULL ───────────────────────────────────────────────────────
//  The clip keeps playing behind it. Comments are read WHILE watching, not instead of it —
//  which is why this replaced the old panel that shrank the video into a box and paused it.
//
//  ── REPORTING IS PER COMMENT ────────────────────────────────────────────────────
//  App Review guideline 1.2 covers every kind of user-generated content, and a comment is UGC.
//  Reporting the clip does not cover someone being abusive underneath it, so each row that
//  isn't yours carries its own report action (`clip_comment`, 091). Your own rows carry Delete.
//

import SwiftUI

struct ClipCommentsSheet: View {
    let clip: Clip
    /// The count moved by posting or deleting, for a feed whose rows this engine doesn't own.
    var onCountChange: (Int) -> Void = { _ in }

    @EnvironmentObject private var engine: ClipsEngine
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var reporting: ClipComment?
    @State private var toast: String?
    @FocusState private var composerFocused: Bool

    private var rows: [ClipComment] { engine.comments[clip.id] ?? [] }
    private var loading: Bool { engine.commentsLoading.contains(clip.id) && rows.isEmpty }
    private var canPost: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidColor.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    if !clip.commentsEnabled {
                        commentsOff
                    } else if loading {
                        Spacer()
                        ProgressView().tint(VoiidColor.primary)
                        Spacer()
                    } else if rows.isEmpty {
                        emptyState
                    } else {
                        list
                    }
                    if clip.commentsEnabled { composer }
                }
            }
            .navigationTitle(rows.isEmpty ? "Comments" : "\(ClipCount.compact(max(rows.count, clip.commentCount))) comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay(alignment: .top) {
                if let toast {
                    Text(toast)
                        .font(VoiidFont.rounded(13, .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(.black.opacity(0.75)))
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .tint(VoiidBrand.limeBright)
        .task {
            guard clip.commentsEnabled else { return }
            if engine.comments[clip.id] == nil { await engine.loadComments(for: clip.id) }
        }
        .confirmationDialog(
            "Report this comment?",
            isPresented: .init(get: { reporting != nil }, set: { if !$0 { reporting = nil } }),
            titleVisibility: .visible
        ) {
            ForEach(ReportReason.allCases) { reason in
                Button(reason.label) { report(reason) }
            }
            Button("Cancel", role: .cancel) { reporting = nil }
        } message: {
            Text("Tell us what's wrong with it. Reports are reviewed, and we act on serious ones within 24 hours.")
        }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: VoiidSpacing.md) {
                ForEach(rows) { row($0) }
            }
            .padding(VoiidSpacing.md)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .softScrollEdge([.top, .bottom])
    }

    private func row(_ c: ClipComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ProfileAvatarButton(photoURL: c.authorPhotoURL, name: c.authorName, size: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(c.authorName)
                        .font(VoiidFont.rounded(13, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                        .lineLimit(1)
                    Text(c.sendState == .sending ? "Sending…" : Self.age(c.createdAt))
                        .font(VoiidFont.rounded(11))
                        .foregroundColor(VoiidColor.textSecondary)
                }
                Text(c.text)
                    .font(VoiidFont.rounded(14))
                    .foregroundColor(VoiidColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                // A failed comment is kept and made retryable — never silently dropped.
                if c.sendState == .failed {
                    Button {
                        Task {
                            await engine.retryComment(clipId: clip.id, commentId: c.id,
                                                      authorId: session.userId ?? "",
                                                      authorName: session.profile.fullName)
                        }
                    } label: {
                        Text("Failed to send · Retry")
                            .font(VoiidFont.caption)
                            .foregroundColor(VoiidColor.error)
                    }
                }
            }

            Spacer(minLength: 0)

            // Only once the comment exists on the server: a pending row has no id to act on.
            if c.sendState == .sent {
                Menu {
                    if c.authorId == session.userId {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Haptics.rigid()
                            Task {
                                await engine.deleteComment(clipId: clip.id, commentId: c.id)
                                onCountChange(-1)
                            }
                        }
                    } else {
                        Button("Report", systemImage: "flag", role: .destructive) { reporting = c }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13))
                        .foregroundColor(VoiidColor.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More options for this comment")
            }
        }
        .opacity(c.sendState == .sending ? 0.55 : 1)
    }

    private var emptyState: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Spacer()
            Image(systemName: "bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(VoiidColor.textSecondary)
            Text("No comments yet")
                .font(VoiidFont.rounded(16, .semibold))
                .foregroundColor(VoiidColor.textPrimary)
            Text("Be the first to say something.")
                .font(VoiidFont.subhead)
                .foregroundColor(VoiidColor.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// The author turned comments off when posting this clip.
    private var commentsOff: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Spacer()
            Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(VoiidColor.textSecondary)
            Text("Comments are off")
                .font(VoiidFont.rounded(16, .semibold))
                .foregroundColor(VoiidColor.textPrimary)
            Text("The creator turned off comments for this clip.")
                .font(VoiidFont.subhead)
                .foregroundColor(VoiidColor.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Add a comment…", text: $draft, axis: .vertical)
                .focused($composerFocused)
                .lineLimit(1...4)
                .font(VoiidFont.rounded(14))
                .foregroundColor(VoiidColor.textPrimary)
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, 10)
                .background(Capsule().fill(VoiidColor.surfaceCard))

            Button {
                Haptics.tap()
                post()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(canPost ? VoiidColor.primary : VoiidColor.textSecondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!canPost)
            .accessibilityLabel("Post comment")
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, VoiidSpacing.sm)
        .background(.bar)
    }

    private func post() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        composerFocused = false
        Task {
            let sent = await engine.addComment(clipId: clip.id, text: text,
                                               authorId: session.userId ?? "",
                                               authorName: session.profile.fullName)
            if sent { onCountChange(1) }
        }
    }

    private func report(_ reason: ReportReason) {
        guard let c = reporting else { return }
        reporting = nil
        Task {
            let sent = (try? await ReportService.shared.submit(target: .clipComment(commentId: c.id),
                                                                reason: reason, note: "")) != nil
            if sent { Haptics.success() }
            withAnimation(.easeOut(duration: 0.2)) {
                toast = sent ? "Reported. Thanks \u{2014} we\u{2019}ll review it." : "Couldn\u{2019}t send the report. Try again."
            }
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.easeOut(duration: 0.2)) { toast = nil }
        }
    }

    /// "now", "5m", "3h", "2d", "4w" — the reference's short ages.
    static func age(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        if s < 604_800 { return "\(s / 86_400)d" }
        return "\(s / 604_800)w"
    }
}
