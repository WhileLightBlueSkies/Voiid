//
//  CreatorPrivacyView.swift
//  Voiid
//
//  Privacy controls for the PUBLIC creator profile.
//
//  ── WHY THIS IS SEPARATE FROM SETTINGS → PRIVACY ────────────────────────────────
//  The reference keeps account settings in their own sheet ("YOUR ACCOUNT. Devices,
//  privacy, the V PIN. Private, and only you see it") and this is a different thing: it
//  governs a PUBLIC, server-attributed surface, not the E2EE messaging identity. Mixing
//  them would suggest the two identities are one, which 029's schema note is explicit they
//  are not — the creator profile is deliberately not the messaging profile.
//
//  ── WHY FIVE SWITCHES AND NOT ONE "PRIVATE ACCOUNT" TOGGLE ──────────────────────
//  A single private flag is the obvious design and the wrong one. It conflates decisions
//  people genuinely make differently: a visible grid with a hidden follower count is a
//  common and coherent choice, and so is a reachable profile that does not surface in
//  search. Each control here is one decision a creator can actually articulate.
//
//  ── EVERY CONTROL SAVES IMMEDIATELY ─────────────────────────────────────────────
//  No Save button. A privacy screen with an unsaved state can leave someone believing they
//  are hidden when they are not, and that failure is worse than the occasional redundant
//  request. Each change PATCHes just its own field (the encoder omits nil, so nothing else
//  is touched) and reverts visibly if the server refuses.
//

import SwiftUI

struct CreatorPrivacyView: View {

    @EnvironmentObject private var creators: CreatorEngine

    /// Seeded from the loaded profile; each is written through on change.
    @State private var gridVisibility = "everyone"
    @State private var showCounts = true
    @State private var discoverable = true
    @State private var allowFollows = true
    @State private var allowComments = true

    @State private var saving = false
    @State private var errorText: String?
    /// Suppresses the write-through while the initial values are being seeded — otherwise
    /// simply opening the screen PATCHes every field back to the server.
    @State private var seeded = false

    private var profile: CreatorService.Profile? { creators.me }

    var body: some View {
        ScrollView {
            VStack(spacing: VoiidSpacing.lg) {
                if let errorText {
                    Text(errorText)
                        .font(VoiidFont.caption)
                        .foregroundColor(VoiidColor.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, VoiidSpacing.md)
                }

                gridCard
                audienceCard
                discoveryCard
            }
            .padding(.vertical, VoiidSpacing.md)
        }
        .scrollIndicators(.hidden)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("Profile privacy")
        .navigationBarTitleDisplayMode(.inline)
        .task { await seed() }
    }

    // MARK: - Cards

    private var gridCard: some View {
        VoiidCardSection(
            "Your clips",
            footer: gridFooter
        ) {
            ForEach(Array(GridChoice.allCases.enumerated()), id: \.element) { index, choice in
                if index > 0 { VoiidRowDivider() }
                Button {
                    Haptics.selection()
                    gridVisibility = choice.rawValue
                    Task { await save(grid: choice.rawValue) }
                } label: {
                    VoiidSettingsRow(icon: choice.icon, title: choice.title) {
                        if gridVisibility == choice.rawValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(VoiidColor.primary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(gridVisibility == choice.rawValue ? [.isSelected] : [])
            }
        }
    }

    /// Spells out the consequence of the CURRENT choice rather than describing the control.
    /// "Who can see your clips" tells someone nothing they cannot see from the rows.
    private var gridFooter: String {
        switch gridVisibility {
        case "followers":
            return "People can still find your profile and see your bio — but only followers see your clips."
        case "nobody":
            return "Your clips stay on your profile for you alone. They remain in the main feed unless you delete them."
        default:
            return "Anyone on Voiid can see your clips on your profile."
        }
    }

    private var audienceCard: some View {
        VoiidCardSection(
            "Your audience",
            footer: """
                Turning off follows keeps the people who already follow you — it only stops \
                new ones. Comments are hidden, not deleted, so turning them back on restores \
                the conversation.
                """
        ) {
            VoiidSettingsRow(icon: "person.badge.plus", title: "Allow new followers") {
                Toggle("", isOn: $allowFollows)
                    .labelsHidden().tint(VoiidColor.primary)
                    .onChange(of: allowFollows) { _, v in
                        guard seeded else { return }
                        Task { await save(allowFollows: v) }
                    }
            }

            VoiidRowDivider()

            VoiidSettingsRow(icon: "text.bubble", title: "Allow comments") {
                Toggle("", isOn: $allowComments)
                    .labelsHidden().tint(VoiidColor.primary)
                    .onChange(of: allowComments) { _, v in
                        guard seeded else { return }
                        Task { await save(allowComments: v) }
                    }
            }

            VoiidRowDivider()

            VoiidSettingsRow(icon: "number", title: "Show follower counts") {
                Toggle("", isOn: $showCounts)
                    .labelsHidden().tint(VoiidColor.primary)
                    .onChange(of: showCounts) { _, v in
                        guard seeded else { return }
                        Task { await save(showCounts: v) }
                    }
            }
        }
    }

    private var discoveryCard: some View {
        VoiidCardSection(
            "Discovery",
            footer: """
                When this is off you won’t appear in search or suggestions. Anyone with a \
                direct link to your profile can still open it — this makes you unlisted, \
                not unreachable.
                """
        ) {
            VoiidSettingsRow(icon: "magnifyingglass", title: "Show in search") {
                Toggle("", isOn: $discoverable)
                    .labelsHidden().tint(VoiidColor.primary)
                    .onChange(of: discoverable) { _, v in
                        guard seeded else { return }
                        Task { await save(discoverable: v) }
                    }
            }
        }
    }

    // MARK: - Load / save

    private func seed() async {
        let p = await creators.ensureMeLoaded()
        guard let p else { return }
        gridVisibility = p.grid_visibility ?? "everyone"
        showCounts = p.show_counts ?? true
        discoverable = p.discoverable ?? true
        allowFollows = p.allow_follows ?? true
        allowComments = p.allow_comments ?? true
        // Only now do the onChange handlers become live writes.
        seeded = true
    }

    /// One field per call. The encoder omits nil, so a change to one switch never rewrites
    /// the others — and never re-sends the handle, which would burn the 30-day rename window.
    private func save(grid: String? = nil, showCounts: Bool? = nil,
                      discoverable: Bool? = nil, allowFollows: Bool? = nil,
                      allowComments: Bool? = nil) async {
        saving = true
        errorText = nil
        do {
            try await creators.updatePrivacy(gridVisibility: grid, showCounts: showCounts,
                                             discoverable: discoverable,
                                             allowFollows: allowFollows,
                                             allowComments: allowComments)
        } catch {
            // Put the switch back. A privacy control that silently fails leaves someone
            // believing they are hidden when they are not.
            errorText = "Couldn’t save that. Check your connection and try again."
            await seed()
        }
        saving = false
    }

    private enum GridChoice: String, CaseIterable {
        case everyone, followers, nobody

        var title: String {
            switch self {
            case .everyone:  return "Everyone"
            case .followers: return "Followers only"
            case .nobody:    return "Only me"
            }
        }
        var icon: String {
            switch self {
            case .everyone:  return "globe"
            case .followers: return "person.2"
            case .nobody:    return "lock"
            }
        }
    }
}
