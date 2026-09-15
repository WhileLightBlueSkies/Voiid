//
//  ScanQRCodeView.swift
//  Voiid
//
//  Framed camera → server-resolved preview → explicit request/join.
//  A QR supplies a handle, never a messaging or membership permission.
//

import SwiftUI
import AVFoundation

@MainActor
struct ScanQRCodeView: View {
    var onOpenConversation: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var permission: AVAuthorizationStatus = .notDetermined
    @State private var cameraUnavailable = false
    @State private var rejected = false
    @State private var capturedCommunity: CommunityLink?
    @State private var capturedLink: ProfileLink?
    @State private var torchOn = false
    @State private var torchAvailable = false
    @State private var rejectionTask: Task<Void, Never>?

    private var captured: Bool { capturedLink != nil || capturedCommunity != nil }
    private var showsViewfinder: Bool {
        #if targetEnvironment(simulator) && DEBUG
        return true
        #else
        return permission == .authorized && !cameraUnavailable
        #endif
    }

    var body: some View {
        Group {
            if let community = capturedCommunity {
                CommunityJoinSheet(link: community, onScanAgain: scanAgain)
            } else if let profile = capturedLink {
                FindByUsernameView(prefilledHandle: profile.username, onScanAgain: scanAgain,
                                   onOpen: onOpenConversation)
            } else {
                scanner
            }
        }
        .tint(VoiidColor.primary)
        .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.2), value: captured)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { torchOn = false }
        }
        .onDisappear {
            torchOn = false
            rejectionTask?.cancel()
        }
    }

    private var scanner: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        QRScreenHeading(title: "Scan QR", subtitle: "Scan a Voiid profile or community code")
                        cameraWindow
                            .frame(height: max(260, min(460, geometry.size.height - 230)))
                        VStack(spacing: 12) {
                            if showsViewfinder {
                                Button {
                                    Haptics.tap()
                                    torchOn.toggle()
                                } label: {
                                    VStack(spacing: 8) {
                                        Image(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                            .font(.system(size: 22, weight: .medium))
                                            .frame(width: 56, height: 56)
                                            .background(torchOn ? VoiidColor.accentTint : VoiidColor.surfaceRaised,
                                                        in: Circle())
                                        Text(torchOn ? "Flashlight on" : "Flashlight")
                                            .font(.system(.footnote, design: .rounded))
                                    }
                                    .foregroundStyle(VoiidColor.textPrimary)
                                }
                                .buttonStyle(.plain)
                                .disabled(!torchAvailable)
                                .opacity(torchAvailable ? 1 : 0.5)
                                .accessibilityLabel("Flashlight")
                                .accessibilityValue(torchOn ? "On" : "Off")
                                .accessibilityHint(torchAvailable ? "Lights the code in a dark room" : "Not available on this camera")
                                .accessibilityIdentifier("scan.flashlight")
                            }
                            if rejected {
                                Label("That isn’t a Voiid profile or community code. Try another.", systemImage: "exclamationmark.circle")
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(VoiidColor.error)
                                    .multilineTextAlignment(.center)
                                    .accessibilityIdentifier("scan.invalidCode")
                            }
                            #if targetEnvironment(simulator) && DEBUG
                            HStack {
                                Button("Simulate profile") { accept("https://voiid.app/u/arjundev") }
                                    .accessibilityIdentifier("scan.simulateProfile")
                                Button("Simulate community") { accept("https://voiid.app/c/voiid_jobs") }
                                    .accessibilityIdentifier("scan.simulateCommunity")
                            }
                            .font(.system(.footnote, design: .rounded))
                            .buttonStyle(.bordered)
                            #endif
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .background(VoiidColor.background.ignoresSafeArea())
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Close scanner")
                }
            }
            .toolbarBackground(VoiidColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await requestAccess()
            }
        }
    }

    private var cameraWindow: some View {
        ZStack {
            Color.black
            if permission == .authorized && !cameraUnavailable {
                VoiidQRScannerPreview(isScanning: !captured && scenePhase == .active,
                              torchOn: torchOn,
                              onCode: accept,
                              onUnavailable: { cameraUnavailable = true; torchOn = false },
                              onTorchStatus: { available, enabled in
                                  torchAvailable = available
                                  torchOn = enabled
                              })
                    .accessibilityHidden(true)
            }
            if showsViewfinder {
                #if targetEnvironment(simulator) && DEBUG
                Image(systemName: "qrcode")
                    .font(.system(size: 150))
                    .foregroundStyle(.white.opacity(0.8))
                    .accessibilityHidden(true)
                #endif
                ScanBrackets(inset: 28, color: VoiidColor.primary)
                    .padding(.vertical, 26)
                    .accessibilityHidden(true)
            } else if permission == .notDetermined {
                ProgressView("Opening camera…").tint(.white).foregroundStyle(.white)
            } else {
                deniedMessage
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityIdentifier("scan.viewfinder")
    }

    private var deniedMessage: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill").font(.system(size: 36))
            Text(cameraUnavailable ? "Camera unavailable" : "Camera access is off")
                .font(.system(.headline, design: .rounded))
            Text(cameraUnavailable ? "The camera was interrupted. Try opening it again." : "Turn it on in Settings to scan a code.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            if cameraUnavailable {
                Button("Try again") {
                    cameraUnavailable = false
                    torchOn = false
                    torchAvailable = false
                }
                .buttonStyle(.borderedProminent)
                .tint(VoiidColor.primary)
            }
            if !cameraUnavailable, let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(VoiidColor.primary, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(24)
    }

    private func requestAccess() async {
        #if targetEnvironment(simulator) && DEBUG
        permission = .denied
        #else
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard !Task.isCancelled else { return }
        permission = AVCaptureDevice.authorizationStatus(for: .video)
        #endif
    }

    private func accept(_ raw: String) {
        guard !captured, scenePhase == .active else { return }
        let community = CommunityLink.parse(URL(string: raw))
        let profile = ProfileLink.parse(URL(string: raw))
        guard community != nil || profile != nil else {
            guard !rejected else { return }
            Haptics.error()
            rejected = true
            rejectionTask = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                rejected = false
            }
            return
        }
        rejectionTask?.cancel()
        rejected = false
        torchOn = false
        capturedCommunity = community
        capturedLink = profile
        Haptics.success()
        UIAccessibility.post(notification: .announcement,
                             argument: community == nil ? "Profile code scanned. Loading preview." : "Community code scanned. Loading preview.")
    }

    private func scanAgain() {
        capturedLink = nil
        capturedCommunity = nil
        rejected = false
        torchOn = false
    }
}

/// Shared with the two scan result screens. Dynamic Type, real content, no fixed text heights.
struct QRScreenHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(VoiidColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(VoiidColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QRIdentityAvatar: View {
    let photoURL: String?
    let name: String

    var body: some View {
        ZStack {
            VoiidColor.primary
            if let photoURL, !photoURL.isEmpty {
                ProfileAvatarButton(photoURL: photoURL, name: name, size: 88,
                                    fillsFrame: true, placeholderFill: VoiidColor.primary)
            } else {
                Text(name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased())
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .foregroundStyle(VoiidColor.textOnPrimary)
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityHidden(true)
    }
}

struct QRActionButtonStyle: ButtonStyle {
    var secondary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(secondary ? VoiidColor.textPrimary : VoiidColor.textOnPrimary)
            .frame(maxWidth: .infinity, minHeight: 24)
            .padding(.vertical, 16)
            .padding(.horizontal, 16)
            .background(secondary ? VoiidColor.surfaceRaised : VoiidColor.primary,
                        in: RoundedRectangle(cornerRadius: 16))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

// MARK: - Brackets

/// Four corner brackets, drawn as one shape.
///
/// `inset` pulls all four toward the centre — that is the capture gesture: the frame closing
/// on what it caught, which reads as deliberate where a scale on the whole window would just
/// look like a zoom.
private struct ScanBrackets: View {
    var inset: CGFloat
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let arm: CGFloat = 34          // long enough to imply the edge, short enough to stay corners
            let r: CGFloat = 26            // matches the window's own corner radius

            Path { p in
                // Top-left
                p.move(to: CGPoint(x: 0, y: arm))
                p.addLine(to: CGPoint(x: 0, y: r))
                p.addQuadCurve(to: CGPoint(x: r, y: 0), control: .zero)
                p.addLine(to: CGPoint(x: arm, y: 0))
                // Top-right
                p.move(to: CGPoint(x: w - arm, y: 0))
                p.addLine(to: CGPoint(x: w - r, y: 0))
                p.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0))
                p.addLine(to: CGPoint(x: w, y: arm))
                // Bottom-right
                p.move(to: CGPoint(x: w, y: h - arm))
                p.addLine(to: CGPoint(x: w, y: h - r))
                p.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h))
                p.addLine(to: CGPoint(x: w - arm, y: h))
                // Bottom-left
                p.move(to: CGPoint(x: arm, y: h))
                p.addLine(to: CGPoint(x: r, y: h))
                p.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
                p.addLine(to: CGPoint(x: 0, y: h - arm))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
        .padding(inset)
    }
}

// MARK: - Camera

struct VoiidQRScannerPreview: UIViewControllerRepresentable {
    let isScanning: Bool
    let torchOn: Bool
    let onCode: (String) -> Void
    let onUnavailable: () -> Void
    let onTorchStatus: (Bool, Bool) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onUnavailable = onUnavailable
        controller.onTorchStatus = onTorchStatus
        controller.setScanning(isScanning)
        controller.setTorch(torchOn)
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onCode = onCode
        controller.onUnavailable = onUnavailable
        controller.onTorchStatus = onTorchStatus
        controller.setScanning(isScanning)
        controller.setTorch(torchOn)
    }

    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) {
        controller.onCode = nil
        controller.onUnavailable = nil
        controller.onTorchStatus = nil
        controller.setTorch(false)
        controller.setScanning(false)
    }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onUnavailable: (() -> Void)?
    var onTorchStatus: ((Bool, Bool) -> Void)?

    private let session = AVCaptureSession()
    // One queue preserves start/stop order, including dismissal during camera startup.
    private let sessionQueue = DispatchQueue(label: "app.voiid.qr-camera", qos: .userInitiated)
    private var preview: AVCaptureVideoPreviewLayer?
    private var isScanning = false
    private var isConfigured = false
    private var captureDevice: AVCaptureDevice?
    private var metadataOutput: AVCaptureMetadataOutput?
    private var requestedTorch = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        NotificationCenter.default.addObserver(self, selector: #selector(captureStarted),
                                               name: AVCaptureSession.didStartRunningNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(captureFailed),
                                               name: AVCaptureSession.runtimeErrorNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(captureInterrupted),
                                               name: AVCaptureSession.wasInterruptedNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(captureResumed),
                                               name: AVCaptureSession.interruptionEndedNotification, object: session)
        configure()
    }

    private func configure() {
        session.beginConfiguration()
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            reportUnavailable()
            return
        }
        session.addInput(input)
        captureDevice = device
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            reportUnavailable()
            return
        }
        session.addOutput(output)
        metadataOutput = output
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            session.commitConfiguration()
            reportUnavailable()
            return
        }
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        // A preview-layer conversion before the first camera frame can produce an empty
        // or stale region. Decode the full sensor frame; the brackets are visual guidance.
        output.rectOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.unlockForConfiguration()
        } catch { /* Camera defaults still permit scanning if focus configuration is refused. */ }
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
        isConfigured = true
        Task { @MainActor [weak self] in
            self?.onTorchStatus?(device.hasTorch && device.isTorchAvailable, false)
        }
        setScanning(isScanning)
    }

    private func reportUnavailable() {
        Task { @MainActor [weak self] in self?.onUnavailable?() }
    }

    func setScanning(_ enabled: Bool) {
        isScanning = enabled
        guard isConfigured else { return }
        sessionQueue.async { [session] in
            if enabled {
                if !session.isRunning { session.startRunning() }
            } else if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func setTorch(_ enabled: Bool) {
        guard enabled != requestedTorch else { return }
        requestedTorch = enabled
        guard let device = captureDevice, device.hasTorch else { return }
        // Torch and capture lifecycle share one queue, so dismissal cannot leave the light on.
        sessionQueue.async { [weak self] in
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if enabled && device.isTorchAvailable {
                    try device.setTorchModeOn(level: min(0.6, AVCaptureDevice.maxAvailableTorchLevel))
                } else {
                    device.torchMode = .off
                }
            } catch { /* Reflect the actual hardware state below, including thermal refusal. */ }
            Task { @MainActor [weak self] in
                self?.onTorchStatus?(device.hasTorch && device.isTorchAvailable, device.isTorchActive)
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        updatePreviewOrientation()
    }

    private func updatePreviewOrientation() {
        guard let connection = preview?.connection else { return }
        let angle: CGFloat
        switch view.window?.windowScene?.interfaceOrientation {
        case .landscapeLeft: angle = 0
        case .landscapeRight: angle = 180
        case .portraitUpsideDown: angle = 270
        default: angle = 90
        }
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
    }

    @objc nonisolated private func captureStarted() {
        Task { @MainActor [weak self] in
            guard let self, self.isScanning else { return }
            self.view.setNeedsLayout()
            if let device = self.captureDevice {
                self.onTorchStatus?(device.hasTorch && device.isTorchAvailable, device.isTorchActive)
            }
        }
    }

    @objc nonisolated private func captureFailed() {
        Task { @MainActor [weak self] in
            guard let self, self.isScanning else { return }
            self.reportUnavailable()
        }
    }

    @objc nonisolated private func captureInterrupted() {
        Task { @MainActor [weak self] in
            guard let self, self.isScanning else { return }
            self.setTorch(false)
            self.reportUnavailable()
        }
    }

    @objc nonisolated private func captureResumed() {
        Task { @MainActor [weak self] in
            guard let self, self.isScanning else { return }
            self.setScanning(true)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        setTorch(false)
        setScanning(false)
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard isScanning else { return }
        for case let object as AVMetadataMachineReadableCodeObject in objects {
            if object.type == .qr, let value = object.stringValue {
                onCode?(value)
                return
            }
        }
    }
}
