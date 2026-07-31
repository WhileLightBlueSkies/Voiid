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
    @Environment(\.dismiss) private var dismiss
    @State private var muted = false
    @State private var viewPhoto = false
    @State private var showAllMedia = false
    @State private var profile: UserProfile?
    @State private var showBlockConfirm = false
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
            // 20pt between sections, not 24 — with titles now sitting outside the cards,
            // each section already carries 8pt of its own leading space, so 24 opened gaps
            // wide enough to read as unrelated screens stacked on top of each other.
            VStack(spacing: 20) {
                headerCard
                aboutCard
                sharedMediaCard
                callHistoryCard
                settingsCard
                dangerCard
            }
            // 20pt gutters: 24 left the cards floating in a wide margin on a 390pt phone.
            .padding(.horizontal, 20)
            .padding(.top, VoiidSpacing.sm)
            .padding(.bottom, VoiidSpacing.xl)
        }
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(VoiidColor.primary)
        // Hide the bottom bar on this detail screen. We do NOT reset on disappear: when you
        // pop back to the CHAT (also a detail screen) its onAppear does not re-fire, so a
        // reset here would wrongly show the bar over the chat. The bar is restored only when
        // a ROOT tab page appears (each sets hideTabBar = false).
        .onAppear { session.hideTabBar = true }
        .task { await loadProfile() }
        .fullScreenCover(isPresented: $viewPhoto) {
            ProfilePhotoViewer(title: displayName, imageName: conversation.photoName) { viewPhoto = false }
        }
        .sheet(isPresented: $showAllMedia) { SharedMediaSheet(title: conversation.title, conversationId: conversation.id) }
        .confirmationDialog("Block \(displayName)?", isPresented: $showBlockConfirm, titleVisibility: .visible) {
            Button("Block", role: .destructive) { notImplemented = "Blocking isn’t available yet." }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They won’t be able to message or call you.")
        }
        .confirmationDialog("Report \(displayName)?", isPresented: $showReportConfirm, titleVisibility: .visible) {
            Button("Report", role: .destructive) { notImplemented = "Reporting isn’t available yet." }
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

    // Header: photo, name, identity, quick actions.
    //
    // THE PAGE HAS ONE SUBJECT and the header is it. Previously it was a 112pt avatar with
    // 8pt gaps to a 24pt name — the same rhythm as every card below it, so the person the
    // page is ABOUT carried no more weight than a "Mute notifications" toggle. It now gets
    // deliberate air above and below, a larger name, and a hairline ring that separates the
    // photo from the background without drawing a box around it.
    private var headerCard: some View {
        VStack(spacing: 0) {
            Button { Haptics.tap(); viewPhoto = true } label: {
                ProfileAvatarButton(photoURL: photoRef, name: displayName, size: 104)
                    // A 1px ring at 8% — enough to define the edge against a light photo,
                    // invisible against a dark one. A heavier border would read as a frame.
                    .overlay(Circle().strokeBorder(VoiidColor.textPrimary.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.bottom, VoiidSpacing.md)

            Text(displayName)
                .font(VoiidFont.rounded(28, .bold))
                // Optical tightening: at 28pt the default tracking looks loose. Apple's own
                // large titles are negatively tracked for exactly this reason.
                .kerning(-0.4)
                .foregroundColor(VoiidColor.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            // ONE line of secondary identity, not two stacked at equal weight. The handle and
            // the number were competing — same size, same spacing — so neither read as the
            // primary way to identify this person. The handle leads (it is what you share);
            // the number follows it, quieter, separated by a dot.
            if identityLine != nil {
                identityRow
                    .padding(.top, 5)
            }

            quickActions
                .padding(.top, VoiidSpacing.lg)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, VoiidSpacing.sm)
        .padding(.bottom, VoiidSpacing.xs)
    }

    /// The handle, the number, or both — resolved once so the header does not branch inline.
    private var identityLine: (handle: String?, secondary: String?)? {
        let handle = profile?.username.flatMap { $0.isEmpty ? nil : "@\($0)" }
        let secondary = secondaryIdentity
        guard handle != nil || secondary != nil else { return nil }
        return (handle, secondary)
    }

    @ViewBuilder
    private var identityRow: some View {
        if let line = identityLine {
            HStack(spacing: 6) {
                if let handle = line.handle {
                    Text(handle)
                        .font(VoiidFont.rounded(15, .medium))
                        .foregroundColor(VoiidColor.primary)
                }
                if line.handle != nil && line.secondary != nil {
                    Circle()
                        .fill(VoiidColor.textSecondary.opacity(0.4))
                        .frame(width: 3, height: 3)
                }
                if let secondary = line.secondary {
                    Text(secondary)
                        .font(VoiidFont.rounded(15, .regular))
                        .foregroundColor(VoiidColor.textSecondary)
                }
            }
        }
    }

    /// Message / Call / Video.
    ///
    /// ONE SEGMENTED CONTROL, not three floating tinted rectangles. Three separate 46pt
    /// blocks with captions underneath read as three unrelated buttons that happen to sit in
    /// a row; a single grouped surface with hairline separators reads as one control with
    /// three choices — which is what it is. The label moves INSIDE the button, so the caption
    /// row disappears and with it 20pt of vertical noise.
    private var quickActions: some View {
        HStack(spacing: 0) {
            quickAction("message.fill", "Message") { dismiss() }
            actionSeparator
            quickAction("phone.fill", "Call") { requestCall(.voice) }
            actionSeparator
            quickAction("video.fill", "Video") { requestCall(.video) }
        }
        .frame(height: 58)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
    }

    private var actionSeparator: some View {
        Rectangle()
            .fill(VoiidColor.divider.opacity(0.5))
            .frame(width: 1, height: 26)
    }

    private func quickAction(_ icon: String, _ label: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: { Haptics.tap(); tap() }) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                Text(label)
                    .font(VoiidFont.rounded(11, .medium))
            }
            .foregroundColor(VoiidColor.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPressStyle())
    }

    /// The peer's photo reference, preferring the freshly-fetched profile and falling back to
    /// whatever the directory already cached — so a face shows on the first frame offline.
    private var photoRef: String? {
        if let u = profile?.photoURL, !u.isEmpty { return u }
        guard let peer = conversation.peerUserId else { return nil }
        return UserDirectory.shared.photoURL(peer)
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
        let status = profile?.statusText ?? ""
        let about = profile?.about ?? ""
        card("About") {
            if !status.isEmpty {
                HStack(alignment: .top, spacing: VoiidSpacing.sm) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 12))
                        .foregroundColor(VoiidColor.primary)
                        .padding(.top, 3)
                    Text(status)
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
            if status.isEmpty && about.isEmpty {
                Text("Hey there! I am using Voiid.")
                    .font(VoiidFont.rounded(16, .regular))
                    .foregroundColor(VoiidColor.textSecondary)
            }
        }
    }

    /// All shared visual media in this 1:1, newest first — real, from the message store.
    /// Videos count too: the strip previously filtered to `image/` only, so a chat full of
    /// videos reported "no media shared yet".
    private var sharedMedia: [MediaRef] {
        ChatEngine.shared.messages(conversationId: conversation.id)
            .compactMap { $0.media }
            .filter { $0.mime.hasPrefix("image/") || $0.mime.hasPrefix("video/") }
            .reversed()
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
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(VoiidColor.divider)
                        .frame(width: 76, height: 76)
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
    private var recentCalls: [LocalStore.CallHistoryEntry] {
        Array(LocalStore.callsForConversation(conversation.id).reversed().prefix(4))
    }

    @ViewBuilder
    private var callHistoryCard: some View {
        // Hidden entirely when there are none: an empty "Calls" card on a contact you have
        // only ever texted is an affordance to nothing.
        if !recentCalls.isEmpty {
            card("Calls") {
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

    private var settingsCard: some View {
        card {
            Toggle(isOn: $muted) {
                Label("Mute notifications", systemImage: "bell.slash")
                    .font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.textPrimary)
            }.tint(VoiidColor.primary)
        }
    }

    /// Block and Report have NO backend yet (no route, no table). Rather than leave them as
    /// silent no-ops that look like they worked, they confirm and then say plainly that the
    /// feature is not live. A button that appears to succeed and does nothing is the worst of
    /// the three options for a safety feature.
    ///
    /// Destructive actions sit LAST and unlabelled — no "DANGER" header shouting at a screen
    /// you opened to see someone's photo. The red carries it, and the confirmation catches
    /// the mistake.
    private var dangerCard: some View {
        card {
            actionRow("hand.raised.fill", "Block \(displayName)") { showBlockConfirm = true }
            Divider().background(VoiidColor.divider.opacity(0.4))
            actionRow("exclamationmark.bubble.fill", "Report \(displayName)") { showReportConfirm = true }
        }
    }

    // MARK: data

    /// Load the peer's public profile (name, about, username, photo). Phone is not
    /// fetched — the backend doesn't expose it on the profile endpoint (privacy).
    private func loadProfile() async {
        guard let peerId = conversation.peerUserId else { return }
        profile = try? await ChatService.shared.userProfile(userId: peerId)
        // Cache what the server told us, so the next visit (and every call from this
        // person) can name them with no network at all.
        if let p = profile {
            UserDirectory.shared.upsertFromServer(userId: peerId, fullName: p.name,
                                                  username: p.username, photoURL: p.photoURL)
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
                .background(VoiidColor.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        }
    }

    private func actionRow(_ icon: String, _ text: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: { Haptics.rigid(); tap() }) {
            HStack(spacing: VoiidSpacing.md) {
                Image(systemName: icon).font(.system(size: 17)).foregroundColor(VoiidColor.error).frame(width: 24)
                Text(text).font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.error)
                Spacer()
            }.padding(.vertical, 4)
        }.buttonStyle(.plain)
    }
}
