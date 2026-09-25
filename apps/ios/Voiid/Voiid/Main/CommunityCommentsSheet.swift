//
//  CommunityCommentsSheet.swift
//  Voiid
//
//  The conversation under a community Home post: the thread, oldest first, and a box to add
//  to it. Built to the Clips comments sheet so both read as one kind of thing.
//
//  Comments are server-readable, like the post itself — a post is a broadcast to the
//  community and its replies are part of the same public thread (095).
//

import SwiftUI

struct CommunityCommentsSheet: View {
    let communityId: String
    let post: CommunityService.Post
    /// The post's comment count after an add or a delete, so the card behind stays true.
    var onCountChange: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var comments: [CommunityService.PostComment] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var draft = ""
    @State private var sending = false
    @State private var sendError: String?
    @FocusState private var writing: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                content
                composer
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle(comments.isEmpty ? "Comments" : "\(comments.count) comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if loading && comments.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, comments.isEmpty {
            VStack(spacing: VoiidSpacing.sm) {
                Text(loadError).font(VoiidFont.rounded(14)).foregroundColor(VoiidColor.textSecondary)
                Button("Try again") { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if comments.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 28))
                    .foregroundColor(VoiidColor.textSecondary)
                Text("No comments yet")
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                Text("Start the conversation.")
                    .font(VoiidFont.rounded(14))
                    .foregroundColor(VoiidColor.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture { writing = true }
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(comments) { c in
                        row(c)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .id(c.id)
                            .swipeActions(edge: .trailing) {
                                if c.mine == true {
                                    Button(role: .destructive) {
                                        Task { await delete(c) }
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: comments.count) { _, _ in
                    if let last = comments.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }

    private func row(_ c: CommunityService.PostComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CommunityAvatar(name: c.displayName, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(c.displayName)
                        .font(VoiidFont.rounded(13.5, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                    if let at = c.created_at {
                        Text(CommunityFeedDate.age(at))
                            .font(VoiidFont.rounded(11.5))
                            .foregroundColor(VoiidColor.textSecondary)
                    }
                }
                Text(c.text)
                    .font(VoiidFont.rounded(14.5))
                    .foregroundColor(VoiidColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = c.text }
            if c.mine == true {
                Button("Delete", systemImage: "trash", role: .destructive) { Task { await delete(c) } }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 4) {
            if let sendError {
                Text(sendError)
                    .font(VoiidFont.rounded(12))
                    .foregroundColor(VoiidColor.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Add a comment…", text: $draft, axis: .vertical)
                    .focused($writing)
                    .lineLimit(1...5)
                    .font(VoiidFont.rounded(15))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(VoiidColor.fieldFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .onChange(of: draft) { _, new in
                        if new.count > 1000 { draft = String(new.prefix(1000)) }
                    }
                let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(VoiidColor.textOnAccent)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(canSend ? VoiidColor.accent : VoiidColor.fieldFill))
                }
                .disabled(!canSend)
                .accessibilityLabel("Post comment")
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, VoiidSpacing.sm)
        .background(.bar)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            comments = try await CommunityService.shared.postComments(communityId: communityId, postId: post.id)
            loadError = nil
        } catch {
            loadError = "Couldn't load comments."
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        sendError = nil
        defer { sending = false }
        do {
            let (comment, count) = try await CommunityService.shared.addPostComment(
                communityId: communityId, postId: post.id, body: text)
            Haptics.success()
            draft = ""
            withAnimation(.easeOut(duration: 0.2)) { comments.append(comment) }
            onCountChange(count)
        } catch {
            sendError = (error as? APIError)?.errorDescription ?? "Couldn't post that. Try again."
        }
    }

    private func delete(_ c: CommunityService.PostComment) async {
        do {
            let count = try await CommunityService.shared.deletePostComment(
                communityId: communityId, postId: post.id, commentId: c.id)
            withAnimation(.easeOut(duration: 0.2)) { comments.removeAll { $0.id == c.id } }
            onCountChange(count)
        } catch {
            sendError = "Couldn't delete that comment."
        }
    }
}
