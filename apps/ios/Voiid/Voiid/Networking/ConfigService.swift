//
//  ConfigService.swift
//  Voiid
//
//  Server-driven version negotiation + feature flags. On launch the app hits the
//  UNVERSIONED /config endpoint to learn the API version to use, which features
//  are enabled (server-toggled, no app update needed), and whether THIS build must
//  force-update. Gate optional UI on `isEnabled(...)`.
//

import SwiftUI
import Combine

@MainActor
final class ConfigService: ObservableObject {
    static let shared = ConfigService()
    private let api = APIClient()
    private init() {}

    @Published var featureFlags: [String: Bool] = [:]
    @Published var apiVersion: String = APIConfig.apiVersion

    private struct ConfigDTO: Decodable {
        let api_version: String
        let force_update: Bool
        let feature_flags: [String: Bool]
        let store_url: StoreURL?
        struct StoreURL: Decodable { let ios: String?; let android: String? }
    }

    /// Fetch remote config. Safe to call on every launch; failures are ignored
    /// (the app falls back to its built-in defaults).
    func fetch() async {
        guard let cfg: ConfigDTO = try? await api.request("GET", "config", auth: false, versioned: false) else { return }
        featureFlags = cfg.feature_flags
        apiVersion = cfg.api_version
        if cfg.force_update {
            NotificationCenter.default.post(name: .voiidUpdateRequired, object: cfg.store_url?.ios)
        }
    }

    /// Server feature flag (default off when unknown).
    func isEnabled(_ key: String) -> Bool { featureFlags[key] ?? false }
}

// MARK: - Forced-update gate (blocking)

private struct ForceUpdateGate: ViewModifier {
    @State private var required = false
    @State private var storeURL: String?

    func body(content: Content) -> some View {
        content
            .task { await ConfigService.shared.fetch() }
            .onReceive(NotificationCenter.default.publisher(for: .voiidUpdateRequired)) { note in
                storeURL = note.object as? String
                required = true
            }
            .fullScreenCover(isPresented: $required) {
                UpdateRequiredView(storeURL: storeURL)
            }
    }
}

extension View {
    /// Attach near the app root: fetches /config on launch and shows a blocking
    /// update screen whenever the backend returns 426 / force_update.
    func voiidForceUpdateGate() -> some View { modifier(ForceUpdateGate()) }
}

struct UpdateRequiredView: View {
    let storeURL: String?
    var body: some View {
        VStack(spacing: VoiidSpacing.lg) {
            Spacer()
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 64)).foregroundColor(VoiidColor.primary)
            Text("Update required")
                .font(VoiidFont.rounded(22, .bold)).foregroundColor(VoiidColor.textPrimary)
            Text("A newer version of VOIID is needed to keep chatting securely. Please update to continue.")
                .font(VoiidFont.rounded(15)).foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, VoiidSpacing.xl)
            Spacer()
            Button {
                if let s = storeURL, let url = URL(string: s) { UIApplication.shared.open(url) }
            } label: {
                Text("Update VOIID")
                    .font(VoiidFont.rounded(16, .semibold)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(VoiidColor.primary)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.pill, style: .continuous))
            }
            .padding(.horizontal, VoiidSpacing.lg).padding(.bottom, VoiidSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoiidColor.background.ignoresSafeArea())
        .interactiveDismissDisabled(true)
    }
}
