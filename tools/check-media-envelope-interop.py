#!/usr/bin/env python3
"""Decode Kotlin-generated encrypted-media envelope fixtures using production Swift DTOs."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
source=(root/'apps/ios/Voiid/Voiid/Networking/ChatEngine.swift').read_text()
def extract(marker):
    a=source.index(marker); b=source.index('{',a); depth=1; end=b+1
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}');end+=1
    return source[a:end].replace('private struct MediaEnvelope','struct MediaEnvelope')
fixtures=list((root/'apps/android').glob('**/build/media-interop-fixtures/*.json'))
assert len(fixtures)==3, 'Run Android MediaEnvelopeInteropTest first'
main=r'''
let decoder = JSONDecoder()
for path in CommandLine.arguments.dropFirst() {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let original = try decoder.decode(MediaEnvelope.self, from: data)
    precondition(original.v == 1 && original.caption.isEmpty)
    var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    legacy.removeValue(forKey: "v")
    legacy.removeValue(forKey: "caption")
    let compatible = try decoder.decode(MediaEnvelope.self, from: JSONSerialization.data(withJSONObject: legacy))
    precondition(compatible.media == original.media && compatible.caption.isEmpty)
    legacy["v"] = 2
    do {
        _ = try decoder.decode(MediaEnvelope.self, from: JSONSerialization.data(withJSONObject: legacy))
        preconditionFailure("Unknown versions must not be silently accepted")
    } catch {}
    legacy.removeValue(forKey: "v")
    var media = legacy["media"] as! [String: Any]; media.removeValue(forKey: "key"); legacy["media"] = media
    do {
        _ = try decoder.decode(MediaEnvelope.self, from: JSONSerialization.data(withJSONObject: legacy))
        preconditionFailure("Encryption fields must remain required")
    } catch {}
    print("PASS Kotlin → Swift \(original.media.mime), omitted defaults, required keys and unknown versions")
}
'''
with tempfile.TemporaryDirectory(prefix='voiid-media-wire-') as directory:
    folder=Path(directory)
    (folder/'main.swift').write_text('import Foundation\n'+extract('struct MediaRef:')+'\n'+extract('private struct MediaEnvelope:')+'\n'+main)
    subprocess.run(['xcrun','swiftc','-module-cache-path',str(folder/'cache'),str(folder/'main.swift'),'-o',str(folder/'check')],check=True)
    subprocess.run([str(folder/'check')]+[str(p) for p in sorted(fixtures)],check=True)
