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
    @State private var scope: FeedScope = .explore
    /// The creator page pushed on top of the grid, by handle.
    @State private var openHandle: String?

    @Namespace private var scopePill
    @Namespace private var zoom

    /// Which feed the grid is showing. Following is a separate SOURCE, not a filter over
    /// Explore — it is its own endpoint with its own cursor, so mixing them into one list
    /// would break keyset pagination.
    enum FeedScope: String, CaseIterable { case explore = "Explore", following = "Following" }

    /// 3 columns, 2pt gutters, edge-to-edge — the reference layout. Uniform 9:16 tiles;
    /// a staggered grid is deliberately avoided (it needs per-tile aspect data before
    /// first paint and reflows constantly as pages append).
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                scopePicker
                content
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
    /// exists.
    ///
    /// This was a stock UIKit segmented `Picker` — the one control on the screen that looked
    /// like it belonged to a different app, and the one Android had already replaced with
    /// branded pills. The filled capsule slides between the two labels via
    /// `matchedGeometryEffect` so the switch reads as one object moving, not two redrawing.
    ///
    /// The two pills now share ONE recessed track rather than each carrying its own capsule
    /// fill. Two separately-filled capsules read as two independent toggles that happen to sit
    /// together; a single track reads as one control with two positions, which is what this is.
    /// It also gives the sliding capsule something to slide *within* — previously it appeared
    /// to travel across bare background.
    private var scopePicker: some View {
        HStack(spacing: 0) {
            ForEach(FeedScope.allCases, id: \.self) { option in
                Button {
                    Haptics.selection()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                        scope = option
                    }
                } label: {
                    Text(option.rawValue)
                        .font(VoiidFont.rounded(14, .semibold))
                        .foregroundColor(scope == option
                                         ? VoiidColor.textOnPrimary : VoiidColor.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background {
                            if scope == option {
                                Capsule().fill(VoiidColor.primary)
                                    .matchedGeometryEffect(id: "scope", in: scopePill)
                            }
                        }
                        .padding(.vertical, 4)   // 44pt of hit height around a 36pt pill
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
        // Held to the width of a real segmented control rather than the full bleed: at
        // full width two words float in the middle of an enormous track.
        .frame(maxWidth: 280)
        // The second frame is what CENTRES the first: a 280pt box in a full-width parent
        // sits at the leading edge otherwise.
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.bottom, VoiidSpacing.sm)
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
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(Array(creators.following.enumerated()),
                            id: \.element.id) { index, clip in
                        Button {
                            Haptics.tap()
                            openFollowingIndex = index
                        } label: {
                            followingTile(clip)
                        }
                        .buttonStyle(.plain)
                        .matchedTransitionSource(id: clip.id, in: zoom)
                        .clipTileFadeIn(index: index)
                        // The creator page is no longer the tap target, so it gets the
                        // platform's own "act on this item" gesture instead of vanishing.
                        .contextMenu {
                            if let h = clip.author_handle {
                                Button {
                                    Haptics.tap()
                                    openHandle = h
                                } label: {
                                    Label("View @\(h)", systemImage: "person.crop.circle")
                                }
                            }
                        }
                        .task { await creators.loadMoreFollowingIfNeeded(currentItem: clip) }
                    }
                }
                .padding(.top, 2)
                Color.clear.frame(height: 100)
            }
            .refreshable { await creators.refreshFollowing() }
        }
    }

    private func followingTile(_ clip: CreatorService.CreatorClipRow) -> some View {
        // Aspect ratio on the CELL, not the image — see the note in CreatorProfileView.
        // scaledToFill reports an unbounded ideal height, so a tile that constrains only the
        // image depends on its container handing down a definite size. That holds here today
        // and does not in a VStack, which is exactly how the profile grid came to overlap.
        ZStack(alignment: .bottomLeading) {
            ClipThumbnail(url: clip.thumb_url)
                .scaledToFill()
            LinearGradient(colors: [.clear, .black.opacity(0.72)],
                           startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 1) {
                if let h = clip.author_handle {
                    HStack(spacing: 2) {
                        Text("@\(h)")
                            .font(VoiidFont.rounded(10, .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        // Real field on the joined author row — shown only when the server
                        // says so, never as a default.
                        if clip.author_verified == true {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 8.5))
                                .foregroundColor(VoiidColor.accentSoft)
                                // The seal must not be the thing that gets compressed when a
                                // long handle runs out of room — the Text shrinks, the badge
                                // keeps its size.
                                .layoutPriority(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
                HStack(spacing: 3) {
                    Image(systemName: "play.fill").font(.system(size: 8))
                    Text(ClipCount.compact(clip.view_count))
                        .font(VoiidFont.rounded(10, .semibold))

                    Spacer(minLength: 4)

                    if let text = ClipDuration.label(clip.duration_ms) {
                        Text(text)
                            .font(VoiidFont.rounded(10, .semibold))
                            .monospacedDigit()
                    }
                }
            }
            .foregroundColor(.white)
            .shadow(radius: 2)
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipped()
        .contentShape(Rectangle())
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
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(engine.clips.enumerated()), id: \.element.id) { index, clip in
                    Group {
                        if clip.uploadState == .none {
                            Button {
                                Haptics.tap()
                                openIndex = index
                            } label: {
                                tile(clip)
                            }
                            .buttonStyle(.plain)
                            .matchedTransitionSource(id: clip.id, in: zoom)
                        } else {
                            // An in-flight or failed tile is NOT wrapped in the open-player
                            // button. It has no server row to play, and more importantly a
                            // Button's label swallows every touch inside it — the failed
                            // tile's own Retry and Dismiss controls were unreachable while
                            // they lived in there.
                            tile(clip)
                        }
                    }
                    .clipTileFadeIn(index: index)
                    .task { await engine.loadMoreIfNeeded(currentItem: clip) }
                }
            }
            .padding(.top, 2)

            if engine.loadingMore {
                ProgressView()
                    .tint(VoiidColor.primary)
                    .padding(.vertical, VoiidSpacing.lg)
            }

            Color.clear.frame(height: 100)   // clears the floating tab bar
        }
        .refreshable { await engine.refresh() }
    }

    // MARK: - Tile

    private func tile(_ clip: Clip) -> some View {
        ZStack(alignment: .bottomLeading) {
            ClipThumbnail(url: clip.thumbURL, localPath: clip.localThumbPath)
                .aspectRatio(9.0 / 16.0, contentMode: .fill)
                .clipped()

            // Scrim: the view count sits on arbitrary user video, so it needs its own
            // contrast floor rather than relying on the frame being dark.
            LinearGradient(colors: [.clear, .black.opacity(0.7)],
                           startPoint: .center, endPoint: .bottom)

            switch clip.uploadState {
            case .uploading(let progress):
                uploadOverlay(progress: progress)
            case .failed(let message):
                failedOverlay(clip: clip, message: message)
            case .none:
                // Views left, runtime right — the two facts you actually scan a grid for.
                // Duration is real data (`durationMs` on the row), not decoration, and it is
                // hidden rather than faked when the row predates the column being populated.
                HStack(spacing: 3) {
                    Image(systemName: "play.fill").font(.system(size: 9))
                    Text(ClipCount.compact(clip.viewCount))
                        .font(VoiidFont.rounded(11, .semibold))

                    Spacer(minLength: 4)

                    if let text = ClipDuration.label(clip.durationMs) {
                        Text(text)
                            .font(VoiidFont.rounded(11, .semibold))
                            .monospacedDigit()
                    }
                }
                .foregroundColor(.white)
                .shadow(radius: 2)
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
        .contentShape(Rectangle())
    }

    private func uploadOverlay(progress: Double) -> some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 6) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(VoiidColor.primary)
                    .frame(width: 56)
                Text("Uploading")
                    .font(VoiidFont.rounded(10, .medium))
                    .foregroundColor(.white)
            }
        }
    }

    /// THE ONE TILE WHERE A MIS-TAP COSTS THE USER A VIDEO. Retry and Dismiss sit millimetres
    /// apart inside a third of a phone width, and Dismiss deletes an export the user has
    /// already waited through — so both get a real ≥44pt frame rather than the 10pt text
    /// buttons this had, and Retry gets the visible capsule so the two do not read alike.
    private func failedOverlay(clip: Clip, message: String) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16)).foregroundColor(VoiidColor.error)
                Text("Upload failed")
                    .font(VoiidFont.rounded(10, .semibold)).foregroundColor(.white)

                // Retry comes FIRST and Dismiss is the quiet one: the video has already cost
                // the user an export, and offering only "Dismiss" (as this did) threw that
                // away as the single available action.
                if engine.canRetryUpload(clip.id) {
                    Button {
                        Haptics.tap()
                        engine.retryUpload(clip.id)
                    } label: {
                        Text("Retry")
                            .font(VoiidFont.rounded(12, .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, VoiidSpacing.md)
                            .frame(height: 30)
                            .background(Capsule().fill(VoiidColor.fieldFill))
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SoftPressStyle())
                }

                Button {
                    Haptics.tap()
                    engine.discardFailedUpload(clip.id)
                } label: {
                    Text("Dismiss")
                        .font(VoiidFont.rounded(12, .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, VoiidSpacing.xs)
        }
        .accessibilityLabel("Upload failed. \(message)")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: VoiidSpacing.xs) {
            Text("Clips")
                .font(VoiidFont.rounded(28, .bold))
                .foregroundColor(VoiidColor.textPrimary)
            Spacer()
            // `square.grid.3x3` because that is literally what the destination is. The old
            // `person.crop.square.filled.and.at.rectangle` was unreadable at 22pt and named
            // nothing a user would recognise.
            NavigationLink {
                MyClipsView().environmentObject(engine)
            } label: {
                Image(systemName: "square.grid.3x3")
                    .font(.system(size: 20))
                    .foregroundColor(VoiidColor.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("My clips")

            // Shown only once a creator profile exists — before that there is no page to
            // open, and the handle picker belongs to the compose flow, not to a stray
            // toolbar button.
            if let mine = creators.me {
                Button {
                    Haptics.tap()
                    openHandle = mine.handle
                } label: {
                    // The user's own face is the identity anchor for the whole surface; a
                    // generic `person.circle` told them nothing about whose clips these are.
                    myAvatar(mine)
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                        // The accent ring marks this one avatar as YOURS. Every other avatar
                        // on the surface (tiles, creator pages) is unringed, so the ring is
                        // the only thing distinguishing "me" from "someone" at 28pt.
                        .overlay(Circle().stroke(VoiidColor.accent, lineWidth: 1.5).padding(-2.5))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("My creator profile")
            }

            Button {
                Haptics.tap()
                startCompose()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(VoiidColor.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("New clip")
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, VoiidSpacing.xs)
    }

    /// Reuses ClipThumbnail — an avatar is the same problem as a cover frame: a presigned
    /// URL that can expire or 404, wanting a shimmer rather than a grey hole.
    @ViewBuilder
    private func myAvatar(_ p: CreatorService.Profile) -> some View {
        if let url = p.avatar_url {
            ClipThumbnail(url: url).scaledToFill()
        } else {
            ZStack {
                Circle().fill(VoiidColor.fieldFill)
                Text(String(p.handle.prefix(1)).uppercased())
                    .font(VoiidFont.rounded(13, .semibold))
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
