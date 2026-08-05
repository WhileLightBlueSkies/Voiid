# Conference escalation from a 1:1 call, under full E2EE — research + design

Topic: from a live 1:1 call, add a third participant; if the added person is UNKNOWN to the
other participant, show their `@username` only; a shared call grants **no** messaging rights —
the contact-PIN reachability gate (020) applies unchanged afterwards, on the same principle as
"a follow is not a messaging right" (029).

All file:line citations are from the repo as of commit `41eefc7` (2026-08-05).

---

## 1. What exists today

### 1.1 Two disjoint call stacks, no bridge between them

**1:1 calls** are a single-`PeerConnection` mesh of exactly two:

- Android: `object CallManager` owns "a single [PeerConnection] for the active call"
  (`apps/android/app/src/main/java/com/voiid/app/net/CallService.kt:50-68`, field `pc` at
  `:147`). Group calls are explicitly "OUT OF SCOPE for v1 (group SRTP keys come from
  GroupSession.callKeys later); [startOutgoing] no-ops for a group request"
  (`CallService.kt:65-66`).
- iOS: `CallService` mirrors this (`apps/ios/Voiid/Voiid/Networking/CallService.swift:5-14`,
  `pc` at `:150`), with `ActiveCall` modelling exactly one peer (`CallService.swift:43-58`).
- Media security is WebRTC **DTLS-SRTP only**; the header admits the trust model: "The
  signaling that carries the DTLS fingerprints is authenticated server-side, so a network
  attacker can't MITM without the server colluding. (An additional verified-keying layer from
  e2e-core `srtpKeysFor1to1` is a future enhancement.)" (`CallService.swift:10-14`).

**Group calls** are a LiveKit SFU with frame-level E2EE keyed off the conversation's MLS group:

- Backend mints a room-scoped JWT: room name is derived `voiid-<conversation_id>`
  (`backend/api/src/routes/calls.ts:176-181`), authorization is "active member of the
  conversation" (`calls.ts:166-174`), identity is `<user_id>:<device_id>` (`calls.ts:181`).
  The grant carries **no display name** (`calls.ts:184-196`).
- Key = MLS exporter secret → SRTP keys → base64 passphrase for LiveKit's shared-key provider:
  iOS `GroupEngine.callKeys` / `callKeyPassphrase`
  (`apps/ios/Voiid/Voiid/Networking/GroupEngine.swift:680-697`), Android
  `GroupEngine.callKey` calling `session.callKeys(m)`
  (`apps/android/app/src/main/java/com/voiid/app/net/GroupEngine.kt:498-542`). Both clients
  **refuse to join unencrypted** if the key can't be derived
  (`GroupCallService.swift:178-188`, `GroupCallService.kt:167-174`).
- Mid-call rekey on MLS epoch change exists on both platforms
  (`GroupCallService.swift:229-268` `reapplyCallKey` → `keyProvider.setKey`;
  `GroupCallService.kt:327` `provider.setSharedKey(key, KEY_INDEX)`).
- The two stacks are **mutually exclusive by design** — separate WebRTC builds and one audio
  session (`GroupCallService.swift:16-25`, `canStart()` at `:134-136`;
  `GroupCallService.kt:30-58`).

### 1.2 Signaling

The WS relay (`backend/websocket/src/index.ts`) forwards nine 1:1 frame types
(`call_offer/answer/ice/hangup/busy/decline/ringing/hold/unhold`), each to a **single**
`to_user_id` (`index.ts:407-435`), with a Redis offer buffer for push-woken callees
(`index.ts:21-38, 444-448`) and a `call_taken` sibling-device verdict (`index.ts:479-501`).
Renegotiation reuses `call_offer` under the same `call_id`; the `hasNegotiated` flag is the
discriminator between "renegotiation — apply silently" and "new call — ring"
(`CallService.kt:194-199, 451-483`; iOS `handleIncomingOffer` `CallService.swift:958`,
renegotiation branch `:1034`).

### 1.3 Key material already in e2e-core (unused for 1:1)

`packages/e2e-core/src/call.rs` has the whole 1:1-and-group keying story ready:
`new_call_secret()` — "a fresh per-call secret for a 1:1 call. Sent to the peer over the
ratchet; never given to the server in the clear" (`call.rs:30-54`),
`srtp_keys_for_1to1` (`call.rs:56-61`), and the shared KDF `derive_srtp_keys` (HKDF-SHA256,
salt `voiid-srtp-v1`, `call.rs:63-79`). It is exposed over uniffi on both platforms
(`apps/ios/Voiid/Voiid/voiid.swift:2165, 2212`;
`apps/android/app/src/main/java/uniffi/voiid/voiid.kt:651, 1694`) and **called by nothing**
in the 1:1 path (only `GroupSession.callKeys` is used, via GroupEngine).

### 1.4 History schema is already group-shaped

`database/migrations/014_calls.sql` has a `call_participants` table — "Group-call readiness
(Phase later): who joined a call and from which device… present so a group call can record
per-participant join/leave without another migration" (`014_calls.sql:30-45`). It is written
by nothing today.

### 1.5 The reachability + identity planes

- 020: three ways to open a conversation — mutual contacts, one-way contact (request),
  `@username` + 6-digit PIN (request) (`database/migrations/020_reachability.sql:7-15`);
  rate-limiting IS the PIN's security (`020_reachability.sql:71-77`,
  `backend/api/src/routes/reachability.ts:40-48, 171-204`).
- 029: "FOLLOWING ADDS NO FOURTH PATH… Any future code that reads `creator_follows` to decide
  whether a message is allowed is a bug, not a feature"
  (`database/migrations/029_creator_profiles.sql:13-23`). The conference requirement is the
  same rule applied to calls: **sharing a call is not a reachability edge.**
- Identity display precedence on both clients: saved_name → full_name → phone → username →
  "Unknown", "NEVER a raw user id"
  (`apps/android/app/src/main/java/com/voiid/app/store/UserDirectory.kt:24-30, 101-106`;
  `apps/ios/Voiid/Voiid/Storage/UserDirectory.swift:19-20, 94-100`).
- `GET /users/:id` returns `full_name` and `username` to **any authenticated user**; only
  photo/about are privacy-scoped (`backend/api/src/routes/users.ts:36-82`, `full_name`
  unconditionally at `:72`).

---

## 2. What is broken or weak

### 2.1 There is no escalation path at all (root cause: two sealed stacks)

Nothing can move a live 1:1 call to three participants: the 1:1 engine holds exactly one
`pc` (`CallService.kt:147`, `CallService.swift:150`), every signaling frame is unicast to one
`to_user_id` (`index.ts:417`), and the group stack requires tearing the 1:1 stack down first
(`GroupCallService.swift:134-136`, `GroupCallService.kt:53-58`). There is no `call_invite`
frame, no ad-hoc room, and no way for the second 1:1 participant to learn a migration is
happening.

### 2.2 Conference keys today ARE conversation keys (root cause: room + key both derived from the conversation)

The only multi-party call that exists is keyed from `GroupSession.callKeys` — the MLS
exporter secret of a **group conversation** — and roomed as `voiid-<conversation_id>`
(`calls.ts:178`; `GroupEngine.swift:680-697`). So the only way to get three people into a
call today is to first create a group conversation containing all three
(`backend/api/src/routes/conversations.ts:101-127`), which hands the unknown third party a
**persistent messaging surface** with both participants — precisely what the requirement
forbids. This is the load-bearing design change: the joiner must get **call keys, not
conversation keys** (§4.2).

### 2.3 `POST /calls/ring` and the offer relay bypass the 020 reachability gate (root cause: no membership/authorization check on the 1:1 ring path)

- `POST /calls/ring` inserts a `calls` row and pushes VoIP/wake notifications to
  `to_user_id`'s devices with **no check** that the caller shares a conversation with the
  callee, or any conversation at all — contrast with `/group/token` (`calls.ts:166-174`) and
  `/group/ring` (`calls.ts:224-230`), which both verify membership. The 1:1 handler validates
  only shapes (`calls.ts:40-61`).
- The WS relay forwards `call_offer` to any `to_user_id` (`index.ts:407-447`); documented for
  `loc_update` as "the receiving client must discard unauthorized frames — that check is the
  real authorization" (`index.ts:255-259`), **but the call path has no client-side check**:
  Android `onRemoteOffer`/`onRingPush` ring for any offer (`CallService.kt:373-399,
  451-509`), resolving an unknown caller to "Unknown" rather than rejecting.

Net effect: anyone who learns your `user_id` (e.g. from a group roster,
`conversations.ts:188-195`) can make every device you own ring — VoIP push included — with no
PIN, no request, no mutual contact. The PIN gate 020 built for messages does not exist for
calls. Any conference-invite feature must not widen this further, and should fix it.

### 2.4 Group-call identity display violates both house rules

The LiveKit token carries no `name` (`calls.ts:184-196` — correct: the server should not
assert names), but the client fallbacks then show a **raw user-id prefix**: iOS
`shortName(identity)` = first 6 chars of the uuid (`GroupCallService.swift:420, 434-437`),
Android `ident.substringBefore(':')` (`GroupCallService.kt:365`). That breaks "NEVER a raw
user id" (`UserDirectory.kt:30`) and is exactly the surface where the unknown-participant
`@username` rule must land. Neither platform routes group-call rosters through
`UserDirectory`.

### 2.5 Unknown-participant disclosure is currently full_name, not @username

Wherever a client does resolve an unfamiliar user, the precedence chain prefers `full_name`
over `username` (`UserDirectory.kt:24-30`, `UserDirectory.swift:60`), and `GET /users/:id`
gives `full_name` to any authenticated caller (`users.ts:72`). For a conference joiner who is
a stranger to one side, the requirement is **@username only** — the private-plane identity
(profile name, photo, phone) must not leak across a shared call. Today there is no code path
that distinguishes "known to me" from "unknown" when labelling a call participant.

### 2.6 1:1 media keying trusts the server (acknowledged, still open)

`srtpKeysFor1to1` is unused; DTLS fingerprints ride server-relayed SDP
(`CallService.swift:10-14`). A colluding relay can MITM a 1:1 call. The conference design
below distributes a call secret over the ratchet anyway — doing the same for plain 1:1 calls
falls out nearly for free (§4.6, fix 8).

### 2.7 Bug-class notes for the new wire messages

- Android call frames are built by hand (`CallService.kt:1848-1857`) or with
  `@EncodeDefault`-annotated serializables (`ChatEngine.kt:883-885` — the receipts/stories
  lesson). Any new `call_invite`/`call_migrate` Kotlin DTOs must use `@EncodeDefault` on
  type/version fields or hand-built JSON, or `encodeDefaults=false` will strip them.
- iOS decoders must make every new field optional (`try?`/default) — Swift `Codable` throws
  `keyNotFound` on absent keys, and old servers/relays will omit new fields.
- The proposed `call_participants` upsert (§4.3) must not rely on the
  `unique (call_id, user_id, device_id)` constraint when `device_id` is NULL
  (`014_calls.sql:40`) — Postgres NULLs break `on conflict` targets there; key invites on
  `(call_id, user_id)` with a partial unique index, mirroring the 027 receipt fix.

---

## 3. How Signal and WhatsApp do it

### 3.1 Signal: no 1:1 escalation — group calls and Call Links instead

Signal-Android (`/Users/devacc/Signal stack/Signal-Android`) has **no path that adds a
participant to a live direct call**. The shapes it does have are instructive:

- **Direct (1:1) calls**: RingRTC call messages ride the E2EE message pipeline —
  `onSendCallMessage` hands RingRTC's opaque payload to
  `sendCallMessage(RecipientUtil.toSignalServiceAddress(...))`
  (`app/src/main/java/org/thoughtcrime/securesms/service/webrtc/SignalCallManager.java:878-909`).
  Signaling is itself E2EE — Voiid's relay-stamped-but-plaintext frames are weaker.
- **Group calls**: exist only inside a GroupV2 group. `onSendCallMessageToGroup` fans
  RingRTC's opaque frames to members via `GroupSendUtil.sendCallMessage`
  (`SignalCallManager.java:915-956`). Media keys are per-sender and distributed inside those
  E2EE call messages; the SFU learns membership only via zk group credentials. Key rotation
  on membership change is automatic because eligibility = group membership.
- **Ad-hoc multi-party (the closest analogue to our requirement)**: **Call Links**. The room
  secret is a client-generated `CallLinkRootKey` carried in the URL fragment — the server
  never sees it (`app/src/main/java/org/thoughtcrime/securesms/calls/links/CallLinks.kt:32,
  74-125`). Joiners unknown to the admin land in a **pending state and must be approved**
  (`components/webrtc/v2/PendingParticipantsState.kt:13`,
  `components/webrtc/v2/WebRtcCallActivity.kt:1429`), and are labelled by their self-asserted
  profile name. Two lessons: (a) the conference secret is call-scoped and out-of-band from
  any conversation; (b) joining a call together creates **no messaging relationship** —
  message requests still gate contact afterwards, which is exactly the 020/029 principle.

### 3.2 WhatsApp (product behaviour; no source available)

WhatsApp *does* support in-call escalation: "add participant" on a 1:1 call migrates it from
P2P to their conference infrastructure. Per its published security whitepaper, the initiator
generates call key material and distributes it to each participant over pairwise
Signal-protocol sessions; adding a participant re-keys. The added person sees the call
immediately; contact rules for messaging afterwards are unchanged. This — make-before-break
migration plus initiator-distributed per-call keys over pairwise E2EE — is the model the
design below adopts, with Signal's approval/identity discipline layered on.

---

## 4. Recommended design

### 4.1 Signaling (backend/websocket + backend/api)

New relay frames, same discipline as the existing nine (unicast `to_user_id`, sender stamped
from JWT, rebuilt from a fixed field list, never logged — `index.ts:379-435`):

- `call_invite` — inviter → invitee: `{ call_id, room, call_kind, invited_by, other_user_id }`.
  Buffer in the existing offer buffer keyed by `call_id` (`index.ts:444-448`) so a push-woken
  invitee still gets it; clear on `call_invite_cancel` / resolution, same as offers.
- `call_invite_accept` / `call_invite_decline` — invitee → inviter (decline reuses the
  existing sibling `call_taken` plumbing so the invitee's other devices stop ringing,
  `index.ts:479-501`).
- `call_migrate` — inviter → current 1:1 peer: `{ call_id, room }` = "escalating; connect to
  the SFU room, keep 1:1 media until it's up".
- `call_key` — any participant → any participant: `{ call_id, ciphertexts: [{device_id, body}] }`,
  opaque pairwise-ratchet ciphertext exactly like the location relay's opacity rule
  (`index.ts:245-259`). This carries the call secret (§4.2); the relay must apply the same
  base64-only structural check.

New API surface (`backend/api/src/routes/calls.ts`):

- `POST /calls/:id/escalate` → creates the **ad-hoc room** `voiid-call-<call_id>` (call-scoped,
  NOT `voiid-<conversation_id>`), marks the caller + current peer in `call_participants`
  (`014_calls.sql:33-45`), and VoIP/wake-pushes the invitee with `type: 'call'`-style
  content-free meta (reuse `calls.ts:63-105`). **Authorization**: requester must be a
  participant of the live call AND must be allowed to reach the invitee — same test the
  message path uses: mutual contact, or an existing accepted conversation membership with the
  invitee (`reachability.ts:73-90`, `conversation_members.request_state = 'accepted'`,
  `020_reachability.sql:46-55`). The invitee's relationship to the *other* participant is
  deliberately not required — that is the "unknown participant" case.
- `POST /calls/:id/adhoc-token` → LiveKit JWT for room `voiid-call-<call_id>`, gated on a
  `call_participants` row (`joined/invited`, `left_at is null`) instead of conversation
  membership — the counterpart of `calls.ts:166-181`. Same `<user_id>:<device_id>` identity,
  **no name claim**.
- **No conversation row is ever created or modified** by either endpoint. Grep-guard in tests:
  nothing under `/calls` may INSERT into `conversations` or `conversation_members` (the 029
  rule, restated for calls: reading `call_participants` to authorize a message is a bug).

### 4.2 Key exchange for the joiner — call keys, not conversation keys

Use the machinery already shipped in e2e-core, none of which touches conversation state:

1. On escalation the **inviter** generates a fresh root: `newCallSecret()`
   (`call.rs:48-54`; uniffi: `voiid.swift:2165`, `voiid.kt:1694` area). This secret is
   call-scoped and dies with the call — it is *not* the MLS exporter and grants nothing
   beyond media decryption.
2. Distribute it pairwise over the Double Ratchet: to the current peer over the existing 1:1
   session; to the invitee by establishing sessions from their prekey bundles, exactly the
   `ChatEngine.encryptFanout` / `resolveTargets` / `fetchBundles` device-fanout path
   (`apps/android/.../ChatEngine.kt:630-712`; iOS `ChatEngine.swift` equivalent). Session
   establishment stores no `conversations` row — 020's comment is explicit that key exchange
   is orthogonal to conversation authorization (`020_reachability.sql:17-19`). The ciphertext
   rides the `call_key` frame (§4.1), not the durable message path — no chat artifact.
3. Everyone derives the LiveKit passphrase the same way group calls already do:
   `deriveSrtpKeys(root)` → base64(`masterKey‖masterSalt`) (`call.rs:63-79`; format per
   `GroupEngine.swift:685-697` / `GroupEngine.kt:498-542`), applied via the existing
   shared-key provider (`GroupCallService.swift:195`, `GroupCallService.kt:183-185`).
4. **Rekey on every membership change** (join and leave): the inviter (fallback: lowest
   user_id still present) mints a new secret and re-fans `call_key`; clients re-apply via the
   already-built `setKey`/`setSharedKey` rotation path (`GroupCallService.swift:249-268`,
   `GroupCallService.kt:327`). This gives the joiner no access to pre-join media and a leaver
   no access after leaving — the property MLS epochs give group calls, done per-call.
5. Refuse to connect without a key, as both group clients already do
   (`GroupCallService.swift:178-188`, `GroupCallService.kt:167-174`).

### 4.3 Call lifecycle / persistence

Write `call_participants` rows (finally using `014_calls.sql:33-45`) with an added `state`
column (`invited → joined → left`) via a small migration; unique on `(call_id, user_id)`
partial-index (NULL `device_id` caveat, §2.7). `POST /calls/:id/status` keeps working
unchanged for history.

### 4.4 UI states

Inviter: `CONNECTED → ESCALATING → CONFERENCE`. During `ESCALATING` both the 1:1
`PeerConnection` and the SFU connection are live (**make-before-break**); the 1:1 leg is hung
up (normal `call_hangup`, `index.ts:451-465` cleanup applies) only after both original
participants report SFU-connected. Failure of the SFU leg falls back to the still-standing
1:1 call — never drop working media to attempt an upgrade.

Peer: receives `call_migrate`, shows "Adding <name>…", joins the room, keeps 1:1 audio until
SFU media flows.

Invitee: standard incoming-call surface (Telecom / CallKit via the existing ring-push path,
`CallService.kt:373-399`, `calls.ts:63-105`) labelled "<inviter> is adding you to a call".
Accept → fetch adhoc token → join room; decline → `call_invite_decline`, inviter's UI shows
it, nothing else changes.

The 1:1/group mutual-exclusion gates (`GroupCallService.swift:134-136`,
`GroupCallService.kt:53-58`) need one carve-out: the escalation window may hold both engines
for the same `call_id`.

### 4.5 Identity disclosure rules (who sees whom as what)

For every roster tile, resolve locally, per viewer:

- **Known** (in `UserDirectory`: saved contact, or an accepted-conversation peer): existing
  precedence chain (`UserDirectory.kt:24-30`) — saved name wins, photo allowed.
- **Unknown**: show `@username` **only** — no full_name, no photo, no phone. Fetch via
  `GET /users/:id` but bind the label to `username` and ignore `full_name`/`photo_url` in
  this state (better: a minimal endpoint or a server change withholding `full_name` from
  non-contacts, since `users.ts:72` currently over-shares — see fix 6). If `username` is
  null (user never set one), show "Unknown", never a uuid (`UserDirectory.kt:30`,
  `GroupCallService.swift:434-437` and `GroupCallService.kt:365` both currently violate this).
- The unknown tile's tap-through goes to the @username profile → "Message" routes through
  `POST /reachability/request` with the PIN prompt, **unchanged**
  (`reachability.ts:145-244`). Nothing in the call flow writes anything that
  `isMutualContact`/`hasSavedContact` (`reachability.ts:73-90`) reads, so the gate holds by
  construction; keep it that way with the grep-guard from §4.1.
- The relay/token never assert names (already true, `calls.ts:184-196`) — identity is always
  resolved viewer-side, so each participant can legitimately see a *different* label for the
  same person (my "Mum" is your "@nehal").

### 4.6 Ordering with the ring-authorization fix

Fix §2.3 first or together: `call_invite` adds a second server-sanctioned way to make a
stranger's phone ring, and it must launch behind the same reachability test — while today's
`/calls/ring` has none at all.

---

## 5. Recommended fixes (ordered)

| # | What | Platform | Sev | Files | Risk |
|---|------|----------|-----|-------|------|
| 1 | Authorize `POST /calls/ring` + client-side offer gate (see §2.3) | backend + both mobile | critical | `backend/api/src/routes/calls.ts`, `backend/websocket/src/index.ts`, `apps/android/.../net/CallService.kt`, `apps/ios/.../Networking/CallService.swift` | Low server risk; client gate must not drop offers from legitimate not-yet-synced peers — gate on "shares any accepted conversation OR in UserDirectory", log-only first release |
| 2 | Ad-hoc call rooms: `POST /calls/:id/escalate`, `POST /calls/:id/adhoc-token`, `call_participants` writes + `state` migration | backend | high | `backend/api/src/routes/calls.ts`, new `database/migrations/030_call_conference.sql` | Medium; NULL-device_id upsert caveat (§2.7) |
| 3 | Relay frames `call_invite`/`call_invite_accept`/`call_invite_decline`/`call_migrate`/`call_key` with buffering + opacity checks | backend | high | `backend/websocket/src/index.ts` | Low — mirrors existing frame plumbing |
| 4 | Call-secret generation + pairwise distribution + rekey-on-membership-change | both mobile | high | `apps/android/.../net/CallService.kt`, `GroupCallService.kt`, `ChatEngine.kt`; `apps/ios/.../Networking/CallService.swift`, `GroupCallService.swift`, `ChatEngine.swift` | High — key-agreement races on rapid join/leave; debounce like the epoch rekey (`GroupCallService.swift:236-243`) |
| 5 | Escalation engine: make-before-break 1:1→SFU migration + invitee join UX | both mobile | high | same call engine files + `CallScreens`/`GroupCallScreen[s]`, `VoiidMessagingService.kt`, `VoiidApp.swift` | High — audio-session handover between the two WebRTC builds is the hard part (`GroupCallService.swift:22-25`) |
| 6 | Identity rules: unknown ⇒ @username-only labels; kill raw-uuid fallbacks; optionally stop `GET /users/:id` returning `full_name` to non-contacts | both mobile (+backend) | medium | `GroupCallService.swift:420,434-437`, `GroupCallService.kt:349,365`, `UserDirectory.kt`, `UserDirectory.swift`, `backend/api/src/routes/users.ts` | Low mobile; backend change needs an audit of existing `full_name` consumers |
| 7 | Guard tests: no `/calls` code writes conversation rows; no reachability reads `call_participants` | backend | medium | `backend/api/test/` (new), `backend/api/src/routes/calls.ts` | Low |
| 8 | Use `newCallSecret` + `srtpKeysFor1to1` for plain 1:1 calls too (closes §2.6) | both mobile | low | `CallService.swift:10-14` area, `CallService.kt`, `ChatEngine.*` | Medium — needs a version-negotiated rollout so old clients still interop |

### Hypotheses (marked as such)

- WhatsApp's escalation mechanics (§3.2) are from its public whitepaper/product behaviour,
  not source.
- Whether LiveKit's shared-key provider re-keys glitch-free under rapid successive `setKey`
  calls at conference scale is untested here; the group-call debounce
  (`GroupCallService.swift:238-241`) suggests the same treatment will be needed.
