# Game-invite notification banner — design, name resolution, and delivery paths

Researched 2026-08-05 against the live tree. Every claim cites file:line. Hypotheses are marked.

---

## 1. What exists today

### 1.1 How an invite is born and travels

- `POST /games/matches` mints the match row only — it deliberately sends **no** notification
  (`backend/api/src/routes/games.ts:46-107`; the comment at :50-53 states the client sends the
  invite itself over the message pipe).
- The client then sends an ordinary **E2EE text message** whose body carries marker lines
  (`voiid:game/<slug>/<matchId>` + `voiid:gamemeta/<JSON>`):
  iOS `apps/ios/Voiid/Voiid/Networking/GamesEngine.swift:456-486`,
  Android `apps/android/app/src/main/java/com/voiid/app/net/GamesEngine.kt:480-518`.
  The wire format lives in `apps/ios/Voiid/Voiid/Networking/GameInvite.swift:32-154` and
  `apps/android/app/src/main/java/com/voiid/app/net/GameInvite.kt:32-141`.
- The embedded `Meta.from` (the name shown in the poster bubble's "from X" line) is chosen **by
  the sender**, resolved from the sender's *own* directory row:
  `GamesEngine.swift:469-475` (`UserDirectory.shared.displayName(myId, fallback: "")`),
  `GamesEngine.kt:495-503`.
- Android's meta serializer explicitly sets `encodeDefaults = true` (`GameInvite.kt:40`) — the
  known kotlinx `encodeDefaults=false` bug class is already defended against here.

### 1.2 The in-app banner (Games tab only)

- The banner component: iOS `apps/ios/Voiid/Voiid/Games/InviteBanner.swift:21-106`, Android
  `apps/android/app/src/main/java/com/voiid/app/main/games/InviteBanners.kt:60-166`. Visuals:
  48 dp art tile (runtime lookup `game_<slug>`, glyph fallback), title line, subtitle
  (`game · overs · m:ss left`), a "Play" capsule for live invites, an ✕ for dead ones. Uses the
  design-system tokens (`VoiidColor`/`VoiidSpacing`/`VoiidRadius`/`VoiidFont` — defined in
  `apps/ios/Voiid/Voiid/DesignSystem/Theme.swift` and
  `apps/android/app/src/main/java/com/voiid/app/ui/theme/Color.kt`).
- Data source: a **20-second poll** of `GET /games/invites` while the Games tab is open —
  iOS `apps/ios/Voiid/Voiid/Games/GamesHomeView.swift:265-270`, Android
  `apps/android/app/src/main/java/com/voiid/app/main/games/GamesHomeScreen.kt:110-115`. There is
  no socket/push delivery to this surface (comment at `GamesHomeView.swift:57-59`).
- `GET /games/invites` (`games.ts:167-224`) returns per invite:
  `inviter_id`, and `inviter_name = users.full_name ?? users.username ?? null`
  (:184, :216). Live vs missed is derived server-side from `created_at` against a 10-minute TTL
  (:165, :219).
- Client models: iOS `GamesAPI.PendingInvite` (`apps/ios/Voiid/Voiid/Networking/GamesAPI.swift:100-115`),
  Android `GamesService.PendingInvite`
  (`apps/android/app/src/main/java/com/voiid/app/net/GamesService.kt:100-114`).
- Banner title today: `"\(invite.inviter_name ?? "A friend") wants to play"`
  (`InviteBanner.swift:51-52`) / `"${invite.inviter_name ?: "A friend"} wants to play"`
  (`InviteBanners.kt:121`). **`inviter_id` is carried but never used on either platform.**
- Tap actions: tapping the live banner or "Play" opens the match board directly
  (`GamesHomeView.swift:108-121` — `openMatch`, which routes to the per-slug renderer at :156-183);
  dismissing a dead banner calls `POST /games/matches/:id/decline`
  (`GamesHomeView.swift:114-120`, `GamesHomeScreen.kt:156-166`, backend `games.ts:233-260`).
  A **live** banner has no decline affordance — only "Play" (`InviteBanner.swift:63-80`,
  `InviteBanners.kt:141-164`).

### 1.3 The transcript bubble

- `GameInviteBubble`: iOS `apps/ios/Voiid/Voiid/Main/ChatDetailView.swift:1415-1500`, Android
  `apps/android/app/src/main/java/com/voiid/app/main/ChatUI.kt:663-794`. 16:9 art card,
  "GAME INVITE" eyebrow, game name, `detailLine()`, a `"from \(meta.from)"` line for inbound
  invites (`ChatDetailView.swift:1469-1473`, `ChatUI.kt:760-766`), and one button:
  "Tap to play" / "Open lobby" / "Invite expired" (`ChatDetailView.swift:1475-1491`,
  `ChatUI.kt:768-791`). Tap posts `.voiidOpenGameMatch` (iOS) or
  `DeepLinkRouter.openGameMatch` (Android); `GamesHomeView.swift:287-291` receives it.

### 1.4 The backgrounded / killed-app path

- The push is a content-free wake (`data: {type:"wake", message_id, conversation_id}`).
- **Android**: `VoiidMessagingService.onMessageReceived`
  (`apps/android/app/src/main/java/com/voiid/app/net/VoiidMessagingService.kt:56-146`) fetches +
  decrypts via the real `ChatEngine.sync` path (:163-220). Title precedence: address book first —
  `UserDirectory.displayName(peerUserId, fallback = p.title)` (:209-212). Body: if the decrypted
  text parses as an invite, `gameInviteBody` renders "🎮 Invited you to <game> · <details>", or
  "Game invite expired" past TTL (:234-242). Tap deep-links to the **conversation**
  (`Notifier.postMessage` intent extra `EXTRA_CONVERSATION_ID`, :294-303) — not the game.
- **iOS**: the NSE (`apps/ios/Voiid/VoiidNSE/NotificationService.swift:35-65`) calls
  `ChatEngine.notificationDecrypt`
  (`apps/ios/Voiid/Voiid/Networking/ChatEngine.swift:649-700`): title from
  `senderName` → `SharedDirectory.displayName(senderId, fallback: server full_name)`
  (:736-739, `apps/ios/Voiid/Voiid/Networking/SharedStore.swift:93-114` — saved_name →
  full_name → phone_e164 → username → fallback → "Unknown"); body from
  `GameInvite.notificationBody` (:690-695, `GameInvite.swift:144-153`). Tap →
  `AppDelegate.didReceive` deep-links to the conversation via the non-secret `conversation_id`
  (`apps/ios/Voiid/Voiid/VoiidApp.swift:69-105`).
- So the killed-app path already shows the **saved contact name** in the title (correct), and the
  tap lands in the chat, where the bubble's "Tap to play" joins the match.

### 1.5 Identity-resolution machinery (the chain the banner should use)

- Android `UserDirectory`
  (`apps/android/app/src/main/java/com/voiid/app/store/UserDirectory.kt:37-119`; precedence
  documented at :24-30, implemented by `UserRow.displayName()` at :273-279):
  **saved_name → full_name → phone_e164 → username → "Unknown"**, with `displayName(id, fallback)`
  at :101-106 refusing a fallback equal to the raw id.
- iOS `UserDirectory` (`apps/ios/Voiid/Voiid/Storage/UserDirectory.swift:33-101`) — identical
  precedence (:14-20, :59-66); NSE-safe mirror `SharedDirectory` (`SharedStore.swift:73-114`).
- The reachability privacy model (`backend/api/src/routes/reachability.ts:1-12, 92-137`): profile
  `full_name`/`username`/`photo_url` are what a peer may legitimately see; the server never
  returns raw phone numbers to peers — `phone_e164` in the directory exists only when *this
  device's* address book supplied it (`UserDirectory.kt:122-134`).

---

## 2. What is broken or weak

1. **The banner ignores the saved contact name.** Both platforms print the server's
   `inviter_name` — the inviter's self-chosen profile `full_name` (else `username`,
   `games.ts:216`) — even when the invitee has them saved as "Mum". `inviter_id` is available in
   the payload (`GamesAPI.swift:107`, `GamesService.kt:108`) and both platforms own a documented
   one-true-resolver, but neither `InviteBanner.swift:52` nor `InviteBanners.kt:121` consults it.
   This violates the app's own stated invariant ("If you saved them as 'Mum', every screen says
   'Mum'" — `UserDirectory.swift:15-16`, `UserDirectory.kt:25-26`) and is inconsistent with the
   push notification for the same invite, which *does* resolve through the directory
   (`VoiidMessagingService.kt:209-212`, `ChatEngine.swift:736-739`). Root cause: the banner was
   built off the server payload alone.

2. **`POST /games/matches` has no relationship gate on `opponent_ids`.** The route validates
   UUID shape only (`games.ts:72-74`) and never checks a conversation, contact link, or the
   reachability model. Any authenticated user who learns (or guesses at scale) a victim's user id
   can mint `waiting` matches naming them, and `GET /games/invites` (keyed only on
   `player_ids @> [me]`, `games.ts:188-197`) will surface a banner **carrying the stranger's
   `full_name`/`username`** — bypassing the mutual-contact/PIN gates that ordinary messages must
   pass (`reachability.ts:1-12`). The E2EE invite *message* would fail without a session, but the
   banner is driven purely by the match row. This is both a spam vector and a quiet crack in the
   reachability model.

3. **The bubble's "from X" line trusts the sender-asserted name.** `meta.from` is written by the
   sender (`GamesEngine.swift:469-475`) and rendered verbatim to the invitee
   (`ChatDetailView.swift:1469-1473`, `ChatUI.kt:760-766`). The invitee's saved name never wins,
   and a modified client can put any string there. The authenticated sender id
   (`message.senderId`) is in hand at both call sites and is what the notification path already
   uses.

4. **Sender-side "Unknown"/empty `from`.** `UserDirectory.displayName(myId, fallback: "")`
   returns `"Unknown"` when one's own row isn't in the directory yet (`UserDirectory.swift:94-101`;
   own row is only written on profile load/edit — `apps/android/.../model/Stores.kt:84-116`).
   `GameInvite.encode` only guards `isEmpty` (`GameInvite.swift:92`, `GameInvite.kt:97`), so the
   human line can read "🎮 Unknown invited you to Tic Tac Toe". *Hypothesis on frequency* (needs a
   fresh-install repro), but the code path plainly exists.

5. **No decline on a live invite, anywhere.** The live banner offers only "Play"
   (`InviteBanner.swift:63-80`, `InviteBanners.kt:141-164`); the bubble offers only
   "Tap to play" (`ChatDetailView.swift:1475-1491`, `ChatUI.kt:768-791`); the system notification
   has no action buttons (`Notifier.postMessage`, `VoiidMessagingService.kt:275-324`;
   `VoiidApp.swift:66` registers only a missed-call category). The decline endpoint exists and is
   idempotent (`games.ts:233-260`) — the invitee just can't reach it until the invite is dead.

6. **The banner only exists on the Games tab, fed by a 20 s poll.** An invite arriving while the
   user is elsewhere in the foreground app produces no in-app surface (the OS banner covers
   background; iOS foreground presentation is enabled via `willPresent`, `VoiidApp.swift:114`,
   Android posts a system notification even in foreground). Worst case on the tab itself is ~20 s
   of a 10-minute window (`GamesHomeView.swift:265-270`).

7. **iOS banner briefly renders the "Missed" state.** `@State private var remaining: Int64 = 0`
   (`InviteBanner.swift:28`) makes `dead == true` (:30) until `.task` (:88-94) runs after first
   render — a one-frame "Missed invite"/grey flash on live invites. Android seeds the countdown
   inside `remember` so it renders correctly on frame one (`InviteBanners.kt:73-75`).

8. **iOS `PendingInvite` decode fragility (known bug class).** Swift's synthesized `Decodable`
   ignores property default values — `overs`, `sent_at`, `expires_at`, `missed`
   (`GamesAPI.swift:106-112`) all **throw `keyNotFound` if the server ever omits them**, and one
   throw kills the whole invites fetch (silently: `try? await api.invites()` at
   `GamesHomeView.swift:267`). Today `games.ts:208-220` always emits every key, so this is latent,
   not live; Android's kotlinx model with defaults (`GamesService.kt:101-114`) tolerates absence.

---

## 3. How WhatsApp + Signal do it

- **Name precedence.** Signal-Android resolves every rendered name through one method,
  `Recipient.getDisplayName`
  (`/Users/devacc/Signal stack/Signal-Android/app/src/main/java/org/thoughtcrime/securesms/recipients/Recipient.kt:568-604`):
  nickname → **system contact name** → profile name → pretty-printed E.164 → email → username →
  localized "Unknown". The local address book beats the sender's self-chosen profile name, and the
  raw identifier is never shown. Voiid's `UserDirectory` order (saved → full_name → phone →
  username → "Unknown") is the same shape; the defect is only that the games banner bypasses it.
- **Sender identity is never taken from message content.** Signal attributes a message to the
  authenticated sender (the envelope's sourceServiceId) and resolves the display name from the
  local recipient store at render time; a display name embedded in a payload is treated as a
  *profile* record to be stored, not a string to render as attribution. Voiid's own notification
  path follows this (server-asserted `sender_id` → local directory, `ChatEngine.swift:709-711`,
  `736-739`); the bubble's `meta.from` does not.
- **Content-free pushes, locally rewritten.** Signal-iOS's NSE and WhatsApp both receive a
  contentless push, decrypt on-device, and rewrite the banner with the locally-resolved contact
  name — exactly Voiid's `VoiidNSE/NotificationService.swift` + `VoiidMessagingService.kt`
  architecture. This part of Voiid is already Signal-grade; do not regress it (never put the
  inviter name or game in the push payload).
- **Who may make your phone buzz.** Signal gates unknown senders behind message requests —
  notifications from strangers are constrained and profile info is withheld until accept. The
  analog here: a games invite should only be creatable toward someone the reachability model says
  you can already message; Voiid has the model (`reachability.ts`) but the games route skips it.

---

## 4. Recommended fixes (ordered)

Each item is independently actionable.

### Fix 1 — Resolve the banner name through the local directory (both-mobile, high)
- **iOS** `apps/ios/Voiid/Voiid/Games/InviteBanner.swift:52`: replace
  `invite.inviter_name ?? "A friend"` with
  `UserDirectory.shared.displayName(invite.inviter_id ?? "", fallback: invite.inviter_name)`
  and treat the `"Unknown"` result as "Someone".
- **Android** `apps/android/app/src/main/java/com/voiid/app/main/games/InviteBanners.kt:121`:
  replace `invite.inviter_name ?: "A friend"` with
  `UserDirectory.displayName(invite.inviter_id.orEmpty(), fallback = invite.inviter_name)`
  (call `UserDirectory.init(context)` — idempotent — if needed).
- Resulting order: saved contact name → local full_name → local phone → local username →
  server-sent `full_name`/`username` → "Someone". Never the raw id. Risk: none — pure read.

### Fix 2 — Gate match creation on the reachability model (backend, high)
- `backend/api/src/routes/games.ts` `POST /matches` (:55-107): before inserting, verify each
  opponent shares an accepted `direct` conversation with the caller (both members
  `request_state = 'accepted'`, `left_at is null` — same shape as the idempotency query in
  `backend/api/src/routes/reachability.ts:208-217`). Reject with 403 otherwise. This closes the
  stranger-banner/enumeration vector and makes the `full_name` disclosure in
  `GET /games/invites` legitimate by construction (an accepted peer may already see it).
  Risk: low; the only legitimate client flow picks opponents from existing direct conversations
  (`GamesHomeView.swift:228-238`, OpponentPickerSheet), so nothing user-visible changes.

### Fix 3 — Add Decline to the live banner (both-mobile, medium)
- Add a secondary "Decline" affordance (ghost/borderless button beside the "Play" capsule) to the
  live state: `InviteBanner.swift:63-80` and `InviteBanners.kt:141-164`, wired to the existing
  dismiss closures (`GamesHomeView.swift:114-120`, `GamesHomeScreen.kt:160-165`) which already
  call `POST /games/matches/:id/decline`. Backend needs nothing (`games.ts:233-260` is
  idempotent). Risk: none.

### Fix 4 — Attribute the bubble's "from" line to the authenticated sender (both-mobile, medium)
- **iOS** `apps/ios/Voiid/Voiid/Main/ChatDetailView.swift:1469-1473`: render
  `UserDirectory.shared.displayName(message.senderId, fallback: invite.meta?.from)` instead of
  `meta.from` directly.
- **Android** `apps/android/app/src/main/java/com/voiid/app/main/ChatUI.kt:760-766`: same via
  `UserDirectory.displayName(message.senderId, fallback = meta.from)`.
- Keep `meta.from` in the wire format for old clients and the pre-marker human line. Risk: none.

### Fix 5 — Stop encoding "Unknown" as the sender name (both-mobile, medium)
- **iOS** `apps/ios/Voiid/Voiid/Networking/GamesEngine.swift:469-475` and **Android**
  `apps/android/app/src/main/java/com/voiid/app/net/GamesEngine.kt:495-503`: after resolving own
  name, map `"Unknown"` to `""` so `GameInvite.encode`'s existing `isEmpty` guard
  (`GameInvite.swift:92`, `GameInvite.kt:97`) produces "Someone invited you…" instead of
  "Unknown invited you…". Optionally prefer the session profile store's own full name over the
  directory row. Risk: none.

### Fix 6 — Kill the iOS first-frame "Missed" flash (ios, low)
- `apps/ios/Voiid/Voiid/Games/InviteBanner.swift:28-30`: initialize `remaining` from the invite
  (`_remaining = State(initialValue: max(0, invite.expires_at - GameInvite.nowMs()))` in an
  `init`), or compute `dead` as `invite.missed || invite.expires_at <= GameInvite.nowMs()`
  independent of `@State`. Mirrors Android `InviteBanners.kt:73-75`. Risk: none.

### Fix 7 — Harden iOS `PendingInvite` decoding (ios, low)
- `apps/ios/Voiid/Voiid/Networking/GamesAPI.swift:100-115`: defaults on `var` properties do NOT
  apply during synthesized decode — give `overs`, `sent_at`, `expires_at`, `missed` a custom
  `init(from:)` using `decodeIfPresent` with the current defaults (or make them optionals with
  computed accessors), so one omitted key can't zero out the whole invites poll (which is
  swallowed by `try?` at `GamesHomeView.swift:267`). Risk: none.

### Fix 8 — Banner design spec (both-mobile, design, medium)
Target visual (stays within existing tokens `VoiidColor` / `VoiidSpacing` / `VoiidRadius` /
`VoiidFont`; files: `InviteBanner.swift`, `InviteBanners.kt`):
- **Live**: `surfaceCard` base with a `primary`-tinted left accent or 0.12-alpha fill (as today),
  48 pt game-art tile, **inviter avatar** (from `UserDirectory.photoURL(inviter_id)` /
  `UserDirectory.photoUrl`, initials fallback) overlapping the art tile's corner; title
  `"<resolved name> wants to play"` (rounded 14 semibold); subtitle
  `"<game> · <settings> · <m:ss> left"` (rounded 12, `textSecondary`); trailing **Play** capsule
  (`primary` fill, `textOnPrimary`) plus **Decline** ghost button (Fix 3). Countdown may tint
  toward the warning color under 60 s.
- **Missed**: flat `surfaceCard`, "Missed invite · <game> · from <resolved name>", single ✕.
- The name may show: saved contact name, profile full name, @username — in that order. A phone
  number appears only if it came from *this device's* address book (`UserDirectory.kt:122-134`);
  the server never supplies numbers, and with Fix 2 every inviter is an accepted peer, so
  profile-name visibility conforms to the reachability model (`reachability.ts:92-137`).
- **Killed-app path stays as is architecturally** (content-free push → local decrypt → local
  name): tap continues to open the conversation, where the bubble joins the match. Optionally add
  a "Play" `UNNotificationAction` / Android action button carrying only the non-secret
  `match_id`+`slug` (the server already knows both — no new leak), registered next to the
  missed-call category (`VoiidApp.swift:66`) and in `Notifier.postMessage`
  (`VoiidMessagingService.kt:275-324`).

### Fix 9 — (Optional) push the invite to the Games tab faster (both-mobile, low)
- The 20 s poll (`GamesHomeView.swift:265-270`, `GamesHomeScreen.kt:110-115`) can miss ~3% of a
  10-minute window; if invites feel laggy, refresh the invites list when a just-received chat
  message parses as an invite (both ChatEngines already parse invites for notification bodies),
  rather than adding a new delivery path.
