//
//  CommunityAuthoring.swift
//  Voiid
//
//  The WRITE side of the community Home and About tabs: composing a post, pinning an
//  announcement, and adding an About link. Everything here targets routes that already exist
//  in backend/api/src/routes/communities.ts and client methods that already exist in
//  CommunityService — until this file, none of the six had a caller, so a host could read
//  their community's feed and had no way to put anything in it.
//
//  ── WHY THESE ARE SHEETS AND NOT PUSHED SCREENS ─────────────────────────────────
//  Each one is a short, self-contained write that returns you to the surface you started on:
//  post → the feed you were reading, pin → the card at the top of it, link → the row you just
//  added. A push would take the reader away from the thing the write changes, and coming back
//  would look like navigation rather than like the list having grown.
//
//  ── THE GATES, AND WHERE THEY ACTUALLY LIVE ─────────────────────────────────────
//  Every gate in this file is CONVENIENCE, NOT ENFORCEMENT. The server decides, and it decides
//  the same way whether or not the button was drawn:
//
//    POST   /:id/posts ................ ACTIVE MEMBER. `communityAccess(id, user, false)` —
//                                       explicitly NOT manager. The route comment says why:
//                                       a discoverable community shows its feed to a stranger
//                                       so they can decide to join, and letting that stranger
//                                       post would hand every discoverable community an open
//                                       spam endpoint. Reading is wider than writing; writing
//                                       is wider than managing. Do not narrow this to admins.
//    DELETE /:id/posts/:postId ........ THE AUTHOR, OR A MANAGER. One UPDATE with the
//                                       ownership test in the WHERE, and ONE 404 for "no such
//                                       post", "already removed" and "not yours" alike — so
//                                       there is nothing for the client to branch on and no
//                                       point in the client guessing.
//    POST   /:id/announcements ........ requireManager (owner or admin).
//    DELETE /:id/announcements/:annId . requireManager.
//    POST   /:id/links ................ requireManager.
//    DELETE /:id/links/:linkId ........ requireManager.
//
//  ── NOT E2EE, RESTATED WHERE IT IS WRITTEN ──────────────────────────────────────
//  Posts, announcements and links are SERVER-READABLE by design (047_community_home.sql). A
//  post is a broadcast addressed to everyone who might later look — including, for a
//  discoverable community, people holding no MLS key — and there is no key that means
//  "everyone who might later look". The composer therefore performs no encryption, and that
//  is the correct behaviour rather than a missing step. Channel messages (MLS) and the
//  member↔host DM stay encrypted and share no code path with anything in this file.
//
//  ── THE LENGTH LIMITS ARE THE DATABASE'S, NOT INVENTED ──────────────────────────
//  Every ceiling below is copied from a `check` constraint in 047_community_home.sql, which
//  the routes mirror as MAX_* constants. A client limit looser than the column's turns a typo
//  into a 500; a client limit tighter than the column's silently forbids something the product
//  allows. Both are worth the pedantry of naming the constraint beside each number.
//

import SwiftUI
import PhotosUI

/// The server's own ceilings, named after the constraints that own them.
///
/// A single enum rather than three scattered literals: when 047 changes, there is exactly one
/// place to change, and the constraint name in each comment is what makes the check possible.
enum CommunityWriteLimits {
    /// community_posts_body_len: `char_length(body) between 1 and 5000`.
    static let postBody = 5000
    /// community_announcements_title_len: `between 1 and 140`.
    static let announcementTitle = 140
    /// community_announcements_body_len: `between 1 and 2000`.
    static let announcementBody = 2000
    /// community_links_label_len: `between 1 and 60`.
    static let linkLabel = 60
    /// community_links_value_len: `between 1 and 500`.
    static let linkValue = 500
}

// MARK: - Shared chrome

/// The header every composer sheet opens with, plus its Cancel / confirm pair.
///
/// Factored out because the three sheets differ only in their fields: giving each its own
/// toolbar would let them drift apart, and a Post button that sits somewhere different from
/// the Pin button is the kind of inconsistency nobody reports but everybody feels.
private struct ComposerScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    /// The confirming verb — "Post", "Pin", "Add". Named for what it does, never "Done": the
    /// user is about to publish something to other people and the button should say so.
    let confirm: String
    let canConfirm: Bool
    let busy: Bool
    /// Non-nil ONLY after a write actually failed. A composer that dismissed on failure would
    /// destroy the text the user typed and tell them nothing; this keeps both.
    let failure: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                    VoiidSettingsHeader(title, subtitle: subtitle)

                    content

                    // The failure sits with the fields rather than in an alert: an alert is
                    // dismissed and gone, and the user's next action is to fix the text that
                    // is still on screen underneath it.
                    if let failure {
                        HStack(alignment: .top, spacing: VoiidSpacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(VoiidColor.error)
                            Text(failure)
                                .font(.footnote)
                                .foregroundStyle(VoiidColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(VoiidSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(VoiidColor.error.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md,
                                                    style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md,
                                                  style: .continuous)
                            .stroke(VoiidColor.error.opacity(0.35), lineWidth: 1))
                    }
                }
                .padding(VoiidSpacing.md)
            }
            .voiidSettingsPage()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .foregroundStyle(VoiidColor.textSecondary)
                        // Disabled mid-write, not because cancelling is dangerous but because
                        // the request cannot be recalled: dismissing would leave the user
                        // believing nothing was posted while the row lands anyway.
                        .disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView().tint(VoiidColor.accent)
                    } else {
                        Button(confirm, action: onConfirm)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(canConfirm ? VoiidColor.accentInk
                                                        : VoiidColor.textSecondary)
                            .disabled(!canConfirm)
                    }
                }
            }
        }
    }
}

/// A labelled text field in the composer's card vocabulary, with a live remaining-characters
/// count once the user is near the ceiling.
///
/// The counter appears at 80% rather than always: a count on an empty field is noise, and a
/// count that only shows up when it matters is what makes the ceiling feel like a guardrail
/// instead of a scold.
private struct ComposerField<Content: View>: View {
    let label: String
    let count: Int
    let limit: Int
    @ViewBuilder var content: Content

    private var showCounter: Bool { count >= (limit * 4) / 5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(label)
                    .font(VoiidFont.rounded(12.5, .semibold))
                    .foregroundStyle(VoiidColor.textSecondary)
                Spacer(minLength: 0)
                if showCounter {
                    Text("\(limit - count)")
                        .font(VoiidFont.rounded(12, .semibold))
                        .monospacedDigit()
                        // Over the ceiling is impossible — the binding truncates — so this is
                        // only ever a warning about the last fifth, never an error state.
                        .foregroundStyle(count >= limit ? VoiidColor.warning
                                                        : VoiidColor.textSecondary)
                }
            }

            content
                .font(VoiidFont.rounded(15))
                .foregroundStyle(VoiidColor.textPrimary)
                .tint(VoiidColor.accent)
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, 12)
                .background(VoiidColor.fieldFill)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .stroke(VoiidColor.fieldBorder, lineWidth: 1))
        }
    }
}

/// A `String` binding that refuses to hold more than `limit` characters.
///
/// TRUNCATING RATHER THAN VALIDATING ON SUBMIT is the deliberate choice: the server trims to
/// the same ceiling silently, so a client that accepted 6000 characters and let the user press
/// Post would publish a post ending mid-sentence with no warning. Refusing the keystroke is
/// the only feedback that arrives before the damage.
private func capped(_ source: Binding<String>, _ limit: Int) -> Binding<String> {
    Binding(
        get: { source.wrappedValue },
        set: { source.wrappedValue = String($0.prefix(limit)) }
    )
}

// MARK: - Post composer

/// Write a post into a community's Home feed.
///
/// ── THE PHOTO, AND WHY IT WORKS NOW ─────────────────────────────────────────────
/// This composer shipped with NO media field, because `POST /media/presign-upload` returns an
/// OPAQUE R2 KEY and the feed card rendered `media_url` through `ClipThumbnail(url:)`, which
/// fetches the string as given — a key in that field was a broken image for everyone including
/// the author. `POST /clips/presign-upload` was no help either: it mints a clip row and a clip
/// id, and the object it produces is addressed as a clip, not as a free-standing image.
///
/// `MediaKeyResolver` closes that: any view holding a key presigns it on demand and caches the
/// result, so the key stored in `media_url` is renderable by every reader. The alternative —
/// a route handing out long-lived public URLs — was refused because the bucket also holds E2EE
/// message ciphertext and because a URL that never expires keeps serving a photo after its
/// author or a moderator has taken it down. `MediaKeyResolver`'s header makes the full argument.
///
/// A text box asking the user to paste a URL remains refused, and always will be: it moves
/// missing infrastructure onto the user and produces posts whose media is a link to somebody
/// else's server that can rot, redirect, or track the reader.
///
/// ── THE UPLOAD MUST NOT COST THE USER THEIR TEXT ────────────────────────────────
/// The photo is uploaded as part of Post, not on selection, and a FAILED upload leaves the
/// sheet open with the body intact and the photo still attached. The one thing this must never
/// do is discard what somebody wrote because their network dropped while sending a picture.
struct CommunityPostComposer: View {
    let communityId: String
    /// Handed the post the server actually created — never a locally-built one. The server
    /// fills the author columns and the id, and the feed needs both.
    let onPosted: (CommunityService.Post) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var body_ = ""
    @State private var busy = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    // ── The photo ────────────────────────────────────────────────────────────────
    @State private var photoItem: PhotosPickerItem?
    /// The chosen image, held as pixels rather than as a `PhotosPickerItem` so the preview can
    /// draw immediately and so a retry after a failed upload does not have to re-read from the
    /// photo library — which can fail on its own, for its own reasons, and would turn one
    /// error into two.
    @State private var photo: UIImage?
    /// Set when reading the picked item failed. Distinct from `failure`, which is about the
    /// POST: a photo that would not load and a post that would not send are different problems
    /// with different fixes, and one message for both would name the wrong one.
    @State private var photoError: String?
    @State private var loadingPhoto = false

    private var trimmed: String {
        body_.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ComposerScaffold(
            title: "New post",
            subtitle: "Everyone in this community can see this, and so can anyone browsing it.",
            confirm: "Post",
            // A body of only whitespace is a 400 server-side ("a post cannot be empty"), so
            // the button is dark until there is something real to send.
            canConfirm: !trimmed.isEmpty,
            busy: busy,
            failure: failure,
            onCancel: { dismiss() },
            onConfirm: { Task { await submit() } }
        ) {
            ComposerField(label: "What's happening?",
                          count: body_.count,
                          limit: CommunityWriteLimits.postBody) {
                TextField("Share something with the community…",
                          text: capped($body_, CommunityWriteLimits.postBody),
                          axis: .vertical)
                    .lineLimit(6...14)
                    .focused($focused)
            }

            photoRow

            // Said before they post, not after. 047 makes this feed server-readable because a
            // post is a broadcast; the person writing one is entitled to know that before they
            // write it rather than to discover it in a privacy policy.
            HStack(alignment: .top, spacing: VoiidSpacing.sm) {
                Image(systemName: "megaphone")
                    .font(.system(size: 12))
                    .foregroundStyle(VoiidColor.accentInk)
                Text("Posts are not end-to-end encrypted. They are a broadcast to the whole "
                     + "community. Your Spaces and your messages with the host stay encrypted.")
                    .font(.footnote)
                    .foregroundStyle(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(VoiidSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VoiidColor.accentTint)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        }
        // The keyboard is the point of this sheet; opening without it costs a tap every time.
        .task { focused = true }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
    }

    /// Add-a-photo, or the chosen photo with a way to remove it.
    ///
    /// The preview is drawn at the same 172pt height the FEED CARD uses, so what the composer
    /// shows is what the post will look like — a preview at a different size is a preview of a
    /// different thing.
    @ViewBuilder
    private var photoRow: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            if let photo {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 172)
                        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md,
                                                    style: .continuous))

                    // Disabled while the post is in flight. A photo pulled out from under an
                    // upload that has already started would leave the composer's state and the
                    // request disagreeing about what is being sent.
                    Button {
                        Haptics.tap()
                        self.photo = nil
                        photoItem = nil
                        photoError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(VoiidColor.textOnAccent)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                    .padding(VoiidSpacing.sm)
                    .disabled(busy)
                    .accessibilityLabel("Remove photo")
                }
            }

            PhotosPicker(selection: $photoItem, matching: .images) {
                HStack(spacing: VoiidSpacing.sm) {
                    if loadingPhoto {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: photo == nil ? "photo.on.rectangle"
                                                       : "arrow.triangle.2.circlepath")
                            .font(.system(size: 13))
                    }
                    Text(photo == nil ? "Add a photo" : "Replace photo")
                        .font(VoiidFont.rounded(14, .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(VoiidColor.accentInk)
                .padding(VoiidSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VoiidColor.fieldFill)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .stroke(VoiidColor.fieldBorder, lineWidth: 1))
            }
            .disabled(busy || loadingPhoto)

            if let photoError {
                Text(photoError)
                    .font(.footnote)
                    .foregroundStyle(VoiidColor.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Read the picked item into pixels. NO UPLOAD HAPPENS HERE — see `submit`.
    private func loadPhoto(_ item: PhotosPickerItem) async {
        loadingPhoto = true
        photoError = nil
        defer { loadingPhoto = false }

        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            // The previously chosen photo, if any, is LEFT ALONE. A failed replace must not
            // also destroy the picture that was already attached and fine.
            photoError = "Couldn\u{2019}t read that photo. Try another one."
            Haptics.error()
            return
        }
        photo = image
    }

    private func submit() async {
        guard !busy, !trimmed.isEmpty else { return }
        busy = true
        failure = nil
        defer { busy = false }

        do {
            // The upload is part of Post rather than of picking, so a user who chooses a photo
            // and then changes their mind never spends data on it.
            //
            // A THROW HERE LEAVES THE SHEET OPEN with the body and the photo both intact — the
            // catch below does not distinguish, and does not need to: whichever half failed,
            // the user's next action is the same, and their text is still on screen.
            var mediaKey: String?
            if let photo {
                mediaKey = try await MediaService.shared.uploadCommunityImage(photo)
            }

            let post = try await CommunityService.shared.createPost(
                communityId: communityId, body: trimmed, mediaUrl: mediaKey)
            Haptics.success()
            onPosted(post)
            dismiss()
        } catch {
            // STAY OPEN. The text is still here, the error says what happened, and the user
            // can press Post again. This can legitimately 403 where reading succeeded — the
            // route is member-gated and the feed is not — so the server's own sentence is
            // more useful than any message this screen could invent.
            Haptics.error()
            failure = (error as? APIError)?.errorDescription
                ?? "Couldn\u{2019}t post that. Try again."
        }
    }
}

// MARK: - Announcement composer

/// Pin a new announcement. Manager only (`requireManager`).
///
/// ONE CALL, NOT TWO. The server unpins whatever is live and inserts the new row IN THE SAME
/// TRANSACTION, because `community_announcements_one_live_idx` is UNIQUE on (community_id)
/// WHERE unpinned_at IS NULL and would refuse a second live row. A client that unpinned first
/// and then posted would leave the community with NOTHING pinned if the second call failed —
/// and the first call is not undoable from here. So this sends the new one and only the new
/// one, whether or not something is already pinned.
struct CommunityAnnouncementComposer: View {
    let communityId: String
    /// True when this replaces a live announcement — the only thing that changes is the copy,
    /// because the request is identical either way.
    let replacing: Bool
    let onPinned: (CommunityService.Announcement) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var body_ = ""
    @State private var busy = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedBody: String {
        body_.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ComposerScaffold(
            title: replacing ? "Replace announcement" : "Pin an announcement",
            subtitle: replacing
                ? "This replaces what is pinned now, in one step. The old one is kept in the "
                  + "community's history."
                : "It sits at the top of Home until you unpin it or pin another.",
            confirm: "Pin",
            canConfirm: !trimmedTitle.isEmpty && !trimmedBody.isEmpty,
            busy: busy,
            failure: failure,
            onCancel: { dismiss() },
            onConfirm: { Task { await submit() } }
        ) {
            ComposerField(label: "Title",
                          count: title.count,
                          limit: CommunityWriteLimits.announcementTitle) {
                TextField("Weekly meetup moved to Thursday",
                          text: capped($title, CommunityWriteLimits.announcementTitle))
                    .focused($focused)
            }

            ComposerField(label: "Announcement",
                          count: body_.count,
                          limit: CommunityWriteLimits.announcementBody) {
                TextField("The details people need…",
                          text: capped($body_, CommunityWriteLimits.announcementBody),
                          axis: .vertical)
                    .lineLimit(5...12)
            }
        }
        .task { focused = true }
    }

    private func submit() async {
        guard !busy, !trimmedTitle.isEmpty, !trimmedBody.isEmpty else { return }
        busy = true
        failure = nil
        defer { busy = false }

        do {
            let pinned = try await CommunityService.shared.pinAnnouncement(
                communityId: communityId, title: trimmedTitle, body: trimmedBody)
            Haptics.success()
            onPinned(pinned)
            dismiss()
        } catch {
            Haptics.error()
            failure = (error as? APIError)?.errorDescription
                ?? "Couldn\u{2019}t pin that announcement. Try again."
        }
    }
}

// MARK: - Link composer

/// Add an About link. Manager only (`requireManager`).
///
/// `value` IS NOT VALIDATED AS A URL, and that is 047 speaking rather than an omission: the
/// column is `text` because the About tab also carries a contact address and a "read the
/// handbook" label, and forcing every row to parse as a URL would exclude both. The field
/// therefore accepts whatever the host means to put there.
struct CommunityLinkComposer: View {
    let communityId: String
    let onAdded: (CommunityService.AboutLink) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var value = ""
    /// Nil means "let the About tab pick its fallback". 047 leaves `icon` free text precisely
    /// so the client owns the set, so the set lives here and the server never invents one.
    @State private var icon: String?
    @State private var busy = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    /// The fixed client-side set the migration's comment refers to. Deliberately small and
    /// concrete: a free-text SF Symbol box would let a host save a name that renders as
    /// nothing, and there is no way for the About tab to tell that apart from "no icon".
    private static let icons: [(name: String, meaning: String)] = [
        ("link", "Link"),
        ("globe", "Website"),
        ("envelope", "Email"),
        ("doc.text", "Document"),
        ("calendar", "Events"),
        ("cart", "Shop"),
        ("play.rectangle", "Video"),
        ("bubble.left.and.bubble.right", "Chat"),
        ("music.note", "Music"),
        ("book", "Reading"),
    ]

    private var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ComposerScaffold(
            title: "Add a link",
            subtitle: "Links show on the About tab, to members and to anyone browsing.",
            confirm: "Add",
            canConfirm: !trimmedLabel.isEmpty && !trimmedValue.isEmpty,
            busy: busy,
            failure: failure,
            onCancel: { dismiss() },
            onConfirm: { Task { await submit() } }
        ) {
            ComposerField(label: "Label",
                          count: label.count,
                          limit: CommunityWriteLimits.linkLabel) {
                TextField("Website", text: capped($label, CommunityWriteLimits.linkLabel))
                    .focused($focused)
            }

            ComposerField(label: "Where it goes",
                          count: value.count,
                          limit: CommunityWriteLimits.linkValue) {
                TextField("https://example.com  ·  hello@example.com  ·  Room 4, Tuesdays",
                          text: capped($value, CommunityWriteLimits.linkValue))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Icon")
                    .font(VoiidFont.rounded(12.5, .semibold))
                    .foregroundStyle(VoiidColor.textSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.icons, id: \.name) { option in
                            let selected = icon == option.name
                            Button {
                                Haptics.selection()
                                // Tapping the chosen one clears it: the icon is optional and
                                // there has to be a way back to "none" once one is picked.
                                icon = selected ? nil : option.name
                            } label: {
                                Image(systemName: option.name)
                                    .font(.system(size: 15))
                                    .foregroundStyle(selected ? VoiidColor.textOnAccent
                                                              : VoiidColor.accentInk)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        RoundedRectangle(cornerRadius: VoiidRadius.md,
                                                         style: .continuous)
                                            .fill(selected ? VoiidColor.accent
                                                           : VoiidColor.surfaceCard))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: VoiidRadius.md,
                                                         style: .continuous)
                                            .stroke(selected ? .clear : VoiidColor.divider,
                                                    lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.meaning)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
        .task { focused = true }
    }

    private func submit() async {
        guard !busy, !trimmedLabel.isEmpty, !trimmedValue.isEmpty else { return }
        busy = true
        failure = nil
        defer { busy = false }

        do {
            let link = try await CommunityService.shared.createLink(
                communityId: communityId, label: trimmedLabel,
                value: trimmedValue, icon: icon)
            Haptics.success()
            onAdded(link)
            dismiss()
        } catch {
            Haptics.error()
            // The route answers a 409 when the community is at its link ceiling. That sentence
            // is the server's and is more specific than anything invented here would be.
            failure = (error as? APIError)?.errorDescription
                ?? "Couldn\u{2019}t add that link. Try again."
        }
    }
}
