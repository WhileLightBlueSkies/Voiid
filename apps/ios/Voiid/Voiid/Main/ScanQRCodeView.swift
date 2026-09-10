//
//  ScanQRCodeView.swift
//  Voiid
//
//  A scan supplies a validated handle. Lookup, Contact PIN and request acceptance
//  remain in FindByUsernameView; the confirmation here only means the QR was read.
//

import SwiftUI
import AVFoundation

@MainActor
struct ScanQRCodeView: View {
    var onCommunityScan: ((CommunityLink) -> Void)? = nil
    var onScan: (ProfileLink) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var permission: AVAuthorizationStatus = .notDetermined
    @State private var cameraUnavailable = false
    @State private var rejected = false
    @State private var capturedCommunity: CommunityLink?
    @State private var capturedLink: ProfileLink?
    @State private var confirmed = false
    @State private var sweeping = false
    @State private var handoffTask: Task<Void, Never>?
    @State private var rejectionTask: Task<Void, Never>?

    private var captured: Bool { capturedLink != nil || capturedCommunity != nil }
    private var motion: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 1)
    }
    private var showsViewfinder: Bool {
        #if targetEnvironment(simulator) && DEBUG
        return true
        #else
        return permission == .authorized && !cameraUnavailable
        #endif
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if permission == .authorized && !cameraUnavailable {
                    CameraPreview(isScanning: !captured && scenePhase == .active,
                                  onCode: accept,
                                  onUnavailable: { cameraUnavailable = true })
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                }

                // Sits BETWEEN the camera and the viewfinder, so the window cut out of the
                // reticle's scrim is never dimmed twice. Cancel and the title need a ground
                // — white on a live camera is legible only by luck — and a gradient gives
                // them one without a bar, so the top edge reads as this surface fading out
                // rather than as chrome laid over a picture. Mirrors the footer exactly.
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.5), .black.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 150)
                    Spacer(minLength: 0)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)

                if showsViewfinder || captured {
                    reticle
                } else if permission == .notDetermined {
                    ProgressView().tint(.white)
                } else {
                    deniedMessage
                }

            }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomChrome }
            .navigationTitle("Scan code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancelPendingWork()
                        dismiss()
                    }
                    .foregroundStyle(.white)
                }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await requestAccess()
            }
            .onDisappear { cancelPendingWork() }
        }
        .preferredColorScheme(.dark)
    }

    private var reticle: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - 64, geo.size.height * 0.58, 280)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.44)
            let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2,
                              width: side, height: side)
            ZStack {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRoundedRect(in: rect, cornerSize: CGSize(width: 28, height: 28))
                }
                .fill(.black.opacity(captured ? 0.85 : 0.52), style: FillStyle(eoFill: true))

                #if targetEnvironment(simulator) && DEBUG
                // A visible target makes the simulator useful even without camera hardware.
                RoundedRectangle(cornerRadius: 24)
                    .fill(VoiidColor.surfaceRaised)
                    .overlay {
                        Image(systemName: "qrcode")
                            .font(.system(size: side * 0.56, weight: .regular))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .frame(width: side - 28, height: side - 28)
                    .opacity(captured ? 0 : 1)
                    .position(center)
                    .accessibilityHidden(true)
                #endif

                ZStack {
                    // NO FILL. The window is a hole in the scrim and must stay one: any
                    // tint over it, even at 0.025, is a colour cast on the one part of the
                    // frame the camera is actually being judged on. It also fights the
                    // scanner itself — a QR is read by contrast, and washing the feed is
                    // the one thing a viewfinder must never do to what it is looking at.
                    ScanBrackets(inset: 0, color: captured ? VoiidColor.accentInk : .white)
                    if !captured { laser(side: side) }
                }
                .frame(width: side, height: side)
                .scaleEffect(captured && !reduceMotion ? 0.94 : 1)
                .opacity(confirmed ? 0 : 1)
                .position(center)
                .accessibilityHidden(true)

                if captured {
                    confirmation(handle: capturedCommunity?.handle ?? capturedLink?.username ?? "")
                        .frame(width: min(geo.size.width - 40, 340))
                        .scaleEffect(confirmed || reduceMotion ? 1 : 0.95)
                        .opacity(confirmed ? 1 : 0)
                        .position(x: center.x, y: center.y + (confirmed || reduceMotion ? 0 : 12))
                }

                VStack(spacing: 8) {
                    Text("Scan. Connect.")
                        .font(VoiidFont.rounded(25, .bold))
                        .tracking(-0.6)
                    Text("Scan a Voiid profile or community code")
                        .font(VoiidFont.rounded(14, .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .fixedSize(horizontal: false, vertical: true)
                .position(x: center.x, y: rect.maxY + 56)
                .opacity(captured ? 0 : 1)
                .accessibilityHidden(captured)
            }
            .animation(motion, value: captured)
            .animation(motion, value: confirmed)
        }
    }

    private func confirmation(handle: String) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .stroke(VoiidColor.accentInk.opacity(0.2), lineWidth: 1)
                    .frame(width: 108, height: 108)
                    .scaleEffect(confirmed && !reduceMotion ? 1.18 : 1)
                    .opacity(confirmed ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: confirmed)
                Circle().fill(VoiidColor.accent.opacity(0.12))
                    .frame(width: 112, height: 112)
                Circle().fill(VoiidColor.accent.opacity(0.16))
                    .frame(width: 92, height: 92)
                Circle()
                    .fill(VoiidColor.accent.gradient)
                    .frame(width: 72, height: 72)
                    .shadow(color: VoiidColor.accent.opacity(0.3), radius: 18, y: 6)
                ScanCheckmark()
                    .trim(from: 0, to: confirmed ? 1 : 0)
                    .stroke(.white, style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 30, height: 23)
                    .animation(.easeOut(duration: reduceMotion ? 0 : 0.25).delay(reduceMotion ? 0 : 0.08),
                               value: confirmed)
            }
            .frame(height: 120)
            .accessibilityHidden(true)

            Text("Code scanned")
                .font(VoiidFont.rounded(26, .bold))
                .tracking(-0.6)
                .padding(.top, 14)
            Text("You’re one step closer.")
                .font(VoiidFont.rounded(15, .medium))
                .foregroundStyle(VoiidColor.textSecondary)
                .padding(.top, 6)

            HStack(spacing: 12) {
                Text(String(handle.prefix(1)).uppercased())
                    .font(VoiidFont.rounded(19, .bold))
                    .foregroundStyle(VoiidColor.accentInk)
                    .frame(width: 46, height: 46)
                    .background(VoiidColor.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 4) {
                    Text("@\(handle)")
                        .font(VoiidFont.rounded(17, .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("Voiid profile code")
                        .font(VoiidFont.rounded(12, .medium))
                        .foregroundStyle(VoiidColor.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VoiidColor.accentInk)
            }
            .padding(14)
            .background(VoiidColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 20))
            .padding(.top, 24)

            Label(capturedCommunity == nil ? "Next, enter their Contact PIN" : "Review the community before joining", systemImage: "lock.fill")
                .font(VoiidFont.rounded(12, .medium))
                .foregroundStyle(VoiidColor.textSecondary)
                .padding(.top, 20)
        }
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 32)
                .fill(VoiidColor.surfaceCard)
                .overlay {
                    RoundedRectangle(cornerRadius: 32)
                        .strokeBorder(LinearGradient(colors: [VoiidColor.accentInk.opacity(0.4),
                                                              .white.opacity(0.06)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing),
                                      lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scan.confirmation")
    }

    /// The sweep.
    ///
    /// ── EASE-IN-OUT, NOT LINEAR ────────────────────────────────────────────────
    /// A linear sweep that reverses has a velocity discontinuity at each end: the beam is
    /// travelling at full speed, then instantly at full speed the other way. The eye reads
    /// that as a mechanical tick — the "brick wall" a reversal makes when velocity is not
    /// carried through it. `easeInOut` decelerates into the turn and accelerates out, which
    /// is what a real thing sweeping back and forth does, and it is the difference between
    /// this looking like a scanner and looking like a loading bar.
    ///
    /// ── AND IT BREATHES ────────────────────────────────────────────────────────
    /// The beam dims at the extremes and is brightest mid-travel. A constant-opacity line
    /// pinging between two edges is the single most dated thing about a scanner; tying
    /// brightness to travel makes the sweep read as one continuous gesture instead of two
    /// end points.
    private func laser(side: CGFloat) -> some View {
        let travel = side / 2 - 26
        return ZStack {
            // The wake: what the beam has just passed over, so the sweep has a direction
            // rather than being a line that merely exists in two places.
            LinearGradient(colors: [.clear, VoiidColor.accentInk.opacity(0.20)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 44)
                .offset(y: -22)
            Capsule()
                .fill(LinearGradient(colors: [.clear, VoiidColor.accentInk, .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 2)
                .shadow(color: VoiidColor.accentInk.opacity(0.55), radius: 9)
        }
        .frame(width: side - 24)
        .opacity(sweeping ? 1 : 0.35)
        .offset(y: reduceMotion ? 0 : (sweeping ? travel : -travel))
        .animation(reduceMotion ? nil
                                : .easeInOut(duration: 1.9).repeatForever(autoreverses: true),
                   value: sweeping)
        .onAppear { sweeping = true }
        .onDisappear { sweeping = false }
        .allowsHitTesting(false)
    }

    private var bottomChrome: some View {
        VStack(spacing: 18) {
            if rejected {
                Label("That isn’t a Voiid code. Try another.", systemImage: "qrcode")
                    .font(VoiidFont.rounded(13, .medium))
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(VoiidColor.surfaceRaised, in: Capsule())
                    .transition(.opacity)
                    .accessibilityIdentifier("scan.invalidCode")
            }
            #if DEBUG
            if !captured {
                Button {
                    accept("https://voiid.app/u/arjundev")
                } label: {
                    Label("Simulate scan", systemImage: "qrcode.viewfinder")
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 15)
                        .background(VoiidColor.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("scan.simulate")
            }
            #endif
            Label(captured ? "Your connection starts with a request" : "Their code. Your next conversation.",
                  systemImage: "lock.shield")
                .font(VoiidFont.rounded(12, .medium))
                .foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 24)
        // Reserve the same footer space during capture so its disappearance cannot
        // move the viewfinder underneath the confirmation animation.
        .frame(minHeight: 130, alignment: .bottom)
        // ── ONE SURFACE, NOT TWO ───────────────────────────────────────────────────
        // This was `.background(.black)`, which cut the camera off at a straight opaque
        // edge — the sheet read as a viewfinder with a control bar bolted under it. The
        // scrim over the camera is already black at 0.52, so a gradient that starts at
        // clear and ARRIVES at that same value continues the dim instead of interrupting
        // it: the chrome is the bottom of one surface, not a second one.
        //
        // The skill's rule for exactly this: fade where content meets floating chrome,
        // never a hard divider.
        .background {
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.55), .black],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var deniedMessage: some View {
        VStack(spacing: VoiidSpacing.md) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.6))
            Text(cameraUnavailable ? "Camera unavailable" : "Camera access is off")
                .font(VoiidFont.rounded(17, .semibold))
                .foregroundStyle(.white)
            Text(cameraUnavailable ? "Close the scanner and try again." : "Turn it on in Settings to scan a code.")
                .font(VoiidFont.subhead)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            if !cameraUnavailable, let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url)
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundStyle(VoiidColor.accentInk)
                    .padding(.top, VoiidSpacing.sm)
            }
        }
        .padding(VoiidSpacing.lg)
    }

    private func requestAccess() async {
        #if targetEnvironment(simulator) && DEBUG
        permission = .denied
        #else
        let current = AVCaptureDevice.authorizationStatus(for: .video)
        if current == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard !Task.isCancelled else { return }
        permission = AVCaptureDevice.authorizationStatus(for: .video)
        #endif
    }

    private func accept(_ raw: String) {
        guard !captured else { return }
        let community = CommunityLink.parse(URL(string: raw))
        let profile = ProfileLink.parse(URL(string: raw))
        guard profile != nil || (community != nil && onCommunityScan != nil) else {
            guard !rejected else { return }
            Haptics.error()
            withAnimation(.easeOut(duration: 0.2)) { rejected = true }
            rejectionTask = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(1.6)) } catch { return }
                withAnimation(.easeOut(duration: 0.2)) { rejected = false }
            }
            return
        }
        rejectionTask?.cancel()
        rejected = false
        capturedLink = profile
        capturedCommunity = community
        Haptics.success()
        UIAccessibility.post(notification: .announcement, argument: "Code scanned. @\(community?.handle ?? profile?.username ?? "").")
        handoffTask = Task { @MainActor in
            do {
                // Brief frame lock, then the identity card settles and the check draws.
                try await Task.sleep(for: .milliseconds(reduceMotion ? 40 : 120))
                confirmed = true
                try await Task.sleep(for: .milliseconds(UIAccessibility.isVoiceOverRunning ? 1800 : 950))
            } catch { return }
            guard !Task.isCancelled else { return }
            if let community { onCommunityScan?(community) }
            else if let profile { onScan(profile) }
            dismiss()
        }
    }

    private func cancelPendingWork() {
        handoffTask?.cancel()
        rejectionTask?.cancel()
    }
}

private struct ScanCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.width * 0.36, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
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

private struct CameraPreview: UIViewControllerRepresentable {
    let isScanning: Bool
    let onCode: (String) -> Void
    let onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onUnavailable = onUnavailable
        controller.setScanning(isScanning)
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onCode = onCode
        controller.setScanning(isScanning)
    }

    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) {
        controller.onCode = nil
        controller.setScanning(false)
    }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onUnavailable: (() -> Void)?

    private let session = AVCaptureSession()
    // One queue preserves start/stop order, including dismissal during camera startup.
    private let sessionQueue = DispatchQueue(label: "app.voiid.qr-camera", qos: .userInitiated)
    private var preview: AVCaptureVideoPreviewLayer?
    private var isScanning = false
    private var isConfigured = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
    }

    private func configure() {
        session.beginConfiguration()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            reportUnavailable()
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            reportUnavailable()
            return
        }
        session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            session.commitConfiguration()
            reportUnavailable()
            return
        }
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
        isConfigured = true
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
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
