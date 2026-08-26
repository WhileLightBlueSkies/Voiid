//
//  ClipCameraView.swift
//  Voiid
//
//  The dedicated clip camera: multi-take recording with a LIVE-FILTERED viewfinder.
//
//  WHY THIS EXISTS. Clips used to borrow the story camera in a `.clip` mode, which is a
//  single-shot camera: it fires `onCapture` and dismisses the moment the first recording
//  finalizes, and the composer accepted exactly one URL. So iOS had no multi-take, no undo
//  and no banked progress while Android already had all three, and the shape of that camera
//  ruled out ever putting the filter strip in the live preview.
//
//  CAPTURE PIPELINE. Unlike the story camera this does NOT use AVCaptureMovieFileOutput or
//  AVCaptureVideoPreviewLayer — neither can render a CIFilter. Frames come off
//  AVCaptureVideoDataOutput, are filtered per-frame for the preview only, and are written to
//  disk CLEAN through an AVAssetWriter. The chosen filter travels with the finished URL and
//  is baked exactly once at export, so the edit stays non-destructive and the colour is never
//  applied twice. (The movie output and the data output do not usefully coexist in one
//  session, which is why this is a separate camera and stories are left alone.)
//
//  SEGMENTS. Each press/release is one take written to its own `clip_seg_<uuid>.mp4`. They
//  are concatenated only when the author commits: re-muxing after every stop would stall the
//  shutter for seconds on a long take. A single 1× take is handed over untouched.
//

import SwiftUI
import AVFoundation
import CoreImage
import MetalKit
import PhotosUI
import Photos
import UIKit
import Combine

// MARK: - Takes

/// One recorded segment plus the playback rate the author picked for it.
///
/// Recording always happens at 1×; the rate is applied at join time. That keeps the shutter
/// responsive and keeps the camera's output a plain recording rather than an already-rendered
/// edit — the same "produce a description, render once" rule the editor follows.
struct ClipTake: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    /// Seconds actually written to the file, i.e. real time at 1×.
    let recordedSeconds: Double
    /// 0.3…3. Applied by `ClipTakeJoiner`.
    let speed: Double

    /// Seconds this take will contribute to the FINISHED clip. A 0.3× take stretches, a 3×
    /// take shrinks — the 90s cap has to be counted in these, not in recorded seconds.
    var outputSeconds: Double { recordedSeconds / speed }
}

/// The record-rail rates, matching Instagram's set.
enum ClipSpeed {
    static let options: [Double] = [0.3, 0.5, 1, 2, 3]

    static func label(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))×" : String(format: "%.1f×", v)
    }
}

// MARK: - Screen

struct ClipCameraView: View {
    var maxSeconds: Double = ClipCaps.maxDurationSeconds
    /// The joined recording plus the filter chosen in the viewfinder. The filter is passed
    /// as an EDIT, never burnt into the file, so the editor can still change it.
    var onDone: (URL, ClipFilter) -> Void
    /// A video chosen from the library. It goes through the composer's existing intake so
    /// duration and cap validation are identical for recordings and imports.
    var onGalleryPicked: (PhotosPickerItem) -> Void
    var onClose: () -> Void

    @StateObject private var cam = ClipCameraController()

    @State private var pickerItem: PhotosPickerItem?
    @State private var galleryThumb: UIImage?
    @State private var joining = false
    @State private var confirmImport = false
    @State private var pendingImport: PhotosPickerItem?

    // Shutter gesture bookkeeping — see `shutterPressChanged`.
    @State private var showGrid = false
    /// Self-timer in seconds. 0 = off. Applies to the NEXT take only — it is a framing aid
    /// for getting into shot, not a mode you leave armed and forget.
    @State private var timerSeconds = 0
    /// Live countdown while the timer runs; nil when idle.
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?

    @State private var pressActive = false
    @State private var pressBegan = Date()
    @State private var pressConsumed = false

    private var totalSeconds: Double { cam.bankedSeconds + cam.liveSeconds }
    private var full: Bool { totalSeconds >= maxSeconds - 0.05 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ClipCameraPreview(renderer: cam.renderer,
                              onZoom: { cam.zoom(scale: $0, began: $1) },
                              onFocus: { cam.focus(atNormalizedViewPoint: $0) },
                              onFlip: { if !cam.isRecording { Haptics.tap(); cam.flip() } })
                .ignoresSafeArea()

            if showGrid { gridOverlay }

            // The countdown owns the whole screen while it runs: you are looking at the
            // frame, not at a control, so a number in a corner would be missed.
            if let countdown {
                Text("\(countdown)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(radius: 12)
                    .transition(.scale(scale: 1.4).combined(with: .opacity))
                    .id(countdown)   // re-triggers the transition on each tick
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                topBar
                progressTicks
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.top, VoiidSpacing.sm)
                Spacer(minLength: 0)
                if let text = cam.errorText {
                    Text(text)
                        .font(VoiidFont.footnote)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.vertical, VoiidSpacing.sm)
                        .background(Color.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.sm, style: .continuous))
                        .padding(.horizontal, VoiidSpacing.lg)
                }
                Spacer(minLength: 0)
                // Zoom is ALWAYS available, recording included: framing is something you
                // do both before and during a take.
                //
                // The SPEED rail is deliberately not here. It rendered "1×/2×/3×" — the
                // same strings as zoom, stacked directly above it — and did not work in
                // testing. `ClipTakeJoiner` still applies `take.speed`, and `selectedSpeed`
                // still defaults to 1, so removing the control changes nothing downstream;
                // re-adding it is one line once the behaviour is fixed.
                zoomRail
                faceRail
                filterRail
                bottomBar
            }
            .padding(.bottom, VoiidSpacing.md)

            if joining {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    ProgressView("Putting your takes together…")
                        .tint(.white)
                        .foregroundColor(.white)
                }
            }
        }
        .statusBarHidden(true)
        .onAppear {
            cam.maxSeconds = maxSeconds
            cam.start()
            loadGalleryThumb()
        }
        .onDisappear {
            // The countdown Task outlives the view unless it is cancelled here — otherwise
            // it fires `startRecording()` against a session `cam.stop()` just tore down.
            cancelCountdown()
            cam.stop()
        }
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
        .confirmationDialog("Use a video from your library?",
                            isPresented: $confirmImport, titleVisibility: .visible) {
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
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: VoiidSpacing.sm) {
            roundButton("xmark", label: "Close") {
                cam.stop()
                cam.discardTakes()
                onClose()
            }
            Spacer()
            if totalSeconds > 0 || cam.isRecording {
                // Elapsed AND the cap, so a 90s clip does not stop at what looks like an
                // arbitrary moment with no warning it was coming.
                Text(String(format: "%02d:%02d / %02d:%02d",
                            Int(totalSeconds) / 60, Int(totalSeconds) % 60,
                            Int(maxSeconds) / 60, Int(maxSeconds) % 60))
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, 6)
                    .background(cam.isRecording ? VoiidColor.error : Color.black.opacity(0.4))
                    .clipShape(Capsule())
            }
            Spacer()
            if cam.hasTorch {
                roundButton(cam.torchOn ? "bolt.fill" : "bolt.slash",
                            label: "Flash", active: cam.torchOn) {
                    Haptics.tap()
                    cam.toggleTorch()
                }
            }
            // Cycles 0 → 3 → 10 → 0. A cycling button rather than a menu: three states are
            // faster to tap through than to pick from, and the icon carries the current one.
            // One symbol plus a text badge, rather than the `N.circle.fill` numeric
            // glyphs: those exist only for some N and have moved between SF Symbols
            // releases, and a missing symbol renders as an EMPTY button — a control that
            // silently disappears is worse than one that is a little plainer.
            roundButton("timer",
                        label: timerSeconds == 0 ? "Self-timer off" : "Self-timer \(timerSeconds) seconds",
                        active: timerSeconds != 0,
                        badge: timerSeconds == 0 ? nil : "\(timerSeconds)") {
                guard !cam.isRecording else { return }
                Haptics.tap()
                timerSeconds = timerSeconds == 0 ? 3 : (timerSeconds == 3 ? 10 : 0)
            }
            roundButton("square.grid.3x3", label: "Grid", active: showGrid) {
                Haptics.tap()
                showGrid.toggle()
            }
            roundButton("arrow.triangle.2.circlepath.camera", label: "Flip camera") {
                // Flipping mid-take would have to cut the segment; simply not offered while
                // recording, which is what the Android camera does too.
                guard !cam.isRecording else { return }
                Haptics.tap()
                cam.flip()
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.sm)
    }

    /// One tick per banked take plus the in-flight one, so "how much have I got" is
    /// answerable at a glance and undo has a visual anchor.
    private var progressTicks: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(cam.takes) { take in
                    Capsule()
                        .fill(Color.white)
                        .frame(width: tickWidth(take.outputSeconds, in: geo.size.width))
                }
                if cam.isRecording {
                    Capsule()
                        .fill(VoiidColor.error)
                        .frame(width: tickWidth(cam.liveSeconds, in: geo.size.width))
                }
                Spacer(minLength: 0)
            }
            .frame(height: 3)
        }
        .frame(height: 3)
        .opacity(cam.takes.isEmpty && !cam.isRecording ? 0 : 1)
    }

    private func tickWidth(_ seconds: Double, in total: CGFloat) -> CGFloat {
        max(2, total * CGFloat(min(1, seconds / maxSeconds)))
    }

    // MARK: Rails

    private var speedRail: some View {
        HStack(spacing: VoiidSpacing.sm) {
            ForEach(ClipSpeed.options, id: \.self) { s in
                Button {
                    Haptics.selection()
                    cam.selectedSpeed = s
                } label: {
                    HStack(spacing: 3) {
                        // Names the control. Without it this rail renders "1×/2×/3×" — the
                        // identical strings the zoom rail shows — and the two read as one
                        // repeated control stacked on itself.
                        Image(systemName: "speedometer")
                            .font(.system(size: 9, weight: .bold))
                        Text(ClipSpeed.label(s))
                            .font(VoiidFont.rounded(13, .semibold))
                    }
                        .foregroundColor(cam.selectedSpeed == s ? .black : .white)
                        .frame(minWidth: 58, minHeight: 44)
                        .background(cam.selectedSpeed == s ? Color.white : Color.black.opacity(0.35))
                        .clipShape(Capsule())
                }
                .buttonStyle(SoftPressStyle())
                .accessibilityLabel("Speed \(ClipSpeed.label(s))")
                .accessibilityAddTraits(cam.selectedSpeed == s ? [.isSelected] : [])
            }
        }
        .padding(.bottom, VoiidSpacing.sm)
    }

    /// Zoom presets plus a live readout, the way the system camera does it.
    ///
    /// The presets exist because a pinch is imprecise: getting exactly 2× by feel is
    /// fiddly, and "back to 1×" was previously only reachable by pinching all the way
    /// down. Tapping the ACTIVE preset is not a no-op — it reads the current factor, so a
    /// pinched 2.4× shows "2.4×" and tapping 2× snaps it clean.
    private var zoomRail: some View {
        HStack(spacing: 6) {
            ForEach(cam.availableZoomPresets, id: \.self) { factor in
                let active = abs(cam.currentZoom - factor) < 0.05
                Button {
                    Haptics.selection()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        cam.setZoom(factor)
                    }
                } label: {
                    // The active pill shows the REAL factor to one decimal when it is not a
                    // round number, so the readout never lies about where the pinch landed.
                    HStack(spacing: 3) {
                        // The glyph is what separates this rail from the SPEED rail above,
                        // which renders the identical strings "1×/2×/3×". Without it the two
                        // are indistinguishable stacked on top of each other.
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 9, weight: .bold))
                        Text(active ? liveZoomLabel(factor) : Self.zoomLabel(factor))
                            .font(VoiidFont.rounded(active ? 13 : 12, .semibold))
                    }
                        .foregroundColor(active ? .black : .white)
                        .frame(minWidth: active ? 56 : 46, minHeight: 34)
                        .background(active ? Color.white : Color.black.opacity(0.4))
                        .clipShape(Capsule())
                        // 44pt of target around a 34pt pill — the pills sit close together
                        // and a mis-tap changes the shot.
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SoftPressStyle())
                .accessibilityLabel("\(Self.zoomLabel(factor)) zoom")
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .padding(.bottom, VoiidSpacing.sm)
    }

    private func liveZoomLabel(_ factor: CGFloat) -> String {
        Self.zoomLabel(cam.currentZoom)
    }

    /// `Int(factor)` truncates, which rendered the 0.5× ultra-wide preset as "0×".
    private static func zoomLabel(_ v: CGFloat) -> String {
        v.rounded() == v ? "\(Int(v))×" : String(format: "%.1f×", v)
    }

    /// Rule-of-thirds guides. Off by default: they are a framing aid, not decoration, and
    /// permanent lines over every shot is noise for the majority who never want them.
    private var gridOverlay: some View {
        GeometryReader { geo in
            Path { p in
                for i in 1...2 {
                    let x = geo.size.width * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: geo.size.height))
                    let y = geo.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.28), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// Face effects, on their own rail above the colour filters.
    ///
    /// Deliberately NOT merged into the colour rail: the two are independent — a dog filter
    /// in black and white is a legitimate combination — so one shared rail would force a
    /// choice the pipeline does not actually impose.
    private var faceRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: VoiidSpacing.sm) {
                ForEach(ClipFaceEffect.allCases) { e in
                    let on = cam.faceEffect == e
                    Button {
                        Haptics.selection()
                        cam.faceEffect = e
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: e.symbol).font(.system(size: 13, weight: .semibold))
                            Text(e.label).font(VoiidFont.rounded(13, .semibold))
                        }
                        .foregroundColor(on ? .black : .white)
                        .padding(.horizontal, VoiidSpacing.md)
                        .frame(minHeight: 38)
                        .background(on ? Color.white : Color.black.opacity(0.35))
                        .clipShape(Capsule())
                        .padding(.vertical, 3)   // 44pt of target around a 38pt pill
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SoftPressStyle())
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
        }
        .frame(height: 44)
        .padding(.bottom, VoiidSpacing.xs)
    }

    private var filterRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: VoiidSpacing.sm) {
                ForEach(ClipFilter.allCases) { f in
                    Button {
                        Haptics.selection()
                        cam.filter = f
                    } label: {
                        Text(f.label)
                            .font(VoiidFont.rounded(13, .semibold))
                            .foregroundColor(cam.filter == f ? .black : .white)
                            .padding(.horizontal, VoiidSpacing.md)
                            .frame(minHeight: 44)
                            .background(cam.filter == f ? Color.white : Color.black.opacity(0.35))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(SoftPressStyle())
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
        }
        .frame(height: 44)
        .padding(.bottom, VoiidSpacing.md)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 0) {
            galleryButton
            Spacer(minLength: VoiidSpacing.sm)
            undoButton
            Spacer(minLength: VoiidSpacing.sm)
            shutter
            Spacer(minLength: VoiidSpacing.sm)
            acceptButton
            Spacer(minLength: VoiidSpacing.sm)
            // Balances the gallery button so the shutter stays optically centred.
            Color.clear.frame(width: 52, height: 52)
        }
        .padding(.horizontal, VoiidSpacing.md)
    }

    /// Instagram's corner thumbnail. The image only appears when library access has ALREADY
    /// been granted — opening the camera is not the moment to demand a new permission.
    private var galleryButton: some View {
        PhotosPicker(selection: $pickerItem, matching: .videos) {
            ZStack {
                if let galleryThumb {
                    Image(uiImage: galleryThumb).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.15)
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                .stroke(.white.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(SoftPressStyle())
    }

    private var undoButton: some View {
        // Present but inert while recording rather than vanishing, so the row does not
        // reflow under the user's thumb mid-take.
        Group {
            if !cam.takes.isEmpty && !cam.isRecording {
                roundButton("arrow.uturn.backward", label: "Undo last take") {
                    Haptics.tap()
                    cam.undoLastTake()
                }
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .frame(width: 44, height: 44)
    }

    private var acceptButton: some View {
        Group {
            if !cam.takes.isEmpty && !cam.isRecording {
                Button {
                    Haptics.success()
                    commit()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(VoiidColor.textOnPrimary)
                        .frame(width: 52, height: 52)
                        .background(VoiidColor.primary)
                        .clipShape(Circle())
                }
                .buttonStyle(SoftPressStyle())
                .accessibilityLabel("Use clip")
            } else {
                Color.clear.frame(width: 52, height: 52)
            }
        }
        .frame(width: 52, height: 52)
    }

    private var shutter: some View {
        Circle()
            .stroke(.white, lineWidth: 4)
            .frame(width: 76, height: 76)
            .overlay(
                RoundedRectangle(cornerRadius: cam.isRecording ? 8 : 31, style: .continuous)
                    .fill(cam.isRecording ? VoiidColor.error : .white)
                    .frame(width: cam.isRecording ? 34 : 62, height: cam.isRecording ? 34 : 62)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: cam.isRecording)
            )
            .contentShape(Circle())
            .gesture(
                // A DragGesture with no minimum distance is the only reliable press/release
                // signal here: onLongPressGesture's `pressing` callback also fires for a
                // plain tap, which would start and immediately end a 0.1s take.
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressActive else { return }
                        pressActive = true
                        shutterPressChanged(true)
                    }
                    .onEnded { _ in
                        pressActive = false
                        shutterPressChanged(false)
                    }
            )
            .accessibilityLabel(cam.isRecording ? "Stop recording" : "Record")
    }

    private func shutterPressChanged(_ pressing: Bool) {
        if pressing {
            if cam.isRecording {
                // A second press ends a take that is running locked.
                cam.stopRecording()
                pressConsumed = true
            } else if countdown != nil {
                // Pressing during a countdown CANCELS it. Without this the only escape from
                // a 10-second timer you triggered by accident is to close the camera.
                cancelCountdown()
                pressConsumed = true
            } else {
                guard !full else { return }
                pressConsumed = false
                pressBegan = Date()
                if timerSeconds > 0 {
                    // A timed take is always LOCKED: you set a timer to get into shot, so
                    // there is no finger on the shutter to release. `pressConsumed` stops
                    // the release handler below from stopping the take we have not begun.
                    pressConsumed = true
                    startCountdown()
                } else {
                    cam.startRecording()
                }
            }
            return
        }
        if pressConsumed { pressConsumed = false; return }
        // Under a third of a second reads as a TAP, which LOCKS the take running — nobody
        // holds a finger down for ninety seconds. A real press-and-hold ends on release,
        // which is how a burst of short segments gets banked.
        if Date().timeIntervalSince(pressBegan) >= 0.35 { cam.stopRecording() }
    }

    /// Counts down, then starts a locked take. Driven by a Task rather than a Timer so it
    /// cancels cleanly — `cancelCountdown` tears the task down, and leaving the screen
    /// cancels it with the view.
    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task {
            for remaining in stride(from: timerSeconds, through: 1, by: -1) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                    countdown = remaining
                }
                Haptics.tap()
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdown = nil
            guard !full else { return }
            Haptics.selection()
            cam.startRecording()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        withAnimation { countdown = nil }
    }

    // MARK: Commit

    private func commit() {
        let takes = cam.takes
        guard !takes.isEmpty else { return }
        joining = true
        let filter = cam.filter
        Task {
            let joined = await ClipTakeJoiner.join(takes: takes)
            await MainActor.run {
                joining = false
                guard let joined else {
                    cam.errorText = "Couldn't put those takes together."
                    return
                }
                cam.forgetTakes()
                cam.stop()
                onDone(joined, filter)
            }
        }
    }

    // MARK: Chrome helpers

    /// `badge` rides on the corner for a control whose state is a NUMBER (the self-timer).
    /// The alternative — swapping in a numeric SF Symbol per value — depends on glyphs that
    /// exist only for some values and have moved between SF Symbols releases; a missing one
    /// renders as an empty circle.
    private func roundButton(_ systemName: String, label: String,
                             active: Bool = false, badge: String? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(active ? .black : .white)
                .frame(width: 44, height: 44)
                .background(active ? Color.white : Color.black.opacity(0.35))
                .clipShape(Circle())
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge)
                            .font(VoiidFont.rounded(10, .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Color.white)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.black.opacity(0.35), lineWidth: 1))
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(SoftPressStyle())
        .accessibilityLabel(label)
    }

    private func loadGalleryThumb() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let options = PHFetchOptions()
            options.fetchLimit = 1
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let result = PHAsset.fetchAssets(with: .video, options: options)
            guard let asset = result.firstObject else { return }
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
}

// MARK: - Metal viewfinder

/// The live preview. An `AVCaptureVideoPreviewLayer` cannot render a CIFilter at all, so the
/// filtered frames are drawn into an MTKView instead — the same shape Signal-iOS uses.
///
/// The gesture recognisers live in the UIView rather than in SwiftUI because focus needs the
/// exact aspect-fill geometry (which only the view knows) and because a single/double tap
/// pair resolves cleanly with `require(toFail:)`.
private struct ClipCameraPreview: UIViewRepresentable {
    let renderer: ClipCameraRenderer
    let onZoom: (CGFloat, Bool) -> Void
    /// Normalised (0…1) point inside the VISIBLE video, y down.
    let onFocus: (CGPoint) -> Void
    let onFlip: () -> Void

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        // CIContext renders straight into the drawable's texture, which it cannot do while
        // the drawable is framebuffer-only.
        view.framebufferOnly = false
        view.isOpaque = true
        view.backgroundColor = .black
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.delegate = renderer
        renderer.attach(to: view)

        context.coordinator.onZoom = onZoom
        context.coordinator.onFocus = onFocus
        context.coordinator.onFlip = onFlip
        context.coordinator.renderer = renderer

        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.onZoom = onZoom
        context.coordinator.onFocus = onFocus
        context.coordinator.onFlip = onFlip
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var onZoom: ((CGFloat, Bool) -> Void)?
        var onFocus: ((CGPoint) -> Void)?
        var onFlip: (() -> Void)?
        weak var renderer: ClipCameraRenderer?

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began: onZoom?(1, true)
            case .changed: onZoom?(g.scale, false)
            default: break
            }
        }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) { onFlip?() }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view = g.view, let renderer,
                  let normalized = renderer.normalizedPoint(forViewPoint: g.location(in: view),
                                                            in: view.bounds.size) else { return }
            onFocus?(normalized)
        }
    }
}

/// Holds the most recent filtered frame and draws it aspect-fill. Deliberately NOT an
/// ObservableObject: frames arrive 30 times a second on the capture queue and publishing
/// each one would push a SwiftUI invalidation per frame.
final class ClipCameraRenderer: NSObject, MTKViewDelegate {
    private let lock = NSLock()
    private var latest: CIImage?
    private var extent: CGRect = .zero
    private var ciContext: CIContext?
    private var commandQueue: MTLCommandQueue?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    func attach(to view: MTKView) {
        guard let device = view.device, let queue = device.makeCommandQueue() else { return }
        commandQueue = queue
        // Intermediates are useless here: every frame is a different image, so caching them
        // only grows memory.
        ciContext = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
    }

    func submit(_ image: CIImage) {
        lock.lock()
        latest = image
        extent = image.extent
        lock.unlock()
    }

    /// Maps a point in the view to 0…1 inside the visible (aspect-filled, therefore cropped)
    /// video, so tap-to-focus lands where the finger actually is rather than where an
    /// un-cropped mapping would put it.
    func normalizedPoint(forViewPoint point: CGPoint, in size: CGSize) -> CGPoint? {
        lock.lock(); let ex = extent; lock.unlock()
        guard ex.width > 0, ex.height > 0, size.width > 0, size.height > 0 else { return nil }
        let scale = max(size.width / ex.width, size.height / ex.height)
        let drawnWidth = ex.width * scale
        let drawnHeight = ex.height * scale
        let originX = (size.width - drawnWidth) / 2
        let originY = (size.height - drawnHeight) / 2
        let u = (point.x - originX) / drawnWidth
        let v = (point.y - originY) / drawnHeight
        return CGPoint(x: min(max(u, 0), 1), y: min(max(v, 0), 1))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let ciContext, let commandQueue,
              let drawable = view.currentDrawable,
              let buffer = commandQueue.makeCommandBuffer() else { return }
        lock.lock(); let image = latest; lock.unlock()
        guard let image else { return }

        let size = view.drawableSize
        let ex = image.extent
        guard ex.width > 0, ex.height > 0, size.width > 0, size.height > 0 else { return }

        // Aspect-fill: scale to cover, then centre. Done as a transform on the image rather
        // than as a source rect so the render bounds stay the whole drawable.
        let scale = max(size.width / ex.width, size.height / ex.height)
        let dx = (size.width - ex.width * scale) / 2 - ex.origin.x * scale
        let dy = (size.height - ex.height * scale) / 2 - ex.origin.y * scale
        let shown = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))

        ciContext.render(shown, to: drawable.texture, commandBuffer: buffer,
                         bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        buffer.present(drawable)
        buffer.commit()
    }
}

// MARK: - Capture controller

/// NOT @MainActor: session configuration, frame delivery and writer appends all run on
/// private serial queues (isolating them to the main actor would freeze the UI and is
/// Apple-discouraged). Every @Published mutation hops back to main.
final class ClipCameraController: NSObject, ObservableObject,
                                  AVCaptureVideoDataOutputSampleBufferDelegate,
                                  AVCaptureAudioDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()
    let renderer = ClipCameraRenderer()

    private let videoOut = AVCaptureVideoDataOutput()
    private let audioOut = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "voiid.clip.camera.session")
    private let videoQueue = DispatchQueue(label: "voiid.clip.camera.video")
    private let audioQueue = DispatchQueue(label: "voiid.clip.camera.audio")
    /// Every writer touch happens here, so video and audio appends can never interleave
    /// mid-call from their two delivery queues.
    private let writerQueue = DispatchQueue(label: "voiid.clip.camera.writer")

    private var cameraInput: AVCaptureDeviceInput?
    private var micInput: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private var position: AVCaptureDevice.Position = .back
    private var configured = false
    private var pendingStopAfterFinish = false

    // MARK: Published state

    @Published var isRecording = false
    @Published var takes: [ClipTake] = []
    /// Output seconds of the take currently being written (already speed-adjusted).
    @Published var liveSeconds: Double = 0
    @Published var errorText: String?
    @Published var hasTorch = false
    @Published var torchOn = false
    @Published var selectedSpeed: Double = 1
    @Published var filter: ClipFilter = .none {
        didSet {
            filterLock.lock(); liveFilter = filter; filterLock.unlock()
        }
    }

    /// The face-tracked effect. Same lock as `filter`: both are read on the capture queue
    /// and written from the UI, and they are read together on every frame.
    @Published var faceEffect: ClipFaceEffect = .none {
        didSet {
            filterLock.lock(); liveFaceEffect = faceEffect; filterLock.unlock()
            // Drop stale faces when switching off, so re-enabling cannot flash the ears at
            // wherever a face was several seconds ago.
            if faceEffect == .none { faceDetector.reset() }
        }
    }

    /// Re-derived from what is on disk rather than accumulated, so undo can never drift.
    var bankedSeconds: Double { takes.reduce(0) { $0 + $1.outputSeconds } }

    var maxSeconds: Double = ClipCaps.maxDurationSeconds

    private let filterLock = NSLock()
    private var liveFilter: ClipFilter = .none
    private var liveFaceEffect: ClipFaceEffect = .none
    private let faceDetector = ClipFaceDetector()
    private var writerPixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    /// ONE context for the whole session. A CIContext compiles and caches Metal shaders on
    /// creation; building one per frame is the classic way to turn a 30 fps capture into a
    /// slideshow. Explicitly told not to hold a colour space it does not need.
    private lazy var writerCIContext: CIContext = {
        CIContext(options: [.cacheIntermediates: false])
    }()

    // MARK: Writer state — writerQueue only

    private var writer: AVAssetWriter?
    private var writerVideoInput: AVAssetWriterInput?
    private var writerAudioInput: AVAssetWriterInput?
    private var writing = false
    private var sessionStarted = false
    private var firstPTS: CMTime = .invalid
    private var lastPTS: CMTime = .invalid
    private var takeURL: URL?
    private var takeSpeed: Double = 1
    /// Recorded (1×) seconds this take is allowed before the cap is reached.
    private var recordBudget: Double = 0
    private var lastPublishedLive: Double = -1

    // MARK: Lifecycle

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // Re-entering the camera after a push to the editor only needs the session back.
            if self.configured {
                if !self.session.isRunning { self.session.startRunning() }
                return
            }
            self.configured = true
            self.session.beginConfiguration()
            self.attachCamera(position: self.position)
            self.attachMicrophone()
            // 1080p explicitly, not `.high`: the export ladder's top rung is 1080p and a
            // 720p source would silently skip it. Asked AFTER the inputs are attached,
            // because a preset is only answerable against the devices in the session.
            if self.session.canSetSessionPreset(.hd1920x1080) {
                self.session.sessionPreset = .hd1920x1080
            } else {
                self.session.sessionPreset = .high
            }

            self.videoOut.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            self.videoOut.alwaysDiscardsLateVideoFrames = true
            self.videoOut.setSampleBufferDelegate(self, queue: self.videoQueue)
            if self.session.canAddOutput(self.videoOut) { self.session.addOutput(self.videoOut) }

            self.audioOut.setSampleBufferDelegate(self, queue: self.audioQueue)
            if self.session.canAddOutput(self.audioOut) { self.session.addOutput(self.audioOut) }

            self.session.commitConfiguration()
            self.applyConnectionGeometry()
            self.session.startRunning()
        }
    }

    /// Tearing the session down while a take is still being written truncates the file, so a
    /// recording in flight is finished first and the session stops from its completion.
    func stop() {
        if isRecording {
            pendingStopAfterFinish = true
            stopRecording()
            return
        }
        setTorch(on: false)
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func attachCamera(position: AVCaptureDevice.Position) {
        if let cameraInput { session.removeInput(cameraInput) }
        // Prefer a VIRTUAL multi-lens device (triple → dual-wide → dual) over the bare wide
        // angle. A virtual device exposes the ultra-wide and telephoto as one continuous
        // zoom range and switches lenses itself, which is what makes a real 0.5× possible —
        // `builtInWideAngleCamera` alone has no ultra-wide to reach, so 0.5× would have been
        // a button that could never work. Falls back to the wide angle on devices (and the
        // front camera) that have nothing richer.
        let preferred: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
        ]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: preferred,
                                                         mediaType: .video, position: position)
        guard let dev = discovery.devices.first,
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else {
            DispatchQueue.main.async { self.errorText = "Couldn't start the camera." }
            return
        }
        session.addInput(input)
        cameraInput = input
        device = dev
        let torch = dev.hasTorch
        // Only offer a preset the device can actually reach. The front camera's ceiling is
        // much lower than the back's, so this is recomputed per attach rather than once.
        let ceiling = min(Self.maxUsableZoom,
                          min(dev.activeFormat.videoMaxZoomFactor, dev.maxAvailableVideoZoomFactor))

        // ── PRESETS COME FROM THE HARDWARE, NOT A HARD-CODED LIST ──────────────────
        // On a virtual device, `virtualDeviceSwitchOverVideoZoomFactors` are the exact
        // points where AVFoundation swaps physical lenses — i.e. the real optical stops.
        // On a triple camera the ultra-wide is lens 0, so 1.0 in the device's own scale is
        // the ULTRA-WIDE, and the "1×" a user expects is the first switch-over point.
        //
        // Deriving them means a 2-lens phone shows 0.5/1/2 and a 1-lens phone shows just 1,
        // instead of every device claiming the same three buttons.
        let switchOvers = dev.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let base = switchOvers.first ?? 1        // device units per user 1×
        let userCeiling = ceiling / base

        // OPTICAL stops first — the real lenses. On a dual-wide iPhone the switch-overs are
        // [2.0], meaning device 2.0 is the wide lens: that is the user's 1×, and device 1.0
        // (the ultra-wide) is user 0.5×.
        var presets: [CGFloat] = []
        if !switchOvers.isEmpty {
            presets.append(1 / base)                        // the ultra-wide
            presets.append(contentsOf: switchOvers.map { $0 / base })
        } else {
            presets.append(1)                               // single lens: 1× only
        }

        // Then the useful DIGITAL stops above the longest lens. A dual-wide phone has no
        // telephoto, but 2× on it is still a real, useful crop — omitting it would leave
        // that phone with only 0.5× and 1×, which is fewer options than the camera app
        // itself offers. Only added where they clear the longest optical stop, so a
        // telephoto phone never gets a digital "2×" duplicating its optical one.
        // At most TWO digital stops. Every optical stop is kept — those are real lenses —
        // but a rail of six pills does not fit a phone width, and the pinch still reaches
        // the full ceiling for anything between or beyond them.
        let opticalTop = presets.max() ?? 1
        for stop in [CGFloat(2), 3, 5, 10] where stop > opticalTop {
            if presets.count >= (switchOvers.isEmpty ? 3 : switchOvers.count + 3) { break }
            presets.append(stop)
        }

        presets = presets.map { ($0 * 10).rounded() / 10 }.filter { $0 <= userCeiling }
        // De-duplicate in order: a dual-wide device can report a switch-over that rounds
        // onto a value already in the list, and two identical pills is exactly the repeat
        // this rail is being fixed for.
        var seen = Set<CGFloat>()
        presets = presets.filter { seen.insert($0).inserted }
        // Flipping to a camera with a lower ceiling must not leave the indicator reading a
        // factor the new device cannot hold — AVFoundation clamps it silently otherwise.
        // `base` (above) is the one conversion between the device's zoom scale and the
        // user's: on a phone with an ultra-wide, device 1.0 IS the ultra-wide, so a
        // user-facing 1× is `switchOvers[0]` in device units.
        let userScaleBase = base
        let clampedZoom = min(dev.videoZoomFactor / userScaleBase, ceiling / userScaleBase)
        DispatchQueue.main.async {
            self.hasTorch = torch
            if !torch { self.torchOn = false }
            self.zoomScaleBase = userScaleBase
            self.availableZoomPresets = presets
            self.currentZoom = clampedZoom
        }
    }

    private func attachMicrophone() {
        guard micInput == nil, let mic = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(input) else { return }
        session.addInput(input)
        micInput = input
    }

    /// The buffers are rotated and mirrored HERE, once, so the preview and the written file
    /// agree and the file needs no preferred transform downstream.
    private func applyConnectionGeometry() {
        guard let connection = videoOut.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = (position == .front)
        }
    }

    func flip() {
        guard !isRecording else { return }
        // The previous camera's faces do not apply to the new one, and a stale box would
        // park the ears mid-air until the next detection lands.
        faceDetector.reset()
        position = (position == .back) ? .front : .back
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.attachCamera(position: self.position)
            self.session.commitConfiguration()
            self.applyConnectionGeometry()
        }
    }

    // MARK: Hardware controls

    func toggleTorch() { setTorch(on: !torchOn) }

    private func setTorch(on: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let dev = self.device, dev.hasTorch else { return }
            guard (try? dev.lockForConfiguration()) != nil else { return }
            dev.torchMode = on ? .on : .off
            dev.unlockForConfiguration()
            DispatchQueue.main.async { self.torchOn = on }
        }
    }

    private var zoomAtGestureStart: CGFloat = 1

    /// Ceiling in USER units (so 10 means 10× as the camera app labels it).
    ///
    /// `videoMaxZoomFactor` reports 100×+ on modern iPhones — almost all of it unusable
    /// digital crop, and leaving it uncapped squeezed the whole useful range into a sliver
    /// of the pinch. 10× matches what the system camera offers on this hardware, so the
    /// pinch spends itself across a range that is actually worth having.
    static let maxUsableZoom: CGFloat = 10

    /// Drives the on-screen zoom pill. Main-actor published so the indicator and the preset
    /// buttons read the same value the gesture is writing.
    @Published var currentZoom: CGFloat = 1

    /// Which presets this device can actually reach. Recomputed on every camera attach,
    /// because the front camera's ceiling is far lower than the back's — offering a 3×
    /// button that the front camera cannot honour would be a dead control.
    @Published var availableZoomPresets: [CGFloat] = [1]

    /// Device-zoom units per 1 user-facing ×. On a phone with an ultra-wide the device's
    /// own 1.0 is the ULTRA-WIDE, so the "1×" a person means is this value in device units.
    /// 1 on single-lens devices, where the two scales are the same.
    private(set) var zoomScaleBase: CGFloat = 1

    /// Pinch zoom.
    ///
    /// Three things make this feel like the system camera rather than a slider:
    ///
    /// 1. **The gesture start is captured on the MAIN actor, not the session queue.** It was
    ///    hopping to `sessionQueue` to read `videoZoomFactor` when the pinch began — but the
    ///    first `.changed` often lands before that async block runs, so the gesture multiplied
    ///    against a STALE start value and the image jumped at the moment you touched it.
    ///
    /// 2. **The ceiling is capped for usability, not by the hardware.** `videoMaxZoomFactor`
    ///    is often 100–150× on modern iPhones; past ~8× the frame is unusable mush, and the
    ///    whole useful range was crammed into the first few percent of the gesture. Capping
    ///    at 8× spends the gesture where the picture is real.
    ///
    /// 3. **Zoom is applied with a RAMP while recording.** Setting `videoZoomFactor` directly
    ///    snaps between values, which reads as a stutter in the recorded file. `ramp(toVideoZoomFactor:)`
    ///    interpolates in hardware. Outside recording the direct set is right — it must track
    ///    the finger 1:1 with no lag.
    @MainActor
    func zoom(scale: CGFloat, began: Bool) {
        if began {
            zoomAtGestureStart = currentZoom
            return
        }

        // Floor is the widest preset (0.5× on an ultra-wide phone), not a hard 1 — clamping
        // to 1 would make the ultra-wide unreachable by pinch on exactly the devices that
        // have one.
        let floor = availableZoomPresets.first ?? 1
        let target = min(max(zoomAtGestureStart * scale, floor), Self.maxUsableZoom)
        // Published immediately so the on-screen indicator tracks the finger rather than
        // waiting on the session queue.
        currentZoom = target

        // Read on main and captured, NOT read inside the block: `isRecording` is @Published
        // and reading it from the session queue is the same data race the type's note warns
        // about, just in the other direction.
        let recording = isRecording
        let deviceTarget = target * zoomScaleBase   // user units → device units
        sessionQueue.async { [weak self] in
            guard let self, let dev = self.device else { return }
            let ceiling = min(Self.maxUsableZoom * self.zoomScaleBase,
                              min(dev.activeFormat.videoMaxZoomFactor, dev.maxAvailableVideoZoomFactor))
            let clamped = min(max(deviceTarget, dev.minAvailableVideoZoomFactor), ceiling)
            guard (try? dev.lockForConfiguration()) != nil else { return }
            if recording {
                // 8×/second: fast enough to feel immediate, slow enough that the recorded
                // file shows a glide instead of a staircase.
                dev.ramp(toVideoZoomFactor: clamped, withRate: 8)
            } else {
                dev.videoZoomFactor = clamped
            }
            dev.unlockForConfiguration()
        }
    }

    /// Jump to a preset (the 1× / 2× / 3× buttons), animated rather than snapped.
    ///
    /// @MainActor like `zoom`: both write `currentZoom`, and this class is deliberately not
    /// main-isolated (see the type's note), so the isolation has to be stated per method or
    /// the @Published write lands on whatever queue the caller happened to be on.
    @MainActor
    func setZoom(_ factor: CGFloat) {
        let floor = availableZoomPresets.first ?? 1
        let target = min(max(factor, floor), Self.maxUsableZoom)
        currentZoom = target
        let deviceTarget = target * zoomScaleBase
        sessionQueue.async { [weak self] in
            guard let self, let dev = self.device else { return }
            let ceiling = min(Self.maxUsableZoom * self.zoomScaleBase,
                              min(dev.activeFormat.videoMaxZoomFactor, dev.maxAvailableVideoZoomFactor))
            let clamped = min(max(deviceTarget, dev.minAvailableVideoZoomFactor), ceiling)
            guard (try? dev.lockForConfiguration()) != nil else { return }
            // Always ramped: a preset tap is a deliberate jump, and snapping 1× → 3× is
            // jarring in the preview even when nothing is recording.
            dev.ramp(toVideoZoomFactor: clamped, withRate: 12)
            dev.unlockForConfiguration()
        }
    }

    /// `point` is 0…1 inside the visible video, y down. `focusPointOfInterest` is always
    /// expressed against a landscape-home-button-right sensor regardless of device
    /// orientation, so a portrait viewfinder point has to be rotated into that space — and
    /// un-mirrored again when the front camera preview is mirrored.
    func focus(atNormalizedViewPoint point: CGPoint) {
        let u = (position == .front) ? (1 - point.x) : point.x
        let devicePoint = CGPoint(x: point.y, y: 1 - u)
        Haptics.tap()
        sessionQueue.async { [weak self] in
            guard let self, let dev = self.device else { return }
            guard (try? dev.lockForConfiguration()) != nil else { return }
            if dev.isFocusPointOfInterestSupported, dev.isFocusModeSupported(.autoFocus) {
                dev.focusPointOfInterest = devicePoint
                dev.focusMode = .autoFocus
            }
            if dev.isExposurePointOfInterestSupported, dev.isExposureModeSupported(.continuousAutoExposure) {
                dev.exposurePointOfInterest = devicePoint
                dev.exposureMode = .continuousAutoExposure
            }
            dev.unlockForConfiguration()
        }
    }

    // MARK: Recording

    func startRecording() {
        guard !isRecording else { return }
        let remaining = maxSeconds - bankedSeconds
        guard remaining > 0.2 else { return }
        let speed = selectedSpeed
        Haptics.rigid()
        isRecording = true
        liveSeconds = 0
        errorText = nil
        // Recording is always 1×; a 0.3× take yields 1/0.3 output seconds per recorded
        // second, so the RECORDED budget has to be scaled by the speed or a slow-motion
        // take would sail past the backend's 90s cap.
        let budget = remaining * speed
        writerQueue.async { [weak self] in self?.beginWriter(speed: speed, budget: budget) }
    }

    func stopRecording() {
        guard isRecording else { return }
        writerQueue.async { [weak self] in self?.finishTake() }
    }

    func undoLastTake() {
        guard let last = takes.popLast() else { return }
        try? FileManager.default.removeItem(at: last.url)
        // `bankedSeconds` is a sum over what remains, so nothing needs correcting here —
        // subtracting the last measured duration is what drifts.
    }

    /// Throw away every take and its file. Used by Close and by a gallery import.
    func discardTakes() {
        for take in takes { try? FileManager.default.removeItem(at: take.url) }
        takes = []
    }

    /// Hand the takes on WITHOUT deleting them — the joiner owns the files from here.
    func forgetTakes() { takes = [] }

    /// The encoder settings AVFoundation recommends for this session, corrected for the
    /// quarter-turn the connection applies.
    ///
    /// The recommendation is quoted against the SENSOR, which is landscape, so on a rotated
    /// connection it can hand back a 1920×1080 target for 1080×1920 buffers — every take
    /// would come out pillarboxed. The swap is a no-op when the recommendation already came
    /// back portrait.
    private func portraitVideoSettings() -> [String: Any]? {
        guard var settings = videoOut.recommendedVideoSettingsForAssetWriter(writingTo: .mp4)
        else { return nil }
        guard let connection = videoOut.connection(with: .video),
              connection.videoRotationAngle == 90 || connection.videoRotationAngle == 270,
              let width = settings[AVVideoWidthKey] as? NSNumber,
              let height = settings[AVVideoHeightKey] as? NSNumber,
              width.intValue > height.intValue else { return settings }
        settings[AVVideoWidthKey] = height
        settings[AVVideoHeightKey] = width
        return settings
    }

    private func beginWriter(speed: Double, budget: Double) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip_seg_\(UUID().uuidString).mp4")
        do {
            let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let videoSettings = portraitVideoSettings()
            let videoInput = AVAssetWriterInput(mediaType: .video,
                                                outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            guard assetWriter.canAdd(videoInput) else { throw ClipCameraError.writerRejectedInput }
            assetWriter.add(videoInput)

            // An adaptor so a FACE EFFECT can be burned into the recording.
            //
            // Colour filters do not need this — they are re-applied losslessly at export via
            // AVVideoComposition, which is why the writer takes the untouched buffer. A face
            // effect cannot take that route: the export has no per-frame face positions, and
            // re-running detection over the finished file would be both slow and a different
            // result. So the ears are composited HERE, at capture, where the tracking data
            // actually exists. Colour still stays out of the file.
            //
            // WIDTH AND HEIGHT ARE REQUIRED. Without them the adaptor cannot build its
            // pixel-buffer pool, `pixelBufferPool` stays nil, and every frame silently
            // falls back to the unfiltered path — the effect would show in the preview and
            // be absent from the recording, with no error anywhere to explain why.
            // They are taken from the writer's OWN settings so the buffer we render into
            // always matches what the encoder expects.
            let settings = videoSettings
            var adaptorAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            if let w = settings?[AVVideoWidthKey] as? NSNumber,
               let h = settings?[AVVideoHeightKey] as? NSNumber {
                adaptorAttrs[kCVPixelBufferWidthKey as String] = w
                adaptorAttrs[kCVPixelBufferHeightKey as String] = h
            }
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: adaptorAttrs)

            var audioInput: AVAssetWriterInput?
            if let audioSettings = audioOut.recommendedAudioSettingsForAssetWriter(writingTo: .mp4)
                as? [String: Any] {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = true
                if assetWriter.canAdd(input) {
                    assetWriter.add(input)
                    audioInput = input
                }
            }

            guard assetWriter.startWriting() else { throw ClipCameraError.writerRejectedInput }

            writer = assetWriter
            writerVideoInput = videoInput
            writerPixelAdaptor = adaptor
            writerAudioInput = audioInput
            takeURL = url
            takeSpeed = speed
            recordBudget = budget
            sessionStarted = false
            firstPTS = .invalid
            lastPTS = .invalid
            lastPublishedLive = -1
            writing = true
        } catch {
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                self.isRecording = false
                self.errorText = "Couldn't start recording."
            }
        }
    }

    /// Close the current take. A take cut short by the cap is COMPLETE and playable, so it is
    /// kept — the AssetWriter equivalent of the story camera's salvage branch, where hitting
    /// `maxRecordedDuration` reports an "error" that actually means success.
    private func finishTake() {
        guard writing, let assetWriter = writer, let url = takeURL else { return }
        writing = false
        let recorded = (sessionStarted && lastPTS.isValid && firstPTS.isValid)
            ? (lastPTS - firstPTS).seconds : 0
        let speed = takeSpeed

        writerVideoInput?.markAsFinished()
        writerAudioInput?.markAsFinished()
        writer = nil
        writerVideoInput = nil
        writerPixelAdaptor = nil
        writerAudioInput = nil
        takeURL = nil

        assetWriter.finishWriting { [weak self] in
            guard let self else { return }
            let ok = assetWriter.status == .completed && recorded >= 0.15
            DispatchQueue.main.async {
                self.isRecording = false
                self.liveSeconds = 0
                if ok {
                    self.takes.append(ClipTake(url: url, recordedSeconds: recorded, speed: speed))
                } else {
                    try? FileManager.default.removeItem(at: url)
                    // A dropped take with no message is indistinguishable from a broken
                    // shutter button.
                    if assetWriter.status == .failed {
                        self.errorText = assetWriter.error?.localizedDescription
                            ?? "That take couldn't be saved."
                    }
                }
                if self.pendingStopAfterFinish {
                    self.pendingStopAfterFinish = false
                    self.stop()
                }
            }
        }
    }

    // MARK: Frame delivery

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOut {
            if let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) {
                filterLock.lock()
                let active = liveFilter
                let face = liveFaceEffect
                filterLock.unlock()

                // Fire-and-forget: the detector copies the buffer and returns immediately,
                // so the capture queue is never blocked. It now TRACKS on every frame
                // (cheap) and only re-detects periodically, which is what makes the effect
                // move at video rate instead of stepping.
                if face != .none { faceDetector.submit(pixels) }

                // BOTH the colour filter and the face effect are PREVIEW-ONLY. The buffer
                // handed to the writer below is the untouched one, so a look is baked
                // exactly once, at export.
                var preview = active.apply(to: CIImage(cvPixelBuffer: pixels))
                if face != .none {
                    preview = ClipFaceRenderer.apply(face, to: preview,
                                                     faces: faceDetector.latest)
                }
                renderer.submit(preview)
            }
            writerQueue.async { [weak self] in self?.appendVideo(sampleBuffer) }
        } else if output === audioOut {
            writerQueue.async { [weak self] in self?.appendAudio(sampleBuffer) }
        }
    }

    private func appendVideo(_ sample: CMSampleBuffer) {
        guard writing, let assetWriter = writer, let input = writerVideoInput,
              assetWriter.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid else { return }

        if !sessionStarted {
            assetWriter.startSession(atSourceTime: pts)
            sessionStarted = true
            firstPTS = pts
        }
        lastPTS = pts

        filterLock.lock(); let face = liveFaceEffect; filterLock.unlock()
        let faces = face == .none ? [] : faceDetector.latest

        if input.isReadyForMoreMediaData {
            if face != .none, !faces.isEmpty,
               let adaptor = writerPixelAdaptor,
               let source = CMSampleBufferGetImageBuffer(sample),
               let rendered = renderFaceEffect(face, faces: faces, source: source,
                                               adaptor: adaptor) {
                adaptor.append(rendered, withPresentationTime: pts)
            } else {
                // No face in frame, or the effect is off: append the ORIGINAL buffer. This
                // path is also the fallback if the render fails — a take that records
                // unadorned is recoverable; a dropped frame is not.
                input.append(sample)
            }
        }

        let recorded = (pts - firstPTS).seconds
        publishLive(recorded / takeSpeed)
        if recorded >= recordBudget { finishTake() }
    }

    /// Composite the face effect into a fresh buffer from the adaptor's pool.
    ///
    /// Returns nil on any failure, and the caller falls back to appending the untouched
    /// sample — an unadorned take beats a dropped frame.
    private func renderFaceEffect(_ effect: ClipFaceEffect, faces: [TrackedFace],
                                  source: CVPixelBuffer,
                                  adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess,
              let buffer = out else { return nil }

        let composed = ClipFaceRenderer.apply(effect, to: CIImage(cvPixelBuffer: source),
                                              faces: faces)
        writerCIContext.render(composed, to: buffer)
        return buffer
    }

    private func appendAudio(_ sample: CMSampleBuffer) {
        // Audio that arrives before the first video frame would drag the session start
        // backwards and open the take with a black lead-in.
        guard writing, sessionStarted, let assetWriter = writer, let input = writerAudioInput,
              assetWriter.status == .writing, input.isReadyForMoreMediaData else { return }
        input.append(sample)
    }

    /// Publishing every frame would push a SwiftUI invalidation 30 times a second for a
    /// label that shows whole seconds.
    private func publishLive(_ seconds: Double) {
        guard abs(seconds - lastPublishedLive) >= 0.05 else { return }
        lastPublishedLive = seconds
        DispatchQueue.main.async { self.liveSeconds = seconds }
    }
}

private enum ClipCameraError: Error { case writerRejectedInput }

// MARK: - Joining takes

enum ClipTakeJoiner {

    /// Concatenate the takes into the single file the rest of the composer expects, applying
    /// each take's speed as a time scale.
    ///
    /// A lone 1× take is returned AS-IS: every take shares the same codec and session
    /// settings, so joining them is a passthrough remux, and copying one file through a full
    /// export would be pure loss in the overwhelmingly common case.
    static func join(takes: [ClipTake]) async -> URL? {
        guard !takes.isEmpty else { return nil }
        if takes.count == 1, takes[0].speed == 1 { return takes[0].url }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        var scaled = false

        for take in takes {
            let asset = AVURLAsset(url: take.url)
            guard let source = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration),
                  duration.seconds > 0 else { continue }
            let range = CMTimeRange(start: .zero, duration: duration)
            do {
                try videoTrack.insertTimeRange(range, of: source, at: cursor)
            } catch {
                continue
            }
            if let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first,
               let audioTrack {
                try? audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
            }

            if take.speed != 1 {
                scaled = true
                let target = CMTimeMultiplyByFloat64(duration, multiplier: 1.0 / take.speed)
                composition.scaleTimeRange(CMTimeRange(start: cursor, duration: duration),
                                           toDuration: target)
                cursor = cursor + target
            } else {
                cursor = cursor + duration
            }
        }

        guard cursor.seconds > 0 else { return nil }

        // Passthrough is invalid for a scaled segment — retiming needs a real encode — but
        // it is exactly right for a plain join, where every take already shares the encoder
        // settings the session produced.
        let primary = scaled ? AVAssetExportPreset1920x1080 : AVAssetExportPresetPassthrough
        if let out = await export(composition, preset: primary) {
            cleanUp(takes)
            return out
        }
        if primary == AVAssetExportPresetPassthrough,
           let out = await export(composition, preset: AVAssetExportPreset1920x1080) {
            cleanUp(takes)
            return out
        }
        return nil
    }

    private static func export(_ composition: AVMutableComposition, preset: String) async -> URL? {
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            return nil
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip_takes_\(UUID().uuidString).mp4")
        session.outputURL = out
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }

    /// The takes are consumed by the join; leaving them behind would double the temp-file
    /// cost of every multi-segment recording.
    private static func cleanUp(_ takes: [ClipTake]) {
        for take in takes { try? FileManager.default.removeItem(at: take.url) }
    }
}
