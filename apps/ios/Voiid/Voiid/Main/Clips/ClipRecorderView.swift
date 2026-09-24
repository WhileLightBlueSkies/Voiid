//
//  ClipRecorderView.swift
//  Voiid
//
//  The Clips recorder. Built to the Voiid Ui reference (Chat/ClipRecorderScreen.swift) and
//  run on the real camera engine (ClipCameraEngine.swift), which records, banks takes and
//  joins them. It replaced the old ClipCameraView screen outright.
//
//  ── THE LAYOUT ──────────────────────────────────────────────────────────────────
//  The frame is the screen. Around it:
//    • top    — close, and the timer (only once there is something to time)
//    • right  — a vertical tool column: flip, flash, speed, timer, grid. It fades out while
//               recording so the shot is unobstructed.
//    • bottom — ONE row: effects + upload on the left, the shutter in the middle, undo +
//               next on the right. Zoom and clip length sit just above and below it, small.
//  Faces and colour filters live in an Effects tray with two tabs: they are chosen once per
//  clip, not touched throughout it, so they do not need to live on screen.
//
//  ── PROGRESS LIVES ON THE SHUTTER ───────────────────────────────────────────────
//  A ring around the shutter fills as you record, with a notch at the end of each take — the
//  thumb is on the shutter, so that is where the eye already is. A thin segmented bar is kept
//  up top as well, for the moment you glance up.
//

import SwiftUI
import PhotosUI
import Photos
import CoreImage

private enum RecorderTab: String, CaseIterable { case faces = "Faces", filters = "Filters" }

private extension ClipFaceEffect {
    /// The tray shows faces, not symbols — the reference's emoji glyphs.
    var glyph: String {
        switch self {
        case .none: return ""
        case .dog: return "🐶"
        case .tiger: return "🐯"
        case .party: return "🥳"
        case .cyber: return "🤖"
        case .bunny: return "🐰"
        case .koala: return "🐨"
        case .cat: return "🐱"
        case .sunglasses: return "😎"
        case .crown: return "👑"
        case .halo: return "😇"
        case .devil: return "😈"
        }
    }
}

struct ClipRecorderView: View {
    /// Owned by the composer, so the takes survive the push to the editor and back.
    @ObservedObject var cam: ClipCameraController
    /// The joined recording plus the filter chosen in the viewfinder. The filter is passed as
    /// an EDIT, never burnt into the file, so the editor can still change it.
    var onDone: (URL, ClipFilter) -> Void
    /// A video chosen from the library, through the composer's own intake.
    var onGalleryPicked: (PhotosPickerItem) -> Void
    var onClose: () -> Void

    /// The clip's length. Defaults to the whole allowance (2 minutes, MAX_DURATION_MS in the
    /// API); the shorter lengths are a choice, not a limit to discover mid-take.
    @State private var maxSeconds: Double = ClipCaps.maxDurationSeconds
    @State private var lockedTake = false
    @State private var pressed = false
    @State private var pressBegan = Date()
    @State private var consumeRelease = false

    @State private var showGrid = false
    @State private var timerSeconds = 0
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var showSpeed = false

    @State private var showEffects = false
    @State private var effectsTab: RecorderTab = .faces
    /// A frame from the viewfinder, for the filter thumbnails — your shot in each look.
    @State private var filterSample: CIImage?
    @State private var filterThumbs: [ClipFilter: UIImage] = [:]

    @State private var confirmDiscard = false
    @State private var joining = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var galleryThumb: UIImage?
    @State private var confirmImport = false
    @State private var pendingImport: PhotosPickerItem?

    private var recording: Bool { cam.isRecording }
    private var total: Double { cam.bankedSeconds + cam.liveSeconds }
    private var full: Bool { total >= maxSeconds - 0.05 }
    private var hasTakes: Bool { !cam.takes.isEmpty }
    private var lengths: [Double] { [15, 30, 60, 120].filter { $0 <= ClipCaps.maxDurationSeconds } }

    var body: some View {
        ZStack {
            viewfinder

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
                if let text = cam.errorText { errorBanner(text) }
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

            if joining {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    ProgressView("Putting your takes together…")
                        .tint(.white)
                        .foregroundColor(.white)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .confirmationDialog("Discard this clip?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { close() }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("The \(cam.takes.count) take\(cam.takes.count == 1 ? "" : "s") you've recorded will be lost.")
        }
        .confirmationDialog("Use a video from your library?", isPresented: $confirmImport,
                            titleVisibility: .visible) {
            Button("Discard takes and import", role: .destructive) {
                if let item = pendingImport {
                    cam.discardTakes()
                    onGalleryPicked(item)
                }
                pendingImport = nil
            }
            Button("Keep recording", role: .cancel) { pendingImport = nil }
        } message: {
            Text("The \(cam.takes.count) take\(cam.takes.count == 1 ? "" : "s") you've recorded will be discarded.")
        }
        .onAppear {
            cam.maxSeconds = maxSeconds
            cam.start()
            loadGalleryThumb()
        }
        .onDisappear {
            // The countdown outlives the view unless cancelled — it would start a take on a
            // session `cam.stop()` just tore down.
            cancelCountdown()
            cam.stop()
        }
        .onChange(of: maxSeconds) { _, s in cam.maxSeconds = s }
        .onChange(of: cam.isRecording) { _, on in if !on { lockedTake = false } }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            // An import replaces the takes, so ask first rather than silently binning work.
            if cam.takes.isEmpty {
                onGalleryPicked(item)
            } else {
                pendingImport = item
                confirmImport = true
            }
        }
    }

    // MARK: Viewfinder

    private var viewfinder: some View {
        ClipCameraPreview(renderer: cam.renderer,
                          onZoom: { cam.zoom(scale: $0, began: $1) },
                          onFocus: { cam.focus(atNormalizedViewPoint: $0) },
                          onFlip: { flip() })
            .ignoresSafeArea()
    }

    private var grid: some View {
        GeometryReader { geo in
            Path { p in
                for i in 1...2 {
                    let x = geo.size.width * CGFloat(i) / 3
                    let y = geo.size.height * CGFloat(i) / 3
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
        VStack(spacing: 10) {
            segmentBar
                .opacity(hasTakes || recording ? 1 : 0)

            ZStack {
                if hasTakes || recording {
                    HStack(spacing: 6) {
                        if recording {
                            Circle().fill(VoiidColor.error).frame(width: 7, height: 7)
                        }
                        Text("\(Self.clock(total)) / \(Self.clock(maxSeconds))")
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
                    glassButton("xmark", label: "Close") {
                        if hasTakes { confirmDiscard = true } else { close() }
                    }
                    .opacity(recording ? 0 : 1)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var segmentBar: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(cam.takes) { take in
                    Capsule().fill(.white)
                        .frame(width: max(3, geo.size.width * take.outputSeconds / maxSeconds))
                }
                if recording {
                    Capsule().fill(VoiidColor.error)
                        .frame(width: max(3, geo.size.width * cam.liveSeconds / maxSeconds))
                }
                Spacer(minLength: 0)
            }
            .background(Capsule().fill(.white.opacity(0.2)))
        }
        .frame(height: 3)
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .font(VoiidFont.footnote)
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, VoiidSpacing.sm)
            .background(Color.black.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.sm, style: .continuous))
            .padding(.horizontal, VoiidSpacing.lg)
            .padding(.top, 10)
            .onTapGesture { cam.errorText = nil }
    }

    // MARK: Right column

    private var toolColumn: some View {
        VStack(spacing: 14) {
            tool(cam.isFront ? "arrow.triangle.2.circlepath.camera.fill" : "arrow.triangle.2.circlepath.camera",
                 "Flip") { flip() }
            if cam.hasTorch {
                tool(cam.torchOn ? "bolt.fill" : "bolt.slash", "Flash", active: cam.torchOn) {
                    Haptics.tap(); cam.toggleTorch()
                }
            }
            tool("speedometer", cam.selectedSpeed == 1 ? "Speed" : ClipSpeed.label(cam.selectedSpeed),
                 active: cam.selectedSpeed != 1 || showSpeed) {
                Haptics.tap()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showSpeed.toggle() }
            }
            tool("timer", timerSeconds == 0 ? "Timer" : "\(timerSeconds)s", active: timerSeconds != 0) {
                Haptics.tap()
                timerSeconds = timerSeconds == 0 ? 3 : (timerSeconds == 3 ? 10 : 0)
            }
            tool("square.grid.3x3", "Grid", active: showGrid) {
                Haptics.tap(); showGrid.toggle()
            }
        }
    }

    private func tool(_ icon: String, _ label: String, active: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(active ? .black : .white)
                    .frame(width: 42, height: 42)
                    .background(
                        Circle().fill(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial))
                    )
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
            if showSpeed && !recording { speedPicker.transition(.move(edge: .bottom).combined(with: .opacity)) }
            // Zoom is the real lenses of this phone; a face lens runs on the front camera
            // through ARKit, which has no zoom.
            if !cam.lensActive && cam.availableZoomPresets.count > 1 { zoomPill }
            shutterRow
            if !hasTakes && !recording {
                lengthPicker.transition(.opacity)
            } else {
                Text(recording ? (lockedTake ? "Tap to stop" : "Release to stop") : "Hold or tap to add another take")
                    .font(VoiidFont.rounded(12, .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(height: 30)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 10)
        .padding(.top, 60)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
        .animation(.easeOut(duration: 0.2), value: hasTakes)
        .animation(.easeOut(duration: 0.2), value: recording)
    }

    private var zoomPill: some View {
        let current = cam.currentZoom
        // The preset nearest the live zoom is the lit one, so a pinch still lands on a pill.
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
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: lit)
    }

    private var speedPicker: some View {
        HStack(spacing: 4) {
            ForEach(ClipSpeed.options, id: \.self) { s in
                Button {
                    Haptics.selection()
                    cam.selectedSpeed = s
                } label: {
                    Text(ClipSpeed.label(s))
                        .font(VoiidFont.rounded(13, .semibold))
                        .foregroundColor(cam.selectedSpeed == s ? .black : .white)
                        .frame(width: 54, height: 34)
                        .background(Capsule().fill(cam.selectedSpeed == s ? Color.white : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    private var shutterRow: some View {
        HStack(alignment: .center, spacing: 0) {
            // Left: effects, then upload. Effects first — it changes the shot you are about to
            // take; the upload replaces it.
            HStack(spacing: 18) {
                let styled = cam.faceEffect != .none || cam.filter != .none
                sideButton(styled ? "face.smiling.inverse" : "face.smiling", "Effects", highlight: styled) {
                    Haptics.tap()
                    openEffects()
                }
                .opacity(recording ? 0 : 1)
                .disabled(recording)
                galleryButton
                    .opacity(recording || hasTakes ? 0 : 1)
                    .disabled(recording || hasTakes)
            }
            .frame(maxWidth: .infinity)

            shutter

            // Right: undo, then next — only once there is a take to act on.
            HStack(spacing: 18) {
                if hasTakes && !recording {
                    sideButton("delete.left", "Undo") {
                        Haptics.tap()
                        withAnimation(.easeOut(duration: 0.2)) { cam.undoLastTake() }
                    }
                    .transition(.scale.combined(with: .opacity))
                    Button {
                        Haptics.success()
                        commit()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(VoiidColor.textOnAccent)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(VoiidColor.accent))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Next")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
    }

    /// Tap = a locked take that runs until the next tap. Hold = a take that ends on release,
    /// for a burst of short segments. Under a third of a second counts as a tap.
    private var shutter: some View {
        let progress = min(1, total / maxSeconds)
        return ZStack {
            Circle()
                .stroke(.white.opacity(0.35), lineWidth: 5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(recording ? VoiidColor.error : VoiidColor.accent,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            ForEach(Array(takeEnds.enumerated()), id: \.offset) { _, end in
                Capsule()
                    .fill(.black)
                    .frame(width: 3, height: 9)
                    .offset(y: -41)
                    .rotationEffect(.degrees(360 * end / maxSeconds))
            }
            RoundedRectangle(cornerRadius: recording ? 9 : 31, style: .continuous)
                .fill(recording ? VoiidColor.error : .white)
                .frame(width: recording ? 32 : 62, height: recording ? 32 : 62)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: recording)
        }
        .frame(width: 82, height: 82)
        .scaleEffect(recording && !lockedTake ? 1.12 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: recording)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true; pressDown() } }
                .onEnded { _ in pressed = false; pressUp() }
        )
        .opacity(full && !recording ? 0.5 : 1)
        .accessibilityLabel(recording ? "Stop recording" : "Record")
        .accessibilityAddTraits(.isButton)
    }

    private var takeEnds: [Double] {
        var sum = 0.0
        return cam.takes.map { sum += $0.outputSeconds; return sum }
    }

    private var lengthPicker: some View {
        HStack(spacing: 22) {
            ForEach(lengths, id: \.self) { s in
                Button {
                    Haptics.selection()
                    withAnimation(.easeOut(duration: 0.15)) { maxSeconds = s }
                } label: {
                    VStack(spacing: 4) {
                        Text(s >= 120 ? "2m" : "\(Int(s))s")
                            .font(VoiidFont.rounded(13.5, maxSeconds == s ? .bold : .medium))
                            .foregroundColor(maxSeconds == s ? .white : .white.opacity(0.6))
                        Circle()
                            .fill(maxSeconds == s ? Color.white : Color.clear)
                            .frame(width: 4, height: 4)
                    }
                    .frame(minWidth: 36, minHeight: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(s >= 120 ? "2 minute clip" : "\(Int(s)) second clip")
                .accessibilityAddTraits(maxSeconds == s ? [.isSelected] : [])
            }
        }
    }

    private var galleryButton: some View {
        PhotosPicker(selection: $pickerItem, matching: .videos, photoLibrary: .shared()) {
            VStack(spacing: 4) {
                Group {
                    if let galleryThumb {
                        Image(uiImage: galleryThumb).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.white.opacity(0.15))
                    }
                }
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white, lineWidth: 1.5))
                Text("Upload")
                    .font(VoiidFont.rounded(10.5, .semibold))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Upload a video from your library")
    }

    private func sideButton(_ icon: String, _ label: String, highlight: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
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

    // MARK: Effects tray

    private var effectsTray: some View {
        ZStack(alignment: .bottom) {
            // Tapping the frame closes the tray — you are back to looking at the shot.
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { closeEffects() }

            VStack(spacing: 14) {
                Capsule().fill(.white.opacity(0.35)).frame(width: 36, height: 4).padding(.top, 8)

                HStack(spacing: 0) {
                    ForEach(RecorderTab.allCases, id: \.self) { tab in
                        Button {
                            Haptics.selection()
                            withAnimation(.easeOut(duration: 0.18)) { effectsTab = tab }
                        } label: {
                            VStack(spacing: 6) {
                                Text(tab.rawValue)
                                    .font(VoiidFont.rounded(14, .semibold))
                                    .foregroundColor(effectsTab == tab ? .white : .white.opacity(0.55))
                                Capsule()
                                    .fill(effectsTab == tab ? Color.white : Color.clear)
                                    .frame(width: 24, height: 2.5)
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

                HStack {
                    Spacer()
                    Button {
                        Haptics.tap()
                        closeEffects()
                    } label: {
                        Text("Done")
                            .font(VoiidFont.rounded(15, .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 28)
                            .frame(height: 42)
                            .background(Capsule().fill(.white))
                    }
                    .buttonStyle(PressableButtonStyle())
                    Spacer()
                }
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .ignoresSafeArea(edges: .bottom)
            )
            .transition(.move(edge: .bottom))
        }
    }

    private func effectCell<C: View>(selected: Bool, label: String,
                                     @ViewBuilder content: () -> C,
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
        withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) { showEffects = true }
        // The filter thumbnails are YOUR shot in each look, taken from the live frame now.
        cam.grabFrame { image in
            guard let cg = image?.cgImage else { return }
            let sample = CIImage(cgImage: cg)
            let scale = 140 / max(sample.extent.width, 1)
            let small = sample.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            // Ten 140-pixel renders: quick enough to do here, on the main actor.
            Task { @MainActor in
                let context = CIContext(options: [.cacheIntermediates: false])
                var thumbs: [ClipFilter: UIImage] = [:]
                for filter in ClipFilter.allCases {
                    let out = filter.apply(to: small)
                    if let cg = context.createCGImage(out, from: out.extent) {
                        thumbs[filter] = UIImage(cgImage: cg)
                    }
                }
                filterThumbs = thumbs
            }
        }
    }

    private func closeEffects() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { showEffects = false }
    }

    // MARK: Helpers

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

    private func close() {
        cancelCountdown()
        cam.stop()
        cam.discardTakes()
        onClose()
    }

    // MARK: Recording

    private func pressDown() {
        if recording {
            // A second press ends a locked take.
            cam.stopRecording()
            consumeRelease = true
            return
        }
        if countdown != nil { cancelCountdown(); consumeRelease = true; return }
        guard !full else { return }
        consumeRelease = false
        pressBegan = Date()
        if timerSeconds > 0 {
            consumeRelease = true
            startCountdown()
        } else {
            startTake(locked: false)
        }
    }

    private func pressUp() {
        if consumeRelease { consumeRelease = false; return }
        guard recording else { return }
        if Date().timeIntervalSince(pressBegan) < 0.35 {
            // A tap: keep going until the next tap.
            lockedTake = true
        } else {
            cam.stopRecording()
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            for n in stride(from: timerSeconds, through: 1, by: -1) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { countdown = n }
                Haptics.tap()
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdown = nil
            // One take per countdown — the timer is for getting into shot, not a mode.
            timerSeconds = 0
            startTake(locked: true)
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        withAnimation { countdown = nil }
    }

    private func startTake(locked: Bool) {
        showSpeed = false
        lockedTake = locked
        cam.startRecording()
    }

    private func commit() {
        let takes = cam.takes
        guard !takes.isEmpty else { return }
        joining = true
        let filter = cam.filter
        Task {
            // The takes are KEPT: back from the editor lands here with them all, ready for
            // another. The composer deletes them once the clip is posted or closed.
            let joined = await ClipTakeJoiner.join(takes: takes, consumeTakes: false)
            await MainActor.run {
                joining = false
                guard let joined else {
                    cam.errorText = "Couldn't put those takes together."
                    return
                }
                onDone(joined, filter)
            }
        }
    }

    private func loadGalleryThumb() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let options = PHFetchOptions()
            options.fetchLimit = 1
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            guard let asset = PHAsset.fetchAssets(with: .video, options: options).firstObject else { return }
            let request = PHImageRequestOptions()
            request.deliveryMode = .opportunistic
            request.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 156, height: 156),
                contentMode: .aspectFill, options: request
            ) { image, _ in
                guard let image else { return }
                DispatchQueue.main.async { galleryThumb = image }
            }
        }
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
