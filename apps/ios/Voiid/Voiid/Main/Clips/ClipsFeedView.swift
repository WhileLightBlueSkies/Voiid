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
    @State private var showComposer = false
    @State private var showHandleSheet = false
    @State private var scope: FeedScope = .explore
    /// The creator page pushed on top of the grid, by handle.
    @State private var openHandle: String?

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
                    .environmentObject(engine)
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

    // MARK: - Scope

    /// Explore / Following. A segmented control rather than a top tab bar: there are exactly
    /// two sources and they share one grid, so a full tab bar would imply more structure than
    /// exists.
    private var scopePicker: some View {
        Picker("Feed", selection: $scope) {
            ForEach(FeedScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
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
            ScrollView {
                VStack(spacing: VoiidSpacing.sm) {
                    Image(systemName: "person.2")
                        .font(.system(size: 34))
                        .foregroundColor(VoiidColor.textSecondary.opacity(0.6))
                    Text("Nothing here yet")
                        .font(VoiidFont.headline)
                        .foregroundColor(VoiidColor.textPrimary)
                    Text("Clips from creators you follow will show up here.")
                        .font(VoiidFont.subhead)
                        .foregroundColor(VoiidColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, VoiidSpacing.xxl)
                .padding(.horizontal, VoiidSpacing.lg)
            }
            .refreshable { await creators.refreshFollowing() }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(creators.following) { clip in
                        Button {
                            Haptics.tap()
                            // Tapping a following-feed tile opens its creator. The fullscreen
                            // pager is driven by an index into ClipsEngine's own page, which
                            // this list is not part of, so it cannot be reused here.
                            if let h = clip.author_handle { openHandle = h }
                        } label: {
                            followingTile(clip)
                        }
                        .buttonStyle(.plain)
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
        ZStack(alignment: .bottomLeading) {
            ClipThumbnail(url: clip.thumb_url)
                .aspectRatio(9.0 / 16.0, contentMode: .fill)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.6)],
                           startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 1) {
                if let h = clip.author_handle {
                    Text("@\(h)")
                        .font(VoiidFont.rounded(10, .semibold))
                        .lineLimit(1)
                }
                HStack(spacing: 3) {
                    Image(systemName: "eye.fill").font(.system(size: 9))
                    Text(ClipCount.compact(clip.view_count))
                        .font(VoiidFont.rounded(10, .semibold))
                }
            }
            .foregroundColor(.white)
            .shadow(radius: 2)
            .padding(6)
        }
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
                    Button {
                        // A still-uploading tile has no server row to play yet.
                        guard clip.uploadState == .none else { return }
                        Haptics.tap()
                        openIndex = index
                    } label: {
                        tile(clip)
                    }
                    .buttonStyle(.plain)
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
            LinearGradient(colors: [.clear, .black.opacity(0.55)],
                           startPoint: .center, endPoint: .bottom)

            switch clip.uploadState {
            case .uploading(let progress):
                uploadOverlay(progress: progress)
            case .failed(let message):
                failedOverlay(clip: clip, message: message)
            case .none:
                HStack(spacing: 3) {
                    Image(systemName: "eye.fill").font(.system(size: 10))
                    Text(ClipCount.compact(clip.viewCount))
                        .font(VoiidFont.rounded(11, .semibold))
                }
                .foregroundColor(.white)
                .shadow(radius: 2)
                .padding(6)
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

    private func failedOverlay(clip: Clip, message: String) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16)).foregroundColor(VoiidColor.error)
                Text("Upload failed")
                    .font(VoiidFont.rounded(10, .semibold)).foregroundColor(.white)
                Button("Dismiss") { engine.discardFailedUpload(clip.id) }
                    .font(VoiidFont.rounded(10, .medium))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Clips")
                .font(VoiidFont.display)
                .foregroundColor(VoiidColor.textPrimary)
            Spacer()
            NavigationLink {
                MyClipsView().environmentObject(engine)
            } label: {
                Image(systemName: "person.crop.square.filled.and.at.rectangle")
                    .font(.system(size: 22))
                    .foregroundColor(VoiidColor.textPrimary)
            }
            .accessibilityLabel("My clips")
            .padding(.trailing, VoiidSpacing.sm)

            // Shown only once a creator profile exists — before that there is no page to
            // open, and the handle picker belongs to the compose flow, not to a stray
            // toolbar button.
            if let mine = creators.me {
                Button {
                    Haptics.tap()
                    openHandle = mine.handle
                } label: {
                    Image(systemName: "person.circle")
                        .font(.system(size: 22))
                        .foregroundColor(VoiidColor.textPrimary)
                }
                .accessibilityLabel("My creator profile")
                .padding(.trailing, VoiidSpacing.sm)
            }

            Button {
                Haptics.tap()
                startCompose()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(VoiidColor.primary)
            }
            .accessibilityLabel("New clip")
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, VoiidSpacing.sm)
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
