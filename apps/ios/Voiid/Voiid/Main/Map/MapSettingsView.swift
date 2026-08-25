//
//  MapSettingsView.swift
//  Voiid
//
//  The Map's own settings page, reached from the control beside the search field.
//
//  ── EVERY CONTROL HERE ALREADY EXISTED ──────────────────────────────────────────
//  Nothing on this screen is a new capability, and nothing is a second implementation:
//
//   * Ghost Mode is the SAME binding shape `PrivacySettingsView` already uses —
//     `!isVisible` read, `enterGhost(.untilOff)` / `leaveGhost()` write. Two toggles for one
//     hard gate is how a user ends up visible while one screen says they are hidden, so the
//     shape is copied deliberately rather than reinvented.
//   * Who can see me, and the active share's countdown / add-time / per-person revoke, are
//     `MapAudienceSheet(mode: .manage)` — presented, not rebuilt. That sheet already owns the
//     30-second countdown tick, the 24-hour ceiling wording and the rekey-in-flight states.
//     A copy here would be a second thing to keep correct.
//   * Map style is the same `@AppStorage` key the map's layers control writes, so the two
//     entry points are one setting.
//   * Stop all location sharing is `killSwitch()`, with the same heavier `rigid` haptic and
//     the same confirmation weight it has everywhere else.
//
//  ── WHY IT IS A PUSHED PAGE, NOT A SHEET ────────────────────────────────────────
//  It is built from the Settings card vocabulary (`SettingsChrome.swift`), and those screens
//  are pages: a 32pt header that scrolls away, cards at `VoiidRadius.lg`, circle-outline
//  accent icons. A sheet wearing that chrome would be the one Settings surface in the app
//  that reads as somewhere else.
//

import SwiftUI

struct MapSettingsView: View {
    @ObservedObject private var engine = MapPresenceEngine.shared
    @ObservedObject private var visibility = MapVisibilityState.shared

    /// Shared with `FriendsMapScreen`'s layers control through the key rather than through a
    /// binding, so whichever surface is opened first shows what the other last chose.
    @AppStorage(VoiidMapStyle.storageKey) private var styleRaw = VoiidMapStyle.standard.rawValue
    private var style: VoiidMapStyle { VoiidMapStyle(rawValue: styleRaw) ?? .standard }

    @State private var showStylePicker = false
    @State private var showAudience = false
    @State private var confirmStopAll = false
    /// The kill switch is a round trip (revoke server-side, rekey, distribute `map_off`), so
    /// the row shows it is working rather than sitting inert.
    @State private var stopping = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                VoiidSettingsHeader(
                    "Map settings",
                    subtitle: "Who can see you, for how long, and what the Map looks like.",
                    badge: ("lock.fill", "End-to-end encrypted"))

                visibilityCard
                audienceCard
                styleCard
                stopCard
                footer
            }
            .padding(VoiidSpacing.md)
        }
        .font(.body)
        .foregroundStyle(VoiidColor.textPrimary)
        .fontDesign(.rounded)
        .voiidSettingsPage()
        .sheet(isPresented: $showAudience) { MapAudienceSheet(mode: .manage) }
        // Same dialog, same three options, same storage as the map's layers control.
        .confirmationDialog("Map style", isPresented: $showStylePicker,
                            titleVisibility: .visible) {
            ForEach(VoiidMapStyle.allCases) { option in
                Button(option == style ? "\(option.title) ✓" : option.title) {
                    Haptics.selection()
                    styleRaw = option.rawValue
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        // A confirmation, because this one is not undoable in the sense a user expects:
        // everyone is dropped and re-adding them means picking them all again.
        .confirmationDialog("Stop all location sharing?", isPresented: $confirmStopAll,
                            titleVisibility: .visible) {
            Button("Stop sharing", role: .destructive) {
                Haptics.rigid()
                stopping = true
                Task {
                    await engine.killSwitch()
                    stopping = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everyone is removed and Ghost Mode turns on. Your location stops being taken at all.")
        }
        // The Map tab's own alert is presented behind this page's sheet, so a failure raised
        // in here is answered in here — the same mirroring `MapAudienceSheet` does.
        .alert("Map", isPresented: Binding(get: { engine.lastError != nil },
                                           set: { if !$0 { engine.lastError = nil } })) {
            Button("OK", role: .cancel) { engine.lastError = nil }
        } message: {
            Text(engine.lastError ?? "")
        }
    }

    // MARK: - Cards

    private var visibilityCard: some View {
        VoiidCardSection(
            "Visibility",
            footer: """
                Ghost Mode is a hard switch, not a filter: while it’s on your location isn’t \
                sent, and it isn’t even taken — the provider is stopped. Turning it off starts \
                a fresh share with a new key, so the time you were hidden stays hidden.
                """
        ) {
            // THE SAME BINDING AS PrivacySettingsView, deliberately. One gate, one shape —
            // see the file note.
            VoiidSettingsRow(icon: "moon.zzz", title: "Ghost Mode") {
                Toggle("", isOn: Binding(
                    get: { !visibility.isVisible },
                    set: { ghost in
                        Haptics.tap()
                        Task {
                            if ghost { await engine.enterGhost(.untilOff) }
                            else { await engine.leaveGhost() }
                        }
                    }
                ))
                .labelsHidden()
                .tint(VoiidColor.primary)
            }
            .accessibilityHint("Hides you from everyone on the Map")
        }
    }

    private var audienceCard: some View {
        VoiidCardSection(
            "Sharing",
            footer: shareFooter
        ) {
            // Both rows open the SAME manage sheet, because that sheet is already both
            // things: the roster with per-person "Stop sharing", and the active share's
            // countdown with its two add-time buttons. Two doors to one surface is honest
            // here — they are the two questions a user arrives with.
            VoiidSettingsRow(icon: "person.2",
                             title: "Who can see me",
                             detail: audienceDetail,
                             action: { showAudience = true }) { VoiidChevron() }

            if engine.outboundShareId != nil {
                VoiidRowDivider()
                VoiidSettingsRow(icon: "clock",
                                 title: "Active share",
                                 detail: "Add time, or stop one person",
                                 action: { showAudience = true }) { VoiidChevron() }
            }
        }
    }

    /// What the audience row says under its title. Three genuinely different answers, never
    /// a count standing in for a state.
    private var audienceDetail: String {
        if !visibility.isVisible { return "Ghost Mode is on — no one can see you" }
        let n = engine.audience.count
        if n == 0 { return "No one added yet" }
        return n == 1 ? "1 person" : "\(n) people"
    }

    private var shareFooter: String {
        engine.outboundShareId != nil
            ? "A Map share always ends on its own. Add time to top it up, to at most 24 hours from now."
            : "You appear to no one until you pick people by name. There is no “share with everyone”."
    }

    private var styleCard: some View {
        VoiidCardSection(
            "Appearance",
            footer: """
                Standard hides shops, cafés and other map labels so the faces of the people \
                sharing with you stay readable.
                """
        ) {
            VoiidSettingsRow(icon: style.icon,
                             title: "Map style",
                             detail: style.title,
                             action: { showStylePicker = true }) { VoiidChevron() }
        }
    }

    private var stopCard: some View {
        VoiidCardSection(
            footer: "Ends every share and turns Ghost Mode on. It can’t un-see a location someone already saw."
        ) {
            VoiidSettingsRow(icon: "location.slash",
                             title: "Stop all location sharing",
                             destructive: true,
                             // Disabled mid-flight rather than allowed to queue a second
                             // revoke-and-rekey round trip on top of the first.
                             action: stopping ? nil : { confirmStopAll = true }) {
                if stopping { ProgressView() }
            }
            .accessibilityHint("Ends every share and turns Ghost Mode on")
        }
    }

    /// WHAT THE MAP DOES AND DOES NOT SHARE, stated plainly and accurately. Every clause here
    /// is checkable against the engine: the 3-decimal coarsening is `MapLocationProvider`, the
    /// per-session key is `MapPresenceEngine.goVisible`, and the no-history claim is
    /// `MapPresenceStore` keeping only a latest fix.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What the Map shares")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(VoiidColor.textSecondary)
                .padding(.leading, 4)

            Text("""
                Only an approximate position — rounded to about 110 metres — and only to the \
                people you named, encrypted end to end with a key the server never sees. \
                Voiid keeps no location history: the Map holds each person’s latest position \
                and nothing before it.

                It never shares your battery level, your speed, your address book, or where \
                you have been. Nothing is sent while Ghost Mode is on, because nothing is \
                taken.
                """)
                .font(.footnote)
                .foregroundStyle(VoiidColor.textSecondary)
                .padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
