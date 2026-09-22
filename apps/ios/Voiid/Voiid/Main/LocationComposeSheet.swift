import SwiftUI
import MapKit
import CoreLocation
// ObservableObject and @Published are Combine's, not SwiftUI's. The target builds with
// MemberImportVisibility, which stops them arriving transitively through SwiftUI.
import Combine

/// A picker owns its own short-lived location request; it never depends on Map-tab caches.
@MainActor
final class LocationPickerModel: ObservableObject {
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var locating = false
    @Published private(set) var fix: CLLocation?
    @Published private(set) var results: [MKMapItem] = []
    @Published private(set) var searching = false
    @Published var error: String?
    private let service = LocationService()
    private var waitingForAuthorization = false
    private var requestID = UUID()
    private var search: MKLocalSearch?

    init() {
        authorization = service.authorizationStatus
        service.onAuthChange = { [weak self] status, _ in
            guard let self else { return }
            self.authorization = status
            if status == .authorizedAlways || status == .authorizedWhenInUse { self.error = nil }
            if self.waitingForAuthorization && status != .notDetermined {
                self.waitingForAuthorization = false
                self.locate()
            }
        }
    }

    func locate() {
        guard !locating else { return }
        error = nil
        authorization = service.authorizationStatus
        switch authorization {
        case .notDetermined:
            waitingForAuthorization = true
            service.requestWhenInUse()
        case .authorizedAlways, .authorizedWhenInUse:
            locating = true
            let request = UUID()
            requestID = request
            service.requestOneShot { [weak self] location in
                guard let self, self.requestID == request else { return }
                self.locating = false
                if let location { self.fix = location }
                else { self.error = "Couldn’t find your location. Try again outdoors, or search for a place." }
            }
        default:
            error = "Location access is off. Enable it in Settings to locate yourself or share live. You can still search and send a pin."
        }
    }

    func find(_ query: String, region: MKCoordinateRegion?) async {
        cancelSearch()
        guard !query.isEmpty else { return }
        searching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        if let region { request.region = region }
        let operation = MKLocalSearch(request: request)
        search = operation
        defer { if search === operation { searching = false; search = nil } }
        do {
            let response = try await operation.start()
            guard !Task.isCancelled, search === operation else { return }
            results = Array(response.mapItems.prefix(8))
            error = results.isEmpty ? "No places found. Try a nearby landmark or a fuller address." : nil
        } catch {
            guard !Task.isCancelled, search === operation else { return }
            self.error = "Couldn’t search places. Check your connection and try again."
        }
    }

    func cancelSearch() {
        search?.cancel()
        search = nil
        searching = false
        results = []
    }

    func cancelLocate() {
        requestID = UUID()
        waitingForAuthorization = false
        service.cancelOneShot()
        locating = false
    }

    func stop() {
        cancelLocate()
        cancelSearch()
    }
}

struct LocationComposeSheet: View {
    let conversationTitle: String
    let isGroup: Bool
    let audienceCount: Int
    var onSendPin: (String?, CLLocationCoordinate2D?) async -> Bool
    var onStartLive: (ShareDuration) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var picker = LocationPickerModel()
    @ObservedObject private var engine = LocationShareEngine.shared
    private enum Mode { case pin, live }
    @State private var mode: Mode = .pin
    @State private var camera: MapCameraPosition = .automatic
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var query = ""
    @State private var label = ""
    @State private var duration: ShareDuration = .oneHour
    @State private var sending = false
    @State private var sendError: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Share with \(conversationTitle)")
                        .font(VoiidFont.rounded(14, .medium)).foregroundStyle(VoiidColor.textSecondary)
                    Picker("Location type", selection: $mode) {
                        Text("Send a pin").tag(Mode.pin)
                        Text("Live location").tag(Mode.live)
                    }.pickerStyle(.segmented)
                    if mode == .pin { pinSection } else { liveSection }
                    if let error = sendError ?? picker.error { errorNotice(error) }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Share location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(sending) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { sendBar }
            .disabled(sending)
            .task { picker.locate() }
            .task(id: query) {
                let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                let region = coordinate.map { MKCoordinateRegion(center: $0, latitudinalMeters: 10_000, longitudinalMeters: 10_000) }
                await picker.find(text, region: region)
            }
            .onChange(of: query) { _, text in
                picker.cancelSearch()
                picker.error = nil
                if !text.isEmpty { picker.cancelLocate() }
            }
            .onChange(of: picker.fix) { _, fix in
                guard let fix else { return }
                select(fix.coordinate, name: "Current location")
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active && coordinate == nil { picker.locate() }
            }
            .onDisappear { picker.stop() }
        }
        .interactiveDismissDisabled(sending)
        .tint(VoiidColor.accentInk)
    }

    private var pinSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(VoiidColor.textSecondary)
                TextField("Search places or addresses", text: $query)
                    .font(VoiidFont.rounded(16, .regular)).focused($searchFocused)
                    .autocorrectionDisabled().submitLabel(.search)
                if picker.searching { ProgressView() }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(14).background(VoiidColor.fieldFill, in: RoundedRectangle(cornerRadius: 16))
            if !picker.results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(picker.results.enumerated()), id: \.offset) { _, item in
                        Button {
                            select(item.placemark.coordinate, name: item.name ?? "Selected place")
                            query = ""
                            picker.cancelSearch()
                            searchFocused = false
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill").foregroundStyle(VoiidColor.accentInk)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name ?? "Place").font(VoiidFont.rounded(15, .semibold))
                                    Text(item.placemark.title ?? "").font(VoiidFont.rounded(12, .regular))
                                        .foregroundStyle(VoiidColor.textSecondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.left").font(.caption)
                            }
                            .foregroundStyle(VoiidColor.textPrimary).padding(14).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 16))
            }
            ZStack {
                Map(position: $camera) { UserAnnotation() }
                    .mapStyle(.standard(emphasis: .muted))
                    .onMapCameraChange(frequency: .onEnd) { context in
                        guard camera.positionedByUser else { return }
                        picker.cancelLocate()
                        coordinate = context.camera.centerCoordinate
                        label = "Dropped pin"
                    }
                Image(systemName: "mappin")
                    .font(.system(size: 32, weight: .semibold)).foregroundStyle(VoiidColor.accent)
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                    .offset(y: -16).allowsHitTesting(false)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button { searchFocused = false; picker.locate() } label: {
                            HStack(spacing: 7) {
                                if picker.locating { ProgressView() } else { Image(systemName: "location.fill") }
                                Text(picker.locating ? "Locating…" : "Locate me")
                                    .font(VoiidFont.rounded(13, .semibold))
                            }
                            .frame(minHeight: 44).padding(.horizontal, 14)
                            .background(VoiidColor.surfaceCard, in: Capsule())
                            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                        }.disabled(picker.locating)
                    }
                }.padding(12)
            }
            .frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 20))
            Text(coordinate == nil ? "Find yourself, search a place, or move the map to choose a pin." : "Move the map to adjust your pin. This location won’t update after sending.")
                .font(VoiidFont.rounded(12, .regular)).foregroundStyle(VoiidColor.textSecondary)
            TextField("Place name (optional)", text: $label)
                .font(VoiidFont.rounded(16, .regular)).padding(14)
                .background(VoiidColor.fieldFill, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "location.circle.fill").font(.system(size: 36)).foregroundStyle(VoiidColor.accentInk)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Let them follow your journey").font(VoiidFont.rounded(19, .semibold))
                    Text(isGroup ? "Everyone in \(conversationTitle) (\(audienceCount) people) can see your live location." : "Only \(conversationTitle) can see your live location.")
                        .font(VoiidFont.rounded(14, .regular)).foregroundStyle(VoiidColor.textSecondary)
                }
            }
            Text("SHARE FOR").font(VoiidFont.rounded(12, .semibold)).foregroundStyle(VoiidColor.textSecondary)
            VStack(spacing: 0) {
                ForEach(ShareDuration.allCases) { option in
                    Button { duration = option; Haptics.selection() } label: {
                        HStack {
                            Text(option.label).font(VoiidFont.rounded(16, .medium))
                            Spacer()
                            Image(systemName: option == duration ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(option == duration ? VoiidColor.accentInk : VoiidColor.textSecondary)
                        }.foregroundStyle(VoiidColor.textPrimary).padding(16).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 18))
            Label("Ends automatically. Stop at any time from the banner in your chat.", systemImage: "timer")
                .font(VoiidFont.rounded(13, .regular)).foregroundStyle(VoiidColor.textSecondary)
            if engine.authorizationStatus != .authorizedAlways {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Keep sharing when Voiid is in the background")
                        .font(VoiidFont.rounded(14, .semibold))
                    Text("Allow Always for reliable background updates. Without it, updates may pause when you leave the app.")
                        .font(VoiidFont.rounded(12, .regular)).foregroundStyle(VoiidColor.textSecondary)
                    Button("Allow background location") {
                        if engine.authorizationStatus == .authorizedWhenInUse { engine.requestAlways() }
                        else { picker.locate() }
                    }.font(VoiidFont.rounded(14, .semibold))
                    Button("Open location settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }.font(VoiidFont.rounded(13, .medium))
                }.padding(16).background(VoiidColor.accentTint, in: RoundedRectangle(cornerRadius: 16))
            }
            if engine.isReducedAccuracy {
                Label("Your device is sharing an approximate location.", systemImage: "location.circle")
                    .font(VoiidFont.rounded(12, .regular)).foregroundStyle(VoiidColor.textSecondary)
            }
        }
    }

    private func errorNotice(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(text, systemImage: "exclamationmark.circle")
                .font(VoiidFont.rounded(13, .regular)).foregroundStyle(VoiidColor.textSecondary)
            if picker.authorization == .denied || picker.authorization == .restricted {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.font(VoiidFont.rounded(14, .semibold))
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(VoiidColor.fieldFill, in: RoundedRectangle(cornerRadius: 14))
    }

    private var sendBar: some View {
        Button { commit() } label: {
            HStack(spacing: 10) {
                if sending { ProgressView().tint(VoiidColor.textOnAccent) }
                else { Image(systemName: mode == .pin ? "paperplane.fill" : "location.fill") }
                Text(sending ? "Sending…" : (mode == .pin ? "Send this location" : "Share for \(duration.label)"))
                    .font(VoiidFont.rounded(16, .semibold))
            }.frame(maxWidth: .infinity).frame(height: 52)
                .foregroundStyle(VoiidColor.textOnAccent)
                .background(VoiidColor.accent, in: Capsule())
        }
        .disabled(sending || (mode == .pin ? coordinate == nil : !canLocate))
        .opacity((mode == .pin ? coordinate != nil : canLocate) ? 1 : 0.45)
        .padding(.horizontal, 20).padding(.vertical, 12).background(VoiidColor.background)
    }

    private var canLocate: Bool {
        engine.authorizationStatus == .authorizedAlways || engine.authorizationStatus == .authorizedWhenInUse
    }

    private func select(_ point: CLLocationCoordinate2D, name: String) {
        picker.cancelLocate()
        coordinate = point
        label = name
        camera = .region(MKCoordinateRegion(center: point, latitudinalMeters: 700, longitudinalMeters: 700))
    }

    private func commit() {
        guard !sending else { return }
        sending = true
        sendError = nil
        searchFocused = false
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let success = mode == .pin
                ? await onSendPin(name.isEmpty ? nil : name, coordinate)
                : await onStartLive(duration)
            sending = false
            if success { Haptics.success(); dismiss() }
            else { sendError = engine.lastError ?? "Couldn’t share your location. Check your connection and try again." }
        }
    }
}
