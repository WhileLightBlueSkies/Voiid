# Swift binding (iOS)

Generated Swift FFI for `voiid-e2e-core`, consumed by `apps/ios`. Crypto is
never written here — this is generated glue over the Rust core.

## Build

From `packages/e2e-core`:

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios  # once
./build-apple.sh
```

This produces `target/apple/Voiid.xcframework` and (re)generates
`bindings/swift/voiid.swift`.

## Wire into the Xcode project (`apps/ios/Voiid`)

1. Drag `Voiid.xcframework` into the project; add it to the app target's
   "Frameworks, Libraries, and Embedded Content".
2. Add `bindings/swift/voiid.swift` to the target.
3. `import voiid` (or the module name) in Swift.

## Usage sketch

```swift
// Each device, once:
let me = Identity.create()
let bundle = me.publishBundle(oneTimeKeyCount: 50)   // upload to backend

// Start a chat with a peer whose bundle we fetched:
let session = try me.startSession(theirIdentityKey: peer.identityKey,
                                  theirOneTimeKey: peer.oneTimeKeys[0])
let wire = try session.encrypt(plaintext: Array("hello".utf8))  // -> relay

// Verify there's no MITM (compare out of band):
let number = safetyNumber(ourFingerprint: me.fingerprint(),
                          theirFingerprint: peer.fingerprint)

// Persist across launches (store pickleKey in the Keychain):
let pickle = try session.toPickle(pickleKey: pickleKey)   // [UInt8], 32 bytes
```

Groups (`GroupMember`/`GroupSession`), media (`encryptMedia`/`decryptMedia`),
and calls (`newCallSecret`/`srtpKeysFor1to1`/`GroupSession.callKeys`) mirror the
Rust API one-to-one.
