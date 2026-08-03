//
//  StoryCameraView.swift
//  Voiid
//
//  In-app camera for story capture, built from scratch (the app had NO AVCaptureSession
//  anywhere). NSCameraUsageDescription / mic permission are already declared and requested
//  at onboarding, so there is no new permission plumbing here.
//
//  Photo → JPEG Data; video → a temp .mov file URL (tap to snap, press-and-hold to record).
//  The composer applies the size/re-encode caps (§8.2) before posting.
//
//  Shared by stories (30s, photo or video) and clips (90s, VIDEO ONLY) via `mode` — see
//  CameraMode. Clips previously reused the story defaults verbatim, which silently capped a
//  90s clip at 30s and let a shutter TAP produce a photo the clip composer could only
//  discard (its `guard let videoURL else { return }` made that look like a dead button).
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

    static let story = CameraMode(maxSeconds: 30, videoOnly: false)
    static let clip = CameraMode(maxSeconds: 90, videoOnly: true)
}

struct StoryCameraView: View {
    /// Called with a captured photo (Data, "image/jpeg") or video (temp file URL, "video/mp4").
    var mode: CameraMode = .story
    var onCapture: (_ photo: Data?, _ videoURL: URL?) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cam = CameraController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: cam.session).ignoresSafeArea()

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 20, weight: .semibold)).foregroundColor(.white).padding(12)
                    }
                    Spacer()
                    Button { cam.flip() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera").font(.system(size: 20)).foregroundColor(.white).padding(12)
                    }
                }
                .padding(.top, 44).padding(.horizontal, VoiidSpacing.sm)
                Spacer()
                if cam.isRecording {
                    // Elapsed AND the cap, so a 90s clip does not stop at what looks like an
                    // arbitrary moment with no warning it was coming.
                    Text(String(format: "%02d:%02d / %02d:%02d",
                                cam.recordSeconds / 60, cam.recordSeconds % 60,
                                mode.maxSeconds / 60, mode.maxSeconds % 60))
                        .font(VoiidFont.headline).foregroundColor(.white)
                        .padding(.horizontal, VoiidSpacing.md).padding(.vertical, 6)
                        .background(VoiidColor.error).clipShape(Capsule())
                }
                shutter
                    .padding(.bottom, 48)
            }
        }
        .onAppear {
            cam.maxSeconds = mode.maxSeconds
            cam.start()
        }
        .onDisappear { cam.stop() }
        .onChange(of: cam.captured) { _, out in
            guard let out else { return }
            onCapture(out.photo, out.video); dismiss()
        }
        .alert(
            "Recording failed",
            isPresented: Binding(
                get: { cam.recordingError != nil },
                set: { if !$0 { cam.recordingError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { cam.recordingError = nil }
        } message: {
            Text(cam.recordingError ?? "")
        }
    }

    private var shutter: some View {
        Circle()
            .stroke(.white, lineWidth: 4)
            .frame(width: 76, height: 76)
            .overlay(Circle().fill(cam.isRecording ? VoiidColor.error : .white)
                .frame(width: cam.isRecording ? 34 : 62, height: cam.isRecording ? 34 : 62))
            .onTapGesture {
                // In video-only mode a tap TOGGLES recording. Press-and-hold still works for
                // people who expect the story gesture, but tap-to-start is what a 90s clip
                // actually needs — nobody holds a finger down for a minute and a half.
                if mode.videoOnly {
                    if cam.isRecording { cam.stopRecording() } else { cam.startRecording() }
                } else {
                    cam.capturePhoto()
                }
            }
            .onLongPressGesture(minimumDuration: 0.3, pressing: { pressing in
                // Hold-to-record, but never let the release of a tap-to-start recording stop
                // it immediately: in video-only mode the tap already owns the toggle.
                if pressing {
                    if !cam.isRecording { cam.startRecording() }
                } else if !mode.videoOnly {
                    cam.stopRecording()
                }
            }, perform: {})
    }
}

// MARK: - Preview layer

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView(); v.videoPreviewLayer.session = session
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - Capture controller

/// NOT @MainActor: AVCaptureSession configuration and start/stop run on a private serial
/// queue (isolating them to the main actor would freeze the UI and is Apple-discouraged).
/// The @Published UI state is always mutated back on the main queue.
private final class CameraController: NSObject, ObservableObject,
                                      AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
    struct Output: Equatable { var photo: Data?; var video: URL? }

    let session = AVCaptureSession()
    private let photoOut = AVCapturePhotoOutput()
    private let movieOut = AVCaptureMovieFileOutput()
    private var input: AVCaptureDeviceInput?
    private var position: AVCaptureDevice.Position = .back
    private let queue = DispatchQueue(label: "voiid.story.camera")

    @Published var isRecording = false
    @Published var recordSeconds = 0
    @Published var captured: Output?
    private var timer: Timer?

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            self.configureInput(position: self.position)
            if self.session.canAddOutput(self.photoOut) { self.session.addOutput(self.photoOut) }
            if self.session.canAddOutput(self.movieOut) { self.session.addOutput(self.movieOut) }
            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    /// Tearing the session down while the movie file is still being finalized truncates or
    /// loses the recording, and AVFoundation reports that as a delegate `error` the old code
    /// silently swallowed — the "recorded a clip, got nothing back" bug. If a recording is
    /// still in flight, stop it and let the delegate tear the session down once the file is
    /// safely closed.
    func stop() {
        if isRecording {
            pendingStopAfterFinish = true
            stopRecording()
            return
        }
        queue.async { [weak self] in self?.session.stopRunning() }
    }

    private var pendingStopAfterFinish = false

    private func configureInput(position: AVCaptureDevice.Position) {
        if let input { session.removeInput(input) }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let newInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(newInput) else { return }
        session.addInput(newInput)
        input = newInput
        // Add the mic once, for video recording with sound.
        if session.inputs.count < 2, let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput) {
            session.addInput(micInput)
        }
    }

    func flip() {
        position = (position == .back) ? .front : .back
        queue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.configureInput(position: self.position)
            self.session.commitConfiguration()
        }
    }

    func capturePhoto() {
        Haptics.tap()
        queue.async { [weak self] in
            guard let self else { return }
            self.photoOut.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    /// Hard cap in seconds, supplied by the presenting view's CameraMode (30 story / 90 clip).
    /// A hardcoded 30 here silently truncated every clip recorded past half a minute.
    var maxSeconds: Int = 30

    func startRecording() {
        guard !isRecording else { return }
        Haptics.rigid()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("story_\(UUID().uuidString).mov")
        isRecording = true; recordSeconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordSeconds += 1
            if self.recordSeconds >= self.maxSeconds { self.stopRecording() }   // §8.2 hard cap
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.movieOut.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false; timer?.invalidate(); timer = nil
        queue.async { [weak self] in self?.movieOut.stopRecording() }
    }

    // MARK: Delegates (called off the main queue → hop back to main for @Published)

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        DispatchQueue.main.async { self.captured = Output(photo: data, video: nil) }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        // AVFoundation sets AVErrorRecordingSuccessfullyFinished on a recording that was cut
        // short but whose file IS complete and playable (hitting the duration cap, or the
        // session stopping). Treating every non-nil error as failure threw those away.
        let salvageable = (error as NSError?)
            .map { ($0.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true }
            ?? false
        let usable = error == nil || salvageable

        DispatchQueue.main.async {
            if usable {
                self.captured = Output(photo: nil, video: outputFileURL)
            } else {
                // Surface it. A dropped recording with no message is indistinguishable from
                // a broken shutter button.
                self.recordingError = (error as NSError?)?.localizedDescription
                    ?? "The recording could not be saved."
                try? FileManager.default.removeItem(at: outputFileURL)
            }
            if self.pendingStopAfterFinish {
                self.pendingStopAfterFinish = false
                self.queue.async { [weak self] in self?.session.stopRunning() }
            }
        }
    }

    @Published var recordingError: String?
}
