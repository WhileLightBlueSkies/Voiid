# VOIID E2EE Security Audit

**Date:** August 2026 · **Scope:** every encryption surface in the product · **Method:** full source trace, client → relay → recipient, with file:line evidence for every claim.

**Surfaces covered:** 1:1 messages · group chat (MLS) · voice/video calls · documents/photos/videos · stories/moments · recovery & backup · server relay and storage · account/device lifecycle.

> **Honest framing.** This is an internal code audit, not an independent cryptographic review. It verifies the implementation against its stated threat model (hostile relay in scope; compromised endpoint out of scope). "100% secure" is not a thing anyone can certify — what this document gives you is every place the current code can leak, break, or be abused, ranked, with the exact lines that prove it.

---

## 1. Verdict by surface

| Surface | Content confidential vs hostile server? | Status |
| --- | --- | --- |
| 1:1 messages | **Yes** — Double Ratchet, keys never leave devices | Solid core; two HIGH client-side trust/lifecycle bugs (§3) |
| Group chat | **Yes** — MLS (RFC 9420) + X-Wing PQ | Sound crypto; CRITICAAL-grade server-side KeyPackage planting hole (§2.1) |
| Group calls | **Yes** — frame-level E2EE keyed from MLS exporter, SFU never sees keys | Sound; epoch-partition caveat (§5) |
| 1:1 calls | **NO** — DTLS-SRTP only; fingerprints ride the relayed SDP | The one surface where "E2EE" overstates reality (§6.1) |
| Documents/photos/videos (chat media) | **Yes** — AES-256-GCM envelope, key rides the ratchet | Sound except MIME leak + profile photos in plaintext (§7) |
| Stories/moments | **Yes** — per-device ratchet envelopes | Sound; spam vector (§9) |
| Recovery/backup | PIN-wrapped, offline-crackable at 4-digit floor | Weakest link for at-rest content (§8) |
| Server/storage | Ciphertext-only persistence verified column-by-column | Multiple API authz holes leak *metadata* + ciphertext corpus (§2) |

---

## 2. CRITICAL & HIGH — fix before any public launch

### 2.1 CRITICAL · MLS KeyPackage planting → attacker joins groups as the victim
`POST /mls/keypackages` takes `device_id` from the request body and inserts `(auth_user_id, body_device_id, kp)` with **no ownership check** — `backend/api/src/routes/mls.ts:36-63`. The identical bug class was found and fixed in `prekeys.ts:27-54` (`ownsDevice()`); MLS never got the fix. Consumption selects purely by target device (`mls.ts:75-92`), and device ids are public via `GET /devices/:user_id`.

**Attack:** attacker mints their own MLS KeyPackage, publishes it against a *victim's* device id, drains the legit packages (trivially, §2.4), and the next person to add the victim seals the HPKE Welcome — group keys plus ratchet tree — **to the attacker**, who then holds full read/write access under the victim's displayed identity.
**Fix:** port `ownsDevice()` to this route; add `kp.user_id = d.user_id` binding to the consumption query; verify the KeyPackage credential identity equals the roster entry being added (`GroupEngine.swift:645-650` currently checks nothing).

### 2.2 HIGH · Any user can read any conversation's timeline
`GET /messages/conversation/:id` filters only on `m.conversation_id = $1` — there is **no membership check** (`backend/api/src/routes/messages.ts:387-452`). Conversation ids travel (group rosters, links). Result: sender ids, timestamps, content types, R2 media references, receipt aggregates, and all legacy-path ciphertext for conversations you were never in.
**Fix:** apply `isConversationMember` exactly as `POST /send` already does (`messages.ts:112-120`).

### 2.3 HIGH · Pending-message harvest across users
`GET /messages/pending/:user_id` never compares the path parameter to the JWT identity (`messages.ts:457-496`; the legacy branch binds `cm.user_id = req.params.user_id` directly, and nothing marks legacy rows delivered, so it is repeatable forever).
**Fix:** reject unless `req.params.user_id === req.auth.user_id`, and require `device_id` (if supplied as query) to belong to that same user.

### 2.4 HIGH · Prekey / KeyPackage exhaustion by strangers
`GET /prekeys/:user_id` and `GET /mls/keypackages/:user_id` consume one one-time prekey/KeyPackage per call with **no relationship check** between caller and target (`prekeys.ts:135-203`, `mls.ts:73-126`). A looped attacker keeps victims permanently unable to receive new-session 1:1 mail or group invites (senders degrade to the fallback key; MLS joins fail outright).
**Fix:** gate fetching on block-list pass + shared-conversation OR mutual-contact OR valid PIN proof, mirroring Signal's authenticated prekey policy; add per-(caller,target) rate limits.

### 2.5 HIGH · New-device trust is silent TOFU (future-only MITM window)
First sighting of a peer identity key pins it automatically with zero user surface — `verifyAndPinIdentity`, `apps/ios/Voiid/Voiid/Networking/ChatEngine.swift:1248-1257`. A hostile relay that fabricates an extra device in `GET /devices/:victim` gets pinned silently, yielding a future-only MITM that no UI ever surfaces ("new device added" events do not exist; safety numbers exist but verification is manual and compares only current pins).
**Fix:** notify-and-confirm on first sighting of any (peer, device); make a changed pin fatal-loud; add a group fingerprint equivalent.

### 2.6 HIGH · Fallback-key lifecycle loses messages with no adversary required
Two compounding client defects:
1. `restore_fallback_key` is never called after restoring the identity pickle (binding exists, zero call sites — `voiid.swift:1135,1318`), so after every restart the bundle regenerates a fresh fallback key locally while the server keeps serving the older one whose private half vodozemac has since dropped. Senders' prekey messages then fail session creation forever (`ChatEngine.swift:806-811` tombstones them).
2. Every failed upload retry calls `rotate_fallback_key()` again, burning retention slots (`E2EManager.swift:404-460`, `keys.rs:128-151`).

**Fix:** restore the fallback key from the persisted pickle on launch; make rotation idempotent until upload succeeds; test explicitly with an app-restart + blocked-upload sequence.

### 2.7 HIGH (config-dependent) · Auth dev bypass ships in the loaded env
Root `.env` sets `NODE_ENV=development` and `AUTH_DEV_BYPASS=1`; `backend/api/src/firebase.ts:85-93` then accepts `"dev:<any phone>"` as a valid token and mints a 30-day JWT for any account. One misconfigured deploy = total impersonation.
**Fix:** remove both values from deploy artifacts; add a startup assertion refusing `AUTH_DEV_BYPASS=1` outside local dev.

### 2.8 HIGH · Profile photos stored and served unencrypted
`uploadProfilePhoto` PUTs raw JPEG (`MediaService.swift:53-69`), and `POST /media/presign-download` signs any `media/…` key for any authenticated user (`media.ts:41-53`). The fix already exists unused in core (`generate_profile_key`, `media.rs:66-90`) — `ProfileKeyStore` still carries a stale "bindings missing" blocker.
**Fix:** ship profile-photo encryption; entitlement-check downloads like stories already do (`stories.ts:212-255`).

---

## 3. MEDIUM

| # | Finding | Evidence | Fix direction |
| --- | --- | --- | --- |
| M1 | Receipt forging + offline-redelivery suppression: `POST /receipts/mark` accepts arbitrary message ids, flips `is_pending=false` on rows the caller isn't party to | `receipts.ts:31-88` | membership check + scoped update |
| M2 | `GET /receipts/:message_id` leaks who read/delivered anything to anyone | `receipts.ts:91-98` | party check |
| M3 | MLS `max_past_epochs = 0` + server marks deliveries on fetch ⇒ one missed Commit permanently desyncs a device's group decryptability; concurrent-commit reconciliation exists in core but is never called | `group.rs:222-228`, `mls.ts:270-278`, `GroupEngine.swift:38-45` | retain ≥2 past epochs; mark delivered only after client ack; wire `clear_pending` |
| M4 | Ex-member residual read if any remaining member misses the removal Commit (enabled by M3) | `GroupEngine.swift:699-710` | follows M3 |
| M5 | 1:1-call SRTP commitment tag is optional; peers without it complete calls unverified | `CallKeyExchange.swift:46-66,360-376` | make mismatch fatal or banner-loud |
| M6 | Real MIME type of chat media stored server-side (stories correctly send wrapper-only) | `ChatEngine.swift:439`, `MediaService.swift:43`, `messages.ts:216-220` | adopt the stories pattern |
| M7 | No size cap on presigned media uploads (backup caps at 50 MiB; chat/stories unlimited) | `r2.ts:49-53` | sign content-length ranges |
| M8 | WS hardening: 100 MiB default frame cap, JWT in `?token=` query (proxy logs), `typing`/`session_reset` fan-out uncapped, `loc_update` rate limit bypassed by rotating share_id | `websocket/src/index.ts:280,283-285,119-123,350-380,725-733` | explicit maxPayload, subtitle-only token, per-connection budgets |
| M9 | Recovery PIN offline brute-force: 4-digit floor × Argon2id minimum params × lockout enforced only by client self-reporting | `BackupComponents.swift:14-19`, `recovery.rs:49-58`, `recovery.ts:74-112` | ≥6-digit floor, common-PIN rejection, server-side guessing cost (OPAQUE/SVR-style) |
| M10 | 30-day JWTs, logout is client-side only, no per-device token revocation | `auth.ts:8,71-93`, `routes/auth.ts:72-73` | short tokens + refresh, device-scoped revocation |

## 4. LOW / INFO (selected)

- Signed prekey is not actually signed — bundle authenticity rests on TLS + TOFU pin (`E2EManager.swift:330-337`, `SECURITY.md:109-113` discloses honestly).
- 64-bit truncated MAC (Olm V1 sessions) halves forgery margin; disclosed in SECURITY.md §6, accurate (`session.rs:74,97`).
- `cargo audit` CI workflow named in SECURITY.md does not exist; nine pinned advisories including two libcrux side-channel RUSTSECs are unmonitored.
- `SecRandomCopyBytes` return ignored when minting pickle keys — failure would persist an all-zero key (`E2EManager.swift:260`, `ChatEngine.swift:1500`).
- Corrupt identity pickle silently recreates identity (`E2EManager.swift:205-211`).
- SDP/ICE (host IPs) buffered server-side ≤60s; standard WebRTC trade-off, TURN mitigates (`websocket/src/index.ts:633-658`).
- Linking poll hands a full JWT to whoever presents the QR token within its 5-minute TTL (`linking.ts:77-86`).
- Story fan-out skips block/reachability gates at delivery time (`stories.ts:136-187`) — unsolicited-content vector.
- Backup blob lacks version/user AAD binding — stale-backup rollback possible with R2 write access (`backup.ts:47-61`).
- Sanctioned non-E2EE stores (documented, not leaks): clips/captions/profiles, games moves, communities metadata, contact-sync graph, IPs/push tokens, and `content_reports.evidence` — the single legitimate plaintext message store, gated by a disclosure constraint (`035_reports.sql:123-133`).

---

## 5. Verified sound (evidence-backed)

**Content confidentiality holds against a hostile relay on every modeled surface:**

1. **No plaintext message column anywhere** — `006_messages.sql:12` (`ciphertext bytea`, "no plaintext column exists, by design"), `013_message_ciphertexts.sql` per-device blobs only. A full DB dump yields ciphertext + the complete social/metadata graph, **never** message content or location coordinates (locations are never persisted at all — `018_location_shares.sql` header enumerates the absences; fixes ride WS as opaque base64, overwrite-only, deleted on stop).
2. **Core crypto discipline** — every GCM nonce freshly random (`media.rs:97-98`, `recovery.rs:140-144,242-243`); CSPRNG throughout; pickles AES-encrypted, wrong-key fails closed (`session.rs:134-145`); replay rejected (`tests/hardening.rs:53-69`); hostile ciphertext cannot panic the decrypt path (fuzz targets + `tests/robustness.rs`); PQ 1:1 handshake compile-gated inert (`pqxdh.rs:132-146`).
3. **MLS composition** — HPKE-sealed Welcomes the server cannot open; tree-hash mismatch fails join; signature validation before add; SKIP LOCKED prevents double-consumption; removal rekeys before roster delete (`group.rs:208-344`, `mls.ts:75-92`).
4. **Group calls** — keys derived from the MLS exporter on-device, re-applied each epoch; SFU/API never see key material; join fails closed without a derivable key (`group.rs:423-439`, `GroupCallService.swift:178-196`).
5. **Media envelopes** — SHA-256 verified before AEAD decrypt; key+nonce+hash travel only inside ratchet envelopes; no thumbnail bytes ever uploaded anywhere (`media.rs:93-149`, `Main/Stories/StoryMedia.swift:109`).
6. **Relay hygiene** — sender identity always stamped from the connect-time JWT; outbound frames rebuilt from fixed field lists so smuggled fields are never stored or echoed; push payloads provably content-free (tested builders); no message ciphertext ever touches Redis; no console/error sink captures bodies (`websocket/src/index.ts:427-443`, `pushPayload.ts`, backend-wide scan).
7. **Recovery crypto composition** — BIP39 24-word checksummed phrase never stored server-side; Argon2id wrap fails closed on wrong PIN; backup blob HKDF-domain-separated (`recovery.rs:41-282`).

---

## 6. Answers to the question you asked

*"We have proper E2EE for 1:1, group chat, calls, documents, photos and videos — right?"*

- **1:1 messages — yes**, genuinely solid for existing pinned devices.
- **Group chat — yes** cryptographically, but §2.1 lets an attacker *become* a member under your name; that's an authorization hole, not a crypto break, and it must close first.
- **Calls — group yes; 1:1 no.** 1:1 is DTLS-SRTP with an optional, non-fatal verification tag. Either implement true E2EE keying or stop marketing 1:1 calls as end-to-end encrypted.
- **Documents/photos/videos in chat — yes** (AES-256-GCM envelope over the ratchet), with the MIME metadata leak (M6) and plaintext profile photos (§2.8) as the exceptions to fix.
- **Stories — yes**, per-device envelopes, viewer privacy engineered and honestly documented.

The content encryption is real. What can "leak or be broken" today is: **identity/membership trust** (§2.1, §2.5), **delivery availability** (§2.4, §2.6, M3), **metadata** (§2.2, §2.3, M1-M2), **at-rest backups behind weak PINs** (M9), and **one misconfig away impersonation switch** (§2.7).

## 7. Remediation order

1. Verify prod env has neither `AUTH_DEV_BYPASS` nor default `JWT_SECRET` (§2.7, M10).
2. Port `ownsDevice` to `POST /mls/keypackages` + consumption binding + client credential check (§2.1).
3. Membership-check `GET /messages/conversation/:id`; bind `/pending/:user_id` to the JWT (§2.2, §2.3).
4. Relationship-gate prekey/KeyPackage fetching (§2.4); scope receipt writes (M1-M2).
5. Fix fallback-key restore/rotation idempotency + restart test (§2.6); surface new-device pinning (§2.5).
6. Ship encrypted profile photos + entitlement-checked downloads (§2.8); wrapper-only MIME (M6); upload size caps (M7).
7. Make 1:1-call verification mandatory-or-loud (M5); MLS epoch retention + delivery-after-ack (M3).
8. PIN floor ≥6 + server-side guessing cost (M9); WS hardening set (M8).

*Then:* the independent cryptographic review this repo's own SECURITY.md already promises. This document does not replace it.

---

## 8. Adversarial verification (post-audit attack pass)

Findings were re-tested by attacking, not just reading. Executed locally against the real code; the remote Supabase instance was deliberately **not** touched.

### 8.1 EXECUTED — restart rotates the server-served fallback key (§2.6) ✅ PROVEN

`packages/e2e-core/tests/regress_fallback_restore.rs` reproduces the exact client sequence: publish bundle → pickle → restore **without** `restore_fallback_key()` (the app never calls it) → routine replenish.

```
test restart_without_fallback_restore_rotates_the_served_key ... ok
  → PROOF: an ordinary app restart publishes a DIFFERENT fallback key than
    the one the server still serves; senders holding the old bundle
    eventually produce undecryptable prekey messages.
test restore_then_publish_keeps_the_served_key_stable ... ok
  → VALIDATES THE FIX: with restore_fallback_key() called, no replenish ever
    mints a different served key.
```

The test is kept in the tree as a permanent regression gate for the fix.

### 8.2 EXECUTED — `assertOpaque()` plaintext smuggling (A14) ✅ BYPASSED

Run against the real validator (`packages/common-utils/src/crypto.ts`):

```
BYPASS  · case variant        { Body: "meet me at 7pm" }        → accepted
BYPASS  · nested object       { meta: { note: "..." } }         → accepted
BYPASS  · unknown extra field { stickyNote: "..." }             → accepted
```

Impact stays LOW only because every persistence/relay sink whitelists named columns; residual risk is covert-channel storage in free-text columns (`content_type`, `media_mime`, `media_url`). Fix remains: allowlist validation on send bodies.

### 8.3 EXECUTED — recovery PIN offline cost (M9) ✅ MEASURED (claim corrected)

Measured against shipped Argon2id parameters (m=19 MiB, t=2, p=1), debug build:

```
per-guess: 296 ms | full 4-digit keyspace ≈ 49 min single-core
                    | 6-digit keyspace   ≈ 82 hours single-core
```

Release build is ~5–10× faster per core and the work parallelizes trivially, so the practical numbers are **~5–10 min for a 4-digit PIN, ~half a day to a day for 6 digits on a commodity multi-core box**. My original "seconds-to-minutes" phrasing overstated 4-digit speed at these params — the corrected framing: the floor is low enough that mass cracking after any DB breach is routine work, so M9's fixes (≥6-digit floor, common-PIN rejection, server-side guessing cost) stand unchanged. Test: `packages/e2e-core/tests/pin_brute_force.rs`.

### 8.4 REQUEST-LEVEL PROOFS — API authz holes (not executed; live DB off-limits)

Exact attacks against §2.1–§2.4, each verified against the code path first-hand (`messages.ts:387-452/457-496`, `mls.ts:36-63/73-92`, `prekeys.ts:135-203`). Any authenticated JWT suffices; `AUTH_DEV_BYPASS=1` makes minting one trivial while present.

```bash
# §2.2 — read ANY conversation's full timeline (no membership check):
curl -H "Authorization: Bearer $ATTACKER_JWT" \
  https://api.example/v1/messages/conversation/<any-conversation-uuid>

# §2.3 — harvest + never-release another user's pending queue (legacy path,
#        bound to req.params.user_id, repeatable forever):
curl -H "Authorization: Bearer $ATTACKER_JWT" \
  https://api.example/v1/messages/pending/<victim-user-uuid>

# §2.1 — plant an attacker-controlled MLS KeyPackage on a VICTIM's device
#        (device ids are public via GET /devices/:user_id):
curl -X POST -H "Authorization: Bearer $ATTACKER_JWT" -H "Content-Type: application/json" \
  -d '{"device_id":"<victim-device-id>","key_packages":["<attacker-keypackage-b64>"]}' \
  https://api.example/v1/mls/keypackages
# …then drain the victim's legit packages until only the planted one is served:
curl -H "Authorization: Bearer $ATTACKER_JWT" \
  https://api.example/v1/mls/keypackages/<victim-user-uuid>

# §2.4 — prekey exhaustion loop (denies all new inbound sessions):
while true; do curl -H "Authorization: Bearer $ATTACKER_JWT" \
  https://api.example/v1/prekeys/<victim-user-uuid>; sleep 0.21; done
```

These four are the launch blockers. Each is a one-line-to-three-line server fix listed in §7 items 2–4.

### 8.5 What survived the attack pass

- Hostile-ciphertext decrypt paths: fuzzed negative suites all hold (`tests/hardening.rs`, `tests/robustness.rs`) — no panic, no accept.
- Replay of ratchet messages rejected; consumed OTKs cannot re-establish (`tests/prekeys.rs:39-61`).
- Wrong-PIN / tampered wrap / wrong pickle key all fail closed (`tests/recovery.rs`, `tests/hardening.rs:73-84`).
- GCM nonce discipline: fresh random nonce per encryption verified in source across media/recovery/call paths.

---

## 9. Remediation log (post-audit fixes)

Status after the fix pass. Suites at time of writing: backend 185/185, e2e-core 21 binaries green (incl. the two new adversarial tests), web build clean.

| Finding | Status | What was done |
| --- | --- | --- |
| §2.1 KeyPackage planting | **FIXED (server)** | `ownsDevice()` gate on `POST /mls/keypackages` (404 anti-enumeration) + `kp.user_id = d.user_id` ownership binding in the consumption query — planted rows are unservable even if they exist. Client-side credential-vs-roster check still RECOMMENDED as defence-in-depth. (`routes/mls.ts`) |
| §2.2 Conversation read authz | **FIXED** | `isConversationMember` guard before any read on `GET /messages/conversation/:id`, mirroring the send path. |
| §2.3 Pending harvest | **FIXED** | `GET /messages/pending/:user_id` rejects unless path user == JWT user; supplied device ids must belong to the caller. |
| §2.4 Prekey/KeyPackage drain | **FIXED (policy)** | New shared `guardKeyMaterialFetch` (security.ts): blocked callers get the endpoint's normal empty shape (no oracle), everyone else is throttled per (caller, target) pair — 5/min via Redis. Applied to both `/prekeys/:user_id` and `/mls/keypackages/:user_id`. Sustained cross-IP drain by one account is now impossible; a distributed attack across many accounts remains theoretically possible and is inherent to public prekey serving. |
| §2.7 AUTH_DEV_BYPASS / JWT_SECRET | **FIXED** | `.env` bypass set to 0; both services now REFUSE TO BOOT in production when the bypass is on or JWT_SECRET is missing/dev-default. Mirrored guard in websocket. |
| §2.6 Fallback-key lifecycle | **FIXED (client)** | Published fallback key persisted to Keychain and re-attached via `restoreFallbackKey` on every identity restore; rotation is idempotent (pending-upload marker retried instead of re-rotating); `ensurePrekeys` self-heals if a replenish ever mints an unrecorded fallback key. Regression test: `tests/regress_fallback_restore.rs`. |
| M9 PIN offline cost | **PARTIALLY FIXED** | New-PIN floor raised 4→6 digits with common-PIN blocklist + inline rejection reasons (`PinRules.validNew`); entry rules unchanged so existing wraps keep unlocking. Server-side guessing-cost (OPAQUE/SVR-style) remains OPEN — protocol change. |
| M5 1:1 call verification | **FIXED (frame-level E2EE shipped)** | The vendored stasel WebRTC (no cryptor API) was replaced with LiveKit's fork (`LiveKitWebRTC` via SPM; `apps/ios/VENDOR.md` records the change). `CallService` now attaches an `RTCFrameCryptor` (AES-GCM) to EVERY sender/receiver on the P2P connection, keyed by HKDF(call secret) where the secret is fanned out over the Double Ratchet — media stays peer-to-peer, and a signaling-colluding MITM now sees only ciphertext. Fail-closed: `discardFrameWhenCryptorNotReady=true` drops frames until both keys land. Commitment-tag verification wired at answer time on both sides; live badge (verified/pending/not-verified/mismatch) on both call screens. Keys die with the call in every teardown path. **Caveat:** compile-verified only (simulator build green); two-device call test still required before shipping the claim. |
| M5-group badge | **FIXED** | Group call screen reports LIVE keying state instead of an unconditional lock icon. |

### Still open (tracked)

1. §2.5 new-device TOFU surfacing (client UX work: notify-and-confirm on first sighting).
2. §2.8 profile-photo encryption (bindings already exist in core; ship `ProfileKeyStore`).
3. Client-side MLS credential-vs-roster verification (defence-in-depth on top of §2.1 server fix).
4. M3 MLS epoch retention + delivery-after-client-ack.
5. M6 chat-media MIME leak (adopt stories wrapper pattern). M7 upload size caps. M8 WS hardening set. M10 token revocation model.
6. **Two-device call verification test**: the new 1:1 frame-E2EE path compiles and is wired at every lifecycle point, but a real device-to-device call (ring → accept → connected with VERIFIED badge → hangup) must pass before the marketing claim is repeated anywhere.
