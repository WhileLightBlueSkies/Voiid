//
//  MapMoveScreen.swift
//  Voiid
//
//  Feature (B), Move — "someone is on their way to you", seen from the VIEWER's side.
//
//  ── THE LIVE SHARE TOGGLE IS AT THE BOTTOM AND IT IS A REAL SWITCH ────────────────────
//  Everything above it is read-only status. The one control on this screen that changes what
//  another person can see is a switch, labelled with exactly what it does, positioned where a
//  thumb rests. Turning off your own live sharing mid-journey should take one tap and no
//  hunting — so it is bound to the real Map visibility gate (`MapPresenceEngine`), not to a
//  local flag that merely looks like one.
//
//  ── EVERY NUMBER ON THIS SCREEN IS MEASURED, OR IT IS ABSENT ──────────────────────────
//  The ETA is the traveller's own MKDirections result, sent as an ABSOLUTE arrival instant, so
//  this screen counts it down against its own clock and is right at every frame even if the
//  last frame is minutes old. When the traveller's device has not produced a route yet, `eta`
//  is nil on the wire and this screen says "Calculating" and hides the progress bar entirely.
//  There is deliberately no straight-line fallback: a fabricated ETA is the one failure that
//  is worse than no ETA, because someone plans around it.
//
//  The three states are visually distinct, not one shrugging placeholder:
//    - no Move   → the contact is on the map but not travelling to anywhere they've shared
//    - waiting   → Move received, ETA still being measured on their device
//    - unroutable→ we have a destination and no arrival time, and we say so
//

import SwiftUI
import MapKit
import Combine

struct MapMoveScreen: View {

    /// The contact whose journey this is.
    let senderUserId: String

    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var engine = MapPresenceEngine.shared
    @ObservedObject private var moves = MapMoveEngine.shared
    @ObservedObject private var visibility = MapVisibilityState.shared
    @ObservedObject private var directory = UserDirectory.shared

    @State private var camera: MapCameraPosition = .automatic
    /// Ticks once a second so the countdown and the progress bar advance between frames. The
    /// ETA is absolute, so this is pure local arithmetic — it sends nothing and asks nothing.
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var move: MapMoveInbound? { moves.move(from: senderUserId) }
    private var presence: MapPresence? {
        engine.presences.first { $0.senderUserId == senderUserId }
    }
    private var name: String { directory.displayName(senderUserId) }
    private var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }

    var body: some View {
        ZStack {
            VoiidColor.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                if let move {
                    statusChips(move)

                    ScrollView {
                        VStack(spacing: VoiidSpacing.md) {
                            routeMap(move)
                            destination(move)
                            progress(move)
                            quickActions(move)
                            liveShare
                            footnote
                        }
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.top, VoiidSpacing.md)
                    }
                    .scrollIndicators(.hidden)
                    .contentMargins(.bottom, 96, for: .scrollContent)
                } else {
                    noMove
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onReceive(clock) { now = $0 }
        // The journey ending is a real event, not an empty screen: the sender simply stops
        // attaching Move fields, `MapMoveEngine` clears the entry, and this falls through to
        // the "no longer travelling" state below rather than dismissing under the user.
        .onAppear { session.hideTabBar = true }
        .onDisappear { session.hideTabBar = false }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Button {
                Haptics.tap()
                dismiss()
            } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to map")

            Spacer(minLength: 0)

            VStack(spacing: 1) {
                HStack(spacing: 5) {
                    Text(name)
                        .font(VoiidFont.rounded(16.5, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                        .lineLimit(1)

                    // Green only while their position is genuinely fresh. A dot that is always
                    // green is a dot that means nothing.
                    Circle()
                        .fill(isLive ? VoiidColor.success : VoiidColor.textSecondary)
                        .frame(width: 8, height: 8)
                }

                Text(move == nil ? "Not travelling" : (isLive ? "Moving to you" : "Signal lost"))
                    .font(VoiidFont.rounded(11.5))
                    .foregroundColor(VoiidColor.textSecondary)
            }

            Spacer(minLength: 0)

            // No "End Move" here: this is the VIEWER's screen, and a viewer cannot end someone
            // else's journey. The only thing they own is their own sharing, which is the switch
            // at the bottom of the scroll.
            Color.clear.frame(width: 34, height: 34)
        }
        .padding(.horizontal, VoiidSpacing.sm)
        .padding(.top, VoiidSpacing.sm)
    }

    private var isLive: Bool {
        guard let presence else { return false }
        return MapPresenceState.forFix(at: presence.fixedAt, now: now) == .live
    }

    // MARK: Status chips

    /// Distance and freshness. Both are derived from data we actually hold — there is no
    /// battery chip, because a peer's battery level is not on this wire and inventing one
    /// would be the exact kind of comfortable fiction this screen exists to avoid.
    private func statusChips(_ move: MapMoveInbound) -> some View {
        HStack(spacing: 8) {
            chip("point.topleft.down.curvedto.point.bottomright.up", crowFliesText(move))
            chip("clock.arrow.circlepath", freshnessText)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.sm)
    }

    private func crowFliesText(_ move: MapMoveInbound) -> String {
        guard let presence else { return "Locating…" }
        return Self.distanceText(move.directMetres(from: presence.coordinate)) + " to go"
    }

    private var freshnessText: String {
        guard let presence else { return "No fix yet" }
        let age = now.timeIntervalSince(presence.fixedAt)
        if age < 90 { return "Updated just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "Updated \(f.localizedString(for: presence.fixedAt, relativeTo: now))"
    }

    private func chip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
            Text(text)
                .font(VoiidFont.rounded(12.5, .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundColor(VoiidColor.textPrimary)
        .padding(.horizontal, 11)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(VoiidColor.surfaceCard))
        .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))
    }

    // MARK: Route map

    /// Their live face and the destination flag. No route line is drawn: we hold no route on
    /// this side (the traveller measured it on theirs), and a straight line between the two
    /// pins would read as a path they are not taking.
    private func routeMap(_ move: MapMoveInbound) -> some View {
        Map(position: $camera, interactionModes: []) {
            if let presence {
                Annotation(name, coordinate: presence.coordinate) {
                    MapAvatarPin(userId: senderUserId,
                                 name: name,
                                 photoURL: directory.photoURL(senderUserId),
                                 state: isLive ? .live : .stale,
                                 size: 46)
                }
            }
            Annotation(move.name ?? "Destination", coordinate: move.destination) {
                Image(systemName: "flag.fill")
                    .font(.system(size: 15))
                    .foregroundColor(VoiidColor.textOnAccent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(VoiidColor.accent))
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1)
        )
        .allowsHitTesting(false)
        // Reframe whenever either end moves, so the pair stays in shot as they close in.
        .onChange(of: presence?.coordinate.latitude) { _, _ in frame(move) }
        .onAppear { frame(move) }
    }

    /// Fit both pins with margin. Falls back to the destination alone when we hold no position
    /// for them yet.
    private func frame(_ move: MapMoveInbound) {
        guard let presence else {
            camera = .region(MKCoordinateRegion(center: move.destination,
                                                latitudinalMeters: 1200,
                                                longitudinalMeters: 1200))
            return
        }
        let centre = CLLocationCoordinate2D(
            latitude: (presence.coordinate.latitude + move.destination.latitude) / 2,
            longitude: (presence.coordinate.longitude + move.destination.longitude) / 2)
        let latSpan = abs(presence.coordinate.latitude - move.destination.latitude) * 2.2
        let lonSpan = abs(presence.coordinate.longitude - move.destination.longitude) * 2.2
        withAnimation(.easeInOut(duration: 0.5)) {
            camera = .region(MKCoordinateRegion(
                center: centre,
                span: MKCoordinateSpan(latitudeDelta: max(latSpan, 0.006),
                                       longitudeDelta: max(lonSpan, 0.006))))
        }
    }

    // MARK: Destination

    private func destination(_ move: MapMoveInbound) -> some View {
        HStack(spacing: VoiidSpacing.sm + 2) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(VoiidColor.accentInk)

            VStack(alignment: .leading, spacing: 1) {
                // The traveller's own words for the place. We never reverse-geocode their
                // coordinate to invent a name (§10) — an unnamed destination stays unnamed.
                Text(move.name ?? "Shared destination")
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)
                if let address = move.address {
                    Text(address)
                        .font(VoiidFont.rounded(12))
                        .foregroundColor(VoiidColor.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Button("View place") {
                Haptics.tap()
                let item = MKMapItem(placemark: MKPlacemark(coordinate: move.destination))
                item.name = move.name ?? "Destination"
                item.openInMaps()
            }
            .font(VoiidFont.rounded(13, .semibold))
            .foregroundColor(VoiidColor.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Capsule().fill(VoiidColor.surfaceCard))
            .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))
            .buttonStyle(.plain)
        }
        .padding(VoiidSpacing.md - 2)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1)
        )
    }

    // MARK: Progress

    private func progress(_ move: MapMoveInbound) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ETA")
                    .font(VoiidFont.rounded(11.5))
                    .foregroundColor(VoiidColor.textSecondary)

                if let minutes = move.minutesRemaining(now: now) {
                    Text(minutes == 0 ? "Arriving" : "\(minutes) min")
                        .font(VoiidFont.rounded(24, .bold))
                        .foregroundColor(VoiidColor.textPrimary)
                        // Counts down as the journey advances, so it ticks rather than jumps.
                        .contentTransition(.numericText())

                    Text("Arriving at \(Self.clockText(move.arrivalAt ?? now))")
                        .font(VoiidFont.rounded(11.5))
                        .foregroundColor(VoiidColor.textSecondary)
                } else {
                    // WAITING, not failed. Their device has the Move but MKDirections has not
                    // answered yet — a visually distinct state, and never a placeholder number.
                    Text("Calculating")
                        .font(VoiidFont.rounded(20, .bold))
                        .foregroundColor(VoiidColor.textSecondary)
                    Text("Waiting for \(firstName)'s route")
                        .font(VoiidFont.rounded(11.5))
                        .foregroundColor(VoiidColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: VoiidSpacing.md)

            Rectangle()
                .fill(VoiidColor.divider)
                .frame(width: 1, height: 62)

            VStack(alignment: .leading, spacing: 3) {
                Text("Arrival progress")
                    .font(VoiidFont.rounded(11.5))
                    .foregroundColor(VoiidColor.textSecondary)

                if let fraction = move.progress(now: now) {
                    Text("\(Int(fraction * 100))%")
                        .font(VoiidFont.rounded(24, .bold))
                        .foregroundColor(VoiidColor.accentInk)
                        .contentTransition(.numericText())

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(VoiidColor.divider)
                            Capsule()
                                .fill(VoiidColor.accent)
                                .frame(width: geo.size.width * fraction)
                        }
                    }
                    .frame(height: 4)
                } else {
                    // NO ETA MEANS NO BAR. A progress bar with nothing behind it is the most
                    // convincing lie this screen could tell, so it is simply not drawn.
                    Text("—")
                        .font(VoiidFont.rounded(24, .bold))
                        .foregroundColor(VoiidColor.textSecondary)
                    Color.clear.frame(height: 4)
                }

                if let presence {
                    Text(Self.distanceText(move.directMetres(from: presence.coordinate))
                         + " as the crow flies")
                        .font(VoiidFont.rounded(11))
                        .foregroundColor(VoiidColor.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    Text("Position not in yet")
                        .font(VoiidFont.rounded(11))
                        .foregroundColor(VoiidColor.textSecondary)
                }
            }
            .padding(.leading, VoiidSpacing.md)
        }
        .padding(VoiidSpacing.md)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1)
        )
    }

    // MARK: Quick actions

    /// Only actions that do something real. "Notify on arrival" is absent because it would
    /// need a background wake this feature does not have — a toggle that quietly never fires
    /// is worse than no toggle.
    private func quickActions(_ move: MapMoveInbound) -> some View {
        HStack(spacing: 8) {
            quickAction("arrow.triangle.turn.up.right.circle", "Directions") {
                let item = MKMapItem(placemark: MKPlacemark(coordinate: move.destination))
                item.name = move.name ?? "Destination"
                item.openInMaps(launchOptions: [
                    MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
            }
            quickAction("square.and.arrow.up", "Share ETA") {
                shareETA(move)
            }
        }
    }

    /// Shares the ARRIVAL TIME as text, not the destination coordinate — passing a friend's
    /// destination out of the encrypted envelope into an arbitrary app would undo the whole
    /// point of carrying it in there.
    private func shareETA(_ move: MapMoveInbound) {
        let text: String
        if let minutes = move.minutesRemaining(now: now), let at = move.arrivalAt {
            text = "\(name) is arriving at \(Self.clockText(at)) (about \(minutes) min)."
        } else {
            text = "\(name) is on their way — arrival time not available yet."
        }
        let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController?.present(av, animated: true)
    }

    private func quickAction(_ icon: String, _ title: String,
                             _ tap: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            tap()
        } label: {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(VoiidColor.accentInk)

                Text(title)
                    .font(VoiidFont.rounded(11.5, .medium))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .stroke(VoiidColor.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Live share — the one real control on this screen

    /// Bound to the ACTUAL Map visibility gate, not a decorative flag. Turning it off enters
    /// Ghost Mode: the provider stops, the key rotates, and the audience gets a durable
    /// `map_off`. That is the honest meaning of "stop letting them see me", and it is one tap
    /// from under the thumb.
    private var liveShare: some View {
        Toggle(isOn: Binding(
            get: { visibility.isVisible },
            set: { on in
                Haptics.selection()
                Task {
                    if on { await MapPresenceEngine.shared.leaveGhost() }
                    else { await MapPresenceEngine.shared.enterGhost(.untilOff) }
                }
            })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Share your live movement")
                    .font(VoiidFont.rounded(14.5, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)

                Text(visibility.isVisible
                     ? "\(firstName) and everyone on your Map list can see where you are."
                     : "Ghost Mode is on — nobody can see you, and no location is taken.")
                    .font(VoiidFont.rounded(12))
                    .foregroundColor(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(VoiidColor.accent)
        .padding(VoiidSpacing.md)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1)
        )
    }

    private var footnote: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
            Text("End-to-end encrypted — the destination and ETA never reach our servers")
                .font(VoiidFont.rounded(11.5))
                .multilineTextAlignment(.center)
        }
        .foregroundColor(VoiidColor.textSecondary)
        .padding(.top, 2)
    }

    // MARK: No-move state

    /// Visually distinct from both "calculating" and an error: nothing is wrong, there is
    /// simply no journey. Reached both on open (they were never travelling) and mid-session
    /// (they arrived and their fixes stopped carrying a destination).
    private var noMove: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Spacer()
            Image(systemName: "figure.walk.motion")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(VoiidColor.textSecondary)
            Text("\(firstName) isn’t travelling")
                .font(VoiidFont.rounded(17, .semibold))
                .foregroundColor(VoiidColor.textPrimary)
            Text("When they share a destination with you, their route and ETA appear here.")
                .font(VoiidFont.rounded(13))
                .foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, VoiidSpacing.xl)
            Spacer()
        }
    }

    // MARK: Formatting

    private static func clockText(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Metres under a kilometre, one decimal above — matching how the rest of the location
    /// surface reads distance.
    static func distanceText(_ metres: CLLocationDistance) -> String {
        metres < 1000 ? "\(Int(metres.rounded())) m"
                      : String(format: "%.1f km", metres / 1000)
    }
}
