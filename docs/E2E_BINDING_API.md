# Voiid E2E Bindings — Public API Surface (real, from generated bindings)

> Dumped from the generated UniFFI bindings (gitignored, built per-machine), so
> this is the exact API the app code must call. Source of truth for chat wiring.
> iOS: `apps/ios/Voiid/Voiid/E2E/voiid.swift` · Android: `apps/android/.../uniffi/voiid/voiid.kt`
>
> Errors: Swift `E2eFfiError` (.NoSession/.DecryptionFailed/.InvalidKey/.Serialization);
> Kotlin `E2eFfiException.{NoSession,DecryptionFailed,InvalidKey,Serialization}`.

## Factories
- `Identity.create()` (no args) · `Identity.restore(pickle, pickleKey)` · `Session.restore(pickle, pickleKey)` · `GroupMember.create(identity: bytes)`
- Sessions come only from `Identity.startSession`/`acceptSession` or `Session.restore`.

## Identity
- `publishBundle(oneTimeKeyCount: UInt32/UInt) -> PublicBundle`
- `replenishPrekeys(count) -> PublicBundle`
- `fingerprint() -> String`
- `maxOneTimeKeys() -> UInt32/UInt`
- `startSession(theirIdentityKey: String, theirOneTimeKey: String) -> Session`
- `acceptSession(theirIdentityKey: String, firstMessage: WireMessage) -> AcceptedSession`
- `toPickle(pickleKey: bytes) -> String`

## Session (1:1)
- `encrypt(plaintext: bytes) -> WireMessage`
- `decrypt(message: WireMessage) -> bytes`
- `toPickle(pickleKey: bytes) -> String`

## GroupMember / GroupSession
- `GroupMember.createGroup() -> GroupSession` · `joinGroup(welcome, ratchetTree) -> GroupSession` · `keyPackage() -> bytes`
- `GroupSession.addMember(member, theirKeyPackage) -> AddMemberOutput` · `removeMember(member, identity) -> bytes(commit)` · `encrypt(member, plaintext) -> bytes` · `decrypt(member, message) -> bytes?` · `callKeys(member) -> SrtpKeys` · `memberCount()`
- NOTE: group encrypt/decrypt take `member` as the FIRST arg.

## Records
- `PublicBundle { identityKey: String, signingKey: String, oneTimeKeys: [String] }`
- `WireMessage { msgType: UInt64/ULong, body: String }`
- `AcceptedSession { session: Session, plaintext: bytes }`
- `AddMemberOutput { commit, welcome, ratchetTree: bytes }`
- `MediaKey { key, nonce, ciphertextSha256: String }` · `EncryptedMedia { ciphertext: bytes, mediaKey: MediaKey }`
- `SrtpKeys { masterKey, masterSalt: bytes }` · `CallSecret { secret: String }`

## Free functions
- `safetyNumber(ourId: bytes, ourFingerprint: String, theirId: bytes, theirFingerprint: String) -> String`
- `encryptMedia(plaintext: bytes) -> EncryptedMedia` · `decryptMedia(mediaKey, ciphertext: bytes) -> bytes`
- `newCallSecret() -> CallSecret` · `srtpKeysFor1to1(callSecret) -> SrtpKeys`

## Backend mapping (how this lines up with the API)
- `bundle.identityKey` → `devices.identity_public_key` (POST /devices/register). Round-trips via base64.
- `bundle.oneTimeKeys[]` → `one_time_prekeys` (POST /prekeys/upload), each as `{key_id: index, public_key}`.
- `bundle.signingKey` → peer fingerprint for `safetyNumber` (stored for verification; not needed for startSession).
- To start a chat: GET peer bundle → `startSession(theirIdentityKey = identity_public_key, theirOneTimeKey = one_time_prekey.public_key)`.
- e2e-core has NO signed-prekey-with-signature, so `/prekeys/upload` signed_prekey is OPTIONAL.
