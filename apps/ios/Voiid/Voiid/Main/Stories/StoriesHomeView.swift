//
//  StoriesHomeView.swift
//  Voiid
//
//  The Stories tab root. Local-first: it renders from StoryEngine's published state (backed
//  by StoryStore) and refreshes the feed in the background — a failed fetch never blanks the
//  screen. One home for the feature (no tray above the chat grid, §8.1); the tab icon carries
//  the unread dot.
//
//  Ordering (§8.3): "Your moment" first, then unviewed contexts, then viewed contexts. One
//  card per author context, never one per story.
//
//  ── THE RESTYLE ─────────────────────────────────────────────────────────────────
//  The look comes from the Voiid Ui reference (Chat/MemoriesScreen.swift): a card grid with
//  segmented pips across each card's top edge, a big rounded header, and a section scaffold.
//  What was taken and what was refused:
//
//    TAKEN   card treatment + grid rhythm; the pips (they are REAL here — see StoryMomentCard);
//            the section header scaffold; the header's type scale.
//    REFUSED titles and glyphs ("Concert Night 🎵") — a story has no title, only an E2EE
//            caption the server never sees, and inventing one would mean inventing a field.
//    REFUSED the "N years ago" throwback rail — stories are reaped at 24h, so a year-ago story
//            can never exist. Rendering an always-empty rail would be a lie in the layout.
//            The space it occupied is given to "Your moment", which IS true of this screen.
//    REFUSED absolute dates ("Aug 9, 2024") — see StoryTime.
//
//  ── SECTIONS ────────────────────────────────────────────────────────────────────
//  The reference groups by "Recent / This Month". That is meaningless for content with a
//  24-hour lifetime: EVERYTHING is this month, and everything is recent. The real distinction
//  the model already draws — and the one the ordering rule above is built on — is
//  unviewed vs viewed (`StoryContext.hasUnviewed`, which the engine also sorts by). So the
//  sections are "New" and "Seen", which is both true of the data and the thing a user
//  actually wants ranked: what is left to watch before it expires.
//

import SwiftUI

struct StoriesHomeView: View {
    @EnvironmentObject var session: AppSession
    @ObservedObject private var engine = StoryEngine.shared

    @State private var showComposer = false
    @State private var openContext: StoryContext?
    @State private var openMine = false

    /// Feed-fetch lifecycle, tracked HERE because the engine deliberately never throws to the
    /// UI (`refresh()` is local-first and leaves state as it was on failure). Without this the
    /// screen cannot tell "we have not looked yet" from "we looked and the network refused",
    /// and both would render as the empty state — which would tell the user their contacts
    /// posted nothing when in fact we simply failed to ask.
    private enum FeedPhase { case idle, loading, loaded, failed }
    @State private var phase: FeedPhase = .idle

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10),
              count: dynamicTypeSize.isAccessibilitySize ? 2 : 4)
    }

    // MARK: - Sectioning

    /// Unviewed first. Both lists preserve the engine's own ordering (unviewed-first,
    /// then newest-first), so this only splits a list that is already sorted correctly.
    private var newContexts: [StoryContext] { engine.contexts.filter { $0.hasUnviewed } }
    private var seenContexts: [StoryContext] { engine.contexts.filter { !$0.hasUnviewed } }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                        yourMomentCard

                        if !newContexts.isEmpty {
                            section("New", count: newContexts.count) {
                                recentRail(newContexts)
                            }
                        }

                        if !seenContexts.isEmpty {
                            section("Seen", count: seenContexts.count) {
                                grid(seenContexts)
                            }
                        }

                        // Only one of these can show, and only when there is genuinely nothing
                        // to lay out. Order matters: a failed fetch must win over "empty".
                        if engine.contexts.isEmpty {
                            switch phase {
                            case .loading: loadingState
                            case .failed:  failedState
                            case .idle, .loaded:
                                if engine.myStories.isEmpty { emptyState }
                            }
                        }
                    }
                    .padding(.top, VoiidSpacing.sm)
                    // Measured bar height rather than a guess — see AppSession.bottomInset.
                    // The floor matters: `bottomInset` is 0 until the tab bar measures itself a
                    // frame later, and the last row would already have laid out underneath it.
                    .padding(.bottom, max(session.bottomInset, 96))
                }
                .scrollIndicators(.hidden)
                composeButton
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Moments")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Moment unavailable", isPresented: Binding(get: { engine.actionError != nil }, set: { if !$0 { engine.actionError = nil } })) {
                Button("OK") { engine.actionError = nil }
            } message: { Text(engine.actionError ?? "") }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Moments").font(VoiidFont.screenTitle)
                        .foregroundStyle(VoiidColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink { MomentsPrivacyView() } label: {
                        Image(systemName: "person.2.badge.gearshape")
                    }
                    .accessibilityLabel("Moments privacy")
                    NavigationLink { StoryArchiveView() } label: {
                        Image(systemName: "archivebox")
                    }
                    .accessibilityLabel("Archive")
                }
            }
            .onAppear {
                session.hideTabBar = false
                Task { await load() }
            }
            .refreshable { await load() }
            .sheet(isPresented: $showComposer) { StoryComposerView() }
            .fullScreenCover(item: $openContext) { ctx in
                StoryViewerView(contexts: viewerContexts(startingAt: ctx), startAuthorId: ctx.authorId)
            }
            .fullScreenCover(isPresented: $openMine) {
                if let mine = myContext { StoryViewerView(contexts: [mine], startAuthorId: mine.authorId) }
            }
        }
    }

    /// Only the engine consumes feed envelopes. A health probe must never discard them.
    private func load() async {
        if engine.contexts.isEmpty && engine.myStories.isEmpty { phase = .loading }
        phase = await engine.refresh() ? .loaded : .failed
    }

    // MARK: - Grid

    private func recentRail(_ contexts: [StoryContext]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
                ForEach(contexts) { ctx in
                    StoryMomentCard(context: ctx, width: dynamicTypeSize.isAccessibilitySize ? 164 : 118,
                                    height: dynamicTypeSize.isAccessibilitySize ? 230 : 190, compact: false) {
                        openContext = ctx
                    }
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
    }

    private func grid(_ contexts: [StoryContext]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 10) {
            ForEach(contexts) { ctx in
                StoryMomentCard(context: ctx) {
                    openContext = ctx
                }
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
    }

    // MARK: - Section scaffold

    /// The count rides in the header rather than as a separate line: "New" alone does not say
    /// how much is left to watch before it expires, which is the one number this screen exists
    /// to answer. It is drawn from the same array being rendered, so it can never disagree with
    /// the grid beneath it.
    ///
    /// `.relativeTo(.title3)` scales the size with the user's text setting instead of pinning
    /// it at 19pt — a header that stayed put while the body around it grew would invert the
    /// hierarchy at the large accessibility sizes (rule 8).
    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        count: Int,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: VoiidSpacing.sm) {
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundColor(VoiidColor.textPrimary)

                Text("\(count)")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundColor(VoiidColor.textSecondary)
                    .monospacedDigit()

                Spacer(minLength: 0)
            }
            .padding(.horizontal, VoiidSpacing.md)
            // One element to VoiceOver, so it announces "New, 3 moments" rather than
            // reading the heading and a bare numeral as two unrelated stops.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(count) \(count == 1 ? "moment" : "moments")")
            .accessibilityAddTraits(.isHeader)

            content()
        }
    }

    // MARK: - Your moment
    //
    // This occupies the slot the reference gave its throwback rail. It is a wide banner rather
    // than a grid tile because it is the one entry that is about ACTING (post something), not
    // about watching — and because posting/failed state needs room for real words.

    private var myContext: StoryContext? {
        guard let first = engine.myStories.first else { return nil }
        return StoryContext(authorId: first.authorId, stories: engine.myStories.sorted { $0.createdAt < $1.createdAt })
    }

    /// The three post states are deliberately distinguished by COLOUR, GLYPH AND WORDS at once,
    /// never colour alone: an upload in flight, one that failed, and one that landed must not be
    /// mistaken for each other at a glance.
    private enum MyState { case posting, failed, posted, none }

    private var myState: MyState {
        if !engine.posting.isEmpty { return .posting }
        if engine.myStories.contains(where: { engine.failedPosts.contains($0.id) }) { return .failed }
        return engine.myStories.isEmpty ? .none : .posted
    }

    private var yourMomentCard: some View {
        Button {
            Haptics.tap()
            // A failed post reopens the composer to retry; a live one opens the viewer.
            switch myState {
            case .none, .failed: showComposer = true
            case .posting:       break            // nothing to view yet, and nothing to retry
            case .posted:        openMine = true
            }
        } label: {
            HStack(spacing: VoiidSpacing.md) {
                ZStack(alignment: .bottomTrailing) {
                    ProfileAvatarButton(photoURL: session.profile.photoURL,
                                        name: session.profile.fullName, size: 56)
                        .padding(3)
                        .overlay(Circle().stroke(myRingColor, lineWidth: 2.5))

                    switch myState {
                    case .posting:
                        // A determinate-looking spinner would imply progress we do not measure.
                        ProgressView()
                            .controlSize(.small)
                            .padding(4)
                            .background(Circle().fill(VoiidColor.surfaceCard))
                    case .failed:
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(VoiidColor.textOnAccent, VoiidColor.error)
                    case .none:
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(VoiidColor.textOnPrimary, VoiidColor.primary)
                    case .posted:
                        EmptyView()
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Your moment")
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(VoiidColor.textPrimary)
                    Text(mySubtitle)
                        // .caption was 12pt fixed and did not grow with the user's text
                        // setting; .footnote is the same visual step but scales (rule 8).
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(myState == .failed ? VoiidColor.error : VoiidColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Pips for my own context too, on the same real numbers as the cards.
                    //
                    // NOT colorMultiply. That multiplied every capsule alike — the filled white
                    // ones AND the 0.35-alpha unfilled ones — so both landed on the same teal
                    // and the "how many" the pips exist to show was flattened away. Drawn
                    // directly instead: solid accent for a posted story against an accent tint
                    // for the ground, which keeps the two states distinct on the light card.
                    // Every story here is mine and therefore seen, so all of them read filled,
                    // which is exactly what currentIndex == count already asserted.
                    if myState == .posted, let mine = myContext, mine.stories.count > 1 {
                        HStack(spacing: 3) {
                            ForEach(0..<mine.stories.count, id: \.self) { _ in
                                Capsule()
                                    .fill(VoiidColor.accent)
                                    .frame(height: 3)
                            }
                        }
                        .frame(maxWidth: 92)
                        .padding(.top, 3)
                        .accessibilityHidden(true)   // the subtitle already says "N updates"
                    }
                }

                Spacer(minLength: 0)

                if let mine = engine.myStories.first, myState == .posted {
                    Menu {
                        Button(role: .destructive) { Task { await engine.deleteStory(mine) } } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18))
                            .foregroundColor(VoiidColor.textSecondary)
                            .frame(width: 44, height: 44)
                    }
                }
            }
            .padding(VoiidSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                    .fill(VoiidColor.surfaceCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                    .stroke(myState == .failed ? VoiidColor.error.opacity(0.5) : VoiidColor.divider,
                            lineWidth: 1)
            )
            .padding(.horizontal, VoiidSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPressStyle(scale: 0.98))
    }

    private var myRingColor: Color {
        switch myState {
        case .posted:  return VoiidColor.accent
        case .failed:  return VoiidColor.error
        case .posting: return VoiidColor.divider
        case .none:    return .clear
        }
    }

    private var mySubtitle: String {
        switch myState {
        case .posting:
            let n = engine.posting.count
            return n == 1 ? "Posting…" : "Posting \(n)…"
        case .failed:
            return "Didn't send — tap to retry"
        case .none:
            return "Add to your moment"
        case .posted:
            let n = engine.myStories.count
            let when = StoryTime.relative(engine.myStories.first?.createdAt)
            return n == 1 ? "1 update · \(when)" : "\(n) updates · \(when)"
        }
    }

    // MARK: - Chrome

    /// The FAB floats over the grid, so it needs its own separation from whatever tile happens
    /// to scroll under it — a flat disc on a photo has no edge. A soft ring plus a deeper
    /// shadow gives it one against both a bright and a dark frame (§12: bigger/floating
    /// surfaces read as thicker, and the shadow does the separating over busy content).
    ///
    /// It stays even though the banner also opens the composer: the banner scrolls away, and
    /// posting must remain one tap from anywhere in a long feed. Its glyph is deliberately the
    /// same "plus" the banner's `.none` badge uses, so the two read as one action, not two.
    private var composeButton: some View {
        Button { Haptics.tap(); showComposer = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(VoiidColor.textOnPrimary)
                .frame(width: 60, height: 60)
                .background(VoiidColor.primary)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
        }
        .buttonStyle(SoftPressStyle(scale: 0.92))
        .padding(.trailing, VoiidSpacing.lg)
        .padding(.bottom, session.bottomInset)
        .accessibilityLabel("Post a moment")
    }

    // MARK: - Distinct states
    //
    // Three separate screens on purpose (§rule 4). "We are looking", "we looked and failed",
    // and "we looked and there is nothing" are three different facts, and collapsing the middle
    // one into the last would tell the user nobody posted when we simply never got an answer.

    /// A skeleton in the real grid shape rather than a centred spinner. Two reasons: it tells
    /// the user what is about to arrive (cards, in a two-up portrait grid) instead of only that
    /// something is happening, and when the content lands it replaces tiles of the SAME size, so
    /// the screen does not jump from a spinner to a full grid. The placeholder ratio is read
    /// from the card itself so the two can never drift apart.
    private var loadingState: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            LazyVGrid(columns: gridColumns, spacing: 10) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(VoiidColor.surfaceCard)
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(VoiidColor.divider, lineWidth: 1)
                        }
                }
            }
            .padding(.horizontal, VoiidSpacing.md)

            Text("Loading moments…")
                .font(.system(.subheadline, design: .rounded))
                .foregroundColor(VoiidColor.textSecondary)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, VoiidSpacing.sm)
        // The skeleton is scenery; VoiceOver gets the one fact that matters.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading moments")
    }

    private var failedState: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundColor(VoiidColor.textSecondary.opacity(0.7))
            Text("Couldn't load moments")
                .font(.system(.headline, design: .rounded))
                .foregroundColor(VoiidColor.textPrimary)
            // Explicitly NOT "no moments": we do not know that, and saying so would be a guess.
            Text("We couldn't reach the server. Your moments are safe — pull to try again.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)

            // The pill is built INSIDE the label. It used to be assembled on the Button's
            // outside, which put `.buttonStyle` after the background — so the press style
            // wrapped an already-decorated view and the padding sat outside the tap target,
            // leaving the capsule's edges dead to touch. Built as a label, the whole pill is
            // the hit area and the press scale applies to it.
            Button { Task { await load() } } label: {
                Text("Try Again")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(VoiidColor.textOnAccent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(VoiidColor.accent))
            }
            .buttonStyle(SoftPressStyle())
            .padding(.top, VoiidSpacing.xs)
        }
        .frame(maxWidth: .infinity)
        // Proportional, not a fixed 72/80. On a 667pt SE with the banner above it a fixed inset
        // pushed the button toward the tab bar; at large Dynamic Type it pushed it off. This
        // gives the same airy placement on a tall screen and simply stops taking space on a
        // short one, and the block stays scrollable either way.
        .padding(.top, VoiidSpacing.xxl)
        .padding(.horizontal, VoiidSpacing.xl)
    }

    private var emptyState: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 44))
                .foregroundColor(VoiidColor.textSecondary.opacity(0.5))
            Text("No moments yet")
                .font(.system(.headline, design: .rounded))
                .foregroundColor(VoiidColor.textPrimary)
            // No hardcoded "\n" — a forced break lands mid-sentence once the text scales or is
            // localised. Let it wrap to the measured width instead.
            Text("Share a photo or video with your contacts. It disappears after 24 hours.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, VoiidSpacing.xxl)
        .padding(.horizontal, VoiidSpacing.xl)
    }

    // MARK: - Helpers

    /// Outer pager order: the tapped author first, then the rest of the unviewed/viewed
    /// contexts, so a horizontal swipe moves through people as in §8.4.
    private func viewerContexts(startingAt ctx: StoryContext) -> [StoryContext] {
        var ordered = engine.contexts
        if let i = ordered.firstIndex(where: { $0.authorId == ctx.authorId }) {
            let picked = ordered.remove(at: i)
            ordered.insert(picked, at: 0)
        }
        return ordered
    }
}
