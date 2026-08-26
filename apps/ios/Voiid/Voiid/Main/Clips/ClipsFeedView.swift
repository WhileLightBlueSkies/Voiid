//
//  ClipsFeedView.swift
//  Voiid
//
//  The Clips grid — a dense 3-column Instagram/Explore-style grid of cover frames.
//
//  Replaces the old vertical card list (one clip per screen-width card), which showed
//  ~1.5 clips per screen and made browsing feel empty. The grid is thumbnails only:
//  tapping one opens the fullscreen pager at that index.
//

import SwiftUI

struct ClipsFeedView: View {
    @EnvironmentObject var session: AppSession
    @StateObject private var engine = ClipsEngine.shared
    @StateObject private var creators = CreatorEngine()

    @State private var openIndex: Int?
    /// Index into the Following feed, kept separate from `openIndex` so switching scope
    /// cannot present a player pointed at the wrong list.
    @State private var openFollowingIndex: Int?
    @State private var showComposer = false
    @State private var showHandleSheet = false
    @State private var showMine = false
    @State private var scope: FeedScope = .explore
    /// The creator page pushed on top of the grid, by handle.
    @State private var openHandle: String?

    @Namespace private var scopePill
    @Namespace private var zoom

    /// Which feed the grid is showing. Following is a separate SOURCE, not a filter over
    /// Explore — it is its own endpoint with its own cursor, so mixing them into one list
    /// would break keyset pagination.
    enum FeedScope: String, CaseIterable { case explore = "Explore", following = "Following" }

    /// 3 columns, 8pt gutters — the Voiid Ui reference layout. Cards need a gutter to read
    /// as cards; the old 2pt edge-to-edge grid was a mosaic of bare thumbnails. Uniform
    /// 0.72 tiles; a staggered grid is deliberately avoided (it needs per-tile aspect data
    /// before first paint and reflows constantly as pages append).
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // The scope pills and the action cluster share ONE row, so they are laid
                // out against each other and cannot drift. They were a scrolling strip and
                // a fixed top-trailing overlay before — two elements on the same visual
                // line with no knowledge of each other, which is exactly why the pills and
                // the avatar never shared a baseline and the strip slid underneath the
                // cluster on scroll.
                //
                // The reference has no header, and this is not one: it is the scope control
                // the reference lacks (it has one static sample array, so no second source)
                // plus the actions its floating avatar stood for, on the single line they
                // both already occupied.
                topBar
                content
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showMine) {
                MyClipsView().environmentObject(engine)
            }
            .navigationDestination(item: $openHandle) { handle in
                CreatorProfileView(handle: handle)
                    .environmentObject(creators)
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .onAppear {
                session.hideTabBar = false
                if !engine.hasLoadedOnce { Task { await engine.refresh() } }
                // Warm the gate so tapping compose opens the composer directly instead of
                // pausing on a spinner at the moment the user is trying to create.
                Task { await creators.ensureMeLoaded() }
            }
            .fullScreenCover(item: $openIndex.asIdentifiable()) { boxed in
                ClipFullscreenView(startIndex: boxed.value)
                    .navigationTransition(.zoom(sourceID: exploreZoomID(boxed.value), in: zoom))
                    .environmentObject(engine)
                    .environmentObject(creators)
            }
            // Following tiles open the CLIP now. They used to open the creator instead —
            // a workaround for a pager that could only index into the Explore feed, which
            // meant the one grid built from people you chose to follow was the one grid you
            // could not watch. The creator page is still one long-press away.
            .fullScreenCover(item: $openFollowingIndex.asIdentifiable()) { boxed in
                ClipFullscreenView(startIndex: boxed.value, feed: followingFeed)
                    .navigationTransition(.zoom(sourceID: followingZoomID(boxed.value), in: zoom))
                    .environmentObject(engine)
                    .environmentObject(creators)
            }
            .fullScreenCover(isPresented: $showComposer) {
                ClipComposerFlow()
                    .environmentObject(engine)
                    .environmentObject(creators)
            }
            .sheet(isPresented: $showHandleSheet) {
                CreatorHandleSheet { _ in
                    // Whatever raised the gate can now proceed: either finish an upload
                    // parked at the commit step, or open the composer that was blocked.
                    Task {
                        if engine.hasPendingCommits { await engine.retryPendingCommits() }
                        else { showComposer = true }
                    }
                }
                .environmentObject(creators)
            }
            // The engine raises this when a commit came back `profile_required` — the
            // backstop for an upload that started before the profile went away.
            .onChange(of: engine.needsCreatorProfile) { _, needs in
                if needs { showHandleSheet = true; engine.needsCreatorProfile = false }
            }
        }
    }

    // MARK: - The gate

    /// Opens the composer, or the handle picker first if this account has no creator
    /// profile yet.
    ///
    /// Checked HERE rather than at the end of the upload on purpose. `POST /clips` answers
    /// 428 only after the video is already in R2 — the composer exports a 480/720/1080
    /// ladder and PUTs every rung before the row is committed — so gating on the response
    /// would mean asking for a handle after a 100 MB upload the user could still lose.
    /// Asking first costs one cached GET. The 428 path remains as a backstop for the race.
    private func startCompose() {
        Task {
            let profile = await creators.ensureMeLoaded()
            if profile == nil && creators.hasLoadedMe {
                showHandleSheet = true
            } else {
                // A failed lookup falls through to the composer rather than blocking: the
                // server still enforces the gate, and refusing to open on a network blip
                // would be a worse failure than the rare parked upload.
                showComposer = true
            }
        }
    }

    // MARK: - Pager sources

    /// The Following rows as pager pages, plus the closure that extends them. The pager
    /// itself is feed-agnostic — see the header of ClipFullscreenView.
    private var followingFeed: ClipFullscreenView.Feed {
        let rows = creators.following
        return ClipFullscreenView.Feed(
            clips: rows.map { Clip(creatorRow: $0) },
            loadMore: { clip in
                guard let row = rows.first(where: { $0.id == clip.id }) else { return }
                await creators.loadMoreFollowingIfNeeded(currentItem: row)
            })
    }

    /// Zoom transitions are anchored on the clip id, not the index: a page appended while
    /// the cover is animating would otherwise re-point it at a different tile.
    private func exploreZoomID(_ index: Int) -> String {
        engine.clips.indices.contains(index) ? engine.clips[index].id : "clips"
    }

    private func followingZoomID(_ index: Int) -> String {
        creators.following.indices.contains(index) ? creators.following[index].id : "following"
    }

    // MARK: - Scope

    /// Explore / Following. A pill pair rather than a top tab bar: there are exactly two
    /// sources and they share one grid, so a full tab bar would imply more structure than
    /// exists. The reference has no rail at all, but it also has no second source — its
    /// grid is one static sample array. Following is a genuinely separate endpoint with its
    /// own cursor, and dropping the switch would strand it.
    ///
    /// It now scrolls WITH the grid instead of being pinned above it, which is how the
    /// reference's "land straight in the feed" holds: the first thing on screen is clips,
    /// and the switch is there when you reach for it rather than occupying the top strip
    /// permanently.
    ///
    /// The two pills share ONE recessed track. Two separately-filled capsules read as two
    /// independent toggles that happen to sit together; a single track reads as one control
    /// with two positions, and gives the sliding capsule something to slide *within*.
    private var scopeStrip: some View {
        HStack(spacing: 0) {
            ForEach(FeedScope.allCases, id: \.self) { option in
                Button {
                    Haptics.selection()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                        scope = option
                    }
                } label: {
                    Text(option.rawValue)
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(scope == option
                                         ? VoiidColor.textOnPrimary : VoiidColor.textSecondary)
                        // Horizontal padding, not maxWidth: the strip is fixedSize now, so
                        // `maxWidth: .infinity` collapses to the label's intrinsic width and
                        // the text sits hard against the capsule edge. This is what sets the
                        // pill's width, and it is why the control read as cramped.
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                        .background {
                            if scope == option {
                                Capsule().fill(VoiidColor.primary)
                                    .matchedGeometryEffect(id: "scope", in: scopePill)
                            }
                        }
                        .padding(.vertical, 3)   // 44pt of hit height around a 38pt pill
                        .contentShape(Rectangle())
                }
                .buttonStyle(SoftPressStyle())
                .accessibilityAddTraits(scope == option ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 3)
        .background(
            Capsule().fill(VoiidColor.fieldFill)
                .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))
        )
        // Sized to its content, not stretched: it shares a row with the actions now, so a
        // maxWidth would push them off the trailing edge. The two labels set the width.
        .fixedSize(horizontal: true, vertical: false)
        .onChange(of: scope) { _, new in
            // Loaded on first switch only; afterwards the cached page is reused so toggling
            // back and forth is instant rather than a round-trip each way.
            if new == .following && !creators.followingLoadedOnce {
                Task { await creators.refreshFollowing() }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if scope == .following {
            followingContent
        } else {
            exploreContent
        }
    }

    /// Clips from creators you follow. Its empty state is distinct from Explore's on purpose:
    /// "you don't follow anyone yet" is a different problem from "there are no clips", and
    /// offering "post a clip" here would be a non-sequitur.
    @ViewBuilder
    private var followingContent: some View {
        if let error = creators.followingError, creators.following.isEmpty {
            ScrollView {
                ClipsEmptyState(kind: .failed(error)) { Task { await creators.refreshFollowing() } }
            }
            .refreshable { await creators.refreshFollowing() }
        } else if creators.followingLoading && creators.following.isEmpty {
            ScrollView { ClipsGridSkeleton().padding(.top, 2) }
                .disabled(true)
        } else if creators.following.isEmpty && creators.followingLoadedOnce {
            // Routed through the shared component rather than hand-rolled inline, which is
            // how this state drifted into having no CTA at all while every other empty state
            // on the surface had one.
            ScrollView {
                ClipsEmptyState(kind: .followingNobody) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                        scope = .explore
                    }
                }
            }
            .refreshable { await creators.refreshFollowing() }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(creators.following.enumerated()),
                            id: \.element.id) { index, clip in
                        // Same tile as Explore. The creator page is a real target on the
                        // handle row now rather than a long-press affordance nothing
                        // advertised.
                        ClipTile(
                            clip: Clip(creatorRow: clip),
                            onOpen: { openFollowingIndex = index },
                            onCreator: { if let h = clip.author_handle { openHandle = h } }
                        )
                        .matchedTransitionSource(id: clip.id, in: zoom)
                        .clipTileFadeIn(index: index)
                        .task { await creators.loadMoreFollowingIfNeeded(currentItem: clip) }
                    }
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.top, 4)
                Color.clear.frame(height: 100)
            }
            .refreshable { await creators.refreshFollowing() }
        }
    }


    @ViewBuilder
    private var exploreContent: some View {
        // Order matters: the error state must win over the empty state. Rendering
        // "No clips yet" for a failed request tells the user the feature is dead.
        if let error = engine.loadError, engine.clips.isEmpty {
            ScrollView {
                ClipsEmptyState(kind: .failed(error)) { Task { await engine.refresh() } }
            }
            .refreshable { await engine.refresh() }
        } else if engine.loading && engine.clips.isEmpty {
            ScrollView { ClipsGridSkeleton().padding(.top, 2) }
                .disabled(true)
        } else if engine.clips.isEmpty && engine.hasLoadedOnce {
            ScrollView {
                ClipsEmptyState(kind: .noClips) { Haptics.tap(); startCompose() }
            }
            .refreshable { await engine.refresh() }
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(engine.clips.enumerated()), id: \.element.id) { index, clip in
                    // ClipTile carries its own open/creator/retry targets, so an in-flight
                    // or failed tile no longer needs different wrapping: a Button's label
                    // swallows every touch inside it, which is how the failed tile's Retry
                    // and Dismiss became unreachable when the whole tile was one button.
                    ClipTile(
                        clip: clip,
                        onOpen: { if clip.uploadState == .none { openIndex = index } },
                        onCreator: { if let h = clip.authorHandle { openHandle = h } },
                        onRetry: { engine.retryUpload(clip.id) },
                        onDismissFailed: { engine.discardFailedUpload(clip.id) },
                        canRetry: engine.canRetryUpload(clip.id)
                    )
                    .matchedTransitionSource(id: clip.id, in: zoom)
                    .clipTileFadeIn(index: index)
                    .task { await engine.loadMoreIfNeeded(currentItem: clip) }
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
            // Clears the floating avatar, which would otherwise sit on the corner of the
            // top-right tile and hide its view count.
            .padding(.top, 4)

            if engine.loadingMore {
                ProgressView()
                    .tint(VoiidColor.primary)
                    .padding(.vertical, VoiidSpacing.lg)
            }

            Color.clear.frame(height: 100)   // clears the floating tab bar
        }
        .refreshable { await engine.refresh() }
    }

    // MARK: - Top bar

    /// The scope pills and the actions on one line.
    ///
    /// EVERY control here is 44pt tall and centre-aligned, so their centres line up exactly,
    /// and every VISIBLE shape is 38pt — the pills' track, the action circles, the avatar.
    /// Matching the visible height is what makes the row read as aligned; matching only the
    /// 44pt targets would leave the visible pieces off by their differing insets.
    ///
    /// If one of these changes, they all change. A pill at 38 beside a circle at 36 is the
    /// misalignment this row was built to fix.
    private var topBar: some View {
        HStack(spacing: 8) {
            scopeStrip
            Spacer(minLength: VoiidSpacing.sm)
            actions
        }
        // The row owns the horizontal inset, so the pills' leading edge and the grid's
        // first column share one margin — they were on VoiidSpacing.md and the grid on its
        // own padding before, which is why the pills did not line up with the tiles.
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.xs)
        .padding(.bottom, VoiidSpacing.sm)
    }

    // MARK: - Actions

    /// The reference puts ONE floating avatar in the top-right and nothing else, so the tab
    /// is the grid and nothing but the grid. Compose and My Clips still have to be reachable,
    /// so they ride the same floating cluster rather than reinstating a header bar.
    ///
    /// Each control sits on its own blurred circle: they float over arbitrary user video, and
    /// a bare glyph on a bright frame is unreadable. The scope switch that used to live here
    /// moved into the grid as a scrolling pill pair (see `scopeStrip`) — it belongs to the
    /// content, not to the chrome.
    private var actions: some View {
        HStack(spacing: 8) {
            floatingButton("square.grid.3x3", label: "My clips") { showMine = true }

            floatingButton("plus", label: "New clip") { startCompose() }

            // Shown only once a creator profile exists: before that there is no page to open,
            // and the handle picker belongs to the compose flow, not to a stray button.
            if let mine = creators.me {
                Button {
                    Haptics.tap()
                    openHandle = mine.handle
                } label: {
                    myAvatar(mine)
                        .frame(width: 38, height: 38)
                        .clipShape(Circle())
                        // The accent ring marks this one avatar as YOURS. Every other avatar
                        // on the surface is unringed, so the ring is the only thing telling
                        // "me" from "someone" at 36pt.
                        .overlay(Circle().stroke(VoiidColor.accent, lineWidth: 2).padding(-3))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SoftPressStyle())
                .accessibilityLabel("Your creator profile, @\(mine.handle)")
            }
        }
    }

    private func floatingButton(_ icon: String, label: String,
                                _ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(VoiidColor.textPrimary)
                .frame(width: 38, height: 38)
                // A material, not a flat fill: this floats over video, and the reference's
                // own chrome reads as a layer above the content rather than a hole in it.
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(VoiidColor.divider, lineWidth: 0.5))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SoftPressStyle())
        .accessibilityLabel(label)
    }

    /// Reuses ClipThumbnail — an avatar is the same problem as a cover frame: a presigned
    /// URL that can expire or 404, wanting a shimmer rather than a grey hole.
    @ViewBuilder
    private func myAvatar(_ p: CreatorService.Profile) -> some View {
        if let url = p.avatar_url {
            // ClipThumbnail fills internally; a second scaledToFill leaves it unbounded.
            ClipThumbnail(url: url)
        } else {
            ZStack {
                Circle().fill(VoiidColor.fieldFill)
                Text(String(p.handle.prefix(1)).uppercased())
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.textSecondary)
            }
        }
    }
}

// MARK: - Int -> Identifiable for fullScreenCover(item:)

/// `fullScreenCover(item:)` needs an Identifiable; an index of 0 is a perfectly valid
/// selection, so it cannot be modelled with a plain optional Int + isPresented.
struct IdentifiableIndex: Identifiable {
    let value: Int
    var id: Int { value }
}

extension Binding where Value == Int? {
    func asIdentifiable() -> Binding<IdentifiableIndex?> {
        Binding<IdentifiableIndex?>(
            get: { wrappedValue.map(IdentifiableIndex.init(value:)) },
            set: { wrappedValue = $0?.value }
        )
    }
}
