//
//  StoriesHomeView.swift
//  Voiid
//
//  The Stories tab root. Local-first: it renders from StoryEngine's published state (backed
//  by StoryStore) and refreshes the feed in the background — a failed fetch never blanks the
//  screen. One home for the feature (no tray above the chat grid, §8.1); the tab icon carries
//  the unread dot.
//
//  Ordering (§8.3): "Your story" first, then unviewed contexts (accent ring), then viewed
//  contexts (divider ring). One row per author context, never one per story.
//

import SwiftUI

struct StoriesHomeView: View {
    @EnvironmentObject var session: AppSession
    @ObservedObject private var engine = StoryEngine.shared

    @State private var showComposer = false
    @State private var openContext: StoryContext?
    @State private var openMine = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: VoiidSpacing.md) {
                        yourStoryRow
                        if !engine.contexts.isEmpty {
                            Rectangle().fill(VoiidColor.divider.opacity(0.4)).frame(height: 1)
                                .padding(.horizontal, VoiidSpacing.md)
                        }
                        ForEach(engine.contexts) { ctx in
                            Button { Haptics.tap(); openContext = ctx } label: { contextRow(ctx) }
                                .buttonStyle(SoftPressStyle())
                        }
                        if engine.contexts.isEmpty && engine.myStories.isEmpty {
                            emptyState
                        }
                    }
                    .padding(.top, VoiidSpacing.sm)
                    // Measured bar height rather than a guess — see AppSession.bottomInset.
                    .padding(.bottom, session.bottomInset)
                }
                composeButton
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Moments")
            .onAppear { session.hideTabBar = false; Task { await engine.refresh() } }
            .refreshable { await engine.refresh() }
            .sheet(isPresented: $showComposer) { StoryComposerView() }
            .fullScreenCover(item: $openContext) { ctx in
                StoryViewerView(contexts: viewerContexts(startingAt: ctx), startAuthorId: ctx.authorId)
            }
            .fullScreenCover(isPresented: $openMine) {
                if let mine = myContext { StoryViewerView(contexts: [mine], startAuthorId: mine.authorId) }
            }
        }
    }

    // MARK: - Your story

    private var myContext: StoryContext? {
        guard let first = engine.myStories.first else { return nil }
        return StoryContext(authorId: first.authorId, stories: engine.myStories.sorted { $0.createdAt < $1.createdAt })
    }

    private var yourStoryRow: some View {
        HStack(spacing: VoiidSpacing.md) {
            Button {
                Haptics.tap()
                if engine.myStories.isEmpty { showComposer = true } else { openMine = true }
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    ringAvatar(photoURL: session.profile.photoURL, name: session.profile.fullName,
                               ringColor: engine.myStories.isEmpty ? .clear : VoiidColor.accent)
                    if engine.myStories.isEmpty {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(VoiidColor.primary, VoiidColor.background)
                    }
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("Your moment").font(VoiidFont.headline).foregroundColor(VoiidColor.textPrimary)
                Text(mySubtitle).font(VoiidFont.caption).foregroundColor(VoiidColor.textSecondary)
            }
            Spacer()
            if let mine = engine.myStories.first {
                Menu {
                    Button(role: .destructive) { Task { await engine.deleteStory(mine) } } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 18)).foregroundColor(VoiidColor.textSecondary)
                        .frame(width: 44, height: 44)
                }
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
    }

    private var mySubtitle: String {
        if engine.posting.count > 0 { return "Posting…" }
        if let first = engine.myStories.first, engine.failedPosts.contains(first.id) { return "Failed — tap to retry" }
        if engine.myStories.isEmpty { return "Add to your moment" }
        let n = engine.myStories.count
        return n == 1 ? "1 update · \(relative(engine.myStories[0].createdAt))" : "\(n) updates"
    }

    // MARK: - Context row

    private func contextRow(_ ctx: StoryContext) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            ringAvatar(photoURL: UserDirectory.shared.photoURL(ctx.authorId),
                       name: UserDirectory.shared.displayName(ctx.authorId),
                       ringColor: ctx.hasUnviewed ? VoiidColor.accent : VoiidColor.divider)
            VStack(alignment: .leading, spacing: 2) {
                Text(UserDirectory.shared.displayName(ctx.authorId))
                    .font(VoiidFont.headline).foregroundColor(VoiidColor.textPrimary)
                Text(subtitle(ctx)).font(VoiidFont.caption).foregroundColor(VoiidColor.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, VoiidSpacing.md)
        .contentShape(Rectangle())
    }

    private func subtitle(_ ctx: StoryContext) -> String {
        let count = ctx.stories.count
        let when = ctx.newest.map { relative($0.createdAt) } ?? ""
        return count == 1 ? when : "\(count) updates · \(when)"
    }

    // MARK: - Ring avatar (reuses ProfileAvatarButton per §8.3, which resolves R2 keys)

    private func ringAvatar(photoURL: String?, name: String?, ringColor: Color) -> some View {
        ProfileAvatarButton(photoURL: photoURL, name: name, size: 52)
            .padding(3)
            .overlay(Circle().stroke(ringColor, lineWidth: 2.5))
    }

    // MARK: - Chrome

    private var composeButton: some View {
        Button { Haptics.tap(); showComposer = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(VoiidColor.textOnPrimary)
                .frame(width: 60, height: 60)
                .background(VoiidColor.primary)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        }
        .padding(.trailing, VoiidSpacing.lg)
        .padding(.bottom, session.bottomInset)
    }

    private var emptyState: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "circle.dashed").font(.system(size: 44)).foregroundColor(VoiidColor.textSecondary.opacity(0.5))
            Text("No moments yet").font(VoiidFont.headline).foregroundColor(VoiidColor.textPrimary)
            Text("Share a photo or video with your contacts.\nIt disappears after 24 hours.")
                .font(VoiidFont.subhead).foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 80)
        .padding(.horizontal, VoiidSpacing.xl)
    }

    // MARK: - Helpers

    /// Outer pager order: the tapped author first, then the rest of the unviewed/viewed
    /// contexts, so a horizontal swipe moves through people as in §8.4.
    private func viewerContexts(startingAt ctx: StoryContext) -> [StoryContext] {
        var ordered = engine.contexts
        if let i = ordered.firstIndex(where: { $0.authorId == ctx.authorId }) {
            let picked = ordered.remove(at: i)
            ordered.insert(picked, at: 0)
        }
        return ordered
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
