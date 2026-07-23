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
//  MapKit only (no dependency; `import MapKit` auto-links). The app is pinned to light, so
//  the standard light map with POIs excluded is the calm, on-brand surface. No background
//  location for the Map ever — so no blue system pill is expected here; if one appears, it
//  is a bug (§8).
//

import SwiftUI
import MapKit

struct MapTabView: View {
    @EnvironmentObject var session: AppSession
    @ObservedObject private var engine = MapPresenceEngine.shared
    @ObservedObject private var visibility = MapVisibilityState.shared
    @ObservedObject private var directory = UserDirectory.shared

    @State private var camera: MapCameraPosition = .automatic
    @State private var showAudiencePicker = false
    @State private var showAudienceList = false
    @State private var showGhostOptions = false
    @State private var showExplainer = false

    @AppStorage("voiid.map.seenExplainer") private var seenExplainer = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                map
                    .ignoresSafeArea(edges: .bottom)

                VStack(spacing: VoiidSpacing.sm) {
                    visibilityPill
                    if !awayContacts.isEmpty || !waitingContacts.isEmpty {
                        awayStrip
                    }
                    Spacer()
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.top, VoiidSpacing.sm)
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

    private var liveContacts: [MapPresence] {
        engine.presences.filter {
            let s = MapPresenceState.forFix(at: $0.fixedAt)
            return s == .live || s == .stale
        }
    }

    private var map: some View {
        Map(position: $camera) {
            ForEach(liveContacts) { p in
                Annotation(directory.displayName(p.senderUserId), coordinate: p.coordinate) {
                    contactMarker(p)
                }
            }
            if visibility.isVisible { UserAnnotation() }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls { MapUserLocationButton(); MapCompass() }
    }

    private func contactMarker(_ p: MapPresence) -> some View {
        let stale = MapPresenceState.forFix(at: p.fixedAt) == .stale
        return VStack(spacing: 2) {
            ProfileAvatarButton(photoURL: directory.photoURL(p.senderUserId),
                                name: directory.displayName(p.senderUserId), size: 44)
                .overlay(Circle().stroke(stale ? VoiidColor.textSecondary : VoiidColor.primary,
                                         lineWidth: 2))
                .saturation(stale ? 0.25 : 1)
                .opacity(stale ? 0.75 : 1)
            if stale {
                Text(relativeAge(p.fixedAt))
                    .font(VoiidFont.rounded(10, .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(VoiidColor.surfaceCard))
                    .foregroundColor(VoiidColor.textSecondary)
            }
        }
        .accessibilityLabel("\(directory.displayName(p.senderUserId))\(stale ? ", last seen \(relativeAge(p.fixedAt))" : "")")
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
