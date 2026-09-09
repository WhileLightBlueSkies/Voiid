#!/usr/bin/env python3
"""Exercise production iOS camera restart scheduling with asynchronous native stops."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/ios/Voiid/Voiid/Networking/CallService.swift').read_text()
start = source.index('    private func startCapture(capturer:')
methods = source[start:source.index('    private func fetchIceServers', start)]
methods = methods.replace('private func', 'func')
fixture = r'''
import Foundation
struct Dimensions { let width: Int32 = 1280 }
struct Rate { let maxFrameRate = 30.0 }
struct Format {
    let formatDescription = Dimensions()
    let videoSupportedFrameRateRanges = [Rate()]
}
func CMVideoFormatDescriptionGetDimensions(_ value: Dimensions) -> Dimensions { value }
final class AVCaptureDevice {
    enum Position { case front, back }
    let position: Position
    init(_ position: Position) { self.position = position }
}
final class LKRTCCameraVideoCapturer {
    var running = true
    var pendingStops: [() -> Void] = []
    var started: [AVCaptureDevice.Position] = []
    static func captureDevices() -> [AVCaptureDevice] { [.init(.front), .init(.back)] }
    static func supportedFormats(for device: AVCaptureDevice) -> [Format] { [Format()] }
    func stopCapture(completion: (() -> Void)? = nil) {
        if let completion { pendingStops.append(completion) } else { running = false }
    }
    func completeStops() {
        let callbacks = pendingStops; pendingStops = []; running = false
        callbacks.forEach { $0() }
    }
    func startCapture(with device: AVCaptureDevice, format: Format, fps: Int,
                      completion: (Error?) -> Void) {
        precondition(!running, "Starting before stop completion recreates the duplicate native connection")
        running = true; started.append(device.position); completion(nil)
    }
}
enum State { case connected, ended }
struct Call { var id = "current"; var isVideo = true; var state = State.connected }
@MainActor final class Harness {
    var active: Call? = Call()
    var videoCapturer: LKRTCCameraVideoCapturer? = LKRTCCameraVideoCapturer()
    var cameraRequestGeneration = 0
    var videoEnabled = true
    var isOnHold = false
    var captureSuspendedForBackground = false
    func isCurrentCall(_ id: String) -> Bool { active?.id == id && active?.state != .ended }
''' + methods + r'''
}
@main struct Check {
    @MainActor static func drain() async { for _ in 0..<20 { await Task.yield() } }
    @MainActor static func main() async {
        let ordered = Harness(), camera = ordered.videoCapturer!
        ordered.startCapture(capturer: camera, front: false)
        precondition(camera.started.isEmpty)
        camera.completeStops(); await drain()
        precondition(camera.started == [.back])

        let rapid = Harness(), rapidCamera = rapid.videoCapturer!
        rapid.startCapture(capturer: rapidCamera, front: false)
        rapid.startCapture(capturer: rapidCamera, front: true)
        rapidCamera.completeStops(); await drain()
        precondition(rapidCamera.started == [.front], "Only the latest camera request should start")

        for condition in 0..<5 {
            let h = Harness(), c = h.videoCapturer!
            h.startCapture(capturer: c, front: false)
            switch condition {
            case 0: h.isOnHold = true
            case 1: h.active?.state = .ended
            case 2: h.videoEnabled = false
            case 3: h.videoCapturer = LKRTCCameraVideoCapturer()
            default: h.captureSuspendedForBackground = true
            }
            c.completeStops(); await drain()
            precondition(c.started.isEmpty, "A stale camera callback must not restart capture")
        }

        let cancelled = Harness(), cancelledCamera = cancelled.videoCapturer!
        cancelled.startCapture(capturer: cancelledCamera, front: false)
        cancelled.stopCapture(capturer: cancelledCamera)
        cancelledCamera.completeStops(); await drain()
        precondition(cancelledCamera.started.isEmpty)
        print("PASS: 8 production camera lifecycle cases: stop ordering, rapid flips, hold, end, camera off, replacement, background, cancellation")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='voiid-camera-lifecycle-') as directory:
    folder = Path(directory)
    swift = folder / 'CameraCheck.swift'
    swift.write_text(fixture)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'cache'),
                    str(swift), '-o', str(folder / 'check')], check=True)
    subprocess.run([str(folder / 'check')], check=True)
