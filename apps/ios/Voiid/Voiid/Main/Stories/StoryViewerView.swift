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

import SwiftUI
import AVKit

struct StoryViewerView: View {
    let contexts: [StoryContext]
    let startAuthorId: String

    @Environment(\.dismiss) private var dismiss
    @State private var authorIndex: Int = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $authorIndex) {
                ForEach(Array(contexts.enumerated()), id: \.element.authorId) { idx, ctx in
                    StoryContextPlayer(
                        context: ctx,
                        isActive: idx == authorIndex,
                        onAdvanceContext: { advanceContext() },
                        onRewindContext: { if authorIndex > 0 { withAnimation { authorIndex -= 1 } } },
                        onDismiss: { dismiss() })
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .onAppear {
            authorIndex = contexts.firstIndex { $0.authorId == startAuthorId } ?? 0
            StoryStore.sweepExpired()
        }
        .statusBarHidden(true)
    }

    private func advanceContext() {
        if authorIndex < contexts.count - 1 { withAnimation { authorIndex += 1 } }
        else { dismiss() }
    }
}

// MARK: - One author's stories

private struct StoryContextPlayer: View {
    let context: StoryContext
    let isActive: Bool
    let onAdvanceContext: () -> Void
    let onRewindContext: () -> Void
    let onDismiss: () -> Void

    @ObservedObject private var engine = StoryEngine.shared
    @State private var index: Int = 0
    @State private var progress: Double = 0
    @State private var paused = false
    @State private var chromeHidden = false
    @State private var muted = true
    @State private var fileURL: URL?
    @State private var loadState: LoadState = .loading
    @State private var player: AVPlayer?
    @State private var showReply = false
    @State private var showViewers = false
    @State private var replyText = ""
    @State private var toast: String?

    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    enum LoadState { case loading, ready, failed, gone }

    private var stories: [Story] { context.stories }
    private var current: Story? { stories.indices.contains(index) ? stories[index] : nil }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                // Tap zones: left third = back, right two-thirds = forward.
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).frame(width: geo.size.width / 3)
                        .onTapGesture { back() }
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { forward() }
                }

                VStack {
                    if !chromeHidden {
                        header
                        StorySegmentProgressView(count: stories.count, currentIndex: index, progress: progress)
                            .padding(.horizontal, VoiidSpacing.md).padding(.top, 4)
                    }
                    Spacer()
                    if !chromeHidden { footer }
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
                paused = pressing
                withAnimation { chromeHidden = pressing }
                if pressing { player?.pause() } else if isActive { player?.play() }
            }, perform: {})
            // Swipe down dismisses.
            .simultaneousGesture(
                DragGesture(minimumDistance: 40).onEnded { v in
                    if v.translation.height > 80 { onDismiss() }
                }
            )
        }
        .onChange(of: isActive) { _, active in if active { start() } else { stop() } }
        .onChange(of: index) { _, _ in loadCurrent() }
        .onAppear { index = context.firstUnviewedIndex; if isActive { start() } }
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
            if let s = current, s.media.mime.hasPrefix("video"), let player {
                VideoPlayer(player: player).disabled(true)
            } else if let url = fileURL, let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                failureText("This story couldn't be loaded")
            }
        case .failed:
            failureText("This story couldn't be loaded")
        case .gone:
            failureText("This story is no longer available")
        }
    }

    private func failureText(_ s: String) -> some View {
        VStack(spacing: VoiidSpacing.md) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundColor(.white.opacity(0.7))
            Text(s).font(VoiidFont.subhead).foregroundColor(.white.opacity(0.85))
        }
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: VoiidSpacing.sm) {
            ProfileAvatarButton(photoURL: UserDirectory.shared.photoURL(context.authorId),
                                name: UserDirectory.shared.displayName(context.authorId), size: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(context.isMine ? "Your story" : UserDirectory.shared.displayName(context.authorId))
                    .font(VoiidFont.headline).foregroundColor(.white)
                if let s = current {
                    Text(relative(s.createdAt)).font(VoiidFont.caption).foregroundColor(.white.opacity(0.7))
                }
            }
            Spacer()
            if current?.media.mime.hasPrefix("video") == true {
                Button { muted.toggle(); player?.isMuted = muted } label: {
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
        .padding(.top, 44)
    }

    @ViewBuilder private var footer: some View {
        if context.isMine {
            Button { paused = true; player?.pause(); showViewers = true } label: {
                let s = current
                let count = s.map { StoryStore.viewers(storyId: $0.id).count } ?? 0
                Label(StorySettings.shared.sendViewReceipts ? "\(count) views" : "Views",
                      systemImage: "eye")
                    .font(VoiidFont.subhead).foregroundColor(.white)
                    .padding(.horizontal, VoiidSpacing.md).padding(.vertical, VoiidSpacing.sm)
                    .background(.white.opacity(0.15)).clipShape(Capsule())
            }
            .padding(.bottom, 40)
        } else if current?.allowsReplies == true {
            VStack(spacing: VoiidSpacing.sm) {
                HStack(spacing: VoiidSpacing.md) {
                    ForEach(["❤️","😂","😮","😢","👏","🔥"], id: \.self) { emoji in
                        Button { sendReaction(emoji) } label: { Text(emoji).font(.system(size: 30)) }
                            .buttonStyle(BouncyEmojiStyle())
                    }
                }
                Button { paused = true; player?.pause(); showReply = true } label: {
                    HStack {
                        Text("Reply to \(UserDirectory.shared.displayName(context.authorId))…")
                            .foregroundColor(.white.opacity(0.7))
                        Spacer()
                    }
                    .padding(.horizontal, VoiidSpacing.md).frame(height: 48)
                    .background(.white.opacity(0.12)).clipShape(Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.bottom, 34)
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
        .onDisappear { if isActive && !paused { player?.play() }; paused = false }
    }

    private func sendReaction(_ emoji: String) {
        guard let s = current else { return }
        Task { await engine.reply(to: s, text: "", reaction: emoji) }
        toastThenDismiss("Sent")
    }

    // MARK: - Playback lifecycle

    private func start() {
        index = min(max(context.firstUnviewedIndex, 0), max(stories.count - 1, 0))
        loadCurrent()
    }

    private func stop() {
        player?.pause(); player = nil; progress = 0
    }

    private func loadCurrent() {
        progress = 0
        player?.pause(); player = nil
        guard let s = current else { onAdvanceContext(); return }
        // Mark seen immediately on display (drives the ring); receipt sent async if opted in.
        Task { await engine.markViewed(s) }
        loadState = .loading
        Task {
            guard let url = await engine.ensureDownloaded(s) else {
                loadState = (StoryStore.story(s.id)?.downloadState == .gone) ? .gone : .failed
                return
            }
            fileURL = url
            if s.media.mime.hasPrefix("video") {
                let p = AVPlayer(url: url); p.isMuted = muted
                player = p
                if isActive && !paused { p.play() }
            }
            loadState = .ready
            prefetchNext()
        }
    }

    /// §8.4 prefetch: only the NEXT story in THIS context.
    private func prefetchNext() {
        let n = index + 1
        guard stories.indices.contains(n) else { return }
        Task { await engine.ensureDownloaded(stories[n]) }
    }

    private func advanceProgress() {
        guard isActive, !paused, loadState == .ready, let s = current else { return }
        let dur = s.segmentDuration
        // Video advances on natural end; images on the 5s timer. For video we track the
        // player's own time so pause/seek stays exact.
        if s.media.mime.hasPrefix("video"), let player, let item = player.currentItem, item.duration.seconds > 0 {
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
