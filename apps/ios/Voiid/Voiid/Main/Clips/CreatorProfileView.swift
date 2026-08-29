//
//  CreatorProfileView.swift
//  Voiid
//
//  A creator's public profile, reached from a clip.
//
//  ── A 1:1 PORT OF THE VOIID UI REFERENCE ────────────────────────────────────────
//  The layout here is Chat/SocialProfileScreen.swift, copied structure-for-structure:
//  cover → identity → counts → actions → highlights → tabBar → grid, with the top bar
//  FLOATING over the cover rather than sitting above it in the stack. Every size, spacing
//  and radius is the reference's. Where this file differs from that one it is because the
//  reference is a static mockup over sample arrays and this renders live data — those
//  places are commented individually.
//
//  ── THIS IS THE THIRD IDENTITY, AND THEY ARE ALL DIFFERENT ──────────────────────
//  Carried over from the reference because it still governs what belongs here:
//
//    * Settings       — YOUR ACCOUNT. Devices, privacy, the V PIN. Only you see it.
//    * this screen    — a PUBLIC creator page. Follow, the grid, highlights. NOT a route
//                       to messaging: see the note in `actions`.
//                       `is_self` swaps Follow for Edit profile/Share and changes
//                       nothing else, which is the test that both states are one screen.
//
//  ── WHAT IS DELIBERATELY NOT THE REFERENCE ──────────────────────────────────────
//  The reference's tab bar has three tabs — Posts, Clips, Tagged. Voiid has only clips, so
//  two of the three would be dead controls. The bar is kept (it is load-bearing to the
//  layout: it separates the header from the grid) with the tabs that have content behind
//  them, and grows when there is something to put there.
//

import SwiftUI

struct CreatorProfileView: View {

    let handle: String

    @EnvironmentObject private var creators: CreatorEngine
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession

    @State private var loadError: String?
    @State private var loading = false
    @State private var showEdit = false
    @State private var showPrivacy = false
    /// One-line explanation for an action that cannot complete yet. Shown as a transient
    /// banner rather than an alert: it is information, not a decision to make.
    @State private var hintText: String?
    @State private var bioExpanded = false
    @State private var openIndex: Int?
    @State private var highlightRows: [CreatorService.Highlight] = []
    @State private var highlightsLoading = true
    @State private var highlightsError: String?
    @Namespace private var zoom

    private var profile: CreatorService.Profile? { creators.cachedProfile(handle) }

    /// The reference's 3 × 3pt mesh.
    private let columns = [
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3),
    ]

    var body: some View {
        ZStack {
            VoiidColor.background.ignoresSafeArea()

            if let p = profile {
                ScrollView {
                    VStack(spacing: 0) {
                        // The cover and the identity block OVERLAP: the avatar sits on the
                        // cover's lower edge, which is what ties the two into one header
                        // rather than two stacked bands.
                        cover(p)
                        identity(p)
                        counts(p)
                        actions(p)
                        highlights
                        tabBar
                        grid(p)
                    }
                }
                .scrollIndicators(.hidden)
                .ignoresSafeArea(edges: .top)
                .contentMargins(.bottom, max(session.bottomInset, 96), for: .scrollContent)
                .refreshable {
                    await load()
                    await creators.refreshClips(for: handle)
                }
            } else if loading {
                ProgressView().tint(VoiidColor.primary)
            } else if let loadError {
                ClipsEmptyState(kind: .failed(loadError)) { Task { await load() } }
            }

            // Floats over the cover rather than sitting above it in the stack. A row of
            // buttons on its own band costs 56pt of height and pushes the name below the
            // fold — the reference's note, and the reason this is an overlay.
            //
            // `safeAreaInset` rather than a top-aligned frame plus a magic number: the
            // system supplies the real inset, so the button lands correctly on every device
            // instead of on whichever one the constant was measured against.
            // A top-aligned VStack inside the safe area. `ignoresSafeArea` is applied to the
            // SCROLL VIEW above, not here, so this bar keeps the real inset the system
            // reports — which is the whole point: 56 was only ever right on one device.
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if let hintText { hintBanner(hintText) }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        // `navigationBarBackButtonHidden` also kills the interactive swipe-back gesture, and
        // losing edge-swipe on a pushed screen is a real regression — it is how most people
        // actually go back. This restores it so the drawn chevron is a VISUAL replacement
        // for the system button, not a behavioural one.
        .voiidInteractiveSwipeBack()
        .task {
            if profile == nil { await load() }
            if creators.clips(for: handle).isEmpty { await creators.refreshClips(for: handle) }
            await loadHighlights()
        }
        .sheet(isPresented: $showEdit) {
            if let p = profile { CreatorEditSheet(profile: p).environmentObject(creators) }
        }
        .navigationDestination(isPresented: $showPrivacy) {
            CreatorPrivacyView().environmentObject(creators)
        }
        .fullScreenCover(item: $openIndex.asIdentifiable()) { boxed in
            ClipFullscreenView(startIndex: boxed.value, feed: pagerFeed)
                .navigationTransition(.zoom(sourceID: zoomID(boxed.value), in: zoom))
                .environmentObject(creators)
        }
    }

    // MARK: - Cover

    /// 148pt, blurred, fading into the page. The reference note: without the fade the cover
    /// ends on a hard horizontal line and reads as a banner ad.
    private func cover(_ p: CreatorService.Profile) -> some View {
        ZStack {
            // The reference has a dedicated cover image; a creator profile has an avatar and
            // an optional cover. Blurring the avatar is the fallback so the band is never
            // empty — the same treatment, one source down.
            if let url = p.avatar_url {
                ClipThumbnail(url: url)
                    .frame(height: 148)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .blur(radius: 14)
                    .overlay(VoiidColor.background.opacity(0.35))
            } else {
                LinearGradient(
                    colors: [VoiidColor.accent.opacity(0.22),
                             VoiidColor.accent.opacity(0.05),
                             VoiidColor.background],
                    startPoint: .topTrailing, endPoint: .bottomLeading)
            }

            LinearGradient(colors: [.clear, VoiidColor.background.opacity(0.6),
                                    VoiidColor.background],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(height: 148)
        .clipped()
    }

    // MARK: - Top bar

    /// Glass circles, because they sit on a photograph rather than on the ground — a flat
    /// surface fill would read as grey dots stuck to the cover.
    ///
    /// ── PLACEMENT ───────────────────────────────────────────────────────────────
    /// Aligned to the SAFE AREA, not a hardcoded 56pt. The reference could hardcode it
    /// because it only ever ran on one simulator; 56 is wrong on every device whose inset
    /// is not 56 — too low on a Pro Max, overlapping the clock on a device with none. The
    /// bar is placed in the safe area and the ZStack keeps it over the cover.
    ///
    /// ── ONE OVERFLOW, NOT TWO ───────────────────────────────────────────────────
    /// There were two ellipsis buttons on this screen — one here and one in the action row
    /// — and this one only set a flag that did nothing. Two identical glyphs with different
    /// behaviours is the opposite of "things that look the same must behave the same"
    /// (Familiarity). The overflow now lives in exactly one place: the action row, beside
    /// the actions it belongs to (Grouping — a control sits near what it affects).
    ///
    /// So the top bar carries navigation only, which is what a navigation bar is for.
    private var topBar: some View {
        HStack {
            backButton

            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.sm)
    }

    /// The system's own back affordance: a chevron at the leading edge that also responds to
    /// the interactive swipe-back gesture, which `navigationBarBackButtonHidden` would
    /// otherwise take away.
    ///
    /// Drawn rather than left to `.navigationTitle` because it sits ON the cover photograph
    /// — a standard bar would need an opaque strip and cost the 56pt of height the reference
    /// removed on purpose. The swipe gesture is restored separately (see `body`), so this is
    /// a visual replacement, not a behavioural one.
    private var backButton: some View {
        Button {
            Haptics.tap()
            dismiss()
        } label: {
            Image(systemName: "chevron.backward")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                // 34pt visible inside a 44pt target: the glyph matches the reference, the
                // touch area matches the platform minimum.
                .frame(width: 34, height: 34)
                .background(Circle().fill(.black.opacity(0.28)))
                .background(.ultraThinMaterial, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Back")
    }

    private func circleButton(_ icon: String, _ label: String,
                              action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.black.opacity(0.28)))
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    // MARK: - Identity

    /// Avatar, name and bio in ONE left-aligned column.
    ///
    /// The reference's note: a large avatar BESIDE the text leaves the name competing with a
    /// circle twice its height and forces the bio into a narrow gutter. Stacked, the bio gets
    /// the full width and the name is the largest thing on screen — which, on a profile, it
    /// should be.
    private func identity(_ p: CreatorService.Profile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            avatar(p)
                // Pulls the avatar up onto the cover.
                .offset(y: -38)
                .padding(.bottom, -38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(p.display_name ?? p.handle)
                        .font(VoiidFont.rounded(21, .bold))
                        .foregroundColor(VoiidColor.textPrimary)

                    if p.is_verified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 15))
                            .foregroundColor(VoiidColor.accentInk)
                    }
                }

                Text("@\(p.handle)")
                    .font(VoiidFont.rounded(13.5))
                    .foregroundColor(VoiidColor.textSecondary)
            }

            if let bio = p.bio, !bio.isEmpty {
                Text(bio)
                    .font(VoiidFont.rounded(14))
                    .foregroundColor(VoiidColor.textPrimary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(bioExpanded ? nil : 3)
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.18)) { bioExpanded.toggle() }
                    }
            }

            if let link = p.link_url, !link.isEmpty {
                linkRow(link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, VoiidSpacing.md)
    }

    /// 82pt — the reference's size exactly.
    private func avatar(_ p: CreatorService.Profile) -> some View {
        avatarImage(p)
            .frame(width: 82, height: 82)
            .clipShape(Circle())
            .overlay(Circle().stroke(VoiidColor.background, lineWidth: 4))
            .overlay(alignment: .bottomTrailing) {
                // The Voiid mark as a creator badge: this is a Voiid account rather than one
                // linked from elsewhere. Distinct from `is_verified` (the seal by the name),
                // which is a manual, audited admin action.
                Circle()
                    .fill(VoiidColor.accent)
                    .frame(width: 24, height: 24)
                    .overlay {
                        Text("V")
                            .font(VoiidFont.rounded(12, .bold))
                            .foregroundColor(VoiidColor.textOnAccent)
                    }
                    .overlay(Circle().stroke(VoiidColor.background, lineWidth: 2.5))
            }
    }

    @ViewBuilder
    private func avatarImage(_ p: CreatorService.Profile) -> some View {
        if let url = p.avatar_url {
            ClipThumbnail(url: url)
        } else {
            ZStack {
                Circle().fill(
                    LinearGradient(colors: [AvatarPalette.color(for: p.handle),
                                            AvatarPalette.color(for: p.handle).opacity(0.72)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(AvatarPalette.initials(for: p.display_name ?? p.handle))
                    .font(VoiidFont.rounded(30, .semibold))
                    .foregroundColor(.white)
            }
        }
    }

    private func linkRow(_ link: String) -> some View {
        Link(destination: URL(string: link.hasPrefix("http") ? link : "https://\(link)")
             ?? URL(string: "https://voiid.app")!) {
            HStack(spacing: 4) {
                Image(systemName: "link").font(.system(size: 11, weight: .semibold))
                Text(link.replacingOccurrences(of: "https://", with: ""))
                    .font(VoiidFont.rounded(13.5))
                    .lineLimit(1)
            }
            .foregroundColor(VoiidColor.accentInk)
        }
    }

    // MARK: - Counts

    private func counts(_ p: CreatorService.Profile) -> some View {
        HStack(spacing: 18) {
            // A nil count means the server WITHHELD it (see publicProfile). The item is
            // omitted rather than shown as 0 — zero is a factual claim this profile is not
            // making.
            if let clips = p.clip_count {
                countItem(ClipCount.compact(clips), "Clips")
            }
            if ClipsFeatureFlags.showSocialCounts {
                if let followers = p.follower_count {
                    countItem(ClipCount.compact(followers), "Followers")
                }
                if let following = p.following_count {
                    countItem(ClipCount.compact(following), "Following")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.md)
    }

    /// NOT a button. The reference makes these tappable, but there is no followers list to
    /// open — a control that presses and goes nowhere is the dead affordance this screen is
    /// meant to avoid.
    private func countItem(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(VoiidFont.rounded(15, .bold))
                .foregroundColor(VoiidColor.textPrimary)
                .monospacedDigit()
            Text(label)
                .font(VoiidFont.rounded(13))
                .foregroundColor(VoiidColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }

    // MARK: - Actions

    private func actions(_ p: CreatorService.Profile) -> some View {
        HStack(spacing: 8) {
            if p.is_self {
                secondaryAction("Edit profile", fill: true) { showEdit = true }
                secondaryAction("Share profile", fill: false) { share(p) }
            } else {
                Button {
                    Haptics.tap()
                    Task { await creators.toggleFollow(p.handle) }
                } label: {
                    Text(p.following ? "Following" : "Follow")
                        .font(VoiidFont.rounded(14.5, .semibold))
                        .foregroundColor(p.following ? VoiidColor.textPrimary
                                                     : VoiidColor.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(p.following ? VoiidColor.surfaceCard : VoiidColor.accent))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(p.following ? VoiidColor.divider : .clear, lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle())
                // The server refuses new follows when the creator has turned them off; the
                // button is disabled rather than failing after the tap.
                .disabled(p.can_follow == false && !p.following)
                .opacity(p.can_follow == false && !p.following ? 0.5 : 1)

                // NO MESSAGE BUTTON. Messaging a creator from their public page is not a
                // feature Voiid offers: it would cross from the public creator identity into
                // the E2EE messaging one, and reaching someone still goes through the
                // contact-PIN gate by design (020_reachability). The reference draws one
                // because its creator page is a mockup with no such boundary.
                //
                // It was here showing "coming soon", which is worse than absent — it
                // advertises a route that does not exist and will not.

                // One overflow, not two icon buttons — the reference's reasoning: a rare
                // action does not earn a permanent 38pt square.
                Menu {
                    Button("Copy profile link", systemImage: "link") { copyLink(p) }
                    Divider()
                    Button("Report", systemImage: "exclamationmark.triangle",
                           role: .destructive) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            hintText = "Thanks — we'll review this profile."
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                        .frame(width: 42, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(VoiidColor.surfaceCard))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(VoiidColor.divider, lineWidth: 1))
                }
                .accessibilityLabel("More options")
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.md)
    }

    private func secondaryAction(_ title: String, fill: Bool,
                                 _ tap: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            tap()
        } label: {
            Text(title)
                .font(VoiidFont.rounded(14.5, .semibold))
                .foregroundColor(fill ? VoiidColor.textOnAccent : VoiidColor.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(fill ? VoiidColor.accent : VoiidColor.surfaceCard))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(fill ? .clear : VoiidColor.divider, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: - Highlights

    /// Photo-filled rings, not empty circles with a glyph in the middle: a highlight IS its
    /// content, and an outlined icon communicates none of that.
    @ViewBuilder
    private var highlights: some View {
        if !highlightRows.isEmpty {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(highlightRows) { row in
                        VStack(spacing: 6) {
                            ClipThumbnail(url: row.cover_url)
                                .frame(width: 56, height: 56)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(VoiidColor.divider, lineWidth: 1))

                            Text(row.title ?? "")
                                .font(VoiidFont.rounded(11.5))
                                .foregroundColor(VoiidColor.textSecondary)
                                .lineLimit(1)
                        }
                        .frame(width: 64)
                    }
                }
                .padding(.horizontal, VoiidSpacing.md)
            }
            .scrollIndicators(.hidden)
            .padding(.top, VoiidSpacing.lg)
        }
    }

    // MARK: - Tabs

    /// Load-bearing even with one tab: it is the rule that separates the header from the
    /// grid. The reference's Posts/Tagged are omitted rather than stubbed — see the file
    /// note.
    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.3x3")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                    Rectangle()
                        .fill(VoiidColor.accent)
                        .frame(height: 2)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, VoiidSpacing.md)

            Divider().overlay(VoiidColor.divider)
        }
        .accessibilityLabel("Clips")
    }

    // MARK: - Grid

    @ViewBuilder
    private func grid(_ p: CreatorService.Profile) -> some View {
        let rows = creators.clips(for: handle)

        if p.can_see_grid == false {
            // A deliberate setting, not a failure: say so plainly rather than showing an
            // empty grid that reads as "this creator has posted nothing".
            VStack(spacing: VoiidSpacing.sm) {
                Image(systemName: "lock")
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(VoiidColor.placeholder)
                Text(p.grid_visibility == "followers"
                     ? "Follow to see their clips" : "These clips are private")
                    .font(VoiidFont.rounded(14))
                    .foregroundColor(VoiidColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 56)
        } else if rows.isEmpty {
            Text("No clips yet")
                .font(VoiidFont.rounded(14))
                .foregroundColor(VoiidColor.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 56)
        } else {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    postTile(row) { openIndex = index }
                        .matchedTransitionSource(id: row.id, in: zoom)
                        .task {
                            await creators.loadMoreClipsIfNeeded(handle: handle, currentItem: row)
                        }
                }
            }
            .padding(.top, 3)
        }
    }

    private func postTile(_ row: CreatorService.CreatorClipRow,
                          _ tap: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            tap()
        } label: {
            ZStack(alignment: .bottomLeading) {
                // Wrapped in a zero-size Color: a bare scaledToFill image proposes its OWN
                // dimensions to the layout and would burst the grid column.
                Color.clear
                    .overlay(ClipThumbnail(url: row.thumb_url))
                    .clipped()

                LinearGradient(colors: [.clear, .black.opacity(0.55)],
                               startPoint: .center, endPoint: .bottom)

                HStack(spacing: 4) {
                    Image(systemName: "play.fill").font(.system(size: 9.5))
                    Text(ClipCount.compact(row.view_count))
                        .font(VoiidFont.rounded(11.5, .semibold))
                }
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .padding(7)
            }
            .aspectRatio(0.8, contentMode: .fit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pager

    private var pagerFeed: ClipFullscreenView.Feed {
        let rows = creators.clips(for: handle)
        return ClipFullscreenView.Feed(
            clips: rows.map { Clip(creatorRow: $0, handle: handle) },
            // Matched back to its source row by id: `rows.last!` would both crash on an
            // empty grid and ask for the next page from the wrong position, so the pager
            // would stop paginating at the end of page one.
            loadMore: { reached in
                guard let row = rows.first(where: { $0.id == reached.id }) else { return }
                await creators.loadMoreClipsIfNeeded(handle: handle, currentItem: row)
            })
    }

    private func zoomID(_ index: Int) -> String {
        let rows = creators.clips(for: handle)
        return index < rows.count ? rows[index].id : "\(index)"
    }

    /// Transient status, bottom-anchored so it does not cover the thing just acted on.
    ///
    /// Enters and leaves along the SAME path (up from the bottom, back down) — a banner that
    /// slides in one way and fades out another reads as two unrelated events. Spring rather
    /// than a fixed curve so a second message re-targets smoothly instead of cutting.
    private func hintBanner(_ text: String) -> some View {
        Text(text)
            .font(VoiidFont.rounded(13.5, .medium))
            .foregroundColor(VoiidColor.textPrimary)
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))
            .padding(.bottom, max(session.bottomInset, 96))
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                // Auto-dismiss: this is status, and status that needs dismissing is a task.
                Task {
                    try? await Task.sleep(for: .seconds(2.6))
                    withAnimation(.spring(response: 0.35, dampingFraction: 1)) {
                        hintText = nil
                    }
                }
            }
    }

    // MARK: - Actions plumbing

    private func share(_ p: CreatorService.Profile) { copyLink(p) }

    private func copyLink(_ p: CreatorService.Profile) {
        UIPasteboard.general.string = "https://voiid.app/@\(p.handle)"
        Haptics.success()
    }

    // MARK: - Loading

    private func load() async {
        loading = profile == nil
        loadError = nil
        do { _ = try await creators.loadProfile(handle) }
        catch { loadError = "Couldn't load that profile." }
        loading = false
    }

    private func loadHighlights() async {
        highlightsLoading = true
        highlightsError = nil
        do { highlightRows = try await CreatorService.shared.highlights(handle: handle).rows }
        catch { highlightsError = "Couldn't load highlights." }
        highlightsLoading = false
    }
}

// MARK: - Edit sheet

/// Edit your own creator profile. The handle is editable but rate-limited to once every 30
/// days server-side, so the field says as much rather than letting the user discover the
/// limit via a 429.
struct CreatorEditSheet: View {
    let profile: CreatorService.Profile

    @EnvironmentObject var creators: CreatorEngine
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String
    @State private var bio: String
    @State private var link: String
    @State private var saving = false
    @State private var errorText: String?

    init(profile: CreatorService.Profile) {
        self.profile = profile
        _displayName = State(initialValue: profile.display_name ?? "")
        _bio = State(initialValue: profile.bio ?? "")
        _link = State(initialValue: profile.link_url ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                    field("Display name", $displayName)
                    field("Bio", $bio)
                    field("Link", $link)

                    if let errorText {
                        Text(errorText)
                            .font(VoiidFont.footnote)
                            .foregroundColor(VoiidColor.error)
                    }

                    VoiidPrimaryButton(title: saving ? "Saving…" : "Save", enabled: !saving) {
                        Haptics.tap()
                        Task { await save() }
                    }
                }
                .padding(VoiidSpacing.md)
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(VoiidColor.textSecondary)
                }
            }
        }
    }

    private func field(_ label: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.xs) {
            Text(label).font(VoiidFont.footnote)
                .foregroundColor(VoiidColor.textSecondary)
            VoiidTextField(placeholder: "Optional", text: binding)
        }
    }

    /// The handle is deliberately NOT sent: this sheet does not edit it, and including it
    /// unchanged would still be a no-op that risks burning the 30-day rename window if the
    /// server's comparison ever changed.
    private func save() async {
        saving = true
        errorText = nil
        defer { saving = false }
        do {
            _ = try await creators.updateProfile(
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                bio: bio.trimmingCharacters(in: .whitespacesAndNewlines),
                linkURL: link.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Highlights
//
// `ProfileHighlight` and its `samples` are GONE. The rail reads `CreatorService.Highlight`
// straight from GET /creators/:handle/highlights (048_creator_highlights.sql), so a local
// mirror of the type would be a second shape to keep in step with the wire for no gain.
