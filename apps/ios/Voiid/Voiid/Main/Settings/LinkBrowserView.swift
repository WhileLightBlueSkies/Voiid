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

    // Design reference: Voiid Ui/Chat/LinkedDevicesScreen.swift (LinkBrowserSheet).
    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if linked {
                        linkedStep
                    } else if let preview {
                        confirmStep(preview)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        scanStep
                    }
                }
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.vertical, VoiidSpacing.md)
                .animation(.snappy, value: preview?.verification_code)
            }
            .softScrollEdge()
            .background(VoiidColor.background.ignoresSafeArea())
            .foregroundStyle(VoiidColor.textPrimary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel(); dismiss() }.disabled(busy && preview != nil)
                }
            }
        }
        .tint(VoiidColor.accentInk)
        .interactiveDismissDisabled(busy)
        .task { active = true; await requestCamera() }
        .onDisappear { cancel() }
    }

    // MARK: Step 1 — scan

    private var scanStep: some View {
        VStack(spacing: VoiidSpacing.lg) {
            VStack(spacing: 6) {
                Text("Link a Browser")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text("Open Voiid Web on your computer and scan the QR code it shows.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(VoiidColor.textSecondary)
            }
            .multilineTextAlignment(.center)

            ZStack {
                Color.black
                if cameraAllowed {
                    BrowserCamera(isScanning: active && scenePhase == .active && !busy && error == nil,
                                  onCode: scan,
                                  onUnavailable: { error = "Camera unavailable. Check camera access in Settings and try again." })
                        .accessibilityLabel("Camera for scanning a Voiid Web QR code")
                    ScanBrackets(inset: 28, color: VoiidColor.primary)
                        .padding(.vertical, 26)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    if busy {
                        ProgressView("Checking browser…").tint(.white).foregroundStyle(.white)
                            .padding(VoiidSpacing.md)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                } else {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white.opacity(0.6))
                        .accessibilityHidden(true)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            if let error {
                VStack(spacing: VoiidSpacing.sm) {
                    Text(error)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(VoiidColor.error)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.updatesFrequently)
                    HStack(spacing: VoiidSpacing.md) {
                        Button("Try Again") { reset(); operation = Task { await requestCamera() } }
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                }
            }

            Label("Only link computers you own", systemImage: "lock.fill")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(VoiidColor.textSecondary)
            Text("Scanning does not grant access. You will confirm the browser on the next screen.")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Step 2 — confirm

    private func confirmStep(_ preview: DeviceDirectoryService.LinkPreview) -> some View {
        VStack(spacing: VoiidSpacing.lg) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 40))
                .foregroundStyle(VoiidColor.accentInk)
                .frame(width: 84, height: 84)
                .background(VoiidColor.accentTint, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.top, VoiidSpacing.lg)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Link \(preview.device_name)?")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text("Check this code matches the one on your computer.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(VoiidColor.textSecondary)
            }
            .multilineTextAlignment(.center)

            Text(preview.verification_code)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.vertical, VoiidSpacing.md)
                .background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityLabel("Verification code: \(preview.verification_code.map(String.init).joined(separator: " "))")

            Text("This browser will be able to send and receive messages as you. If the codes don't match, or someone sent you this code, cancel.")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)

            if let error {
                Text(error)
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(VoiidColor.error)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            Button(action: approve) {
                HStack(spacing: 8) {
                    if busy { ProgressView().tint(.white) }
                    Text(busy ? "Confirming…" : "Codes Match — Link")
                }
                .font(.system(.body, design: .rounded, weight: .semibold))
                .frame(maxWidth: .infinity)
            }
            .prominentAction()
            .disabled(busy)

            Button("Scan a Different Code", action: reset)
                .font(.system(.subheadline, design: .rounded))
                .disabled(busy)
        }
    }

    // MARK: Step 3 — linked

    private var linkedStep: some View {
        VStack(spacing: VoiidSpacing.lg) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(VoiidColor.accentInk)
                .padding(.top, VoiidSpacing.xl)
            VStack(spacing: 6) {
                Text("Browser Linked")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text("You can remove its access at any time in Linked Devices.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(VoiidColor.textSecondary)
            }
            .multilineTextAlignment(.center)
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .prominentAction()
        }
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
