//
//  StoryCameraView.swift
//  Voiid
//
//  In-app camera for story capture, built from scratch (the app had NO AVCaptureSession
//  anywhere). NSCameraUsageDescription / mic permission are already declared and requested
//  at onboarding, so there is no new permission plumbing here.
//
//  Photo → JPEG Data; video → a temp .mov file URL (tap to snap, press-and-hold to record,
//  capped at 30s). The composer applies the size/re-encode caps (§8.2) before posting.
//

import SwiftUI
import AVFoundation

struct StoryCameraView: View {
    /// Called with a captured photo (Data, "image/jpeg") or video (temp file URL, "video/mp4").
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
                    Text(String(format: "%02d:%02d", cam.recordSeconds / 60, cam.recordSeconds % 60))
                        .font(VoiidFont.headline).foregroundColor(.white)
                        .padding(.horizontal, VoiidSpacing.md).padding(.vertical, 6)
                        .background(VoiidColor.error).clipShape(Capsule())
                }
                shutter
                    .padding(.bottom, 48)
            }
        }
        .onAppear { cam.start() }
        .onDisappear { cam.stop() }
        .onChange(of: cam.captured) { _, out in
            guard let out else { return }
            onCapture(out.photo, out.video); dismiss()
        }
    }

    private var shutter: some View {
        Circle()
            .stroke(.white, lineWidth: 4)
            .frame(width: 76, height: 76)
            .overlay(Circle().fill(cam.isRecording ? VoiidColor.error : .white)
                .frame(width: cam.isRecording ? 34 : 62, height: cam.isRecording ? 34 : 62))
            .onTapGesture { cam.capturePhoto() }
            .onLongPressGesture(minimumDuration: 0.3, pressing: { pressing in
                if pressing { cam.startRecording() } else { cam.stopRecording() }
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
    struct Output { var photo: Data?; var video: URL? }

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

    func stop() { queue.async { [weak self] in self?.session.stopRunning() } }

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

    func startRecording() {
        guard !isRecording else { return }
        Haptics.rigid()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("story_\(UUID().uuidString).mov")
        isRecording = true; recordSeconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordSeconds += 1
            if self.recordSeconds >= 30 { self.stopRecording() }   // §8.2 hard cap
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
        DispatchQueue.main.async { if error == nil { self.captured = Output(photo: nil, video: outputFileURL) } }
    }
}
