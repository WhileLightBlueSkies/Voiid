//
//  StoryCameraView.swift
//  Voiid
//
//  The in-app camera for everything that is not the clips recorder: moments, chat photos and
//  the profile photo. Built to the Voiid Ui reference (Chat/MomentCameraScreen.swift) and run on
//  the clips camera engine (ClipCameraController), so the faces and looks are the same ones.
//
//  ── ONE CAMERA LANGUAGE ─────────────────────────────────────────────────────────
//  The same layout as the Clips recorder: the frame is the screen, tools in a column on the
//  right (flip, flash, timer, grid), effects bottom-left, zoom above the shutter. A moment is a
//  single capture: TAP for a photo, HOLD for a video — the ring fills to the limit — and let go.
//
//  Photo → JPEG taken from the processed frame (so the face and look are IN the photo);
//  video → a temp .mp4 with the face burned in at capture. The composer applies the caps.
//
//  `mode` decides what a presentation may produce — see CameraMode. A chat photo and a
//  profile photo are stills only (no hold, no microphone); a profile photo opens on the front
//  camera behind a circle guide and is cropped square.
//

import Combine
import SwiftUI
import AVFoundation
import CoreImage

/// What a given presentation of the camera is allowed to produce.
struct CameraMode {
    var maxSeconds: Int
    /// When true the shutter TAP starts/stops recording and photo capture is unreachable.
    var videoOnly: Bool
    /// Stills only: no hold-to-record and no microphone.
    var photoOnly: Bool = false
    /// Open on the front camera and crop the still square — a profile photo.
    var selfie: Bool = false

    static let story = CameraMode(maxSeconds: 30, videoOnly: false)
    static let clip = CameraMode(maxSeconds: 90, videoOnly: true)
    static let chatPhoto = CameraMode(maxSeconds: 0, videoOnly: false, photoOnly: true)
    static let profilePhoto = CameraMode(maxSeconds: 0, videoOnly: false, photoOnly: true, selfie: true)
}

private enum CameraEffectsTab: String, CaseIterable { case faces = "Faces", filters = "Filters" }

struct StoryCameraView: View {
    /// Called with a captured photo (Data, "image/jpeg") or video (temp file URL, "video/mp4").
    var mode: CameraMode = .story
    var onCapture: (_ photo: Data?, _ videoURL: URL?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var cam = ClipCameraController()

    @State private var capturing = false
    @State private var pressed = false
    @State private var pressBegan = Date()
    @State private var holdTask: Task<Void, Never>?
    /// The release after a hold ends the recording; the release after a tap takes the photo.
    @State private var heldToRecord = false

    @State private var showGrid = false
    @State private var timerSeconds = 0
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?

    @State private var showEffects = false
    @State private var effectsTab: CameraEffectsTab = .faces
    @State private var filterThumbs: [ClipFilter: UIImage] = [:]

    private var recording: Bool { cam.isRecording }
    private var progress: Double {
        mode.maxSeconds > 0 ? min(1, cam.liveSeconds / Double(mode.maxSeconds)) : 0
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ClipCameraPreview(renderer: cam.renderer,
                              onZoom: { cam.zoom(scale: $0, began: $1) },
                              onFocus: { cam.focus(atNormalizedViewPoint: $0) },
                              onFlip: { flip() })
                .ignoresSafeArea()

            if mode.selfie { selfieGuide }
            if showGrid { grid }

            if let countdown {
                Text("\(countdown)")
                    .font(.system(size: 110, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.4), radius: 14)
                    .transition(.scale(scale: 1.5).combined(with: .opacity))
                    .id(countdown)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomArea
            }

            toolColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
                .padding(.top, 70)
                .opacity(recording || showEffects ? 0 : 1)
                .allowsHitTesting(!recording && !showEffects)
                .animation(.easeOut(duration: 0.2), value: recording)

            if showEffects { effectsTray }
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .onAppear {
            cam.maxSeconds = Double(mode.maxSeconds)
            cam.wantsAudio = !mode.photoOnly
            if mode.selfie { cam.setInitialPosition(.front) }
            cam.start()
        }
        .onDisappear {
            holdTask?.cancel()
            countdownTask?.cancel()
            cam.stop()
        }
        .onChange(of: cam.takes) { _, takes in
            // One take is the whole recording here — no multi-take editor behind this camera.
            guard let take = takes.last else { return }
            cam.forgetTakes()
            onCapture(nil, take.url)
            dismiss()
        }
        .alert("Camera problem",
               isPresented: Binding(get: { cam.errorText != nil }, set: { if !$0 { cam.errorText = nil } })) {
            Button("OK", role: .cancel) { cam.errorText = nil }
        } message: {
            Text(cam.errorText ?? "")
        }
    }

    // MARK: Overlays

    /// A soft circle so a profile photo is framed where the avatar crop will land.
    private var selfieGuide: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height) * 0.78
            Circle()
                .strokeBorder(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                .frame(width: d, height: d)
                .position(x: geo.size.width / 2, y: geo.size.height * 0.42)
        }
        .allowsHitTesting(false)
    }

    private var grid: some View {
        GeometryReader { geo in
            Path { p in
                for i in 1...2 {
                    let x = geo.size.width * CGFloat(i) / 3, y = geo.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: geo.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Top

    private var topBar: some View {
        ZStack {
            if recording {
                HStack(spacing: 6) {
                    Circle().fill(VoiidColor.error).frame(width: 7, height: 7)
                    Text("\(Self.clock(cam.liveSeconds)) / \(Self.clock(Double(mode.maxSeconds)))")
                        .font(VoiidFont.rounded(14, .semibold))
                        .monospacedDigit()
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(.ultraThinMaterial, in: Capsule())
                .environment(\.colorScheme, .dark)
                .transition(.opacity)
            }
            HStack {
                glassButton("xmark", label: "Close") { dismiss() }
                    .opacity(recording ? 0 : 1)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .animation(.easeOut(duration: 0.2), value: recording)
    }

    // MARK: Tools

    private var toolColumn: some View {
        VStack(spacing: 14) {
            tool(cam.isFront ? "arrow.triangle.2.circlepath.camera.fill" : "arrow.triangle.2.circlepath.camera",
                 "Flip") { flip() }
            if cam.hasTorch {
                tool(cam.torchOn ? "bolt.fill" : "bolt.slash", "Flash", active: cam.torchOn) { cam.toggleTorch() }
            }
            tool("timer", timerSeconds == 0 ? "Timer" : "\(timerSeconds)s", active: timerSeconds != 0) {
                timerSeconds = timerSeconds == 0 ? 3 : (timerSeconds == 3 ? 10 : 0)
            }
            tool("square.grid.3x3", "Grid", active: showGrid) { showGrid.toggle() }
        }
    }

    private func tool(_ icon: String, _ label: String, active: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap(); action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(active ? .black : .white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial)))
                    .environment(\.colorScheme, .dark)
                Text(label)
                    .font(VoiidFont.rounded(10.5, .semibold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 3)
            }
            .frame(width: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    // MARK: Bottom

    private var bottomArea: some View {
        VStack(spacing: 14) {
            if !cam.lensActive && cam.availableZoomPresets.count > 1 && !recording { zoomPill }
            HStack(spacing: 0) {
                HStack {
                    let styled = cam.faceEffect != .none || cam.filter != .none
                    sideButton(styled ? "face.smiling.inverse" : "face.smiling", "Effects", highlight: styled) {
                        openEffects()
                    }
                    .opacity(recording ? 0 : 1)
                    .disabled(recording)
                }
                .frame(maxWidth: .infinity)

                shutter

                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }
            .padding(.horizontal, 16)

            Text(hint)
                .font(VoiidFont.rounded(12, .medium))
                .foregroundColor(.white.opacity(0.75))
                .frame(height: 20)
                .contentTransition(.opacity)
        }
        .padding(.bottom, 12)
        .padding(.top, 60)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    private var hint: String {
        if recording { return mode.videoOnly ? "Tap to stop" : "Release to stop" }
        if mode.photoOnly { return "Tap to take a photo" }
        if mode.videoOnly { return "Tap to record" }
        return "Tap for photo, hold for video"
    }

    private var zoomPill: some View {
        let current = cam.currentZoom
        let lit = cam.availableZoomPresets.min { abs($0 - current) < abs($1 - current) }
        return HStack(spacing: 2) {
            ForEach(cam.availableZoomPresets, id: \.self) { z in
                let active = z == lit
                Button {
                    Haptics.selection()
                    cam.setZoom(z)
                } label: {
                    Text(active ? Self.zoomLabel(current) + "×" : Self.zoomLabel(z))
                        .font(VoiidFont.rounded(active ? 12.5 : 11.5, .bold))
                        .foregroundColor(active ? VoiidColor.accent : .white)
                        .frame(width: active ? 38 : 32, height: active ? 38 : 32)
                        .background(Circle().fill(.black.opacity(active ? 0.55 : 0.3)))
                        .frame(width: 42, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(Self.zoomLabel(z))× zoom")
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 4)
        .background(Capsule().fill(.black.opacity(0.25)))
    }

    /// Tap: a photo. Hold: a video, the ring filling to the limit. Video-only: tap toggles.
    private var shutter: some View {
        ZStack {
            Circle().stroke(.white.opacity(recording ? 0.35 : 0.9), lineWidth: 5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(VoiidColor.error, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(recording ? 1 : 0)
            RoundedRectangle(cornerRadius: recording ? 9 : 32, style: .continuous)
                .fill(recording ? VoiidColor.error : .white)
                .frame(width: recording ? 32 : 64, height: recording ? 32 : 64)
        }
        .frame(width: 82, height: 82)
        .scaleEffect(recording && !mode.videoOnly ? 1.12 : (pressed || capturing ? 0.93 : 1))
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 1), value: recording)
        .animation(.easeOut(duration: 0.1), value: pressed)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true; pressDown() } }
                .onEnded { _ in pressed = false; pressUp() }
        )
        .accessibilityLabel(mode.photoOnly ? "Take photo" : (mode.videoOnly ? "Record" : "Shutter. Tap for a photo, hold for a video."))
        .accessibilityAddTraits(.isButton)
    }

    private func sideButton(_ icon: String, _ label: String, highlight: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap(); action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(highlight ? VoiidColor.accent : .white)
                    .frame(width: 38, height: 38)
                Text(label)
                    .font(VoiidFont.rounded(10.5, .semibold))
                    .foregroundColor(.white)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    // MARK: Effects

    private var effectsTray: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.001).ignoresSafeArea()
                .onTapGesture { closeEffects() }

            VStack(spacing: 14) {
                Capsule().fill(.white.opacity(0.35)).frame(width: 36, height: 4).padding(.top, 8)

                HStack(spacing: 0) {
                    ForEach(CameraEffectsTab.allCases, id: \.self) { tab in
                        Button {
                            Haptics.selection()
                            effectsTab = tab
                        } label: {
                            VStack(spacing: 6) {
                                Text(tab.rawValue)
                                    .font(VoiidFont.rounded(14, .semibold))
                                    .foregroundColor(effectsTab == tab ? .white : .white.opacity(0.55))
                                Capsule().fill(effectsTab == tab ? Color.white : .clear).frame(width: 24, height: 2.5)
                            }
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 60)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        if effectsTab == .faces {
                            ForEach(ClipFaceEffect.allCases.filter(\.isAvailable)) { f in
                                effectCell(selected: cam.faceEffect == f, label: f.label) {
                                    if f == .none {
                                        Image(systemName: "circle.slash").font(.system(size: 22)).foregroundColor(.white)
                                    } else {
                                        Text(f.glyph).font(.system(size: 30))
                                    }
                                } action: { cam.faceEffect = f }
                            }
                        } else {
                            ForEach(ClipFilter.allCases) { l in
                                effectCell(selected: cam.filter == l, label: l.label) {
                                    if let thumb = filterThumbs[l] {
                                        Image(uiImage: thumb).resizable().scaledToFill()
                                    } else {
                                        Color.white.opacity(0.12)
                                    }
                                } action: { cam.filter = l }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }

                Button {
                    Haptics.tap(); closeEffects()
                } label: {
                    Text("Done")
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 28)
                        .frame(height: 42)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .ignoresSafeArea(edges: .bottom)
            )
            .transition(reduceMotion ? .opacity : .move(edge: .bottom))
        }
    }

    private func effectCell<C: View>(selected: Bool, label: String, @ViewBuilder content: () -> C,
                                     action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.easeOut(duration: 0.15)) { action() }
        } label: {
            VStack(spacing: 6) {
                content()
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(.white.opacity(0.12)))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(selected ? VoiidColor.accent : .white.opacity(0.25),
                                             lineWidth: selected ? 3 : 1))
                Text(label)
                    .font(VoiidFont.rounded(11, selected ? .bold : .medium))
                    .foregroundColor(.white.opacity(selected ? 1 : 0.8))
                    .lineLimit(1)
            }
            .frame(width: 68)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func openEffects() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 1)) {
            showEffects = true
        }
        // The look thumbnails are YOUR shot in each look, from the live frame now.
        cam.grabFrame { image in
            guard let cg = image?.cgImage else { return }
            let sample = CIImage(cgImage: cg)
            let scale = 140 / max(sample.extent.width, 1)
            let small = sample.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            Task { @MainActor in
                let context = CIContext(options: [.cacheIntermediates: false])
                var thumbs: [ClipFilter: UIImage] = [:]
                for filter in ClipFilter.allCases {
                    let out = filter.apply(to: small)
                    if let cg = context.createCGImage(out, from: out.extent) { thumbs[filter] = UIImage(cgImage: cg) }
                }
                filterThumbs = thumbs
            }
        }
    }

    private func closeEffects() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 1)) {
            showEffects = false
        }
    }

    // MARK: Capture

    private func glassButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap(); action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    private func flip() {
        guard !recording else { return }
        Haptics.tap()
        cam.flip()
    }

    private func pressDown() {
        pressBegan = Date()
        heldToRecord = false
        if countdown != nil { cancelCountdown(); return }
        if mode.videoOnly {
            recording ? cam.stopRecording() : cam.startRecording()
            return
        }
        if timerSeconds > 0 { startCountdown(); return }
        guard !mode.photoOnly else { return }
        // Held past a beat: it is a video.
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard pressed, !Task.isCancelled, !recording else { return }
            heldToRecord = true
            cam.startRecording()
        }
    }

    private func pressUp() {
        holdTask?.cancel()
        if mode.videoOnly || countdown != nil { return }
        if heldToRecord {
            heldToRecord = false
            if recording { cam.stopRecording() }
            return
        }
        if timerSeconds > 0 { return }
        snap()
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            for n in stride(from: timerSeconds, through: 1, by: -1) {
                withAnimation(.spring(response: 0.28, dampingFraction: 1)) { countdown = n }
                Haptics.tap()
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdown = nil
            snap()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        withAnimation { countdown = nil }
    }

    private func snap() {
        guard !capturing, !recording else { return }
        capturing = true
        let square = mode.selfie
        cam.captureStill { image in
            capturing = false
            guard var image else { return }
            if square { image = Self.squareCrop(image) }
            guard let data = image.jpegData(compressionQuality: 0.88) else { return }
            onCapture(data, nil)
            dismiss()
        }
    }

    /// Centre-square crop biased toward the top, where the selfie guide sits.
    private static func squareCrop(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = cg.width, h = cg.height, side = min(w, h)
        let x = (w - side) / 2
        let y = max(0, min(h - side, Int(Double(h) * 0.42) - side / 2))
        guard let cropped = cg.cropping(to: CGRect(x: x, y: y, width: side, height: side))
        else { return image }
        return UIImage(cgImage: cropped)
    }

    private static func clock(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    private static func zoomLabel(_ v: CGFloat) -> String {
        let r = (v * 10).rounded() / 10
        if r == r.rounded() { return "\(Int(r))" }
        return r < 1 ? String(format: ".%d", Int((r * 10).rounded())) : String(format: "%.1f", r)
    }
}
