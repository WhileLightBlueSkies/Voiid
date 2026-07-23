//
//  LocationPinBubble.swift
//  Voiid
//
//  How a location renders in a conversation (docs/LOCATION.md §4). A 220×140 card with a
//  LOCALLY-rendered map thumbnail (MKMapSnapshotter, off-main, NSCache-backed) and an
//  accent pin glyph at centre. Two variants:
//   • static pin  — frozen coordinate + optional user-typed label.
//   • live share  — pulsing dot, "Live until HH:MM" countdown, an inline Stop if it is
//                   yours; on stop/expiry it becomes the frozen final pin, "ended HH:MM".
//
//  THE MAP-TILE LEAK, STATED PLAINLY (docs/LOCATION.md §4): rendering a map sends the
//  viewport to Apple. Voiid's server stays blind; the tile provider does not. Honoured
//  here by `MapTilePreference` — OFF renders a coordinate card with an "Open in Maps"
//  button and issues ZERO tile requests. Sending/receiving still work fully.
//
//  We NEVER upload a rendered thumbnail as media — each viewer renders locally, so no R2
//  object and no second key, and the sender's device never leaks on a viewer's behalf.
//

import SwiftUI
import MapKit

/// Display-only preference: load map tiles (default ON). The Settings toggle that writes
/// it lives on the Privacy screen (feature B); reading it here keeps feature A honest.
enum MapTilePreference {
    private static let key = "voiid.location.loadMapTiles"
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
    static func set(_ on: Bool) { UserDefaults.standard.set(on, forKey: key) }
}

/// Off-main map-thumbnail cache keyed by (rounded coord, span). A scrolling message list
/// must never re-render the same snapshot, and a snapshot must never block the main thread.
final class MapSnapshotCache {
    static let shared = MapSnapshotCache()
    private let cache = NSCache<NSString, UIImage>()
    private init() {}

    private func key(_ coord: CLLocationCoordinate2D, meters: Double) -> NSString {
        // ~1.1 m rounding is already applied upstream; key on 5 decimals + span.
        NSString(string: String(format: "%.5f,%.5f@%.0f", coord.latitude, coord.longitude, meters))
    }

    func snapshot(_ coord: CLLocationCoordinate2D, meters: Double = 600,
                  size: CGSize, completion: @escaping (UIImage?) -> Void) {
        let k = key(coord, meters: meters)
        if let cached = cache.object(forKey: k) { completion(cached); return }
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: coord, latitudinalMeters: meters,
                                            longitudinalMeters: meters)
        options.size = size
        options.pointOfInterestFilter = .excludingAll   // calm, on-brand, no POIs
        // The app is pinned to light; render the light map deterministically.
        options.traitCollection = UITraitCollection(userInterfaceStyle: .light)
        MKMapSnapshotter(options: options).start(with: .global()) { [weak self] snap, _ in
            guard let img = snap?.image else { DispatchQueue.main.async { completion(nil) }; return }
            self?.cache.setObject(img, forKey: k)
            DispatchQueue.main.async { completion(img) }
        }
    }
}

/// The location bubble shown inside a chat. Renders from a `LocationRef` and, for live
/// shares, from `LocationShareEngine`'s live state.
struct LocationPinBubble: View {
    let ref: LocationRef
    @ObservedObject private var engine = LocationShareEngine.shared
    @State private var showDetail = false

    private var isLive: Bool { ref.locationKind == .live_start }

    /// The coordinate to draw. A pin uses its own; a live share uses the LATEST fix (the
    /// live_start envelope carries no coordinate — the position arrives over the stream).
    private var coordinate: CLLocationCoordinate2D? {
        if isLive, let sid = ref.shareId, let fix = engine.lastFix(shareId: sid) {
            return CLLocationCoordinate2D(latitude: fix.lat, longitude: fix.lon)
        }
        if let lat = ref.lat, let lon = ref.lon {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return nil
    }

    private var state: ShareState {
        guard isLive, let sid = ref.shareId else { return .live }
        return engine.shareState(shareId: sid, expiresAt: ref.expiresAtDate,
                                 cadence: ref.cadence ?? 15)
    }

    var body: some View {
        Button { showDetail = true } label: { card }
            .buttonStyle(.plain)
            .fullScreenCover(isPresented: $showDetail) {
                if let coordinate {
                    LocationDetailView(coordinate: coordinate, label: ref.label, live: isLive,
                                       state: state, shareId: ref.shareId)
                }
            }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail
            footer
        }
        .frame(width: 220)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md).stroke(VoiidColor.fieldBorder, lineWidth: 1))
    }

    // MARK: - Thumbnail (or coordinate-card fallback)

    @ViewBuilder private var thumbnail: some View {
        ZStack {
            if let coordinate, MapTilePreference.enabled, state != .ended {
                MapThumbnail(coordinate: coordinate, desaturated: state == .stale)
                    .frame(width: 220, height: 120)
                pinGlyph
            } else {
                coordinateCard
            }
            if isLive && state == .live {
                LivePulse().padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 220, height: 120)
        .clipped()
    }

    private var pinGlyph: some View {
        Image(systemName: state == .ended ? "mappin.slash.circle.fill" : "mappin.circle.fill")
            .font(.system(size: 30))
            .foregroundColor(state == .stale ? VoiidColor.textSecondary : VoiidColor.error)
            .background(Circle().fill(VoiidColor.surfaceCard).frame(width: 20, height: 20))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }

    /// Shown when tiles are OFF, a share has ended, or no coordinate is known yet — ZERO
    /// tile requests are issued in this branch.
    private var coordinateCard: some View {
        VStack(spacing: 6) {
            Image(systemName: isLive && state != .ended ? "location.circle" : "mappin.and.ellipse")
                .font(.system(size: 26)).foregroundColor(VoiidColor.primary)
            if let coordinate {
                Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                    .font(VoiidFont.rounded(11, .medium)).foregroundColor(VoiidColor.textSecondary)
            } else {
                Text("Waiting for location…")
                    .font(VoiidFont.rounded(11, .regular)).foregroundColor(VoiidColor.textSecondary)
            }
        }
        .frame(width: 220, height: 120)
        .background(VoiidColor.fieldFill)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(footerTitle)
                .font(VoiidFont.rounded(14, .semibold)).foregroundColor(VoiidColor.textPrimary)
                .lineLimit(1)
            if let sub = footerSubtitle {
                Text(sub).font(VoiidFont.rounded(11, .regular))
                    .foregroundColor(state == .ended ? VoiidColor.textSecondary : VoiidColor.primary)
            }
            if isLive, state != .ended, engine.isEmitting(ref.shareId ?? "") {
                Button {
                    Haptics.rigid()
                    if let sid = ref.shareId { Task { await engine.stopLiveShare(sid) } }
                } label: {
                    Text("Stop sharing")
                        .font(VoiidFont.rounded(12, .semibold)).foregroundColor(VoiidColor.error)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var footerTitle: String {
        if isLive { return state == .ended ? "Live location" : "Live location" }
        return ref.label?.isEmpty == false ? ref.label! : "Location"
    }

    private var footerSubtitle: String? {
        if isLive {
            switch state {
            case .live:  return "Live until \(clock(ref.expiresAtDate))"
            case .stale: return "May have lost signal · until \(clock(ref.expiresAtDate))"
            case .ended: return "ended \(clock(endedClock))"
            }
        }
        // Static pin: honesty about a coarse fix.
        if let acc = ref.acc, acc > 100 { return "Accurate to ~250 m" }
        return nil
    }

    /// For an ended share, prefer the last fix's time, else the expiry.
    private var endedClock: Date? {
        if let sid = ref.shareId, let fix = engine.lastFix(shareId: sid) { return fix.date }
        return ref.expiresAtDate
    }

    private func clock(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: date)
    }
}

/// A single locally-rendered map snapshot as a SwiftUI image (async, cached).
private struct MapThumbnail: View {
    let coordinate: CLLocationCoordinate2D
    var desaturated: Bool = false
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .saturation(desaturated ? 0.15 : 1)
            } else {
                Rectangle().fill(VoiidColor.fieldFill).overlay(ProgressView().scaleEffect(0.7))
            }
        }
        .frame(width: 220, height: 120)
        .task(id: "\(coordinate.latitude),\(coordinate.longitude)") {
            MapSnapshotCache.shared.snapshot(coordinate, size: CGSize(width: 220, height: 120)) { img in
                image = img
            }
        }
    }
}

/// The pulsing accent dot on a live marker.
private struct LivePulse: View {
    @State private var animate = false
    var body: some View {
        Circle().fill(VoiidColor.success)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(VoiidColor.success.opacity(0.5), lineWidth: 6)
                .scaleEffect(animate ? 2 : 1).opacity(animate ? 0 : 1))
            .onAppear { withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { animate = true } }
    }
}
