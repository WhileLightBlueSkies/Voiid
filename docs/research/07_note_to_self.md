# 07 — Note to Self: why it does not work, and how to fix it

Researched 2026-08-05 against the live tree (`main`, 41eefc7). All line numbers cite that state.

## TL;DR

Note to Self exists end-to-end (its own `'self'` conversation type on the server, creation on
every launch, pinned row in the chat list, a dedicated ChatEngine send path for "no other
devices") — but **the store layer on both platforms was never taught that the self
conversation's "peer" is you**. `peerUserId(...)` resolves the peer by looking for a member
whose id is not yours; the self conversation has exactly one member (you), so resolution
throws `404 "no peer"`. Every send aborts before the engine's note-to-self path is ever
reached (the note sits on a clock forever, plus a "Couldn't resolve the recipient." banner),
and every open/sync of the chat surfaces "Couldn't load messages.". The engine's carefully
commented note-to-self handling is dead code. Two further latent bugs sit behind that one:
`resolveTargets` does not exclude the sending device when the peer is yourself (so the
documented "empty target list on a single device" invariant is false), and the sync path
skips every message with `sender_id == myId`, which for Note to Self is *every* message, so a
second linked device would render an empty notes chat.

---

## 1. What exists today (cited)

### Backend

- `POST /conversations/create` accepts `type: 'self'` — idempotent, one per user, one member
  row: `backend/api/src/routes/conversations.ts:30-60`. The design comment (lines 16-29)
  correctly states the E2E model: notes are encrypted to the author's OTHER devices; with a
  single device there are no targets and the client keeps the note local.
- A `'direct'` with yourself is explicitly blocked so self-chats can't collide with the
  two-member 1:1 lookup: `conversations.ts:64-66`.
- No DB constraint blocks the type — `conversations.type` is free text with no CHECK
  (`database/migrations/005_conversations.sql:6`), so the `'self'` insert succeeds.
- The list endpoint returns the self conversation: membership filter is
  `request_state = 'accepted'` (`conversations.ts:152`) and the column defaults to
  `'accepted'` (`database/migrations/020_reachability.sql:47`), which the self-create's
  member insert (`conversations.ts:48-50`) inherits. Verified: nothing server-side hides it.
- Cosmetic: the fall-through error still says `"type must be 'direct' or 'group'"`
  (`conversations.ts:128`).

### iOS

- `ChatService.createSelfChat()` posts `{type:"self"}` (`Networking/ChatService.swift:130-134`;
  Swift `JSONEncoder` always encodes the stored property, so the known
  kotlinx-`encodeDefaults` bug class does not apply here).
- Called on every launch before the list fetch: `Models/Stores.swift:261-264`.
- `ConversationType` has a `self` case (`Models/Models.swift:95`), the DTO maps `"self"` →
  title "Note to Self" (`Networking/ChatService.swift:82-83`), and the list pins self chats
  first (`Models/Stores.swift:311-315`). UI affordances exist throughout
  (`Main/ChatListRows.swift:116`, `Main/DraggableChatGrid.swift:160`,
  `Main/ChatsHomeView.swift:664-671`, `Main/ChatDetailView.swift:145-155, 520-523`).
- The engine has a dedicated note-to-self send path: if the fan-out returns no target
  devices, the note is kept local and marked sent (`Networking/ChatEngine.swift:321-329`),
  backed by an early return in `encryptFanout` when `targets.isEmpty && peerUserId == my id`
  (`Networking/ChatEngine.swift:1040-1052`).

### Android

- Mirror of all of the above: `createSelfChat()` with an explicit
  `Json { encodeDefaults = true }` **specifically to dodge the encodeDefaults bug class**
  (`net/ChatService.kt:57-65` — `type` equals its default `"self"`, so the shared
  `ApiClient.json` would have omitted it and the server would have created a *direct* chat);
  `ConversationType.SELF` (`model/Models.kt:86`); explicit `"self"` mapping with a comment
  warning against `else -> DIRECT` (`net/ChatService.kt:73-80`); create-on-launch + pin-first
  (`model/Stores.kt:238-241, 256-257`); the engine's empty-target note-to-self path
  (`net/ChatEngine.kt:208-216`) and `encryptFanout` early return (`net/ChatEngine.kt:633-642`).

So: server OK, models OK, list OK, engine OK. The break is in the one layer between them.

---

## 2. What is broken (cited, with root cause)

### BREAK 1 — the store's peer resolution throws for the self conversation (the actual "not working at all")

Both stores resolve "the peer" of any non-group conversation by finding a member whose
user_id differs from mine:

- iOS `ChatService.resolvePeer` — `Networking/ChatService.swift:111-118`:
  `members.first(where: { $0.user_id != myId })` → for the self conversation (single member =
  me) this is `nil` and the caller gets `(nil, …)`.
- iOS `ChatStore.peerUserId(for:)` — `Models/Stores.swift:637-647`: no `type == .self` case;
  falls through to `resolvePeer`, then `throw APIError.http(status: 404, message: "no peer")`
  (line 642). Note also that `fetchConversations` only ever populates `conv.peerUserId` for
  `.direct` rows (`Networking/ChatService.swift:92`), so the cached-peer fast paths (lines
  638-640) never hit for self.
- Android identical: `net/ChatService.kt:103-115` (`resolvePeer` returns
  `PeerInfo(null, …)`), `model/Stores.kt:512-520` (`throw ApiError.Http(404, "no peer")`),
  peer only resolved for `DIRECT` (`net/ChatService.kt:88-91`).

Consequences, per platform:

- **Send never happens.** iOS `ChatStore.send` enqueues the note as PENDING, then
  `guard let peer = try? await peerUserId(for: conv) else { loadError = "Couldn't resolve
  the recipient."; return }` (`Models/Stores.swift:709-715`) — the guard always fails for
  Note to Self, `flushPending` is never called, and the note sits at `.sending` (clock icon)
  forever. Android is the same code shape: `model/Stores.kt:644-652`. Media sends die the
  same way (`Models/Stores.swift:624`; `model/Stores.kt:497`), as do replies
  (`Models/Stores.swift:693`; `model/Stores.kt:629`).
- **Opening the chat shows an error.** `syncMessages` resolves the peer before syncing
  (`Models/Stores.swift:483-484`) and the catch sets `loadError = "Couldn't load messages."`
  (lines 498-500). Android: `model/Stores.kt:396-410`.
- **The engine's note-to-self path is dead code.** `flushPending` → `encryptFanout` →
  the `peerUserId == my id` early return (`Networking/ChatEngine.swift:1050`,
  `net/ChatEngine.kt:642`) is unreachable because no caller ever passes the own user id.

Root cause: the feature was built top-down (server type, engine fan-out semantics, UI) and
bottom-up, but the middle layer — "for a self conversation, the peer *is* me" — was never
written. One store method on each platform is missing a two-line special case.

### BREAK 2 — `resolveTargets` includes the sending device (and duplicates) when peer == self

The engine comments promise: *"NOTE TO SELF … `peerUserId` is our own id, so `resolveTargets`
correctly returns our other devices MINUS this one — which on one device is an empty list"*
(`Networking/ChatEngine.swift:1040-1044`; `net/ChatEngine.kt:633-635`). The code does not do
that:

- iOS `resolveTargets` — `Networking/ChatEngine.swift:1090-1101`: the peer-devices loop
  (lines 1092-1093) appends **every** device of `peerUserId` with no `!= myDev` filter; when
  `peerUserId` is my own id that includes the *current sending device*. The own-devices block
  (lines 1095-1098) then appends my other devices **a second time**.
- Android identical: `net/ChatEngine.kt:670-682` (unfiltered peer loop at 672-673, duplicate
  own-device append at 677-680).

So once BREAK 1 is fixed, a single-device user's note would target *its own device*: the
empty-targets local-save path (`ChatEngine.swift:326-329` / `ChatEngine.kt:213-216`) never
fires. Instead the client fetches its own prekey bundle — `GET /prekeys/:user_id` hands out a
bundle for **all** of the user's active devices including the caller's own, consuming a
one-time prekey (`backend/api/src/routes/prekeys.ts:59-112`) — TOFU-pins its own identity,
mints a vodozemac session with itself, and uploads ciphertext addressed to itself. On a
multi-device account, every other own device is targeted twice → two encrypts per note (the
ratchet advances twice; the server drops the duplicate row via
`on conflict (message_id, recipient_device_id) do nothing`,
`backend/api/src/routes/messages.ts:96-104`, so one ratchet step's output is discarded —
skipped-message-key handling has to absorb it on receive).

Root cause: the peer loop was written for the strict "peer ≠ me" case and the note-to-self
comment was added to `encryptFanout` without checking what `resolveTargets` actually returns
for `peer == me`. (Hypothesis, marked as such: this was never seen in testing because BREAK 1
prevents this code from ever running with `peerUserId == my id`.)

### BREAK 3 — sync skips every own-sent message, so a linked device shows an empty Note to Self

The inbound decrypt loop skips anything with `sender_id == myId` (receipt bookkeeping only):
`Networking/ChatEngine.swift:782-786`; `net/ChatEngine.kt:328-331`. In Note to Self **every**
message has `sender_id == myId`, so a second (linked) device — the only party the fan-out
encrypts to — never decrypts or displays a single note, even though a per-device ciphertext
addressed to it sits in `message_ciphertexts`. (This is the same gap that keeps *any* own
sent message from appearing on a linked device; Note to Self is just the 100% case.)

### Not broken (checked, to save the next agent time)

- kotlinx `encodeDefaults` on the create body: already defended on Android
  (`net/ChatService.kt:60-63`); iOS `JSONEncoder` unaffected.
- Server-side visibility: `request_state` defaults to `'accepted'` — the self conversation
  is returned by `GET /conversations` (see §1).
- Unread badge: `sender_id <> $1` in the unread lateral (`conversations.ts:165`) means Note
  to Self can never accumulate a bogus unread count.
- iOS enum decode: `ConversationType(rawValue: "self")` matches the backticked case
  (`Models/Models.swift:95`); no Codable keyNotFound risk (type is always present).

---

## 3. How WhatsApp + Signal do it (from the Signal source)

Signal has no dedicated conversation type — Note to Self is a 1:1 whose recipient is your own
account, special-cased at the send boundary:

- **Recipient == self → the message becomes a sync message, never a DataMessage.**
  `Signal-Android/app/src/main/java/org/thoughtcrime/securesms/jobs/IndividualSendJob.kt:352-356`:
  `if (SignalStore.account.aci == address.serviceId) { messageSender.sendSyncMessage(mediaMessage) … }`.
  The note travels as a *sent transcript* to your own other devices only
  (`createSelfSendSyncMessage`, `lib/libsignal-service/.../SignalServiceMessageSender.java:703-708, 1936-1947`).
- **Single device → no network at all.** `SignalServiceMessageSender.java:718-726`:
  `if (!aciStore.isMultiDevice()) { "We do not have any linked devices. Skipping." return SendMessageResult.success(…) }`.
  This is exactly the invariant Voiid's `encryptFanout` comment describes.
- **The sending device is always excluded from its own fan-out.**
  `SignalServiceMessageSender.java:2860-2866`: when the recipient matches the local address,
  `deviceIds.remove(localDeviceId)`. This is the line Voiid's `resolveTargets` is missing.
- **Receipts are short-circuited locally.** `IndividualSendJob.kt:186-190`: a self-send is
  immediately marked delivered + read + viewed — no waiting for a receipt that will never
  come. (Voiid's local `markSent` on the empty-target path is the moral equivalent.)
- **Linked devices render notes from the sent transcript**, i.e. the receive pipeline
  processes own-sent sync content into the thread instead of skipping it — the capability
  Voiid's `sender_id == myId → continue` forecloses (BREAK 3).

Voiid's separate `'self'` type (vs. Signal's self-1:1) is a legitimate design divergence and
should be kept — it avoids the duplicate-member-row ambiguity the backend comment explains
(`conversations.ts:21-24`). What must be copied is Signal's *send-boundary* behavior: peer =
me, exclude my own device, empty target set = local success.

---

## 4. Recommended fixes (ordered)

### Fix 1 — CRITICAL, both mobile: teach `peerUserId` that the self conversation's peer is me

- **iOS** `apps/ios/Voiid/Voiid/Models/Stores.swift` — at the top of
  `peerUserId(for:)` (line 637): if `conv.type == .self`, return
  `TokenStore.shared.userId` (throw `.notAuthenticated` if nil) before any resolution.
  Also gate the self case out of presence + session-reset in `syncMessages`
  (lines 489-497): skip `fetchPresence` and the `resetSession`/`sendSessionReset` branch
  when `conv.type == .self` (a session reset addressed to yourself is meaningless, and the
  header must not show your own "online").
- **Android** `apps/android/app/src/main/java/com/voiid/app/model/Stores.kt` — same two
  changes: early return `tokens.userId` in `peerUserId()` (line 512) when
  `conv.type == ConversationType.SELF`; skip presence/reset in `syncMessages`
  (lines 401-407) for SELF.
- **Risk:** low. The value flows into `ChatEngine.sync`/`flushPending`, both of which are
  written for `peerUserId == my id` (the note-to-self comments) — but do not ship without
  Fix 2, or single-device sends will start encrypting to themselves (see BREAK 2).

### Fix 2 — HIGH, both mobile: `resolveTargets` must exclude the sending device (and not duplicate) when peer == self

- **iOS** `apps/ios/Voiid/Voiid/Networking/ChatEngine.swift` — in `resolveTargets`
  (lines 1090-1101): when `peerUserId == TokenStore.shared.userId`, skip the peer-devices
  fetch/append entirely and let the existing own-other-devices block (lines 1095-1098, which
  already filters `!= myDev`) produce the target list. Equivalently: filter
  `$0.id != myDev` in the peer loop *and* dedupe by device id; the skip is simpler and
  halves the `GET /devices` calls.
- **Android** `apps/android/app/src/main/java/com/voiid/app/net/ChatEngine.kt` — same change
  in `resolveTargets` (lines 670-682).
- This makes the documented invariant true: single device → `targets` empty →
  `encryptFanout` returns `[]` → `flushPending` marks the note sent locally
  (`ChatEngine.swift:326-329` / `ChatEngine.kt:213-216`); linked devices → encrypt once per
  *other* device only. Matches Signal's `deviceIds.remove(localDeviceId)`
  (`SignalServiceMessageSender.java:2860-2866`).
- **Risk:** low; strictly narrows the target set for the peer==self case, which no working
  flow currently exercises (BREAK 1 gated it). No E2EE weakening — notes remain encrypted
  per-device to the author's own other devices, ciphertext-only on the server.

### Fix 3 — MEDIUM, both mobile: let a linked device decrypt own-sent fan-out ciphertexts (notes are invisible on a second device otherwise)

- **iOS** `apps/ios/Voiid/Voiid/Networking/ChatEngine.swift` — in `decryptInboundLocked`
  (lines 778-786): in the `m.sender_id == myId` branch, before `continue`, if the row is not
  already in the local store (`!seen.contains(m.id)`) **and** carries a ciphertext for this
  device (`m.ciphertext != nil`) **and** `m.sender_device_id != E2EManager.shared.deviceId`,
  decrypt it (the fan-out encrypted it to this device's session with the sending device) and
  append it with `isMine: true`. That is the sent-transcript equivalent of Signal's linked
  device behavior.
- **Android** `apps/android/app/src/main/java/com/voiid/app/net/ChatEngine.kt` — same change
  in the sync loop (lines 324-331).
- **Risk:** medium — this branch also runs for ordinary 1:1s (it is the general
  linked-device sent-message sync gap), so test that receipts bookkeeping (the current sole
  purpose of the branch) still runs, and that the sending device itself (whose
  `sender_device_id` equals its own id) still skips. Can ship after 1+2; single-device Note
  to Self works without it.

### Fix 4 — LOW, backend: stale error string

- `backend/api/src/routes/conversations.ts:128` — `"type must be 'direct' or 'group'"` →
  `"type must be 'direct', 'group' or 'self'"`. Cosmetic; no behavior change.

### Explicitly not recommended

- Do **not** add a server-side "loopback" (storing a self-readable ciphertext or plaintext
  for single-device backfill). The backend comment (`conversations.ts:26-29`) and engine
  comments (`ChatEngine.swift:1045-1049`) are right: with one device there is nothing to
  encrypt *to*, and pre-link notes staying on the writing device is the honest E2EE
  consequence — identical to Signal's `isMultiDevice()` skip.
