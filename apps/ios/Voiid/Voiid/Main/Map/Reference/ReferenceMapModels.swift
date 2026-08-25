//
//  ReferenceMapModels.swift
//  Voiid
//
//  Voiid Friends Map — "See your world. On your terms."
//
//  ── PRIVACY IS THE PRODUCT, SO IT IS THE MODEL ──────────────────────────────────
//  A location-sharing feature lives or dies on whether people believe they control it. That
//  belief is not built by a settings screen tucked away somewhere — it is built by the model
//  making the unsafe state impossible to reach by accident.
//
//  So [MapAudience] and [ShareWindow] are separate, both required, and neither has a
//  "share with everyone forever" default. Ghost Mode is a case of the audience enum rather
//  than a Bool beside it, because "who can see me" has exactly one answer at a time and two
//  overlapping flags is how a user ends up visible when they thought they were hidden.
//
//  ── WHAT CHANGED WHEN THIS WAS WIRED UP ─────────────────────────────────────────
//  `MapStore` was a bag of literals: four fake friends around a hardcoded Toronto centre.
//  It is now a LIVE ADAPTER over the real engines — MapPresenceEngine (who is sharing with
//  me, E2EE), MapVisibilityState (am I ghosted), MapLocationProvider (my own last coarse
//  fix, for distances), MapMoveEngine (who is travelling), UserDirectory (names).
//
//  The adapter shape was chosen deliberately: FriendsMapScreen is a signed-off, byte-for-byte
//  port of the design reference. Keeping `MapStore` as its interface means the screen reads
//  `store.friends` / `store.selected` / `store.filter` / `store.isVisible` / `store.statusText`
//  exactly as before, and essentially none of its 400 lines of layout had to move.
//
//  NOTHING HERE EMITS. The adapter is read-only over the engine plus three intent methods
//  that forward to it. Ghost Mode stays the engine's hard local gate; this file cannot
//  weaken it, and takes no fix of its own.
//

import SwiftUI
import CoreLocation
import Combine
import MapKit

// MARK: - Privacy

/// Who can see your location. One answer at a time — see the file note.
///
/// VOIID MAPPING: Voiid has exactly two states on the wire — ghosted, or visible to an
/// explicit per-contact audience. So only `.ghost` and `.selected` are reachable here:
///   `.ghost`    ↔ `MapVisibilityState.isEffectivelyGhosted`
///   `.selected` ↔ visible, with `MapPresenceEngine.audience` naming the recipients.
/// `.closeFriends` and `.allFriends` are kept ONLY so the reference's enum (and anything
/// that switches exhaustively over it) still compiles. They are never assigned and never
/// displayed. Inventing them would mean inventing a friend-tier concept the directory does
/// not have and a "share with all" default §8 explicitly forbids.
enum MapAudience: String, CaseIterable, Identifiable {
    case ghost
    case selected
    case closeFriends
    case allFriends

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ghost:        "Ghost Mode"
        case .selected:     "Only Selected Friends"
        case .closeFriends: "Close Friends"
        case .allFriends:   "All Friends"
        }
    }

    var detail: String {
        switch self {
        case .ghost:        "No one can see you"
        case .selected:     "Choose specific friends"
        case .closeFriends: "Your close friends list"
        case .allFriends:   "All friends on Voiid"
        }
    }

    var icon: String {
        switch self {
        case .ghost:        "eye.slash"
        case .selected:     "person.2"
        case .closeFriends: "person.2.fill"
        case .allFriends:   "globe"
        }
    }

    /// Whether this audience puts you on other people's maps at all.
    var isVisible: Bool { self != .ghost }
}

/// How long the sharing lasts.
///
/// "Until turned off" is deliberately LAST and deliberately not the default. An indefinite
/// share is the one option a user can forget they enabled, so it has to be chosen rather than
/// arrived at.
enum ShareWindow: String, CaseIterable, Identifiable {
    case fifteenMinutes = "15 min"
    case oneHour = "1 hour"
    case untilOff = "Until turned off"

    var id: String { rawValue }
}

// MARK: - People on the map

/// Someone sharing their location with you.
///
/// Built from a `MapPresence` — a decrypted fix that arrived over the 1:1 ratchet. Every
/// field below is either carried by that presence or derived from it; nothing is invented.
struct MapFriend: Identifiable, Hashable {
    /// The sender's user id. Stable, and what every engine call is keyed on.
    let id: String
    let name: String
    /// WHERE THEY ARE, ABSOLUTELY.
    ///
    /// The reference stored `dLat`/`dLon` offsets from a hardcoded Toronto centre because its
    /// friends were hand-placed decoration. Real presences carry a real coordinate (already
    /// coarsened to 3 dp ≈ 110 m by the sender before it ever left their device), so the
    /// offsets are gone and `FriendsMapScreen.coordinate(for:)` now just returns this.
    let coordinate: CLLocationCoordinate2D
    /// "2 min ago" — from `presence.fixedAt` via `MapFormatters.relativeAge`.
    var lastSeen: String = ""
    // NO BATTERY FIELD, BY DECISION. `MapEnvelope` carries lat/lon/accuracy/seq and nothing
    // else — battery level is neither sent nor stored by anyone. The reference's chip was
    // removed from the card rather than fed a fabricated number, and the field went with it:
    // a property nothing can populate is a property the next reader wastes an hour sourcing.
    /// Human distance from ME, or nil when it cannot be answered honestly — no fix of my own
    /// (Ghost Mode stops my provider), or a gap inside the coarsening noise floor.
    /// `MapFormatters.distanceText` owns that judgement; this is just its result.
    var distanceText: String? = nil
    /// NO SOURCE. Voiid's directory has no favourites concept. Always false, so the star
    /// never draws. Kept as a field so the reference's card body is untouched.
    var isFavourite: Bool = false
    /// True when `MapMoveEngine` holds an inbound Move from this person — they are actively
    /// travelling and their route screen is worth offering.
    var isMoving: Bool = false

    static func == (l: MapFriend, r: MapFriend) -> Bool {
        l.id == r.id && l.name == r.name && l.lastSeen == r.lastSeen
            && l.distanceText == r.distanceText
            && l.isFavourite == r.isFavourite && l.isMoving == r.isMoving
            && l.coordinate.latitude == r.coordinate.latitude
            && l.coordinate.longitude == r.coordinate.longitude
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The map's filter row.
///
/// All four chips stay — the row is signed-off UI. Only `.friends` has a backend; the other
/// three are honest about it via `unavailableMessage` (rendered as an empty state) rather
/// than silently showing the friends list under someone else's label.
enum MapFilter: String, CaseIterable, Identifiable {
    case friends = "Friends"
    case places = "Places"
    case hangouts = "Hangouts"
    case move = "Move"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .friends:  "person.2"
        case .places:   "mappin.circle"
        case .hangouts: "figure.2"
        case .move:     "arrow.triangle.turn.up.right.diamond"
        }
    }

    /// nil when the chip has a real backend. Otherwise the line shown in place of pins.
    var unavailableMessage: String? {
        switch self {
        case .friends:  nil
        case .places:   "Saved places aren't available yet."
        case .hangouts: "Hangouts aren't available yet."
        case .move:     "Moves appear on a friend's card when they're travelling."
        }
    }
}

/// A destination in an active Move.
struct MapPlace: Hashable {
    var name: String = "Central Market"
    var address: String = "87 Market St, Toronto"
}

/// A live journey toward someone.
///
/// KEPT AS A UI MARKER ONLY. The real journey lives in `MapMoveEngine` (`MapMoveInbound` /
/// `MapMoveOutbound`) and is rendered by `MapMoveScreen`. This struct survives because the
/// reference screen's `store.move` is what drives its Move navigation; nothing reads its
/// literal ETA/progress fields any more.
struct MoveSession: Hashable {
    var friend: MapFriend
    var place = MapPlace()
    var etaMinutes: Int = 12
    var arrivalTime: String = "7:53 PM"
    /// 0…1.
    var progress: Double = 0.6
    var remainingKm: Double = 1.4
    var mode: String = "Walking"
    var isSharingLive: Bool = true

    var progressText: String { "\(Int(progress * 100))%" }
}

/// What the friends list is doing right now.
///
/// Loading / empty / failed must be three distinguishable things: "no one is sharing with
/// you" is a normal, correct, permanent-feeling state, and "we couldn't load" is a fault.
/// Collapsing them into one empty view tells a user their friends abandoned them when in
/// fact the socket dropped.
enum MapFeedState: Equatable {
    /// Engine restoring from the keychain-backed store, or the socket has not settled.
    case loading
    /// At least one person is on the map.
    case loaded
    /// Loaded fine, nobody is sharing with us.
    case empty
    /// The engine reported a failure. Carries its message verbatim.
    case failed(String)
}

// MARK: - Store

/// The map's state, shared across the four screens of the flow.
///
/// An object rather than per-screen `@State`: the privacy choice made in step 2 has to be the
/// same choice the map badge reads in step 3, and a copy in each screen is how those two end
/// up disagreeing about whether the user is visible.
///
/// NOW A LIVE ADAPTER. It subscribes to the engines on `start()` and republishes them in the
/// shape the reference screen already reads. It owns no location state of its own and
/// persists nothing.
@Observable
@MainActor
final class MapStore {

    // MARK: Engine-derived, read-only

    var friends: [MapFriend] = []
    var feedState: MapFeedState = .loading
    /// My own last coarse fix as the SHARING provider knows it. nil while ghosted — the
    /// provider is stopped, so no fix is taken for sharing purposes at all. That is the hard
    /// gate and it stays.
    ///
    /// This is NO LONGER what draws the "You" pin. It used to be, which meant Ghost Mode hid
    /// the user from themselves: the pin vanished and "Centre on me" had nothing to centre
    /// on. The pin now comes from MapKit's own `UserAnnotation`, driven by MapKit's separate
    /// CoreLocation session — see FriendsMapScreen. What remains here is distance maths to
    /// friends, which genuinely should stop while ghosted (it is derived from a fix we are
    /// deliberately not taking).
    var myCoordinate: CLLocationCoordinate2D?
    /// How many people I am currently visible to. Drives the header's status line.
    var audienceCount: Int = 0

    /// Mirrors `MapVisibilityState`. Only `.ghost` / `.selected` are ever assigned — see the
    /// enum's note on why the other two cases exist but are unreachable.
    var audience: MapAudience = .ghost
    var window: ShareWindow = .oneHour
    var hasLocationPermission = false

    /// The RAW iOS authorization, not just the granted/not-granted boolean above.
    ///
    /// WHY both: `hasLocationPermission` answers "can we emit?", which is all the engine
    /// cares about. The map needs a finer answer, because "we have never asked" and "you
    /// said no" are different sentences with different remedies — one is a prompt, the other
    /// is a trip to Settings — and a map that shows neither your pin nor a reason is the bug
    /// this exists to prevent. `MapPrivacyScreen` already makes exactly this distinction;
    /// this republishes the same source (`MapLocationProvider.authorization`) rather than
    /// inventing a second notion of it.
    var locationAuthorization: CLAuthorizationStatus = .notDetermined

    // MARK: Screen-local UI state (genuinely the screen's, not the engine's)

    /// Whether the intro and privacy steps have been completed. Drives which screen the tab
    /// opens on.
    var hasOnboarded = false
    var filter: MapFilter = .friends
    /// Who is open in the bottom card, if anyone.
    var selected: MapFriend?
    /// The active journey, if any. A marker that the Move screen should be pushed — the real
    /// journey data comes from MapMoveEngine.
    var move: MoveSession?

    // MARK: Derived

    /// Visible means the engine is actually emitting: not ghosted, AND authorised. Both, not
    /// either — an authorised-but-ghosted device sends nothing, and so does a non-ghosted
    /// device with no permission.
    var isVisible: Bool { audience.isVisible && hasLocationPermission }

    /// A one-line summary of the current privacy state, for the map's header.
    ///
    /// Real counts, not a stored label: "Visible to 3" is checkable by the user against the
    /// audience sheet, where "Only Selected Friends · 1 hour" was a promise the mock made.
    var statusText: String {
        guard isVisible else { return "Ghost Mode · hidden" }
        if audienceCount == 0 { return "Visible · no one added yet" }
        return audienceCount == 1 ? "Visible to 1 person" : "Visible to \(audienceCount) people"
    }

    /// What the pins should be for the current chip. Only Friends has data; every other chip
    /// draws nothing and the screen shows that chip's `unavailableMessage` instead.
    var visibleFriends: [MapFriend] {
        filter == .friends ? friends : []
    }

    /// Where to point the camera, in descending order of honesty:
    ///   1. my own last coarse fix,
    ///   2. failing that, the centroid of whoever is on the map — better to frame the people
    ///      than an arbitrary city,
    ///   3. failing that, a neutral default. Toronto is kept from the reference purely so the
    ///      screen has *somewhere* to sit before any data arrives; it is never shown with a
    ///      "you" pin on it, because `myCoordinate` being nil is exactly this case.
    var centre: CLLocationCoordinate2D {
        if let myCoordinate { return myCoordinate }
        if !friends.isEmpty {
            let lat = friends.map(\.coordinate.latitude).reduce(0, +) / Double(friends.count)
            let lon = friends.map(\.coordinate.longitude).reduce(0, +) / Double(friends.count)
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return Self.fallbackCentre
    }

    /// Neutral pre-data camera position. See `centre`.
    static let fallbackCentre = CLLocationCoordinate2D(latitude: 43.6487, longitude: -79.3817)

    // MARK: Wiring

    @ObservationIgnored private var bag = Set<AnyCancellable>()
    @ObservationIgnored private var started = false

    /// Subscribe to the engines. Idempotent — the screen calls it from `onAppear`, which fires
    /// again on every return to the tab.
    func start() {
        guard !started else { refresh(); return }
        started = true

        let engine = MapPresenceEngine.shared
        let visibility = MapVisibilityState.shared
        let provider = MapLocationProvider.shared
        let moves = MapMoveEngine.shared
        let directory = UserDirectory.shared

        // One recompute for every source that can change what the map shows. Merged rather
        // than handled separately because the outputs are interdependent — a new fix of MINE
        // changes every friend's distance text, and a directory update renames pins.
        Publishers.MergeMany(
            engine.objectWillChange.eraseToAnyPublisher(),
            visibility.objectWillChange.eraseToAnyPublisher(),
            provider.objectWillChange.eraseToAnyPublisher(),
            moves.objectWillChange.eraseToAnyPublisher(),
            directory.objectWillChange.eraseToAnyPublisher()
        )
        // objectWillChange fires BEFORE the value lands, so read on the next tick.
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.refresh() }
        .store(in: &bag)

        refresh()
    }

    /// Pull the current truth out of the engines. Pure read — no engine method is called.
    func refresh() {
        let engine = MapPresenceEngine.shared
        let visibility = MapVisibilityState.shared
        let provider = MapLocationProvider.shared
        let moves = MapMoveEngine.shared
        let directory = UserDirectory.shared

        locationAuthorization = provider.authorization
        hasLocationPermission = provider.authorization == .authorizedWhenInUse
            || provider.authorization == .authorizedAlways
        // Only the two reachable cases — see MapAudience's note.
        audience = visibility.isEffectivelyGhosted ? .ghost : .selected
        audienceCount = engine.audience.count
        myCoordinate = provider.lastFix?.coordinate

        // Only people whose fix is fresh enough to draw. An aged-out pin is a lie about where
        // someone is, so the engine's own freshness verdict is the filter — the away strip is
        // where those people belong, not the map.
        let live = engine.presences.filter {
            let s = MapPresenceState.forFix(at: $0.fixedAt)
            return s == .live || s == .stale
        }

        friends = live
            .map { p in
                MapFriend(
                    id: p.senderUserId,
                    name: directory.displayName(p.senderUserId),
                    coordinate: p.coordinate,
                    lastSeen: MapFormatters.relativeAge(p.fixedAt),
                    distanceText: MapFormatters.distanceText(from: provider.lastFix,
                                                             to: p.coordinate),
                    isFavourite: false,                 // no favourites concept — see the note
                    isMoving: moves.move(from: p.senderUserId) != nil)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Keep the open card pointing at the SAME person's latest fix rather than a snapshot
        // taken when they were tapped — otherwise the card freezes while the pin moves.
        if let sel = selected {
            selected = friends.first { $0.id == sel.id }
        }

        // Three distinguishable states, in priority order.
        //
        //  failed  — the engine reported a fault. It wins over an empty list, because the
        //            fault is WHY the list is empty; telling someone "no friends are sharing"
        //            when the socket dropped is a lie about their friends.
        //  loading — nobody drawable YET, but we know at least one person has us in their
        //            audience (`inboundSenders`), so a fix is genuinely on its way. The
        //            engine restores synchronously from its store at init, so there is no
        //            spinner-before-first-read phase; this is the only true loading case.
        //  empty   — nobody has us in their audience at all. A correct, settled answer.
        if let err = engine.lastError {
            feedState = .failed(err)
        } else if !friends.isEmpty {
            feedState = .loaded
        } else if !engine.inboundSenders.isEmpty {
            feedState = .loading
        } else {
            feedState = .empty
        }
    }

    // MARK: Intent — the only things this adapter asks the engine to DO

    func startMove(with friend: MapFriend) {
        move = MoveSession(friend: friend)
    }

    func endMove() { move = nil }
}

// MARK: - Map style

/// The three MapKit base styles the Map offers, plus the persistence key both entry points
/// (the map's layers control and Map settings) read.
///
/// WHY AN ENUM AND NOT A RAW `MapStyle`: `MapStyle` is opaque, not `Equatable` and not
/// `RawRepresentable`, so it can be neither compared for a checkmark nor written to
/// `@AppStorage`. This enum is the storable identity; `mapStyle` is the only place it turns
/// into the real thing, so the two entry points can never render different maps.
///
/// WHY ONLY THREE: these are MapKit's actual base styles. `.imagery` and `.hybrid` are the
/// same tiles with and without labels; anything beyond that would be a name for a style
/// MapKit does not have.
enum VoiidMapStyle: String, CaseIterable, Identifiable {
    case standard, hybrid, satellite

    var id: String { rawValue }

    /// The `@AppStorage` key. Declared here so no call site spells the string itself.
    static let storageKey = "voiid.map.style"

    var title: String {
        switch self {
        case .standard:  "Standard"
        case .hybrid:    "Hybrid"
        case .satellite: "Satellite"
        }
    }

    var icon: String {
        switch self {
        case .standard:  "map"
        case .hybrid:    "globe.americas"
        case .satellite: "globe"
        }
    }

    var mapStyle: MapStyle {
        switch self {
        // POINTS OF INTEREST STAY EXCLUDED ON STANDARD, DELIBERATELY. Café and shop pins
        // compete with the friend faces this map exists to show — the friends are the
        // content, and MapKit's own POI markers are the same size and shape as our pins.
        // The imagery styles carry no POI parameter, so there is nothing to exclude there.
        case .standard:  .standard(pointsOfInterest: .excludingAll)
        case .hybrid:    .hybrid
        case .satellite: .imagery
        }
    }
}
