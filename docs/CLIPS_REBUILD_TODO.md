# Clips rebuild — what's done, what's left, what to run

Written 2026-08-04, at commit `3fa4a01` on `main`. Everything described here is **pushed**.

This is the handover for continuing the Clips / creator-economy work on another machine.

> **UPDATE 2026-08-04 — all of §3 is now built on both platforms.** See §7 at the bottom for
> what changed, what the original §3 got wrong, and what is still unverified. §1 (migrations,
> secret key, admin seed, clip wipe) is still **not run** — those are live-infrastructure
> actions and remain outstanding.

---

## 1. Run these first (nothing works until you do)

### 1a. Apply the migrations

Four new migrations are on `main` and applied **nowhere**. Until they run, the creator
profile endpoints 500 and the admin panel cannot log in — `creator_profiles` and
`admin_users` do not exist.

```bash
node --env-file=/opt/voiid/.env infrastructure/deployment/migrate.mjs
```

The runner applies every unapplied `database/migrations/NNN_*.sql` in filename order, each
in its own transaction, and ledgers it in `schema_migrations` so re-runs are no-ops.

| Migration | What it adds |
|---|---|
| `026_contact_pin_readable.sql` | `contact_pin_enc` — the permanently-viewable PIN |
| `027_receipt_null_device.sql` | Fixes the NULL-device receipt duplicate rows |
| `028_admin_users.sql` | `admin_users`, `admin_sessions`, clip takedown columns, audit log |
| `029_creator_profiles.sql` | Creator profiles, follow graph, handle history, counter triggers |

> **On the two `026` files.** There are two (`026_contact_pin_readable` and
> `026_games_snake`). This is **not** a problem — `schema_migrations` is keyed on the full
> filename, not the number, so both apply independently. Verified in `migrate.mjs:44`.

Verify afterwards:

```sql
\dt   -- expect creator_profiles, creator_follows, creator_handle_history,
      -- reserved_handles, admin_users, admin_sessions, admin_audit_log
```

### 1b. Set `VOIID_SECRETBOX_KEY`

Long outstanding, from the contact-PIN work. `026` stores an encrypted PIN and
`seal()` throws without this key.

```bash
openssl rand -base64 32   # put the result in .env as VOIID_SECRETBOX_KEY
```

### 1c. Create the first admin account

Admin login is email + password, added manually (by design — see the header of `028`).
No account exists yet, so the panel cannot be logged into. There is **no seed script yet**;
either ask for one or insert directly:

```bash
node -e "console.log(require('bcryptjs').hashSync(process.argv[1],10))" 'YOUR_PASSWORD'
```
```sql
insert into admin_users (email, password_hash, name)
values ('nehal@coreedgesolution.com', '<hash from above>', 'Nehal');
```

### 1d. Wipe the old clips — **IRREVERSIBLE**

You asked for a clean slate before creator profiles become mandatory. **This has not been
run.** It permanently deletes every clip row and every R2 object, with no backup.

```bash
# SAFE. Prints counts, deletes nothing.
node --env-file=.env backend/api/scripts/wipe-clips.mjs

# DESTRUCTIVE. No undo.
node --env-file=.env backend/api/scripts/wipe-clips.mjs --confirm
```

Run the dry run first and read the numbers. R2 objects are deleted **before** rows,
deliberately — the keys only exist in the rows, so the reverse order orphans every video
with no way left to enumerate it. If it dies halfway, re-running resumes correctly.

### 1e. Admin panel

```bash
cd apps/admin-web && npm install && npm run dev   # http://localhost:3100
```
Set `NEXT_PUBLIC_API_BASE` if not pointing at `https://api-dev.voiid.app`.

---

## 2. What is already built and pushed

### Backend — complete

| Thing | Where |
|---|---|
| Creator profiles, follow graph, counters | `database/migrations/029_creator_profiles.sql` |
| Profile + follow API | `backend/api/src/routes/creators.ts` |
| Admin auth, moderation, audit | `backend/api/src/routes/admin.ts` |
| Clip wipe script | `backend/api/scripts/wipe-clips.mjs` |
| Moderation queue UI | `apps/admin-web/app/clips/page.tsx` |

**Endpoints now live** (all under `/v1` except admin, which is at `/admin`):

```
GET    /creators/me                     your profile, or {profile:null}
GET    /creators/handle-available       advisory check for the composer
POST   /creators                        create (the gate before first post)
PATCH  /creators/me                     edit; handle changes max 1×/30 days
POST   /creators/me/avatar-presign      public avatar upload URL
POST   /creators/me/avatar              attach uploaded avatar
GET    /creators/:handle                public profile (301s if renamed)
GET    /creators/:handle/clips          that creator's grid
POST   /creators/:handle/follow         follow
DELETE /creators/:handle/follow         unfollow
GET    /creators/feed/following         clips from creators you follow
```

### Three rules baked into the schema

1. **A follow grants no messaging rights.** The three reachability paths in `020` are
   untouched. A creator with a million followers gains zero inbound message rights. Any
   future code that reads `creator_follows` to authorise a message is a bug.
2. **Creator handle ≠ chat `@username`, but they share one namespace.** Separate because
   `users.username` is half a private credential (username + PIN opens a request) while a
   creator handle is meant to be public. Shared namespace because one `@name` meaning two
   people is an impersonation vector. Enforced by a cross-table trigger.
3. **A creator profile is required before posting.** `POST /clips` returns
   **`428` with `code: "profile_required"`** when none exists. The client turns that
   specific code into the handle picker.

### Performance — the reels lag fix

The stutter was **not** rendering. Every page change made a network round-trip to mint a
presigned playback URL, with zero caching. Fixed on both platforms:

- Playback URLs are now cached against the server's `expires_in`, keyed by quality
- Neighbour preloads run in parallel (were serial — the clip about to appear was queued
  behind one already scrolled past)
- Window is asymmetric (−1, +2), since reels scrolling is overwhelmingly downward
- **Android:** `collect` → `collectLatest`; the 2s view-count delay was blocking the pager
- **iOS:** preload detached from `.task(id:)`, which cancels on every page change

### Filters — fixed, not rebuilt

Filters already existed. Reading the mappings found real bugs:

- **iOS had four filters that were really two** — Vivid≡Chrome, Dramatic≡Noir
- **Android's were saturation-only**, so Chrome/Process/Transfer/Instant were near-identical
- **Dramatic was grayscale on Android, colour on iOS** — same clip, different result

> **Android has no system filter library.** iOS gets these looks from Apple's own
> `CIPhotoEffect` set (what Photos uses). Google Photos' filters are private to that app, so
> the Android looks are authored as colour matrices. That's why the two drifted apart.

---

## 3. What is left to build

All client-side. **The backend for every item below is already done and pushed.**

### 3a. Handle-picker gate — *do this first*
Blocks everything else; without it nobody can post at all.

- Intercept `428 profile_required` from `POST /clips`
- Sheet: handle field with live availability (`GET /creators/handle-available`, debounced),
  display name, optional bio/avatar
- On success `POST /creators`, then retry the upload
- Errors to handle: `409` taken, `400` bad format

### 3b. Creator profile screen
- Header: avatar, display name, `@handle`, bio, link, follower/following/clip counts
- Follow / Following button → `POST`/`DELETE /creators/:handle/follow`
- Grid of that creator's clips → `GET /creators/:handle/clips` (keyset paginated)
- Your own profile shows Edit instead of Follow
- **Reuse the existing square grid.** It works and it's what the user wants kept —
  do not redesign it.

### 3c. Following feed
`GET /creators/feed/following` exists. Needs a tab or toggle next to the main feed.

### 3d. Camera recording UI
Existing composer is gallery-first. Wants in-app recording: hold-to-record, segments,
front/back flip, timer, and the filter strip live in the preview.

### 3e. Upload polish
Background upload that survives leaving the screen, real progress, retry on failure.

---

## 4. Deferred by agreement

Ads / advertiser accounts · KYC and payouts · public follower lists (graph records now,
just isn't exposed) · face-effect filters (colour only for now) · server-driven UI for the
feed — **recommended against**; use server-driven *config* with native rendering instead
(Apple guideline 4.7 risk, and a reels feed's hard problems — gestures, preloading, scroll
performance — get worse with remote layout, not better).

---

## 5. Honest limitations

- **Neither app has been run.** Everything above is compiler- and test-verified only:
  iOS `BUILD SUCCEEDED`, Android `compileDebugKotlin --rerun-tasks BUILD SUCCESSFUL`,
  backend `tsc` clean, 100/100 tests. The *felt* smoothness of the pager and the *look* of
  the filters are unconfirmed — check both on device.
- **`029` was tested against a real scratch Postgres 18**, not just reasoned about — cross-table
  handle collisions, reserved handles, self/duplicate follows, counter behaviour across
  takedown+delete combinations, and cascade on user delete. Two genuine trigger bugs were
  found and fixed that way.
- **The admin panel has never talked to a live server** — no admin row has existed yet.

---

## 6. Not E2E encrypted — say this plainly in the UI

Clips, creator profiles, follows, likes, views and comments are **public and not
end-to-end encrypted**. The server can read the video, the caption, and who liked what.
This is a deliberate, scoped exception: a broadcast has no fixed recipient set to encrypt
to, and the product needs server-attributed counts.

**Messages, calls, locations and moments are unaffected and remain E2EE.** Nothing in the
Clips work touches those paths, and none of it is a precedent for weakening them.

---

## 7. Update — §3 is built (2026-08-04)

All five items in §3 are implemented on **both** platforms and pushed to `main`. Both apps
build clean, and both were installed and run on real hardware.

### What §3 got wrong

Two of its claims did not survive contact with the code, and the fixes matter:

**3a said "intercept `428 profile_required` and retry the upload."** That is a trap. The
composer exports a 480/720/1080 ladder and PUTs *every rung to R2* before the row is
committed, so the 428 only ever arrives **after** a 100 MB upload. Gating on it would ask for
a handle at the exact moment the user could still lose the work — and "retry the upload"
would re-send the whole ladder.

What was built instead: the profile check happens **before** the composer opens (one cached
`GET /creators/me`). The 428 path remains as a backstop for the race, and it **parks** the
finished upload rather than failing it — the bytes are already in R2, so `retryPendingCommits`
re-sends only the row.

**3d said "existing composer is gallery-first, wants in-app recording."** False on iOS, which
already had `StoryCameraView(mode: .clip)` — 90s cap, video-only, tap-to-toggle, hold-to-record,
flip, live timer. **Android** was the real gap: its CameraX stack binds `ImageCapture` only and
`camera-video` was not even a dependency, so clips handed off to the system camera intent.

### Also fixed on the way

Both API clients decoded only `{ error }` and **discarded the server's `code`**, leaving the
status as the only discriminator. Since 428 is a generic "precondition required" that any
future endpoint may reuse, matching on it alone would fire the handle picker for an unrelated
precondition. `APIError.http` / `ApiError.Http` now carry `code` — that is why chat, stories,
calls and profile editing appear in the 3a diff.

| Item | iOS | Android |
|---|---|---|
| 3a handle-picker gate | `CreatorHandleSheet.swift` | `CreatorHandleSheet.kt` |
| 3b creator profile + edit | `CreatorProfileView.swift` | `CreatorProfileView.kt` |
| 3c Following feed | `ClipsFeedView.swift` (scope picker) | `ClipsFeedView.kt` (scope pills) |
| 3d in-app camera | already existed | **new** `ClipCameraView.kt` + `ClipSegments.kt` |
| 3e retry / progress / background | `ClipsEngine.swift` | `ClipsStore.kt`, `ClipService.kt` |
| Service + store | `CreatorService.swift`, `CreatorEngine.swift` | `CreatorService.kt`, `CreatorStore.kt` |

### Two platform traps worth remembering

- **OkHttp follows redirects by default.** `GET /creators/:handle` signals a rename with a
  301 whose body is `{ moved_to }` and which has **no Location header**, so with the shared
  client the 301 is never visible — it re-requests a header-less redirect and the rename hop
  becomes an unexplained failure. `CreatorService.kt` uses a dedicated
  `followRedirects(false)` client for that one call. Exactly **one** hop is followed; history
  can chain a→b→c and looping would let a rename cycle hang the screen.
- **OkHttp has no write-progress hook.** Byte-level upload progress needed a
  `ForwardingSink`-based `RequestBody` wrapper. Its buffered sink must be **flushed, not
  closed** — closing it closes the underlying sink and OkHttp still needs that to finish the
  request.

### Still unverified — read this before trusting the above

- **The creator endpoints have never returned 200 to a real client.** Everything above is
  build-verified and installed, but §1a is still unrun, so `creator_profiles` may not exist on
  the dev database. `/v1/creators/me` does route (it answers 401, not 404), so the *code* is
  deployed — but a live signed-in round-trip has not been observed. **Apply the migrations
  first**; until then expect 500s from every creator endpoint.
- **Verified on device:** Android — installed on a real phone, and `ClipCameraView` was
  confirmed working (live preview, `00:08 / 01:30` timer against the 90s cap, flip, and the
  undo/shutter/confirm segment controls appearing only once a take existed). iOS — built,
  signed, installed and launched on an iPhone 15; process stayed alive, no crash reports.
- **Not exercised on device:** the handle picker, profile screen, follow button and Following
  feed — all of which need a working `029` to do anything.
- **The multi-segment join** (`ClipSegments.concatenate`) has not been run with 2+ takes. The
  single-take path, which is the common case, short-circuits before any transcode.
