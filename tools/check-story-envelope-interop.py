#!/usr/bin/env python3
"""Decode actual Kotlin story fixtures with the production Swift envelopes."""
from pathlib import Path
import subprocess, tempfile, sys
root = Path(__file__).resolve().parents[1]
build_root = Path(sys.argv[1]) if len(sys.argv) > 1 else root
fixtures = sorted((build_root / 'apps/android/app/build/story-interop-fixtures').glob('*.json'))
assert len(fixtures) == 3, 'Run StoryEnvelopeInteropTest first'
def extract(source, marker):
    start = source.index(marker); end = source.index('{', start) + 1; depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[start:end]
chat = (root / 'apps/ios/Voiid/Voiid/Networking/ChatEngine.swift').read_text()
story = (root / 'apps/ios/Voiid/Voiid/Models/Story.swift').read_text()
code = 'import Foundation\n' + '\n'.join([
    extract(chat, 'struct MediaRef:'), extract(story, 'struct StoryEnvelope:'), extract(story, 'struct StoryViewEnvelope:')])
code += r'''
for path in CommandLine.arguments.dropFirst() {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    if path.hasSuffix("receipt.json") {
        let receipt = try JSONDecoder().decode(StoryViewEnvelope.self, from: data)
        precondition(receipt.viewed_at == 2000)
    } else {
        let story = try JSONDecoder().decode(StoryEnvelope.self, from: data)
        precondition(story.media.key == "test-key" && story.created_at == 1000 && story.expires_at == 86401000)
        precondition((story.caption ?? "").isEmpty && (story.allowsReplies ?? true))
        var fields = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var media = fields["media"] as! [String: Any]; media.removeValue(forKey: "key"); fields["media"] = media
        do {
            _ = try JSONDecoder().decode(StoryEnvelope.self, from: JSONSerialization.data(withJSONObject: fields))
            preconditionFailure("Missing encryption key accepted")
        } catch {}
    }
}
print("PASS: Kotlin → Swift photo, video and view-receipt envelopes; timestamps, omitted defaults and required encryption keys")
'''
with tempfile.TemporaryDirectory(prefix='voiid-story-interop-') as directory:
    folder=Path(directory); (folder/'main.swift').write_text(code)
    subprocess.run(['xcrun','swiftc','-module-cache-path',str(folder/'cache'),str(folder/'main.swift'),'-o',str(folder/'check')],check=True)
    subprocess.run([str(folder/'check')]+[str(p) for p in fixtures],check=True)
