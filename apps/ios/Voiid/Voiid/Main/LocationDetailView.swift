//
//  LocationDetailView.swift
//  Voiid
//
//  Full-screen detail for a location message (docs/LOCATION.md §4): the map, Open in Maps
//  (system handoff), and Directions. There is NO in-app routing and NO reverse-geocoding
//  to a street address (§10) — we hand off to the system map app, which keeps the
//  coordinate off any geocoder we control.
//
//  iOS 17+ Map(position:) + Annotation. Deployment target is 18.0, so no availability
//  fallback is required. The map is calm and light: POIs excluded, standard style.
//

import SwiftUI
import MapKit

struct LocationDetailView: View {
    let coordinate: CLLocationCoordinate2D
    var label: String?
    var live: Bool = false
    var state: ShareState = .live
    var shareId: String?

    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition

    init(coordinate: CLLocationCoordinate2D, label: String?, live: Bool,
         state: ShareState, shareId: String?) {
        self.coordinate = coordinate
        self.label = label
        self.live = live
        self.state = state
        self.shareId = shareId
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: coordinate, latitudinalMeters: 800, longitudinalMeters: 800)))
    }

    var body: some View {
        ZStack(alignment: .top) {
            map.ignoresSafeArea()
            header
            controls
        }
        .preferredColorScheme(.light)
    }

    private var map: some View {
        Map(position: $position) {
            Annotation(label ?? (live ? "Live location" : "Location"), coordinate: coordinate) {
                Image(systemName: state == .ended ? "mappin.slash.circle.fill"
                                : (live ? "location.circle.fill" : "mappin.circle.fill"))
                    .font(.system(size: 34))
                    .foregroundColor(state == .stale ? VoiidColor.textSecondary : VoiidColor.error)
                    .shadow(radius: 2)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold)).foregroundColor(VoiidColor.textPrimary)
                    .padding(10).background(VoiidColor.surfaceCard).clipShape(Circle())
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            }
            Spacer()
            if live {
                HStack(spacing: 6) {
                    Circle().fill(stateColor).frame(width: 8, height: 8)
                    Text(stateLabel).font(VoiidFont.rounded(12, .semibold)).foregroundColor(VoiidColor.textPrimary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(VoiidColor.surfaceCard).clipShape(Capsule())
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            }
        }
        .padding(.horizontal, VoiidSpacing.md).padding(.top, VoiidSpacing.md)
    }

    private var controls: some View {
        VStack {
            Spacer()
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
                .font(VoiidFont.rounded(15, .semibold)).foregroundColor(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(VoiidColor.primary).clipShape(Capsule())
        }
        .buttonStyle(.plain)
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
        let placemark = MKPlacemark(coordinate: coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = label ?? (live ? "Live location" : "Shared location")
        item.openInMaps(launchOptions: directions
            ? [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving] : nil)
    }
}
