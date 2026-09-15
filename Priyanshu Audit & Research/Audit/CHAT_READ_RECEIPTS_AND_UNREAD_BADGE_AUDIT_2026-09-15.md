# Chat read receipts and sticky unread badges: audit

> **Date:** 15 Sep 2026  
> **Baseline:** `main` at `9fc79f3`  
> **Scope:** chat tiles/grid unread badges, opening a conversation, receipt persistence, sender “Seen” state, local caches, iOS, Android, web companion, and API.  
> **Method:** read-only source and history audit. No product code or data was changed. A live two-account/device reproduction was not available, so runtime-only conclusions are explicitly marked for verification.

---

## Executive summary

The reported symptom has a confirmed historical root cause: clients marked only message IDs they had locally, while history was fetched 50 at a time. A conversation with more unread messages than the local page could never clear the older unread rows; the server therefore kept returning a non-zero `unread_count`, and the home-grid badge returned or stayed visible.

The current baseline already contains a same-day repair in commits `2efcddd`, `2536c65`, and `9fc79f3`: opening a chat clears the in-memory badge immediately, and both mobile clients call a server-side whole-conversation read endpoint that sweeps all unread messages. A PostgreSQL integration test covers 2,500 messages and multiple server batches.

That repair addresses the primary high-volume failure, but the flow is not fully reliable yet. Four material gaps remain:

1. the whole-conversation request is fire-and-forget, silently discards failures, and has no durable retry;
2. its sender notification uses `conversation_id`, while both mobile WebSocket clients accept receipt events only when they contain `message_id`, so live “Seen” updates are dropped;
3. the local zero is not written to the conversation database, allowing a cached non-zero badge to reappear after lifecycle/store reconstruction before server convergence;
4. “my unread state” and “tell the sender I read this” are represented by the same receipt. Turning off read receipts therefore also prevents durable unread clearing.

**Assessment:** the >50-message sticky-badge root cause is fixed in source, but the end-to-end feature should not be called fully closed until the P1 reliability and privacy/state-model findings below are addressed and verified on two devices.

## Expected state flow

1. `/conversations` calculates `unread_count` from inbound messages for which the current user has no `read` row ([conversations.ts:249](../../backend/api/src/routes/conversations.ts#L249)).
2. The chat tile/grid renders `VConversation.unreadCount` ([DraggableChatGrid.swift:247](../../apps/ios/Voiid/Voiid/Main/DraggableChatGrid.swift#L247), [ChatsHomeView.kt:1073](../../apps/android/app/src/main/java/com/voiid/app/main/ChatsHomeView.kt#L1073)).
3. Opening a chat records the open conversation, clears its in-memory count, loads/syncs messages, and calls the read path ([Stores.swift:648](../../apps/ios/Voiid/Voiid/Models/Stores.swift#L648), [Stores.kt:400](../../apps/android/app/src/main/java/com/voiid/app/model/Stores.kt#L400)).
4. The read path calls both the conversation-wide endpoint and the per-message endpoint for locally held messages ([ChatEngine.swift:1285](../../apps/ios/Voiid/Voiid/Networking/ChatEngine.swift#L1285), [ChatEngine.kt:738](../../apps/android/app/src/main/java/com/voiid/app/net/ChatEngine.kt#L738)).
5. The backend writes `message_read_receipts`; subsequent `/conversations` calls should return zero, while a WebSocket receipt should update the sender’s visible message status.

## Findings

| ID | Severity | Status | Finding |
|---|---:|---|---|
| RR-01 | P0 | Fixed in current source | Message-ID-only marking could never clear unread messages outside the 50-message local history page |
| RR-02 | P1 | Open | Whole-conversation failures are swallowed and never retried |
| RR-03 | P1 | Open | Conversation-wide receipt notifications are incompatible with both mobile WebSocket consumers |
| RR-04 | P1 | Open / architectural | Disabling sender read receipts also disables durable unread clearing |
| RR-05 | P2 | Open | Optimistic badge clearing is memory-only, so stale cached badges can reappear |
| RR-06 | P2 | Open | The whole-conversation endpoint loses mobile device identity |
| RR-07 | P2 | Coverage gap | Tests prove the server sweep, not the user-visible end-to-end behavior or failures |
| RR-08 | P3 | Scope mismatch | Web companion cannot use the new whole-conversation endpoint |

## Detailed findings

### RR-01 · P0 · Fixed in current source · The 50-message ceiling caused permanently sticky badges

**Evidence.** Mobile history is paged, and the old read path could only POST IDs already present in the local store. The source history explicitly records the observed failure: a chat with 162 unread messages marked the newest 50 and stranded 112 ([ChatEngine.swift:1286](../../apps/ios/Voiid/Voiid/Networking/ChatEngine.swift#L1286)). Since `/conversations` counts every inbound message without a read receipt, those older rows kept `unread_count` non-zero.

**Current mitigation.** Both mobile clients now POST `/receipts/conversation/:id/read`. The backend processes up to 2,000 messages per pass and repeats until none remain ([receipts.ts:156](../../backend/api/src/routes/receipts.ts#L156)). The integration test inserts 2,500 inbound messages and asserts zero remain unread ([receiptPostgres.test.ts:301](../../backend/api/test/receiptPostgres.test.ts#L301)).

**Conclusion.** This is the strongest match for the reported “I read everything but the tile tag remains” symptom, particularly on an established conversation. The code repair is present at this baseline; deployment status must be confirmed separately.

### RR-02 · P1 · Open · The authoritative clearing request has no failure recovery

**Evidence.** iOS starts the conversation-wide POST in `Task.detached` and discards the error with `try?` ([ChatEngine.swift:1297](../../apps/ios/Voiid/Voiid/Networking/ChatEngine.swift#L1297)). Android launches it in a long-lived scope but wraps it in `runCatching` without logging, queueing, or retrying ([ChatEngine.kt:752](../../apps/android/app/src/main/java/com/voiid/app/net/ChatEngine.kt#L752)).

The per-message fallback has retry sets, but it covers only locally stored IDs. It cannot repair the exact >page-size backlog for which the conversation endpoint was introduced. A transient failure, expired token, rejected device, or old backend route can therefore leave the server count non-zero indefinitely.

**Recommended change.** Treat the conversation-wide operation as an acknowledged, retryable intent keyed by conversation ID. Persist pending IDs locally, remove them only after a 2xx response, retry on reconnect/foreground, and log response status. Continue per-message marking for granular sender ticks, but do not treat it as the fallback for badge convergence.

### RR-03 · P1 · Open · Sender live “Seen” updates are dropped

**Evidence.** `/receipts/conversation/:id/read` publishes `{ type: "receipt", conversation_id, ... }` ([receipts.ts:213](../../backend/api/src/routes/receipts.ts#L213)). iOS invokes its receipt callback only when `message_id` exists ([WebSocketClient.swift:372](../../apps/ios/Voiid/Voiid/Networking/WebSocketClient.swift#L372)); Android does the same ([WebSocketClient.kt:469](../../apps/android/app/src/main/java/com/voiid/app/net/WebSocketClient.kt#L469)). Neither consumes a conversation-level receipt event.

The per-message fallback still publishes usable events for the locally loaded page, and later message polling can recover persisted status. However, messages cleared only by the server sweep will not transition live on the sender’s screen. This directly matches the “doesn’t mark the message read” half of the report even when the recipient’s unread count eventually clears.

**Recommended change.** Pick one protocol and test it across platforms: either publish one standard `message_id` receipt for every changed message, or formally support a conversation-level receipt carrying a server timestamp/watermark and update all applicable sent messages client-side. A conversation-level event is cheaper, but it needs an unambiguous boundary so messages sent concurrently are not incorrectly marked read.

### RR-04 · P1 · Open / architectural · Private unread state is coupled to public read receipts

**Evidence.** iOS and Android gate the entire `markRead` call on the “send read receipts” privacy setting ([Stores.swift:679](../../apps/ios/Voiid/Voiid/Models/Stores.swift#L679), [Stores.kt:424](../../apps/android/app/src/main/java/com/voiid/app/model/Stores.kt#L424)). The backend derives unread count from those same sender-visible receipt rows ([conversations.ts:249](../../backend/api/src/routes/conversations.ts#L249)).

Opening a chat with read receipts disabled clears the badge only in memory. The server still considers every message unread, so a later conversation refresh restores the badge. This is deterministic, not a network race.

**Recommended change.** Separate recipient-owned read position from sender-visible read receipt consent. For example, maintain a per-user/per-conversation `last_read_message_id` or monotonic read timestamp for badge state, then emit sender-visible receipts only when consent allows it. The setting should control disclosure, not whether the app remembers what its own user read.

### RR-05 · P2 · Open · Optimistic clearing is not persisted locally

**Evidence.** `clearUnreadLocally` mutates only published arrays on both clients ([Stores.swift:661](../../apps/ios/Voiid/Voiid/Models/Stores.swift#L661), [Stores.kt:411](../../apps/android/app/src/main/java/com/voiid/app/model/Stores.kt#L411)). The local database is not updated. On iOS, later server conversation saves deliberately overwrite `unread_count` ([LocalStore.swift:95](../../apps/ios/Voiid/Voiid/Storage/LocalStore.swift#L95)).

If the app/store is reconstructed before the server POST succeeds—or if it fails—the old cached non-zero count can flash or persist. This is especially visible when returning quickly to the grid or relaunching offline.

**Recommended change.** Persist the optimistic zero together with a pending-read marker. Do not allow an older server snapshot to overwrite it while that intent is pending; reconcile only after an acknowledged read or a provably newer inbound message.

### RR-06 · P2 · Open · The conversation-wide call does not send `device_id`

**Evidence.** The per-message request explicitly includes the mobile device ID ([ChatEngine.swift:1202](../../apps/ios/Voiid/Voiid/Networking/ChatEngine.swift#L1202)). The conversation-wide request sends an empty body on both mobile platforms. The backend therefore resolves these calls as legacy device-less requests when the auth token lacks a device claim ([receipts.ts:127](../../backend/api/src/routes/receipts.ts#L127), [deviceAuthorization.ts:15](../../backend/api/src/deviceAuthorization.ts#L15)).

This currently clears the user-level unread query because that query accepts a read receipt from any device. It nevertheless creates inconsistent receipt provenance and bypasses the active-device validation expected by the per-message route.

**Recommended change.** Include `device_id` consistently and reject device-less calls from modern mobile sessions. Add coverage for revoked and cross-user devices on the conversation route.

### RR-07 · P2 · Coverage gap · No test proves what the user sees

The 2,500-message PostgreSQL test is valuable, but there is no regression test covering:

- opening a chat causes its grid badge to become zero and remain zero after reload;
- a failed whole-conversation POST is retried;
- the read-receipts-disabled case clears private unread state without disclosing it;
- a sender currently viewing the chat receives a compatible live update;
- iOS/Android request bodies include an active device ID;
- a message arriving while the chat is open is read without reintroducing the badge;
- rapid open/back navigation does not cancel or lose the read intent.

**Recommended change.** Add one API integration suite for convergence/failure and one store-level test per mobile platform using a fake API/WebSocket. Finish with a two-account device matrix: iOS→Android, Android→iOS, same-platform, direct/group, online/offline, privacy on/off, 1/50/51/2,500 unread, rapid back, relaunch, and multi-device.

### RR-08 · P3 · Scope mismatch · Web companion cannot call the new endpoint

The linked-browser capability allowlist permits `/receipts/mark` but not `/receipts/conversation/:id/read` ([webCompanion.ts:9](../../backend/api/src/webCompanion.ts#L9)). The web client marks only message IDs it has loaded ([engine.ts:261](../../apps/web-client/src/engine.ts#L261)). If web is expected to clear a long backlog, it retains the original ceiling class of bug.

**Recommended change.** Either authorize the scoped conversation endpoint for companion sessions with device validation, or paginate and mark the full history. Prefer the server-owned sweep so all clients share one invariant.

## Root-cause conclusion

The direct cause of the originally reported persistent tile badge was incomplete receipt coverage: the client equated “messages in my local page” with “all messages the server counts as unread.” The server’s unread query was internally correct; it faithfully exposed the incomplete client write.

The present whole-conversation endpoint corrects that mismatch. The remaining systemic problem is that read state has three meanings but only one durable representation:

- the recipient has viewed the conversation;
- the recipient’s own badge should clear across devices;
- the sender may be told that messages were read.

Those meanings currently travel through one `message_read_receipts` row and one best-effort request. That coupling explains the privacy-off failure, makes local optimism fragile, and leaves sender live updates underspecified.

## Recommended implementation order

1. **P1:** make conversation-read an acknowledged, persisted retry intent; include `device_id`.
2. **P1:** define and implement one compatible sender notification protocol, with a concurrency-safe read boundary.
3. **P1:** split private unread position from optional sender-visible receipts.
4. **P2:** persist optimistic local clearing and prevent stale snapshots from regressing it.
5. **P2:** add mobile store tests and cross-device end-to-end coverage.
6. **P3:** give web companion the same whole-conversation semantics if it is in supported scope.

## Verification performed

- Read the badge renderers, mobile stores, message engines, local conversation persistence, WebSocket receipt consumers, API unread query, receipt routes, companion capability allowlist, relevant migrations/tests, and the three fix commits.
- Confirmed route registration at `/receipts` and confirmed the current baseline is `9fc79f3`.
- Confirmed the PostgreSQL integration test exists for a multi-pass 2,500-message sweep. It was not executed because it requires the repository’s PostgreSQL integration environment.
- Ran the backend TypeScript build. It is currently blocked by a pre-existing unrelated error: `routes/calls.ts` imports `encodeOneToOneCallGrant`, which the installed `@voiid/common-utils` does not export. No receipt-specific compiler error was reported before that stop.

## Release gate

Before declaring the issue fixed in production, verify that API commit `9fc79f3` (or later) and mobile builds containing the conversation-wide calls are deployed together. Then test an account with more than 50 unread messages, because a small chat can pass through the per-message fallback and hide a broken or undeployed whole-conversation route.
