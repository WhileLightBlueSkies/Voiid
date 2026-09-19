//
//  SocialProfileView.swift
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
import PhotosUI

struct SocialProfileView: View {

    let handle: String
    @State private var renamedHandle: String?
    private var activeHandle: String { renamedHandle ?? handle }

    @EnvironmentObject private var creators: SocialEngine
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
    @State private var tab: ProfileTab = .grid
    @State private var openIndex: Int?
    @State private var highlightRows: [SocialService.Highlight] = []
    @State private var highlightsLoading = true
    @State private var highlightsError: String?
    @Namespace private var zoom

    private var profile: SocialService.Profile? { creators.cachedProfile(activeHandle) }

    /// The reference's 3 × 3pt mesh.
    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: 3),
        GridItem(.flexible(minimum: 0), spacing: 3),
        GridItem(.flexible(minimum: 0), spacing: 3),
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
                    .containerRelativeFrame(.horizontal)
                }
                .scrollIndicators(.hidden)
                .ignoresSafeArea(edges: .top)
                .contentMargins(.bottom, max(session.bottomInset, 96), for: .scrollContent)
                .refreshable {
                    await load()
                    await creators.refreshClips(for: activeHandle)
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
        // THE SYSTEM BACK BUTTON, not a drawn one.
        //
        // The Voiid Ui reference hides the bar and paints a glass chevron on the cover, and
        // this screen used to match it. The cost is that the one control every pushed screen
        // shares stops looking like itself here — and a hidden bar also takes the swipe-back
        // gesture with it, which then has to be restored by hand.
        //
        // An inline bar over a scrolling cover is transparent until the content reaches it,
        // so the photograph is still edge to edge; the difference is that going back is the
        // platform's affordance, in the platform's place, with its gesture intact.
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            if profile == nil { await load() }
            if creators.clips(for: activeHandle).isEmpty { await creators.refreshClips(for: activeHandle) }
            await loadHighlights()
        }
        .onChange(of: creators.me?.handle) { oldHandle, newHandle in
            guard oldHandle == activeHandle, let newHandle, oldHandle != newHandle else { return }
            renamedHandle = newHandle
            Task {
                await creators.refreshClips(for: newHandle)
                await loadHighlights()
            }
        }
        .sheet(isPresented: $showEdit) {
            if let p = profile { CreatorEditSheet(profile: p).environmentObject(creators) }
        }
        .navigationDestination(isPresented: $showPrivacy) {
            SocialPrivacyView().environmentObject(creators)
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
    private func cover(_ p: SocialService.Profile) -> some View {
        ZStack {
            // The reference has a dedicated cover image; a creator profile has an avatar and
            // an optional cover. Blurring the avatar is the fallback so the band is never
            // empty — the same treatment, one source down.
            if let url = p.avatar_url {
                Color.clear
                    .overlay { ClipThumbnail(url: url) }
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
    /// Empty now that the system bar carries the back button. Kept as the spacer that holds
    /// the cover's top inset, so removing it would shift the whole header up.
    private var topBar: some View {
        Color.clear.frame(height: 0)
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
    private func identity(_ p: SocialService.Profile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            avatar(p)
                // Pulls the avatar up onto the cover.
                .offset(y: -38)
                .padding(.bottom, -38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(p.display_name ?? p.handle)
                        .font(.title2.weight(.bold))
                        .foregroundColor(VoiidColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if p.is_verified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 15))
                            .foregroundColor(VoiidColor.accentInk)
                    }
                }

                Text("@\(p.handle)")
                    .font(.subheadline)
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
    private func avatar(_ p: SocialService.Profile) -> some View {
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
    private func avatarImage(_ p: SocialService.Profile) -> some View {
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
                    .font(.subheadline)
                    .lineLimit(1)
            }
            .foregroundColor(VoiidColor.accentInk)
        }
    }

    // MARK: - Counts

    private func counts(_ p: SocialService.Profile) -> some View {
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
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.md)
    }

    /// NOT a button. The reference makes these tappable, but there is no followers list to
    /// open — a control that presses and goes nowhere is the dead affordance this screen is
    /// meant to avoid.
    private func countItem(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private func actions(_ p: SocialService.Profile) -> some View {
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(p.following ? VoiidColor.textPrimary
                                                     : VoiidColor.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                .frame(minHeight: 44)
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
                        .frame(width: 44, height: 44)
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
                .font(.subheadline.weight(.semibold))
                .foregroundColor(fill ? VoiidColor.textOnAccent : VoiidColor.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
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

    /// Three tabs, matching the Voiid Ui reference.
    ///
    /// ALL THREE SHOW THE SAME GRID, and that is what the reference does too — its `tab`
    /// state only moves the underline. There is no server-side distinction to honour: a
    /// "reel" is the player mode for a clip, not a separate kind of content (clips.ts:2),
    /// and nothing tags a person in a clip yet.
    ///
    /// So this is chrome that matches the design without claiming content that does not
    /// exist. When tagging ships, this is where it hangs.
    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(ProfileTab.allCases) { option in
                    let selected = option == tab

                    Button {
                        Haptics.selection()
                        withAnimation(.easeOut(duration: 0.18)) { tab = option }
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: option.icon)
                                .font(.system(size: 16, weight: selected ? .semibold : .regular))
                                .foregroundColor(selected ? VoiidColor.textPrimary
                                                          : VoiidColor.textSecondary)

                            Rectangle()
                                .fill(selected ? VoiidColor.accent : .clear)
                                .frame(height: 2)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.label)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(.top, VoiidSpacing.md)

            Divider().overlay(VoiidColor.divider)
        }
    }

    // MARK: - Grid

    @ViewBuilder
    private func grid(_ p: SocialService.Profile) -> some View {
        let rows = creators.clips(for: activeHandle)

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
                            await creators.loadMoreClipsIfNeeded(handle: activeHandle, currentItem: row)
                        }
                }
            }
            .padding(.top, 3)
        }
    }

    private func postTile(_ row: SocialService.CreatorClipRow,
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
        let rows = creators.clips(for: activeHandle)
        return ClipFullscreenView.Feed(
            clips: rows.map { Clip(creatorRow: $0, handle: activeHandle) },
            // Matched back to its source row by id: `rows.last!` would both crash on an
            // empty grid and ask for the next page from the wrong position, so the pager
            // would stop paginating at the end of page one.
            loadMore: { reached in
                guard let row = rows.first(where: { $0.id == reached.id }) else { return }
                await creators.loadMoreClipsIfNeeded(handle: activeHandle, currentItem: row)
            })
    }

    private func zoomID(_ index: Int) -> String {
        let rows = creators.clips(for: activeHandle)
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

    private func share(_ p: SocialService.Profile) { copyLink(p) }

    private func copyLink(_ p: SocialService.Profile) {
        UIPasteboard.general.string = "https://voiid.app/@\(p.handle)"
        Haptics.success()
    }

    // MARK: - Loading

    private func load() async {
        loading = profile == nil
        loadError = nil
        do { _ = try await creators.loadProfile(activeHandle) }
        catch { loadError = "Couldn't load that profile." }
        loading = false
    }

    private func loadHighlights() async {
        highlightsLoading = true
        highlightsError = nil
        do { highlightRows = try await SocialService.shared.highlights(handle: activeHandle).rows }
        catch { highlightsError = "Couldn't load highlights." }
        highlightsLoading = false
    }
}

// MARK: - Edit sheet

/// Edit your own creator profile. The handle is editable but rate-limited to once every 30
/// days server-side, so the field says as much rather than letting the user discover the
/// limit via a 429.
struct CreatorEditSheet: View {
    let profile: SocialService.Profile

    @EnvironmentObject var creators: SocialEngine
    @Environment(\.dismiss) private var dismiss

    @State private var username: String
    @State private var handleState: SocialEngine.HandleState = .idle
    @State private var confirmRename = false
    @State private var confirmDiscard = false
    @State private var displayName: String
    @State private var bio: String
    @State private var link: String
    @State private var saving = false
    @State private var errorText: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var uploadingPhoto = false
    /// The bytes just picked, shown immediately so the avatar does not wait on a presigned
    /// re-download — the same local-first trick EditProfileView uses for the account photo.
    @State private var pickedImage: UIImage?

    init(profile: SocialService.Profile) {
        self.profile = profile
        _username = State(initialValue: profile.handle)
        _displayName = State(initialValue: profile.display_name ?? "")
        _bio = State(initialValue: profile.bio ?? "")
        _link = State(initialValue: profile.link_url ?? "")
    }

    private var normalizedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var usernameChanged: Bool { normalizedUsername != profile.handle.lowercased() }
    private var hasChanges: Bool {
        usernameChanged || displayName != (profile.display_name ?? "")
            || bio != (profile.bio ?? "") || link != (profile.link_url ?? "")
    }
    private var canSave: Bool {
        hasChanges && !saving && !uploadingPhoto
            && SocialEngine.isWellFormed(normalizedUsername)
            && (!usernameChanged || handleState != .taken)
            && displayName.count <= 40 && bio.count <= 160 && link.count <= 200
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    avatarPicker
                        .padding(.vertical, VoiidSpacing.sm)

                    VoiidCardSection("Identity", footer: "Use 3–20 letters, numbers or underscores, starting with a letter. You can change your social username once every 30 days. Your chat username stays the same.") {
                        field("Display name", placeholder: "Your name", text: $displayName)
                        VoiidRowDivider(inset: VoiidSpacing.md)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Username").font(.footnote.weight(.medium))
                                .foregroundStyle(VoiidColor.textSecondary)
                            HStack(spacing: 4) {
                                Text("@").foregroundStyle(VoiidColor.textSecondary)
                                TextField("username", text: $username)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.asciiCapable)
                                    .accessibilityLabel("Social username")
                            }
                            .font(.body)
                            if usernameChanged { usernameFeedback.font(.footnote) }
                        }
                        .padding(VoiidSpacing.md)
                    }
                    VoiidCardSection("About you") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Bio").font(.footnote.weight(.medium))
                                Spacer()
                                Text("\(bio.count)/160")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(bio.count > 160 ? VoiidColor.error : VoiidColor.textSecondary)
                            }
                            .foregroundStyle(VoiidColor.textSecondary)
                            TextField("A little about you", text: $bio, axis: .vertical)
                                .lineLimit(3...6)
                                .font(.body)
                                .accessibilityLabel("Bio")
                        }
                        .padding(VoiidSpacing.md)
                        VoiidRowDivider(inset: VoiidSpacing.md)
                        field("Link", placeholder: "https://", text: $link, keyboard: .URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    if displayName.count > 40 || link.count > 200 {
                        Text("Keep your name within 40 characters and your link within 200.")
                            .font(.footnote).foregroundStyle(VoiidColor.error)
                    }
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(VoiidColor.error)
                            .accessibilityLabel("Couldn’t save. \(errorText)")
                    }
                }
                .padding(VoiidSpacing.md)
                .disabled(saving)
            }
            .scrollDismissesKeyboard(.interactively)
            .fontDesign(.rounded)
            .foregroundStyle(VoiidColor.textPrimary)
            .voiidSettingsPage()
            .navigationTitle("Edit social profile")
            .interactiveDismissDisabled(hasChanges || saving || uploadingPhoto)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges { confirmDiscard = true } else { dismiss() }
                    }
                    .disabled(saving || uploadingPhoto)
                    .tint(VoiidColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        if usernameChanged { confirmRename = true }
                        else { Task { await save() } }
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                    .tint(VoiidColor.primary)
                }
            }
            .confirmationDialog("Change your username?", isPresented: $confirmRename,
                                titleVisibility: .visible) {
                Button("Change to @\(normalizedUsername)") { Task { await save() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You won’t be able to change it again for 30 days.")
            }
            .confirmationDialog("Discard profile changes?", isPresented: $confirmDiscard,
                                titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .onChange(of: username) { _, _ in
                if usernameChanged {
                    creators.checkHandle(username) { handleState = $0 }
                } else {
                    creators.cancelHandleCheck()
                    handleState = .idle
                }
            }
            .onDisappear { creators.cancelHandleCheck() }
        }
    }

    @ViewBuilder
    private var usernameFeedback: some View {
        switch handleState {
        case .checking:
            Label("Checking availability…", systemImage: "ellipsis")
                .foregroundStyle(VoiidColor.textSecondary)
        case .available:
            Label("Username available", systemImage: "checkmark.circle")
                .foregroundStyle(VoiidColor.success)
        case .taken:
            Label("This username is taken", systemImage: "xmark.circle")
                .foregroundStyle(VoiidColor.error)
        case .badFormat, .idle:
            Text("Start with a letter. Use 3–20 letters, numbers or underscores.")
                .foregroundStyle(VoiidColor.textSecondary)
        case .failed:
            Text("Availability will be checked when you save.")
                .foregroundStyle(VoiidColor.textSecondary)
        }
    }

    /// THE PUBLIC AVATAR, and the copy says so.
    ///
    /// This is `social_profiles.avatar_r2_key` — plaintext, visible to strangers on Clips,
    /// community posts and game rosters. It is NOT the account photo from Settings, which is
    /// governed by `photo_privacy` and shown only to people you have connected with. Two
    /// pictures for two audiences; conflating them is the bug 029 created this column to
    /// avoid.
    private var avatarPicker: some View {
        VStack(spacing: VoiidSpacing.sm) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let pickedImage {
                            Image(uiImage: pickedImage).resizable().scaledToFill()
                        } else if let url = profile.avatar_url {
                            ClipThumbnail(url: url)
                        } else {
                            ZStack {
                                Circle().fill(VoiidColor.accentTint)
                                Text(String(profile.handle.prefix(1)).uppercased())
                                    .font(VoiidFont.rounded(34, .bold))
                                    .foregroundColor(VoiidColor.accent)
                            }
                        }
                    }
                    .frame(width: 96, height: 96)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(VoiidColor.divider, lineWidth: 1))

                    // The affordance, because a tappable avatar with no badge reads as
                    // decoration and nobody finds it.
                    ZStack {
                        Circle().fill(VoiidColor.accent).frame(width: 30, height: 30)
                        if uploadingPhoto {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .overlay(Circle().strokeBorder(VoiidColor.background, lineWidth: 2))
                }
            }
            .buttonStyle(.plain)
            .disabled(uploadingPhoto || saving)
            .accessibilityLabel("Change your public profile photo")

            Text(uploadingPhoto ? "Uploading photo…" : "Change photo")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VoiidColor.primary)
                .accessibilityHidden(true)
            Text("Your social photo is public. Photo changes save immediately.")
                .font(.footnote)
                .foregroundStyle(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await uploadAvatar(item) }
        }
    }

    private func uploadAvatar(_ item: PhotosPickerItem) async {
        uploadingPhoto = true
        defer { uploadingPhoto = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                errorText = "Couldn't read that image."
                return
            }
            pickedImage = image
            // Re-encoded rather than sent as-is: a HEIC straight off the camera is several
            // megabytes and the server stores exactly what it is given.
            guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
                pickedImage = nil
                errorText = "Couldn't prepare that image."
                return
            }
            _ = try await creators.uploadAvatar(jpeg: jpeg)
            errorText = nil
            Haptics.success()
        } catch {
            pickedImage = nil
            errorText = (error as? APIError)?.errorDescription ?? "Couldn't upload that photo."
        }
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>,
                       keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.footnote.weight(.medium))
                .foregroundStyle(VoiidColor.textSecondary)
            TextField(placeholder, text: text)
                .font(.body)
                .keyboardType(keyboard)
                .accessibilityLabel(label)
        }
        .padding(VoiidSpacing.md)
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        errorText = nil
        defer { saving = false }
        do {
            _ = try await creators.updateProfile(
                handle: usernameChanged ? normalizedUsername : nil,
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                bio: bio.trimmingCharacters(in: .whitespacesAndNewlines),
                linkURL: link.trimmingCharacters(in: .whitespacesAndNewlines))
            Haptics.success()
            dismiss()
        } catch {
            errorText = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Highlights
//
// `ProfileHighlight` and its `samples` are GONE. The rail reads `SocialService.Highlight`
// straight from GET /creators/:handle/highlights (048_creator_highlights.sql), so a local
// mirror of the type would be a second shape to keep in step with the wire for no gain.

/// The profile's tab bar. Mirrors `ProfileTab` in the Voiid Ui reference, including the
/// labels: "Posts" for the grid and "Clips" for the reels icon.
enum ProfileTab: String, CaseIterable, Identifiable {
    case grid, reels, tagged

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .grid:   "square.grid.3x3"
        case .reels:  "play.square"
        case .tagged: "person.crop.square"
        }
    }

    var label: String {
        switch self {
        case .grid:   "Posts"
        case .reels:  "Clips"
        case .tagged: "Tagged"
        }
    }
}
