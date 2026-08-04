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

    private func header(_ p: CreatorService.Profile) -> some View {
        VStack(spacing: VoiidSpacing.md) {
            HStack(alignment: .center, spacing: VoiidSpacing.md) {
                avatar(p)
                // Counts sit beside the avatar rather than under the bio so the numbers stay
                // above the fold on a small phone.
                HStack(spacing: 0) {
                    stat(ClipCount.compact(p.clip_count), "Clips")
                    stat(ClipCount.compact(p.follower_count), "Followers")
                    stat(ClipCount.compact(p.following_count), "Following")
                }
                .frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(p.display_name ?? "@\(p.handle)")
                        .font(VoiidFont.headline)
                        .foregroundColor(VoiidColor.textPrimary)
                    if p.is_verified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 13))
                            .foregroundColor(VoiidColor.primary)
                    }
                }
                if p.display_name != nil {
                    Text("@\(p.handle)")
                        .font(VoiidFont.footnote)
                        .foregroundColor(VoiidColor.textSecondary)
                }
                if let bio = p.bio, !bio.isEmpty {
                    Text(bio)
                        .font(VoiidFont.subhead)
                        .foregroundColor(VoiidColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                if let link = p.link_url, !link.isEmpty {
                    // Rendered as a tappable link only when it actually parses as one; a
                    // creator-supplied string is not guaranteed to be a URL.
                    if let url = URL(string: link), url.scheme != nil {
                        Link(destination: url) {
                            Text(link)
                                .font(VoiidFont.footnote)
                                .foregroundColor(VoiidColor.primary)
                                .lineLimit(1)
                        }
                    } else {
                        Text(link)
                            .font(VoiidFont.footnote)
                            .foregroundColor(VoiidColor.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actionButton(p)
        }
        .padding(VoiidSpacing.md)
    }

    @ViewBuilder
    private func avatar(_ p: CreatorService.Profile) -> some View {
        // ClipThumbnail already handles async load, failure and shimmer; a creator avatar is
        // the same problem (a presigned URL that may expire or 404).
        if let url = p.avatar_url {
            ClipThumbnail(url: url)
                .frame(width: 84, height: 84)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(VoiidColor.fieldFill)
                Text(String(p.handle.prefix(1)).uppercased())
                    .font(VoiidFont.rounded(32, .semibold))
                    .foregroundColor(VoiidColor.textSecondary)
            }
            .frame(width: 84, height: 84)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(VoiidFont.rounded(17, .bold))
                .foregroundColor(VoiidColor.textPrimary)
            Text(label)
                .font(VoiidFont.caption)
                .foregroundColor(VoiidColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Your own page shows Edit; everyone else's shows Follow. There is deliberately no
    /// Message button — see the header note.
    @ViewBuilder
    private func actionButton(_ p: CreatorService.Profile) -> some View {
        if p.is_self {
            Button {
                Haptics.tap()
                showEdit = true
            } label: {
                Text("Edit profile")
                    .font(VoiidFont.headline)
                    .foregroundColor(VoiidColor.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(VoiidColor.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
            }
            .buttonStyle(SoftPressStyle())
        } else {
            Button {
                Haptics.tap()
                Task { await creators.toggleFollow(p.handle) }
            } label: {
                Text(p.following ? "Following" : "Follow")
                    .font(VoiidFont.headline)
                    .foregroundColor(p.following ? VoiidColor.textPrimary : VoiidColor.textOnPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(p.following ? VoiidColor.fieldFill : VoiidColor.primary)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
            }
            .buttonStyle(SoftPressStyle())
        }
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
                ForEach(rows) { clip in
                    // THE ASPECT RATIO BELONGS ON THE CELL, NOT THE IMAGE.
                    //
                    // This grid overlapped its own rows. `ClipThumbnail` uses scaledToFill,
                    // which reports an UNBOUNDED ideal height — putting .aspectRatio on the
                    // image only clips the picture, it never tells the cell how tall to be.
                    // The other grids get away with it because they sit directly inside a
                    // ScrollView, which hands its children a definite width to resolve
                    // against; this one is nested in a VStack beside the profile header,
                    // where nothing constrains the cell and every row bleeds into the next.
                    //
                    // Constraining the ZStack fixes it at the source: the cell is a 9:16 box,
                    // the image fills and clips inside it, and the layout is identical to the
                    // other grids by construction rather than by luck.
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
                    .task {
                        await creators.loadMoreClipsIfNeeded(handle: handle, currentItem: clip)
                    }
                }
            }
        }
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
