#!/usr/bin/env python3
"""Compile the production Swift message records and verify linked-device cache repair."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/ios/Voiid/Voiid/Networking/ChatEngine.swift').read_text()

def declaration(name):
    start = source.index('struct ' + name + ':')
    body = source.index('{', start)
    depth = 1
    end = body + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

with tempfile.TemporaryDirectory(prefix='voiid-message-owner-') as directory:
    folder = Path(directory)
    (folder / 'models.swift').write_text('import Foundation\n' + declaration('MediaRef') + '\n' + declaration('DecryptedMessage'))
    (folder / 'main.swift').write_text('''import Foundation
let mine = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
let peer = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
let date = Date(timeIntervalSince1970: 1000)
var old = DecryptedMessage(id: "server-message", senderId: mine, text: "Sent from web नमस्ते", createdAt: date, isMine: false)
old.quotedId = "quoted-message"
old.quotedPreview = "Earlier text"
old.reactions = [peer: "❤️"]
old.deliveryStatus = "read"
old.readAt = date
let encoder = JSONEncoder()
let decoder = JSONDecoder()
let cached = try decoder.decode(DecryptedMessage.self, from: encoder.encode(old))
let fixed = cached.resolvingOwnership(for: mine.uppercased())
precondition(fixed.isMine)
var expected = old
expected.isMine = true
let before = try JSONSerialization.jsonObject(with: encoder.encode(expected)) as! NSDictionary
let after = try JSONSerialization.jsonObject(with: encoder.encode(fixed)) as! NSDictionary
precondition(before == after, "Repair must preserve every field except direction")
let restored = try decoder.decode(DecryptedMessage.self, from: encoder.encode(fixed))
precondition(restored.isMine && restored.id == old.id)
precondition(!old.resolvingOwnership(for: peer).isMine)
precondition(!old.resolvingOwnership(for: nil).isMine)
precondition(!old.resolvingOwnership(for: "").isMine)
let local = DecryptedMessage(id: "pending", senderId: "me", text: "offline", createdAt: date, isMine: true, pending: true)
precondition(local.resolvingOwnership(for: mine).isMine)
precondition(local.resolvingOwnership(for: mine).pending)
for value in [old, DecryptedMessage(id: "control", senderId: mine, text: "", createdAt: date, isMine: false, control: true), DecryptedMessage(id: "failure", senderId: mine, text: "unavailable", createdAt: date, isMine: false, failed: true)] {
    precondition(value.resolvingOwnership(for: mine).isMine)
}
print("Swift linked-device ownership: cached rows repaired; peer/unknown identities stay incoming; pending, control, failure and metadata preserved")
''')
    subprocess.run(['swiftc', '-module-cache-path', str(folder / 'cache'), str(folder / 'models.swift'), str(folder / 'main.swift'), '-o', str(folder / 'check')], check=True)
    subprocess.run([str(folder / 'check')], check=True)
