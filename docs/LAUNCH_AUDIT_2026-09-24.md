# Pre-launch audit — 24 September 2026

Module by module: what works, what is broken, what is pending, and what is worth adding before
launch. Checked against the code on `main` (`97aa317d` and the log fix after it), the live dev
server (`api-dev.voiid.app`, build `05941e32`) and its logs and database. Earlier audits this
builds on: `AUDIT-FINAL-REPORT.md` (6 Sep), `PENDING.md` (2 Sep),
`IOS_ANDROID_UI_PARITY_2026-09-23.md` (23 Sep). Where those still hold they are referenced,
not repeated.

**Legend:** 🔴 blocks launch · 🟠 fix before launch · 🟡 should do · 🟢 idea / improvement

---

## 0. The short version

| # | What | Why it matters | State |
|---|---|---|---|
| 🔴 1 | **Clip uploads and follows fail on the server** | A database trigger still writes to the old `creator_profiles` table. Every clip save and every follow errors out. No clip has ever been saved. | **Fixed, not deployed** — migration 093, committed locally (`97aa317d`). Dry-run on the live DB passed. |
| 🔴 2 | **No refunds for paid events** | Cancelling a paid event leaves tickets paid. No refund on any platform or in admin web. | Not built |
| 🔴 3 | **No crash reporting** | No Crashlytics or Sentry in either app. After launch, crashes would be invisible. | Not built |
| 🔴 4 | **Recovery PIN security (S04)** | A short PIN can be guessed offline. Open since the 6 Sep audit and marked a release gate. | Open |
| 🟠 5 | **Payments and KYC are in sandbox** | `CASHFREE_ENV=sandbox`. Production keys, DigiLocker switched on at Cashfree, and Easy Split are still to do. | Waiting on Cashfree |
| 🟠 6 | **Host approval needs DigiLocker** | `KYC_REQUIRE_AADHAAR` is unset, so Aadhaar is required. Until Cashfree enables DigiLocker, **no host can be approved**. | Config decision |
| 🟠 7 | **College-email joining can't send codes** | No SMTP settings on the server. | Needs SMTP credentials |
| 🟠 8 | **Android is behind on Clips** | None of the new recorder/editor/post flow, player or comments sheet; Puppy is still the old sticker; face filters are not recorded into Android video. | Not started |
| 🟠 9 | **Production server** | Only `api-dev` exists, running `NODE_ENV=development`. The E2E Networks production plan is not started. | Not started |
| 🟠 10 | **Database TLS is unverified** | Workers run with `VOIID_DB_TLS_INSECURE=1`: encrypted, but the certificate is not checked. | Needs the Supabase CA cert |

---

## 1. Clips

**Works (iOS, today):** the recorder in the Voiid Ui design (live camera, takes, speed, timer,
grid, 1× by default); the 3D Puppy lens (ARKit); the editor (text burned in, trim, filters,
cover from a frame or a photo, sound); the post screen (caption, per-clip comments, save to
Photos). Post returns at once; the tile shows Preparing → Uploading with the reason and Retry on
failure. Player with comments sheet, report comment, block. 2-minute cap on all three layers.

| | Item |
|---|---|
| 🔴 | Upload fix (migration 093) must be deployed — see §0. |
| 🟠 | **Android:** port the recorder, editor, post screen, player and comments sheet. Replace the dog sticker with a 3D lens (ARCore Augmented Faces). Record face filters into the video (CameraX 1.4 `OverlayEffect`). |
| 🟠 | **Test on device:** the new flow compiles but has not been walked end to end on a phone. Also check text placement on a sideways library video. |
| 🟡 | Requests with a non-UUID id (bots hitting `/…/index`) return **500** instead of 400. Validate ids at the route. |
| 🟡 | Uploads use a background *task* (a few minutes), not a background `URLSession`. A long upload on slow data can still be killed if the app is left. |
| 🟡 | The top rendition is uploaded twice (as baseline and as `_fhd`). About 30–50% extra data per post. Server-side change needed to reuse the baseline key. |
| 🟢 | Drafts (save an edit and finish later), music/sounds, auto-captions, view insights for creators, more 3D lenses (cat, bunny) built like Puppy. |

## 2. Chats and messaging

**Works:** E2EE 1:1 and groups, media, voice notes, location, polls, reactions, replies,
forwarding, message requests, safety numbers, linked devices, backups.

| | Item |
|---|---|
| 🔴 | **S04 recovery PIN** (from 6 Sep): short-PIN recovery is guessable offline. Needs a design change and independent review. |
| 🟠 | **25 MB limit + on-device compressor.** Today documents are capped at **50 MB** and photos/videos have **no cap**. Design ready in Voiid Ui (attach menu, compress sheet with estimates, trim for long videos, file bubble). To build: iOS (AVAssetExportSession / PDFKit), Android (Media3 Transformer), plus a server-side size check on `/media/presign-upload`. |
| 🟠 | **I01 / M04** (6 Sep): move chat persistence off the main actor and page history. Matters on long chats. |
| 🟡 | Android: message long-press popover, swipeable media viewer, pull-to-refresh (0 screens), swipe actions on chat rows. See the parity doc §2–3. |

## 3. Calls

| | Item |
|---|---|
| 🟠 | **R05:** conference seat admission is not serialized under the participant cap. |
| 🟠 | APNs logs show `BadDeviceToken` → sandbox retries. Fine for dev builds, but release builds need the production APNs environment and **Q03** (separate dev and release config). |
| 🟡 | The 6 Sep items R01/R03/R04 are implemented but not verified live across relay instances. |

## 4. Communities, events and payments

**Works:** 2-step create, discovery, join (open / request / invite / college email), posts,
moderation, roles, moderator badges, institutions and official communities from admin, host
threads, tournaments, invite links (mint and revoke now exist), paid events through Cashfree,
host KYC (PAN, bank or UPI, DigiLocker Aadhaar), the host panel and ticket wallet.

| | Item |
|---|---|
| 🔴 | **Refunds / order cancel.** `EventService` notes "nothing is refunded" on event cancel. Needed: a refund call to Cashfree, host and admin actions, and an attendee notice. |
| 🟠 | Cashfree production keys, DigiLocker + Easy Split enabled, pricing confirmed. |
| 🟠 | Decide `KYC_REQUIRE_AADHAAR` (see §0 #6). |
| 🟠 | SMTP for college email (Cloudflare Email, $5/mo, `smtp.mx.cloudflare.net:465`, or any provider). |
| 🟡 | Auto-approve strong KYC matches (name match + PAN valid + bank verified) to cut admin work. |
| 🟡 | `GET /events/:id` has no client, so a shared link to one event cannot open it. |
| 🟢 | Event reminders (push 1 day and 1 hour before), QR check-in from the host panel, waitlists for sold-out events. |

## 5. Moments (stories)

| | Item |
|---|---|
| 🟡 | Android: no story archive. |
| 🟡 | C04 (durable story deletion) is implemented but not verified. Story reaping failed on the server from 11 to 17 Sep (TLS); check nothing expired and was left behind. |

## 6. Map and location

| | Item |
|---|---|
| 🟡 | Android: no Move/travel mode, no map settings or notifications screens, no intro and privacy screens. |

## 7. Games

| | Item |
|---|---|
| 🟡 | Android: Carrom shows "Coming soon". |
| 🟡 | The games service logs many `stale durable match write rejected` sweeps. Harmless alone, but it is R06 (game ownership) showing: fix before running more than one games instance. |

## 8. Profile, settings, privacy

| | Item |
|---|---|
| 🟠 | **Account deletion** exists on both apps as an erasure *request* with a due date. Apple accepts this only if it really happens. The erasure worker was failing 11–17 Sep: check any requests from that week were completed, and add an alert if one passes its due date. |
| 🟡 | U05/U06: reduced motion, Dynamic Type and legibility (6 Sep). |

## 9. AI (Bask)

| | Item |
|---|---|
| 🟡 | Android has the chat only, not the hub (suggestions, history). |

## 10. Web companion and admin web

| | Item |
|---|---|
| 🟡 | Android cannot link a browser (no QR scanner for it yet). |
| 🟡 | Admin web: add refunds (with §4) and a KYC queue with auto-approve (with §4). |

## 11. Server, infrastructure and operations

**Health now:** API, database, Redis, Firebase and media are up. 313/332 API tests pass,
0 fail, 19 skipped (they need a database).

| | Item |
|---|---|
| 🔴 | Deploy migration 093 (§0 #1). |
| 🔴 | **Crash reporting** on both apps (§0 #3). |
| 🟠 | **A database smoke test in CI** that inserts a clip, a follow, a comment and an order against the replayed schema. Today's trigger bug passed CI because nothing wrote those rows. |
| 🟠 | **Error logs now name the route** (e.g. `POST /clips`), so a 500 can be traced. In `backend/api/src/errors.ts`, committed locally with this audit, not deployed. Before this, the logs had only a request id. |
| 🟠 | Production on E2E Networks: provisioning, `NODE_ENV=production`, secrets, backups, TLS, monitoring, **Q04** (verified artifacts, readiness, rollback). |
| 🟠 | Supabase CA certificate, then remove `VOIID_DB_TLS_INSECURE` (§0 #10). |
| 🟡 | Node 20 → 22. The AWS SDK drops Node 20 in January 2027. |
| 🟡 | Uptime and alerting: 5xx rate, worker failures, overdue erasure requests. The TLS outage ran for 6 days unnoticed. |
| 🟡 | A deadlock and a "types deduced" error are in the API log with no route recorded. They will be traceable after the log fix ships. |
| 🟡 | P04 pool and latency budgets, and Android release optimization (Q06), before scaling. |

## 12. Android overall

About 98k lines against iOS's 119k. Most screens exist; the gaps are whole features and polish.
Full list: `IOS_ANDROID_UI_PARITY_2026-09-23.md`. Biggest for launch: **Clips (§1)**,
**pull-to-refresh and the message long-press menu** (touched every session), then Map Move,
story archive, Carrom and the AI hub.

---

## Decisions needed from you

1. Deploy migration 093 now? It fixes clip uploads and follows. (Pushing also runs the iOS release workflow.)
2. `KYC_REQUIRE_AADHAAR`: keep it required (and wait for Cashfree DigiLocker), or turn it off until then?
3. SMTP provider for college email.
4. Crash reporting: Firebase Crashlytics (already using Firebase) or Sentry?
5. Order of work after launch blockers: Android Clips, the chat compressor, or production on E2E?

## Done in this session (for the record)

- Voiid Ui designs committed: communities, Clips create flow, Puppy lens, chat compressor (`c09a1aa`, Voiid-Ui repo, local).
- Clips flow shipped to `main` and the dev server (`05941e32`). Migration 093 committed locally (`97aa317d`).
- Error log route fix: committed locally with this audit, not deployed.
