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
    /// Drives `scrollPosition(id:)`. Kept separate from `index` so a programmatic jump and a
    /// user scroll cannot fight each other mid-gesture.
    @State private var scrolledID: Int?
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
                pager(size: CGSize(
                    width: geo.size.width,
                    height: showComments ? geo.size.height * 0.42 : geo.size.height))

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

    /// Vertical paging via `ScrollView` + `scrollTargetBehavior(.paging)`.
    ///
    /// This REPLACED a rotated horizontal TabView (a 90° `rotationEffect` on the container
    /// plus a -90° counter-rotation on every page). That hack caused both bugs reported from
    /// the device: each page was framed with **width and height transposed**, so every video
    /// sat in a wrong-aspect box and appeared cropped; and the nested rotations forced SwiftUI
    /// to render each page off-screen and re-composite it every frame, on top of video decode,
    /// which is what made scrolling stutter.
    ///
    /// It also read `UIScreen.main.bounds`, which is wrong under split-view/iPad and is
    /// deprecated — the size now comes from the enclosing GeometryReader.
    private func pager(size: CGSize) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
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
                    .frame(width: size.width, height: size.height)
                    .id(i)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrolledID)
        .scrollIndicators(.hidden)
        // Comments open = the reel is a shrunken box at the top; paging it there would be
        // a stray gesture fighting the comment list's own scroll.
        .scrollDisabled(showComments)
        .frame(width: size.width, height: size.height)
        .clipped()
        .onChange(of: scrolledID) { _, newValue in
            if let newValue, newValue != index { index = newValue }
        }
        .onAppear { scrolledID = index }
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
    /// Non-nil while the user is holding one side of the screen (Instagram-style scrub speed).
    @State private var heldSpeed: Float?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if let player, ready {
                    // AVPlayerLayer, NOT SwiftUI's VideoPlayer: VideoPlayer always letterboxes
                    // (no way to set videoGravity) and ships player controls we then have to
                    // disable. `.resizeAspect` keeps the true aspect ratio — a portrait clip is
                    // never stretched and a landscape one is never cropped.
                    ClipPlayerLayerView(player: player)
                        .allowsHitTesting(false)
                } else {
                    // Branded loader over the blurred cover frame — never a black screen.
                    ClipVideoLoader(thumbURL: clip.thumbURL, localThumbPath: clip.localThumbPath)
                }

                chrome

                if let heldSpeed {
                    speedPill(heldSpeed)
                }
            }
            .contentShape(Rectangle())
            // Press-and-hold the LEFT third for 0.5x, the RIGHT third for 2x; release restores
            // 1x. minimumDistance 0 makes this fire on touch-down, and the distance check in
            // onEnded is what keeps a plain tap working as the mute toggle.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard heldSpeed == nil, !compact else { return }
                        let third = geo.size.width / 3
                        let speed: Float?
                        if value.startLocation.x < third { speed = 0.5 }
                        else if value.startLocation.x > geo.size.width - third { speed = 2.0 }
                        else { speed = nil }
                        guard let speed else { return }
                        heldSpeed = speed
                        player?.rate = speed
                        Haptics.tap()
                    }
                    .onEnded { value in
                        if heldSpeed != nil {
                            heldSpeed = nil
                            // Setting rate resumes playback; only restore it if this page is
                            // still the visible one.
                            player?.rate = isActive ? 1.0 : 0.0
                        } else if abs(value.translation.height) < 10,
                                  abs(value.translation.width) < 10 {
                            // A genuine tap (not a swipe that became a page change).
                            muted.toggle()
                            player?.isMuted = muted
                            Haptics.tap()
                        }
                    }
            )
        }
        .onChange(of: isActive) { _, active in
            if active {
                player?.play()
            } else {
                player?.pause()
                // Scrolling away mid-hold must not leave the next clip stuck at 2x.
                heldSpeed = nil
            }
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

    /// Visible feedback while a speed hold is active — without it the change in playback rate
    /// is easy to mistake for the app glitching.
    private func speedPill(_ speed: Float) -> some View {
        VStack {
            Text(speed == 2.0 ? "2x" : "0.5x")
                .font(VoiidFont.rounded(15, .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, VoiidSpacing.xs)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 60)
            Spacer()
        }
        .transition(.opacity)
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

// MARK: - AVPlayerLayer host

/// A UIView backed by AVPlayerLayer so `videoGravity` is settable.
///
/// SwiftUI's `VideoPlayer` cannot do this — it always letterboxes and always brings its own
/// controls. `.resizeAspect` shows the whole frame at its true aspect ratio: portrait clips
/// fill naturally, and a landscape clip letterboxes rather than being cropped to fill (which
/// is what `.resizeAspectFill` / Android's RESIZE_MODE_ZOOM were doing wrong).
private struct ClipPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
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
