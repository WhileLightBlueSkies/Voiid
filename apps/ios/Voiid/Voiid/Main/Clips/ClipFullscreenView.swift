//
//  ClipFullscreenView.swift
//  Voiid
//
//  Fullscreen reels player: a vertical pager over the loaded feed page with a REAL
//  AVPlayer (the previous version drew a gradient and a play glyph — it never played
//  anything). Tapping comments/caption shrinks the video into a top box and slides the
//  comments panel up beneath it.
//
//  PLAYER LIFECYCLE is the load-bearing part of this file: only the current page and
//  its immediate neighbours hold an AVPlayer. An unbounded pager of live players is
//  the standard way this screen runs the device out of memory.
//

import SwiftUI
import AVKit
import Combine

struct ClipFullscreenView: View {
    let startIndex: Int

    @EnvironmentObject var engine: ClipsEngine
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var index: Int
    @State private var showComments = false
    @State private var commentDraft = ""
    @StateObject private var players = ClipPlayerPool()

    init(startIndex: Int) {
        self.startIndex = startIndex
        _index = State(initialValue: startIndex)
    }

    private var currentClip: Clip? {
        engine.clips.indices.contains(index) ? engine.clips[index] : nil
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                pager(height: showComments ? geo.size.height * 0.42 : geo.size.height)

                if showComments, let clip = currentClip {
                    commentsPanel(for: clip)
                        .frame(height: geo.size.height * 0.58)
                        .transition(.move(edge: .bottom))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showComments)
        }
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(.keyboard)
        .onAppear { session.hideTabBar = true }
        .onDisappear {
            session.hideTabBar = false
            players.releaseAll()
        }
        .task(id: index) { await onPageChanged() }
    }

    // MARK: - Pager

    private func pager(height: CGFloat) -> some View {
        TabView(selection: $index) {
            ForEach(Array(engine.clips.enumerated()), id: \.element.id) { i, clip in
                ClipPlayerPage(
                    clip: clip,
                    player: players.player(for: clip.id),
                    isActive: i == index && !showComments,
                    compact: showComments,
                    onToggleLike: { Task { await engine.toggleLike(clip.id) } },
                    onOpenComments: { openComments(clip) },
                    onBack: { showComments ? closeComments() : dismiss() }
                )
                .rotationEffect(.degrees(-90))
                .frame(width: height, height: UIScreen.main.bounds.width)
                .tag(i)
            }
        }
        .frame(width: UIScreen.main.bounds.width, height: height)
        .rotationEffect(.degrees(90), anchor: .topLeading)
        .offset(x: UIScreen.main.bounds.width)
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: height)
        .clipped()
    }

    // MARK: - Page lifecycle

    private func onPageChanged() async {
        guard let clip = currentClip else { return }

        // Preload a ±1 window and release everything outside it.
        let window = [index - 1, index, index + 1]
            .filter { engine.clips.indices.contains($0) }
            .map { engine.clips[$0].id }
        players.retainOnly(window)

        for id in window {
            await players.prepare(id: id) { try await engine.playbackURL(for: id) }
        }
        players.play(clip.id)

        // A view counts after a >=2s watch, not on appearance — counting scroll-past
        // impressions inflates the number the entire grid is built around.
        let watched = clip.id
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if currentClip?.id == watched { await engine.markViewed(watched) }
    }

    // MARK: - Comments

    private func openComments(_ clip: Clip) {
        Haptics.tap()
        withAnimation { showComments = true }
        players.pause(clip.id)
        if engine.comments[clip.id] == nil {
            Task { await engine.loadComments(for: clip.id) }
        }
    }

    private func closeComments() {
        withAnimation { showComments = false }
        if let clip = currentClip { players.play(clip.id) }
    }

    private func commentsPanel(for clip: Clip) -> some View {
        let rows = engine.comments[clip.id] ?? []
        return VStack(spacing: 0) {
            Capsule().fill(VoiidColor.divider)
                .frame(width: 40, height: 4)
                .padding(.vertical, VoiidSpacing.sm)

            HStack {
                Text(rows.isEmpty ? "Comments" : "\(rows.count) comments")
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                Spacer()
                Button { closeComments() } label: {
                    Image(systemName: "xmark").foregroundColor(VoiidColor.textSecondary)
                }
            }
            .padding(.horizontal, VoiidSpacing.lg)
            .padding(.bottom, VoiidSpacing.sm)
            Divider()

            if engine.commentsLoading.contains(clip.id) && rows.isEmpty {
                Spacer()
                ProgressView().tint(VoiidColor.primary)
                Spacer()
            } else if rows.isEmpty {
                Spacer()
                VStack(spacing: VoiidSpacing.xs) {
                    Text("No comments yet")
                        .font(VoiidFont.headline).foregroundColor(VoiidColor.textPrimary)
                    Text("Be the first to say something.")
                        .font(VoiidFont.subhead).foregroundColor(VoiidColor.textSecondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: VoiidSpacing.md) {
                        ForEach(rows) { c in commentRow(c, clipId: clip.id) }
                    }
                    .padding(VoiidSpacing.lg)
                }
            }

            Divider()
            composer(for: clip)
        }
        .background(VoiidColor.background)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func commentRow(_ c: ClipComment, clipId: String) -> some View {
        HStack(alignment: .top, spacing: VoiidSpacing.sm) {
            ProfileAvatarButton(photoURL: c.authorPhotoURL, name: c.authorName, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.authorName)
                    .font(VoiidFont.rounded(13, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                Text(c.text)
                    .font(VoiidFont.rounded(14, .regular))
                    .foregroundColor(VoiidColor.textPrimary)

                // A failed comment is kept and made retryable — never silently dropped.
                if c.sendState == .failed {
                    Button {
                        Task {
                            await engine.retryComment(
                                clipId: clipId, commentId: c.id,
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
            Spacer()
        }
        .opacity(c.sendState == .sending ? 0.55 : 1)
    }

    private func composer(for clip: Clip) -> some View {
        HStack(spacing: VoiidSpacing.sm) {
            TextField("", text: $commentDraft,
                      prompt: Text("Add a comment…").foregroundColor(VoiidColor.placeholder))
                .font(VoiidFont.rounded(15, .regular))
                .foregroundColor(VoiidColor.textPrimary)
                .padding(.horizontal, VoiidSpacing.md)
                .frame(height: 44)
                .background(VoiidColor.fieldFill)
                .clipShape(Capsule())

            Button {
                let text = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                Haptics.tap()
                commentDraft = ""
                Task {
                    await engine.addComment(
                        clipId: clip.id, text: text,
                        authorId: session.userId ?? "",
                        authorName: session.profile.fullName)
                }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 22))
                    .foregroundColor(VoiidColor.primary)
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, VoiidSpacing.sm)
    }
}

// MARK: - One page

private struct ClipPlayerPage: View {
    let clip: Clip
    let player: AVPlayer?
    let isActive: Bool
    let compact: Bool
    let onToggleLike: () -> Void
    let onOpenComments: () -> Void
    let onBack: () -> Void

    @State private var muted = true
    @State private var ready = false

    var body: some View {
        ZStack {
            Color.black

            if let player, ready {
                VideoPlayer(player: player)
                    .disabled(true)
                    .allowsHitTesting(false)
            } else {
                // Branded loader over the blurred cover frame — never a black screen.
                ClipVideoLoader(thumbURL: clip.thumbURL, localThumbPath: clip.localThumbPath)
            }

            chrome
        }
        .onTapGesture {
            muted.toggle()
            player?.isMuted = muted
            Haptics.tap()
        }
        .onChange(of: isActive) { _, active in
            if active { player?.play() } else { player?.pause() }
        }
        .task(id: player) {
            guard let player else { return }
            player.isMuted = muted
            // Poll readiness rather than KVO — a handful of 120ms checks is cheaper to
            // reason about here than an observer whose lifetime must track the pager.
            for _ in 0..<80 {
                if player.currentItem?.status == .readyToPlay {
                    ready = true
                    if isActive { player.play() }
                    return
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    private var chrome: some View {
        VStack {
            HStack {
                Button(action: onBack) {
                    Image(systemName: compact ? "chevron.down" : "chevron.left")
                        .font(.title2)
                        .foregroundColor(.white)
                        .padding()
                }
                Spacer()
                if !compact {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.9))
                        .padding()
                }
            }
            Spacer()

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                    HStack(spacing: VoiidSpacing.sm) {
                        ProfileAvatarButton(photoURL: clip.authorPhotoURL,
                                            name: clip.authorName, size: 44)
                        Text(clip.authorName)
                            .font(VoiidFont.rounded(15, .semibold))
                            .foregroundColor(.white)
                    }
                    if !compact, let caption = clip.caption, !caption.isEmpty {
                        Text(caption)
                            .font(VoiidFont.rounded(14, .regular))
                            .foregroundColor(.white)
                            .lineLimit(3)
                    }
                }
                Spacer()

                if !compact {
                    VStack(spacing: VoiidSpacing.lg) {
                        action(clip.likedByMe ? "heart.fill" : "heart",
                               ClipCount.compact(clip.likeCount),
                               clip.likedByMe ? VoiidColor.error : .white) {
                            Haptics.tap(); onToggleLike()
                        }
                        action("bubble.right.fill",
                               ClipCount.compact(clip.commentCount), .white) { onOpenComments() }
                        action("eye.fill", ClipCount.compact(clip.viewCount), .white) {}
                    }
                }
            }
            .padding()
        }
    }

    private func action(_ icon: String, _ label: String, _ color: Color,
                        _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 26)).foregroundColor(color)
                Text(label).font(VoiidFont.rounded(11, .medium)).foregroundColor(.white)
            }
        }
    }
}

// MARK: - Player pool

/// Holds at most a ±1 window of AVPlayers. Everything outside is torn down: an
/// unbounded pager of live players is how this screen OOMs on a long scroll.
@MainActor
final class ClipPlayerPool: ObservableObject {
    @Published private var players: [String: AVPlayer] = [:]
    private var loopObservers: [String: NSObjectProtocol] = [:]
    private var preparing: Set<String> = []
    /// The ids `retainOnly` last authorised. Minting a playback URL is an await, and the
    /// pager can move several pages during it — without this, a player created for a page
    /// that has already scrolled out would never be released (retainOnly ran BEFORE it was
    /// inserted), which silently defeats the ±1 bound this class exists to enforce.
    private var allowed: Set<String> = []

    func player(for id: String) -> AVPlayer? { players[id] }

    func prepare(id: String, url: @escaping () async throws -> URL) async {
        guard players[id] == nil, !preparing.contains(id) else { return }
        preparing.insert(id)
        defer { preparing.remove(id) }

        guard let resolved = try? await url() else { return }
        // Re-check AFTER the await: drop the result if the window moved on.
        guard allowed.contains(id), players[id] == nil else { return }

        let item = AVPlayerItem(url: resolved)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        // Clips loop, like every other short-video feed.
        loopObservers[id] = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }
        players[id] = player
    }

    func play(_ id: String) {
        for (key, p) in players where key != id { p.pause() }
        players[id]?.play()
    }

    func pause(_ id: String) { players[id]?.pause() }

    func retainOnly(_ ids: [String]) {
        let keep = Set(ids)
        allowed = keep
        for (id, player) in players where !keep.contains(id) {
            player.pause()
            player.replaceCurrentItem(with: nil)
            if let token = loopObservers[id] { NotificationCenter.default.removeObserver(token) }
            loopObservers[id] = nil
            players[id] = nil
        }
    }

    func releaseAll() { retainOnly([]) }
}
