//
//  StoryViewerView.swift
//  Voiid
//
//  Full-screen story viewer. Structure follows Signal's two-pager idiom (studied, no code
//  copied — Signal is AGPLv3): an OUTER horizontal pager between author contexts, and an
//  INNER stepper through one author's stories driven by tap zones + an auto-advancing timer.
//  A segmented progress bar carries one segment per story in the current context.
//
//  Durations are content-driven: images 5s, video min(duration, 30s). A story still
//  downloading shows a spinner and the timer does NOT start. Long-press pauses + hides
//  chrome; swipe-down dismisses. Prefetch is the NEXT story in the CURRENT context only.
//
//  Media decode and playback live in StoryMedia.swift: stills are downsampled off the main
//  thread, video runs through an AVPlayerLayer out of a two-deep pool.
//

import Combine
import SwiftUI
import AVFoundation

struct StoryViewerView: View {
    let contexts: [StoryContext]
    let startAuthorId: String

    @Environment(\.dismiss) private var dismiss
    @State private var authorIndex: Int = 0
    /// Drives `scrollPosition(id:)`. Kept separate from `authorIndex` so a programmatic jump
    /// and a user swipe cannot fight each other mid-gesture.
    @State private var scrolledID: Int?

    var body: some View {
        GeometryReader { geo in
            let safeArea = StorySafeArea.resolve(geo.safeAreaInsets)

            // LazyHStack + paging, NOT a paged TabView. TabView builds EVERY author page up
            // front, and each page carries its own 30 Hz progress timer — with a dozen
            // authors in the tray that was hundreds of timer fires a second before the user
            // had swiped once. Clips moved to this construction for the same reason.
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(contexts.enumerated()), id: \.element.authorId) { idx, ctx in
                        StoryContextPlayer(
                            context: ctx,
                            isActive: idx == authorIndex,
                            pageSize: geo.size,
                            safeArea: safeArea,
                            // Where the FOLLOWING author's page will actually open, so the
                            // prefetch window can spill across the boundary. Without it every
                            // horizontal swipe between people was a guaranteed cold start on a
                            // black frame.
                            nextContextStories: StoryViewerView.head(of: contexts, after: idx),
                            onAdvanceContext: { advanceContext() },
                            onRewindContext: { if authorIndex > 0 { authorIndex -= 1 } },
                            onDismiss: { dismiss() })
                        .frame(width: geo.size.width, height: geo.size.height)
                        .id(idx)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrolledID)
            .scrollIndicators(.hidden)
            // THE OFF-CENTRE BUG. `.ignoresSafeArea()` below expands this view's layout
            // REGION, but a ScrollView independently re-inserts the safe area as content
            // insets on its own content (the default `automatic` behaviour). So each page —
            // already sized to the FULL screen height by the `.frame` above — was pushed down
            // by the top inset and clipped by the same amount at the bottom: on a notched
            // phone the whole story sat ~59pt low with its last ~59pt cut off, which is the
            // "not centred" report. Zeroing the scroll content margins is what actually makes
            // a page's frame and the screen the same rectangle.
            .contentMargins(.all, 0, for: .scrollContent)
            .onChange(of: scrolledID) { _, newValue in
                if let newValue, newValue != authorIndex { authorIndex = newValue }
            }
            .onChange(of: authorIndex) { _, newValue in
                if scrolledID != newValue { withAnimation { scrolledID = newValue } }
            }
        }
        .background(Color.black)
        // The MEDIA ignores the safe area, not just the backdrop behind it. Previously
        // `.ignoresSafeArea()` sat on the black fill alone, so every story was framed by the
        // insets — roughly 59pt of black above and 34pt below on a notched phone.
        .ignoresSafeArea()
        .onAppear {
            let start = contexts.firstIndex { $0.authorId == startAuthorId } ?? 0
            authorIndex = start
            scrolledID = start
            StoryStore.sweepExpired()
        }
        .statusBarHidden(true)
    }

    private func advanceContext() {
        if authorIndex < contexts.count - 1 { authorIndex += 1 }
        else { dismiss() }
    }

    /// The stories the author after `idx` would show first — from THEIR resume point, since a
    /// page opens at `firstUnviewedIndex`, not at zero.
    private static func head(of contexts: [StoryContext], after idx: Int) -> [Story] {
        guard contexts.indices.contains(idx + 1) else { return [] }
        let next = contexts[idx + 1]
        return Array(next.stories.dropFirst(next.firstUnviewedIndex).prefix(StoryPrefetch.depth))
    }
}

/// Shared prefetch bound. Three deep matches what Signal-iOS warms ahead of the current story;
/// past that it is bandwidth spent on stories the user will most likely never reach.
enum StoryPrefetch {
    static let depth = 3
}

// MARK: - One author's stories

private struct StoryContextPlayer: View {
    let context: StoryContext
    let isActive: Bool
    /// Full physical page size (the pager ignores the safe area), used to bound the decode.
    let pageSize: CGSize
    let safeArea: EdgeInsets
    /// The next author's opening stories, for the tail of this page's prefetch window.
    let nextContextStories: [Story]
    let onAdvanceContext: () -> Void
    let onRewindContext: () -> Void
    let onDismiss: () -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var engine = StoryEngine.shared
    @StateObject private var players = StoryPlayerPool()
    @State private var index: Int = 0
    @State private var progress: Double = 0
    /// Held down by the LONG-PRESS only. Every other reason to stop is derived — see `paused`.
    @State private var pressPaused = false
    /// The app is not frontmost. AVPlayer is stopped by the system when we background, but
    /// nothing was stopping the 30 Hz progress timer: a story backgrounded mid-playback kept
    /// burning progress against a frozen frame and could auto-advance — or auto-CLOSE the
    /// viewer — entirely off screen, so the user came back to a different story or to no
    /// viewer at all.
    @State private var scenePaused = false
    @State private var chromeHidden = false
    @State private var muted = true
    @State private var image: UIImage?
    @State private var backdrop: UIImage?
    @State private var loadState: LoadState = .loading
    @State private var showReply = false
    @State private var showViewers = false
    @State private var replyText = ""
    @State private var toast: String?

    /// One 30 Hz tick per BUILT page. That is only tolerable because the pager is lazy now:
    /// under the old TabView every author in the tray had one of these running from the
    /// moment the viewer opened.
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    enum LoadState { case loading, ready, failed, gone }

    private var stories: [Story] { context.stories }
    private var current: Story? { stories.indices.contains(index) ? stories[index] : nil }
    private var activePlayer: AVPlayer? { current.flatMap { players.player(for: $0.id) } }

    /// THE single source of truth for "the story is not running".
    ///
    /// This was a stored flag that four different places wrote by hand, and one of them —
    /// the viewers sheet — never wrote it back. Opening Views paused the timer and the video
    /// and then had no `.onDisappear` to undo either, so the story sat frozen forever: no
    /// auto-advance, no auto-close. The reply sheet's own resume had the mirror-image defect,
    /// `if isActive && !paused { play() }` evaluated while `paused` was still true, so video
    /// never actually resumed there either — only the progress bar did.
    ///
    /// Deriving it means a sheet cannot leak a pause: `showViewers`/`showReply` go false when
    /// the sheet dismisses BY ANY ROUTE — the Done button, an interactive swipe-down, or a
    /// programmatic dismiss — and `paused` follows on its own with nothing to forget.
    ///
    /// `progress` is deliberately NOT reset by any of this. It accumulates in
    /// `advanceProgress`, so a resume picks the segment up exactly where it stopped rather
    /// than restarting it.
    private var paused: Bool {
        pressPaused || scenePaused || showViewers || showReply
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                // The canvas is pinned to the PAGE, explicitly, before anything is drawn on
                // it. `maxWidth/maxHeight: .infinity` only offers to grow — it does not stop
                // an oversized child from growing the ZStack past the page and dragging the
                // centre of the layout off screen with it, which is exactly what the
                // unbounded `.scaledToFill()` backdrop was doing (see `backdropLayer`).
                content
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                // Tap zones: left third = back, right two-thirds = forward.
                //
                // They stop short of the footer. Previously they ran the full page height, so
                // the invisible forward-tap sheet sat directly ON TOP of the emoji rail and
                // the reply field — a near-miss on a heart advanced the story instead, and the
                // rail's own 44pt targets were unreachable at their edges. The reserved strip
                // is the footer's real height, so the controls own their own space.
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).frame(width: geo.size.width / 3)
                        .onTapGesture { back() }
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { forward() }
                }
                .padding(.bottom, chromeHidden ? 0 : footerReserve)

                scrim(pageHeight: geo.size.height)
                    .opacity(chromeHidden ? 0 : 1)
                    .animation(.easeInOut(duration: 0.2), value: chromeHidden)

                VStack {
                    if !chromeHidden {
                        header
                        StorySegmentProgressView(count: stories.count, currentIndex: index, progress: progress)
                            .padding(.horizontal, VoiidSpacing.md).padding(.top, 4)
                    }
                    Spacer()
                    if !chromeHidden {
                        caption
                        footer
                    }
                }
                .padding(.top, 8)

                if let toast {
                    Text(toast).font(VoiidFont.subhead).foregroundColor(.white)
                        .padding(.horizontal, VoiidSpacing.md).padding(.vertical, VoiidSpacing.sm)
                        .background(.black.opacity(0.6)).clipShape(Capsule())
                }
            }
            // Long-press pauses the timer and fades the chrome; release resumes.
            .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 24, pressing: { pressing in
                pressPaused = pressing
                withAnimation { chromeHidden = pressing }
                // Release resumes through the same one path every other resume uses, so a
                // release while a sheet is somehow still up cannot start playback under it.
                if pressing { players.pauseAll() } else { syncPlayback() }
            }, perform: {})
            // Swipe down dismisses.
            .simultaneousGesture(
                DragGesture(minimumDistance: 40).onEnded { v in
                    if v.translation.height > 80 { onDismiss() }
                }
            )
        }
        // ONE place turns playback on and off, for every reason there is to pause: the
        // long-press, the two sheets, and backgrounding. Two `.onDisappear` closures doing it
        // by hand is what drifted apart and produced the stuck-paused bug.
        .onChange(of: paused) { _, _ in syncPlayback() }
        .onChange(of: scenePhase) { _, phase in scenePaused = (phase != .active) }
        .onChange(of: isActive) { _, active in if active { start() } else { stop() } }
        .onChange(of: index) { _, _ in loadCurrent() }
        .onAppear { index = context.firstUnviewedIndex; if isActive { start() } }
        // A page the pager has recycled must not keep a decoder — or an audio session — alive.
        .onDisappear { stop() }
        .onReceive(tick) { _ in advanceProgress() }
        .sheet(isPresented: $showViewers) { if let s = current { StoryViewersSheet(story: s) } }
        .sheet(isPresented: $showReply) { replySheet }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch loadState {
        case .loading:
            ProgressView().tint(.white).scaleEffect(1.4)
        case .ready:
            if let s = current, s.media.mime.hasPrefix("video"), let player = players.player(for: s.id) {
                ZStack {
                    backdropLayer
                    StoryPlayerLayerView(player: player).allowsHitTesting(false)
                }
            } else if let image {
                ZStack {
                    backdropLayer
                    // FULL-BLEED for anything shot roughly in the screen's shape, letterboxed
                    // for anything that isn't. `.scaledToFit()` alone was the "cropped it up"
                    // report: a 9:16 story on a 19.5:9 phone is only a few percent off the
                    // page, yet it still drew bands and let the blurred backdrop bleed through
                    // at the top and bottom of what should read as an edge-to-edge photo.
                    //
                    // But fill is not free — it crops the overflowing axis — so it is applied
                    // only where the crop is a sliver. See `mediaFills`.
                    storyImage(image)
                }
            } else {
                failureText("This moment couldn't be loaded")
            }
        case .failed:
            failureText("This moment couldn't be loaded")
        case .gone:
            failureText("This moment is no longer available")
        }
    }

    /// How far from the page's own aspect ratio a story may be before filling it would cost
    /// real content. 0.25 is a quarter off the page's ratio: on a 19.5:9 phone (0.462) that
    /// admits everything from ~0.35 to ~0.58 — the whole band of portrait capture, 9:16
    /// included, where the crop is a sliver off one axis. A 4:3 photo (1.333) and a square are
    /// nowhere near it, and a landscape frame filled to a 19.5:9 page would lose two thirds of
    /// its width: that is the "vertical sliver" this threshold exists to refuse.
    private static let fillRatioTolerance: Double = 0.25

    /// True when `image` is close enough to the page's shape that filling it crops only an
    /// edge. Compared as a RELATIVE difference so the same tolerance means the same thing on
    /// an SE (0.562) and on a Dynamic Island phone (0.462) instead of being generous on one
    /// and strict on the other.
    private func mediaFills(_ image: UIImage) -> Bool {
        let page = pageSize
        guard page.width > 0, page.height > 0, image.size.width > 0, image.size.height > 0
        else { return false }
        let pageRatio = page.width / page.height
        let mediaRatio = image.size.width / image.size.height
        return abs(mediaRatio - pageRatio) / pageRatio <= Self.fillRatioTolerance
    }

    /// The story frame itself.
    ///
    /// Near-page-ratio media fills; everything else keeps its true aspect over the blurred
    /// backdrop, because a caption burned into the bottom of a 4:3 photo or a face at the edge
    /// of a landscape shot is exactly what an unconditional fill would cut off.
    ///
    /// EITHER branch is explicitly bounded to the page and clipped, for the same reason the
    /// backdrop is (see below): `.scaledToFill()` deliberately overflows, and an unbounded
    /// overflow reports its OVERSIZED shape as the layer's size, grows the enclosing stack and
    /// drags the centre of the layout off screen. The `.frame` is what stops that; the fill
    /// still happens inside it.
    @ViewBuilder private func storyImage(_ image: UIImage) -> some View {
        if mediaFills(image) {
            Color.clear
                .overlay {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
                .frame(width: pageSize.width, height: pageSize.height)
                .clipped()
        } else {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                // Bounded too. `.scaledToFit()` cannot overflow, but stating the page keeps
                // both branches sizing identically so a swap between them never shifts the
                // centre by a point.
                .frame(width: pageSize.width, height: pageSize.height)
        }
    }

    /// The story itself is drawn at its true aspect ratio, so anything that is not the screen's
    /// shape — a 4:3 photo on a 19.5:9 phone is the common case — leaves bands. Filling them
    /// with pure black is what the "too much black space" report was about. Both Signal clients
    /// and WhatsApp Status put the SAME frame behind, cropped to fill and blurred, so the bands
    /// read as an extension of the photo instead of as dead screen.
    ///
    /// The source is a ~96px copy (see `StoryImageCache.backdrop`), and the media on top is
    /// untouched — this adds a layer, it does not crop the story.
    @ViewBuilder private var backdropLayer: some View {
        if let backdrop {
            // `.scaledToFill()` DELIBERATELY overflows — that is what filling means — so it
            // must be clamped to the page and clipped, or it reports its overflowed size as
            // the layer's size. Unclamped it grew the enclosing ZStack, and the
            // `.scaledToFit()` media stacked on top then centred itself against that larger
            // rectangle instead of against the screen: a portrait photo behind a landscape
            // one pushed the story visibly off-centre. `.frame` here sizes the layer; the
            // fill still happens inside it.
            Color.clear
                .overlay {
                    Image(uiImage: backdrop)
                        .resizable()
                        .scaledToFill()
                }
                .frame(width: pageSize.width, height: pageSize.height)
                .clipped()
                .blur(radius: 28, opaque: true)
                .overlay(Color.black.opacity(0.4))
                .allowsHitTesting(false)
        } else {
            // Neutral rather than pure black while the backdrop decodes, and for the media we
            // could not read a frame from at all.
            Color(white: 0.07)
        }
    }

    private func failureText(_ s: String) -> some View {
        VStack(spacing: VoiidSpacing.md) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundColor(.white.opacity(0.7))
            Text(s).font(VoiidFont.subhead).foregroundColor(.white.opacity(0.85))
        }
    }

    // MARK: - Header / caption / footer

    /// Progress capsules, the author name, the timestamp and the reply rail are all white drawn
    /// straight onto the media — over a snow shot or a white wall none of it is readable. These
    /// two gradients give the chrome a contrast floor that does not depend on the frame behind
    /// it, the same construction Clips uses and the same one Signal and WhatsApp Status use.
    private func scrim(pageHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.5), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: safeArea.top + 120)
            Spacer(minLength: 0)
            // Deep enough for the caption plus the emoji row and the reply field beneath it.
            //
            // A flat 35% of the page is 298pt on a 6.7" phone but only 233pt on a 667pt SE —
            // and the chrome it has to cover is very nearly the SAME height on both, because
            // the rail and the capsule are fixed sizes. So on the small screen the gradient
            // ran out before the controls did and the top of the emoji rail sat on raw media.
            // `footerReserve` is the real measured height of that chrome; taking the larger of
            // the two makes the scrim proportional on big screens and sufficient on small ones.
            LinearGradient(colors: [.clear, .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: max(pageHeight * 0.35, footerReserve + 96))
        }
        .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(spacing: VoiidSpacing.sm) {
            ProfileAvatarButton(photoURL: UserDirectory.shared.photoURL(context.authorId),
                                name: UserDirectory.shared.displayName(context.authorId), size: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(context.isMine ? "Your moment" : UserDirectory.shared.displayName(context.authorId))
                    .font(VoiidFont.headline).foregroundColor(.white)
                if let s = current {
                    Text(relative(s.createdAt)).font(VoiidFont.caption).foregroundColor(.white.opacity(0.7))
                }
            }
            Spacer()
            if current?.media.mime.hasPrefix("video") == true {
                Button { muted.toggle(); activePlayer?.isMuted = muted } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundColor(.white).padding(8)
                }
            }
            if context.isMine, let s = current {
                Menu {
                    Button(role: .destructive) { Task { await engine.deleteStory(s); onDismiss() } } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis").foregroundColor(.white).padding(8) }
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, safeArea.top)
    }

    /// The caption rides in the story envelope and Android has rendered it since day one;
    /// the iOS viewer never referenced it, so an iOS viewer silently dropped what the sender
    /// wrote.
    @ViewBuilder private var caption: some View {
        if let s = current, !s.caption.isEmpty {
            Text(s.caption)
                .font(VoiidFont.rounded(15, .regular))
                .foregroundColor(.white)
                // BOUNDED. The caption shares one VStack with the footer, so an unbounded
                // caption at AX5 on a 667pt SE grew until it pushed the reply field off the
                // bottom of the screen — the controls simply left. Four lines is enough for
                // any caption worth reading at a glance on a 5s story, and the tail truncates
                // rather than evicting the interface.
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.bottom, VoiidSpacing.sm)
        }
    }

    @ViewBuilder private var footer: some View {
        if context.isMine {
            // No hand-written `paused = true` here any more: `showViewers` IS the pause (see
            // `paused`), and `.onChange(of: paused)` drives the player. One flag, one flip.
            Button { showViewers = true } label: {
                let s = current
                let count = s.map { StoryStore.viewers(storyId: $0.id).count } ?? 0
                Label(StorySettings.shared.sendViewReceipts ? "\(count) views" : "Views",
                      systemImage: "eye")
                    .font(VoiidFont.subhead).foregroundColor(.white)
                    .padding(.horizontal, VoiidSpacing.md).padding(.vertical, VoiidSpacing.sm)
                    .background(.white.opacity(0.15)).clipShape(Capsule())
            }
            .padding(.bottom, safeArea.bottom + VoiidSpacing.sm)
        } else if current?.allowsReplies == true {
            VStack(spacing: VoiidSpacing.sm) {
                // A 30pt glyph is a ~30pt target; six of them in a row on a phone is a
                // gauntlet. The height comes from PADDING around each emoji rather than from a
                // `.frame` stretching one — a frame would give the button a 44pt box while the
                // glyph still drew at 30pt in the middle of it, which looks identical and
                // hit-tests identically only if `contentShape` agrees. Padding + an explicit
                // contentShape makes the whole 44pt genuinely tappable.
                //
                // `spacing: 0` because the padding now supplies the gaps; keeping VoiidSpacing.md
                // on top of it would overflow six 44pt targets past a 320pt-wide SE.
                HStack(spacing: 0) {
                    ForEach(["❤️","😂","😮","😢","👏","🔥"], id: \.self) { emoji in
                        Button { sendReaction(emoji) } label: {
                            Text(emoji)
                                .font(.system(size: 30))
                                // NOT scaled by Dynamic Type: at AX5 a 30pt emoji becomes ~90pt
                                // and six of them cannot share a row on any iPhone. The rail is
                                // a row of targets, and the target size is what accessibility
                                // actually needs here — which the 44pt below already guarantees.
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(BouncyEmojiStyle())
                        .accessibilityLabel("React \(emoji)")
                    }
                }
                .frame(maxWidth: .infinity)
                Button { showReply = true } label: {
                    HStack {
                        Text("Reply to \(UserDirectory.shared.displayName(context.authorId))…")
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, VoiidSpacing.md)
                    // `minHeight`, not `height`. A hard 48 clipped the label the moment
                    // Dynamic Type grew it past the capsule — the field kept its shape and
                    // ate its own text. A minimum keeps the 44pt+ target on the default size
                    // and lets the capsule grow with the type instead of cropping it.
                    .padding(.vertical, VoiidSpacing.sm)
                    .frame(minHeight: 48)
                    .background(.white.opacity(0.12)).clipShape(Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
                    .contentShape(Capsule())
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.bottom, safeArea.bottom + VoiidSpacing.sm)
        }
    }

    private var replySheet: some View {
        VStack(spacing: VoiidSpacing.md) {
            Text("Reply to \(UserDirectory.shared.displayName(context.authorId))")
                .font(VoiidFont.headline).foregroundColor(VoiidColor.textPrimary)
            VoiidTextField(placeholder: "Message", text: $replyText)
            VoiidPrimaryButton(title: "Send", enabled: !replyText.trimmingCharacters(in: .whitespaces).isEmpty) {
                if let s = current {
                    let body = replyText
                    Task { await engine.reply(to: s, text: body, reaction: nil) }
                }
                replyText = ""; showReply = false; toastThenDismiss("Sent")
            }
            Spacer()
        }
        .padding(VoiidSpacing.lg)
        .background(VoiidColor.background.ignoresSafeArea())
        .presentationDetents([.height(260)])
    }

    private func sendReaction(_ emoji: String) {
        guard let s = current else { return }
        Task { await engine.reply(to: s, text: "", reaction: emoji) }
        toastThenDismiss("Sent")
    }

    // MARK: - Playback lifecycle

    /// Makes the video match `paused`. The progress timer needs no equivalent — it reads
    /// `paused` directly in `advanceProgress` — so this is the whole of the resume path.
    private func syncPlayback() {
        guard isActive, !paused, loadState == .ready else {
            players.pauseAll()
            return
        }
        activePlayer?.play()
    }

    private func start() {
        index = min(max(context.firstUnviewedIndex, 0), max(stories.count - 1, 0))
        loadCurrent()
    }

    private func stop() {
        players.releaseAll()
        progress = 0
    }

    private func loadCurrent() {
        progress = 0
        image = nil
        backdrop = nil
        players.pauseAll()
        guard let s = current else { onAdvanceContext(); return }
        // Mark seen immediately on display (drives the ring); receipt sent async if opted in.
        Task { await engine.markViewed(s) }
        loadState = .loading
        // Fast forward-taps can leave two loads in flight. Only the one whose story is still
        // on screen may write view state, or a slow story overwrites the one after it.
        let target = s.id
        Task {
            guard let url = await engine.ensureDownloaded(s) else {
                guard current?.id == target else { return }
                loadState = (StoryStore.story(s.id)?.downloadState == .gone) ? .gone : .failed
                return
            }
            let isVideo = s.media.mime.hasPrefix("video")
            var decoded: UIImage?
            if isVideo {
                players.prepare(id: s.id, url: url, muted: muted)
            } else {
                decoded = await StoryImageCache.shared.image(at: url, maxPixel: decodePixelSize)
            }
            guard current?.id == target else { return }
            image = decoded
            loadState = .ready
            if isVideo, isActive, !paused {
                players.activate(s.id, restart: true)
            }
            prefetchWindow()
            // AFTER the story is on screen: the backdrop only fills bands the user is already
            // looking at, so it must never be in front of the media it sits behind.
            let filler = await StoryImageCache.shared.backdrop(at: url, isVideo: isVideo)
            guard current?.id == target else { return }
            backdrop = filler
        }
    }

    /// Vertical strip at the bottom of the page that the invisible forward/back tap sheet must
    /// NOT cover, so the emoji rail and the reply field own their own hit area.
    ///
    /// Computed from the same parts the footer is actually built from — the 44pt reaction row,
    /// the 48pt reply capsule, the spacing between them and the bottom inset — rather than a
    /// magic number, so it stays correct on an SE (bottom inset 0) and on a Dynamic Island
    /// phone (34) without a second value to keep in sync. The "views" footer on your OWN story
    /// is shorter, so this over-reserves slightly there; over-reserving costs a strip of
    /// forward-tap at the very bottom edge, while under-reserving costs a mis-sent reaction.
    private var footerReserve: CGFloat {
        guard !context.isMine else { return 44 + safeArea.bottom + VoiidSpacing.sm }
        return 44 + VoiidSpacing.sm + 48 + safeArea.bottom + VoiidSpacing.sm
    }

    /// Bound the decode to what the screen can actually show — a 12MP still resampled to
    /// ~1290px is the difference between a stall and a frame. `VoiidScreen.width` is the
    /// floor because a page measured mid-layout can hand us a zero size, and a 3px thumbnail
    /// blown up full-screen is worse than the stall we are removing.
    private var decodePixelSize: CGFloat {
        max(pageSize.width, pageSize.height, VoiidScreen.width) * displayScale
    }

    /// §8.4 prefetch, three deep and spilling into the next author.
    ///
    /// It used to warm exactly one story, in this context only, on a task that started only
    /// after the current story had finished downloading — so on a cold context item 2 was
    /// serialised behind item 1's whole round-trip, and the author boundary was never crossed
    /// at all. Three parallel warms, plus the head of the following author once this context
    /// is nearly done, is what makes both the forward tap and the sideways swipe a resume.
    ///
    /// It warms the DECODE, not just the bytes: a downloaded-but-undecoded story still pays
    /// the expensive half on display.
    private func prefetchWindow() {
        let ahead = Array(stories.dropFirst(index + 1).prefix(StoryPrefetch.depth))
        let window = ahead + nextContextStories.prefix(StoryPrefetch.depth - ahead.count)

        // The player pool stays TWO deep regardless of how far the byte prefetch reaches: an
        // AVPlayer is a live decoder and an audio-session participant, so only the story
        // immediately next gets one. Everything beyond it is warmed as bytes on disk.
        players.retainOnly([current?.id, ahead.first?.id].compactMap { $0 })

        guard !window.isEmpty else { return }
        let pixels = decodePixelSize
        // Detached at utility, and parallel — the exact remedy already applied to the Clips
        // pager. Serialising these would put the story about to come on screen last in line
        // behind the two after it, and leaving them on the page's own scope means a page the
        // pager recycles takes its warmed neighbours down with it.
        // The window is the concurrency cap: at most `depth` R2 downloads at once.
        Task.detached(priority: .utility) { [engine, players, cache = StoryImageCache.shared, muted] in
            await withTaskGroup(of: Void.self) { group in
                for (offset, story) in window.enumerated() {
                    group.addTask {
                        guard let url = await engine.ensureDownloaded(story) else { return }
                        let isVideo = story.media.mime.hasPrefix("video")
                        // Only the story immediately next gets the FULL-SIZE warm — a
                        // screen-sized still is ~20MB decoded, and three of those in the cache
                        // would evict the one on screen to warm ones the user may never reach.
                        // Everything else lands as bytes plus its ~96px backdrop, which is
                        // enough for the next page to open on the blurred fill rather than on
                        // black while its own decode runs.
                        if offset == 0 {
                            if isVideo { await players.prepare(id: story.id, url: url, muted: muted) }
                            else { _ = await cache.image(at: url, maxPixel: pixels) }
                        }
                        _ = await cache.backdrop(at: url, isVideo: isVideo)
                    }
                }
            }
        }
    }

    private func advanceProgress() {
        guard isActive, !paused, loadState == .ready, let s = current else { return }
        let dur = s.segmentDuration
        // Video advances on natural end; images on the 5s timer. For video we track the
        // player's own time so pause/seek stays exact.
        if s.media.mime.hasPrefix("video"), let player = activePlayer,
           let item = player.currentItem, item.duration.seconds > 0 {
            let t = player.currentTime().seconds
            progress = min(t / min(item.duration.seconds, 30.0), 1)
            if progress >= 1 { forward() }
        } else {
            progress += (1.0 / 30.0) / dur
            if progress >= 1 { forward() }
        }
    }

    private func forward() {
        if index < stories.count - 1 { index += 1 } else { onAdvanceContext() }
    }
    private func back() {
        if index > 0 { index -= 1 } else { onRewindContext() }
    }

    private func toastThenDismiss(_ msg: String) {
        toast = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { onDismiss() }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
