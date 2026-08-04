//
//  LocationComposeSheet.swift
//  Voiid
//
//  Compose a location to send into a conversation (docs/LOCATION.md §4, §8). Two modes:
//   • Pin  — one-off coordinate + an optional user-typed label (NEVER geocoded).
//   • Live — time-bounded sharing, 15 min / 1 hour / 8 hours (no indefinite option).
//
//  The audience is named EXPLICITLY above the duration picker, so nobody shares live
//  location without seeing exactly who will receive it. Authorization is requested here,
//  in-context, at the moment of first share — never at onboarding: WhenInUse when the
//  sheet opens, escalating to Always only when a duration > 15 min is chosen.
//

import SwiftUI
import MapKit
import CoreLocation

struct LocationComposeSheet: View {
    let conversationTitle: String
    let isGroup: Bool
    /// How many people will see it (group member count minus you, or 1 for a 1:1).
    let audienceCount: Int

    /// Send a static pin with an optional label.
    /// Label, and the coordinate the user placed. A nil coordinate means "wherever I am now"
    /// — the map never reported a camera, so fall back to a live fix.
    var onSendPin: (String?, CLLocationCoordinate2D?) -> Void
    /// Start a live share for the chosen duration.
    var onStartLive: (ShareDuration) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var engine = LocationShareEngine.shared

    enum Mode { case pin, live }
    @State private var mode: Mode = .pin
    /// The picker map's camera. Starts on the user so the common case — "here" — needs no
    /// panning at all.
    @State private var pickerCamera: MapCameraPosition = .automatic
    /// Set once, on appear: `.automatic` with no annotations frames the entire globe, which
    /// is a useless starting point for placing a pin.
    @State private var didCentrePicker = false
    /// The coordinate under the crosshair. Nil until the map reports a camera, at which point
    /// `commit` prefers it over a fresh one-shot fix.
    @State private var pickedCoordinate: CLLocationCoordinate2D?
    /// ~600 m across: close enough to place a pin on a building, wide enough to orient.
    private let pickerSpan = MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
    @State private var label = ""
    @State private var duration: ShareDuration = .oneHour
    @State private var sending = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                    modePicker
                    if mode == .pin { pinSection } else { liveSection }
                    if deniedForBackground { backgroundDeniedNote }
                }
                .padding(VoiidSpacing.lg)
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Share location").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(mode == .pin ? "Send" : "Share") { commit() }
                        .fontWeight(.semibold).disabled(sending || !authorizedEnough)
                }
            }
            .onAppear {
                // In-context WhenInUse prompt the moment the user reaches for location.
                if engine.authorizationStatus == .notDetermined { engine.requestWhenInUse() }
            }
        }
        // No colour-scheme pin: Peacock tokens resolve per theme, and a sheet that
        // forced light would be the one bright rectangle in a dark app.
        .tint(VoiidColor.primary)
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            Text("Pin").tag(Mode.pin)
            Text("Live").tag(Mode.live)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Pin

    private var pinSection: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            // THE MAP, which was missing entirely.
            //
            // The sheet only ever offered "send your current location" — so you could not
            // send where you are MEETING someone, only where you happened to be standing,
            // which is most of what a location pin is actually for.
            //
            // The pin is FIXED AT THE CENTRE and the map moves under it, rather than a marker
            // you drag. That is what WhatsApp, Uber and Google Maps all do, for a good
            // reason: a dragged marker sits under your thumb at the moment you place it, so
            // you cannot see what you are choosing. A fixed crosshair stays visible while the
            // map pans beneath.
            ZStack {
                Map(position: $pickerCamera)
                    .mapStyle(.standard(emphasis: .muted))
                    .onMapCameraChange(frequency: .onEnd) { ctx in
                        pickedCoordinate = ctx.camera.centerCoordinate
                    }

                // The crosshair. Sits slightly high so the pin's POINT is at the centre —
                // centring the whole glyph would put the tip below the position it marks.
                Image(systemName: "mappin")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(VoiidColor.error)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                    .offset(y: -15)
                    .allowsHitTesting(false)

                // Recentre on the user. Panning away and losing yourself is the one thing a
                // picker must let you undo.
                Button {
                    Haptics.tap()
                    // The Map provider already holds a recent coarse fix, so recentring costs
                    // no new location request.
                    if let here = MapLocationProvider.shared.lastFix?.coordinate {
                        withAnimation { pickerCamera = .region(.init(center: here, span: pickerSpan)) }
                    }
                } label: {
                    Image(systemName: "location.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(VoiidColor.primary)
                        .frame(width: 36, height: 36)
                        .background(VoiidColor.surfaceCard, in: Circle())
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(VoiidSpacing.sm)
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            .onAppear {
                guard !didCentrePicker else { return }
                didCentrePicker = true
                // Centre on the user, and ask for a fresh fix if we have none — otherwise the
                // picker opens on the whole world and every pin starts with a hunt.
                if let here = MapLocationProvider.shared.lastFix?.coordinate {
                    pickerCamera = .region(.init(center: here, span: pickerSpan))
                    pickedCoordinate = here
                } else {
                    MapLocationProvider.shared.refreshOnce()
                }
            }

            Text("Drag the map to place the pin. It stays fixed — it does not update.")
                .font(VoiidFont.rounded(13, .regular)).foregroundColor(VoiidColor.textSecondary)
            TextField("", text: $label,
                      prompt: Text("Add a label (optional)").foregroundColor(VoiidColor.placeholder))
                .font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.textPrimary)
                .padding(.horizontal, VoiidSpacing.md).frame(height: 50)
                .background(VoiidColor.fieldFill)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md).stroke(VoiidColor.fieldBorder, lineWidth: 1))
        }
    }

    // MARK: - Live

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            // The audience, named explicitly.
            Text(audienceLine)
                .font(VoiidFont.rounded(14, .medium)).foregroundColor(VoiidColor.textPrimary)
            Text("For how long?")
                .font(VoiidFont.rounded(13, .semibold)).foregroundColor(VoiidColor.textSecondary)
            ForEach(ShareDuration.allCases) { d in
                Button {
                    Haptics.selection(); duration = d
                    // Escalate to Always only for > 15 min so it keeps running in background.
                    if d.needsAlways, engine.authorizationStatus == .authorizedWhenInUse {
                        engine.requestAlways()
                    }
                } label: {
                    HStack {
                        Text(d.label).font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.textPrimary)
                        Spacer()
                        if duration == d { Image(systemName: "checkmark").foregroundColor(VoiidColor.primary) }
                    }
                    .padding(.horizontal, VoiidSpacing.md).frame(height: 50)
                    .background(duration == d ? VoiidColor.fieldFill : VoiidColor.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md).stroke(VoiidColor.fieldBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Text("Sharing stops automatically when the timer ends. You can stop it any time from the banner.")
                .font(VoiidFont.rounded(12, .regular)).foregroundColor(VoiidColor.textSecondary)
        }
    }

    private var audienceLine: String {
        if isGroup {
            return "Everyone in \(conversationTitle) (\(audienceCount) \(audienceCount == 1 ? "person" : "people")) will see your live location."
        }
        return "\(conversationTitle) will see your live location."
    }

    // MARK: - Background-denied disclosure

    /// True when a background-capable duration is chosen but Always was denied — the share
    /// will run foreground-only, and we say so rather than let it silently pause.
    private var deniedForBackground: Bool {
        mode == .live && duration.needsAlways && engine.authorizationStatus == .authorizedWhenInUse
    }

    private var backgroundDeniedNote: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "info.circle").foregroundColor(VoiidColor.warning)
            Text("Live location pauses when you leave Voiid — allow Always in Settings to keep it running in the background.")
                .font(VoiidFont.rounded(12, .regular)).foregroundColor(VoiidColor.textSecondary)
        }
        .padding(VoiidSpacing.md)
        .background(VoiidColor.fieldFill)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
    }

    // MARK: - Commit

    /// Location works even with reduced accuracy (labelled Approximate elsewhere); the
    /// only hard requirement is that location isn't fully denied.
    private var authorizedEnough: Bool {
        switch engine.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse, .notDetermined: return true
        default: return false
        }
    }

    private func commit() {
        sending = true
        Haptics.success()
        switch mode {
        case .pin:  onSendPin(label.trimmingCharacters(in: .whitespaces).isEmpty ? nil
                              : label.trimmingCharacters(in: .whitespaces),
                              pickedCoordinate)
        case .live: onStartLive(duration)
        }
        dismiss()
    }
}
