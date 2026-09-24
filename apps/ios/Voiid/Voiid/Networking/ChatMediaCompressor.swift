//
//  ChatMediaCompressor.swift
//  Voiid
//
//  The 25 MB chat limit, and the on-device compressor that makes a bigger file fit.
//  Designed in Voiid Ui (Chat/ChatAttachments.swift); the screens are Main/Media/ChatAttachSheets.swift.
//
//  ── ONE LIMIT FOR EVERYTHING ────────────────────────────────────────────────────
//  Anything sent in a chat — photo, video, document — is at most 25 MB. Over it, the file is
//  not refused: it is compressed HERE, on the phone, before it is encrypted. Voiid never sees
//  the file, compressed or not. The server enforces the same limit on the upload.
//
//  ── WHAT SHRINKS, AND HOW ───────────────────────────────────────────────────────
//  • Photos: re-encoded as JPEG, quietly — there is no visible trade-off to ask about.
//  • Video: re-encoded to a bitrate computed from the length, so the result lands under the
//    limit by design rather than by luck, and retried once lower if it does not. H.264, which
//    every Android phone plays; HEVC would be smaller but not universally decodable.
//  • PDF: pages re-drawn as JPEG images. Text stops being selectable — the sheet says so.
//  • Anything else (zip, docx, keynote…) is already compressed. The sheet says it cannot be
//    made smaller rather than promising a size it cannot reach.
//

import AVFoundation
import CoreImage
import CoreTransferable
import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers

nonisolated enum ChatMediaLimit {
    /// Decimal megabytes, as the Files app and Photos show sizes — "25 MB" means the same thing
    /// to the person reading it as to this check.
    static let bytes: Int64 = 25_000_000

    static func text(_ b: Int64) -> String {
        let mb = Double(b) / 1_000_000
        if mb >= 100 { return String(format: "%.0f MB", mb) }
        if mb >= 1 { return String(format: "%.1f MB", mb).replacingOccurrences(of: ".0 MB", with: " MB") }
        return String(format: "%.0f KB", max(1, Double(b) / 1000))
    }

    static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

// MARK: - What is being sent

/// A picked file that is over the limit, on disk in the app's temp directory.
nonisolated struct ChatOversizeFile: Identifiable, Sendable {
    enum Kind: Sendable, Equatable {
        case video(seconds: Double)
        case pdf(pages: Int)
        /// Nothing useful can be done to it.
        case other
    }

    let id = UUID()
    let url: URL
    let name: String
    let bytes: Int64
    let kind: Kind
}

/// A way to make a video fit, and what it is expected to come out at.
nonisolated struct ChatVideoPlan: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let note: String
    let longEdge: CGFloat
    let videoBitrate: Int
    let audioBitrate: Int
    let seconds: Double

    var estimatedBytes: Int64 {
        Int64(Double(videoBitrate + audioBitrate) * seconds / 8 * 1.02)
    }
}

nonisolated enum ChatVideoPlanner {
    /// Aim under the limit: the container, keyframes and rate control all add a little.
    private static let budgetBits = Double(ChatMediaLimit.bytes) * 8 * 0.92
    private static let audioBitrate = 96_000

    /// Resolution tiers: the long edge, the least bitrate that still looks right at it, and
    /// the most worth spending.
    private static let tiers: [(edge: CGFloat, label: String, min: Double, max: Double)] = [
        (1920, "1080p", 3_500_000, 8_000_000),
        (1280, "720p", 1_600_000, 4_000_000),
        (960, "540p", 900_000, 2_200_000),
        (640, "360p", 450_000, 1_100_000),
    ]

    /// The choices for a video of this length, best first. Empty when even the lowest tier
    /// will not fit — the sheet offers a trim instead.
    static func plans(seconds: Double, sourceBytes: Int64) -> [ChatVideoPlan] {
        guard seconds > 0 else { return [] }
        let fit = budgetBits / seconds - Double(audioBitrate)
        // Never spend more than the source had: re-encoding cannot add detail.
        let sourceBitrate = Double(sourceBytes) * 8 / seconds

        guard let bestIndex = tiers.firstIndex(where: { fit >= $0.min }) else { return [] }
        let best = tiers[bestIndex]
        let bestRate = min(fit, best.max, sourceBitrate * 0.9)
        var out = [ChatVideoPlan(id: "best", title: "Best quality that fits",
                                 note: "\(best.label) — looks sharp full-screen",
                                 longEdge: best.edge, videoBitrate: Int(bestRate),
                                 audioBitrate: audioBitrate, seconds: seconds)]

        if bestIndex + 1 < tiers.count {
            let next = tiers[bestIndex + 1]
            let rate = min(bestRate * 0.5, next.max)
            if rate >= next.min {
                out.append(ChatVideoPlan(id: "small", title: "Smaller",
                                         note: "\(next.label) — quicker to send on mobile data",
                                         longEdge: next.edge, videoBitrate: Int(rate),
                                         audioBitrate: 64_000, seconds: seconds))
            }
        }
        return out
    }

    /// For a video too long for any tier: the longest stretch that fits at the lowest one.
    static func maxSeconds() -> Double {
        (budgetBits / (tiers.last!.min + 64_000)).rounded(.down)
    }
}

// MARK: - Video

nonisolated enum ChatCompressError: LocalizedError {
    case unreadable, failed(String), stillTooBig(Int64)

    var errorDescription: String? {
        switch self {
        case .unreadable: "Couldn't read that file."
        case .failed(let why): why
        case .stillTooBig(let b): "It's still \(ChatMediaLimit.text(b)) after compressing. Try a smaller option."
        }
    }
}

nonisolated enum ChatVideoCompressor {
    /// Re-encode `source` to the plan, keeping only `range` of it. Retries once at 80% of the
    /// bitrate if the first result is over the limit.
    static func compress(_ source: URL, plan: ChatVideoPlan, range: CMTimeRange,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let first = try await transcode(source, plan: plan, range: range, progress: { progress($0 * 0.95) })
        let size = ChatMediaLimit.size(of: first)
        if size <= ChatMediaLimit.bytes { progress(1); return first }

        try? FileManager.default.removeItem(at: first)
        let lower = ChatVideoPlan(id: plan.id, title: plan.title, note: plan.note, longEdge: plan.longEdge,
                                  videoBitrate: Int(Double(plan.videoBitrate) * 0.8 * Double(ChatMediaLimit.bytes) / Double(size)),
                                  audioBitrate: plan.audioBitrate, seconds: plan.seconds)
        let second = try await transcode(source, plan: lower, range: range, progress: { progress(0.95 + $0 * 0.05) })
        let secondSize = ChatMediaLimit.size(of: second)
        guard secondSize <= ChatMediaLimit.bytes else {
            try? FileManager.default.removeItem(at: second)
            throw ChatCompressError.stillTooBig(secondSize)
        }
        progress(1)
        return second
    }

    private static func transcode(_ source: URL, plan: ChatVideoPlan, range: CMTimeRange,
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ChatCompressError.unreadable
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let natural = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)

        // Scale in the track's own (unrotated) orientation; the rotation rides along as the
        // output track's transform, exactly as the camera wrote it.
        let longest = max(natural.width, natural.height)
        let scale = min(1, plan.longEdge / max(longest, 1))
        let width = Int((natural.width * scale / 2).rounded()) * 2
        let height = Int((natural.height * scale / 2).rounded()) * 2

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat_video_\(UUID().uuidString).mp4")

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw ChatCompressError.unreadable }
        reader.add(videoOut)

        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: plan.videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: true,
            ] as [String: Any],
        ])
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoIn) else { throw ChatCompressError.failed("Couldn't set up the video encoder.") }
        writer.add(videoIn)

        var audioOut: AVAssetReaderTrackOutput?
        var audioIn: AVAssetWriterInput?
        if let audioTrack {
            // The reader resamples and down-mixes to plain stereo PCM, so the AAC encoder is
            // always handed one known format, whatever the source recorded.
            let pcm = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            let aac = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: plan.audioBitrate,
            ])
            aac.expectsMediaDataInRealTime = false
            if reader.canAdd(pcm), writer.canAdd(aac) {
                reader.add(pcm)
                writer.add(aac)
                audioOut = pcm
                audioIn = aac
            }
        }

        guard reader.startReading() else {
            throw ChatCompressError.failed(reader.error?.localizedDescription ?? "Couldn't read the video.")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw ChatCompressError.failed(writer.error?.localizedDescription ?? "Couldn't write the video.")
        }
        writer.startSession(atSourceTime: range.start)

        let job = TranscodeJob(reader: reader, writer: writer)
        let start = range.start.seconds
        let length = max(range.duration.seconds, 0.001)

        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    await job.pump(videoOut, into: videoIn, label: "video") { pts in
                        progress(min(1, max(0, (pts - start) / length)))
                    }
                }
                if let audioOut, let audioIn {
                    group.addTask { await job.pump(audioOut, into: audioIn, label: "audio") { _ in } }
                }
                try await group.waitForAll()
            }
        } onCancel: {
            job.cancel()
        }

        if Task.isCancelled || job.cancelled {
            try? FileManager.default.removeItem(at: out)
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: out)
            throw ChatCompressError.failed(reader.error?.localizedDescription ?? "Couldn't read the video.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw ChatCompressError.failed(writer.error?.localizedDescription ?? "Couldn't finish the video.")
        }
        return out
    }
}

/// Moves samples from reader outputs to writer inputs on AVFoundation's own queues.
nonisolated private final class TranscodeJob: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    private let lock = NSLock()
    private var _cancelled = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    init(reader: AVAssetReader, writer: AVAssetWriter) {
        self.reader = reader
        self.writer = writer
    }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
        reader.cancelReading()
        writer.cancelWriting()
    }

    /// Feeds one track until the reader runs dry, then marks the input finished.
    func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String,
              onTime: @escaping @Sendable (Double) -> Void) async {
        let queue = DispatchQueue(label: "voiid.chat.compress.\(label)")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            // Every callback runs on `queue`, so the flag is only ever touched there.
            let state = PumpState()
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !state.finished else { return }
                func finish() {
                    state.finished = true
                    input.markAsFinished()
                    done.resume()
                }
                while input.isReadyForMoreMediaData {
                    if cancelled || reader.status != .reading { finish(); return }
                    guard let sample = output.copyNextSampleBuffer() else { finish(); return }
                    onTime(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                    if !input.append(sample) {
                        reader.cancelReading()
                        finish()
                        return
                    }
                }
            }
        }
    }
}

nonisolated private final class PumpState: @unchecked Sendable {
    var finished = false
}

// MARK: - PDF

nonisolated enum ChatPDFCompressor {
    enum Quality: String, CaseIterable, Identifiable, Sendable {
        case balanced, smallest
        var id: String { rawValue }
        var title: String { self == .balanced ? "Balanced" : "Smallest" }
        var note: String {
            self == .balanced ? "Sharp enough to print" : "Clear on screen, lightest to send"
        }
        var dpi: CGFloat { self == .balanced ? 144 : 96 }
        var jpegQuality: CGFloat { self == .balanced ? 0.62 : 0.5 }
        /// A typical page at this setting — an estimate, shown as "about".
        var bytesPerPage: Int64 { self == .balanced ? 190_000 : 95_000 }
    }

    static func estimate(pages: Int, quality: Quality) -> Int64 {
        Int64(pages) * quality.bytesPerPage + 20_000
    }

    /// Every page re-drawn as a JPEG image at the quality's resolution, in a new PDF of the
    /// same page sizes. The JPEG bytes are embedded as they are (DCT), not re-encoded.
    static func compress(_ source: URL, quality: Quality,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: source), document.pageCount > 0 else {
                throw ChatCompressError.unreadable
            }
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("chat_pdf_\(UUID().uuidString).pdf")
            guard let context = CGContext(out as CFURL, mediaBox: nil, nil) else {
                throw ChatCompressError.failed("Couldn't create the PDF.")
            }
            let count = document.pageCount
            for index in 0..<count {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                // Rotated pages are drawn upright, as they are displayed.
                let rotated = page.rotation % 180 != 0
                var box = CGRect(origin: .zero, size: rotated
                                 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
                let pixels = CGSize(width: box.width * quality.dpi / 72, height: box.height * quality.dpi / 72)
                let image = autoreleasepool { page.thumbnail(of: pixels, for: .mediaBox) }
                guard let jpeg = image.jpegData(compressionQuality: quality.jpegQuality),
                      let provider = CGDataProvider(data: jpeg as CFData),
                      let cg = CGImage(jpegDataProviderSource: provider, decode: nil,
                                       shouldInterpolate: true, intent: .defaultIntent) else { continue }
                context.beginPage(mediaBox: &box)
                context.draw(cg, in: box)
                context.endPage()
                progress(Double(index + 1) / Double(count))
            }
            context.closePDF()
            let size = ChatMediaLimit.size(of: out)
            guard size <= ChatMediaLimit.bytes else {
                try? FileManager.default.removeItem(at: out)
                throw ChatCompressError.stillTooBig(size)
            }
            return out
        }.value
    }
}

// MARK: - Photos

nonisolated enum ChatPhotoCompressor {
    /// A photo over the limit, as a JPEG under it. Tries the full size at falling quality, then
    /// smaller sizes. Nil only when the data is not an image.
    static func fit(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let edges: [CGFloat] = [max(image.size.width, image.size.height) * image.scale, 6000, 4096, 3000]
        for edge in edges {
            let resized = resize(image, longEdge: edge)
            for quality in [0.85, 0.72, 0.6] as [CGFloat] {
                if let jpeg = resized.jpegData(compressionQuality: quality), Int64(jpeg.count) <= ChatMediaLimit.bytes {
                    return jpeg
                }
            }
        }
        return resize(image, longEdge: 2048).jpegData(compressionQuality: 0.6)
    }

    private static func resize(_ image: UIImage, longEdge: CGFloat) -> UIImage {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let scale = min(1, longEdge / max(pixels.width, pixels.height))
        guard scale < 1 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Picking video as a file

/// A picked video, copied to temp as a FILE. Loading a 1 GB video as `Data` is how a picker
/// kills an app; a file on disk is read only as the encoder needs it.
nonisolated struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("chat_pick_\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }

    /// The type to label the upload with, from the container.
    var mime: String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "video/quicktime"
    }
}

// MARK: - Documents

nonisolated enum ChatAttachmentIntake {
    /// Deletes `url` ONLY if it is one of our own copies in the temp directory. A file that
    /// cannot be compressed is shown from where the person keeps it — deleting that on close
    /// would destroy their original in Files.
    static func removeTemporary(_ url: URL) {
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(temp + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// A picked document over the limit, copied into temp for the compressor. Nil when it is
    /// within the limit (or unreadable) — the ordinary document path handles those.
    static func oversizeDocument(_ url: URL) async -> ChatOversizeFile? {
        await Task.detached(priority: .userInitiated) { () -> ChatOversizeFile? in
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let bytes = ChatMediaLimit.size(of: url)
            guard bytes > ChatMediaLimit.bytes else { return nil }

            let name = url.lastPathComponent
            let isPDF = UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true
            // Only a PDF is worth copying: nothing else can be made smaller, and a 2 GB
            // archive should not be duplicated just to be told so.
            guard isPDF else {
                return ChatOversizeFile(url: url, name: name, bytes: bytes, kind: .other)
            }
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("chat_doc_\(UUID().uuidString).pdf")
            do {
                try FileManager.default.copyItem(at: url, to: copy)
            } catch {
                return ChatOversizeFile(url: url, name: name, bytes: bytes, kind: .other)
            }
            let pages = PDFDocument(url: copy)?.pageCount ?? 0
            return ChatOversizeFile(url: copy, name: name, bytes: bytes,
                                    kind: pages > 0 ? .pdf(pages: pages) : .other)
        }.value
    }
}
