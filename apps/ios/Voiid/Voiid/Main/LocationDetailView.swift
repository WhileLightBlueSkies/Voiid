//
//  LocationDetailView.swift
//  Voiid
//
//  Full-screen detail for a location message (docs/LOCATION.md §4): the map, Open in Maps
//  (system handoff), and Directions. There is NO in-app routing and NO reverse-geocoding
//  to a street address (§10) — we hand off to the system map app, which keeps the
//  coordinate off any geocoder we control.
//
//  LIVE, not a snapshot. This view used to take a single `coordinate` and render it forever,
//  so a friend walking across town stayed pinned wherever they were when the sheet opened —
//  the fix stream was arriving the whole time and only the bubble showed it. It now observes
//  `LocationShareEngine` (whose `version` ticks on every decrypted fix), animates the marker
//  between fixes instead of teleporting it, and follows with the camera until you pan.
//
//  Every sharer in the conversation is drawn on THIS one map: a group where three people are
//  sharing is one map with three faces, not three separate frozen bubbles.
//
//  Nothing here changes cadence, encryption or the background mode — this is presentation
//  over the existing decrypted stream.
//
//  iOS 17+ Map(position:) + Annotation. Deployment target is 18.0, so no availability
//  fallback is required. The map is calm and light: POIs excluded, standard style.
//

import SwiftUI
import MapKit
import Combine

struct LocationDetailView: View {
    /// The coordinate the MESSAGE carried. Used for a static pin, and as the fallback for a
    /// live share whose stream has not produced a fix yet.
    let coordinate: CLLocationCoordinate2D
    var label: String?
    var live: Bool = false
    var state: ShareState = .live
    var shareId: String?
    /// Set for a live share so the map can show every sharer in the same chat (G5).
    var conversationId: String?
    /// Accuracy carried by the message itself, for a static pin with no live fix stream.
    var accuracy: Double?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var engine = LocationShareEngine.shared
    @ObservedObject private var directory = UserDirectory.shared
    @State private var position: MapCameraPosition
    /// The first manual pan hands the camera to the user; the recenter button takes it back.
    @State private var userPanned = false
    /// Ticks the countdown and the "updated Xs ago" line with no network (the timer guarantee).
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(coordinate: CLLocationCoordinate2D, label: String?, live: Bool,
         state: ShareState, shareId: String?, conversationId: String? = nil,
         accuracy: Double? = nil) {
        self.coordinate = coordinate
        self.label = label
        self.live = live
        self.state = state
        self.shareId = shareId
        self.conversationId = conversationId
        self.accuracy = accuracy
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: coordinate, latitudinalMeters: 800, longitudinalMeters: 800)))
    }

    /// One drawable sharer: who they are, where they are now, and how fresh that is.
    private struct Sharer: Identifiable {
        let id: String            // shareId
        let userId: String
        let coordinate: CLLocationCoordinate2D
        let state: ShareState
        let fixedAt: Date?
        let expiresAt: Date?
        /// Device-reported accuracy of this fix, in metres — drives the honesty line.
        let accuracy: Double?
    }

    /// Every still-running sharer in this conversation, newest fix each. Recomputed whenever
    /// the engine's `version` ticks, which is what makes the pins move.
    private var sharers: [Sharer] {
        guard live else { return [] }
        guard let conversationId else { return primarySharer.map { [$0] } ?? [] }
        let rows = LocationStore.activeInbound(conversationId: conversationId)
        let all: [Sharer] = rows.compactMap { row -> Sharer? in
            guard let fix = engine.lastFix(shareId: row.shareId) else { return nil }
            let s = engine.shareState(shareId: row.shareId, expiresAt: row.expiresAt, cadence: row.cadence)
            guard s != .ended else { return nil }
            return Sharer(id: row.shareId, userId: row.ownerUserId,
                          coordinate: CLLocationCoordinate2D(latitude: fix.lat, longitude: fix.lon),
                          state: s, fixedAt: fix.date, expiresAt: row.expiresAt,
                          accuracy: fix.acc)
        }
        // A share opened from MY OWN bubble is outbound and won't be in `activeInbound`; keep
        // the fallback so the sheet is never empty.
        return all.isEmpty ? (primarySharer.map { [$0] } ?? []) : all
    }

    /// The share this bubble opened — drives the header text and the coordinate readout.
    private var primarySharer: Sharer? {
        guard let shareId else { return nil }
        let fix = engine.lastFix(shareId: shareId)
        return Sharer(
            id: shareId,
            userId: "",
            coordinate: fix.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } ?? coordinate,
            state: state,
            fixedAt: fix?.date,
            expiresAt: nil,
            accuracy: fix?.acc ?? accuracy)
    }

    /// What the map is centred on: the live fix when we have one, else the message's own.
    private var focus: CLLocationCoordinate2D {
        sharers.first(where: { $0.id == shareId })?.coordinate ?? sharers.first?.coordinate ?? coordinate
    }

    var body: some View {
        ZStack(alignment: .top) {
            map.ignoresSafeArea()
            header
            controls
        }
        // No colour-scheme pin: Peacock tokens resolve per theme, and a sheet that
        // forced light would be the one bright rectangle in a dark app.
        .onReceive(ticker) { now = $0 }
        // Follow the sharer until the user takes the camera over. `focus` changes on every new
        // fix, so this is what makes the camera track a friend who is walking.
        .onChange(of: focus.latitude) { _, _ in follow() }
        .onChange(of: focus.longitude) { _, _ in follow() }
    }

    private func follow() {
        guard live, !userPanned else { return }
        withAnimation(.easeInOut(duration: 0.8)) {
            position = .region(MKCoordinateRegion(center: focus,
                                                  latitudinalMeters: 800, longitudinalMeters: 800))
        }
    }

    private var map: some View {
        Map(position: $position) {
            if sharers.isEmpty {
                Annotation(label ?? (live ? "Live location" : "Location"), coordinate: coordinate) {
                    staticPin
                }
            } else {
                ForEach(sharers) { s in
                    Annotation(s.userId.isEmpty ? (label ?? "Live location")
                                                : directory.displayName(s.userId),
                               coordinate: s.coordinate) {
                        // A face, not a generic dot — the same marker language as the Map tab.
                        // `.animation` on the coordinate makes the pin GLIDE between fixes
                        // (10–15 s apart) instead of teleporting.
                        MapAvatarPin(userId: s.userId.isEmpty ? nil : s.userId,
                                     name: s.userId.isEmpty ? label : directory.displayName(s.userId),
                                     photoURL: s.userId.isEmpty ? nil : directory.photoURL(s.userId),
                                     state: s.state,
                                     size: 44)
                    }
                }
            }
        }
        // Same skin as the Map tab — `.muted` de-emphasises roads and terrain so the avatar
        // pin is the focus. This screen was missing it, so a live share opened into a busier,
        // more saturated map than the tab it was launched from. MapKit's `.standard` follows
        // the environment colorScheme, which ContentView sets from the user's Light/Dark/System
        // choice, so the tiles theme themselves.
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .animation(.easeInOut(duration: 1.0), value: focus.latitude)
        .animation(.easeInOut(duration: 1.0), value: focus.longitude)
        // Pan detection: a DRAG is unambiguously the user taking the camera over, whereas
        // `onMapCameraChange` also fires for our own programmatic follow moves and would
        // immediately cancel the following it is supposed to protect.
        .simultaneousGesture(DragGesture().onChanged { _ in
            if live && !userPanned { userPanned = true }
        })
    }

    private var staticPin: some View {
        Image(systemName: state == .ended ? "mappin.slash.circle.fill"
                        : (live ? "location.circle.fill" : "mappin.circle.fill"))
            .font(.system(size: 34))
            .foregroundColor(state == .stale ? VoiidColor.textSecondary : VoiidColor.error)
            .shadow(radius: 2)
    }

    private var header: some View {
        HStack(alignment: .top) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold)).foregroundColor(VoiidColor.textPrimary)
                    .padding(10).background(VoiidColor.surfaceCard).clipShape(Circle())
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            }
            Spacer()
            if live {
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle().fill(stateColor).frame(width: 8, height: 8)
                        Text(stateLabel).font(VoiidFont.rounded(12, .semibold)).foregroundColor(VoiidColor.textPrimary)
                    }
                    // WhatsApp's "Live until …" — countdown to expiry + freshness of the fix.
                    if let sub = liveSubtitle {
                        Text(sub).font(VoiidFont.rounded(11)).foregroundColor(VoiidColor.textSecondary)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(VoiidColor.surfaceCard).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            }
        }
        .padding(.horizontal, VoiidSpacing.md).padding(.top, VoiidSpacing.md)
    }

    private var controls: some View {
        VStack {
            Spacer()
            if userPanned && live {
                HStack {
                    Spacer()
                    Button {
                        Haptics.tap()
                        userPanned = false
                        follow()
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(VoiidColor.primary)
                            .padding(12).background(VoiidColor.surfaceCard).clipShape(Circle())
                            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Recenter")
                }
                .padding(.horizontal, VoiidSpacing.lg).padding(.bottom, VoiidSpacing.sm)
            }
            // Honesty line (docs/LOCATION.md §10): the marker is an area, not a doorstep, and
            // someone navigating to a friend needs to know the pin carries a radius.
            Text(LocationAccuracy.note(sharers.first(where: { $0.id == shareId })?.accuracy
                                       ?? primarySharer?.accuracy ?? accuracy))
                .font(VoiidFont.rounded(11))
                .foregroundColor(VoiidColor.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(VoiidColor.surfaceCard.opacity(0.92))
                .clipShape(Capsule())
                .padding(.bottom, VoiidSpacing.sm)
            HStack(spacing: VoiidSpacing.md) {
                actionButton("Open in Maps", "map.fill") { open(directions: false) }
                actionButton("Directions", "arrow.triangle.turn.up.right.circle.fill") { open(directions: true) }
            }
            .padding(.horizontal, VoiidSpacing.lg).padding(.bottom, VoiidSpacing.xl)
        }
    }

    private func actionButton(_ title: String, _ icon: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: { Haptics.tap(); tap() }) {
            Label(title, systemImage: icon)
                .font(VoiidFont.rounded(15, .semibold)).foregroundColor(VoiidColor.textOnPrimary)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(VoiidColor.primary).clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// "ends in 43m · updated 4s ago" — recomputed each tick of `now`.
    private var liveSubtitle: String? {
        guard live else { return nil }
        if state == .ended { return nil }
        var parts: [String] = []
        if let expires = sharers.first(where: { $0.id == shareId })?.expiresAt, expires > now {
            parts.append("ends in \(Self.duration(expires.timeIntervalSince(now)))")
        }
        if state == .stale {
            parts.append("may have lost signal")
        } else if let fixedAt = sharers.first(where: { $0.id == shareId })?.fixedAt
                    ?? primarySharer?.fixedAt {
            parts.append("updated \(Self.age(now.timeIntervalSince(fixedAt)))")
        } else {
            parts.append("waiting for first fix")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func duration(_ t: TimeInterval) -> String {
        let mins = max(0, Int(t) / 60)
        return mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"
    }

    private static func age(_ t: TimeInterval) -> String {
        let secs = max(0, Int(t))
        switch secs {
        case ..<10: return "just now"
        case ..<60: return "\(secs)s ago"
        case ..<3600: return "\(secs / 60)m ago"
        default: return "\(secs / 3600)h ago"
        }
    }

    private var stateColor: Color {
        switch state { case .live: return VoiidColor.success
                       case .stale: return VoiidColor.warning
                       case .ended: return VoiidColor.textSecondary }
    }
    private var stateLabel: String {
        switch state { case .live: return "Live"; case .stale: return "May have lost signal"; case .ended: return "Ended" }
    }

    /// System handoff — no in-app routing. Opens Apple Maps at the coordinate.
    private func open(directions: Bool) {
        let target = focus
        let placemark = MKPlacemark(coordinate: target)
        let item = MKMapItem(placemark: placemark)
        item.name = label ?? (live ? "Live location" : "Shared location")
        item.openInMaps(launchOptions: directions
            ? [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving] : nil)
    }
}
