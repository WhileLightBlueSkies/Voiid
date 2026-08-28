//
//  ContactProfileView.swift
//  Voiid
//
//  1:1 contact profile: header (real photo / name / identity) + quick actions,
//  about, shared media, mute, block/report.
//
//  Structure is MIRRORED by Android ContactProfileView.kt — same sections in the same
//  order with the same icons, so the two apps read as one product.
//
//  A row that does nothing is worse than no row: every action here is wired, and the two
//  that genuinely have no implementation yet (search-in-chat, wallpaper) are gone rather
//  than left as dead taps.
//

import SwiftUI

struct ContactProfileView: View {
    let conversation: VConversation
    /// Set by Call / Video, read by ChatDetailView after this screen pops. The chat owns the
    /// single call-setup path; duplicating it here would let the two drift.
    @Binding var pendingCall: CallKind?
    @EnvironmentObject var session: AppSession
    /// Needed for Clear chat, which now lives in the danger card below.
    @EnvironmentObject var chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    /// Seeded from `MuteStore` on appear — the old `muted` flag was view state that reset
    /// on every open.
    @State private var isMuted = false
    /// Names what was just copied, for the confirmation toast. A copy with no feedback is
    /// indistinguishable from a tap that did nothing.
    @State private var copiedLabel: String?
    @State private var viewPhoto = false
    @State private var showAllMedia = false
    @State private var profile: UserProfile?
    /// Blocking (043). Observed so the row flips between Block and Unblock the moment the
    /// mutation lands, without this view tracking its own copy of the state.
    @ObservedObject private var blocks = BlockService.shared
    @State private var blockFailure: String?
    /// Report flow: the confirmation establishes intent, the sheet collects the reason.
    @State private var showReportSheet = false

    /// Explicit states, because "profile == nil" meant BOTH "still loading" and "failed" —
    /// and the screen drew the same empty page for each.
    private enum LoadState { case loading, loaded, failed }
    @State private var loadState: LoadState = .loading
    @State private var showSafetyNumber = false
    @State private var showBlockConfirm = false
    @State private var showClearChatConfirm = false
    @State private var showReportConfirm = false
    @State private var notImplemented: String?

    /// Display name with the app-wide precedence: the name YOU saved in your address
    /// book wins over the name the peer chose for themselves at signup. Previously
    /// this preferred `profile?.name` (their signup name), so a contact you'd saved as
    /// "Mum" showed up as whatever they typed when registering.
    private var displayName: String {
        guard let peer = conversation.peerUserId else { return conversation.title }
        return UserDirectory.shared.displayName(peer, fallback: profile?.name ?? conversation.title)
    }

    /// Shown under the name: the phone number if we have one, else the peer's own
    /// profile name when it differs from what we're displaying — so there is always a
    /// second identifying line rather than a bare name.
    private var secondaryIdentity: String? {
        guard let peer = conversation.peerUserId else { return nil }
        if let phone = UserDirectory.shared.user(peer)?.phoneE164, !phone.isEmpty { return phone }
        if let full = profile?.name, !full.isEmpty, full != displayName { return full }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Full-bleed: no horizontal padding, and it runs UNDER the status bar. A
                // photo inset from the edges reads as a picture ON a page; one that touches
                // all three edges reads as the page itself, which is the point.
                headerCard

                // 20pt between sections, not 24 — with titles sitting outside the cards,
                // each section already carries 8pt of its own leading space, and 24 opened
                // gaps wide enough to read as unrelated screens stacked together.
                // THE REFERENCE'S ORDER AND SPACING: 10pt between sections, not 20.
                //
                // Encryption comes straight after the actions rather than sixth — it is a
                // fact about this conversation, and burying it under About and Media made
                // the page's most load-bearing statement its least prominent.
                //
                // 10pt reads as one continuous page; at 20 each card floated as its own
                // screen. Calls and Settings have no reference equivalent and keep their
                // place at the end, before the danger zone.
                VStack(spacing: 10) {
                    quickActions
                    contactDetailsCard
                    encryptionCard
                    aboutCard
                    sharedMediaCard
                    callHistoryCard
                    settingsCard
                    dangerCard
                }
                // 20pt gutters: 24 left the cards floating in a wide margin on a 390pt phone.
                // 16pt gutters, the reference's `VoiidSpacing.md`.
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.top, VoiidSpacing.md)
                .padding(.bottom, VoiidSpacing.xl)
                // SKELETON TO CONTENT IS A CROSSFADE, NOT A CUT.
                //
                // The skeletons are deliberately the same GEOMETRY as the real text, so the
                // layout does not move when the profile lands — but the swap itself was one
                // frame, which made that carefully-matched geometry read as a glitch rather
                // than as content arriving. Fading turns "the screen flickered" into "it
                // loaded".
                //
                // On the SECTION STACK, not on each card: every card swaps on the same
                // `loadState`, so one modifier covers all of them and they resolve together
                // instead of popping in a ragged sequence.
                //
                // Opacity only — nothing travels, so this is safe under Reduce Motion and
                // needs no gate. Keyed on `loadState` rather than `profile` so a silent
                // refresh that changes nothing visible does not flash the page.
                .animation(.easeInOut(duration: 0.22), value: loadState)
            }
        }
        // The photo extends past the top safe area; everything else respects it.
        // A FLAT GROUND, and the safe area respected.
        //
        // Both the tinted wash and the `ignoresSafeArea` existed to serve the full-bleed
        // portrait: the photo ran under the status bar, and the glass cards needed something
        // to sample or they rendered as grey slabs. With a centred avatar on a plain ground
        // there is no photo to bleed and nothing to sample, so the tint is now just a
        // coloured haze over a details page.
        .background(VoiidColor.background.ignoresSafeArea())
        // Confirmation, bottom-anchored so it never covers the row just tapped. Auto-
        // dismissing because it is status, and status that must be dismissed is a task.
        .overlay(alignment: .bottom) {
            if let copiedLabel {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
                    Text("\(copiedLabel) copied").font(VoiidFont.rounded(14, .medium))
                }
                .foregroundColor(VoiidColor.textOnAccent)
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, 10)
                .background(Capsule().fill(VoiidColor.accent))
                .padding(.bottom, VoiidSpacing.xl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // The system's own chevron and tint. The forced-white version was correct while a
        // dark photograph sat behind the bar; on the flat ground it is now white-on-light —
        // the one control that must always be findable would be invisible.
        // Hide the bottom bar on this detail screen. We do NOT reset on disappear: when you
        // pop back to the CHAT (also a detail screen) its onAppear does not re-fire, so a
        // reset here would wrongly show the bar over the chat. The bar is restored only when
        // a ROOT tab page appears (each sets hideTabBar = false).
        .onAppear {
            session.hideTabBar = true
            // Read from the store, not remembered in the view. A mute set here survives the
            // app being killed, and one set on another screen shows up correctly here.
            isMuted = MuteStore.isMuted(conversation.id)
        }
        .task { await loadProfile() }
        .task { await loadLocalContent() }
        .fullScreenCover(isPresented: $viewPhoto) {
            ProfilePhotoViewer(title: displayName, imageName: conversation.photoName) { viewPhoto = false }
        }
        .sheet(isPresented: $showSafetyNumber) {
            SafetyNumberView(peerUserId: conversation.peerUserId ?? "", peerName: displayName)
        }
        .sheet(isPresented: $showAllMedia) { SharedMediaSheet(title: conversation.title, conversationId: conversation.id) }
        .sheet(isPresented: $showAllCalls) {
            NavigationStack {
                List(allCalls, id: \.id) { entry in
                    callRow(entry)
                        .listRowBackground(VoiidColor.surfaceCard)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(VoiidColor.background)
                .navigationTitle("Calls")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showAllCalls = false }
                    }
                }
            }
        }
        .confirmationDialog("Clear this chat?", isPresented: $showClearChatConfirm,
                            titleVisibility: .visible) {
            Button("Clear chat", role: .destructive) {
                chat.clearChat(conversation.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every message in this conversation is deleted from this device. This cannot be undone.")
        }
        // Block / unblock. The copy differs because the two actions promise different
        // things, and because blocking is SYMMETRIC — saying only "they won't be able to
        // message you" would leave the user to discover their own sends failing and read
        // it as a bug.
        .confirmationDialog(
            isBlocked ? "Unblock \(displayName)?" : "Block \(displayName)?",
            isPresented: $showBlockConfirm, titleVisibility: .visible
        ) {
            if isBlocked {
                Button("Unblock") { toggleBlock() }
            } else {
                Button("Block", role: .destructive) { toggleBlock() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isBlocked
                 ? "You'll both be able to message and call each other again."
                 : "Neither of you will be able to message or call the other. They won't be "
                   + "told. Your messages and any groups you share stay where they are.")
        }
        // A group has no single person to report, so the sheet is only reachable when there
        // is a peer. Guarded here rather than inside the sheet: a sheet that opens and
        // cannot submit is worse than a button that explains itself.
        .sheet(isPresented: $showReportSheet) {
            if let peerId = conversation.peerUserId {
                ReportSheet(target: .person(userId: peerId)) { showReportSheet = false }
            } else {
                VStack(spacing: 14) {
                    Text("There's no individual contact to report in a group.")
                        .font(VoiidFont.rounded(16, .regular))
                        .foregroundColor(VoiidColor.textPrimary)
                        .multilineTextAlignment(.center)
                    Button("OK") { showReportSheet = false }
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(VoiidColor.primary)
                }
                .padding(32)
            }
        }
        .alert(isBlocked ? "Couldn't unblock" : "Couldn't block",
               isPresented: Binding(get: { blockFailure != nil },
                                    set: { if !$0 { blockFailure = nil } })) {
            Button("OK", role: .cancel) { blockFailure = nil }
        } message: {
            Text(blockFailure ?? "")
        }
        .confirmationDialog("Report \(displayName)?", isPresented: $showReportConfirm, titleVisibility: .visible) {
            // Opens the SHEET rather than submitting. The confirmation establishes intent;
            // a report needs a reason, and a one-tap Report that guessed one would file
            // "spam" against someone reported for something serious.
            Button("Report", role: .destructive) { showReportSheet = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The last few messages from this chat are sent to Voiid for review.")
        }
        .alert("Not available yet",
               isPresented: Binding(get: { notImplemented != nil },
                                    set: { if !$0 { notImplemented = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notImplemented ?? "")
        }
    }

    // Header: a full-bleed portrait with the identity laid over it.
    //
    // WHY NOT A CENTERED AVATAR ON A CARD. That layout — round photo, name under it,
    // buttons under that, all centered on a plain ground — is the 2016 iOS profile, and it
    // wastes the one asset the screen actually has: the person's photo, shown at 104pt in a
    // circle while two thirds of the width sits empty. Apple stopped building profiles that
    // way years ago; Contacts, Photos and Music all now anchor identity to a large image and
    // let content scroll beneath it.
    //
    // So the photo goes edge-to-edge at the top, the name sits ON it in white, and the
    // scrim underneath guarantees the text is legible over ANY photo — a dark portrait, a
    // blown-out selfie, or no photo at all. Nothing is centered for its own sake.
    /// Identity — the Voiid Ui reference's `ContactScreen.identity`.
    ///
    /// ── A CENTRED AVATAR, NOT A FULL-BLEED PORTRAIT ─────────────────────────────
    /// This was a 360pt photograph running under the status bar with the name laid over a
    /// scrim. It looked striking and it was the wrong screen: a contact page is a page of
    /// DETAILS, and a photograph occupying the top third pushes every one of them below the
    /// fold. The reference gives the face 88pt and lets the information start immediately.
    ///
    /// The reference's own note explains the ring: no glow, no double ring — those belong to
    /// the call screen, where a ring reports live audio and earns its place. On a static
    /// portrait it is decoration that makes the avatar the loudest thing on a screen whose
    /// job is details.
    private var headerCard: some View {
        VStack(spacing: VoiidSpacing.sm) {
            avatar
                .overlay(Circle().stroke(VoiidColor.accent.opacity(0.6), lineWidth: 2))
                // 16, not the reference's 52.
                //
                // The reference draws its OWN floating back button over the content, so it
                // must reserve the full height of that chrome. Ours uses the system
                // navigation bar, which already occupies that space — adding 52 on top of it
                // pushed the avatar a bar's height down the screen and left a visible gap
                // under the title.
                //
                // Copying the number without the layout it compensates for is how a value
                // that is correct in one place becomes wrong in another.
                .padding(.top, VoiidSpacing.md)

            HStack(spacing: 6) {
                Text(displayName)
                    .font(VoiidFont.rounded(22, .bold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                // NO VERIFIED SEAL. The reference draws one, but `UserProfile` carries no
                // verification flag — a badge that is either always shown or never shown
                // says nothing. It goes in the day the field exists.
            }

            // NO PRESENCE LINE. The reference shows "Online / Last seen recently", but this
            // screen has never fetched presence — it is a profile read, not a live
            // subscription — and inventing a status here would either be a guess or a lie.
            //
            // The chat header already carries it, live, where it belongs.

            // The handle, which the old full-bleed header buried in a line over the photo.
            if let handle = profile?.username, !handle.isEmpty {
                Text("@\(handle)")
                    .font(VoiidFont.rounded(14))
                    .foregroundColor(VoiidColor.textSecondary)
            }

            encryptedPill
        }
        .frame(maxWidth: .infinity)
    }

    /// 88pt, no photo bleed. Falls back to initials on the brand gradient.
    @ViewBuilder
    private var avatar: some View {
        if let url = profile?.photoURL, !url.isEmpty {
            ClipThumbnail(url: url)
                .frame(width: 88, height: 88)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(
                    LinearGradient(colors: [VoiidColor.primary.opacity(0.85),
                                            VoiidColor.primary.opacity(0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(AvatarPalette.initials(for: displayName))
                    .font(VoiidFont.rounded(32, .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 88, height: 88)
        }
    }

    /// The encryption guarantee, stated on the identity block rather than only as a row far
    /// down the page — it is a property of this contact, and the reference treats it as
    /// identity rather than as a setting.
    private var encryptedPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").font(.system(size: 12))
            Text("End-to-end Encrypted").font(VoiidFont.rounded(13, .medium))
        }
        .foregroundColor(VoiidColor.accentInk)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(VoiidColor.accent.opacity(0.10)))
        .overlay(Capsule().stroke(VoiidColor.accent.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var quickActions: some View {
        HStack(spacing: VoiidSpacing.sm) {
            actionButton("message.fill", "Message", filled: true) { dismiss() }
            actionButton("phone.fill", "Call", filled: false) { requestCall(.voice) }
            actionButton("video.fill", "Video", filled: false) { requestCall(.video) }
        }
    }

    private func actionButton(_ icon: String, _ label: String,
                              filled: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: { Haptics.tap(); tap() }) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                Text(label)
                    .font(VoiidFont.rounded(12, .medium))
            }
            .foregroundStyle(filled ? VoiidColor.textOnPrimary : VoiidColor.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background {
                // The PRIMARY action stays solid — glass on the one button you are most
                // likely to press would make it recede exactly where it should lead. The
                // secondary two are glass, so the group reads as one family with a clear
                // first among them.
                if filled {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(VoiidColor.primary)
                        .shadow(color: VoiidColor.primary.opacity(0.28), radius: 12, y: 5)
                }
            }
            .glassIfNeeded(!filled, cornerRadius: 18)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(SoftPressStyle())
        .accessibilityLabel(label)
    }

    /// The peer's photo reference, preferring the freshly-fetched profile and falling back to
    /// whatever the directory already cached — so a face shows on the first frame offline.
    private var photoRef: String? {
        // Freshest first, then two caches. The CONVERSATION's photo is the third fallback and
        // it matters: it is already on screen in the chat header the user just tapped, so
        // omitting it meant the profile could open with a blank portrait for a face the app
        // was displaying a moment earlier.
        if let u = profile?.photoURL, !u.isEmpty { return u }
        if let peer = conversation.peerUserId,
           let cached = UserDirectory.shared.photoURL(peer), !cached.isEmpty { return cached }
        if let convPhoto = conversation.photoURL, !convPhoto.isEmpty { return convPhoto }
        return nil
    }

    /// Call and Video used to be EMPTY closures — the buttons were decoration.
    ///
    /// Rather than duplicate ChatDetailView's call setup (which resolves the peer id, checks
    /// the group-call lock and builds a CallRequest), this pops back to the chat and asks it
    /// to place the call. One code path owns starting a call, so the two can never drift.
    private func requestCall(_ kind: CallKind) {
        pendingCall = kind
        dismiss()
    }

    /// About AND status — two distinct fields the server has always returned separately
    /// (`bio` and `status_text`). They were being collapsed into one, so a user who set a
    /// status saw it labelled "About" and a user with both lost the status entirely.
    @ViewBuilder
    private var aboutCard: some View {
        // PARSED ONCE, and every branch below keys off the parsed value rather than the raw
        // string. Testing the raw string in one place and the parsed one in another is how an
        // unrecognised value ends up rendering nothing at all: skipped by the status branch
        // for being unknown, and skipped by the fallback for being non-empty.
        let status = AvailabilityStatus.from(profile?.statusText)
        let about = profile?.about ?? ""
        card("About") {
            if loadState == .loading {
                // A SKELETON, not a spinner. The card already occupies this space, so a
                // centred spinner would make the layout jump when text replaces it; two
                // dimmed bars the height of the real lines keep the geometry identical.
                VStack(alignment: .leading, spacing: 8) {
                    Capsule().fill(VoiidColor.textPrimary.opacity(0.08)).frame(height: 14)
                    Capsule().fill(VoiidColor.textPrimary.opacity(0.08))
                        .frame(width: 180, height: 14)
                }
                .modifier(PulsePlaceholder())
            } else if loadState == .failed && status == nil && about.isEmpty {
                // FAILED IS NOT EMPTY. Showing "Hey there! I am using Voiid." here would put
                // words in this person's mouth that they never wrote, purely because our
                // request failed — so the failure says so, and offers the retry.
                HStack(spacing: VoiidSpacing.sm) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 14))
                        .foregroundStyle(VoiidColor.textSecondary)
                    Text("Couldn't load profile")
                        .font(VoiidFont.rounded(15, .regular))
                        .foregroundStyle(VoiidColor.textSecondary)
                    Spacer(minLength: 0)
                    Button("Retry") {
                        Haptics.tap()
                        Task { await loadProfile() }
                    }
                    .font(VoiidFont.rounded(14, .semibold))
                    .foregroundStyle(VoiidColor.primary)
                }
            } else if let availability = status {
                // A KNOWN STATUS, drawn from the vocabulary rather than printed as whatever
                // text the column held.
                //
                // `status_text` accepted anything until the write path was closed to four
                // values, so a row could still contain arbitrary text nobody validated and no
                // report path covers. `AvailabilityStatus.from` returns nil for anything
                // outside the set, and this branch is skipped — an unrecognised value shows as
                // no status rather than as unvetted text on a stranger's profile.
                //
                // The glyph is the status's own, so "Busy" looks the same here as it does in
                // the owner's Settings picker.
                HStack(alignment: .top, spacing: VoiidSpacing.sm) {
                    Image(systemName: availability.systemImage)
                        .font(.system(size: 12))
                        .foregroundColor(availability.tint)
                        .padding(.top, 3)
                    Text(availability.label)
                        .font(VoiidFont.rounded(16, .medium))
                        .foregroundColor(VoiidColor.textPrimary)
                    Spacer(minLength: 0)
                }
                if !about.isEmpty {
                    Divider().background(VoiidColor.divider.opacity(0.4))
                }
            }
            if !about.isEmpty {
                Text(about)
                    .font(VoiidFont.rounded(16, .regular))
                    .foregroundColor(VoiidColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Only when BOTH are genuinely absent. Previously the default text was shown
            // whenever `about` was empty, which meant a peer with a real status still read
            // "Hey there! I am using Voiid." — a message they never wrote.
            if status == nil && about.isEmpty {
                Text("Hey there! I am using Voiid.")
                    .font(VoiidFont.rounded(16, .regular))
                    .foregroundColor(VoiidColor.textSecondary)
            }
        }
    }

    /// All shared visual media in this 1:1, newest first — real, from the message store.
    /// Videos count too: the strip previously filtered to `image/` only, so a chat full of
    /// videos reported "no media shared yet".
    /// Computed ONCE, in `.task`, not on every render.
    ///
    /// THIS IS WHY THE PROFILE FELT SLOW. It was a computed property that decoded the whole
    /// message store for this conversation, filtered it and reversed it — and SwiftUI
    /// evaluated it SIX times per render pass (`isEmpty` in the accessory, `isEmpty` again in
    /// the body, `count`, `prefix(8)`, and so on). On a chat with real history that is six
    /// full decodes for one frame, on the main actor, every time anything on the screen
    /// changed. Same for `recentCalls`, which hit SQLite three times per render.
    @State private var sharedMedia: [MediaRef] = []
    @State private var recentCalls: [LocalStore.CallHistoryEntry] = []
    /// The fuller list behind "See all". Held so expanding costs no query.
    @State private var allCalls: [LocalStore.CallHistoryEntry] = []
    @State private var showAllCalls = false

    /// Load both off the render path. Cheap enough to redo on appear (so a photo sent while
    /// the profile was open shows up), expensive enough that it must never sit in `body`.
    private func loadLocalContent() async {
        let convId = conversation.id
        let media: [MediaRef] = await Task.detached(priority: .userInitiated) {
            await ChatEngine.shared.messages(conversationId: convId)
                .compactMap { $0.media }
                .filter { $0.mime.hasPrefix("image/") || $0.mime.hasPrefix("video/") }
                .reversed()
        }.value
        // Load more than the card shows, so "See all" has something to reveal without a
        // second query. 40 bounds it — a card is not a call log.
        allCalls = Array(LocalStore.callsForConversation(convId).reversed().prefix(40))
        let calls = Array(allCalls.prefix(4))
        sharedMedia = media
        recentCalls = calls
    }

    private var sharedMediaCard: some View {
        card(
            "Media",
            accessory: sharedMedia.isEmpty ? nil : AnyView(
                Button("See all") { Haptics.tap(); showAllMedia = true }
                    .font(VoiidFont.rounded(13, .medium))
                    .foregroundColor(VoiidColor.primary)
            )
        ) {
            if sharedMedia.isEmpty {
                mediaEmptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: VoiidSpacing.sm) {
                        ForEach(Array(sharedMedia.prefix(8)), id: \.mediaUrl) { ref in
                            SharedMediaThumb(ref: ref)
                                .frame(width: 76, height: 76).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                        }
                    }
                    .padding(.vertical, 1)
                }
                // Bleed the strip to the card edge so thumbnails scroll OUT of frame rather
                // than stopping short of it — the cut edge is what tells the eye it scrolls.
                .padding(.horizontal, -VoiidSpacing.md)
                .padding(.leading, VoiidSpacing.md)
            }
        }
    }

    /// The empty state.
    ///
    /// GHOST TILES, not a floating icon in a void. The previous version centred a disc and two
    /// lines in an otherwise blank card, which read as a hole in the layout rather than an
    /// empty shelf. Showing the SHAPE the content will take — three dashed squares the size of
    /// real thumbnails — makes the card look designed-but-empty, and tells the user at a
    /// glance what would appear here.
    private var mediaEmptyState: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            HStack(spacing: VoiidSpacing.sm) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                        // A faint FILL under the dashes. On the old opaque card an outline
                        // alone was enough; on glass a bare dashed rectangle has nothing to
                        // sit on and reads as scratches across the blur. The fill gives each
                        // ghost tile a body, so it reads as an empty slot.
                        .fill(VoiidColor.textPrimary.opacity(0.04))
                        .frame(width: 76, height: 76)
                        .overlay(
                            RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                                .strokeBorder(VoiidColor.divider,
                                              style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        )
                        .overlay {
                            Image(systemName: i == 0 ? "photo" : (i == 1 ? "video" : "doc"))
                                .font(.system(size: 18))
                                .foregroundStyle(VoiidColor.placeholder.opacity(0.5))
                        }
                }
                Spacer(minLength: 0)
            }
            Text("Photos, videos and files you share with \(displayName) appear here.")
                .font(VoiidFont.rounded(12, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
        }
        .padding(.vertical, 2)
    }

    /// Recent calls with this person, from the local `call_history` table.
    ///
    /// The transcript already shows call bubbles, but a profile is where you go to answer
    /// "how often do we actually talk?" — and scrolling a whole chat to reconstruct that is
    /// not an answer. Same data, different question.


    /// Phone and @username — the reference's `contactDetails`, and the one section of that
    /// screen we never had.
    ///
    /// ── EVERY VALUE IS COPYABLE, AND SAYS SO ────────────────────────────────────
    /// A phone number on a profile exists to be USED: dialled, pasted into a message, sent
    /// to someone else. Showing it as inert text means the only way to get it out is to
    /// read it aloud. Tapping the value copies it and a toast confirms — feedback on the
    /// causal event, not silence.
    ///
    /// The trailing button is the value's PRIMARY action, separate from copying: a phone
    /// number calls, a username opens a chat. Two intentions, two targets, so neither has to
    /// be guessed at.
    @ViewBuilder
    private var contactDetailsCard: some View {
        // ── WHERE THE PHONE NUMBER COMES FROM, AND WHY IT IS OFTEN ABSENT ───────
        //
        // NOT from the profile. The server returns `phone_number` only to the account's
        // OWNER (users.ts: `isOwner ? u.phone_number : undefined`) — a number is an
        // account's identity and is never disclosed to anyone else. Reading it from
        // `profile` would therefore always be nil for a contact, and the row would never
        // appear at all.
        //
        // The number shown here is the one from YOUR OWN ADDRESS BOOK, matched during
        // contact sync. That is the correct source and the correct behaviour: you see a
        // number you already had, not one the app disclosed to you.
        //
        // So someone who reached you by @username, and whom you have never saved, shows
        // only their handle — there is no number to show, and inventing one would leak
        // exactly what the server is careful not to.
        let phone = conversation.peerUserId
            .flatMap { UserDirectory.shared.user($0)?.phoneE164 }?
            .trimmingCharacters(in: .whitespaces)
        let handle = profile?.username?.trimmingCharacters(in: .whitespaces)

        if (phone?.isEmpty == false) || (handle?.isEmpty == false) {
            card("Contact") {
                if let phone, !phone.isEmpty {
                    detailRow(icon: "phone.fill", label: "Phone", value: phone,
                              trailingIcon: "phone.arrow.up.right",
                              trailingLabel: "Call \(phone)") {
                        pendingCall = .voice
                        dismiss()
                    }
                }
                if let handle, !handle.isEmpty {
                    if phone?.isEmpty == false {
                        VoiidRowDivider()
                    }
                    detailRow(icon: "at", label: "Username", value: "@\(handle)",
                              trailingIcon: "message.fill",
                              trailingLabel: "Message @\(handle)") {
                        dismiss()
                    }
                }
            }
        }
    }

    /// One detail row.
    ///
    /// ── MAPPING: THE CONTROL SITS BY WHAT IT AFFECTS ────────────────────────────
    /// Three things live on this row and each has one job. The glyph names the KIND of
    /// value. The label/value pair IS the value, and tapping it copies — the most common
    /// thing anyone wants from a number on a screen. The trailing button is that value's
    /// own action: a number calls, a handle messages.
    ///
    /// ── HIERARCHY: THE VALUE IS THE CONTENT ─────────────────────────────────────
    /// The value is 15pt medium in primary ink; its label is 13pt secondary ABOVE it. That
    /// order matters — reading down, you meet the category then the thing, which is how a
    /// form reads. Reversing it makes the label the headline of a row whose subject is the
    /// number.
    ///
    /// ── FEEDBACK ON THE CAUSAL EVENT ────────────────────────────────────────────
    /// Copy fires a success haptic and a toast naming what was copied, on the same frame as
    /// the tap. A copy with no feedback is indistinguishable from a tap that missed.
    private func detailRow(icon: String, label: String, value: String,
                           trailingIcon: String, trailingLabel: String,
                           trailingAction: @escaping () -> Void) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(VoiidColor.accentInk)
                // A fixed column, so the two rows' text starts at the same x whatever the
                // glyph's own width is.
                .frame(width: 26)

            Button {
                UIPasteboard.general.string = value
                Haptics.success()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    copiedLabel = label
                }
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    withAnimation(.easeOut(duration: 0.25)) { copiedLabel = nil }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(VoiidFont.rounded(13))
                        .foregroundColor(VoiidColor.textSecondary)
                    Text(value)
                        .font(VoiidFont.rounded(15, .medium))
                        .foregroundColor(VoiidColor.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        // Numbers align down the card whatever digits they contain.
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            // Presses on TOUCH-DOWN. `.plain` gives no feedback at all, so a copyable value
            // read as inert text and nobody discovered it was tappable.
            .buttonStyle(SoftPressStyle())
            .accessibilityLabel("\(label), \(value)")
            .accessibilityHint("Copies to the clipboard")

            Button {
                Haptics.tap()
                trailingAction()
            } label: {
                Image(systemName: trailingIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(VoiidColor.accentInk)
                    // A TINTED DISC, not a bare glyph. Floating ink beside text reads as
                    // decoration; a filled shape reads as a control, which is what tells
                    // someone this row has a second, different action.
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(VoiidColor.accent.opacity(0.12)))
                    // 44pt of target around a 34pt disc.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SoftPressStyle())
            .accessibilityLabel(trailingLabel)
        }
        .padding(.vertical, 8)
    }

    private var seeAllCallsButton: some View {
        Button {
            Haptics.tap()
            showAllCalls = true
        } label: {
            Text("See all")
                .font(VoiidFont.rounded(13, .medium))
                .foregroundColor(VoiidColor.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var callHistoryCard: some View {
        // Hidden entirely when there are none: an empty "Calls" card on a contact you have
        // only ever texted is an affordance to nothing.
        if !recentCalls.isEmpty {
            // "See all" only when there IS more — an accessory that reveals nothing is worse
            // than none, and the count tells you whether it is worth the tap.
            card("Calls", accessory: allCalls.count > recentCalls.count
                 ? AnyView(seeAllCallsButton) : nil) {
                ForEach(Array(recentCalls.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Divider().background(VoiidColor.divider.opacity(0.4))
                    }
                    callRow(entry)
                }
            }
        }
    }

    private func callRow(_ entry: LocalStore.CallHistoryEntry) -> some View {
        let incoming = entry.direction == "incoming"
        let missed = incoming && entry.outcome != "answered"
        return HStack(spacing: VoiidSpacing.md) {
            // Same arrow language as the transcript bubble, so the two surfaces teach the
            // same vocabulary rather than each inventing one.
            Image(systemName: missed ? "phone.arrow.down.left"
                                     : (incoming ? "arrow.down.left" : "arrow.up.right"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(missed ? VoiidColor.error : VoiidColor.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(callTitle(entry))
                    .font(VoiidFont.rounded(15, .regular))
                    .foregroundStyle(missed ? VoiidColor.error : VoiidColor.textPrimary)
                Text(entry.startedAt, style: .date)
                    .font(VoiidFont.rounded(11, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
            }
            Spacer()
            Image(systemName: entry.kind == "video" ? "video.fill" : "phone.fill")
                .font(.system(size: 12))
                .foregroundStyle(VoiidColor.placeholder)
        }
        .padding(.vertical, 3)
    }

    private func callTitle(_ entry: LocalStore.CallHistoryEntry) -> String {
        let incoming = entry.direction == "incoming"
        switch entry.outcome {
        case "answered":
            guard let ended = entry.endedAt else { return incoming ? "Incoming" : "Outgoing" }
            let secs = max(0, Int(ended.timeIntervalSince(entry.startedAt)))
            let mins = secs / 60
            let duration = mins >= 60
                ? String(format: "%d:%02d:%02d", mins / 60, mins % 60, secs % 60)
                : String(format: "%d:%02d", mins, secs % 60)
            return (incoming ? "Incoming · " : "Outgoing · ") + duration
        case "declined": return incoming ? "Declined" : "Call declined"
        case "failed":   return "Call failed"
        default:         return incoming ? "Missed" : "No answer"
        }
    }

    /// Encryption, and the way to check it.
    ///
    /// A claim of end-to-end encryption that the user cannot verify is a claim they have to
    /// take on faith. This row is what turns it into something checkable — and it sits above
    /// mute and block because it is the more consequential fact about the conversation.
    private var encryptionCard: some View {
        card("Encryption") {
            Button {
                Haptics.tap(); showSafetyNumber = true
            } label: {
                HStack(spacing: VoiidSpacing.md) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(VoiidColor.success)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("End-to-end encrypted")
                            .font(VoiidFont.rounded(16, .regular))
                            .foregroundStyle(VoiidColor.textPrimary)
                        Text("Tap to verify with a safety number")
                            .font(VoiidFont.rounded(12, .regular))
                            .foregroundStyle(VoiidColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VoiidColor.placeholder)
                }
                .padding(.vertical, 2)
            }
            // SoftPressStyle, not .plain. This row opens the safety-number screen — the
            // anti-MITM verification, the most consequential control on this page — and it
            // reacted to a press with nothing at all until the finger lifted.
            .buttonStyle(SoftPressStyle(scale: 0.98))
        }
    }

    /// Mute, with real durations and real effect.
    ///
    /// ── WHAT THIS REPLACED ──────────────────────────────────────────────────────
    /// A `Toggle` bound to `@State private var muted` — local view state, written nowhere.
    /// It reset to off every time the screen opened and silenced precisely nothing. The
    /// control existed, looked correct, and was decoration.
    ///
    /// ── WHY A MENU AND NOT A SWITCH ─────────────────────────────────────────────
    /// "Mute" is not a binary anyone actually means. Silencing a group for the afternoon
    /// and silencing it permanently are different intentions, and a switch forces the
    /// second when the first is what is usually wanted — so people either never mute, or
    /// mute forever and miss things. The durations make the temporary case reachable.
    ///
    /// A muted conversation still DELIVERS: it lands in Notification Centre and the badge,
    /// without a sound or a banner. Muting means "stop interrupting me", not "hide this".
    private var settingsCard: some View {
        card {
            Menu {
                if isMuted {
                    Button(role: .destructive) { unmute() } label: {
                        Label("Unmute", systemImage: "bell")
                    }
                    Divider()
                }
                ForEach(MuteStore.Duration.allCases) { d in
                    Button { mute(for: d) } label: { Text(d.title) }
                }
            } label: {
                HStack(spacing: VoiidSpacing.md) {
                    Image(systemName: isMuted ? "bell.slash.fill" : "bell")
                        .font(.system(size: 17))
                        .foregroundColor(isMuted ? VoiidColor.primary : VoiidColor.textSecondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notifications")
                            .font(VoiidFont.rounded(16, .regular))
                            .foregroundColor(VoiidColor.textPrimary)
                        // STATES THE CURRENT STATE, and when it ends. "Muted" alone leaves
                        // the user wondering whether it is for an hour or forever.
                        Text(muteSubtitle)
                            .font(VoiidFont.rounded(12))
                            .foregroundColor(VoiidColor.textSecondary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(VoiidColor.placeholder)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var muteSubtitle: String {
        guard isMuted else { return "On" }
        guard let until = MuteStore.mutedUntil(conversation.id) else { return "Muted" }
        return "Muted until \(VoiidDate.relative(until))"
    }

    private func mute(for duration: MuteStore.Duration) {
        Haptics.tap()
        MuteStore.mute(conversation.id, for: duration)
        isMuted = true
    }

    private func unmute() {
        Haptics.tap()
        MuteStore.unmute(conversation.id)
        isMuted = false
    }

    /// Block is live (043_user_blocks + /blocks, enforced server-side across messages,
    /// calls, profile, presence, conversation creation, group invites, stories and typing).
    /// The row flips to Unblock when this person is already blocked, so the one control
    /// carries both directions rather than hiding the way back.
    ///
    /// Report is live too: the confirmation establishes intent and ReportSheet collects the
    /// reason. The route and table (035_reports) had shipped with no client on either
    /// platform — Android even had a finished sheet that was reachable from nowhere.
    ///
    /// Destructive actions sit LAST and unlabelled — no "DANGER" header shouting at a screen
    /// you opened to see someone's photo. The red carries it, and the confirmation catches
    /// the mistake.
    private var dangerCard: some View {
        card {
            // CLEAR CHAT LIVES HERE NOW, not in a toolbar overflow menu. It is a destructive
            // action on the CONVERSATION, and this card is already where the conversation's
            // destructive actions live — putting it beside Block and Report means one place
            // to look rather than two, and the chat toolbar loses its last reason to carry an
            // ellipsis.
            actionRow("trash.fill", "Clear chat") { showClearChatConfirm = true }
            Divider().background(VoiidColor.divider.opacity(0.4))
            actionRow(isBlocked ? "hand.raised.slash.fill" : "hand.raised.fill",
                      isBlocked ? "Unblock \(displayName)" : "Block \(displayName)") {
                showBlockConfirm = true
            }
            Divider().background(VoiidColor.divider.opacity(0.4))
            actionRow("exclamationmark.bubble.fill", "Report \(displayName)") { showReportConfirm = true }
        }
    }

    // MARK: blocking

    /// Whether THIS account has blocked the peer. Answers from BlockService's cache, which
    /// is why the profile does not need its own fetch or its own loading state.
    ///
    /// Deliberately cannot answer the reverse — whether the peer blocked US. There is no
    /// route for that and there must not be: a blocked person being able to detect the
    /// block defeats the point of blocking silently.
    private var isBlocked: Bool {
        guard let peerId = conversation.peerUserId else { return false }
        return blocks.isBlocked(peerId)
    }

    /// Block or unblock, whichever the current state calls for.
    ///
    /// On failure the service has already rolled its optimistic change back, so the row
    /// returns to its previous label on its own; this only has to say what happened. A
    /// silent failure here is the dangerous case — someone believing they are protected
    /// when they are not.
    private func toggleBlock() {
        guard let peerId = conversation.peerUserId else {
            blockFailure = "This conversation has no contact to block."
            return
        }
        let wasBlocked = isBlocked
        Task {
            let ok = wasBlocked
                ? await blocks.unblock(userId: peerId)
                : await blocks.block(userId: peerId,
                                     displayName: displayName,
                                     username: profile?.username,
                                     photoURL: profile?.photoURL)
            if !ok {
                blockFailure = wasBlocked
                    ? "Check your connection and try again. \(displayName) is still blocked."
                    : "Check your connection and try again. \(displayName) has not been blocked."
            }
        }
    }

    // MARK: data

    /// Load the peer's public profile (name, about, username, photo). Phone is not
    /// fetched — the backend doesn't expose it on the profile endpoint (privacy).
    /// Load the peer's public profile.
    ///
    /// THE OLD VERSION FAILED SILENTLY, THREE WAYS. `guard let peerId ... else { return }`
    /// returned with no state change; `try?` swallowed every network and decode error; and
    /// `profile` starting nil is indistinguishable from a load that never finished. All
    /// three produced the same thing on screen: a profile with nothing on it, no spinner, no
    /// message, and no way to retry. Each is now a distinct, visible state.
    private func loadProfile() async {
        guard let peerId = conversation.peerUserId else {
            // No peer id at all — the conversation row never resolved one. Real, and not the
            // user's fault, so it says so rather than rendering a blank page forever.
            loadState = .failed
            return
        }

        loadState = .loading
        do {
            let p = try await ChatService.shared.userProfile(userId: peerId)
            profile = p
            loadState = .loaded
            // Cache what the server told us, so the next visit (and every call from this
            // person) can name them with no network at all.
            UserDirectory.shared.upsertFromServer(userId: peerId, fullName: p.name,
                                                  username: p.username, photoURL: p.photoURL)
        } catch {
            // A cached name/photo is still worth showing — the header renders from the
            // directory, so a failed fetch degrades to "less detail" rather than "nothing".
            loadState = .failed
            NSLog("[VOIID] profile load failed for \(peerId): \(error.localizedDescription)")
        }
    }

    // MARK: helpers
    /// A grouped surface, optionally titled.
    ///
    /// The TITLE SITS OUTSIDE the card, in caps at 12pt — the iOS grouped-list idiom. It was
    /// inside, at 15pt semibold, which made every card open with a line of text the same
    /// weight as its content; six of those stacked gave the page no hierarchy at all. Outside
    /// and quieter, the eye skips titles to find a section and reads content within it.
    private func card<Content: View>(
        _ title: String? = nil,
        accessory: AnyView? = nil,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            if title != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline, spacing: VoiidSpacing.sm) {
                    if let title {
                        Text(title.uppercased())
                            .font(VoiidFont.rounded(12, .semibold))
                            // Caps need positive tracking to stay legible; this is the same
                            // treatment Apple uses on grouped section headers.
                            .kerning(0.6)
                            .foregroundColor(VoiidColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                    accessory
                }
                .padding(.horizontal, VoiidSpacing.xs)
            }
            VStack(alignment: .leading, spacing: VoiidSpacing.md) { content() }
                .padding(VoiidSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()
        }
    }

    private func actionRow(_ icon: String, _ text: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: { Haptics.rigid(); tap() }) {
            HStack(spacing: VoiidSpacing.md) {
                Image(systemName: icon).font(.system(size: 17)).foregroundColor(VoiidColor.error).frame(width: 24)
                Text(text).font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.error)
                Spacer()
            }.padding(.vertical, 4)
        }
        // A 44pt destructive row that does not move under the finger reads as disabled. The
        // rigid haptic on the ACTION stays alongside the press haptic: one says "I felt
        // that", the other says "this is serious". Same deliberate exception as end-call.
        .buttonStyle(SoftPressStyle(scale: 0.98))
    }
}

// MARK: - Glass card

extension View {
    /// A translucent card in the system material.
    ///
    /// `.regularMaterial`, NOT a flat `surfaceCard` fill. Material samples and blurs what is
    /// behind it, so the cards pick up the portrait's colour as you scroll them over it —
    /// the page reads as one continuous surface instead of opaque tiles sliding across a
    /// photo. It is also the language the rest of the OS speaks in 2026, and the app already
    /// uses it on the map and AI chrome.
    ///
    /// NOT `.glassEffect`: that is iOS 26-only and this project targets iOS 18, so it would
    /// have to be availability-gated and would leave older devices with a flat fallback that
    /// looks nothing like the design. Material gets the same result everywhere.
    ///
    /// THE HAIRLINE IS WHAT MAKES IT READ AS GLASS. Without a lit top edge a blurred
    /// rectangle just looks like a washed-out fill; the 1px white-to-transparent stroke is
    /// the specular highlight that says "this has a surface". The shadow is deliberately
    /// soft and low-opacity — enough to lift the card off the ground, not enough to look
    /// like a dropped box.
    /// Apply [glassCard] only when `condition` holds, so a caller can switch between a solid
    /// and a glass treatment without duplicating the whole view.
    @ViewBuilder
    func glassIfNeeded(_ condition: Bool, cornerRadius: CGFloat = 20) -> some View {
        if condition { glassCard(cornerRadius: cornerRadius) } else { self }
    }

    /// A card: flat `surfaceCard` with a hairline — the reference's treatment.
    ///
    /// ── WHY THE GLASS IS GONE ───────────────────────────────────────────────────
    /// The material version existed to solve a problem that no longer exists. The page used
    /// to sit on a tinted wash, `.regularMaterial` blurs toward neutral grey, and the two
    /// read as different colour families — grey slabs on a coloured page. Every part of that
    /// card (the material, the 0.06 primary tint pulling it back into the page's hue, the
    /// white gradient hairline, the drop shadow) was compensation for the wash.
    ///
    /// With a flat ground there is nothing to blur and nothing to reconcile: a translucent
    /// card over a single flat colour is just a slightly dimmer version of that colour, at
    /// the cost of a blur pass per card. The reference draws these flat, and on a flat
    /// ground that is both simpler and more legible.
    ///
    /// The name is kept so every call site stays untouched.
    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(VoiidColor.surfaceCard, in: shape)
            .overlay(shape.stroke(VoiidColor.divider, lineWidth: 1))
    }
}
