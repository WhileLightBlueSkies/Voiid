# Voiid E2E Bindings — Public API Surface

Generated UniFFI bindings (gitignored, built per-machine). This is the **real** public
API surface dumped from the generated files, not from memory.

- iOS: `apps/ios/Voiid/Voiid/E2E/voiid.swift`
- Android: `apps/android/app/src/main/java/uniffi/voiid/voiid.kt`

**Errors:** Swift throws `E2eFfiError` (`.NoSession`, `.DecryptionFailed`, `.InvalidKey`,
`.Serialization`); Kotlin throws `E2eFfiException.{NoSession,DecryptionFailed,InvalidKey,Serialization}`.

---

## Constructors & static factories

Construction is via static / companion factories, not plain `init(...)`.

| Type | Swift | Kotlin |
|---|---|---|
| **Identity.create** | `static func create() -> Identity` | `companion object` → `fun create(): Identity` |
| **Identity.restore** | `static func restore(pickle: String, pickleKey: Data) throws -> Identity` | `fun restore(pickle: String, pickleKey: ByteArray): Identity` |
| **Session.restore** | `static func restore(pickle: String, pickleKey: Data) throws -> Session` | `fun restore(pickle: String, pickleKey: ByteArray): Session` |
| **GroupMember.create** | `static func create(identity: Data) throws -> GroupMember` | `fun create(identity: ByteArray): GroupMember` |

- `Identity.create()` takes no args — it generates a fresh identity.
- `GroupMember.create(identity:)` takes the identity bytes.
- `Session` is only obtained via `Identity.startSession` / `acceptSession`, or
  `Session.restore`. There is no public `Session.create`.

---

## Identity

| | Swift | Kotlin |
|---|---|---|
| publishBundle | `publishBundle(oneTimeKeyCount: UInt32) -> PublicBundle` | `publishBundle(oneTimeKeyCount: UInt): PublicBundle` |
| replenishPrekeys | `replenishPrekeys(count: UInt32) -> PublicBundle` | `replenishPrekeys(count: UInt): PublicBundle` |
| fingerprint | `fingerprint() -> String` | `fingerprint(): String` |
| maxOneTimeKeys | `maxOneTimeKeys() -> UInt32` | `maxOneTimeKeys(): UInt` |
| startSession | `startSession(theirIdentityKey: String, theirOneTimeKey: String) throws -> Session` | `startSession(theirIdentityKey: String, theirOneTimeKey: String): Session` |
| acceptSession | `acceptSession(theirIdentityKey: String, firstMessage: WireMessage) throws -> AcceptedSession` | `acceptSession(theirIdentityKey: String, firstMessage: WireMessage): AcceptedSession` |
| toPickle | `toPickle(pickleKey: Data) throws -> String` | `toPickle(pickleKey: ByteArray): String` |

---

## Session

| | Swift | Kotlin |
|---|---|---|
| encrypt | `encrypt(plaintext: Data) throws -> WireMessage` | `encrypt(plaintext: ByteArray): WireMessage` |
| decrypt | `decrypt(message: WireMessage) throws -> Data` | `decrypt(message: WireMessage): ByteArray` |
| toPickle | `toPickle(pickleKey: Data) throws -> String` | `toPickle(pickleKey: ByteArray): String` |

---

## GroupMember

| | Swift | Kotlin |
|---|---|---|
| createGroup | `createGroup() throws -> GroupSession` | `createGroup(): GroupSession` |
| joinGroup | `joinGroup(welcome: Data, ratchetTree: Data) throws -> GroupSession` | `joinGroup(welcome: ByteArray, ratchetTree: ByteArray): GroupSession` |
| keyPackage | `keyPackage() throws -> Data` | `keyPackage(): ByteArray` |

---

## GroupSession

| | Swift | Kotlin |
|---|---|---|
| addMember | `addMember(member: GroupMember, theirKeyPackage: Data) throws -> AddMemberOutput` | `addMember(member: GroupMember, theirKeyPackage: ByteArray): AddMemberOutput` |
| removeMember | `removeMember(member: GroupMember, identity: Data) throws -> Data` | `removeMember(member: GroupMember, identity: ByteArray): ByteArray` |
| encrypt | `encrypt(member: GroupMember, plaintext: Data) throws -> Data` | `encrypt(member: GroupMember, plaintext: ByteArray): ByteArray` |
| decrypt | `decrypt(member: GroupMember, message: Data) throws -> Data?` | `decrypt(member: GroupMember, message: ByteArray): ByteArray?` |
| callKeys | `callKeys(member: GroupMember) throws -> SrtpKeys` | `callKeys(member: GroupMember): SrtpKeys` |
| memberCount | `memberCount() -> UInt32` | `memberCount(): UInt` |

> Group `encrypt`/`decrypt` take `member:` as the **first** param, unlike 1:1 `Session`.

---

## Records (structs / data classes)

| Record | Fields |
|---|---|
| **PublicBundle** | `identityKey: String`, `signingKey: String`, `oneTimeKeys: [String]` |
| **WireMessage** | `msgType: UInt64` / `ULong`, `body: String` |
| **AcceptedSession** | `session: Session`, `plaintext: Data` / `ByteArray` |
| **AddMemberOutput** | `commit: Data`, `welcome: Data`, `ratchetTree: Data` |
| **MediaKey** | `key: String`, `nonce: String`, `ciphertextSha256: String` |
| **EncryptedMedia** | `ciphertext: Data`, `mediaKey: MediaKey` |
| **SrtpKeys** | `masterKey: Data`, `masterSalt: Data` |
| **CallSecret** | `secret: String` |

---

## Free functions

| | Swift | Kotlin |
|---|---|---|
| safetyNumber | `safetyNumber(ourId: Data, ourFingerprint: String, theirId: Data, theirFingerprint: String) -> String` | same, `ByteArray` / `String` |
| encryptMedia | `encryptMedia(plaintext: Data) throws -> EncryptedMedia` | `encryptMedia(plaintext: ByteArray): EncryptedMedia` |
| decryptMedia | `decryptMedia(mediaKey: MediaKey, ciphertext: Data) throws -> Data` | `decryptMedia(mediaKey: MediaKey, ciphertext: ByteArray): ByteArray` |
| newCallSecret | `newCallSecret() -> CallSecret` | `newCallSecret(): CallSecret` |
| srtpKeysFor1to1 | `srtpKeysFor1to1(callSecret: CallSecret) throws -> SrtpKeys` | `srtpKeysFor1to1(callSecret: CallSecret): SrtpKeys` |

---

## Usage shapes

### Swift

```swift
let id = Identity.create()
let bundle = id.publishBundle(oneTimeKeyCount: 100)
let session = try id.startSession(theirIdentityKey: theirIK, theirOneTimeKey: theirOTK)
let wire = try session.encrypt(plaintext: data)          // -> WireMessage(msgType, body)
let plain = try session.decrypt(message: wire)

// receiver side:
let accepted = try id.acceptSession(theirIdentityKey: theirIK, firstMessage: wire)
let session2 = accepted.session
let firstPlain = accepted.plaintext

// persist:
let pickle = try id.toPickle(pickleKey: key)
```

### Kotlin

`Identity.create()` etc. are on the companion object.

```kotlin
val id = Identity.create()
val bundle = id.publishBundle(100u)
val session = id.startSession(theirIk, theirOtk)
val wire = session.encrypt(data)                          // WireMessage(msgType: ULong, body: String)
val plain = session.decrypt(wire)
val accepted = id.acceptSession(theirIk, wire)            // .session, .plaintext
val pickle = id.toPickle(key)
```
