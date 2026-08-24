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

/// The grid's runtime badge — "0:14", "1:07".
enum ClipDuration {
    /// Returns nil rather than "0:00" when the row carries no duration. Rows written before
    /// `duration_ms` was populated are real and playable; stamping them 0:00 would be a
    /// visible lie about content that is fine, so the badge simply does not appear.
    static func label(_ ms: Int?) -> String? {
        guard let ms, ms > 0 else { return nil }
        // Rounded, not truncated: a 14.6s clip reading "0:14" makes the badge look short by
        // a second on every clip that is not exactly on a boundary.
        let total = Int((Double(ms) / 1000).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
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

// MARK: - Verified seal

/// The verified mark, shared by every Clips surface that shows an identity.
///
/// AMBER RATHER THAN PRIMARY. Primary is the fill of every button in the app, so a seal
/// drawn in it reads as one more control the user should try to press. Amber is the token
/// reserved for the rare thing that must be seen (see the accent note in Theme.swift), and
/// a seal is exactly that. Hierarchical rendering keeps the tick legible inside the fill.
struct VerifiedSeal: View {
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(VoiidColor.accent)
            .accessibilityLabel("Verified")
    }
}

// MARK: - Grid fade-in

/// A short staggered fade for tiles as they land.
///
/// The stagger is capped at the first dozen: past that the user is scrolling, and a delay
/// tied to the absolute index would leave a tile blank for the better part of a second on
/// row forty. Opacity only — moving or scaling a tile would fight the grid's own geometry.
struct ClipTileFadeIn: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.easeOut(duration: 0.25)
                    .delay(Double(min(index, 11)) * 0.02)) { shown = true }
            }
    }
}

extension View {
    /// Fade this grid tile in, staggered by its position in the first screenful.
    func clipTileFadeIn(index: Int) -> some View {
        modifier(ClipTileFadeIn(index: index))
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
        case followingNobody    // you follow nobody yet, so Following has nothing to show
        case failed(String)     // the request errored
    }

    let kind: Kind
    var onPrimary: (() -> Void)?

    var body: some View {
        VStack(spacing: VoiidSpacing.sm) {
            ZStack {
                Circle().fill(VoiidColor.fieldFill)
                icon
            }
            .frame(width: 72, height: 72)
            .padding(.bottom, VoiidSpacing.xs)

            Text(title)
                .font(VoiidFont.rounded(22, .semibold))
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
                .buttonStyle(SoftPressStyle())
                .padding(.top, VoiidSpacing.sm)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    /// The pulse is deliberately withheld from `.failed`: an error is already the loudest
    /// thing on the screen, and animating it forever reads as the app still trying.
    @ViewBuilder
    private var icon: some View {
        let glyph = Image(systemName: iconName)
            .font(.system(size: 30))
            .foregroundColor(VoiidColor.primary)
        if isFailure { glyph } else { glyph.symbolEffect(.pulse) }
    }

    private var isFailure: Bool {
        if case .failed = kind { return true }
        return false
    }

    private var iconName: String {
        switch kind {
        case .noClips, .noneFromYou: return "play.rectangle.on.rectangle"
        case .followingNobody:       return "person.2"
        case .failed:                return "exclamationmark.triangle"
        }
    }
    private var title: String {
        switch kind {
        case .noClips:          return "No clips yet"
        case .noneFromYou:      return "You haven't posted a clip"
        case .followingNobody:  return "Nothing here yet"
        case .failed:           return "Couldn't load clips"
        }
    }
    private var subtitle: String {
        switch kind {
        case .noClips:          return "Be the first to post one."
        case .noneFromYou:      return "Your clips will appear here."
        case .followingNobody:  return "Clips from creators you follow will show up here."
        case .failed(let m):    return m
        }
    }
    private var actionTitle: String {
        switch kind {
        case .noClips, .noneFromYou: return "Create clip"
        case .followingNobody:       return "Explore creators"
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
