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
//  THIS FILE IS THE SHELL. It owns the state, the engines, the sheets, the dialogs and the
//  composition — and nothing that can be drawn on its own. The pieces live in Main/Map/:
//  MapCanvas (the map + pins), MapHeader, MapSearchField + MapSuggestionList, MapPlaceCard,
//  MapContactCard, MapChrome (the visibility pill + away strip), MapFormatters (age/distance).
//  Each takes explicit inputs so it can be reasoned about and previewed without an engine.
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
    /// Move (journey / ETA). Observed so a contact who starts travelling grows a badge on
    /// their pin and a "See their route" row on their card without any other change here.
    @ObservedObject private var moves = MapMoveEngine.shared
    /// MY own last coarse fix. Read only to compute the "about N km away" line on a contact
    /// card — never emitted from here, and nil while ghosted (the provider is stopped), which
    /// is exactly why that line is optional rather than assumed.
    @ObservedObject private var myLocation = MapLocationProvider.shared
    /// Direct conversations, so the card's Message action can open an EXISTING 1:1 rather
    /// than minting one. No conversation → no button, because a Map card is not the place to
    /// create a first contact with someone.
    @EnvironmentObject private var chat: ChatStore

    @State private var camera: MapCameraPosition = .automatic
    @State private var showAudiencePicker = false
    @State private var showAudienceList = false
    @State private var showGhostOptions = false
    @State private var showExplainer = false
    /// userId whose card is open — set by tapping a face, cleared by the card's close button.
    @State private var selectedContact: String?
    /// The contact whose Move screen is open, if any — a navigation destination rather than a
    /// sheet, because a journey is a place you go and come back from.
    /// Your own profile / settings, from the header avatar.
    @State private var showSettings = false
    @State private var openMoveFor: String?
    /// The bell's destination, and the search row's. Both are PUSHED rather than presented:
    /// they are built from the Settings card vocabulary, which is a page idiom (a 32pt header
    /// that scrolls away), and the Map's own audience sheet is still a sheet presented from
    /// inside Map settings — a page pushing a sheet reads correctly, a sheet over a sheet
    /// does not.
    @State private var showMapNotifications = false
    @State private var showMapSettings = false
    /// The traveller-side sheet for starting / ending my own Move.
    @State private var showStartMove = false
    /// Last camera region, handed to the Move sheet so its place search is biased to what the
    /// user is looking at — the same bias the Map's own search uses.
    @State private var lastRegion: MKCoordinateRegion?

    // Place search (Feature 4). Native MKLocalSearch — no key, no billing, no proxy.
    @StateObject private var search = MapSearchModel()
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    @AppStorage("voiid.map.seenExplainer") private var seenExplainer = false

    // ── THE MAP TAB IS THE REFERENCE SCREEN, ON THE REAL ENGINE ─────────────────────
    //
    // The tab renders `FriendsMapScreen` (Main/Map/Reference/) — the ported design reference,
    // its layout untouched. It is no longer running on mock data: `MapStore`
    // (ReferenceMapModels.swift) is now a live adapter over `MapPresenceEngine` and friends,
    // so the pins are the real people who chose to be visible to us.
    //
    // THIS FILE REMAINS THE SHELL, and that is the whole reason it survived the port: the
    // NavigationStack, the audience sheets, the ghost dialogs, the Move destination and the
    // explainer all live here, and the screen reaches them through the three closures below
    // rather than owning any engine itself. A screen that is a faithful copy of a design can
    // stay faithful precisely because none of this is inside it.
    //
    // See docs/MAP_STATUS.md for what is engine (untouchable) and what is UI.
    var body: some View {
        NavigationStack {
            FriendsMapScreen(
                onOpenMove: { friend in openMoveFor = friend.id },
                // Opening an EXISTING conversation, never minting one — the lookup below
                // returns nil when there is none, and the screen disables the button.
                onMessage: { friend in openChatWith = directConversation(with: friend.id) },
                hasConversation: { friend in directConversation(with: friend.id) != nil },
                // The header's status line IS the ghost control. `toggleGhost` is the single
                // rule both this and any other surface goes through.
                onToggleVisibility: toggleGhost,
                // Your own avatar opens Settings — the same sheet the Chats header opens, so
                // there is ONE place your profile lives rather than a second half-copy of it.
                onOpenProfile: { showSettings = true },
                // WAS the audience list, as a stopgap. The bell now opens Map activity —
                // a page that states what the engine actually holds (who is sharing, who is
                // waiting on a first fix, when my own share lapses). There is still no event
                // feed anywhere in this app to point it at; see MapNotificationsView's file
                // note for what was searched for and what exists. The reference's hardcoded
                // "3" badge is gone from the screen in the same change.
                onOpenNotifications: { showMapNotifications = true },
                // The control beside the search field. It was empty; it is now the Map's only
                // door to its own settings — see the note at its call site for why that
                // rather than a filter panel.
                onOpenSettings: { showMapSettings = true })
            .navigationDestination(isPresented: $showMapNotifications) {
                MapNotificationsView()
            }
            .navigationDestination(isPresented: $showMapSettings) {
                MapSettingsView()
            }
            .navigationDestination(item: $openMoveFor) { userId in
                MapMoveScreen(senderUserId: userId)
            }
            .navigationDestination(item: $openChatWith) { conv in
                ChatDetailView(conversation: conv)
            }
        }
        .sheet(isPresented: $showAudiencePicker) { MapAudienceSheet(mode: .choose) }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .sheet(isPresented: $showAudienceList) { MapAudienceSheet(mode: .manage) }
        .sheet(isPresented: $showStartMove) { MapStartMoveSheet(region: lastRegion) }
        .fullScreenCover(isPresented: $showExplainer) {
            // Onboarding is marked seen on EVERY exit path, and only the explicit
            // "choose who can see me" door opens the audience picker. "Browse only" lands on
            // the map still ghosted, which is the default state anyway — nothing is emitted.
            MapOnboardingFlow { outcome in
                seenExplainer = true
                showExplainer = false
                if outcome == .chooseAudience { showAudiencePicker = true }
            }
        }
        // Ghost is a DURATION choice on the way in and a single tap on the way out — the one
        // rule, in one place, so the toolbar and the header can never diverge.
        .confirmationDialog("Ghost Mode", isPresented: $showGhostOptions, titleVisibility: .visible) {
            Button(GhostDuration.oneHour.label) { Task { await engine.enterGhost(.oneHour) } }
            Button(GhostDuration.untilTomorrow.label) { Task { await engine.enterGhost(.untilTomorrow) } }
            Button(GhostDuration.untilOff.label) { Task { await engine.enterGhost(.untilOff) } }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            engine.noteForegrounded()
            if !seenExplainer { showExplainer = true }
        }
    }

    /// The chat to push, if the card's Message (or Call) was tapped. A conversation rather
    /// than a userId, because the lookup already proved one exists.
    @State private var openChatWith: VConversation?


    // MARK: - Ghost Mode
    //
    // The one rule, in ONE place: visible → offer a duration; ghosted → leave ghost outright.
    // Both the toolbar button and the header's eye call this, so the two can never diverge.

    private func toggleGhost() {
        if visibility.isVisible { showGhostOptions = true }
        else { Task { await engine.leaveGhost() } }
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

    private var mapCanvas: some View {
        MapCanvas(camera: $camera,
                  contacts: liveContacts,
                  selectedPlace: search.selected,
                  colorScheme: colorScheme,
                  displayName: { directory.displayName($0) },
                  photoURL: { directory.photoURL($0) },
                  move: { moves.move(from: $0) },
                  onRegionChange: { region in
                      search.setRegion(region)
                      // Same bias, reused by the Move sheet's destination search.
                      lastRegion = region
                  },
                  onTapContact: { selectedContact = $0 })
    }

    // MARK: - Header

    private var header: some View {
        MapHeader(photoURL: session.profile.photoURL,
                  fullName: session.profile.fullName,
                  isVisible: visibility.isVisible,
                  statusText: pillText,
                  onToggleGhost: toggleGhost)
    }

    // MARK: - Place search (Feature 4)

    private var searchField: some View {
        MapSearchField(query: $query,
                       focused: $searchFocused,
                       onQueryChange: { search.update(query: $0) },
                       onClear: {
                           query = ""
                           search.reset()
                           searchFocused = false
                       })
    }

    private var suggestionList: some View {
        MapSuggestionList(suggestions: search.suggestions) { s in
            searchFocused = false
            query = s.title
            search.choose(s)
        }
    }

    private func placeCard(_ place: MapSearchModel.SelectedPlace) -> some View {
        MapPlaceCard(place: place) {
            search.selected = nil
            query = ""
            search.reset()
        }
    }

    private func contactCard(_ p: MapPresence) -> some View {
        MapContactCard(presence: p,
                       displayName: directory.displayName(p.senderUserId),
                       photoURL: directory.photoURL(p.senderUserId),
                       move: moves.move(from: p.senderUserId),
                       distanceText: MapFormatters.distanceText(from: myLocation.lastFix,
                                                                to: p.coordinate),
                       conversation: directConversation(with: p.senderUserId),
                       onOpenMove: { openMoveFor = p.senderUserId },
                       onClose: { selectedContact = nil })
    }

    // MARK: - Visibility pill (persistent, unmissable)

    private var visibilityPill: some View {
        MapVisibilityPill(isVisible: visibility.isVisible, text: pillText) {
            showAudienceList = true
        }
    }

    /// One wording of visibility state, used by BOTH the pill and the header's status line, so
    /// the two can never disagree.
    private var pillText: String {
        MapVisibilityPill.text(isVisible: visibility.isVisible,
                               audienceCount: engine.audience.count)
    }

    // MARK: - Away / waiting strip (contacts off the map)

    private var awayContacts: [MapPresence] {
        engine.presences.filter { MapPresenceState.forFix(at: $0.fixedAt) == .agedOut }
    }
    private var waitingContacts: [String] {
        engine.inboundSenders
            .filter { uid in !engine.presences.contains(where: { $0.senderUserId == uid }) }
            .sorted()
    }

    private var awayStrip: some View {
        MapAwayStrip(waiting: waitingContacts,
                     away: awayContacts,
                     displayName: { directory.displayName($0) },
                     photoURL: { directory.photoURL($0) })
    }

    /// The existing 1:1 with this person, if there is one. Deliberately a LOOKUP, never a
    /// creation: the Map may open a conversation that already exists, but starting one is not
    /// something a tap on a pin should do.
    private func directConversation(with userId: String) -> VConversation? {
        chat.directConversations.first { $0.type == .direct && $0.peerUserId == userId }
    }
}
