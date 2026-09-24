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
    /// creator's grid and the Following feed live in `SocialEngine`, so their owner hands
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
    @EnvironmentObject var creators: SocialEngine
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var index: Int
    /// Drives `scrollPosition(id:)`. Kept separate from `index` so a programmatic jump and a
    /// user scroll cannot fight each other mid-gesture.
    @State private var scrolledID: Int?
    /// The clip whose comments sheet is open. The video keeps playing under it.
    @State private var commentsFor: Clip?
    @StateObject private var players = ClipPlayerPool()

    /// The working copy of an injected feed. Held locally because likes, views and comments
    /// made in here have to live somewhere: the rows they came from are read-only snapshots
    /// owned by another engine.
    @State private var injected: [Clip] = []

    /// The clip being reported. Held on the PAGER, not on the page: a sheet raised from
    /// inside a paging page is torn down the moment the user swipes away from it.
    @State private var reporting: Clip?
    /// "More" on the rail: Report and Block, off the rail because they are rare and destructive
    /// and sit beside Like and Comment, which are frequent and reversible.
    @State private var moreFor: Clip?
    @State private var blocking: Clip?
    @State private var toast: String?

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
            pager(size: geo.size)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(VoiidFont.rounded(13, .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(.black.opacity(0.75)))
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(item: $commentsFor) { clip in
            ClipCommentsSheet(clip: clip) { delta in
                // The engine moves counts for rows it owns; an injected row's lives here.
                if feed != nil { mutateInjected(clip.id) { $0.commentCount = max(0, $0.commentCount + delta) } }
            }
        }
        .confirmationDialog(
            moreFor.map { "@\($0.authorHandle ?? $0.authorName)" } ?? "",
            isPresented: .init(get: { moreFor != nil }, set: { if !$0 { moreFor = nil } }),
            titleVisibility: .visible
        ) {
            Button("Report this Clip", role: .destructive) {
                let clip = moreFor; moreFor = nil; reporting = clip
            }
            if let clip = moreFor, clip.authorId != session.userId {
                Button("Block this creator", role: .destructive) {
                    moreFor = nil; blocking = clip
                }
            }
            Button("Cancel", role: .cancel) { moreFor = nil }
        }
        .confirmationDialog(
            "Report this Clip?",
            isPresented: .init(get: { reporting != nil }, set: { if !$0 { reporting = nil } }),
            titleVisibility: .visible
        ) {
            ForEach(ReportReason.allCases) { reason in
                Button(reason.label) { submitReport(reason) }
            }
            Button("Cancel", role: .cancel) { reporting = nil }
        } message: {
            Text("Tell us what's wrong with it. Reports are reviewed, and we act on serious ones within 24 hours.")
        }
        .confirmationDialog(
            blocking.map { "Block @\($0.authorHandle ?? $0.authorName)?" } ?? "",
            isPresented: .init(get: { blocking != nil }, set: { if !$0 { blocking = nil } }),
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) { submitBlock() }
            Button("Cancel", role: .cancel) { blocking = nil }
        } message: {
            Text("You won't see their Clips, and they won't be able to message you. They aren't told.")
        }
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
                        isActive: i == index,
                        compact: false,
                        canFollow: canFollow(clip),
                        onToggleLike: { Task { await toggleLike(clip) } },
                        onOpenComments: { Haptics.tap(); commentsFor = clip },
                        onFollow: { follow(clip) },
                        onMore: { moreFor = clip },
                        onBack: { dismiss() }
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

    // MARK: - Report and block

    /// Confirms, then moves on. A report that produces no acknowledgement reads as ignored,
    /// which is what stops people reporting the second time.
    private func submitReport(_ reason: ReportReason) {
        guard let clip = reporting else { return }
        reporting = nil
        Task {
            do {
                try await ReportService.shared.submit(target: .clip(id: clip.id), reason: reason, note: "")
                Haptics.success()
                showToast("Reported. Thanks \u{2014} we\u{2019}ll review it.")
            } catch {
                showToast("Couldn\u{2019}t send the report. Try again.")
            }
        }
    }

    private func submitBlock() {
        guard let clip = blocking else { return }
        blocking = nil
        Task {
            let ok = await BlockService.shared.block(userId: clip.authorId, displayName: clip.authorName,
                                                     username: clip.authorHandle, photoURL: clip.authorPhotoURL)
            if ok { Haptics.success() }
            showToast(ok ? "Blocked. You won\u{2019}t see their Clips." : "Couldn\u{2019}t block right now. Try again.")
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.easeOut(duration: 0.2)) { toast = nil }
        }
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
    /// "More" — Report and Block. A callback rather than a dialog raised from here: the pager
    /// owns presentation, and one raised inside a paging page dies with it on a swipe.
    let onMore: () -> Void
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
            // The Voiid Ui reference's two gradients: legible chrome at each end without
            // dimming the middle of the video.
            LinearGradient(colors: [.black.opacity(0.55), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: max(220, pageHeight * 0.3))
        }
        .allowsHitTesting(false)
        .opacity(compact ? 0.35 : 1)
        .animation(.easeInOut(duration: 0.2), value: compact)
    }

    /// Built to the Voiid Ui reference (Chat/ClipPlayerScreen.swift): close top-left, the
    /// creator bottom-left, and a rail of Like · Comments · Share · More on the right. The mute
    /// state stays top-right — the reference is silent, real video is not.
    private var chrome: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close")
                Spacer()
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(muted ? "Muted" : "Sound on")
            }
            .padding(.horizontal, VoiidSpacing.xs)

            Spacer()

            HStack(alignment: .bottom, spacing: VoiidSpacing.md) {
                creatorBlock
                Spacer(minLength: 0)
                actionRail
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.bottom, VoiidSpacing.sm)
        }
    }

    private var creatorBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProfileAvatarButton(photoURL: clip.authorPhotoURL, name: clip.authorName, size: 32)
                Text(clip.authorHandle.map { "@\($0)" } ?? clip.authorName)
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if clip.authorVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundColor(VoiidBrand.limeBright)
                        .accessibilityLabel("Verified")
                }
                // Following someone you have just found should not cost a trip to their
                // profile — shown only when the follow state is known (see `canFollow`).
                if canFollow { followChip }
            }
            Text("\(ClipCount.compact(clip.viewCount)) views")
                .font(VoiidFont.rounded(12))
                .foregroundColor(.white.opacity(0.7))
            if let caption = clip.caption, !caption.isEmpty {
                Text(caption)
                    .font(VoiidFont.rounded(14))
                    .foregroundColor(.white)
                    .lineLimit(2)
            }
        }
        .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
    }

    /// Counts under Like and Comments, because a rail of bare glyphs says what you CAN do and
    /// nothing about the clip. Share and More carry no number — there is nothing to count.
    private var actionRail: some View {
        VStack(spacing: VoiidSpacing.md) {
            likeAction
            railButton(icon: "bubble.right", count: clip.commentCount, label: "Comments") {
                onOpenComments()
            }
            ShareLink(item: shareText) {
                railIcon("paperplane", count: nil)
            }
            .accessibilityLabel("Share")
            railButton(icon: "ellipsis", count: nil, label: "More") {
                Haptics.tap()
                onMore()
            }
        }
        .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
    }

    /// Deliberately NOT a per-clip deep link: nothing in the app resolves one yet, and a
    /// shared link that opens nothing is worse than no link. Same text SocialProfileView
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
            railIcon(clip.likedByMe ? "heart.fill" : "heart", count: clip.likeCount,
                     tint: clip.likedByMe ? Color(hex: 0xF87171) : .white)
                .scaleEffect(likePop ? 1.3 : 1)
                .symbolEffect(.bounce, value: clip.likedByMe)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(clip.likedByMe ? "Unlike, \(clip.likeCount)" : "Like, \(clip.likeCount)")
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

    /// A rail action: 52pt wide, 56pt tall with a count, 44pt without — the reference's sizes,
    /// and never smaller than a 44pt target on the busiest control surface in the app.
    private func railButton(icon: String, count: Int?, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { railIcon(icon, count: count) }
            .buttonStyle(.plain)
            .accessibilityLabel(count.map { "\(label), \($0)" } ?? label)
    }

    private func railIcon(_ icon: String, count: Int?, tint: Color = .white) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(tint)
            if let count {
                Text(ClipCount.compact(count))
                    .font(VoiidFont.rounded(11.5, .semibold))
                    .foregroundColor(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .frame(width: 52, height: count == nil ? 44 : 56)
        .contentShape(Rectangle())
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
