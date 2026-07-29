//
//  MapTabView.swift
//  Voiid
//
//  Feature (B) — the Map tab. A Snapchat-Map-style surface that shows ONLY the contacts
//  who have explicitly chosen to be visible to you, and that keeps YOU hidden from everyone
//  until you name individuals.
//
//  The safety surface is the point of this screen, not the map:
//   - First open is a full-screen explainer with exactly two doors — "Browse only" (the
//     default; you stay ghost) and "Choose who can see me". There is no "share with
//     everyone" and no one-tap "share with all contacts" (§8).
//   - A persistent, unmissable pill states your visibility at all times: "Visible to N
//     people" on accent, or "Ghost Mode — hidden from everyone" on grey.
//   - Ghost Mode is one tap, and it is a hard local gate — while ghosted, no fix is taken.
//
//  MapKit only (no dependency; `import MapKit` auto-links). `.standard(emphasis: .muted)`
//  with POIs excluded is the calm, on-brand surface; MapKit resolves it against the
//  environment's colorScheme, which ContentView sets from the user's Light/Dark/System
//  choice — so the tiles theme themselves without a second style definition. No background
//  location for the Map ever — so no blue system pill is expected here; if one appears, it
//  is a bug (§8).
//

import SwiftUI
import MapKit

struct MapTabView: View {
    @EnvironmentObject var session: AppSession
    /// Drives the map's brand-tint strength — a wash tuned for light muddies dark tiles.
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var engine = MapPresenceEngine.shared
    @ObservedObject private var visibility = MapVisibilityState.shared
    @ObservedObject private var directory = UserDirectory.shared
    /// Conversation live shares (A) surfaced on the Map too — see `liveContacts`. Observed so
    /// each decrypted fix (which ticks the engine's `version`) redraws the moving pin.
    @ObservedObject private var shareEngine = LocationShareEngine.shared

    @State private var camera: MapCameraPosition = .automatic
    @State private var showAudiencePicker = false
    @State private var showAudienceList = false
    @State private var showGhostOptions = false
    @State private var showExplainer = false
    /// userId whose card is open — set by tapping a face, cleared by the card's close button.
    @State private var selectedContact: String?

    // Place search (Feature 4). Native MKLocalSearch — no key, no billing, no proxy.
    @StateObject private var search = MapSearchModel()
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    @AppStorage("voiid.map.seenExplainer") private var seenExplainer = false

    var body: some View {
        NavigationStack {
            map
                .ignoresSafeArea(edges: .bottom)
                // A frosted top "wrapper" that HOLDS the visibility bar. Using safeAreaInset (not
                // a ZStack overlay) means MapKit's own controls — the zoom / user-location button
                // and compass — are placed BELOW it, so the bar and the recenter button no longer
                // overlap. The material keeps the pill readable over any map content.
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: VoiidSpacing.sm) {
                        searchField
                        // Suggestions replace the away-strip while searching: one list at a
                        // time, so the top chrome never stacks into a wall.
                        if !search.suggestions.isEmpty {
                            suggestionList
                        } else {
                            visibilityPill
                            if !awayContacts.isEmpty || !waitingContacts.isEmpty {
                                awayStrip
                            }
                        }
                    }
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.top, VoiidSpacing.sm)
                    .padding(.bottom, VoiidSpacing.sm)
                    .background(.ultraThinMaterial)
                }
                // Tapping a face opens a small card: who, how fresh, and one way to reach them.
                //
                // safeAreaInset, NOT overlay(alignment: .bottom): the map above deliberately
                // ignores the bottom safe area so tiles run under the chrome, which means a
                // bottom-aligned overlay anchors to the SCREEN edge.
                //
                // The inset alone is NOT enough. Unlike a TabView, the app's bar is drawn by
                // RootTabView as a ZStack sibling painted OVER this page — it is absent from
                // our safe area entirely, so an inset flush to the screen bottom still lands
                // behind it. `session.tabBarHeight` is that bar's measured height (0 while it
                // is hidden), so adding it is what actually holds the card clear. Measured
                // rather than a constant: the home-indicator inset differs per device.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // A searched place takes precedence over a contact card — it is the thing
                    // the user just explicitly asked for.
                    Group {
                        if let place = search.selected {
                            placeCard(place)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else if let uid = selectedContact,
                                  let p = liveContacts.first(where: { $0.senderUserId == uid }) {
                            contactCard(p)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.bottom, VoiidSpacing.sm + session.tabBarHeight)
                }
                .animation(.easeOut(duration: 0.2), value: selectedContact)
                .animation(.easeOut(duration: 0.2), value: search.selected)
                // Move the camera to a place the moment it resolves.
                .onChange(of: search.selected) { _, place in
                    guard let place else { return }
                    selectedContact = nil
                    withAnimation(.easeInOut(duration: 0.6)) {
                        camera = .region(MKCoordinateRegion(center: place.coordinate,
                                                            latitudinalMeters: 900,
                                                            longitudinalMeters: 900))
                    }
                }
                .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        if visibility.isVisible { showGhostOptions = true }
                        else { Task { await engine.leaveGhost() } }
                    } label: {
                        Image(systemName: visibility.isVisible ? "eye.fill" : "eye.slash.fill")
                            .foregroundStyle(visibility.isVisible ? VoiidColor.primary : VoiidColor.textSecondary)
                    }
                    .accessibilityLabel(visibility.isVisible ? "You are visible on the Map" : "Ghost Mode is on")
                }
            }
        }
        .tint(VoiidColor.primary)
        .onAppear {
            session.hideTabBar = false   // Map is a root tab — always show the bottom bar
            engine.noteForegrounded()
            if !seenExplainer { showExplainer = true }
        }
        .fullScreenCover(isPresented: $showExplainer) {
            MapExplainerView(
                onBrowseOnly: { seenExplainer = true; showExplainer = false },
                onChoose: { seenExplainer = true; showExplainer = false; showAudiencePicker = true }
            )
        }
        .sheet(isPresented: $showAudiencePicker) {
            MapAudienceSheet(mode: .choose)
        }
        .sheet(isPresented: $showAudienceList) {
            MapAudienceSheet(mode: .manage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiidMapAddPeople)) { _ in
            // The manage sheet's "Add people" dismisses itself, then asks the Map to open the
            // chooser (SwiftUI can't swap one sheet for another in place).
            showAudiencePicker = true
        }
        .confirmationDialog("Ghost Mode", isPresented: $showGhostOptions, titleVisibility: .visible) {
            Button(GhostDuration.oneHour.label)       { Task { await engine.enterGhost(.oneHour) } }
            Button(GhostDuration.untilTomorrow.label) { Task { await engine.enterGhost(.untilTomorrow) } }
            Button(GhostDuration.untilOff.label)      { Task { await engine.enterGhost(.untilOff) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("While ghosted you’re hidden from everyone and your location isn’t taken at all.")
        }
        .alert("Map", isPresented: Binding(get: { engine.lastError != nil },
                                           set: { if !$0 { engine.lastError = nil } })) {
            Button("OK", role: .cancel) { engine.lastError = nil }
        } message: {
            Text(engine.lastError ?? "")
        }
    }

    // MARK: - Map

    /// Two sources, one map (docs/LOCATION.md §5 + §7):
    ///   (B) presence — ambient, coarse, 5 min / 250 m. Everyone who chose to be visible to us.
    ///   (A) conversation live shares — someone actively sharing WITH ME from a chat, at
    ///       10–15 s cadence. Those fixes are already decrypted in memory for the in-chat
    ///       bubble; drawing them here publishes nothing new and changes no cadence for anyone.
    ///
    /// Deduped by user with the CONVERSATION share winning — it is strictly fresher, so a
    /// friend live-sharing with you moves in near-real-time rather than sitting on their last
    /// 5-minute presence fix.
    private var liveContacts: [MapPresence] {
        let presence = engine.presences.filter {
            let s = MapPresenceState.forFix(at: $0.fixedAt)
            return s == .live || s == .stale
        }
        var byUser = Dictionary(presence.map { ($0.senderUserId, $0) }, uniquingKeysWith: { _, b in b })
        for share in shareEngine.activeInboundShares() {
            guard let fix = shareEngine.lastFix(shareId: share.shareId) else { continue }
            byUser[share.ownerUserId] = MapPresence(
                senderUserId: share.ownerUserId,
                shareId: share.shareId,
                coordinate: CLLocationCoordinate2D(latitude: fix.lat, longitude: fix.lon),
                accuracy: fix.acc ?? 0,
                seq: fix.seq,
                fixedAt: fix.date)
        }
        return Array(byUser.values).sorted { $0.senderUserId < $1.senderUserId }
    }

    private var map: some View {
        Map(position: $camera) {
            ForEach(liveContacts) { p in
                Annotation(directory.displayName(p.senderUserId), coordinate: p.coordinate) {
                    contactMarker(p)
                }
            }
            // A searched place, if one is selected — a POI pin, visually distinct from the
            // friend avatars so the two never read as the same kind of thing.
            if let place = search.selected {
                Annotation(place.name, coordinate: place.coordinate) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(VoiidColor.error)
                        .shadow(radius: 2)
                }
            }
            // Your OWN blue dot — always shown, even in Ghost Mode. This is a purely
            // client-side view of where YOU are; it is unrelated to what you broadcast to
            // others (that is gated by `visibility`). Ghost mode hides you from others, not
            // from yourself.
            UserAnnotation()
        }
        // Snapchat-style skin: a MUTED, de-emphasised base map so the friend avatars are
        // the visual focus, not the streets. `.muted` desaturates roads/labels/terrain
        // (the closest native MapKit lever to Snapchat's custom look — no tile dependency,
        // no API key). POIs are hidden so the map reads as clean canvas. A soft brand tint
        // overlay unifies it with the app instead of stock Apple grey-blue.
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls { MapUserLocationButton(); MapCompass() }
        // Bias autocomplete to what the user is actually looking at — "coffee" should mean
        // coffee HERE, the way every native map search behaves.
        .onMapCameraChange(frequency: .onEnd) { context in
            search.setRegion(context.region)
        }
        // A soft brand wash unifies MapKit's stock palette with the app. It has to be LIGHTER
        // in dark: the same 6% teal that warms a light basemap only muddies an already-dark
        // one, turning crisp tiles into grey soup. 3% keeps the tint legible as a tint.
        .overlay(
            VoiidColor.primary.opacity(colorScheme == .dark ? 0.03 : 0.06)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        )
    }

    private func contactMarker(_ p: MapPresence) -> some View {
        let stale = MapPresenceState.forFix(at: p.fixedAt) == .stale
        return VStack(spacing: 2) {
            // The shared pin (also used by the live-location detail, and mirrored by Android's
            // AvatarPin.kt), so a face looks the same wherever it appears. It resolves the real
            // photo through AvatarCache and falls back to initials, never a generic dot.
            MapAvatarPin(userId: p.senderUserId,
                         name: directory.displayName(p.senderUserId),
                         photoURL: directory.photoURL(p.senderUserId),
                         state: stale ? .stale : .live,
                         size: 44)
            if stale {
                Text(relativeAge(p.fixedAt))
                    .font(VoiidFont.rounded(10, .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(VoiidColor.surfaceCard))
                    .foregroundColor(VoiidColor.textSecondary)
            }
        }
        .onTapGesture { Haptics.tap(); selectedContact = p.senderUserId }
        .accessibilityLabel("\(directory.displayName(p.senderUserId))\(stale ? ", last seen \(relativeAge(p.fixedAt))" : "")")
    }

    // MARK: - Place search (Feature 4)

    /// Frosted search pill, matching the visibility pill's shape so the top chrome reads as one
    /// family. Typing drives `MKLocalSearchCompleter`; clearing it tears the results down.
    private var searchField: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(VoiidColor.textSecondary)
            TextField("Search places", text: $query)
                .font(VoiidFont.rounded(15))
                .foregroundColor(VoiidColor.textPrimary)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused($searchFocused)
                .autocorrectionDisabled()
                .onChange(of: query) { _, new in search.update(query: new) }
            if !query.isEmpty {
                Button {
                    query = ""
                    search.reset()
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(VoiidColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 10)
        .background(Capsule().fill(VoiidColor.surfaceCard))
        .overlay(Capsule().stroke(VoiidColor.fieldBorder, lineWidth: 1))
    }

    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(search.suggestions.prefix(6), id: \.self) { s in
                Button {
                    Haptics.tap()
                    searchFocused = false
                    query = s.title
                    search.choose(s)
                } label: {
                    HStack(spacing: VoiidSpacing.sm) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(VoiidColor.primary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title)
                                .font(VoiidFont.rounded(14, .medium))
                                .foregroundColor(VoiidColor.textPrimary)
                                .lineLimit(1)
                            if !s.subtitle.isEmpty {
                                Text(s.subtitle)
                                    .font(VoiidFont.rounded(11))
                                    .foregroundColor(VoiidColor.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
    }

    /// Bottom card for a resolved place: name, address, and the two system handoffs.
    private func placeCard(_ place: MapSearchModel.SelectedPlace) -> some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            HStack(alignment: .top, spacing: VoiidSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(VoiidFont.rounded(16, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                        .lineLimit(2)
                    if let address = place.address {
                        Text(address)
                            .font(VoiidFont.rounded(12))
                            .foregroundColor(VoiidColor.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    Haptics.tap()
                    search.selected = nil
                    query = ""
                    search.reset()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(VoiidColor.textSecondary)
                        .padding(8).background(VoiidColor.fieldFill).clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            HStack(spacing: VoiidSpacing.sm) {
                // Handoff only — no in-app routing (docs/LOCATION.md §10.10).
                placeAction("Directions", "arrow.triangle.turn.up.right.circle.fill", filled: true) {
                    place.openInMaps(directions: true)
                }
                placeAction("Open in Maps", "map.fill", filled: false) {
                    place.openInMaps(directions: false)
                }
            }
        }
        .padding(14)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private func placeAction(_ title: String, _ icon: String, filled: Bool,
                             _ tap: @escaping () -> Void) -> some View {
        Button(action: { Haptics.tap(); tap() }) {
            Label(title, systemImage: icon)
                .font(VoiidFont.rounded(14, .semibold))
                .foregroundColor(filled ? .white : VoiidColor.textPrimary)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(filled ? VoiidColor.primary : VoiidColor.fieldFill)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The card shown when you tap a friend's face on the Map.
    ///
    /// Deliberately minimal: who, how fresh their position is, and a way out. No street address
    /// (we never reverse-geocode — docs/LOCATION.md §10) and no coordinate readout.
    private func contactCard(_ p: MapPresence) -> some View {
        let stale = MapPresenceState.forFix(at: p.fixedAt) == .stale
        return HStack(spacing: VoiidSpacing.md) {
            MapAvatarPin(userId: p.senderUserId,
                         name: directory.displayName(p.senderUserId),
                         photoURL: directory.photoURL(p.senderUserId),
                         state: stale ? .stale : .live,
                         size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(directory.displayName(p.senderUserId))
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)
                Text(stale ? "May have lost signal" : "Updated \(relativeAge(p.fixedAt))")
                    .font(VoiidFont.rounded(12))
                    .foregroundColor(VoiidColor.textSecondary)
                    .lineLimit(1)
                // A Map pin is an area, not a doorstep. Presence accuracy is deliberately
                // coarsened to ≥100 m before sending, so this honestly reads "about 100 m".
                Text(LocationAccuracy.note(p.accuracy))
                    .font(VoiidFont.rounded(10))
                    .foregroundColor(VoiidColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                Haptics.tap()
                selectedContact = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(VoiidColor.textSecondary)
                    .padding(8)
                    .background(VoiidColor.fieldFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(14)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    // MARK: - Visibility pill (persistent, unmissable)

    private var visibilityPill: some View {
        Button {
            Haptics.tap()
            showAudienceList = true
        } label: {
            HStack(spacing: VoiidSpacing.sm) {
                Circle()
                    .fill(visibility.isVisible ? VoiidColor.primary : VoiidColor.textSecondary)
                    .frame(width: 8, height: 8)
                    .opacity(visibility.isVisible ? 1 : 0.5)
                Text(pillText)
                    .font(VoiidFont.rounded(14, .semibold))
                    .foregroundColor(visibility.isVisible ? VoiidColor.textOnPrimary : VoiidColor.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor((visibility.isVisible ? VoiidColor.textOnPrimary : VoiidColor.textSecondary).opacity(0.8))
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(visibility.isVisible ? VoiidColor.primary : VoiidColor.surfaceCard)
            )
            .overlay(
                Capsule().stroke(VoiidColor.fieldBorder.opacity(visibility.isVisible ? 0 : 1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var pillText: String {
        if !visibility.isVisible { return "Ghost Mode — hidden from everyone" }
        let n = engine.audience.count
        return n == 1 ? "Visible to 1 person" : "Visible to \(n) people"
    }

    // MARK: - Away / waiting strip (contacts off the map)
    //
    // Aged-out contacts keep their last-known position off the map but appear here with a
    // "last seen" — that is the honest signal that a phone went dark, distinct from an
    // explicit stop (which erases them entirely). Contacts who shared but haven't sent a
    // first fix yet show "Locating…".

    private var awayContacts: [MapPresence] {
        engine.presences.filter { MapPresenceState.forFix(at: $0.fixedAt) == .agedOut }
    }
    private var waitingContacts: [String] {
        engine.inboundSenders
            .filter { uid in !engine.presences.contains(where: { $0.senderUserId == uid }) }
            .sorted()
    }

    private var awayStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: VoiidSpacing.sm) {
                ForEach(waitingContacts, id: \.self) { uid in
                    awayChip(name: directory.displayName(uid), subtitle: "Locating…",
                             photo: directory.photoURL(uid))
                }
                ForEach(awayContacts) { p in
                    awayChip(name: directory.displayName(p.senderUserId),
                             subtitle: "Last seen \(relativeAge(p.fixedAt))",
                             photo: directory.photoURL(p.senderUserId))
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func awayChip(name: String, subtitle: String, photo: String?) -> some View {
        HStack(spacing: 6) {
            ProfileAvatarButton(photoURL: photo, name: name, size: 26)
                .saturation(0.2)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(VoiidFont.rounded(12, .semibold)).foregroundColor(VoiidColor.textPrimary)
                Text(subtitle).font(VoiidFont.rounded(10, .regular)).foregroundColor(VoiidColor.textSecondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Capsule().fill(VoiidColor.surfaceCard))
        .overlay(Capsule().stroke(VoiidColor.fieldBorder, lineWidth: 1))
    }

    private func relativeAge(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
