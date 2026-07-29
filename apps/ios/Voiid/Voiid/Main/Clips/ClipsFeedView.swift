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

    @State private var openIndex: Int?
    @State private var showComposer = false

    /// 3 columns, 2pt gutters, edge-to-edge — the reference layout. Uniform 9:16 tiles;
    /// a staggered grid is deliberately avoided (it needs per-tile aspect data before
    /// first paint and reflows constantly as pages append).
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                content
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .onAppear {
                session.hideTabBar = false
                if !engine.hasLoadedOnce { Task { await engine.refresh() } }
            }
            .fullScreenCover(item: $openIndex.asIdentifiable()) { boxed in
                ClipFullscreenView(startIndex: boxed.value)
                    .environmentObject(engine)
            }
            .fullScreenCover(isPresented: $showComposer) {
                ClipComposerFlow().environmentObject(engine)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
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
                ClipsEmptyState(kind: .noClips) { Haptics.tap(); showComposer = true }
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
            Button {
                Haptics.tap()
                showComposer = true
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
