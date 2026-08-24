//
//  CreatorProfileView.swift
//  Voiid
//
//  A creator's public page: header, follow button, and their grid of clips.
//
//  The grid is the SAME 3-column, 2pt-gutter, 9:16 layout as the Explore feed and My Clips,
//  reusing ClipThumbnail. That is deliberate and not up for redesign — it is the layout the
//  rest of Clips already uses, and a creator page that scrolled differently from the feed it
//  is reached from would read as a different app.
//
//  ── NOT E2EE, AND A FOLLOW IS NOT A MESSAGING RIGHT ──────────────────────────────
//  Everything on this screen is public broadcast content. The Follow button grants the
//  ability to see clips that are already public to everyone and nothing else — it opens no
//  conversation, and there is deliberately no "Message" affordance here. Reaching someone
//  still requires one of the three paths in 020_reachability.sql.
//

import SwiftUI

struct CreatorProfileView: View {
    let handle: String

    @EnvironmentObject var creators: CreatorEngine
    @Environment(\.dismiss) private var dismiss

    @State private var loadError: String?
    @State private var loading = false
    @State private var showEdit = false
    @State private var bioExpanded = false
    /// Which tile the user opened, as an index into this creator's grid.
    @State private var openIndex: Int?
    @Namespace private var zoom

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    /// Read straight from the engine's cache so a follow performed anywhere else in the app
    /// is reflected here without this screen holding its own copy to fall out of date.
    private var profile: CreatorService.Profile? { creators.cachedProfile(handle) }

    var body: some View {
        content
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle(profile.map { "@\($0.handle)" } ?? "@\(handle)")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                // Only fetch if we have not already got this profile cached — arriving from a
                // feed tile usually means it is already here.
                if profile == nil { await load() }
                if creators.clips(for: handle).isEmpty { await creators.refreshClips(for: handle) }
            }
            .sheet(isPresented: $showEdit) {
                if let profile {
                    CreatorEditSheet(profile: profile).environmentObject(creators)
                }
            }
            // A profile used to be a gallery you could never play: the tiles had a content
            // shape and nothing else behind them. The pager takes an injected feed now, so
            // this creator's grid opens in the same player as Explore.
            .fullScreenCover(item: $openIndex.asIdentifiable()) { boxed in
                ClipFullscreenView(startIndex: boxed.value, feed: pagerFeed)
                    .navigationTransition(.zoom(sourceID: zoomID(boxed.value), in: zoom))
                    .environmentObject(ClipsEngine.shared)
                    .environmentObject(creators)
            }
    }

    /// This creator's rows as pager pages. Every clip here belongs to the profile being
    /// viewed, so the handle is supplied explicitly — the grid endpoint returns no author
    /// columns precisely because they would be the same on every row.
    private var pagerFeed: ClipFullscreenView.Feed {
        let rows = creators.clips(for: handle)
        return ClipFullscreenView.Feed(
            clips: rows.map { Clip(creatorRow: $0, handle: handle) },
            loadMore: { clip in
                guard let row = rows.first(where: { $0.id == clip.id }) else { return }
                await creators.loadMoreClipsIfNeeded(handle: handle, currentItem: row)
            })
    }

    /// The zoom transition is anchored on the clip id rather than the index, so a page
    /// appended mid-scroll cannot re-point the animation at a different tile.
    private func zoomID(_ index: Int) -> String {
        let rows = creators.clips(for: handle)
        return rows.indices.contains(index) ? rows[index].id : handle
    }

    @ViewBuilder
    private var content: some View {
        // The error state must win over the empty state: rendering "no clips yet" for a
        // failed request is a lie about someone else's page.
        if let loadError, profile == nil {
            ScrollView {
                ClipsEmptyState(kind: .failed(loadError)) { Task { await load() } }
            }
            .refreshable { await load() }
        } else if profile == nil && loading {
            ProgressView().tint(VoiidColor.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let profile {
            ScrollView {
                VStack(spacing: 0) {
                    header(profile)
                    grid
                    Color.clear.frame(height: 100)
                }
            }
            .refreshable {
                await load()
                await creators.refreshClips(for: handle)
            }
        } else {
            ScrollView {
                ClipsEmptyState(kind: .failed("That creator doesn't exist.")) {
                    Task { await load() }
                }
            }
        }
    }

    // MARK: - Header
    //
    // ── THE REFERENCE'S LAYOUT, THIS APP'S DATA ─────────────────────────────────────
    // Cover band, avatar pulled up onto it, name and bio stacked full-width, counts inline as
    // a sentence, then the action row. That is the reference's SocialProfileScreen, rebuilt
    // against CreatorService.Profile rather than its sample struct.
    //
    // Two things the reference draws that this screen does NOT, and why:
    //
    //   Message button .. ABSENT. A follow is not a messaging right — 020_reachability.sql
    //                     defines the only three ways to open a conversation and none of them
    //                     is "followed them". The reference's Message button would promise
    //                     reachability the server refuses.
    //   Tagged tab ...... ABSENT. Nothing in this app tags a person in a clip, so the tab
    //                     would be permanently empty with no path to filling it.

    private func header(_ p: CreatorService.Profile) -> some View {
        VStack(spacing: 0) {
            cover(p)
            identity(p)
            counts(p)
            actionRow(p)
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.top, VoiidSpacing.md)
            highlights
        }
    }

    /// The cover band. A BLURRED, DIMMED copy of the creator's own avatar rather than a stock
    /// photo or a flat accent wash: it is the only image this screen is guaranteed to have,
    /// it is unmistakably theirs, and blurred it reads as a colour field rather than as the
    /// avatar shown twice. The gradient fades it into the page so the band does not end on a
    /// hard line and read as a banner ad.
    ///
    /// A creator with no avatar gets the accent wash instead — see the else branch.
    @ViewBuilder
    private func cover(_ p: CreatorService.Profile) -> some View {
        ZStack {
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
                    startPoint: .topTrailing, endPoint: .bottomLeading
                )
            }

            LinearGradient(colors: [.clear, VoiidColor.background.opacity(0.6),
                                    VoiidColor.background],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(height: 148)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    /// Avatar, name and bio in ONE left-aligned column.
    ///
    /// The previous version put the avatar beside the counts, which left the name competing
    /// with a 96pt circle and forced the bio into a narrow gutter. Stacking gives the bio the
    /// full width and lets the name be the largest thing on the screen — which, on a profile,
    /// it should be.
    private func identity(_ p: CreatorService.Profile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            avatar(p)
                // Pulls the avatar up onto the cover, which is what ties the two into one
                // header instead of two stacked bands.
                .offset(y: -38)
                .padding(.bottom, -38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(p.display_name ?? "@\(p.handle)")
                        .font(VoiidFont.rounded(21, .bold))
                        .foregroundColor(VoiidColor.textPrimary)
                    if p.is_verified { VerifiedSeal() }
                }

                if p.display_name != nil {
                    Text("@\(p.handle)")
                        .font(VoiidFont.rounded(13.5))
                        .foregroundColor(VoiidColor.textSecondary)
                }
            }

            if let bio = p.bio, !bio.isEmpty { bioBlock(bio) }
            if let link = p.link_url, !link.isEmpty { linkRow(link) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, VoiidSpacing.md)
    }

    /// Inline and left-aligned, reading as a sentence: "128 Clips · 52.4K Followers".
    ///
    /// The previous version gave each count a full-width third with a stacked label and
    /// hairline dividers, which made three numbers occupy as much vertical space as the bio.
    /// Counts are reference data on a profile — worth showing, not worth a band of their own.
    ///
    /// STILL NOT BUTTONS. There is no followers list to open, and a control that presses but
    /// goes nowhere is exactly the dead affordance this screen was fixed for.
    private func counts(_ p: CreatorService.Profile) -> some View {
        HStack(spacing: 18) {
            countItem(ClipCount.compact(p.clip_count), "Clips")
            countItem(ClipCount.compact(p.follower_count), "Followers")
            countItem(ClipCount.compact(p.following_count), "Following")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.md)
    }

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

    /// The reference's highlights rail.
    ///
    /// PREVIEW ONLY, and it says so: there is no highlights table, no endpoint and no way for
    /// a creator to make one. The rail renders the intended shape with the notice above it
    /// rather than pretending the circles are real. Migration 048 creates the table; when the
    /// endpoint lands, the notice and `ProfileHighlight.samples` both go.
    private var highlights: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            UnwiredNotice("Highlights have no table or endpoint yet — migration 048 adds one. "
                          + "These circles are placeholders.")
                .padding(.horizontal, VoiidSpacing.md)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(ProfileHighlight.samples) { highlight in
                        VStack(spacing: 6) {
                            Circle()
                                .fill(VoiidColor.accentTint)
                                .frame(width: 56, height: 56)
                                .overlay {
                                    Image(systemName: highlight.icon)
                                        .font(.system(size: 20))
                                        .foregroundColor(VoiidColor.accentInk)
                                }
                                .overlay(Circle().stroke(VoiidColor.divider, lineWidth: 1))

                            Text(highlight.title)
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
            // Inert, and said so to VoiceOver rather than only in colour.
            .allowsHitTesting(false)
            .opacity(0.55)
        }
        .padding(.top, VoiidSpacing.lg)
    }

    /// 96pt portrait inside a gradient ring, with a 3pt gap of background between the two so
    /// the ring reads as a frame rather than a border drawn on the photo. Primary→accent is
    /// the only two-token gradient in the system, and it is what makes a creator page look
    /// like a creator page instead of a settings row with a circle on it.
    @ViewBuilder
    private func avatar(_ p: CreatorService.Profile) -> some View {
        avatarImage(p)
            .frame(width: 96, height: 96)
            .clipShape(Circle())
            .padding(3)
            .overlay(
                Circle().strokeBorder(
                    LinearGradient(colors: [VoiidColor.primary, VoiidColor.accent],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 2.5)
            )
            // Separates the avatar from the cover it now overlaps.
            .overlay(Circle().stroke(VoiidColor.background, lineWidth: 4).padding(-1))
    }

    @ViewBuilder
    private func avatarImage(_ p: CreatorService.Profile) -> some View {
        // ClipThumbnail already handles async load, failure and shimmer; a creator avatar is
        // the same problem (a presigned URL that may expire or 404).
        if let url = p.avatar_url {
            ClipThumbnail(url: url)
        } else {
            ZStack {
                Circle().fill(VoiidColor.fieldFill)
                Text(String(p.handle.prefix(1)).uppercased())
                    .font(VoiidFont.rounded(36, .semibold))
                    .foregroundColor(VoiidColor.textSecondary)
            }
        }
    }

    /// Three lines, then a "more" expander. A creator bio has no length limit worth
    /// trusting, and an unclamped one can push the grid — the reason to be here — off screen.
    @ViewBuilder
    private func bioBlock(_ bio: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bio)
                .font(VoiidFont.subhead)
                .foregroundColor(VoiidColor.textPrimary)
                .lineLimit(bioExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
            if !bioExpanded && bio.count > 120 {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { bioExpanded = true }
                } label: {
                    Text("more")
                        .font(VoiidFont.rounded(13, .semibold))
                        .foregroundColor(VoiidColor.textSecondary)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func linkRow(_ link: String) -> some View {
        // Rendered as a tappable link only when it actually parses as one; a
        // creator-supplied string is not guaranteed to be a URL.
        if let url = URL(string: link), url.scheme != nil {
            Link(destination: url) {
                HStack(spacing: VoiidSpacing.xs) {
                    Image(systemName: "link").font(.system(size: 11))
                    Text(link).lineLimit(1)
                }
                .font(VoiidFont.footnote)
                .foregroundColor(VoiidColor.primary)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
        } else {
            HStack(spacing: VoiidSpacing.xs) {
                Image(systemName: "link").font(.system(size: 11))
                Text(link).lineLimit(1)
            }
            .font(VoiidFont.footnote)
            .foregroundColor(VoiidColor.textSecondary)
        }
    }

    /// Your own page shows Edit; everyone else's shows Follow. There is deliberately no
    /// Message button — see the header note.
    private func actionRow(_ p: CreatorService.Profile) -> some View {
        HStack(spacing: VoiidSpacing.sm) {
            if p.is_self {
                headerButton("Edit profile", filled: true) {
                    Haptics.tap()
                    showEdit = true
                }
            } else {
                followButton(p)
            }
            shareButton(p)
        }
    }

    /// Follow flips to a quiet outlined "Following" rather than staying loud: once the state
    /// is achieved the button is a status, and a filled primary rectangle would keep asking
    /// for a tap the user has already given.
    private func followButton(_ p: CreatorService.Profile) -> some View {
        Button {
            Haptics.success()
            Task { await creators.toggleFollow(p.handle) }
        } label: {
            Text(p.following ? "Following" : "Follow")
                .font(VoiidFont.rounded(15, .semibold))
                .foregroundColor(p.following ? VoiidColor.textPrimary : VoiidColor.textOnPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(p.following ? VoiidColor.fieldFill : VoiidColor.primary)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                // strokeBorder (not stroke) and AFTER the clip, so the 1pt outline sits
                // inside the shape instead of having its outer half clipped away.
                .overlay(
                    RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                        .strokeBorder(VoiidColor.fieldBorder, lineWidth: p.following ? 1 : 0)
                )
                .padding(.vertical, 4)     // 48pt of hit height around a 40pt button
                .contentShape(Rectangle())
        }
        .buttonStyle(SoftPressStyle())
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: p.following)
    }

    /// Shares the same invite text NewChatView uses. Deliberately not a per-handle deep
    /// link: nothing in the app resolves one yet, and a shared link that opens nothing is
    /// worse than no link at all.
    private func shareButton(_ p: CreatorService.Profile) -> some View {
        ShareLink(item: "Watch @\(p.handle)'s clips on VOIID — https://voiid.app") {
            Text("Share profile")
                .font(VoiidFont.rounded(15, .semibold))
                .foregroundColor(VoiidColor.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(VoiidColor.fieldFill)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
    }

    private func headerButton(_ title: String, filled: Bool,
                              _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(title)
                .font(VoiidFont.rounded(15, .semibold))
                .foregroundColor(filled ? VoiidColor.textOnPrimary : VoiidColor.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(filled ? VoiidColor.primary : VoiidColor.fieldFill)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(SoftPressStyle())
    }

    // MARK: - Grid

    @ViewBuilder
    private var grid: some View {
        let rows = creators.clips(for: handle)
        if rows.isEmpty {
            Text(profile?.is_self == true ? "You haven't posted a clip yet."
                                          : "No clips yet.")
                .font(VoiidFont.subhead)
                .foregroundColor(VoiidColor.textSecondary)
                .padding(.top, VoiidSpacing.xl)
        } else {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, clip in
                    Button {
                        Haptics.tap()
                        openIndex = index
                    } label: {
                        tile(clip)
                    }
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: clip.id, in: zoom)
                    .clipTileFadeIn(index: index)
                    .task {
                        await creators.loadMoreClipsIfNeeded(handle: handle, currentItem: clip)
                    }
                }
            }
        }
    }

    private func tile(_ clip: CreatorService.CreatorClipRow) -> some View {
        // THE ASPECT RATIO BELONGS ON THE CELL, NOT THE IMAGE.
        //
        // This grid overlapped its own rows. `ClipThumbnail` uses scaledToFill, which
        // reports an UNBOUNDED ideal height — putting .aspectRatio on the image only clips
        // the picture, it never tells the cell how tall to be. The other grids get away with
        // it because they sit directly inside a ScrollView, which hands its children a
        // definite width to resolve against; this one is nested in a VStack beside the
        // profile header, where nothing constrains the cell and every row bleeds into the
        // next.
        //
        // Constraining the ZStack fixes it at the source: the cell is a 9:16 box, the image
        // fills and clips inside it, and the layout is identical to the other grids by
        // construction rather than by luck.
        ZStack(alignment: .bottomLeading) {
            ClipThumbnail(url: clip.thumb_url)
                .scaledToFill()

            LinearGradient(colors: [.clear, .black.opacity(0.55)],
                           startPoint: .center, endPoint: .bottom)

            HStack(spacing: 3) {
                Image(systemName: "eye.fill").font(.system(size: 10))
                Text(ClipCount.compact(clip.view_count))
                    .font(VoiidFont.rounded(11, .semibold))
            }
            .foregroundColor(.white)
            .shadow(radius: 2)
            .padding(6)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipped()
        .contentShape(Rectangle())
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do { _ = try await creators.loadProfile(handle) }
        catch { loadError = error.localizedDescription }
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

/// One story highlight on a creator's profile.
///
/// ── PREVIEW ONLY ────────────────────────────────────────────────────────────────
/// There is no `creator_highlights` table, no endpoint and no authoring flow. Migration 048
/// creates the schema; until a route serves it, `samples` is what the rail renders and the
/// `UnwiredNotice` above it says so on screen.
///
/// When the endpoint lands: add `Decodable`, delete `samples`, and delete the notice in
/// `CreatorProfileView.highlights`. The view already reads the type rather than the samples.
struct ProfileHighlight: Identifiable, Hashable {
    let id: String
    let title: String
    /// An SF Symbol standing in for the highlight's cover image until covers exist.
    let icon: String

    static let samples: [ProfileHighlight] = [
        .init(id: "travel", title: "Travel", icon: "airplane"),
        .init(id: "mountains", title: "Mountains", icon: "mountain.2"),
        .init(id: "photo", title: "Photography", icon: "camera"),
        .init(id: "music", title: "Music", icon: "music.note"),
        .init(id: "life", title: "Life", icon: "cup.and.saucer"),
    ]
}
