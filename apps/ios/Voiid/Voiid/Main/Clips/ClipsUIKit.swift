//
//  ClipsUIKit.swift
//  Voiid
//
//  Shared pieces for the Clips surface: the compact count formatter, the cached
//  thumbnail view, the shimmer skeleton, the video loader, and the empty/error states.
//  Kept in one file so the grid and the player cannot drift apart visually.
//

import SwiftUI
import UIKit

// MARK: - Compact counts

enum ClipCount {
    /// "4.7M" / "732K" / "1.2M" — the grid's view-count style.
    ///
    /// Deliberately NOT `Text("\(n)")`, which locale-groups to "4,700,000" and blows the
    /// tile's layout apart. Truncates rather than rounds (949_999 -> "949K", not "950K")
    /// so a count can never appear to jump past a threshold it has not reached.
    static func compact(_ n: Int) -> String {
        switch n {
        case ..<0: return "0"
        case 0..<1_000: return "\(n)"
        case 1_000..<1_000_000:
            let k = Double(n) / 1_000
            return n < 10_000 ? String(format: "%.1fK", floor(k * 10) / 10) : "\(Int(k))K"
        case 1_000_000..<1_000_000_000:
            let m = Double(n) / 1_000_000
            return n < 10_000_000 ? String(format: "%.1fM", floor(m * 10) / 10) : "\(Int(m))M"
        default:
            let b = Double(n) / 1_000_000_000
            return String(format: "%.1fB", floor(b * 10) / 10)
        }
    }
}

// MARK: - Thumbnail cache

/// Small memory cache for grid thumbnails. A 3-column infinite grid re-requesting the
/// same JPEG on every scroll-back would burn the user's data and make the grid flicker.
@MainActor
final class ClipThumbCache {
    static let shared = ClipThumbCache()
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 240          // ~80 rows of a 3-up grid
        cache.totalCostLimit = 48 << 20 // 48 MB
    }

    func cached(_ url: String) -> UIImage? { cache.object(forKey: url as NSString) }

    func load(_ url: String) async -> UIImage? {
        if let hit = cached(url) { return hit }
        // Coalesce: two tiles asking for the same URL share one download.
        if let running = inFlight[url] { return await running.value }

        let task = Task<UIImage?, Never> {
            guard let u = URL(string: url) else { return nil }
            guard let (data, resp) = try? await URLSession.shared.data(from: u),
                  (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
                  let image = UIImage(data: data) else { return nil }
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSString, cost: image.cacheCost) }
        return image
    }
}

private extension UIImage {
    var cacheCost: Int { Int(size.width * size.height * scale * scale * 4) }
}

/// A grid thumbnail: shimmer until it resolves, then a cross-fade. Never a blank box and
/// never a layout jump — the frame is fixed by the caller's aspect ratio.
struct ClipThumbnail: View {
    let url: String?
    /// Local file fallback for an optimistic tile whose upload has not finished.
    var localPath: String?

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if failed {
                // Resolved-but-broken is visually distinct from still-loading: a static
                // placeholder, not an endless shimmer that implies progress.
                VoiidColor.fieldFill
                    .overlay(Image(systemName: "photo")
                        .font(.system(size: 22))
                        .foregroundColor(VoiidColor.textSecondary.opacity(0.5)))
            } else {
                ClipShimmer()
            }
        }
        .animation(.easeOut(duration: 0.2), value: image != nil)
        .task(id: url) { await resolve() }
    }

    private func resolve() async {
        if let localPath, let local = UIImage(contentsOfFile: localPath) {
            image = local
            return
        }
        guard let url else { failed = true; return }
        if let hit = ClipThumbCache.shared.cached(url) { image = hit; return }
        if let loaded = await ClipThumbCache.shared.load(url) { image = loaded }
        else { failed = true }
    }
}

// MARK: - Shimmer

/// The skeleton sweep. One implementation, one period — the grid skeleton and the
/// thumbnail placeholder must pulse in sympathy, not at two different rates.
struct ClipShimmer: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            VoiidColor.fieldFill
                .overlay(
                    LinearGradient(
                        colors: [.clear, VoiidColor.textSecondary.opacity(0.10), .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(width: geo.size.width * 1.6)
                        .offset(x: phase * geo.size.width * 1.6)
                )
                .clipped()
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1.4
            }
        }
    }
}

// MARK: - Video loader

/// Shown while a clip buffers. Draws over the clip's own blurred cover frame so the
/// screen is never black, with a branded progress ring rather than a stock spinner.
struct ClipVideoLoader: View {
    var thumbURL: String?
    var localThumbPath: String?

    @State private var spin = false
    @State private var slow = false

    var body: some View {
        ZStack {
            Color.black
            if thumbURL != nil || localThumbPath != nil {
                ClipThumbnail(url: thumbURL, localPath: localThumbPath)
                    .blur(radius: 24)
                    .opacity(0.55)
                    .clipped()
            }

            VStack(spacing: VoiidSpacing.md) {
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(
                        LinearGradient(colors: [VoiidColor.primary, VoiidColor.accent],
                                       startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 42, height: 42)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)

                if slow {
                    Text("Still loading…")
                        .font(VoiidFont.caption)
                        .foregroundColor(.white.opacity(0.75))
                        .transition(.opacity)
                }
            }
        }
        .onAppear {
            spin = true
            // Only admit to slowness after 3s — showing it immediately makes a fast
            // load feel slow.
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                withAnimation { slow = true }
            }
        }
    }
}

// MARK: - Empty / error states

/// The one empty-state shape for the Clips surface.
///
/// A LOAD FAILURE must use `.failed`, never `.noClips` — telling a user "No clips yet"
/// when the request actually errored is the classic bug in this pattern, and it teaches
/// them the feature is dead.
struct ClipsEmptyState: View {
    enum Kind {
        case noClips            // the global grid really is empty
        case noneFromYou        // the author's own grid
        case failed(String)     // the request errored
    }

    let kind: Kind
    var onPrimary: (() -> Void)?

    var body: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(VoiidColor.textSecondary.opacity(0.5))
            Text(title)
                .font(VoiidFont.headline)
                .foregroundColor(VoiidColor.textPrimary)
            Text(subtitle)
                .font(VoiidFont.subhead)
                .foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, VoiidSpacing.xl)

            if let onPrimary {
                Button {
                    Haptics.tap()
                    onPrimary()
                } label: {
                    Text(actionTitle)
                        .font(VoiidFont.headline)
                        .foregroundColor(VoiidColor.textOnPrimary)
                        .padding(.horizontal, VoiidSpacing.lg)
                        .frame(height: 44)
                        .background(VoiidColor.primary)
                        .clipShape(Capsule())
                }
                .padding(.top, VoiidSpacing.sm)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var icon: String {
        switch kind {
        case .noClips, .noneFromYou: return "play.rectangle.on.rectangle"
        case .failed: return "exclamationmark.triangle"
        }
    }
    private var title: String {
        switch kind {
        case .noClips:     return "No clips yet"
        case .noneFromYou: return "You haven't posted a clip"
        case .failed:      return "Couldn't load clips"
        }
    }
    private var subtitle: String {
        switch kind {
        case .noClips:     return "Be the first to post one."
        case .noneFromYou: return "Your clips will appear here."
        case .failed(let m): return m
        }
    }
    private var actionTitle: String {
        switch kind {
        case .noClips, .noneFromYou: return "Create clip"
        case .failed:                return "Retry"
        }
    }
}

/// Placeholder tiles in the real grid geometry, so nothing reflows when content lands.
struct ClipsGridSkeleton: View {
    var columns: Int = 3
    var count: Int = 12

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns),
                  spacing: 2) {
            ForEach(0..<count, id: \.self) { _ in
                ClipShimmer().aspectRatio(9.0 / 16.0, contentMode: .fill).clipped()
            }
        }
    }
}
