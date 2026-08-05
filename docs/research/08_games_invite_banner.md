# Game-invite notification banner — design, name resolution, and delivery paths

Researched 2026-08-05 against the live tree at `/Users/devacc/Voiid`. Every claim cites file:line
and was read directly. Hypotheses are marked as such.

---

## 1. What exists today

### 1.1 How an invite is born and travels

`POST /games/matches` mints the match row and **deliberately sends no notification**
(`backend/api/src/routes/games.ts:55-107`); the docblock at :46-54 states the client sends the
invite itself over the message pipe, so the wake/push path is not duplicated. The router's header
comment (:14-17) restates the E2EE exception: game *state* is server-readable because the server
referees, but the *invite* is an ordinary E2EE message this router never sees.

The client then sends an ordinary **E2EE text message** whose body carries two marker lines
(`voiid:game/<slug>/<matchId>` and `voiid:gamemeta/<JSON>`):

- iOS `apps/ios/Voiid/Voiid/Networking/GamesEngine.swift:440-486`
- Android `apps/android/app/src/main/java/com/voiid/app/net/GamesEngine.kt:479-518`

The wire format lives in `apps/ios/Voiid/Voiid/Networking/GameInvite.swift:32-154` and
`apps/android/app/src/main/java/com/voiid/app/net/GameInvite.kt:32-141`. The embedded `Meta.from`
— the name the poster bubble prints on its "from X" line — is chosen **by the sender**, resolved
from the sender's *own* directory row: `GamesEngine.swift:469-475`
(`UserDirectory.shared.displayName(myId, fallback: "")`) and `GamesEngine.kt:495-503`.

Android's meta serializer sets `encodeDefaults = true` explicitly (`GameInvite.kt:40`), so the
known kotlinx `encodeDefaults=false` bug class — which previously broke receipts and stories — is
already defended against here. Verified: without it, `from=""`, `overs=0` and `sentAt=0` would be
omitted and the iOS decoder would see an object missing those keys.

### 1.2 The in-app banner (Games tab only)

The banner component is iOS `apps/ios/Voiid/Voiid/Games/InviteBanner.swift:21-106` and Android
`apps/android/app/src/main/java/com/voiid/app/main/games/InviteBanners.kt:60-166`. Both render a
48 pt/dp art tile (runtime lookup of `game_<slug>`, glyph fallback —
`InviteBanner.swift:34-48`, `InviteBanners.kt:97-117`), a title line, a subtitle
(`game · N overs · m:ss left`), a "Play" capsule for live invites, and an ✕ for dead ones.

The two-state design is deliberate and documented identically on both platforms
(`InviteBanner.swift:7-14`, `InviteBanners.kt:49-57`): a LIVE invite is actionable and carries a
countdown; a MISSED one is information, dismissed once seen. The countdown is recomputed from the
**server's** `expires_at` rather than a local duration, so a skewed device clock still agrees with
the backend (`InviteBanner.swift:26-28`, `InviteBanners.kt:71-75`).

Data source is a **20-second poll** of `GET /games/invites` while the Games tab is open — iOS
`GamesHomeView.swift:265-270`, Android `GamesHomeScreen.kt:109-115`. There is no socket or push
delivery to this surface; the rationale is recorded at `GamesHomeView.swift:57-59` ("the games
surface has no socket subscription of its own — a 20s poll while this tab is open is cheaper than
inventing a second delivery path for a banner").

`GET /games/invites` (`games.ts:167-224`) returns per invite: `match_id`, `slug`, `name`,
`icon_key`, `overs` (lifted out of the options bag at :207-213), `options`, `inviter_id`
(= `created_by`, :215), `inviter_name` = `users.full_name ?? users.username ?? null` (:184, :216),
`sent_at`, `expires_at`, and `missed`. Live-vs-missed is derived server-side from `created_at`
against a 10-minute TTL (:165, :219) so no background job has to age rows out. The query excludes
matches the caller created (:193) and filters on `player_ids @> [me]` (:194).

Client models: iOS `GamesAPI.PendingInvite` (`apps/ios/Voiid/Voiid/Networking/GamesAPI.swift:99-115`),
Android `GamesService.PendingInvite` (`apps/android/app/src/main/java/com/voiid/app/net/GamesService.kt:99-114`).

**Banner title today**: `"\(invite.inviter_name ?? "A friend") wants to play"`
(`InviteBanner.swift:51-52`) and `"${invite.inviter_name ?: "A friend"} wants to play"`
(`InviteBanners.kt:121`). **`inviter_id` is carried in the payload but never used on either
platform.**

Tap actions: tapping the live banner body or the "Play" capsule accepts. On iOS this sets
`openMatch` directly (`GamesHomeView.swift:108-113`), routed to the per-slug renderer at
`GamesHomeView.swift:155-183`. On Android it goes through `onAcceptInvite`
(`GamesHomeScreen.kt:159`), wired in `RootTabView.kt:265-272` to
`DeepLinkRouter.openGameMatch(match_id, slug)` — the same seam the chat bubble uses
(`DeepLinkRouter.kt:43-49`). Dismissing a dead banner marks it locally then calls
`POST /games/matches/:id/decline` (`GamesHomeView.swift:114-121`, `GamesHomeScreen.kt:160-166`,
backend `games.ts:233-260`, which is idempotent and only acts on a `waiting` row, :252-257).
A **live** banner has no decline affordance at all — only "Play" (`InviteBanner.swift:63-80`,
`InviteBanners.kt:141-164`).

### 1.3 The transcript bubble

`GameInviteBubble`: iOS `apps/ios/Voiid/Voiid/Main/ChatDetailView.swift:1415-1499`, Android
`apps/android/app/src/main/java/com/voiid/app/main/ChatUI.kt:663-793`. A 16:9 art card with a
legibility gradient, an "Expired" scrim, a "GAME INVITE" eyebrow, the game name, `detailLine()`,
a `"from <meta.from>"` line for inbound invites (`ChatDetailView.swift:1469-1473`,
`ChatUI.kt:764-770`), and one button: "Tap to play" / "Open lobby" / "Invite expired"
(`ChatDetailView.swift:1475-1491`, `ChatUI.kt:772-791`). Tap posts `.voiidOpenGameMatch` (iOS,
received at `GamesHomeView.swift:287-291`) or `DeepLinkRouter.openGameMatch` (Android).

### 1.4 The backgrounded / killed-app path

The push is a content-free wake (`data: {type:"wake", conversation_id, message_id}`).

**Android**: `VoiidMessagingService.onMessageReceived` (`net/VoiidMessagingService.kt:56-146`)
branches on `type`, and for `"wake"` (:117) does a bounded synchronous fetch+decrypt through the
real `ChatEngine` path (:121-145, helper at :195-220). Title precedence puts the address book
first: `UserDirectory.displayName(peerUserId, fallback = p.title)` (:207-212, with the comment
"the address-book name wins over the name the sender chose for themselves, so a notification says
'Mum' too"). Body: if the decrypted text parses as an invite, `gameInviteBody` (:222-242) renders
"🎮 Invited you to \<game\> · \<details\>", or "Game invite expired" past TTL. Tap deep-links to
the **conversation** via `EXTRA_CONVERSATION_ID` (`Notifier.postMessage`, :275-324, intent at
:293-303) — not to the game board.

**iOS**: the NSE (`apps/ios/Voiid/VoiidNSE/NotificationService.swift`) calls
`ChatEngine.notificationDecrypt` (`Networking/ChatEngine.swift:643-701`). Title comes from
`senderName(msg.senderId, members:)` (:686, :736-739) → `SharedDirectory.displayName(senderId,
fallback: serverFullName)` (`Networking/SharedStore.swift:73-114`), whose precedence is documented
at :70-72 as saved_name → full_name → phone_e164 → username → caller's fallback → "Unknown", and
which uses GRDB's NULL-tolerant subscript so a NULL column cannot trap the extension (:104-107).
Body comes from `GameInvite.notificationBody` (`ChatEngine.swift:689-695`,
`GameInvite.swift:144-153`). Tap → `AppDelegate.userNotificationCenter(_:didReceive:)`
deep-links to the conversation via the non-secret `conversation_id`
(`apps/ios/Voiid/Voiid/VoiidApp.swift:69-110`); foreground arrivals still present a banner
(`VoiidApp.swift:113-119`).

**So the killed-app path already shows the saved contact name in the title** — it is the in-app
banner that does not. Tap lands in the chat, where the bubble's "Tap to play" joins the match.

### 1.5 Identity-resolution machinery (the chain the banner should use)

Android `UserDirectory` (`apps/android/app/src/main/java/com/voiid/app/store/UserDirectory.kt:37-119`)
documents the precedence at :24-30 and implements it in `UserRow.displayName()` at :273-279:

> **saved_name → full_name → phone_e164 → username → "Unknown"** — never a raw user id.

`displayName(id, fallback)` at :101-106 applies the row's chain first, then a caller fallback, and
**refuses a fallback equal to the raw id** (:104) — "that is exactly the bug being fixed".
`init(context)` is idempotent and safe from any entry point (:55-65); `ready(context)` additionally
waits for the first load, for cold push processes (:72-75). `photoUrl(userId)` exists at :108.

iOS `UserDirectory` (`apps/ios/Voiid/Voiid/Storage/UserDirectory.swift:69-140`) is identical:
precedence documented at :14-20, implemented in `DirectoryUser.displayName` at :58-66, and
`displayName(_:fallback:)` at :94-101 with the same id-equality guard (:97). It is `@MainActor`
and its in-memory mirror makes it safe to call synchronously inside a SwiftUI `body` (:75-87).
`photoURL(_:)` is at :103. The NSE-safe mirror is `SharedDirectory` (`SharedStore.swift:73-114`).

Writes are column-scoped on both platforms so a server profile refresh can never clobber the
address-book name and vice versa (`UserDirectory.swift:141-146` + the `COALESCE` upserts at
:155-239; `UserDirectory.kt:215-264`).

**Reachability privacy model** (`backend/api/src/routes/reachability.ts:1-12`): mutual contacts
chat directly; a one-way contact arrives as a request; someone found by @username must present a
6-digit PIN. The username-resolution endpoint (:92-137) returns `full_name`, `photo_url`,
`username` and `bio` — and **explicitly never a phone number**, because "a stranger who knows
@nehal must not be able to reach a phone number" (:95-99). Membership state lives in
`conversation_members.request_state ∈ ('pending','accepted','declined')`
(`database/migrations/020_reachability.sql:47-55`).

Consequently `phone_e164` in the local directory exists **only** when *this device's* address book
supplied it — the backend matches contacts by SHA-256 hash and never returns raw numbers
(`UserDirectory.kt:121-134`, and iOS writes it only from `upsertFromAddressBook`,
`UserDirectory.swift:148-168`).

---

## 2. What is broken or weak

### 2.1 The banner ignores the saved contact name (the headline defect)

Both platforms print the server's `inviter_name`, which is the inviter's *self-chosen* profile
`full_name` (else `username`, `games.ts:216`) — even when the invitee has that person saved as
"Mum". `inviter_id` is right there in the payload (`GamesAPI.swift:107`, `GamesService.kt:108`) and
both platforms own a documented one-true-resolver, but neither `InviteBanner.swift:51-52` nor
`InviteBanners.kt:121` consults it.

Root cause: the banner was built off the server payload alone, never wired to `UserDirectory`.

This violates the app's own stated invariant — "If you saved them as 'Mum', every screen says
'Mum', whatever they call themselves" (`UserDirectory.swift:15-16`, `UserDirectory.kt:25-26`) — and
it is *internally inconsistent*: the push notification for the very same invite does resolve
through the directory (`VoiidMessagingService.kt:207-212`, `ChatEngine.swift:736-739`). A user
backgrounded sees "Mum"; the same user with the Games tab open sees "Priya Sharma".

### 2.2 `POST /games/matches` has no relationship gate on `opponent_ids`

The route validates UUID shape and self-exclusion only (`games.ts:72-74`) and then checks the
catalog's seat count (:83-96). It never checks a conversation, a contact link, or the reachability
model. Any authenticated user who learns a victim's user id can mint `waiting` matches naming
them, and `GET /games/invites` — keyed only on `player_ids @> [me]` (:194) — will surface a banner
**carrying the stranger's `full_name`/`username`** (:216), bypassing the mutual-contact/PIN gates
that ordinary messages must pass (`reachability.ts:1-12`).

The E2EE invite *message* would fail without a session, so the stranger cannot get a chat bubble
through — but the banner is driven purely by the match row, so the banner appears anyway. That is
both a spam vector and a quiet crack in the reachability model: profile-name disclosure to someone
who has not passed any gate.

### 2.3 The bubble's "from X" line trusts a sender-asserted string

`meta.from` is written by the sender (`GamesEngine.swift:469-475`, `GamesEngine.kt:495-503`) and
rendered verbatim to the invitee (`ChatDetailView.swift:1469-1473`, `ChatUI.kt:764-770`). The
invitee's saved name never wins, and a modified client can put any string there — including
another person's name. The authenticated sender id is in hand at both call sites
(`message.senderId`: `Models.swift:59`, `Models.kt:56`) and is exactly what the notification path
already keys on.

### 2.4 Sender-side "Unknown" leaks into the human line

`UserDirectory.displayName(myId, fallback: "")` returns the literal `"Unknown"` when one's own row
is not in the directory yet (`UserDirectory.swift:94-101`, `UserDirectory.kt:101-106` — an empty
fallback is rejected at :104, so the chain falls through to "Unknown"). `GameInvite.encode` only
guards `isEmpty`/`isBlank` (`GameInvite.swift:92`, `GameInvite.kt:97`), so the human first line can
read "🎮 Unknown invited you to Tic Tac Toe", and the bubble's "from Unknown" follows.

*Hypothesis on frequency* (needs a fresh-install repro to quantify): the own-row is written by the
profile load/edit path, so the window is a fresh install that sends an invite before a profile
fetch lands. The code path plainly exists regardless.

### 2.5 No decline on a live invite, anywhere

The live banner offers only "Play" (`InviteBanner.swift:71-80`, `InviteBanners.kt:152-164`); the
bubble offers only "Tap to play" (`ChatDetailView.swift:1475-1491`, `ChatUI.kt:772-791`); the
system notification carries no action buttons (`Notifier.postMessage`,
`VoiidMessagingService.kt:275-324` builds no `addAction`; `VoiidApp.swift:58-67` registers only the
missed-call category). The decline endpoint exists and is idempotent (`games.ts:233-260`) — the
invitee simply cannot reach it until the invite is already dead.

### 2.6 The banner exists only on the Games tab, fed by a 20 s poll

An invite arriving while the user is in the foreground app but on another tab produces no in-app
surface at all. Background is covered by the OS banner; iOS foreground presentation is enabled
(`VoiidApp.swift:113-119`) and Android posts a system notification regardless. Worst case on the
tab itself is ~20 s of a 10-minute window (`GamesHomeView.swift:265-270`,
`GamesHomeScreen.kt:109-115`) — tolerable, but it is why an invite can feel "late".

### 2.7 iOS banner briefly renders the "Missed" state (one-frame flash)

`@State private var remaining: Int64 = 0` (`InviteBanner.swift:28`) makes `dead == true`
(:30) until `.task` (:88-94) runs *after* first render — so a live invite flashes the grey
"Missed invite" treatment for a frame. Android seeds the countdown inside `remember` and therefore
renders correctly on frame one (`InviteBanners.kt:73-75`). A genuine cross-platform divergence.

### 2.8 iOS `PendingInvite` decode fragility (known bug class)

Swift's synthesized `Decodable` ignores property default values, so `overs`, `sent_at`,
`expires_at` and `missed` (`GamesAPI.swift:105-112`) all **throw `keyNotFound` if the server ever
omits them** — and one throw kills the whole invites fetch *silently*, because the poll swallows it
with `try?` (`GamesHomeView.swift:267`). Today `games.ts:208-220` always emits every key, so this
is latent rather than live. Android's kotlinx model with defaults (`GamesService.kt:100-114`)
tolerates absence, so the platforms would fail asymmetrically.

### 2.9 Android's banner bypasses the typography token (new finding)

`InviteBanners.kt` contains **zero** references to `VoiidFont` — it sets raw `fontSize = 14.sp` /
`12.sp` / `13.sp` with `FontWeight` (:120-138, :153-157). iOS uses `VoiidFont.rounded(14, .semibold)`
etc. (`InviteBanner.swift:53, 57, 74`). `VoiidFont.rounded` on Android is the Nunito family
(`apps/android/app/src/main/java/com/voiid/app/ui/theme/Type.kt:43-46`), so the Android banner
renders in the *system* font while every iOS surface and most Android surfaces render in Nunito.
Same class of drift affects the surrounding `GamesHomeScreen.kt`. Colors and spacing *are*
tokenized on both (`VoiidColor`/`VoiidSpacing`/`VoiidRadius`, `InviteBanners.kt:41-43`).

### 2.10 There is no avatar component that can show a person (constraint, not a bug)

`VoiidAvatar` on both platforms is a **placeholder-only** component: Android
`ui/components/Components.kt:198-219` draws a "voiid" wordmark on `fieldFill` and takes only a
`size`; iOS `DesignSystem/Components.swift:156` is its counterpart. Neither accepts a photo URL or
initials. Any design that puts the inviter's face on the banner needs that component extended
first — noted here so the design spec below does not assume capability that does not exist.

---

## 3. How WhatsApp + Signal do it

**Name precedence — one resolver, address book wins.** Signal-Android resolves every rendered name
through `Recipient.getDisplayName` and its private `getNameFromLocalData`
(`/Users/devacc/Signal stack/Signal-Android/app/src/main/java/org/thoughtcrime/securesms/recipients/Recipient.kt:567-609`):
group name → **nickname** → **systemContactName** → profileName → pretty-printed E.164 → email,
then username, then a localized "Unknown" (:568-578). The local address book beats the sender's
self-chosen profile name, the username is a *last* resort, and the raw identifier is never shown.
Voiid's `UserDirectory` order (saved → full_name → phone → username → "Unknown") is the same shape
and the same intent — the defect is only that the games banner bypasses it.

**Sender identity is never taken from message content.** Signal attributes a message to the
authenticated sender from the envelope and resolves the display name from the local recipient
store at render time; a display name that arrives inside a payload is treated as a *profile record
to be stored*, not a string to render as attribution. Voiid's own notification path already follows
this (server-asserted sender id → local directory, `ChatEngine.swift:736-739`,
`VoiidMessagingService.kt:207-212`); the games bubble's `meta.from` does not (§2.3). Voiid's group
path is honest about the residual limit of this in its own comment (`ChatEngine.swift:710-714`).

**Content-free pushes, locally rewritten.** Signal-iOS's NSE and WhatsApp both receive a
contentless push, decrypt on-device, and rewrite the banner with the locally-resolved contact name.
That is exactly Voiid's `VoiidNSE/NotificationService.swift` + `VoiidMessagingService.kt`
architecture, and the reasoning is written into both files
(`GameInvite.swift:139-143`, `VoiidMessagingService.kt:222-233`: "the only string Google's servers
ever saw was 'New message'"). **This part of Voiid is already Signal-grade — do not regress it.**
Never move the inviter name or the game into the push payload.

**Who may make your phone buzz.** Signal gates unknown senders behind message requests:
notifications from strangers are constrained, and profile information is withheld until accept.
The analog here is that a game invite should only be creatable toward someone the reachability
model already says you can message. Voiid has the model (`reachability.ts`) — the games route just
skips it (§2.2).

---

## 4. Recommended fixes (ordered)

Each item is independently actionable.

### Fix 1 — Resolve the banner name through the local directory (both-mobile, high)

- **iOS** `apps/ios/Voiid/Voiid/Games/InviteBanner.swift:51-52`: replace
  `invite.inviter_name ?? "A friend"` with a resolved name —
  `UserDirectory.shared.displayName(invite.inviter_id ?? "", fallback: invite.inviter_name)` —
  and map a `"Unknown"` result to `"Someone"` so the banner never prints the sentinel.
  `UserDirectory` is `@MainActor` with a synchronous in-memory mirror, so this is legal directly in
  the SwiftUI `body` (`UserDirectory.swift:75-87`).
- **Android** `apps/android/app/src/main/java/com/voiid/app/main/games/InviteBanners.kt:121`:
  replace `invite.inviter_name ?: "A friend"` with
  `UserDirectory.displayName(invite.inviter_id.orEmpty(), fallback = invite.inviter_name)`, mapping
  `"Unknown"` to `"Someone"`. Call `UserDirectory.init(LocalContext.current)` — idempotent
  (`UserDirectory.kt:55-65`) — if the composable cannot assume it is initialized.

Resulting order: **saved contact name → local full_name → local phone → local username →
server-sent full_name/username → "Someone"**, and never the raw id (the fallback-equals-id guard at
`UserDirectory.swift:97` / `UserDirectory.kt:104` covers that). Risk: none — pure local read.

### Fix 2 — Gate match creation on the reachability model (backend, high)

In `backend/api/src/routes/games.ts`, `POST /matches` (:55-107): before the insert at :98, verify
each id in `opponents` shares an accepted `direct` conversation with the caller — both members
`request_state = 'accepted'` and `left_at is null`, the same join shape as the idempotency query in
`backend/api/src/routes/reachability.ts:208-217`, plus the `request_state` filter that query omits.
Reject with 403 otherwise.

This closes the stranger-banner / id-enumeration vector and makes the `full_name` disclosure in
`GET /games/invites:216` legitimate by construction: an accepted peer may already see that field.
Risk: low. The only legitimate client flow picks opponents from existing direct conversations
(`GamesHomeView.swift:228-238` and `OpponentPickerSheet`), so nothing user-visible changes. Solo
matches are unaffected because `opponents` is empty for them (Snake practice, `games.ts:76-82`).

### Fix 3 — Add Decline to the live banner (both-mobile, medium)

Add a secondary "Decline" affordance beside the "Play" capsule in the live state:
`InviteBanner.swift:71-80` and `InviteBanners.kt:152-164`, wired to the **existing** dismiss
closures (`GamesHomeView.swift:114-121`, `GamesHomeScreen.kt:160-166`), which already mark the id
locally and call `POST /games/matches/:id/decline`. Backend needs nothing — `games.ts:233-260` is
idempotent and only acts on a `waiting` row. Risk: none.

### Fix 4 — Attribute the bubble's "from" line to the authenticated sender (both-mobile, medium)

- **iOS** `apps/ios/Voiid/Voiid/Main/ChatDetailView.swift:1469-1473`: render
  `UserDirectory.shared.displayName(message.senderId, fallback: invite.meta?.from)` instead of
  `meta.from` verbatim. `senderId` is on `VMessage` (`Models/Models.swift:59`).
- **Android** `apps/android/app/src/main/java/com/voiid/app/main/ChatUI.kt:764-770`: same, via
  `UserDirectory.displayName(message.senderId, fallback = meta.from)`. `senderId` is on `VMessage`
  (`model/Models.kt:56`).

Keep `meta.from` on the wire for old clients and for the pre-marker human line. Risk: none.

### Fix 5 — Stop encoding "Unknown" as the sender's name (both-mobile, medium)

In `apps/ios/Voiid/Voiid/Networking/GamesEngine.swift:469-475` and
`apps/android/app/src/main/java/com/voiid/app/net/GamesEngine.kt:495-503`, map a resolved
`"Unknown"` to `""` so `GameInvite.encode`'s existing empty-guard (`GameInvite.swift:92`,
`GameInvite.kt:97`) yields "Someone invited you to …" rather than "Unknown invited you to …".
Better still, prefer the session profile store's own full name before falling back to the directory
row. Risk: none.

### Fix 6 — Kill the iOS first-frame "Missed" flash (ios, low)

`apps/ios/Voiid/Voiid/Games/InviteBanner.swift:28-30`: either seed the state in an `init`
(`_remaining = State(initialValue: max(0, invite.expires_at - GameInvite.nowMs()))`) or compute
`dead` as `invite.missed || invite.expires_at <= GameInvite.nowMs()` so it does not depend on
`@State` having been populated. Mirrors Android's `remember` seeding at `InviteBanners.kt:73-75`.
Risk: none.

### Fix 7 — Harden iOS `PendingInvite` decoding (ios, low)

`apps/ios/Voiid/Voiid/Networking/GamesAPI.swift:99-115`: property defaults do **not** apply during
Swift's synthesized decode. Give `overs`, `sent_at`, `expires_at` and `missed` a custom
`init(from:)` using `decodeIfPresent` with the current defaults, so one omitted key cannot throw
away the entire invites poll — which is swallowed silently by `try?` at `GamesHomeView.swift:267`.
Risk: none.

### Fix 8 — Banner design spec (both-mobile, medium)

Target visual, staying inside the existing tokens (`VoiidColor`, `VoiidSpacing`, `VoiidRadius`,
`VoiidFont`); files `InviteBanner.swift` and `InviteBanners.kt`:

- **Live**: `VoiidColor.primary` at 0.12 alpha on a `VoiidRadius.lg` container (as today);
  48 pt/dp game-art tile; title `"<resolved name> wants to play"` at rounded 14 semibold in
  `textPrimary`; subtitle `"<game> · <settings> · <m:ss> left"` at rounded 12 in `textSecondary`;
  trailing **Play** capsule (`primary` fill, `textOnPrimary`) plus a **Decline** ghost button
  (Fix 3) in `textSecondary`. The countdown may shift to `VoiidColor.warning`
  (`Theme.swift:120`, `Color.kt:114`) under 60 s to make the deadline legible without adding
  motion.
- **Missed**: flat `surfaceCard`, `"Missed invite · <game> · from <resolved name>"`, single ✕.
- **Inviter avatar is optional and currently blocked**: `VoiidAvatar` is placeholder-only on both
  platforms (`ui/components/Components.kt:198-219`, `DesignSystem/Components.swift:156`) and takes
  no photo or initials. If a face is wanted on the banner, extend that component first rather than
  inlining an image loader in the banner.
- **Android must adopt `VoiidFont.rounded(...)`** in place of the raw `sp` sizes at
  `InviteBanners.kt:120-138, 153-157` (see Fix 9) or the two platforms will keep rendering the same
  banner in two different typefaces.
- **What the name may legitimately be**: saved contact name → profile full name → @username, in
  that order. A phone number appears only when *this device's* address book supplied it
  (`UserDirectory.kt:121-134`); the server never returns numbers to peers
  (`reachability.ts:95-99`). With Fix 2 every inviter is an accepted peer, so showing their profile
  name conforms to the reachability model by construction.
- **Killed-app path stays architecturally as is** — content-free push → local decrypt → locally
  resolved name (§1.4). Tap continues to open the conversation, where the bubble joins the match.
  Optionally add a "Play" action button carrying only the non-secret `match_id` + `slug` (the
  server already knows both, so no new leak), registered alongside the missed-call category at
  `VoiidApp.swift:58-67` and via `addAction` in `Notifier.postMessage`
  (`VoiidMessagingService.kt:275-324`). Never put the inviter name or game into the push payload.

### Fix 9 — Tokenize Android banner typography (android, low)

`apps/android/app/src/main/java/com/voiid/app/main/games/InviteBanners.kt:120-138, 153-157`:
replace `fontSize = 14.sp` + `fontWeight = …` with `style = VoiidFont.rounded(14, FontWeight.SemiBold)`
(and 12/13 likewise), importing `com.voiid.app.ui.theme.VoiidFont` (`ui/theme/Type.kt:43-46`).
The same drift exists in `GamesHomeScreen.kt` and can be swept in the same pass. Risk: none —
visual-only, and it moves Android *toward* the iOS rendering.

### Fix 10 — (Optional) surface invites faster (both-mobile, low)

The 20 s poll (`GamesHomeView.swift:265-270`, `GamesHomeScreen.kt:109-115`) can lag a live invite
by up to 20 s of its 10-minute window. If that feels slow, refresh the invites list when a
just-received chat message parses as an invite — both ChatEngines already parse invites for
notification bodies (`ChatEngine.swift:689-695`, `VoiidMessagingService.kt:234-242`) — rather than
inventing a second delivery path for this surface. Risk: none.
