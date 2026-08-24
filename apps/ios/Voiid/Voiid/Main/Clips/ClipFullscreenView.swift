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
//  THE PAGER IS FEED-AGNOSTIC. It used to index straight into `ClipsEngine.clips`, which
//  is why a creator's grid and the Following grid had no playable tiles at all — there was
//  simply nothing for a tap to open. Any list of clips can be handed in now; the player
//  pool, the asymmetric preload window and the playback-URL cache are shared unchanged,
//  because a playback URL needs only a clip id.
//

import SwiftUI
import AVKit
import Combine

struct ClipFullscreenView: View {
    /// An injected list of pages, for a feed this view does not own.
    ///
    /// Explore lives in `ClipsEngine` and mutates in place, so it needs none of this. A
    /// creator's grid and the Following feed live in `CreatorEngine`, so their owner hands
    /// over a snapshot plus the closure that extends it.
    struct Feed {
        var clips: [Clip]
        /// Called with the page the user reached so the owner can append its next page.
        var loadMore: @MainActor (Clip) async -> Void
    }

    let startIndex: Int
    /// nil = page over `ClipsEngine.clips` directly.
    private let feed: Feed?

    @EnvironmentObject var engine: ClipsEngine
    @EnvironmentObject var creators: CreatorEngine
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var index: Int
    /// Drives `scrollPosition(id:)`. Kept separate from `index` so a programmatic jump and a
    /// user scroll cannot fight each other mid-gesture.
    @State private var scrolledID: Int?
    @State private var showComments = false
    @State private var commentDraft = ""
    @StateObject private var players = ClipPlayerPool()

    /// The working copy of an injected feed. Held locally because likes, views and comments
    /// made in here have to live somewhere: the rows they came from are read-only snapshots
    /// owned by another engine.
    @State private var injected: [Clip] = []

    /// The clip being reported. Held on the PAGER, not on the page: a sheet raised from
    /// inside a paging page is torn down the moment the user swipes away from it.
    @State private var reporting: Clip?

    init(startIndex: Int) {
        self.startIndex = startIndex
        self.feed = nil
        _index = State(initialValue: startIndex)
    }

    init(startIndex: Int, feed: Feed) {
        self.startIndex = startIndex
        self.feed = feed
        _index = State(initialValue: startIndex)
    }

    private var pages: [Clip] { feed == nil ? engine.clips : injected }

    private var currentClip: Clip? {
        pages.indices.contains(index) ? pages[index] : nil
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
        .onAppear {
            session.hideTabBar = true
            syncInjected()
        }
        // The owner appends pages as the user scrolls; count is the only thing that moves,
        // and comparing it is far cheaper than diffing the whole snapshot every render.
        .onChange(of: feed?.clips.count) { _, _ in syncInjected() }
        .onDisappear {
            session.hideTabBar = false
            players.releaseAll()
        }
        .task(id: index) { await onPageChanged() }
        // Reporting a clip. Presented from the PAGER so it survives a swipe, and offered as
        // a sheet rather than a confirmation dialog because the server wants a reason and an
        // optional note — see ReportService.
        .sheet(item: $reporting) { clip in
            ReportSheet(target: .clip(id: clip.id)) { reporting = nil }
        }
    }

    // MARK: - Injected feed

    /// Rebuild the working copy from the owner's snapshot WITHOUT discarding local state.
    /// A creator row carries no like state, so re-mapping wholesale would silently undo a
    /// like the user just made every time the grid appended a page.
    private func syncInjected() {
        guard let feed else { return }
        let existing = Dictionary(injected.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        injected = feed.clips.map { row in
            if let mine = existing[row.id] { return mine }
            var c = row
            if let known = engine.knownLikeState(row.id) {
                c.likedByMe = known.liked
                c.likeCount = known.count
            }
            return c
        }
    }

    private func mutateInjected(_ id: String, _ change: (inout Clip) -> Void) {
        guard let i = injected.firstIndex(where: { $0.id == id }) else { return }
        change(&injected[i])
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
                ForEach(Array(pages.enumerated()), id: \.element.id) { i, clip in
                    ClipPlayerPage(
                        clip: clip,
                        player: players.player(for: clip.id),
                        isActive: i == index && !showComments,
                        compact: showComments,
                        canFollow: canFollow(clip),
                        onToggleLike: { Task { await toggleLike(clip) } },
                        onOpenComments: { openComments(clip) },
                        onFollow: { follow(clip) },
                        onReport: { reporting = clip },
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
        // `.task` and `.onAppear` have no guaranteed order, and the first page must not be
        // skipped because the working copy had not been seeded yet.
        if feed != nil && injected.isEmpty { syncInjected() }
        guard let clip = currentClip else { return }

        // The owner of an injected feed pages lazily too, so ask it to extend before the
        // pager reaches the end — otherwise a creator grid stops dead at 30 clips.
        if let feed { await feed.loadMore(clip) }

        // ASYMMETRIC WINDOW: two pages forward, one back. Scrolling is overwhelmingly
        // downward in a reels feed, so the next-next clip is far likelier to be needed than
        // the previous one — but going back must not be a cold start either.
        let list = pages
        let window = [index - 1, index, index + 1, index + 2]
            .filter { list.indices.contains($0) }
            .map { list[$0].id }
        players.retainOnly(window)

        // THE CURRENT PAGE FIRST, AND ALONE. It is the only one the user is looking at, so
        // it must not queue behind a neighbour's network round-trip.
        await players.prepare(id: clip.id) { try await engine.playbackURL(for: clip.id) }
        players.play(clip.id)

        // Neighbours PARALLEL and detached. Previously this was a serial `for … await`, so
        // preparing page n+1 waited on page n-1's round-trip to finish — meaning the clip
        // about to come on screen was last in line behind one already scrolled past. It is
        // also detached from this task because `.task(id: index)` cancels on every page
        // change: a fast scroller would otherwise kill each preload before it landed and
        // arrive at a page with nothing warmed.
        let neighbours = window.filter { $0 != clip.id }
        Task.detached(priority: .utility) { [players, engine] in
            await withTaskGroup(of: Void.self) { group in
                for id in neighbours {
                    group.addTask {
                        await players.prepare(id: id) { try await engine.playbackURL(for: id) }
                    }
                }
            }
        }

        // A view counts after a >=2s watch, not on appearance — counting scroll-past
        // impressions inflates the number the entire grid is built around.
        let watched = clip.id
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard currentClip?.id == watched else { return }
        if let count = await engine.markViewed(watched), feed != nil {
            mutateInjected(watched) { $0.viewCount = count }
        }
    }

    // MARK: - Interactions

    /// Explore rows are owned by the engine and mutate there. An injected row has to be
    /// flipped locally first and reconciled against the server's authoritative count, since
    /// nothing else in the app is holding it.
    private func toggleLike(_ clip: Clip) async {
        guard feed != nil else {
            await engine.toggleLike(clip.id)
            return
        }
        guard let current = injected.first(where: { $0.id == clip.id }) else { return }
        let wasLiked = current.likedByMe
        let previousCount = current.likeCount

        mutateInjected(clip.id) {
            $0.likedByMe = !wasLiked
            $0.likeCount = max(0, previousCount + (wasLiked ? -1 : 1))
        }

        guard let resp = await engine.setLike(clip.id, liked: !wasLiked) else {
            // nil covers both a failed call and a tap that raced one already in flight; in
            // either case the flip this method just made did not happen.
            mutateInjected(clip.id) {
                $0.likedByMe = wasLiked
                $0.likeCount = previousCount
            }
            return
        }
        mutateInjected(clip.id) {
            $0.likedByMe = resp.liked
            $0.likeCount = resp.count
        }
    }

    /// The Follow chip is shown only when we can answer the question honestly: we need the
    /// author's creator handle (the explore feed carries none — it joins `users`) AND a
    /// cached profile that says we are not following yet. Unknown means hidden, never
    /// "Follow" offered to somebody the user already follows.
    private func canFollow(_ clip: Clip) -> Bool {
        guard let handle = clip.authorHandle,
              let profile = creators.cachedProfile(handle) else { return false }
        return !profile.is_self && !profile.following
    }

    private func follow(_ clip: Clip) {
        guard let handle = clip.authorHandle else { return }
        Haptics.success()
        Task { await creators.toggleFollow(handle) }
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
            Spacer(minLength: 0)

            // DELETE YOUR OWN. `DELETE /clips/:id/comments/:commentId` and
            // ClipService.deleteComment have both shipped for a while with no way to reach
            // them: a comment, once posted, could not be taken back from anywhere in the app.
            //
            // Shown only on your own rows, and only once the comment actually exists on the
            // server — a pending row has no id to delete, and a failed one is removed by
            // retrying or by giving up rather than by this control.
            //
            // The hiding is CONVENIENCE, not enforcement: the server checks that the caller
            // wrote the comment (or owns the clip), and it is the authority.
            if c.authorId == session.userId, c.sendState == .sent {
                Menu {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Haptics.rigid()
                        Task {
                            await engine.deleteComment(clipId: clipId, commentId: c.id)
                            // An injected feed owns its own count — see the composer.
                            if feed != nil {
                                mutateInjected(clipId) {
                                    $0.commentCount = max(0, $0.commentCount - 1)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(VoiidColor.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Comment options")
            }
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
                    let sent = await engine.addComment(
                        clipId: clip.id, text: text,
                        authorId: session.userId ?? "",
                        authorName: session.profile.fullName)
                    // The engine only moves the count for rows it owns; an injected row's
                    // count lives here, and is moved only once the comment actually landed.
                    if sent, feed != nil { mutateInjected(clip.id) { $0.commentCount += 1 } }
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
    let canFollow: Bool
    let onToggleLike: () -> Void
    let onOpenComments: () -> Void
    let onFollow: () -> Void
    /// Report this clip or its creator. A separate callback rather than presenting the sheet
    /// from here: the pager owns presentation, and a sheet raised from inside a paging page
    /// dies with the page when the user swipes.
    let onReport: () -> Void
    let onBack: () -> Void

    @State private var muted = true
    @State private var ready = false
    /// Non-nil while the user is holding one side of the screen (Instagram-style scrub speed).
    @State private var heldSpeed: Float?
    /// Drives the one-shot scale pop on the heart.
    @State private var likePop = false

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

                scrim(pageHeight: geo.size.height)
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

    /// The white-on-anything problem: captions, counts and the back chevron were drawn
    /// straight onto arbitrary user video, so a bright clip made all of them illegible.
    ///
    /// Two gradients give them a contrast FLOOR that does not depend on the frame behind
    /// them: a deep one under the caption/action block and a shallow one behind the top row.
    /// Same construction Signal-iOS uses in `StoryItemMediaView`, for the same reason. They
    /// fade with the chrome — when the comments panel takes the screen the reel becomes a
    /// small preview, and a scrim sized for a full page would swallow most of it.
    private func scrim(pageHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.45), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
            Spacer(minLength: 0)
            // ~40% of the page: enough to cover a three-line caption and the whole action
            // rail without dimming the subject of the shot.
            LinearGradient(colors: [.clear, .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: pageHeight * 0.4)
        }
        .allowsHitTesting(false)
        .opacity(compact ? 0.35 : 1)
        .animation(.easeInOut(duration: 0.2), value: compact)
    }

    private var chrome: some View {
        VStack {
            HStack {
                Button(action: onBack) {
                    Image(systemName: compact ? "chevron.down" : "chevron.left")
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(compact ? "Close comments" : "Back")
                Spacer()
                if !compact {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 44, height: 44)
                        .accessibilityLabel(muted ? "Muted" : "Sound on")
                }
            }
            .padding(.horizontal, VoiidSpacing.xs)
            Spacer()

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                    HStack(spacing: VoiidSpacing.sm) {
                        ProfileAvatarButton(photoURL: clip.authorPhotoURL,
                                            name: clip.authorName, size: 44)
                        Text(clip.authorName)
                            .font(VoiidFont.rounded(15, .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        if clip.authorVerified { VerifiedSeal(size: 14) }
                        // Following someone you have just found should not cost a trip to
                        // their profile — but the chip only appears when the follow state is
                        // actually known, so it can never lie (see `canFollow`).
                        if canFollow && !compact { followChip }
                    }
                    if !compact, let caption = clip.caption, !caption.isEmpty {
                        Text(caption)
                            .font(VoiidFont.rounded(14, .regular))
                            .foregroundColor(.white)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: VoiidSpacing.sm)

                if !compact {
                    VStack(spacing: VoiidSpacing.md) {
                        likeAction
                        action("bubble.right.fill",
                               ClipCount.compact(clip.commentCount), .white,
                               "Comments") { onOpenComments() }
                        // Views are a READOUT, not a control: there is nothing to open, so it
                        // gets the same type treatment without pretending to be tappable.
                        VStack(spacing: 4) {
                            Image(systemName: "eye.fill")
                                .font(.system(size: 24)).foregroundColor(.white)
                            Text(ClipCount.compact(clip.viewCount))
                                .font(VoiidFont.rounded(12, .semibold))
                                .foregroundColor(.white)
                        }
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("\(clip.viewCount) views")

                        // SHARE AND REPORT. Both were absent, and the second is not
                        // optional: routes/reports.ts has shipped `clip` and `creator`
                        // target types since moderation landed, and `ReportTarget.clip`
                        // existed in ReportService without a single call site — a
                        // moderation path with no door. A UGC feed that cannot be reported
                        // from is also an App Review problem.
                        Menu {
                            ShareLink(item: shareText) {
                                Label("Share clip", systemImage: "square.and.arrow.up")
                            }
                            Divider()
                            Button("Report", systemImage: "flag", role: .destructive) {
                                Haptics.tap()
                                onReport()
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 24))
                                    .foregroundColor(.white)
                                Text("More")
                                    .font(VoiidFont.rounded(12, .semibold))
                                    .foregroundColor(.white)
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel("More options")
                    }
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.bottom, VoiidSpacing.sm)
        }
    }

    /// Deliberately NOT a per-clip deep link: nothing in the app resolves one yet, and a
    /// shared link that opens nothing is worse than no link. Same text CreatorProfileView
    /// shares, so the two cannot drift.
    private var shareText: String {
        let who = clip.authorHandle.map { "@\($0)" } ?? clip.authorName
        return "Watch \(who)'s clip on VOIID — https://voiid.app"
    }

    private var followChip: some View {
        Button {
            Haptics.tap()
            onFollow()
        } label: {
            Text("Follow")
                .font(VoiidFont.rounded(13, .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, VoiidSpacing.md)
                .frame(height: 30)
                .overlay(Capsule().stroke(.white, lineWidth: 1))
                .padding(.vertical, 7)      // 44pt of hit height around a 30pt chip
                .contentShape(Rectangle())
        }
        .buttonStyle(SoftPressStyle())
        .transition(.opacity.combined(with: .scale))
    }

    /// The heart pops on the way in. Without it a like is a silent colour swap, which on a
    /// moving video is easy to miss entirely — and the tap is the one thing the whole rail
    /// exists for.
    private var likeAction: some View {
        Button {
            Haptics.tap()
            if !clip.likedByMe {
                likePop = true
                withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) { likePop = false }
            }
            onToggleLike()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: clip.likedByMe ? "heart.fill" : "heart")
                    .font(.system(size: 26))
                    .foregroundColor(clip.likedByMe ? VoiidColor.error : .white)
                    .scaleEffect(likePop ? 1.3 : 1)
                    .symbolEffect(.bounce, value: clip.likedByMe)
                Text(ClipCount.compact(clip.likeCount))
                    .font(VoiidFont.rounded(12, .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(clip.likedByMe ? "Unlike" : "Like")
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

    /// A rail action. The 44pt frame is the point: these were bare icon+label stacks whose
    /// tappable area was only as big as the glyph, on the busiest control surface in the app.
    private func action(_ icon: String, _ label: String, _ color: Color,
                        _ accessibility: String,
                        _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 24)).foregroundColor(color)
                Text(label).font(VoiidFont.rounded(12, .semibold)).foregroundColor(.white)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(accessibility)
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
