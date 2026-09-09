#!/usr/bin/env python3
"""Compile iOS's actual v1 commitment and SDP parser against shared test vectors."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'apps/ios/Voiid/Voiid/Networking/CallKeyExchange.swift').read_text()
a = source.index('    private func commitmentTag(')
b = source.index('    /// Settle the verification', a)
method = source[a:b].replace('private func', 'func', 1)
a = source.index('    private func frameMediaKey(')
b = source.index('    /// The shared-key provider', a)
media_method = source[a:b].replace('private func', 'func', 1)
with tempfile.TemporaryDirectory(prefix='voiid-call-key-') as directory:
    folder = Path(directory)
    fixture = folder / 'main.swift'
    fixture.write_text('''import Foundation
import CryptoKit
struct CallSecret { let secret: String }
struct Keys { let masterKey: Data; let masterSalt: Data }
func srtpKeysFor1to1(callSecret: CallSecret) throws -> Keys {
    Keys(masterKey: Data(0..<16), masterSalt: Data(16..<30))
}
''' + method + '''
struct MediaKeyFixture {
    static let frameKeySalt = Data("VoiidFrameKey v1".utf8)
''' + media_method + '''
}
let raw = Data(0..<32)
let padded = raw.base64EncodedString()
let unpadded = padded.replacingOccurrences(of: "=", with: "")
// This is the wire format emitted by e2e-core/vodozemac, not a padded fixture.
precondition(unpadded.count == 43)
precondition(Data(base64Encoded: unpadded) == nil)
let media = MediaKeyFixture()
func mediaHex(_ value: String) -> String? {
    media.frameMediaKey(CallSecret(secret: value))?.withUnsafeBytes {
        Data($0).map { String(format: "%02x", $0) }.joined()
    }
}
// RFC 5869 vector from Android's HMAC extract/expand with the same fixed input.
precondition(mediaHex(unpadded) == "cf5ee977f59af131643cc3b30ecb3df3ab9fabd8a8975b3fcbfd48773c0143f6")
precondition(mediaHex(padded) == mediaHex(unpadded))
precondition(mediaHex("not a base64 secret!") == nil)
precondition(mediaHex(Data(0..<31).base64EncodedString()) == nil)
precondition(mediaHex("") == nil)
print("Swift media key: unpadded Rust secret matches Android HKDF; padded equivalent and invalid-secret rejection passed")
let a = CallSDPTuning.dtlsFingerprint(in: "v=0\\r\\na=fingerprint:SHA-256 aa:bb\\r\\n")!
let b = CallSDPTuning.dtlsFingerprint(in: "a=fingerprint:sha-256 cc:dd\\n")!
let secret = CallSecret(secret: "fixture")
let tag = commitmentTag(secret: secret, fingerprints: [a, b])!
let hex = Data(base64Encoded: tag)!.map { String(format: "%02x", $0) }.joined()
precondition(hex == "a21ba04a2cb9e210d34e5286eef4095487c47492d14b5fe2d1ce56d98d1f110f")
precondition(tag == commitmentTag(secret: secret, fingerprints: [b, a]))
precondition(tag != commitmentTag(secret: secret, fingerprints: [a, "sha-256 EE:FF"]))
precondition(CallSDPTuning.dtlsFingerprint(in: "v=0") == nil)
print("Swift call commitment: shared Android vector, reversed peers, tampered fingerprint and missing fingerprint passed")
''')
    subprocess.run(['swiftc', '-module-cache-path', str(folder / 'cache'), str(root / 'apps/ios/Voiid/Voiid/Networking/CallSDPTuning.swift'), str(fixture), '-o', str(folder / 'check')], check=True)
    subprocess.run([str(folder / 'check')], check=True)
