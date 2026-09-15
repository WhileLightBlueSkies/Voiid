import SwiftUI
import AVFoundation
import LocalAuthentication

/// Separate approval surface; reuses the profile scanner's camera controller only.
@MainActor
struct LinkBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraAllowed = false
    @State private var busy = false
    @State private var scannedToken: String?
    @State private var preview: DeviceDirectoryService.LinkPreview?
    @State private var error: String?
    @State private var linked = false
    @State private var active = true
    @State private var operation: Task<Void, Never>?
    @State private var authentication: LAContext?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if linked {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 56)).foregroundStyle(VoiidColor.primary)
                        Text("Browser linked").font(.title2.bold())
                        Text("You can remove its access at any time in Linked Devices.")
                            .foregroundStyle(VoiidColor.textSecondary)
                        Button("Done") { dismiss() }.buttonStyle(.borderedProminent).tint(VoiidColor.primary)
                    } else if let preview {
                        Image(systemName: "laptopcomputer").font(.system(size: 48)).foregroundStyle(VoiidColor.primary)
                        Text("Link this browser?").font(.title2.bold())
                        Text(preview.device_name).font(.headline)
                        VStack(spacing: 12) {
                            Text("Check this code matches your browser")
                                .font(.subheadline).foregroundStyle(VoiidColor.textSecondary)
                            Text(preview.verification_code).font(.title2.monospaced().bold())
                                .accessibilityLabel("Verification code: \(preview.verification_code)")
                        }
                        .padding().frame(maxWidth: .infinity)
                        .background(VoiidColor.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        Text("This browser will be able to send and receive messages as you. Only approve a QR code on your own computer. Never link a code sent by someone else.")
                            .font(.body).foregroundStyle(VoiidColor.textSecondary)
                        Button(action: approve) {
                            HStack {
                                if busy { ProgressView().tint(.white) }
                                Text(busy ? "Confirming…" : "Confirm and Link")
                            }.frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent).tint(VoiidColor.primary).disabled(busy)
                        Button("Scan a Different Code", action: reset).disabled(busy)
                    } else {
                        Text("Scan the code on Voiid Web")
                            .font(.title2.bold())
                        Text("Open Voiid Web on your computer, then point your camera at its QR code.")
                            .foregroundStyle(VoiidColor.textSecondary)
                        if cameraAllowed {
                            BrowserCamera(isScanning: active && scenePhase == .active && !busy && error == nil,
                                          onCode: scan, onUnavailable: { error = "Camera unavailable. Check camera access in Settings and try again." })
                                .frame(height: 320)
                                .clipShape(RoundedRectangle(cornerRadius: 24))
                                .overlay { Image(systemName: "viewfinder").font(.system(size: 190, weight: .ultraLight)).foregroundStyle(.white.opacity(0.85)).allowsHitTesting(false) }
                                .accessibilityLabel("Camera for scanning a Voiid Web QR code")
                        }
                        if busy { ProgressView("Checking browser…").tint(VoiidColor.primary) }
                        Text("Scanning does not grant access. You will confirm the browser on the next screen.")
                            .font(.footnote).foregroundStyle(VoiidColor.textSecondary)
                    }
                    if let error {
                        Text(error).foregroundStyle(VoiidColor.error).font(.callout).accessibilityAddTraits(.updatesFrequently)
                        if preview == nil {
                            Button("Try Again") { reset(); operation = Task { await requestCamera() } }
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                    }
                }
                .multilineTextAlignment(.center).padding(24)
            }
            .softTopEdgeEffect()
            .background(VoiidColor.background).foregroundStyle(VoiidColor.textPrimary)
            .navigationTitle("Link a Browser").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancel(); dismiss() }.disabled(busy && preview != nil) } }
        }
        .interactiveDismissDisabled(busy)
        .task { active = true; await requestCamera() }
        .onDisappear { cancel() }
    }

    private func requestCamera() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraAllowed = true
        case .notDetermined: cameraAllowed = await AVCaptureDevice.requestAccess(for: .video)
        default: cameraAllowed = false
        }
        if !cameraAllowed { error = "Allow camera access in Settings to scan your browser’s code." }
    }

    private func scan(_ raw: String) {
        guard !busy, preview == nil, error == nil, active else { return }
        guard let token = LinkBrowserCode.token(from: raw) else {
            error = "This is not a Voiid Web linking code. Scan the code shown on your computer."; return
        }
        busy = true
        operation = Task {
            defer { busy = false }
            do {
                let result = try await DeviceDirectoryService.shared.preview(linkToken: token)
                guard !Task.isCancelled, active, result.platform == "web" else { return }
                scannedToken = token; preview = result
            } catch { if !Task.isCancelled && active { self.error = "Couldn’t check this code. It may have expired. Scan a fresh code from your browser." } }
        }
    }

    private func approve() {
        guard !busy, active, let token = scannedToken, let preview else { return }
        busy = true; error = nil
        operation = Task {
            defer { busy = false; authentication = nil }
            let context = LAContext(); authentication = context
            do {
                let confirmed = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                    localizedReason: "Link this browser to send and receive Voiid messages.")
                guard confirmed, !Task.isCancelled, active else { return }
                try await DeviceDirectoryService.shared.approve(linkToken: token, identityKey: preview.identity_public_key)
                guard !Task.isCancelled, active else { return }
                linked = true
            } catch {
                guard !Task.isCancelled, active else { return }
                if let laError = error as? LAError, [.userCancel, .appCancel, .systemCancel].contains(laError.code) { return }
                self.error = "Linking wasn’t completed. Unlock your phone and try again. If this code expired, scan a fresh one."
            }
        }
    }

    private func reset() { operation?.cancel(); scannedToken = nil; preview = nil; error = nil; busy = false }
    private func cancel() { active = false; operation?.cancel(); authentication?.invalidate() }
}

private struct BrowserCamera: UIViewControllerRepresentable {
    let isScanning: Bool
    let onCode: (String) -> Void
    let onUnavailable: () -> Void
    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode; controller.onUnavailable = onUnavailable
        controller.setScanning(isScanning)
        return controller
    }
    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onCode = onCode; controller.onUnavailable = onUnavailable
        controller.setScanning(isScanning)
    }
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) {
        controller.onCode = nil; controller.onUnavailable = nil; controller.setScanning(false)
    }
}
