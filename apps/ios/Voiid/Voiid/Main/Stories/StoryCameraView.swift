//
//  StoryCameraView.swift
//  Voiid
//
//  The in-app camera for everything that is not the clips recorder: stories, chat photos
//  and the profile photo. It runs on the clips camera engine (ClipCameraController), so
//  the face filters people use in clips are here too — a puppy-ear selfie in a chat is the
//  same puppy ears, tracked the same way, as in a clip.
//
//  Photo → JPEG Data taken from the processed frame (so the filter is IN the photo);
//  video → a temp .mp4 with the face filter burned in at capture (tap to snap,
//  press-and-hold to record). The composer applies the size/re-encode caps (§8.2).
//
//  `mode` decides what a presentation may produce — see CameraMode. Clips previously
//  reused the story defaults verbatim, which silently capped a 90s clip at 30s and let a
//  shutter TAP produce a photo the clip composer could only discard.
//

import Combine
import SwiftUI
import AVFoundation

/// What a given presentation of the camera is allowed to produce.
struct CameraMode {
    var maxSeconds: Int
    /// When true the shutter TAP starts/stops recording and photo capture is unreachable —
    /// the only sensible behaviour when the caller cannot use a photo at all.
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

struct StoryCameraView: View {
    /// Called with a captured photo (Data, "image/jpeg") or video (temp file URL, "video/mp4").
    var mode: CameraMode = .story
    var onCapture: (_ photo: Data?, _ videoURL: URL?) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cam = ClipCameraController()
    @State private var capturing = false
    @State private var showFilters = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ClipCameraPreview(renderer: cam.renderer,
                              onZoom: { cam.zoom(scale: $0, began: $1) },
                              onFocus: { cam.focus(atNormalizedViewPoint: $0) },
                              onFlip: { if !cam.isRecording { Haptics.tap(); cam.flip() } })
                .ignoresSafeArea()

            if mode.selfie { selfieGuide }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if cam.isRecording {
                    // Elapsed AND the cap, so a recording does not stop at what looks like an
                    // arbitrary moment with no warning it was coming.
                    Text(String(format: "%02d:%02d / %02d:%02d",
                                Int(cam.liveSeconds) / 60, Int(cam.liveSeconds) % 60,
                                mode.maxSeconds / 60, mode.maxSeconds % 60))
                        .font(VoiidFont.headline).foregroundColor(.white)
                        .padding(.horizontal, VoiidSpacing.md).padding(.vertical, 6)
                        .background(VoiidColor.error).clipShape(Capsule())
                        .padding(.bottom, VoiidSpacing.sm)
                }
                if showFilters && !cam.isRecording {
                    FaceLensRail(selection: $cam.faceEffect)
                        .padding(.bottom, VoiidSpacing.sm)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                shutter
                    .padding(.bottom, 40)
            }
        }
        .statusBarHidden()
        .onAppear {
            cam.maxSeconds = Double(mode.maxSeconds)
            cam.wantsAudio = !mode.photoOnly
            if mode.selfie { cam.setInitialPosition(.front) }
            cam.start()
        }
        .onDisappear { cam.stop() }
        .onChange(of: cam.takes) { _, takes in
            // One take is the whole recording here — there is no multi-take editor behind
            // this camera, so the first finished take is handed straight on.
            guard let take = takes.last else { return }
            cam.forgetTakes()
            onCapture(nil, take.url)
            dismiss()
        }
        .alert(
            "Camera problem",
            isPresented: Binding(
                get: { cam.errorText != nil },
                set: { if !$0 { cam.errorText = nil } }
            )
        ) {
            Button("OK", role: .cancel) { cam.errorText = nil }
        } message: {
            Text(cam.errorText ?? "")
        }
    }

    private var topBar: some View {
        HStack(spacing: VoiidSpacing.sm) {
            circleButton("xmark", label: "Close") { dismiss() }
            Spacer()
            circleButton(showFilters ? "face.smiling.inverse" : "face.smiling",
                         label: showFilters ? "Hide filters" : "Show filters",
                         active: showFilters) {
                Haptics.selection()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showFilters.toggle() }
            }
            if cam.hasTorch {
                circleButton(cam.torchOn ? "bolt.fill" : "bolt.slash",
                             label: "Flash", active: cam.torchOn) {
                    Haptics.tap(); cam.toggleTorch()
                }
            }
            circleButton("arrow.triangle.2.circlepath.camera", label: "Flip camera") {
                guard !cam.isRecording else { return }
                Haptics.tap(); cam.flip()
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, VoiidSpacing.md)
    }

    private func circleButton(_ systemName: String, label: String, active: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(active ? .black : .white)
                .frame(width: 44, height: 44)
                .background(active ? Color.white : Color.black.opacity(0.35))
                .clipShape(Circle())
        }
        .buttonStyle(SoftPressStyle())
        .accessibilityLabel(label)
    }

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

    private var shutter: some View {
        Circle()
            .stroke(.white, lineWidth: 4)
            .frame(width: 78, height: 78)
            .overlay(Circle().fill(cam.isRecording ? VoiidColor.error : .white)
                .frame(width: cam.isRecording ? 34 : 64, height: cam.isRecording ? 34 : 64)
                .clipShape(RoundedRectangle(cornerRadius: cam.isRecording ? 8 : 32)))
            .scaleEffect(capturing ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: capturing)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: cam.isRecording)
            .contentShape(Circle())
            .onTapGesture {
                // In video-only mode a tap TOGGLES recording: nobody holds a finger down for
                // a minute and a half.
                if mode.videoOnly {
                    if cam.isRecording { cam.stopRecording() } else { cam.startRecording() }
                } else if !cam.isRecording {
                    snap()
                }
            }
            .onLongPressGesture(minimumDuration: 0.3, pressing: { pressing in
                // Hold-to-record, but never let the release of a tap-to-start recording stop
                // it immediately: in video-only mode the tap already owns the toggle.
                guard !mode.photoOnly else { return }
                if pressing {
                    if !cam.isRecording { cam.startRecording() }
                } else if !mode.videoOnly {
                    cam.stopRecording()
                }
            }, perform: {})
            .accessibilityLabel(mode.photoOnly ? "Take photo" : "Shutter")
    }

    private func snap() {
        guard !capturing else { return }
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
}
