#!/usr/bin/env python3
"""Exercise the production Swift credential guard against real MLS KeyPackages."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
core = root / 'packages/e2e-core'
subprocess.run(['cargo', 'build', '--locked', '--lib'], cwd=core, check=True)
source = (root / 'apps/ios/Voiid/Voiid/Networking/GroupEngine.swift').read_text()
start = source.index('    private func communityKeyPackageMatches(')
end = source.index('\n    private func fetchKeyPackages', start)
method = source[start:end].replace('private func', 'func', 1)
with tempfile.TemporaryDirectory(prefix='voiid-community-credential-') as directory:
    folder = Path(directory)
    fixture = folder / 'main.swift'
    fixture.write_text('''import Foundation
struct CredentialGuard {
''' + method + '''
}
let guarder = CredentialGuard()
let identity = "member-account::member-device"
let recipient = try GroupMember.create(identity: Data(identity.utf8))
let package = try recipient.keyPackage()
precondition(guarder.communityKeyPackageMatches(package, identity: identity))
precondition(!guarder.communityKeyPackageMatches(package, identity: "member-account::different-device"))
let forged = try GroupMember.create(identity: Data("owner-account::owner-device".utf8))
let forgedPackage = try forged.keyPackage()
precondition(!guarder.communityKeyPackageMatches(forgedPackage, identity: identity))
precondition(!guarder.communityKeyPackageMatches(Data([0,1,2]), identity: identity))
// Validation must not consume the recipient's private KeyPackage or change a real Space.
let owner = try GroupMember.create(identity: Data("real-owner::real-device".utf8))
let space = try owner.createGroup()
precondition(space.memberCount() == 1)
let joined = try space.addMember(member: owner, theirKeyPackage: package)
let recipientSpace = try recipient.joinGroup(welcome: joined.welcome, ratchetTree: joined.ratchetTree)
let ciphertext = try space.encrypt(member: owner, plaintext: Data("credential check passed".utf8))
let plaintext = try recipientSpace.decrypt(member: recipient, message: ciphertext)
precondition(plaintext == Data("credential check passed".utf8))
print("PASS: production Swift rejects mismatched device, forged owner identity and malformed package; valid admission still decrypts")
''')
    bindings = core / 'bindings/swift'
    subprocess.run(['swiftc', '-Xcc', '-fmodule-map-file=' + str(bindings / 'voiidFFI.modulemap'),
                    '-I', str(bindings), '-L', str(core / 'target/debug'), '-lvoiid_e2e_core',
                    str(bindings / 'voiid.swift'), str(fixture), '-o', str(folder / 'check')], check=True)
    env = dict(os.environ, DYLD_LIBRARY_PATH=str(core / 'target/debug'))
    subprocess.run([str(folder / 'check')], env=env, check=True)
