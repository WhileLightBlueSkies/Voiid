# Handoff — 2026-07-23 morning (weekly-limit cutoff)

Everything is **uncommitted on `main`**. Nothing pushed, nothing deployed.
Companion doc: `OVERNIGHT_AUDIT_2026-07-23.md` (full detail on everything before this morning).

## Where things stand right now

| Track | State |
|---|---|
| Calls: offer buffer, TURN, VoIP checklist, contact/dialer linking (both OS), missed-call + group notifications | DONE, compiles; needs device testing |
| iOS Settings tree (privacy/storage/linked devices/about/edit profile) | DONE, compiles |
| All 9 critical review findings + high-impact majors | FIXED, compile-verified |
| Bluetooth/audio-route picker — iOS (voice+video), Android (control now in video too) | DONE; iOS compiles, Android edit batched (unbuilt) |
| Stories + Maps (both features): specs, backend, ~80 client files | Backend typechecks; clients written by agents |
| Stories + Maps **navigation (tab bars)** | Agents were RUNNING at cutoff — check `RootTabView.swift` / Android nav host; finish by hand if partial |
| Stories + Maps verify phase | DELIBERATELY SKIPPED (budget) — never ran |
| Reactions / reply / forward / delete-for-everyone — **iOS + Android** | **WIRED both platforms (uncompiled).** Real E2EE delivery: senders in ChatEngine(.kt/.swift), inbound apply, Stores + refresh, persistence. Envelope JSON matches byte-for-byte across platforms. |
| Profile: fetch REAL server data on login | **DONE both.** Android `loadProfile()` already fetched it; iOS added `AppSession.refreshServerProfile()` (called from ChatsHomeView.task) + `username` on VUser. |
| OTP → backup restore prompt | Already wired both platforms (iOS OTPScreen.verify, Android OtpScreen). No change needed. |
| R2 buckets | ONE bucket is enough — backups use `backups/<uid>` prefix, media uses `media/...`. If you add a story auto-delete lifecycle rule, scope it to `media/` only, never `backups/`. |

## If the Stories/Maps workflow was stopped mid-run

Resume later with (agents already finished replay free from cache):
```
Workflow({ scriptPath: "/Users/devacc/.claude/projects/-Users-devacc-Voiid/fb8211bb-791a-4e9a-9e16-753910465b4a/workflows/scripts/voiid-stories-and-maps-wf_b4499dd3-b41.js",
           resumeFromRunId: "wf_b4499dd3-b41" })
```
If only the tab-bar wiring is missing, it is faster by hand: add Stories + Map tabs in
`apps/ios/Voiid/Voiid/Main/RootTabView.swift` (entry points: `StoriesHomeView`, `MapTabView`)
and the Android bottom-nav host in `MainActivity.kt`/`main/` (composables: see
`main/StoriesHomeView.kt`-equivalents written by the agents), honouring `session.hideTabBar`.

## Reactions/reply/forward/delete — everything is staged, here is the exact plan

**Scouted conclusion: ZERO backend work.** The relay is content-agnostic; these ride
`POST /messages/send` with a `content_type` hint exactly like `story_reply` already does.

**Already in the project:** `apps/ios/Voiid/Voiid/Networking/MessageActionWire.swift` — the
four envelope types (`MessageReactionEnvelope`, `MessageDeleteEnvelope`, `MessageReplyEnvelope`,
`ForwardedMediaEnvelope`) + `MessageActionContentType`. Compiles standalone.

**iOS: DONE (uncompiled).** Files changed:
- `Networking/MessageActionWire.swift` — envelopes + `MessageActionInbound` parser.
- `Networking/ChatEngine.swift` — `DecryptedMessage` gained `reactions/deletedForEveryone/
  quotedId/quotedPreview/quotedSender/forwarded/control`; senders `sendReaction`,
  `sendDeleteForEveryone`, `sendReply`, `forwardMedia`; appliers `applyReaction`/
  `applyDeleteForEveryone`; inbound probe in `decryptInboundLocked`; `messages()` filters
  control rows.
- `Models/Stores.swift` — `react()`/`deleteMessage(forEveryone:)`/`forward()` now deliver over
  E2EE; `send()` uses `sendReply` for quotes; `refresh()` surfaces the new fields onto VMessage.
- `Models/Models.swift` — VMessage already had reaction/deletedForEveryone/replyTo*/forwarded;
  reused as-is (single-emoji display; per-user map is persisted in the engine).

**KNOWN LIMITATIONS to finish later:**
- Reaction DISPLAY is single-emoji (shows peer's else mine). Per-user multi-emoji rendering
  needs a `reactions: [String:String]` on VMessage + ChatDetailView chips.
- GROUPS: reactions/delete wired only for the 1:1 (ChatEngine) path. The MLS group path
  (GroupEngine.ingestGroupMessage) needs the same inbound probe added.
- Inbound FORWARD arrives as a normal media message (no "Forwarded" tag on the receiver).
- NOT COMPILED — build and fix per your rule.

**ANDROID: still pending** — mirror the above in `net/ChatService.kt`/ChatEngine-equivalent,
`model/Models.kt`, `model/Stores.kt`, `main/ChatDetailView.kt`, Room. Envelope JSON field
names MUST match iOS byte-for-byte (`t`,`v`,`target`,`emoji`,`text`,`quotedId`,`quotedPreview`,
`quotedSender`,`media`,`caption`). Realistic effort ~1–2h.

**The hook edits (all in files the Stories agents had locked; mirror `sendStoryReply` at
`ChatEngine.swift:~1127` for every sender):**

1. `ChatEngine.swift`
   - `DecryptedMessage`: add `var reactions: [String: String]? = nil` and
     `var deletedForEveryone: Bool? = nil`, and (for replies) `var quotedId: String?`,
     `var quotedPreview: String?`. **Optionals only** — synthesized Decodable must tolerate
     old store records that lack the keys.
   - Senders (inside ChatEngine — they need private `encryptFanout`/`api`/`append`):
     `sendReaction(target:emoji:conversationId:peerUserId:)`,
     `sendDeleteForEveryone(target:conversationId:peerUserId:)`,
     `sendReply(_ env:conversationId:peerUserId:)` — each: encode envelope → `encryptFanout`
     → POST with its `MessageActionContentType` → local echo/apply + `persist()`.
     `forwardMedia(ref:caption:to:peerUserId:)` sends `ForwardedMediaEnvelope` with
     `content_type: "media"` — **no re-upload**; the R2 ciphertext already exists.
   - Inbound: in `decryptInboundLocked` (~580), before appending a bubble, probe the
     plaintext `"t"` (existing `EnvelopeProbe`): `msg_reaction` → set/clear
     `reactions[senderId]` on the message whose `serverId == target`; `msg_delete` →
     verify sender is the target's author, then tombstone; `msg_reply` → append as a
     normal message carrying the quote fields. Mark all three as seen; never render raw JSON.
   - `decodeEnvelope` (~977): add the three `"t"` branches so old-payload fallback never
     shows JSON in a bubble.
   - GROUPS: same probe where GroupEngine ingests decrypted plaintext
     (`ingestGroupMessage` path) — reactions must work in groups too.
2. `Models.swift` — `VMessage`: replace single `reaction: String?` usage with per-user
   `reactions: [String: String]` (keep the old field for compatibility; UI reads the map).
3. `Stores.swift` — `react()` → `ChatEngine.sendReaction` (optimistic local apply stays);
   `deleteMessage(forEveryone: true)` → `sendDeleteForEveryone`; `forward()` → media
   messages call `forwardMedia` with the original `MediaRef`; `refresh()` maps the new
   fields onto `VMessage`.
4. `ChatDetailView.swift` — render `reactions` (grouped emoji + count), quoted-reply
   header on bubbles, tombstone style for `deletedForEveryone`.
5. **Android mirror** (`net/ChatEngine`-equivalent, `model/Models.kt`, `model/Stores.kt`,
   `main/ChatDetailView.kt`, Room): same envelopes byte-for-byte (JSON field names must
   match iOS exactly), per-user reactions map, append-only Room migration for the new
   message columns.

**Correctness rules that must survive implementation:** delete only honoured from the
original author; reaction clearing is an explicit `emoji: null` signal; all state persisted
(GRDB/Room + the JSON store), not in-memory; server never sees plaintext.

## Deferred verification debt (deliberate, user-directed)
- No compile pass was run after: Android video-call audio control edit, Stories/Maps client
  + nav output. First post-reset action: build both platforms + `tsc` both backends.
- Stories/Maps adversarial verify (privacy/correctness/honesty) never ran. The two earlier
  workflows' verifies found 9 criticals — assume this one hides similar. Run when budget allows.
- Everything device-dependent is untested (see audit doc's device-test list).

## Inputs still needed from the user
1. Google Maps API key (Android) 2. Privacy-policy + Help URLs 3. `rustup` toolchain for
`packages/e2e-core/build-apple.sh` (iOS cannot LINK until then) 4. Deploy `backend/websocket`
5. Fix the same env-name mismatches on the deployed api-dev box (TURN + R2, see audit doc).
