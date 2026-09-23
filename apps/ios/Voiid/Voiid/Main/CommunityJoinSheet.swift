//
//  CommunityJoinSheet.swift
//  Voiid
//
//  What a community invite link opens: the PUBLIC INFO CARD, plus a Join button.
//
//  Port of Android `CommunityJoinSheet.kt`; the two must show the same states, because the same
//  link is going to be opened on both phones by people comparing notes.
//
//  WHY A SHEET AND NOT A SCREEN IN THE COMMUNITIES TAB
//  --------------------------------------------------
//  The link can arrive while the user is anywhere — mid-chat, on the Map, on a cold launch that
//  has not painted a tab yet. A modal is the only presentation that is correct from all of those
//  places, and it means this feature does not have to agree with whatever the Communities tab
//  eventually becomes.
//
//  THE LINK IS NOT AN ANSWER, IT IS A QUESTION
//  -------------------------------------------
//  Everything below the header is what the SERVER said when asked about this handle, with this
//  caller's session attached. Nothing is derived from the fact that a link opened. That is the
//  property that stops a forwarded URL from leaking membership: whoever holds the link gets the
//  same public card a stranger gets, and "are you in this community" is answered — per caller —
//  by `membership_state`, which the server computes from the roster it already owns.
//
//  Nothing here touches E2EE state. Joining inserts server-side membership rows; the MLS Welcome
//  that actually lets this device READ the channels is a separate client-driven step over the
//  existing /mls routes, exactly as group conversations already work.
//

import SwiftUI

struct CommunityJoinSheet: View {
    let link: CommunityLink
    var onScanAgain: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var openCommunity = false
    @State private var card: CommunityService.CommunityCard?
    @State private var joined: String?
    /// The server saying "you were already in" — the join is idempotent, and two devices (or
    /// two taps) must not both claim credit for a membership only one of them created.
    @State private var alreadyIn = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    QRScreenHeading(title: "Community preview", subtitle: "Here’s the community from your QR code or link.")
                    if let card {
                        header(card)
                    } else if let error {
                        failure(error)
                    } else {
                        VStack(spacing: 16) {
                            ProgressView()
                            Text("Looking up @\(link.handle)…")
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundStyle(VoiidColor.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    if let card { outcome(card) }
                    if let onScanAgain {
                        Button("Scan again", action: onScanAgain)
                            .buttonStyle(QRActionButtonStyle(secondary: true))
                            .disabled(busy)
                            .accessibilityIdentifier("scan.again")
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(VoiidColor.background)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { if let onScanAgain { onScanAgain() } else { dismiss() } } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(onScanAgain == nil ? "Close preview" : "Back to scanner")
                    .disabled(busy)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $openCommunity) { CommunityDetailView(handle: link.handle) }
        }
        .tint(VoiidColor.primary)
        .interactiveDismissDisabled(busy)
        .task(id: link.id) { await resolve() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if joined == "pending" || card?.isPending == true { await refreshMembership() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("communityMembershipChanged"))) { note in
            if note.userInfo?["community_id"] as? String == card?.id { Task { await refreshMembership() } }
        }
    }

    private func header(_ card: CommunityService.CommunityCard) -> some View {
        VStack(spacing: 16) {
            QRIdentityAvatar(photoURL: card.avatar_url, name: card.name)
            Text(card.name)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(VoiidColor.textPrimary)
                .multilineTextAlignment(.center)
            InstitutionMark(name: card.institution_name)
            if card.official == true {
                Label("Official", systemImage: "checkmark.seal.fill")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(VoiidColor.accentInk)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(VoiidColor.accentTint, in: Capsule())
            }
            Label(card.policy == "invite_only" ? "Invite-only community" :
                    card.policy == "approval" ? "Approval required" : "Public community",
                  systemImage: card.policy == "invite_only" ? "lock" : "person.3")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(VoiidColor.textSecondary)
            Text("@\(card.handle) · \(Self.memberCount(card.members))")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(VoiidColor.textSecondary)
            Divider().padding(.vertical, 4)
            if let description = card.description, !description.isEmpty {
                Text(description)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Text("Joining doesn’t allow members to message you privately.")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityIdentifier("scan.communityPreview")
    }

    /// The join outcome once there is one, otherwise the button.
    @ViewBuilder
    private func outcome(_ card: CommunityService.CommunityCard) -> some View {
        switch joined ?? card.membership_state ?? "" {
        // 'pending' is a REAL outcome and not an error: an approval-gated community accepted
        // the request and an admin now has to act. Saying "joined" there would be a lie the
        // user discovers later, when no channels appear.
        case "active":
            notice(alreadyIn
                   ? "You’re already a member of this community."
                   : "You’re in. Spaces will become available when their keys sync to this device.")
            secondaryButton("Open community") { openCommunity = true }
        case "pending":
            notice("Request sent. You’ll get in once an admin approves it.")
            secondaryButton("Done") { dismiss() }
        default:
            joinArea(card)
        }
    }

    /// The button, and the sentence explaining what pressing it will actually do.
    ///
    /// Every refusal is stated BEFORE the tap rather than after it. A user who taps Join and
    /// gets an error has learned the same fact one round trip later and one disappointment
    /// worse.
    @ViewBuilder
    private func joinArea(_ card: CommunityService.CommunityCard) -> some View {
        if let blocked = Self.blockedReason(card) {
            notice(blocked)
        } else {
            Button {
                Haptics.rigid()
                Task { await join(card) }
            } label: {
                ZStack {
                    if busy {
                        ProgressView().tint(VoiidColor.textOnPrimary)
                    } else {
                        // "Request to join" is `JoinPolicyOption`'s own label for the
                        // approval tier, quoted deliberately: the sentence a visitor taps
                        // must be the one the host chose.
                        Text(card.policy == "approval" ? "Request to join" : "Join community")
                            .font(VoiidFont.rounded(16, .semibold))
                            .foregroundStyle(VoiidColor.textOnPrimary)
                    }
                }
            }
            // Not merely greyed out: an enabled-looking button that fires a second join is how
            // a max_uses invite gets spent twice by one impatient person.
            .buttonStyle(QRActionButtonStyle())
            .disabled(busy)
            .opacity(busy ? 0.65 : 1)
            .accessibilityIdentifier("scan.joinCommunity")

            Text(Self.policyBlurb(card))
                .font(VoiidFont.rounded(12))
                .foregroundStyle(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)

            if let error {
                Text(error)
                    .font(VoiidFont.rounded(13))
                    .foregroundStyle(VoiidColor.error)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private func failure(_ message: String) -> some View {
        Text("Can’t open this link")
            .font(VoiidFont.rounded(20, .semibold))
            .foregroundStyle(VoiidColor.textPrimary)
        Text(message)
            .font(VoiidFont.rounded(14))
            .foregroundStyle(VoiidColor.textSecondary)
            .multilineTextAlignment(.center)
        Button("Try again") { Task { await resolve() } }
            .buttonStyle(QRActionButtonStyle(secondary: true))
    }

    /// Flat informational block — an outcome or a refusal, never an action.
    private func notice(_ text: String) -> some View {
        Text(text)
            .font(VoiidFont.rounded(14))
            .foregroundStyle(VoiidColor.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(VoiidSpacing.md)
            .background(VoiidColor.fieldFill, in: RoundedRectangle(cornerRadius: VoiidRadius.lg))
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(QRActionButtonStyle(secondary: true))
    }

    // MARK: - Actions

    private func refreshMembership() async {
        guard !busy else { return }
        do {
            let updated = try await CommunityService.shared.resolve(link)
            guard !Task.isCancelled else { return }
            card = updated
            joined = updated.membership_state
        } catch { /* Keep the last server state; the next poll or reopen retries. */ }
    }

    private func resolve() async {
        error = nil
        card = nil
        joined = nil
        alreadyIn = false
        do {
            let resolved = try await CommunityService.shared.resolve(link)
            guard !Task.isCancelled else { return }
            card = resolved
        } catch {
            guard !Task.isCancelled else { return }
            self.error = Self.message(for: error, handle: link.handle)
        }
    }

    private func join(_ card: CommunityService.CommunityCard) async {
        guard !busy else { return }
        busy = true
        error = nil
        do {
            // The id comes from the RESOLVED CARD, never from the URL. Handles can be released
            // and re-registered (030_communities.sql keeps them in one pool with usernames and
            // creator handles), so redeeming against the id the server just handed us is what
            // stops a stale poster from enrolling someone into whatever community inherited
            // the handle.
            let result = try await CommunityService.shared.join(communityId: card.id,
                                                                inviteToken: link.inviteToken)
            joined = result.state
            alreadyIn = result.existed
            Haptics.success()
        } catch {
            self.error = Self.message(for: error, handle: link.handle)
        }
        busy = false
    }

    // MARK: - Copy

    /// "1 member" / "482 members" — plural handled rather than "1 members".
    private static func memberCount(_ n: Int) -> String { n == 1 ? "1 member" : "\(n) members" }

    private static func policyBlurb(_ card: CommunityService.CommunityCard) -> String {
        // A dead token on a community that does not require one. Said out loud, because the
        // user is about to succeed with a link they were told is broken, and silence here reads
        // as the app ignoring the part of the URL they were given.
        if card.invite_valid == false { return "\(deadInvite) You can still join this community without one." }
        switch card.policy {
        // Said plainly because it is the surprising one: nothing happens immediately.
        case "approval": return "An admin reviews requests before you’re let in."
        case "invite_only": return "You’re joining with an invite link. Links can be revoked or expire."
        default: return "Anyone with the link can join."
        }
    }

    /// Why the Join button must NOT be drawn, or nil if it may be.
    ///
    /// One switch over `CommunityMembership`, the same value the community card and the
    /// Communities list read — so a link that opens on "You’re already a member" cannot lead
    /// to a card offering Join.
    ///
    /// `.none` covers never-joined AND `left`, which is also where a DECLINED request lands:
    /// rejecting an applicant sets their row to `left` because the schema has no `declined`
    /// state, so the honest thing to show them is the join button again.
    private static func blockedReason(_ card: CommunityService.CommunityCard) -> String? {
        switch card.membership {
        case .suspended: return "This community is suspended and can’t be joined."
        case .banned:    return "You can’t rejoin this community."
        case .joined:    return "You’re already a member."
        case .requested: return "Your request is waiting for an admin to approve it."
        case .none:
            // A dead token is only FATAL for invite_only — an open or approval community is
            // joinable without one, so a stale poster still works and `policyBlurb` is where
            // the expired link gets mentioned.
            if card.policy == "invite_only", card.invite_valid != true { return deadInvite }
            return nil
        }
    }

    /// ONE sentence for every way an invite can be dead, because the server gives one answer for
    /// all of them on purpose: revoked, expired, used up and never-existed all come back as the
    /// same 404, since an endpoint that distinguished them would be an oracle for guessing
    /// tokens. The user's next move is identical in every case anyway — ask for a new link.
    private static let deadInvite =
        "This invite link isn’t valid any more — ask the host for a new one."

    /// Server errors, turned into something worth reading.
    ///
    /// A 404 deliberately reads as "no such community" and NOT as "you're not allowed to see
    /// it". The server returns the same 404 for a community that does not exist and one the
    /// caller may not see, and the client must not invent a distinction the server was careful
    /// not to make — that distinction is itself the membership leak.
    private static func message(for error: Error, handle: String) -> String {
        guard let api = error as? APIError else {
            return "Couldn’t reach Voiid. Check your connection and try again."
        }
        switch api {
        case .http(404, _, _): return "No community called @\(handle)."
        case .http(let status, let message, _):
            return message.isEmpty ? "Request failed (\(status))." : message
        case .notAuthenticated: return "Sign in to open this link."
        case .alreadySent: return "Already sent."
        case .transport: return "Couldn’t reach Voiid. Check your connection and try again."
        case .decoding: return "Unexpected server response."
        }
    }
}
