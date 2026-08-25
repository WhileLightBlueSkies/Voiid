//
//  CommunitySettingsView.swift
//  Voiid
//
//  The screen a host uses to control who can FIND and who can JOIN their community, plus the
//  rules those people agree to on the way in.
//
//  ── WHY THIS DID NOT EXIST UNTIL NOW ────────────────────────────────────────────
//  `PATCH /communities/:id` has been on the server since 030 and `CommunityService` had no
//  method for it, so a community was immutable after creation: a host who mistyped the name,
//  or wanted to close an open community, or realised their rules were wrong, had no way to
//  change any of it. Two of the seven fields (`category`, `members_can_invite`, both 046) were
//  additionally unreachable through the route itself, and `community_rules` had an INSERT at
//  creation and no read path at all — which is why the About tab rendered `CommunityRule.
//  samples`, showing four invented rules to real members as though the host had written them.
//
//  ── THE GATE IS THE SERVER'S, NOT THIS SCREEN'S ─────────────────────────────────
//  Every route this screen touches is `requireManager` — an ACTIVE owner or an ACTIVE admin of
//  a live community, checked against `communities.owner_id` and the roster row together. The
//  `isOwner` test that decides whether the entry point is drawn in `CommunityDetailView` is
//  CONVENIENCE ONLY: it stops a member being shown a door that would refuse them. It is not
//  enforcement, it cannot be, and a build that got it wrong would produce a 403 rather than an
//  unauthorised write. The one read here — `GET /:id/rules` — is deliberately WIDER than
//  manager (the server uses the same `readGate` as the feed), because someone deciding whether
//  to join needs to see the terms of joining first.
//
//  ── NOT E2EE, AND THAT IS THE POINT ─────────────────────────────────────────────
//  Every value on this screen is SERVER-READABLE by design, and has to be: the server matches
//  searches against the name, gates joins on the policy, and shows the card to strangers who
//  hold no key. 030's header makes this argument in full. Channel messages (MLS) and the
//  member↔host DM stay encrypted and share no code path with anything here.
//
//  ── NO AVATAR EDITING, DELIBERATELY ─────────────────────────────────────────────
//  `PATCH /communities/:id` accepts `avatar_r2_key`, and this screen does not offer it. The
//  column holds an OPAQUE R2 KEY, and nothing in this app produces one a community card can
//  render back: `POST /media/presign-upload` returns a key that needs a per-caller
//  `presign-download` round trip to become viewable, and `POST /clips/presign-upload` mints a
//  clip, which is a different kind of object addressed a different way. A picker wired to
//  either would let a host choose a photo, report success, and leave every viewer — themselves
//  included — looking at a broken image. The same reasoning `CommunityPostComposer` gives for
//  having no media field. When a presign that returns a durable readable URL exists,
//  `update(avatar:)` is a one-line addition and this is the only view that changes.
//
//  ── SAVING IS EXPLICIT, AND A FAILURE SAYS SO ───────────────────────────────────
//  The text fields and toggles edit a local draft; nothing is written until Save. That is not
//  timidity about round trips — it is that `join_policy` and `members_can_invite` INTERACT
//  server-side (see below), so a per-control autosave would fire two writes for one decision
//  and leave the screen briefly showing a state the server had already overridden.
//
//  A failed save NEVER redraws as saved. The draft keeps what the user typed, an error banner
//  names the failure, and the last known-good card is what the read-only rows fall back to —
//  so the screen is either truthful about the server or truthful about being unsaved, and
//  never quietly wrong about both.
//

import SwiftUI

// MARK: - Limits and options

/// The server's ceilings, named after the constraints that own them — the same discipline
/// `CommunityWriteLimits` follows in CommunityAuthoring.swift. A client limit looser than the
/// column's turns a typo into a 500; one tighter silently forbids what the product allows.
private enum CommunitySettingsLimits {
    /// communities_name_len / MAX_NAME in the route.
    static let name = 60
    /// communities_description_len / MAX_DESCRIPTION.
    static let description = 500
    /// The route's `trimmed(body.category, 40)`. No CHECK constraint — 046 made the column
    /// free text on purpose, because a category list changes more often than a schema should.
    static let category = 40
    /// community_rules_title_len: `between 1 and 120`.
    static let ruleTitle = 120
    /// community_rules_detail_len: `<= 400`, nullable.
    static let ruleDetail = 400
    /// MAX_RULES_PER_COMMUNITY in the route.
    static let rules = 20
}

/// The same six the create wizard offers (`CommunityCreateFlow`), so a host does not see one
/// set of categories at creation and a different set here.
///
/// The column is FREE TEXT and the server accepts any string, so this list is a convenience
/// and not a validation: a community whose category came from an older build, or from another
/// client, keeps it and is shown it. `custom` below is what carries that case.
private let communityCategories = ["Design", "Tech", "Gaming", "Music", "Sport", "Local"]

/// The three real values of `communities.join_policy`, with the copy already used by
/// `CommunityDetailView.visibilityText` and `CommunityAboutTab.policyText`.
///
/// The short label is quoted from those two verbatim so the wording cannot drift — a host
/// choosing "Approval needed" here must read the same words a visitor reads on the card. The
/// longer line is this screen's own, because a picker is where the choice is actually made and
/// three words are not enough to make it.
private struct JoinPolicyOption: Identifiable {
    let id: String
    let label: String
    let explanation: String
    let icon: String

    static let all: [JoinPolicyOption] = [
        .init(id: "open", label: "Anyone can join",
              explanation: "Anyone who finds this community joins instantly.",
              icon: "globe"),
        .init(id: "approval", label: "Approval needed",
              explanation: "People ask to join and you review each request.",
              icon: "checkmark.shield"),
        .init(id: "invite_only", label: "Invite only",
              explanation: "The only way in is an invite link or an invite from a member.",
              icon: "lock.fill"),
    ]

    /// Never force-unwrapped and never exhaustively switched: `join_policy` is a string column
    /// and a server that grew a fourth value must not crash a build that knows three.
    static func find(_ id: String) -> JoinPolicyOption? { all.first { $0.id == id } }
}

// MARK: - Screen

@MainActor
struct CommunitySettingsView: View {
    /// The card this screen opened on. The source of truth until a save returns a new one —
    /// held as state rather than a `let` so a successful write updates the screen from the
    /// SERVER'S answer rather than from what was sent.
    @State private var card: CommunityService.CommunityCard

    /// Handed back to the presenting screen after every successful save, so the community
    /// detail view behind this sheet redraws with the new name and policy rather than the
    /// values it loaded before the host changed them.
    private let onSaved: (CommunityService.CommunityCard) -> Void

    @Environment(\.dismiss) private var dismiss

    // ── The draft ────────────────────────────────────────────────────────────────
    // Edited freely; written only on Save. Seeded from the card in `init` and re-seeded from
    // the server's answer after each successful write.
    @State private var name: String
    @State private var about: String
    @State private var discoverable: Bool
    @State private var joinPolicy: String
    @State private var category: String
    @State private var membersCanInvite: Bool

    @State private var saving = false
    /// Non-nil ONLY after a write actually failed. Distinct from the rules list's own error:
    /// the two surfaces fail independently and a host must be able to tell which one did.
    @State private var saveFailure: String?
    /// Set on a save that succeeded, cleared the moment the draft changes again. This is the
    /// screen's only "saved" signal and it is driven by the RESPONSE, never by the request.
    @State private var savedAt: Date?

    // ── Rules ────────────────────────────────────────────────────────────────────
    @State private var rules: [CommunityService.Rule] = []
    /// Three distinct states, not two. `loading` is the first fetch, `rulesError` is a real
    /// failure, and neither of them is an empty list — an empty Rules card says the host wrote
    /// none, which is a different fact from "we could not find out".
    @State private var rulesLoading = true
    @State private var rulesError: String?
    /// The rule being edited, or a fresh one being added. Non-nil IS the sheet's presented
    /// state, so the editor can never act on a rule the list has since reloaded away.
    @State private var editingRule: RuleDraft?
    /// The rule awaiting delete confirmation, same reasoning.
    @State private var pendingDelete: CommunityService.Rule?
    /// Rule ids with a write in flight, so a second tap cannot fire a duplicate.
    @State private var ruleBusy: Set<String> = []

    init(card: CommunityService.CommunityCard,
         onSaved: @escaping (CommunityService.CommunityCard) -> Void = { _ in }) {
        _card = State(initialValue: card)
        self.onSaved = onSaved
        _name = State(initialValue: card.name ?? "")
        _about = State(initialValue: card.description ?? "")
        _discoverable = State(initialValue: card.isDiscoverable)
        _joinPolicy = State(initialValue: card.policy)
        _category = State(initialValue: card.category ?? "")
        _membersCanInvite = State(initialValue: card.membersCanInvite)
    }

    // ── The invite-only rule, mirrored from the server ───────────────────────────
    //
    // 046: "an invite-only community where everyone invites is not invite-only". The route
    // forces `members_can_invite` to false whenever the policy LANDS ON invite_only, whether
    // this request moved it there or it was already there.
    //
    // The client shows that rather than silently flipping the toggle: the Invites row disables
    // and reads as off, and the card's footer says WHY. A toggle that flicked itself off with
    // no explanation would look like a bug, and a toggle that stayed on while the server
    // ignored it would be a lie — this is the third option, which is to tell the truth.

    private var inviteOnly: Bool { joinPolicy == "invite_only" }

    /// What the server will actually store, as opposed to what the toggle last held. Every
    /// read of the invite setting on this screen goes through here.
    private var effectiveMembersCanInvite: Bool { inviteOnly ? false : membersCanInvite }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the draft differs from the card the server last confirmed. Save is dark until
    /// something has actually changed, so the button is never a no-op round trip.
    private var dirty: Bool {
        trimmedName != (card.name ?? "")
            || about.trimmingCharacters(in: .whitespacesAndNewlines) != (card.description ?? "")
            || discoverable != card.isDiscoverable
            || joinPolicy != card.policy
            || category.trimmingCharacters(in: .whitespacesAndNewlines) != (card.category ?? "")
            || effectiveMembersCanInvite != card.membersCanInvite
    }

    /// A name of only whitespace is a 400 server-side ("name cannot be empty"), so the button
    /// refuses before the round trip does.
    private var canSave: Bool { dirty && !trimmedName.isEmpty && !saving }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                    VoiidSettingsHeader(
                        "Community settings",
                        subtitle: "Who can find @\(card.handle), who can join it, and what "
                                + "they agree to.")

                    statusBanner

                    identitySection
                    discoverySection
                    joiningSection
                    invitesSection
                    categorySection
                    rulesSection
                }
                .padding(VoiidSpacing.md)
                // Clears the Save button's own bar at the bottom.
                .padding(.bottom, 72)
            }
            .voiidSettingsPage()
            .safeAreaInset(edge: .bottom) { saveBar }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(VoiidColor.textSecondary)
                        // Disabled mid-write: the request cannot be recalled, so dismissing
                        // would leave the host believing nothing was saved while it lands.
                        .disabled(saving)
                }
            }
            .task { await loadRules() }
            .sheet(item: $editingRule) { draft in
                CommunityRuleEditor(draft: draft) { saved, isNew in
                    // The server's row, never a locally built one — it carries the id and the
                    // position that the list orders on.
                    if isNew {
                        rules.append(saved)
                    } else if let i = rules.firstIndex(where: { $0.id == saved.id }) {
                        rules[i] = saved
                    }
                    rules.sort { $0.order < $1.order }
                }
            }
            .alert("Delete this rule?", isPresented: deleteAlertBinding) {
                Button("Cancel", role: .cancel) { pendingDelete = nil }
                Button("Delete", role: .destructive) {
                    if let rule = pendingDelete { Task { await deleteRule(rule) } }
                }
            } message: {
                Text(pendingDelete.map { "\u{201C}\($0.text)\u{201D} will be removed for everyone." }
                     ?? "")
            }
        }
    }

    // MARK: Status

    /// The one place this screen says what happened to the last write.
    ///
    /// A failure outranks a success and both are explicit: there is deliberately no state in
    /// which the screen shows a changed value with no indication of whether it reached the
    /// server. The failure text is `APIError`'s user-facing copy, which already maps a 403
    /// ("only the owner or an admin can do that") to something a person can act on.
    @ViewBuilder
    private var statusBanner: some View {
        if let saveFailure {
            banner(icon: "exclamationmark.triangle.fill", tint: VoiidColor.error,
                   text: saveFailure)
        } else if savedAt != nil {
            banner(icon: "checkmark.circle.fill", tint: VoiidColor.accentInk,
                   text: "Settings saved.")
        }
    }

    private func banner(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: VoiidSpacing.sm) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .foregroundStyle(VoiidColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(VoiidSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .stroke(tint.opacity(0.35), lineWidth: 1))
    }

    // MARK: Identity

    private var identitySection: some View {
        VoiidCardSection(
            "Identity",
            footer: "The handle @\(card.handle) can\u{2019}t be changed \u{2014} every invite "
                  + "link and pasted URL already points at it."
        ) {
            settingsField(icon: "textformat", label: "Name",
                          placeholder: "Community name",
                          text: capped($name, CommunitySettingsLimits.name),
                          limit: CommunitySettingsLimits.name)
            VoiidRowDivider(inset: 0)
            settingsField(icon: "text.alignleft", label: "Description",
                          placeholder: "What this community is for.",
                          text: capped($about, CommunitySettingsLimits.description),
                          limit: CommunitySettingsLimits.description,
                          multiline: true)
        }
    }

    // MARK: Discovery

    private var discoverySection: some View {
        VoiidCardSection(
            "Discovery",
            // Says plainly what the flag DOES, not what it is called. `discoverable` gates the
            // search index only; an invite link resolves either way, which is the half a host
            // most often assumes wrongly.
            footer: discoverable
                ? "This community appears in search to people who aren\u{2019}t members."
                : "This community is hidden from search. People who aren\u{2019}t members can "
                + "only reach it with a link you give them."
        ) {
            VoiidSettingsRow(icon: "magnifyingglass",
                             title: "Show in search",
                             detail: "Let people who aren\u{2019}t members find this community.") {
                Toggle("", isOn: $discoverable)
                    .labelsHidden()
                    .tint(VoiidColor.accent)
                    .accessibilityLabel("Show in search")
            }
        }
    }

    // MARK: Joining

    private var joiningSection: some View {
        VoiidCardSection(
            "Joining",
            footer: JoinPolicyOption.find(joinPolicy)?.explanation
        ) {
            ForEach(Array(JoinPolicyOption.all.enumerated()), id: \.element.id) { index, option in
                if index > 0 { VoiidRowDivider(inset: 0) }
                Button {
                    Haptics.selection()
                    joinPolicy = option.id
                } label: {
                    HStack(spacing: VoiidSpacing.md) {
                        VoiidRowIcon(systemName: option.icon)
                        Text(option.label)
                            .font(.body)
                            .foregroundStyle(VoiidColor.textPrimary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: VoiidSpacing.sm)
                        if joinPolicy == option.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(VoiidColor.accentInk)
                        }
                    }
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(joinPolicy == option.id ? [.isSelected] : [])
            }
        }
    }

    // MARK: Invites

    /// The one section where the client mirrors a server-side rule, so the footer carries the
    /// reason rather than leaving a dead control unexplained. See the note on `inviteOnly`.
    private var invitesSection: some View {
        VoiidCardSection(
            "Invites",
            footer: inviteOnly
                ? "Members can\u{2019}t invite while this community is invite only \u{2014} an "
                + "invite-only community everyone can invite to isn\u{2019}t invite only. "
                + "Change Joining above to turn this back on."
                : "Members can create invite links. You can always invite people yourself."
        ) {
            VoiidSettingsRow(icon: "person.badge.plus",
                             title: "Members can invite",
                             detail: "Let ordinary members hand out a way in.") {
                Toggle("", isOn: $membersCanInvite)
                    .labelsHidden()
                    .tint(VoiidColor.accent)
                    .accessibilityLabel("Members can invite")
            }
            // Disabled AND forced off visually, rather than silently flipped in the draft: the
            // host's own preference is preserved, so switching the policy back off invite-only
            // restores what they had chosen instead of leaving it off forever.
            .disabled(inviteOnly)
            .opacity(inviteOnly ? 0.45 : 1)
        }
        // The draft binding keeps the host's choice; the SERVER's value is what
        // `effectiveMembersCanInvite` sends. Belt and braces: if the two disagree, the
        // response overwrites the draft in `apply`.
        .onChange(of: inviteOnly) { _, nowInviteOnly in
            if nowInviteOnly { Haptics.selection() }
        }
    }

    // MARK: Category

    private var categorySection: some View {
        VoiidCardSection(
            "Category",
            footer: "How this community is filed in search. Optional."
        ) {
            VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // "None" is a real choice, not an absence: the column is nullable and
                        // clearing it is the only way back out of a category once picked.
                        categoryChip(title: "None", value: "")
                        ForEach(communityCategories, id: \.self) { option in
                            categoryChip(title: option, value: option)
                        }
                        // A category from an older build or another client survives and is
                        // shown, rather than being silently dropped because this list is
                        // shorter than the server's vocabulary.
                        if !category.isEmpty, !communityCategories.contains(category) {
                            categoryChip(title: category, value: category)
                        }
                    }
                    .padding(.horizontal, VoiidSpacing.md)
                }
            }
            .padding(.vertical, VoiidSpacing.md)
        }
    }

    private func categoryChip(title: String, value: String) -> some View {
        let selected = category.trimmingCharacters(in: .whitespacesAndNewlines) == value
        return Button {
            Haptics.selection()
            category = value
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? VoiidColor.textOnAccent : VoiidColor.textPrimary)
                .padding(.horizontal, 15)
                .frame(height: 36)
                .background(Capsule().fill(selected ? VoiidColor.accent : VoiidColor.fieldFill))
                .overlay(Capsule().stroke(selected ? .clear : VoiidColor.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: Rules

    /// Rules save IMMEDIATELY, unlike everything above, and the difference is deliberate: each
    /// one is its own row on its own endpoint with no field that interacts with another, so
    /// there is nothing to batch and a Save button would only add a step between writing a
    /// rule and it existing.
    private var rulesSection: some View {
        VoiidCardSection(
            "Rules",
            footer: "Shown on the About tab to everyone who can see this community, including "
                  + "people deciding whether to join."
        ) {
            if rulesLoading {
                rulesPlaceholder { ProgressView().tint(VoiidColor.accent) }
            } else if let rulesError {
                // A FAILED FETCH IS NOT AN EMPTY LIST. An empty Rules card says the host wrote
                // none; this says we could not find out, and offers the retry.
                rulesPlaceholder {
                    VStack(spacing: 6) {
                        Text(rulesError)
                            .font(.footnote)
                            .foregroundStyle(VoiidColor.textSecondary)
                            .multilineTextAlignment(.center)
                        Button("Try again") { Task { await loadRules() } }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(VoiidColor.accentInk)
                    }
                }
            } else if rules.isEmpty {
                rulesPlaceholder {
                    Text("No rules yet. Members see nothing here until you add one.")
                        .font(.footnote)
                        .foregroundStyle(VoiidColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                    if index > 0 { VoiidRowDivider(inset: 0) }
                    ruleRow(rule, index: index)
                }
            }

            VoiidRowDivider(inset: 0)
            VoiidSettingsRow(
                icon: "plus",
                title: "Add a rule",
                // The ceiling is stated where it bites rather than as a surprise 409.
                detail: rules.count >= CommunitySettingsLimits.rules
                    ? "You\u{2019}ve reached the limit of \(CommunitySettingsLimits.rules)."
                    : nil,
                action: {
                    Haptics.tap()
                    editingRule = RuleDraft(communityId: card.id, rule: nil,
                                            position: (rules.last?.order ?? -1) + 1)
                }
            )
            .disabled(rulesLoading || rules.count >= CommunitySettingsLimits.rules)
            .opacity(rules.count >= CommunitySettingsLimits.rules ? 0.45 : 1)
        }
    }

    private func rulesPlaceholder<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(.vertical, VoiidSpacing.lg)
            .padding(.horizontal, VoiidSpacing.md)
    }

    /// One rule: its number, its text, and the three things a host can do to it. Numbered by
    /// POSITION IN THE LIST rather than by a stored number — 046's own note — so reordering is
    /// a list operation and never a renumbering chore.
    private func ruleRow(_ rule: CommunityService.Rule, index: Int) -> some View {
        let busy = ruleBusy.contains(rule.id)
        return HStack(alignment: .top, spacing: VoiidSpacing.md) {
            Text("\(index + 1)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(VoiidColor.accentInk)
                .frame(width: 34, height: 34)
                .background(Circle().stroke(VoiidColor.accent.opacity(0.5), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.text)
                    .font(.body)
                    .foregroundStyle(VoiidColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                if !rule.explanation.isEmpty {
                    Text(rule.explanation)
                        .font(.footnote)
                        .foregroundStyle(VoiidColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }

            Spacer(minLength: VoiidSpacing.sm)

            if busy {
                ProgressView().tint(VoiidColor.accent)
            } else {
                Menu {
                    Button {
                        editingRule = RuleDraft(communityId: card.id, rule: rule,
                                                position: rule.order)
                    } label: { Label("Edit", systemImage: "pencil") }

                    // Reordering is a PATCH of `position` on the two rules that swap, which is
                    // why it is two menu items rather than a drag: a `List` with `onMove` would
                    // mean giving up the card vocabulary this whole screen is built on, and a
                    // swap is the only reorder a rules list of at most 20 actually needs.
                    Button {
                        Task { await move(from: index, to: index - 1) }
                    } label: { Label("Move up", systemImage: "arrow.up") }
                        .disabled(index == 0)

                    Button {
                        Task { await move(from: index, to: index + 1) }
                    } label: { Label("Move down", systemImage: "arrow.down") }
                        .disabled(index == rules.count - 1)

                    Divider()
                    Button(role: .destructive) {
                        pendingDelete = rule
                    } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(VoiidColor.textSecondary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 11)
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } })
    }

    // MARK: Save bar

    private var saveBar: some View {
        HStack {
            Button {
                Haptics.tap()
                Task { await save() }
            } label: {
                Group {
                    if saving {
                        ProgressView().tint(VoiidColor.textOnAccent)
                    } else {
                        Text("Save changes")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(canSave ? VoiidColor.textOnAccent
                                                     : VoiidColor.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(Capsule().fill(canSave ? VoiidColor.accent
                                                   : VoiidColor.surfaceCard))
                .overlay(Capsule().stroke(canSave ? .clear : VoiidColor.divider, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, VoiidSpacing.sm)
        .background(.ultraThinMaterial)
    }

    // MARK: Field

    /// A labelled field inside a card row. Mirrors `ComposerField` in CommunityAuthoring.swift
    /// — same counter-at-80% rule, same field chrome — rather than importing it, because that
    /// one is `private` to its file and lives inside a sheet's scaffold rather than a card row.
    private func settingsField(icon: String, label: String, placeholder: String,
                               text: Binding<String>, limit: Int,
                               multiline: Bool = false) -> some View {
        let count = text.wrappedValue.count
        return HStack(alignment: .top, spacing: VoiidSpacing.md) {
            VoiidRowIcon(systemName: icon)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(VoiidColor.textSecondary)
                    Spacer(minLength: 0)
                    // Only in the last fifth: a counter on an empty field is noise, and one
                    // that appears when it matters reads as a guardrail rather than a scold.
                    if count >= (limit * 4) / 5 {
                        Text("\(limit - count)")
                            .font(.footnote.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(count >= limit ? VoiidColor.warning
                                                            : VoiidColor.textSecondary)
                    }
                }
                Group {
                    if multiline {
                        TextField(placeholder, text: text, axis: .vertical).lineLimit(2...5)
                    } else {
                        TextField(placeholder, text: text)
                    }
                }
                .font(.body)
                .foregroundStyle(VoiidColor.textPrimary)
                .tint(VoiidColor.accent)
                .padding(.horizontal, VoiidSpacing.sm + 2)
                .padding(.vertical, 9)
                .background(VoiidColor.fieldFill)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .stroke(VoiidColor.fieldBorder, lineWidth: 1))
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 11)
    }

    // MARK: Writes

    /// Save the whole draft in ONE PATCH.
    ///
    /// Only changed fields are sent: `update` omits an absent key entirely, and on this route
    /// an absent key means "leave this column alone" while an explicit null means "clear it".
    /// Sending the full draft every time would work, but it would also make every save a write
    /// to six columns and lose the distinction the route went to trouble to keep.
    private func save() async {
        guard canSave else { return }
        saving = true
        saveFailure = nil
        savedAt = nil
        defer { saving = false }

        let newAbout = about.trimmingCharacters(in: .whitespacesAndNewlines)
        let newCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let updated = try await CommunityService.shared.update(
                communityId: card.id,
                name: trimmedName == (card.name ?? "") ? nil : trimmedName,
                // `.some(nil)` clears; the outer nil leaves it alone. An emptied field is a
                // deliberate clear, which is exactly the case a plain `String?` could not say.
                description: newAbout == (card.description ?? "")
                    ? nil : .some(newAbout.isEmpty ? nil : newAbout),
                discoverable: discoverable == card.isDiscoverable ? nil : discoverable,
                joinPolicy: joinPolicy == card.policy ? nil : joinPolicy,
                category: newCategory == (card.category ?? "")
                    ? nil : .some(newCategory.isEmpty ? nil : newCategory),
                membersCanInvite: effectiveMembersCanInvite == card.membersCanInvite
                    ? nil : effectiveMembersCanInvite)
            apply(updated)
            Haptics.success()
        } catch {
            // The draft is left EXACTLY as the host typed it and the read-only values keep
            // showing the last card the server confirmed. Nothing on screen claims to have
            // been saved.
            saveFailure = (error as? APIError)?.errorDescription
                ?? "Couldn\u{2019}t save those settings."
            Haptics.error()
        }
    }

    /// Adopt the server's answer as the new truth.
    ///
    /// The draft is RE-SEEDED from the response rather than left as typed, because the server
    /// may legitimately have stored something else: it trims to the column ceilings and it
    /// forces `members_can_invite` off for an invite-only community. Re-seeding is what stops
    /// the screen from showing the host's input as though it were the stored value.
    private func apply(_ updated: CommunityService.CommunityCard) {
        card = updated
        name = updated.name ?? ""
        about = updated.description ?? ""
        discoverable = updated.isDiscoverable
        joinPolicy = updated.policy
        category = updated.category ?? ""
        membersCanInvite = updated.membersCanInvite
        savedAt = Date()
        onSaved(updated)
    }

    private func loadRules() async {
        rulesLoading = true
        do {
            let fetched = try await CommunityService.shared.rules(communityId: card.id)
            rules = fetched.sorted { $0.order < $1.order }
            rulesError = nil
        } catch {
            // The list is NOT cleared on failure: whatever was last known good stays visible,
            // and the error says the refresh failed rather than implying the rules vanished.
            rulesError = (error as? APIError)?.errorDescription
                ?? "Couldn\u{2019}t load the rules."
        }
        rulesLoading = false
    }

    private func deleteRule(_ rule: CommunityService.Rule) async {
        pendingDelete = nil
        guard !ruleBusy.contains(rule.id) else { return }
        ruleBusy.insert(rule.id)
        defer { ruleBusy.remove(rule.id) }
        do {
            try await CommunityService.shared.deleteRule(communityId: card.id, ruleId: rule.id)
            rules.removeAll { $0.id == rule.id }
            Haptics.success()
        } catch {
            // Removed from the server or not at all — the row stays until the server confirms.
            rulesError = (error as? APIError)?.errorDescription
                ?? "Couldn\u{2019}t delete that rule."
            Haptics.error()
        }
    }

    /// Swap two rules' `position` values.
    ///
    /// TWO PATCHes, and the local list only moves after BOTH land. A local reorder that
    /// optimistically reordered first would show an order the server does not hold if the
    /// second write failed — and the next open of the screen would silently undo it, which is
    /// the worst way to find out.
    private func move(from: Int, to: Int) async {
        guard rules.indices.contains(from), rules.indices.contains(to) else { return }
        let a = rules[from], b = rules[to]
        guard !ruleBusy.contains(a.id), !ruleBusy.contains(b.id) else { return }
        ruleBusy.insert(a.id); ruleBusy.insert(b.id)
        defer { ruleBusy.remove(a.id); ruleBusy.remove(b.id) }

        do {
            // Positions are swapped rather than recomputed for the whole list: ordering is only
            // ever RELATIVE, so touching two rows is enough and touching twenty is not better.
            let movedA = try await CommunityService.shared.updateRule(
                communityId: card.id, ruleId: a.id, position: b.order)
            let movedB = try await CommunityService.shared.updateRule(
                communityId: card.id, ruleId: b.id, position: a.order)
            if let i = rules.firstIndex(where: { $0.id == movedA.id }) { rules[i] = movedA }
            if let i = rules.firstIndex(where: { $0.id == movedB.id }) { rules[i] = movedB }
            rules.sort { $0.order < $1.order }
            Haptics.selection()
        } catch {
            rulesError = (error as? APIError)?.errorDescription
                ?? "Couldn\u{2019}t reorder the rules."
            Haptics.error()
            // The first write may have landed while the second failed, which would leave two
            // rules sharing a position. Re-reading is the only way to know what the server
            // actually holds — guessing here is what produces a list that disagrees with it.
            await loadRules()
        }
    }
}

// MARK: - Rule editor

/// What the editor sheet is editing. `rule` nil means a new one.
///
/// `Identifiable` so it can drive `.sheet(item:)`: presenting on a non-nil draft rather than on
/// a bool means the sheet can never open against a rule the list has already reloaded away.
struct RuleDraft: Identifiable {
    let communityId: String
    let rule: CommunityService.Rule?
    let position: Int

    /// A stable id per presentation. A new rule has no server id yet, so the sentinel below is
    /// what lets `.sheet(item:)` tell "adding" apart from "editing rule X".
    var id: String { rule?.id ?? "new" }
    var isNew: Bool { rule == nil }
}

/// Add or edit one rule. A sheet rather than a push, for the reason CommunityAuthoring.swift
/// gives: it is a short self-contained write that returns you to the list it changes.
@MainActor
private struct CommunityRuleEditor: View {
    let draft: RuleDraft
    /// Handed the rule the SERVER created or updated, never a locally built one — the id and
    /// the position both come from it and the list orders on the second.
    let onSaved: (CommunityService.Rule, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var detail: String
    @State private var busy = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    init(draft: RuleDraft, onSaved: @escaping (CommunityService.Rule, Bool) -> Void) {
        self.draft = draft
        self.onSaved = onSaved
        _title = State(initialValue: draft.rule?.text ?? "")
        _detail = State(initialValue: draft.rule?.explanation ?? "")
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                    VoiidSettingsHeader(
                        draft.isNew ? "New rule" : "Edit rule",
                        subtitle: "Everyone who can see this community can read this, including "
                                + "people deciding whether to join.")

                    field(label: "Rule", count: title.count,
                          limit: CommunitySettingsLimits.ruleTitle) {
                        TextField("Be useful, not loud",
                                  text: capped($title, CommunitySettingsLimits.ruleTitle))
                            .focused($focused)
                    }

                    // 046 makes `detail` nullable because a short rule does not need
                    // explaining, so this is genuinely optional and says so.
                    field(label: "Detail (optional)", count: detail.count,
                          limit: CommunitySettingsLimits.ruleDetail) {
                        TextField("Critique the work, never the person.",
                                  text: capped($detail, CommunitySettingsLimits.ruleDetail),
                                  axis: .vertical)
                            .lineLimit(3...6)
                    }

                    if let failure {
                        // With the fields rather than in an alert: the user's next action is to
                        // fix the text that is still on screen underneath it.
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
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(VoiidColor.textSecondary)
                        .disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView().tint(VoiidColor.accent)
                    } else {
                        Button(draft.isNew ? "Add" : "Save") { Task { await commit() } }
                            .font(.body.weight(.semibold))
                            // community_rules_title_len is `between 1 and 120`, so an empty
                            // title is a 400 and the button is dark until there is one.
                            .foregroundStyle(trimmedTitle.isEmpty ? VoiidColor.textSecondary
                                                                  : VoiidColor.accentInk)
                            .disabled(trimmedTitle.isEmpty)
                    }
                }
            }
            .onAppear { focused = draft.isNew }
        }
    }

    private func field<Content: View>(label: String, count: Int, limit: Int,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(label)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(VoiidColor.textSecondary)
                Spacer(minLength: 0)
                if count >= (limit * 4) / 5 {
                    Text("\(limit - count)")
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(count >= limit ? VoiidColor.warning
                                                        : VoiidColor.textSecondary)
                }
            }
            content()
                .font(.body)
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

    private func commit() async {
        guard !trimmedTitle.isEmpty, !busy else { return }
        busy = true
        failure = nil
        defer { busy = false }

        let newDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let saved: CommunityService.Rule
            if let existing = draft.rule {
                saved = try await CommunityService.shared.updateRule(
                    communityId: draft.communityId, ruleId: existing.id,
                    title: trimmedTitle,
                    // `.some(nil)` clears a detail the host emptied — the absent-vs-null
                    // distinction the route keeps, and the only way back to no explanation.
                    detail: .some(newDetail.isEmpty ? nil : newDetail))
                // `position` is deliberately NOT sent: editing a rule must not move it, which
                // is the whole reason 046 gave the table an explicit position column.
            } else {
                saved = try await CommunityService.shared.createRule(
                    communityId: draft.communityId, title: trimmedTitle,
                    detail: newDetail.isEmpty ? nil : newDetail)
            }
            onSaved(saved, draft.isNew)
            Haptics.success()
            dismiss()
        } catch {
            // The sheet STAYS OPEN and keeps the text. Dismissing on failure would destroy what
            // the host typed and tell them nothing.
            failure = (error as? APIError)?.errorDescription
                ?? "Couldn\u{2019}t save that rule."
            Haptics.error()
        }
    }
}

/// A `String` binding that refuses to hold more than `limit` characters.
///
/// TRUNCATING RATHER THAN VALIDATING ON SUBMIT, for the reason CommunityAuthoring.swift gives:
/// the server trims to the same ceiling silently, so a client that accepted 200 characters of
/// rule title and let the host press Save would store one ending mid-sentence with no warning.
/// Refusing the keystroke is the only feedback that arrives before the damage.
private func capped(_ source: Binding<String>, _ limit: Int) -> Binding<String> {
    Binding(get: { source.wrappedValue },
            set: { source.wrappedValue = String($0.prefix(limit)) })
}
