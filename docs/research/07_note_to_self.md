# 07 — Note to Self is broken

Research doc. Every claim below cites `file:line` against the tree at commit `41eefc7`.
Hypotheses are labelled **HYPOTHESIS**; everything else was read directly from source.

**Scope note.** Note to Self is E2EE like any other message — it is *not* one of the
scoped non-E2EE exceptions (Clips / creators / games). Nothing recommended here weakens
that: every fix keeps the note encrypted on-device to the author's own devices, with the
server holding only ciphertext it cannot read.

---

## 1. What exists today

The feature was built end-to-end in a past session. All three tiers have real code; it is
the seams between them that fail.

### 1.1 Backend — its own conversation type

`POST /conversations/create` takes `type: 'self'` and creates a conversation with exactly
one member (the caller):

- `backend/api/src/routes/conversations.ts:30` — `if (type === 'self')` branch.
- `backend/api/src/routes/conversations.ts:32-40` — idempotent lookup: `where c.type = 'self'`
  joined to the caller's active membership row, `limit 1`. Returns `{conversation_id, existed:true}`.
- `backend/api/src/routes/conversations.ts:44-47` — insert `conversations (type='self', created_by)`.
- `backend/api/src/routes/conversations.ts:48-51` — insert exactly ONE `conversation_members` row.

The design rationale is documented in place at `conversations.ts:16-29`: a self-chat is its
own `type` rather than a `direct` with two duplicate member rows, because the direct-lookup
query identifies a 1:1 by "exactly two active members" (`conversations.ts:70-77`) and a
duplicated member row would collide with it. That reasoning is sound. The `direct` path
explicitly rejects `member_id === user_id` (`conversations.ts:64`).

**The schema does not constrain `type`.** `database/migrations/005_conversations.sql:6`
declares `type text not null default 'direct'` with only a comment (`-- direct | group`) and
no `CHECK`. So `'self'` inserts cleanly — this is *not* a break, and no migration is needed
for the server-side row to exist.

**The list query does not filter self-chats out.** `GET /conversations`
(`conversations.ts:135-171`) joins only on the caller's own membership and
`me.request_state = 'accepted'` (`conversations.ts:152`). `request_state` defaults to
`'accepted'` (`database/migrations/020_reachability.sql:47`), so the self-chat's single
member row passes the reachability gate. **A self-conversation with one member is returned
by the list endpoint correctly** — the server does not reject or hide it.

`GET /conversations/:id` (`conversations.ts:174-196`) also works: the caller is a member, so
the 403 at `conversations.ts:180` does not fire, and `members` comes back as a one-element
array containing the caller.

Cosmetic only: the fall-through error at `conversations.ts:128` still reads
`"type must be 'direct' or 'group'"`.

### 1.2 iOS

- `apps/ios/Voiid/Voiid/Models/Models.swift:95` — `enum ConversationType: String { case direct, group, `self` }`.
- `apps/ios/Voiid/Voiid/Networking/ChatService.swift:130-134` — `createSelfChat()` posts `{type:"self"}`.
- `apps/ios/Voiid/Voiid/Networking/ChatService.swift:82` — explicit `ConversationType(rawValue: c.type) ?? .direct` mapping.
- `apps/ios/Voiid/Voiid/Networking/ChatService.swift:83` — title `"Note to Self"`.
- `apps/ios/Voiid/Voiid/Networking/ChatService.swift:92` — peer enrichment restricted to `.direct`, so no futile peer hunt.
- `apps/ios/Voiid/Voiid/Models/Stores.swift:264` — `createSelfChat()` called on every launch (idempotent).
- `apps/ios/Voiid/Voiid/Models/Stores.swift:314-315` — self-chats pinned to the top of `directConversations`.
- `apps/ios/Voiid/Voiid/Models/Stores.swift:643` — **`peerUserId(for:)` returns own userId for `.self`.** The comment
  at `Stores.swift:638-642` records that the absence of this line is what killed the feature
  the first time.
- `apps/ios/Voiid/Voiid/Networking/ChatEngine.swift:1090-1114` — `resolveTargets` correctly
  excludes the sending device from the peer loop (`ChatEngine.swift:1101`) and skips the
  own-devices block when `peerUserId == myId` (`ChatEngine.swift:1109`) so linked devices
  aren't double-targeted.
- `apps/ios/Voiid/Voiid/Networking/ChatEngine.swift:1050-1052` — empty target list for a self
  send returns `[]` instead of throwing the retryable 409.
- UI: `ChatDetailView.swift:145-149` (no profile), `ChatDetailView.swift:331` (header not a link),
  `ChatDetailView.swift:523` (no "say hi" nudge), `ChatListRows.swift:116`,
  `DraggableChatGrid.swift:160` (bookmark mark, not a face), `ChatsHomeView.swift:74`
  (self excluded from the "no real chats" empty test), `ChatsHomeView.swift:666-673`
  (empty state offers "Open Note to Self").

### 1.3 Android

Structurally a mirror, with named gaps:

- `apps/android/app/src/main/java/com/voiid/app/model/Models.kt:82` — `SELF` in `ConversationType`.
- `apps/android/app/src/main/java/com/voiid/app/net/ChatService.kt:57-65` — `createSelfChat()`, and
  it *correctly* forces `encodeDefaults = true` (`ChatService.kt:62`) with an explicit comment
  about the known kotlinx default-omission bug class. That known bug class is already handled
  here — without it the server would see no `type` and silently create a DIRECT chat.
- `ChatService.kt:76-81` — explicit `"self" -> ConversationType.SELF` mapping and title.
- `ChatService.kt:90` — peer enrichment restricted to `DIRECT`.
- `apps/android/app/src/main/java/com/voiid/app/model/Stores.kt:241` — `createSelfChat()` on reload.
- `Stores.kt:256-257` — SELF pinned above DIRECT.
- `apps/android/app/src/main/java/com/voiid/app/net/ChatEngine.kt:642` — empty-targets self short-circuit exists.
- `ChatEngine.kt:213-216` — text flush short-circuits on an empty bundle.
- UI: `ChatDetailView.kt:115`, `:295`, `:362`, `:611-614`; `ChatListRows.kt:123`;
  `ChatsHomeView.kt:246`, `:958`.

---

## 2. What is broken

Five distinct defects. **B1 and B2 are independently sufficient to make the feature "not
work at all" as reported** — B1 on Android, B2 on both platforms after the first cold launch.

### B1 (CRITICAL, Android) — `peerUserId()` throws 404 for a SELF conversation, so every send fails

`apps/android/app/src/main/java/com/voiid/app/model/Stores.kt:512-520`:

```kotlin
private suspend fun peerUserId(conv: VConversation): String {
    conv.peerUserId?.let { return it }
    val di = directConversations.indexOfFirst { it.id == conv.id }
    if (di >= 0) directConversations[di].peerUserId?.let { return it }
    val resolved = chatService.resolvePeer(conv.id)
    val peer = resolved.peerUserId ?: throw com.voiid.app.net.ApiError.Http(404, "no peer")
    if (di >= 0) directConversations[di] = directConversations[di].copy(peerUserId = peer)
    return peer
}
```

**Root cause.** There is no `SELF` case. For a self-chat, `conv.peerUserId` is null
(`ChatService.kt:90` deliberately skips peer enrichment for non-DIRECT), so it falls through
to `chatService.resolvePeer(conv.id)`. `resolvePeer` (`ChatService.kt:103-115`) asks for "the
member who isn't me" — `env.members.firstOrNull { it.user_id != myId }` at `ChatService.kt:106`
— of a conversation whose only member IS me. It returns `PeerInfo(null, ...)`
(`ChatService.kt:107`), and line 517 throws `Http(404, "no peer")`.

**This is the exact bug iOS already fixed** at `apps/ios/Voiid/Voiid/Models/Stores.swift:643`,
with the comment at `Stores.swift:638-642` explicitly naming it as "why the whole feature was
dead". The Android port never received that line.

Every Android entry point into a self-chat routes through it and dies:

| Call site | Effect |
| --- | --- |
| `Stores.kt:646` (text send) | throws → caught at `Stores.kt:649-651` → `loadError = "Couldn't resolve the recipient."` — message stays PENDING forever |
| `Stores.kt:629` (reply) | same, `Stores.kt:632-634` |
| `Stores.kt:497` (media) | throws → `markStatus(FAILED)` at `Stores.kt:505` — red failed bubble |
| `Stores.kt:397` (`syncMessages`) | throws → caught `Stores.kt:408-410` → `loadError = "Couldn't load messages."` — **the chat cannot even open cleanly** |
| `Stores.kt:746` (forward media) | `getOrNull() ?: return@launch` — silently drops |
| `Stores.kt:767` (delete for everyone) | silently drops |
| `Stores.kt:800` (react) | silently drops |

Note `syncMessages` at `Stores.kt:397` is on the *open-the-chat* path, so on Android opening
Note to Self shows an error banner before the user types anything.

### B2 (CRITICAL, both platforms) — local persistence collapses `self` into `direct`

Both local stores write the conversation type as a group/not-group boolean, silently
demoting Note to Self to a normal 1:1 on disk.

iOS write — `apps/ios/Voiid/Voiid/Storage/LocalStore.swift:104`:
```swift
c.type == .group ? "group" : "direct",
```
iOS read — `apps/ios/Voiid/Voiid/Storage/LocalStore.swift:63`:
```swift
type: kind == "group" ? .group : .direct,
```

Android write — `apps/android/app/src/main/java/com/voiid/app/store/LocalStore.kt:82`:
```kotlin
kind = if (c.type == ConversationType.GROUP) "group" else "direct",
```
Android read — `apps/android/app/src/main/java/com/voiid/app/store/LocalStore.kt:49,59`:
```kotlin
val isGroup = r.kind == "group"
type = if (isGroup) ConversationType.GROUP else ConversationType.DIRECT,
```

**Root cause.** The persistence layer predates the third conversation type and was never
widened. `ConversationType` gained a third case (`Models.swift:95`, `Models.kt:82`) but the
store still round-trips a binary.

**Why this is fatal on iOS specifically.** `Stores.swift:302-317` (`applyLocalConversations`)
renders the chat list **straight from SQLite** — the comment at `Stores.swift:303-308` states
this is deliberate for instant/offline cold launch. So after the first launch every consumer
sees `.direct`:

- `Stores.swift:314` — `convs.filter { $0.type == .self }` is empty, so the pin is lost.
- `Stores.swift:643` — the self short-circuit **never fires**, because `conv.type` is now
  `.direct`. Send falls through to `Stores.swift:648-649`, `resolvePeer` returns nil
  (`ChatService.swift:114-116`), and it throws `APIError.http(status: 404, "no peer")` —
  reproducing B1 on iOS.
- `ChatService.swift:83` title logic runs on the *network* payload, but
  `LocalStore.swift:54-59` re-derives the title on read: with `peerUserId == nil` the
  `else` branch at `LocalStore.swift:58` yields `storedTitle ?? "Unknown"`. The stored title
  is "Note to Self" so the label survives — but the *type* does not.
- UI checks at `ChatDetailView.swift:145`, `:331`, `:523`, `ChatListRows.swift:116`,
  `DraggableChatGrid.swift:160`, `ChatsHomeView.swift:74`, `:666` all silently take the
  `.direct` branch: the bookmark mark reverts to a face, the header becomes a link into a
  profile of nobody, and the "say hi" nudge appears in your own notes.

On iOS `Stores.swift:264` re-runs `createSelfChat()` and `fetchConversations()` on each
launch, and `applyLocalConversations()` is called again at `Stores.swift:278` — but it reads
from SQLite, which was just written by `saveConversations` at `Stores.swift:268` with the
demoted `"direct"` kind. **The network-correct type is destroyed by the round-trip before it
is ever consumed.** This makes iOS Note to Self work only until the first `saveConversations`
call and never again.

The `kind` column is free text — `LocalStore.swift:37,91` and the Room `ConversationRow`
(`LocalStore.kt:80-89`) store a `String` with no enum/CHECK — so widening it to accept
`"self"` needs **no schema migration**, only the two write sites and two read sites.

### B3 (HIGH, both platforms + backend) — every non-text send posts `messages: []` and the backend 400s

`encryptFanout` deliberately returns an empty array for a single-device self send
(`ChatEngine.swift:1050-1052`, `ChatEngine.kt:642`). Only the **text** path handles that:

- iOS `ChatEngine.swift:326-329` — `if messages.isEmpty { markSent(...); continue }`
- Android `ChatEngine.kt:213-216` — same.

Every other sender passes the empty array straight into `SendBundleBody` and POSTs it:

| Path | iOS | Android |
| --- | --- | --- |
| media | `ChatEngine.swift:424-431` | `ChatEngine.kt:288-293` |
| reaction | `ChatEngine.swift:454-460` | `ChatEngine.kt:889+` |
| delete-for-everyone | `ChatEngine.swift:474-480` | `ChatEngine.kt:901+` |
| reply | `ChatEngine.swift:494-500` | `ChatEngine.kt:913+` |
| forward media | `ChatEngine.swift:519-525` | `ChatEngine.kt:931+` |
| location | `ChatEngine.swift:572-576` | `ChatEngine.kt:974+` |

**Root cause, server side.** `backend/api/src/routes/messages.ts:66`:
```ts
if (Array.isArray(messages) && messages.length > 0) {
```
An empty `messages` array fails the `length > 0` guard, so the request **falls through to the
legacy single-ciphertext path** at `messages.ts:141-144`:
```ts
if (!conversation_id || !ciphertext) {
    return res.status(400).json({ error: 'conversation_id and ciphertext required' });
}
```
The client sent no top-level `ciphertext` (the fan-out body has no such field —
`ChatEngine.swift:1481-1488`, `ChatEngine.kt:1393-1400`), so this is a hard **400**.

Consequence: on a single-device account, sending a photo, a voice note, a reply, a reaction,
a forward, or a location into Note to Self fails outright. On iOS 400 is not in the retryable
set (`ChatEngine.swift:345-350` retries only 409/404/transport), so media shows a red failed
bubble via `Stores.swift:630-631`. Android behaves the same (`ChatEngine.kt:231-232`).

This is also a *server contract* defect independent of Note to Self: a zero-recipient fan-out
is a legitimate state that the endpoint has no representation for.

### B4 (HIGH, Android) — `resolveTargets` encrypts the note to the sending device and double-targets linked devices

`apps/android/app/src/main/java/com/voiid/app/net/ChatEngine.kt:670-682`:

```kotlin
private suspend fun resolveTargets(peerUserId: String): List<TargetDevice> {
    val targets = mutableListOf<TargetDevice>()
    val peerDevs: DevicesResponse = api.requestAs("GET", "devices/$peerUserId")
    peerDevs.devices.forEach { targets.add(TargetDevice(peerUserId, it.id)) }     // ← no self-device filter
    val myId = tokens.userId
    val myDev = e2e.deviceId
    if (myId != null) {
        val mine: DevicesResponse = api.requestAs("GET", "devices/$myId")
        mine.devices.filter { it.id != myDev }.forEach { targets.add(TargetDevice(myId, it.id)) }  // ← not skipped when peer == me
    }
    return targets
}
```

Compare iOS `apps/ios/Voiid/Voiid/Networking/ChatEngine.swift:1096-1112`, which has both
guards and documents exactly why:

- `ChatEngine.swift:1101` — `.filter { !(peerUserId == myId && $0.id == myDev) }` keeps THIS
  device out of the peer loop. The comment at `ChatEngine.swift:1092-1095` states this filter
  "is what makes NOTE TO SELF work".
- `ChatEngine.swift:1109` — `if let myId, peerUserId != myId` skips the own-devices block
  entirely for a self send. The comment at `ChatEngine.swift:1105-1108` records the bug it
  fixes: "every note was encrypted TWICE to each linked device — two ratchet steps for one
  message, one of whose outputs the server then discards as a duplicate row, leaving the
  receiving ratchet to absorb a skipped key."

Android has neither. Two consequences on a self send:

1. **The sending device is a target of its own message.** `targets` is therefore never empty
   for a self send, so the `targets.isEmpty() && peerUserId == tokens.userId` short-circuit at
   `ChatEngine.kt:642` is **dead code on Android** — it can never fire. The engine builds an
   Olm session to itself at `ChatEngine.kt:686+` and encrypts the note to the device that
   wrote it. The server then stores a `message_ciphertexts` row addressed to the sender
   (`messages.ts:97-101`), the sender's own `sync` skips it as an own-message
   (`ChatEngine.kt:328-331`), and it is never read by anyone. **HYPOTHESIS:** building a
   self-addressed Olm session may also consume one of this device's own one-time prekeys per
   note via `fetchBundles` (`ChatEngine.kt:650`), depleting the prekey pool. I did not read
   `backend/api/src/routes/prekeys.ts` to confirm the consumption semantics.
2. **Linked devices are targeted twice** — once by the peer loop (line 673, since
   `peerUserId == myId`) and once by the own-devices loop (line 679). Two ratchet advances for
   one note; the `on conflict … do nothing` at `messages.ts:99` discards the second row, so
   the receiving ratchet must absorb a skipped message key. This is the precise failure iOS
   documented and fixed.

### B5 (HIGH, both platforms) — a linked device never renders a note, because inbound skips all own-sender messages

iOS `apps/ios/Voiid/Voiid/Networking/ChatEngine.swift:778-786`:
```swift
for m in env.messages.reversed() {
    if m.sender_id == myId {
        let applied = m.receipt_status.flatMap { applyReceipt(messageId: m.id, status: $0) } != nil
        NSLog(...)
        continue
    }
```
Android `apps/android/app/src/main/java/com/voiid/app/net/ChatEngine.kt:328-331` — identical.

**Root cause.** The guard is keyed on **user** identity (`sender_id == myId`), but the
multi-device fan-out is addressed at **device** granularity. In every normal conversation
"sent by me" implies "I already hold the plaintext", so `continue` is correct. In Note to
Self *every* message has `sender_id == myId`, including one written on your **other** device
and legitimately fan-out-encrypted to this one. This device holds a real, decryptable
ciphertext for it (`messages.ts:203`, `messages.ts:236-249` return it) and throws it away at
the `continue`.

Net effect: **Note to Self never syncs across devices.** Notes written on the phone are
invisible on the tablet and vice-versa. The in-code comments at `ChatEngine.swift:1046-1049`
and `ChatEngine.kt:638-641` promise exactly the opposite — "The moment a second device is
linked it starts receiving new notes like any other message" — which is not true while B5
stands.

The fix has a clean discriminator already on the wire: `sender_device_id` is populated on
send (`ChatEngine.swift:334`, `ChatEngine.kt:220`), stored (`messages.ts:85-88`), and
returned on read (`messages.ts:202`, DTO at `ChatEngine.swift:1496` / `ChatEngine.kt:1411`).
The guard should be "sent by **this device**", not "sent by this user".

---

## 3. How WhatsApp and Signal do it

### Signal — Note to Self is an ordinary 1:1 whose recipient is you

Signal has **no distinct conversation type**. It is a normal thread whose `Recipient` is the
local account, tested with `recipient.isSelf`:

- `Signal-Android/app/src/main/java/org/thoughtcrime/securesms/util/MessageConstraintsUtil.kt:83`
  — `val isNoteToSelf = targetMessage.toRecipient.isSelf && targetMessage.fromRecipient.isSelf`
- `Signal-Android/app/src/main/java/org/thoughtcrime/securesms/conversation/v2/ConversationFragment.kt:3054`
  — `val isNoteToSelf = viewModel.recipientSnapshot?.isSelf ?: false`
- `Signal-Android/app/src/main/java/org/thoughtcrime/securesms/mediapreview/MediaPreviewV2Fragment.kt:689`

The send path special-cases it in exactly one place —
`Signal-Android/app/src/main/java/org/thoughtcrime/securesms/jobs/IndividualSendJobV2.kt:406-411`:

```kotlin
// If this is a note to self message, don't actually send it. Instead, craft a result of
// what we *would* send. Then it'll be sent via sync message if appropriate.
if (SignalStore.account.aci == recipient.serviceId.getOrNull()) {
  Log.i(TAG, "${logPrefix(dataMessage.timestamp)} Note to self. Skipping primary send.")
  return MessageService.SendSuccess(envelopeContent, true, listOf(SignalServiceAddress.DEFAULT_DEVICE_ID))
}
```

The primary send is **skipped entirely** — no self-addressed ciphertext is ever produced.
Multi-device delivery is then carried by the ordinary sync-transcript mechanism that every
outgoing Signal message already uses:

- `IndividualSendJobV2.kt:372-376` — `if (SignalStore.account.isMultiDevice) { sendSyncMessage(...) }`
- `IndividualSendJobV2.kt:424-466` — builds `SyncMessage.Sent(destinationServiceId, timestamp, message = dataMessage, ...)`
  and calls `messageService.sendSyncMessage(...)`.

Receipts are synthesised locally rather than awaited, because there is no counterparty —
`IndividualSendJobV2.kt:230-233`:
```kotlin
if (recipient.isSelf) {
  SignalDatabase.messages.incrementDeliveryReceiptCount(...)
  SignalDatabase.messages.incrementReadReceiptCount(...)
  SignalDatabase.messages.incrementViewedReceiptCount(...)
}
```

Three transferable lessons:

1. **Never encrypt to the sending device.** Signal skips the primary send outright rather than
   filtering targets afterwards. Voiid's iOS filters (`ChatEngine.swift:1101,1109`) reach the
   same end state; Android's missing filters (B4) do not.
2. **Linked-device delivery is the *same* mechanism as normal multi-device sync**, not a
   special case. Voiid's fan-out to own other devices is the direct analogue — it just has to
   be *received*, which B5 currently blocks.
3. **Receipt/status state is synthesised locally**, since no recipient will ever ack. Voiid's
   `markSent` on an empty bundle (`ChatEngine.swift:327`, `ChatEngine.kt:214`) is the same
   idea, and should be extended to the non-text paths (B3).

Notably, Signal's model makes the whole class of "type collapsed on persistence" bugs (B2)
impossible, because there is no third type to lose — self-ness is derived from the recipient
id, which round-trips through the DB as a normal identifier. Voiid's separate `'self'` type is
still the right call for the reason given at `conversations.ts:16-29` (the two-member 1:1
lookup), but it obligates every persistence and mapping layer to carry three cases — which is
exactly where B2 bites.

### WhatsApp (behavioural, from the product — no source available)

- "Message yourself" appears in the chat list as a normal chat titled "(You)", created lazily
  on first use.
- It syncs across linked devices through the same multi-device fan-out as any chat.
- Media, replies, forwards, and reactions all work — WhatsApp's primary use case for the
  feature is forwarding links and files to yourself, which is precisely what B3 breaks in Voiid.
- There is no "delivered/read" tick pair; state settles at sent.

---

## 4. Recommended fixes

Ordered. F1–F3 together restore a working feature on a single device; F4–F5 make it correct
across linked devices.

### F1 — Android: give `peerUserId()` a SELF case (unblocks Android entirely)

**Platform:** android. **Risk:** very low — one branch, mirrors shipped iOS code.

`apps/android/app/src/main/java/com/voiid/app/model/Stores.kt:512`, as the first line of the
function body, before the `conv.peerUserId?.let` cache check:

```kotlin
if (conv.type == ConversationType.SELF) return tokens.userId ?: ""
```

(`tokens` is the same `TokenStore` used at `ChatService.kt:47`; if it is not already a field
on the store, read the user id from the existing token accessor rather than adding a new
dependency.)

This is a literal port of `apps/ios/Voiid/Voiid/Models/Stores.swift:643`. It unblocks all
seven call sites listed in B1, including the chat-open path at `Stores.kt:397`.

**Verify:** open Note to Self on Android — no "Couldn't load messages." banner; send text —
bubble goes to SENT, not stuck pending.

### F2 — Both: persist and restore the `self` conversation type

**Platform:** both-mobile. **Risk:** low. `kind` is free-text in both stores
(`LocalStore.swift:37,91`; `LocalStore.kt` `ConversationRow.kind: String`), so **no schema
migration is required**. Existing rows already written as `"direct"` self-heal on the next
`fetchConversations` + `saveConversations` cycle, since the server is authoritative on type.

iOS — `apps/ios/Voiid/Voiid/Storage/LocalStore.swift:104`, write:
```swift
c.type.rawValue,            // "direct" | "group" | "self"
```
iOS — `apps/ios/Voiid/Voiid/Storage/LocalStore.swift:63`, read:
```swift
type: ConversationType(rawValue: kind) ?? .direct,
```
Also widen the title derivation at `LocalStore.swift:51-59`: add a `kind == "self"` branch
returning `"Note to Self"` before the `peerUserId` branch, so a self row never falls to the
`"Unknown"` default at `LocalStore.swift:58`.

Android — `apps/android/app/src/main/java/com/voiid/app/store/LocalStore.kt:82`, write:
```kotlin
kind = when (c.type) { ConversationType.GROUP -> "group"; ConversationType.SELF -> "self"; else -> "direct" },
```
Android — `LocalStore.kt:49,59`, read: replace the `isGroup` boolean with a three-way mapping
(`"group" -> GROUP; "self" -> SELF; else -> DIRECT`), and add the corresponding
`"self" -> "Note to Self"` title branch alongside `LocalStore.kt:51-56`.

**Verify:** cold-launch with airplane mode on. Note to Self is still pinned at the top with
the bookmark mark (not a face), the header is not tappable, and sending still works.

### F3 — Backend: accept a zero-recipient fan-out instead of 400-ing

**Platform:** backend. **Risk:** low, additive.

`backend/api/src/routes/messages.ts:66` currently gates on `messages.length > 0`, dropping an
empty array into the legacy path that then demands a top-level `ciphertext`
(`messages.ts:142-144`).

Change the discriminator to presence rather than non-emptiness:
```ts
if (Array.isArray(messages)) {
```
The body below is already safe for an empty array: the metadata insert at `messages.ts:84-89`
writes `ciphertext = null` unconditionally, the per-device loop at `messages.ts:95-103` is a
no-op, `deviceIds` stays `[]` so the `owners` lookup at `messages.ts:110-113` returns nothing,
no Redis publish fires (`messages.ts:120`), and the push is already guarded by
`if (deviceIds.length)` at `messages.ts:130`. It returns `{message_id, delivered_devices: 0}`
— a real server-side row for a note with no other device to reach, which is the right
semantics.

Then let the non-text client paths proceed into this now-successful POST rather than 400-ing.
Preferring the server round-trip over a client-side short-circuit is deliberate: it gives the
note a canonical `message_id` and `created_at`.

**Note:** F3 has a benefit beyond unblocking media — single-device notes get a server row
*now*, so a later-linked device can be given history via the normal fan-out rather than the
"notes stay on the device that wrote them" compromise documented at `ChatEngine.swift:1046-1049`.
(Actually sending that backfill still requires a re-encrypt on the original device; out of
scope here.)

**Verify:** send a photo, a reply, a reaction, and a location into Note to Self on a
single-device account. All succeed; none show a red failed bubble.

### F4 — Android: port the two `resolveTargets` self-device filters from iOS

**Platform:** android. **Risk:** low, but it touches the ratchet — test with a linked device.

`apps/android/app/src/main/java/com/voiid/app/net/ChatEngine.kt:670-682`. Two changes,
mirroring `apps/ios/Voiid/Voiid/Networking/ChatEngine.swift:1096-1112`:

1. Move `val myId = tokens.userId` / `val myDev = e2e.deviceId` above the peer loop, and
   filter the sending device out of it (currently line 673):
   ```kotlin
   peerDevs.devices
       .filter { !(peerUserId == myId && it.id == myDev) }
       .forEach { targets.add(TargetDevice(peerUserId, it.id)) }
   ```
2. Skip the own-devices block entirely when the peer is me (currently line 677):
   ```kotlin
   if (myId != null && peerUserId != myId) { ... }
   ```

Without (1), the `targets.isEmpty()` self short-circuit at `ChatEngine.kt:642` is unreachable
and every note is encrypted to the device that wrote it. Without (2), each linked device is
targeted twice per note.

**Verify:** on a single-device Android account, log the target count for a self send — it must
be 0. With one linked device, it must be 1, not 2.

### F5 — Both: make the inbound own-message skip device-scoped, not user-scoped

**Platform:** both-mobile. **Risk:** medium — this is the main receive loop for *every*
conversation, so a mistake affects all chats, not just Note to Self. Test a normal 1:1
alongside.

iOS `apps/ios/Voiid/Voiid/Networking/ChatEngine.swift:782`:
```swift
if m.sender_id == myId {
```
Android `apps/android/app/src/main/java/com/voiid/app/net/ChatEngine.kt:328`:
```kotlin
if (m.sender_id == myId) {
```

Replace with a check that the message came from **this device**, falling back to the current
user-level behaviour when the server did not record a sender device (legacy rows have
`sender_device_id` null — `messages.ts:81,148`):

```swift
// iOS
let fromThisDevice = m.sender_device_id == nil
    ? (m.sender_id == myId)                                  // legacy row: no device attribution
    : (m.sender_device_id == E2EManager.shared.deviceId)
if m.sender_id == myId && fromThisDevice { /* receipt */ ; continue }
```
```kotlin
// Android
val fromThisDevice = if (m.sender_device_id == null) m.sender_id == myId
                     else m.sender_device_id == e2e.deviceId
if (m.sender_id == myId && fromThisDevice) { m.receipt_status?.let { applyReceipt(m.id, it) }; continue }
```

Keeping the `m.sender_id == myId` conjunct preserves today's semantics for all normal chats (a
message from a peer is never from my device, so nothing changes there), while letting a note
written on my *other* device fall through to the decrypt at `ChatEngine.swift:796` /
`ChatEngine.kt:341`.

One follow-on to check while making this change: messages decrypted on this path are appended
with `isMine: false` (e.g. `ChatEngine.swift:860-862`, and the Android equivalents). For a
self-chat, a note synced from your other device **is** yours and should render as an outgoing
bubble. **HYPOTHESIS:** the cleanest fix is to set `isMine = (m.sender_id == myId)` at the
append sites rather than hardcoding `false`; I did not audit every append site to confirm none
depends on the literal. Verify against `ChatEngine.swift:818,826,841,849,860,872` before
changing them wholesale.

**Verify:** with two linked devices, write a note on A. It appears on B as an outgoing
(right-aligned) bubble, and vice-versa. A normal 1:1 chat still shows peer messages as
incoming and does not duplicate your own sent messages.

### F6 (cosmetic) — Backend: fix the create-conversation error string

**Platform:** backend. **Risk:** none. `backend/api/src/routes/conversations.ts:128` still
reads `"type must be 'direct' or 'group'"` despite `'self'` being valid since the feature
landed. Update to include `'self'`.

---

## 5. Summary of the break

The feature was designed correctly — the backend type, the idempotent create, the fan-out
target logic on iOS, and the whole UI layer are all sound. It fails because of four wiring
gaps and one server contract hole:

- **Android never got the `peerUserId` SELF case** that iOS's own comment identifies as the
  original killer (B1) — this alone makes it "not working at all" on Android.
- **Both local stores silently demote `self` to `direct`** (B2), which re-breaks iOS after the
  first cold launch by disabling the very SELF case that fixed it.
- **The backend has no representation for a zero-recipient fan-out** (B3), so every non-text
  send 400s on a single-device account.
- **Android's `resolveTargets` lacks both self-device filters** (B4), so it encrypts notes to
  the sending device and double-ratchets linked ones.
- **Both inbound loops skip on user identity instead of device identity** (B5), so notes never
  reach a linked device — contradicting the in-code promise that they would.
