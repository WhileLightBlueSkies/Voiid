//
//  CallKeyExchange.swift
//  Voiid
//
//  CALL KEYS, NOT CONVERSATION KEYS.  (repair plan §3.3 and §3.8)
//
//  The single load-bearing rule of conference escalation: the person you add to a live 1:1
//  call must receive a key scoped to THAT CALL, never a key derived from a conversation.
//  Today the only multi-party room in the app is keyed off a group's MLS exporter secret
//  (`GroupEngine.callKeyPassphrase`), which is exactly why escalating by creating a group
//  conversation is forbidden — it would hand a stranger a persistent messaging surface with
//  both participants. A per-call secret grants decryption of this call's media and nothing
//  else. It dies with the call.
//
//  MECHANISM
//    1. The inviter mints `newCallSecret()` — 32 random bytes from e2e-core, shipped on the
//       uniffi surface of both platforms and, until now, called by nothing.
//    2. It is distributed PAIRWISE over the existing Double Ratchet, one ciphertext per
//       recipient DEVICE, riding the opaque `call_key` WS frame. Not the durable message
//       path: a call key is not a message and must leave no chat artifact.
//    3. Everyone derives the media key identically — `srtpKeysFor1to1(secret)` →
//       base64(masterKey ‖ masterSalt) — which is byte-for-byte the format group calls
//       already feed LiveKit's shared-key provider, so the existing rotation path applies it.
//    4. REKEY ON EVERY JOIN AND LEAVE. A joiner gets no access to media sent before they
//       arrived, and a leaver none after they go. That is the property MLS epochs give group
//       calls, reproduced per-call.
//
//  STRUCTURAL RULE, restated here because this file is where it would be easiest to break:
//  NOTHING in the call path may write conversations or conversation_members. Establishing a
//  ratchet session with a stranger's device — which step 2 does — is deliberately fine and
//  creates no conversation row; 020_reachability.sql says as much in its own comments. After
//  the call, reaching that person still requires the 6-digit contact-PIN gate. A SHARED CALL
//  GRANTS NO MESSAGING RIGHTS.
//
//  §3.8 — VERIFIED KEYING FOR PLAIN 1:1 CALLS
//  1:1 media is DTLS-SRTP, and the fingerprints binding that handshake to the peer ride a
//  server-relayed SDP, so a colluding server can MITM (the header of CallService.swift has
//  admitted this since the file was written). DTLS-SRTP alone is therefore transport
//  encryption whose endpoint binding rests on the relay's honesty.
//
//  THE FIX (frame-level E2EE): the vendored WebRTC was replaced with LiveKit's fork, which
//  exposes RTCFrameCryptor — AES-GCM encryption of EVERY RTP payload, applied after the
//  encoder and removed after the decoder, on our OWN RTCPeerConnection. Both sides derive
//  an identical 32-byte media key from the ratchet-delivered call secret (HKDF-SHA256,
//  label below) and feed it to a shared-key provider. A signaling-colluding MITM can now
//  insert itself into DTLS and receive only ciphertext it cannot open, because the frame
//  key never transits anything but the Double Ratchet.
//
//  FAIL-CLOSED: cryptors are created with discardFrameWhenCryptorNotReady = true — until
//  BOTH sides hold the key, frames are DROPPED, never sent in the clear. The worst case
//  is silence, not plaintext.
//
//  The commitment tag (below) stays: it proves the two sides agree on the same secret AND
//  the same DTLS fingerprint pair, which turns "encrypted" into "encrypted WITH THE PEER I
//  VERIFIED" — the property that makes the UI badge meaningful.

import Combine
import CryptoKit
import Foundation
import LiveKitWebRTC

/// How much we know about the media keying of a call, for the UI and for logs.
enum CallKeyVerification: Equatable {
    /// No `call_key` seen — an older peer. The call is DTLS-SRTP protected, as before.
    case unverified
    /// We hold a call secret but the peer's commitment tag hasn't arrived yet.
    case pending
    /// Both sides committed to the same secret AND the same DTLS fingerprint pair.
    case verified
    /// The tags disagree. Either a fingerprint was substituted in transit, or the two
    /// sides are simply on different secrets. Shown to the user; never fatal on its own.
    case mismatch
}

@MainActor
final class CallKeyExchange: ObservableObject {
    static let shared = CallKeyExchange()

    // MARK: - Wire envelope
    //
    // Rides INSIDE the ratchet ciphertext, so the relay sees base64 and nothing else.
    // Every field is optional on the way in: this envelope is new, will gain fields, and a
    // Swift `Codable` throws `keyNotFound` on an absent key — the bug class that has bitten
    // this repo before. A malformed envelope is dropped, never guessed at.
    private struct Envelope: Codable {
        /// Envelope version. 1 = this shape.
        var v: Int?
        /// "secret" (here is the call key) or "verify" (here is my commitment tag).
        var k: String?
        var call_id: String?
        /// base64, as produced by `newCallSecret()`. Present only on kind "secret".
        var secret: String?
        /// Monotonic per-call generation, so a late-delivered older key can never
        /// overwrite a newer one.
        var gen: Int?
        /// base64 SHA-256 commitment. Present only on kind "verify".
        var tag: String?
        var scope: String?
    }

    // MARK: - State

    /// call_id -> the secret currently keying that call's media.
    private var secrets: [String: CallSecret] = [:]
    private var roomSecrets: [String: CallSecret] = [:]
    private var roomGenerations: [String: Int] = [:]
    private var roomMinters: [String: String] = [:]
    private var roomKeyPeers: [String: Set<String>] = [:]
    func peerSupportsRoomKeys(callId: String, userId: String) -> Bool {
        roomKeyPeers[callId]?.contains(userId) == true
    }
    /// call_id -> generation of the held secret. Higher wins.
    private var generations: [String: Int] = [:]
    /// call_id -> user id of whoever minted the held secret. Tie-breaks equal generations
    /// deterministically (lowest id wins), so two peers that rekey at the same instant
    /// converge instead of ping-ponging.
    private var minters: [String: String] = [:]
    /// call_id -> our own commitment tag, retained so a peer's tag can arrive first.
    private var localTags: [String: String] = [:]
    /// call_id -> the peer tag we received before we could compute ours.
    private var remoteTags: [String: String] = [:]
    private var remoteTagGenerations: [String: Int] = [:]
    private var verificationTasks: [String: Task<Void, Never>] = [:]

    /// Verified-keying state per call (§3.8). Published so the call screen can show it.
    @Published private(set) var verification: [String: CallKeyVerification] = [:]

    // MARK: Frame-level E2EE state

    /// call_id -> the shared-key provider feeding our frame cryptors. Created lazily on
    /// first request; when a NEW generation installs, `setSharedKey` re-keys every cryptor
    /// holding this provider — LiveKit's ratchet handles the transition.
    private var frameProviders: [String: LKRTCFrameCryptorKeyProvider] = [:]
    /// call_id -> generation the provider was last keyed with, so an out-of-order
    /// install cannot roll the key backwards.
    private var providerGeneration: [String: Int] = [:]

    /// HKDF label. Domain-separated from everything else e2e-core derives; changing it
    /// invalidates all in-flight calls' keys on BOTH ends simultaneously, so treat it as
    /// protocol constant, not a setting.
    private static let frameKeySalt = Data("VoiidFrameKey v1".utf8)

    /// The 32-byte media key both sides derive from the call secret. Deterministic and
    /// symmetric: same secret in, same key out, on both devices.
    private func frameMediaKey(_ secret: CallSecret) -> SymmetricKey? {
        // e2e-core uses vodozemac's STANDARD_NO_PAD encoding. Foundation requires
        // padding; deriving from the encoded text on failure creates a different
        // audio key from Android even when the Rust SRTP commitment verifies.
        let encoded = secret.secret
        let padded = encoded + String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
        guard let ikm = Data(base64Encoded: padded), ikm.count == 32 else { return nil }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Self.frameKeySalt,
            info: Data(),
            outputByteCount: 32
        )
    }

    /// The shared-key provider for `callId`, creating it (keyed to the CURRENT secret)
    /// if needed. CallService hands this to its RTCFrameCryptors. Returns nil only when
    /// we hold no secret yet — the caller retries once `secretRotated` fires.
    func frameKeyProvider(callId: String) -> LKRTCFrameCryptorKeyProvider? {
        guard let secret = secrets[callId], let mediaKey = frameMediaKey(secret) else { return nil }
        if let existing = frameProviders[callId] { return existing }
        let provider = LKRTCFrameCryptorKeyProvider(
            ratchetSalt: Self.frameKeySalt,
            ratchetWindowSize: 0,
            sharedKeyMode: true,
            uncryptedMagicBytes: nil,
            failureTolerance: -1,
            keyRingSize: 16,
            discardFrameWhenCryptorNotReady: true
        )
        let key = mediaKey.withUnsafeBytes { Data($0) }
        provider.setSharedKey(key, with: 0)
        frameProviders[callId] = provider
        providerGeneration[callId] = generations[callId]
        NSLog("[VOIID] call-key: frame key provider ready for \(callId)")
        return provider
    }

    /// Fires with a call_id whenever that call's media key CHANGED. GroupCallService
    /// subscribes and re-applies it to LiveKit's key provider, debounced exactly like the
    /// MLS epoch rekey — rapid join/leave must settle to one key roll, not thrash the
    /// provider.
    let secretRotated = PassthroughSubject<String, Never>()

    private init() {}

    // MARK: - Reads

    /// The media passphrase for a call, or nil when we hold no secret.
    ///
    /// Format is deliberately identical to `GroupEngine.callKeyPassphrase`: LiveKit's
    /// `BaseKeyProvider` takes a `String` and force-unwraps `.data(using: .utf8)`, so raw
    /// key bytes cannot be handed over — they are not valid UTF-8 and it would crash.
    func passphrase(callId: String) -> String? {
        guard let secret = roomSecrets[callId] else { return nil }
        guard let keys = try? srtpKeysFor1to1(callSecret: secret) else {
            NSLog("[VOIID] call-key: srtpKeysFor1to1 failed for \(callId)")
            return nil
        }
        return (keys.masterKey + keys.masterSalt).base64EncodedString()
    }

    /// True once we hold a key for this call. Callers MUST NOT join a conference room
    /// without one — both group clients already refuse, and an ad-hoc room must too.
    func hasKey(callId: String) -> Bool { roomSecrets[callId] != nil }

    func verificationState(callId: String) -> CallKeyVerification {
        verification[callId] ?? .unverified
    }

    // MARK: - Minting + distribution (§3.3 steps 1–2)

    /// Mint a fresh secret for `callId` and fan it out pairwise to `userIds`.
    ///
    /// Called by the INVITER on escalation and on every subsequent join/leave. The fallback
    /// rule when the inviter is gone (lowest remaining user id mints) lives in
    /// `CallConferenceService`, which is the only place that knows the roster.
    ///
    /// Best-effort per recipient: a device with no free one-time prekey is skipped rather
    /// than failing the whole rekey, because the alternative is nobody getting the new key.
    /// The next membership change re-fans it.
    @discardableResult
    func mintAndDistribute(callId: String, to userIds: [String], scope: String = "room") async -> String? {
        let secret = newCallSecret()
        let generation = ((scope == "room" ? roomGenerations[callId] : generations[callId]) ?? 0) + 1
        let me = TokenStore.shared.userId ?? ""
        install(secret: secret, callId: callId, generation: generation, minter: me, scope: scope)
        await distribute(secret, callId: callId, generation: generation, to: userIds, scope: scope)
        return passphrase(callId: callId)
    }

    /// Re-send the secret we already hold (no new generation). Used when a participant
    /// reports they never got it — a rekey would invalidate everyone else's key to fix one
    /// person, which is the wrong trade.
    func redistribute(callId: String, to userIds: [String]) async {
        guard let secret = secrets[callId] else { return }
        await distribute(secret, callId: callId,
                         generation: generations[callId] ?? 1, to: userIds, scope: "p2p")
    }

    func redistributeRoom(callId: String, to userId: String) async {
        guard let secret = roomSecrets[callId] else { return }
        await distribute(secret, callId: callId, generation: roomGenerations[callId] ?? 1,
                         to: [userId], scope: "room")
    }

    private func distribute(_ secret: CallSecret, callId: String,
                            generation: Int, to userIds: [String], scope: String) async {
        let envelope = Envelope(v: 1, k: "secret", call_id: callId,
                                secret: secret.secret, gen: generation, tag: nil, scope: scope)
        guard let body = try? JSONEncoder().encode(envelope) else { return }
        let myDevice = E2EManager.shared.deviceId
        let me = TokenStore.shared.userId

        var seen = Set<String>()
        for userId in userIds where !userId.isEmpty && seen.insert(userId).inserted {
            do {
                // Our OWN other devices are folded into the first recipient's fan-out so a
                // linked device that answers this call can decrypt the media too. They are
                // included exactly once (`includeOwnDevices` only on the first pass).
                let includeOwn = (userId != me) && (seen.count == 1)
                let parts = try await ChatEngine.shared.encryptCallKeyEnvelope(
                    body, toUserId: userId, includeOwnDevices: includeOwn)
                guard !parts.isEmpty else {
                    NSLog("[VOIID] call-key: no deliverable device for \(userId) on \(callId)")
                    continue
                }
                var byDevice: [String: String] = [:]
                for p in parts { byDevice[p.deviceId] = p.ciphertext }
                WebSocketClient.shared.sendCallKey(toUserId: userId, callId: callId,
                                                   senderDeviceId: myDevice, ciphertexts: byDevice)
            } catch {
                // NEVER logs the envelope, the secret, or the ciphertext.
                NSLog("[VOIID] call-key: fan-out to \(userId) failed for \(callId): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Inbound (§3.3 step 3)

    /// Handle an inbound `call_key` frame. Picks THIS device's ciphertext out of the bundle,
    /// opens it over the ratchet, and installs the secret if it supersedes what we hold.
    func handleInboundCallKey(fromUserId: String, callId: String, senderDeviceId: String?,
                              ciphertexts: [String: String]) async {
        guard let myDevice = E2EManager.shared.deviceId else { return }
        // Not addressed to this device. Not an error: a fan-out names every device of every
        // recipient and the relay may hand us the whole bundle.
        guard let mine = ciphertexts[myDevice] else { return }
        guard let plaintext = await ChatEngine.shared.decryptCallKeyEnvelope(
                ciphertextB64: mine, fromUserId: fromUserId, senderDeviceId: senderDeviceId) else {
            NSLog("[VOIID] call-key: could not open envelope from \(fromUserId) for \(callId)")
            return
        }
        // TWO SHAPES ON THE WIRE, BOTH ACCEPTED (cross-platform 1:1 calls):
        //   iOS:    {v, k:"secret"|"verify", call_id, secret?, gen?, tag?}
        //   Android:{t:"voiid:call_key", call_id, epoch, secret}
        // A decoder that only knew its own dialect made iOS↔Android key delivery
        // impossible. `gen` and `epoch` are the same monotonic generation.
        var env: Envelope
        if let ios = try? JSONDecoder().decode(Envelope.self, from: plaintext), ios.k != nil {
            env = ios
        } else if let obj = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
                  obj["t"] as? String == "voiid:call_key",
                  let secret = obj["secret"] as? String {
            env = Envelope(v: 1, k: "secret", call_id: (obj["call_id"] as? String),
                           secret: secret,
                           gen: (obj["epoch"] as? Int) ?? 1,
                           tag: nil, scope: obj["scope"] as? String)
        } else {
            NSLog("[VOIID] call-key: malformed envelope from \(fromUserId) for \(callId)")
            return
        }
        // A frame's call_id and the envelope's must agree. They are carried in two different
        // trust domains — the outer one is relay-visible and relay-writable, the inner one is
        // sealed — so a disagreement means the relay retargeted the frame. Drop it.
        if let inner = env.call_id, !inner.isEmpty, inner != callId {
            NSLog("[VOIID] call-key: envelope call_id mismatch — dropping")
            return
        }

        if env.scope == "p2p" { roomKeyPeers[callId, default: []].insert(fromUserId) }
        switch env.k {
        case "secret":
            guard let raw = env.secret, !raw.isEmpty else { return }
            let generation = env.gen ?? 1
            let scope = env.scope ?? "p2p"
            guard scope == "p2p" || scope == "room" else { return }
            if scope == "room" {
                install(secret: CallSecret(secret: raw), callId: callId,
                        generation: generation, minter: fromUserId, scope: scope)
                return
            }
            guard supersedes(callId: callId, generation: generation, minter: fromUserId) else {
                NSLog("[VOIID] call-key: ignoring superseded key gen=\(generation) for \(callId)")
                return
            }
            install(secret: CallSecret(secret: raw), callId: callId,
                    generation: generation, minter: fromUserId)
        case "verify":
            guard let tag = env.tag, Data(base64Encoded: tag)?.count == 32,
                  let generation = env.gen, generation > 0,
                  secrets[callId] == nil || generations[callId] == generation else { return }
            remoteTagGenerations[callId] = generation
            remoteTags[callId] = tag
            evaluateVerification(callId: callId)
        default:
            // Unknown kind from a newer client — ignore, don't fail the call.
            break
        }
    }

    /// Generation ordering. Higher generation always wins; an equal generation is broken by
    /// the LOWEST minter user id, so two peers that mint simultaneously converge on the same
    /// answer without another round trip.
    private func supersedes(callId: String, generation: Int, minter: String) -> Bool {
        let held = generations[callId] ?? 0
        if generation > held { return true }
        if generation < held { return false }
        guard let heldMinter = minters[callId] else { return true }
        return minter < heldMinter
    }

    private func install(secret: CallSecret, callId: String, generation: Int, minter: String, scope: String = "p2p") {
        // A room shares the call ID with the P2P leg, but never its encryption state.
        if scope == "room" {
            guard frameMediaKey(secret) != nil, generation > 0 else { return }
            let held = roomGenerations[callId] ?? 0
            guard generation > held || (generation == held && minter < (roomMinters[callId] ?? "~")) else { return }
            roomSecrets[callId] = secret
            roomGenerations[callId] = generation
            roomMinters[callId] = minter
            secretRotated.send(callId)
            return
        }
        guard let mediaKey = frameMediaKey(secret) else {
            NSLog("[VOIID] call-key: invalid media secret rejected")
            return
        }
        let previous = secrets[callId]?.secret
        secrets[callId] = secret
        generations[callId] = generation
        minters[callId] = minter
        // Keep a same-generation commitment that arrived before its secret.
        verificationTasks[callId]?.cancel(); verificationTasks[callId] = nil
        localTags[callId] = nil
        if remoteTagGenerations[callId] != generation {
            remoteTags[callId] = nil; remoteTagGenerations[callId] = nil
        }
        if verification[callId] != nil { verification[callId] = .pending }
        // Only P2P keys reach this provider. Room rotations must never interrupt it.
        if let provider = frameProviders[callId],
           providerGeneration[callId] != generation {
            let key = mediaKey.withUnsafeBytes { Data($0) }
            provider.setSharedKey(key, with: 0)
            providerGeneration[callId] = generation
        }
        guard previous != secret.secret else { return }
        NSLog("[VOIID] call-key: installed gen=\(generation) for \(callId)")
        secretRotated.send(callId)
    }

    /// Forget everything about a call. Called on teardown — a call secret outliving its call
    /// is pure liability, and this class is the only place it exists on this device.
    func clear(callId: String) {
        roomKeyPeers[callId] = nil
        roomSecrets[callId] = nil; roomGenerations[callId] = nil; roomMinters[callId] = nil
        secrets[callId] = nil
        generations[callId] = nil
        minters[callId] = nil
        localTags[callId] = nil
        remoteTags[callId] = nil
        remoteTagGenerations[callId] = nil
        verificationTasks[callId]?.cancel(); verificationTasks[callId] = nil
        verification[callId] = nil
        frameProviders[callId] = nil
        providerGeneration[callId] = nil
    }

    /// Drop every call secret. Sign-out only.
    func wipe() {
        roomKeyPeers.removeAll()
        roomSecrets.removeAll(); roomGenerations.removeAll(); roomMinters.removeAll()
        secrets.removeAll()
        generations.removeAll()
        minters.removeAll()
        localTags.removeAll()
        remoteTags.removeAll()
        remoteTagGenerations.removeAll()
        for task in verificationTasks.values { task.cancel() }
        verificationTasks.removeAll()
        verification.removeAll()
        frameProviders.removeAll()
        providerGeneration.removeAll()
    }

    // MARK: - Verified keying for 1:1 (§3.8)

    /// Mint a secret for a plain 1:1 call and send it to the peer. Called by the CALLER
    /// alongside the offer. Failure is silent and total: the call proceeds unverified.
    func beginOneToOne(callId: String, peerUserId: String) async {
        guard !peerUserId.isEmpty else { return }
        verification[callId] = .pending
        await mintAndDistribute(callId: callId, to: [peerUserId], scope: "p2p")
    }

    /// Compute and send this side's commitment once BOTH DTLS fingerprints are known.
    ///
    /// The tag binds three things at once: the ratchet-delivered secret (which the relay
    /// cannot read), our fingerprint, and the peer's. Fingerprints are sorted so both sides
    /// hash the same input without needing to agree on who is "first".
    ///
    /// Idempotent — the answer/renegotiation paths both call it and only the first does work.
    func sendVerificationTag(callId: String, peerUserId: String,
                             localSDP: String?, remoteSDP: String?) {
        guard !peerUserId.isEmpty, localTags[callId] == nil else { return }
        guard let secret = secrets[callId] else { return }   // legacy peer / no key: nothing to commit
        guard let localSDP, let remoteSDP,
              let localFP = CallSDPTuning.dtlsFingerprint(in: localSDP),
              let remoteFP = CallSDPTuning.dtlsFingerprint(in: remoteSDP) else { return }
        guard let tag = commitmentTag(secret: secret, fingerprints: [localFP, remoteFP]) else { return }
        localTags[callId] = tag
        evaluateVerification(callId: callId)

        let envelope = Envelope(v: 1, k: "verify", call_id: callId,
                                secret: nil, gen: generations[callId], tag: tag, scope: "p2p")
        guard let body = try? JSONEncoder().encode(envelope) else { return }
        let myDevice = E2EManager.shared.deviceId
        let generation = generations[callId]
        verificationTasks[callId]?.cancel()
        verificationTasks[callId] = Task { [weak self] in
            guard let self else { return }
            // Fresh ratchet ciphertext on each attempt; never replay an Olm packet.
            for attempt in 0..<3 {
                if attempt > 0 {
                    do { try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000) }
                    catch { return }
                }
                guard !Task.isCancelled, self.generations[callId] == generation,
                      self.secrets[callId]?.secret == secret.secret else { return }
                do {
                    let parts = try await ChatEngine.shared.encryptCallKeyEnvelope(body, toUserId: peerUserId)
                    guard !Task.isCancelled, self.generations[callId] == generation,
                          self.secrets[callId]?.secret == secret.secret else { return }
                    var byDevice: [String: String] = [:]
                    for p in parts { byDevice[p.deviceId] = p.ciphertext }
                    WebSocketClient.shared.sendCallKey(toUserId: peerUserId, callId: callId,
                                                       senderDeviceId: myDevice, ciphertexts: byDevice)
                } catch {
                    NSLog("[VOIID] call-key: verification delivery failed")
                }
            }
        }
    }

    /// SHA-256 over the derived SRTP keys and the SORTED fingerprint pair. Sorting is what
    /// makes the commitment symmetric: caller and callee hash byte-identical input.
    private func commitmentTag(secret: CallSecret, fingerprints: [String]) -> String? {
        guard let keys = try? srtpKeysFor1to1(callSecret: secret) else { return nil }
        var input = Data()
        input.append(keys.masterKey)
        input.append(keys.masterSalt)
        for fp in fingerprints.sorted() {
            input.append(Data("\u{1F}\(fp)".utf8))   // unambiguous separator, never in a fingerprint
        }
        return Data(SHA256.hash(data: input)).base64EncodedString()
    }

    /// Settle the verification state once both tags exist. Constant-time comparison is
    /// unnecessary here (both values are public commitments, not secrets) but the outcome
    /// is deliberately loud: a mismatch is the one signal a MITM cannot suppress.
    private func evaluateVerification(callId: String) {
        guard let local = localTags[callId], let remote = remoteTags[callId] else {
            if secrets[callId] != nil, verification[callId] == nil {
                verification[callId] = .pending
            }
            return
        }
        if local == remote {
            verification[callId] = .verified
            NSLog("[VOIID] call-key: media keying VERIFIED for \(callId)")
        } else {
            verification[callId] = .mismatch
            // Deliberately not a teardown. Ending the call on mismatch would let anyone able
            // to corrupt one frame end every call; surfacing it lets the user decide.
            NSLog("[VOIID] ⚠️ call-key: commitment MISMATCH for \(callId) — DTLS fingerprints may have been substituted")
        }
    }
}
