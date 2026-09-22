import Foundation

@main struct DocumentCheck {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            checks += 1
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Notes.txt")
        let bytes = Data("Actual document bytes\n".utf8)
        try bytes.write(to: file)
        let document = try ChatDocumentFile.read(file)
        check(document.data == bytes, "File bytes preserved")
        check(document.name == "Notes.txt", "Filename preserved")
        check(document.mime == "text/plain", "MIME inferred from file")
        check(ChatDocumentFile.safeName("../../report.pdf", mime: "application/pdf") == "report.pdf", "Traversal removed")
        check(ChatDocumentFile.safeName("C:\\files\\report.pdf", mime: "application/pdf") == "report.pdf", "Backslashes removed")
        check(ChatDocumentFile.safeName("..", mime: "application/pdf") == "Document.pdf", "Unsafe filename gets typed fallback")
        check(!ChatDocumentFile.safeName("a\u{0}b.txt", mime: "text/plain").contains("\u{0}"), "Control characters removed")
        do { _ = try ChatDocumentFile.read(directory); preconditionFailure("Directory accepted") }
        catch ChatDocumentFile.ImportError.notAFile { checks += 1 }
        let large = directory.appendingPathComponent("large.pdf")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(ChatDocumentFile.maximumBytes + 1))
        try handle.close()
        do { _ = try ChatDocumentFile.read(large); preconditionFailure("Oversized document accepted") }
        catch ChatDocumentFile.ImportError.tooLarge { checks += 1 }
        do { _ = try ChatDocumentFile.read(directory.appendingPathComponent("missing.pdf")); preconditionFailure("Missing file accepted") }
        catch { checks += 1 }
        let old = Data(#"{"mediaUrl":"media/key","mime":"application/pdf","key":"secret","nonce":"nonce","sha256":"hash"}"#.utf8)
        var ref = try JSONDecoder().decode(MediaRef.self, from: old)
        check(ref.filename == nil, "Old attachments still decode")
        ref.filename = "report.pdf"
        let envelope = ChatEngine.MediaEnvelope(media: ref, caption: "report.pdf")
        let decoded = try JSONDecoder().decode(ChatEngine.MediaEnvelope.self, from: JSONEncoder().encode(envelope))
        check(decoded.media.filename == "report.pdf" && decoded.media.key == "secret", "Encrypted envelope retains filename and key")
        check(decoded.caption == "report.pdf", "Direct and group envelope caption round-trips")
        print("Passed \(checks) document import and envelope checks")
    }
}
