# 11 — Admin Panel Expansion, Device/IP Collection, and DPDP Act 2023 Compliance

> Research doc. Every claim about the codebase cites file:line. Statements about the
> DPDP Act are from knowledge of the Act as passed (Aug 2023) and the DPDP Rules as
> notified (Nov 2025); **anything marked [COUNSEL] must be confirmed by an India-qualified
> data-protection lawyer, not implemented from this doc alone.** Existing open legal
> questions already live in `docs/LEGAL_QUESTIONS.md` (§3 covers DPDP, §4 covers IT
> Rules 2021 / intermediary obligations).

---

## 1. What exists today

### 1.1 Admin panel — backend (`backend/api/src/routes/admin.ts`)

A deliberately separate auth plane from user auth (`admin.ts:1-17`): admins are
email+password rows in `admin_users`, never phone-OTP users, so a SIM swap cannot reach
moderation powers (`database/migrations/028_admin_users.sql:3-11`). Sessions are
server-side rows with hashed tokens for instant revocation (`admin.ts:30-39`,
`028_admin_users.sql:36-53`). Mounted at `/admin` with its own rate bucket
(`backend/api/src/index.ts:145`).

Endpoints, exhaustively:

| Endpoint | What | Where |
|---|---|---|
| `POST /admin/login` | email+password, timing-safe, oracle-resistant | `admin.ts:94-131` |
| `POST /admin/logout` | deletes this session row | `admin.ts:134-138` |
| `GET /admin/me` | identity probe for the panel header | `admin.ts:141-144` |
| `GET /admin/stats` | users/clips/comments counts + 24h deltas | `admin.ts:149-164` |
| `GET /admin/clips` | keyset-paginated moderation queue, signed thumbs | `admin.ts:173-208` |
| `GET /admin/clips/:id/playback` | signed URL to review a clip | `admin.ts:211-221` |
| `POST /admin/clips/:id/remove` | soft takedown with reason | `admin.ts:230-246` |
| `POST /admin/clips/:id/restore` | undo takedown | `admin.ts:249-260` |
| `DELETE /admin/clips/:id` | permanent purge, R2 objects first | `admin.ts:268-286` |
| `GET /admin/audit` | audit log read (limit 200) | `admin.ts:291-303` |

Every action writes `admin_audit_log` best-effort (`admin.ts:47-60`;
`028_admin_users.sql:81-95`). The router touches no E2EE content — clips are public
plaintext by design (`admin.ts:14-17`).

### 1.2 Admin panel — frontend (`apps/admin-web`)

Next.js app with exactly three pages: dashboard (`app/page.tsx` — stat cards + one nav
button to clips, plus an honest E2EE disclosure paragraph at `page.tsx:55-62`), login
(`app/login/page.tsx`), and clip moderation (`app/clips/page.tsx`, 158 lines). The API
client is 67 lines (`lib/api.ts`). **There is no users page, no device/session viewer, no
audit-log page (the `/admin/audit` endpoint has no UI), no report queue, and no DPDP
console.** There is also no role system: every `admin_users` row has identical, full power
(`028_admin_users.sql:13-28` has no role column).

### 1.3 Device-type / IP data ALREADY collected

- **`admin_sessions.user_agent` + `admin_sessions.ip inet`** — captured at admin login
  (`admin.ts:120-126`), plus IP inside login/login-failed audit detail
  (`admin.ts:115-116, 128`). This covers *admins only*.
- **`security_events`** (`database/migrations/009_security_events.sql:5-15`): columns
  `event_type, user_id, device_id, phone_number, ip_address inet, metadata`. Written by
  `logSecurityEvent()` (`backend/api/src/security.ts:11-23`). Actual writers today:
  - rate-limit breaches, with IP (`security.ts:29-43`, IP at :31, :37);
  - reachability abuse, with IP (`backend/api/src/routes/reachability.ts:183-184`);
  - failed Firebase logins — **without IP** (`backend/api/src/routes/auth.ts:27`).
- **`devices`** (`database/migrations/002_devices.sql:5-24`): `device_name` (free text,
  e.g. "iPhone 15"), `platform` (`ios|android|web`), `push_token`, `push_provider`,
  `last_seen_at`, `revoked_at`. Registration accepts these client-supplied fields
  (`backend/api/src/routes/devices.ts:9-23`). **No IP, no OS version, no app version is
  stored on the device row.** User auth (`auth.ts:15-45`) stores no IP or user-agent at all.
- **`otp_sessions`** (`004_otp_sessions.sql`): phone number + hashed OTP; no IP.

So: IP collection today is *incidental and security-scoped* (admin sessions + abuse
events), and user device info is *self-declared metadata*. That is close to the right
posture for an E2EE messenger — the gaps are purpose documentation and retention, not
volume of collection.

### 1.4 DPDP-relevant plumbing that already exists

- `users.consent_given_at` column with a "DPDP: lawful consent capture at signup" comment
  (`database/migrations/001_users.sql:14-15`) and `POST /users/consent`
  (`backend/api/src/routes/users.ts:193-198`).
- `DELETE /users/me` — soft delete + device revocation, response says "hard purge runs via
  erasure job (DPDP)" (`users.ts:200-207`).
- Soft-deleted rows excluded everywhere via `deleted_at is null` (e.g. `users.ts:26,50,149`).
- A workers process exists for retention jobs (`backend/workers/src/index.ts:1-21`), whose
  READMEs *claim* "DPDP erasure" as a job (`backend/workers/README.md:48`,
  `backend/signaling/README.md:5`).
- Profile-visibility privacy controls (`database/migrations/019_privacy.sql`).

---

## 2. What is broken or weak

1. **Consent is never actually captured.** `POST /users/consent` exists
   (`users.ts:193-198`) but a grep of both apps finds **zero callers** — no
   `users/consent` reference anywhere in `apps/ios/Voiid/Voiid/**/*.swift` or
   `apps/android/app/src/main/java/com/voiid/app/**/*.kt`. `consent_given_at` is null for
   every user. Root cause: the endpoint shipped without the client leg. Also the record
   itself is too thin for DPDP: a bare timestamp captures no notice version, no language,
   no itemized purposes, and no withdrawal path (Act ss.5-6 expectations, §3 below).

2. **The promised erasure job does not exist.** `users.ts:201,206` and two READMEs
   reference a "DPDP erasure" worker, but `backend/workers/src/` contains only
   `reapStories.ts` (plus db/r2 plumbing); `index.ts` imports only `reapStories`
   (`workers/src/index.ts:16`). Worse, the soft delete nulls
   `full_name/email/photo_url/bio/status_text` but **retains `phone_number` and
   `username` forever** (`users.ts:204`; `phone_number` is `not null unique`,
   `001_users.sql:9`), and the route comment claims "prekeys removed now" while the code
   only revokes devices (`users.ts:205`). A phone number is the primary personal
   identifier in this system; indefinite retention after an erasure request is the single
   largest DPDP exposure in the codebase (Act s.8(7)).

3. **No retention limits on any IP/phone-bearing table.** Nothing ever deletes
   `security_events` (holds IP + phone), expired `otp_sessions` (holds phone), or expired
   `admin_sessions` rows (holds IP + UA) — the only `admin_sessions` delete is per-token
   logout (`admin.ts:136`); grep for cleanup of the other two finds none. DPDP's storage
   limitation (s.8(7): erase when purpose is no longer served) requires a stated,
   enforced retention period.

4. **Client IP is spoofable in every log.** `clientIp()` (`admin.ts:41-45`) and the rate
   limiter (`security.ts:31`) read `x-forwarded-for` directly, but `index.ts` never sets
   Express `trust proxy` (grep: no hit) and nothing validates that the header came from
   our own reverse proxy. A direct connection to the Node port can write any IP it likes
   into `admin_sessions`, `security_events`, and the audit log — poisoning the exact
   records a breach investigation would rely on.

5. **No user-facing report/flag mechanism, hence no report queue.** No report endpoint in
   `backend/api/src/routes/clips.ts` (grep), no `*report*` migration. Moderation is
   purely admin-initiated scrolling of `/admin/clips`. IT Rules 2021 grievance timelines
   (and any app-store policy) assume users can report content [COUNSEL for exact
   obligations — already question #13 in `docs/LEGAL_QUESTIONS.md:72-73`].

6. **No privacy policy or terms actually reachable.** iOS About screen has
   `privacyPolicyURL = nil`, `termsOfServiceURL = nil` with an explicit "ACTION REQUIRED
   FROM PRODUCT" comment (`apps/ios/Voiid/Voiid/Main/Settings/AboutView.swift:30-47`),
   and onboarding renders "Privacy Policy" as non-tappable text
   (`apps/ios/Voiid/Voiid/Onboarding/OnboardingFlow.swift:108`). DPDP notice (s.5) has
   nothing to point at.

7. **User sessions cannot be revoked server-side.** `POST /auth/logout` is a no-op
   (`auth.ts:47-48`); user JWTs are stateless. An admin "device/session viewer" (or a
   user's own "signed-in devices" screen) can revoke a *device* row, but the JWT keeps
   working until expiry — the same problem the admin plane explicitly solved for itself
   (`admin.ts:9-12`).

8. **Failed-login security events carry no IP** (`auth.ts:27` passes only metadata),
   making the one abuse signal that matters for credential-stuffing investigations
   useless. `security.ts:13` supports `ip_address`; the call site just doesn't pass it.

9. **Admin plane has no roles and no report-queue/DPDP surface.** Single implicit
   superadmin role (§1.2); every admin can permanently purge clips (`admin.ts:268-286`).

10. **A deleted account is silently RESURRECTED by the next login.** `POST /auth/firebase`
    upserts on phone number with `on conflict (phone_number) do update set updated_at =
    now()` (`backend/api/src/routes/auth.ts:32-38`) and **never inspects `deleted_at`**.
    Because `DELETE /users/me` only sets `deleted_at` and nulls profile text
    (`users.ts:204`), the row — and its `id`, `username`, `phone_number`, and every child
    row that was never deleted (clips, contact_sync, message_ciphertexts) — is still
    present. Re-authenticating with the same number returns that same `user_id` with
    `deleted_at` still set, so the account is neither erased nor usable: every read path
    filters `deleted_at is null` (`users.ts:50`, `reachability.ts:113`), so the user gets
    a working token addressing a profile that no endpoint will return. Root cause: erasure
    was modelled as a flag with no lifecycle — no job clears it (§2.2) and no login path
    either blocks or intentionally reinstates it. This is simultaneously a DPDP erasure
    failure (s.8(7): data survives the request indefinitely) and a product bug. **Counsel
    must decide the policy** [COUNSEL]: within the grace window, does re-login *cancel* the
    erasure request (requiring an explicit, logged un-delete) or is the account gone?

11. **A soft-deleted user's existing JWT keeps full API access.** `requireAuth`
    (`backend/api/src/auth.ts:22-33`) verifies the JWT signature only and never loads the
    user row — grep for `deleted_at` in `backend/api/src/auth.ts` returns **0 hits**. With
    `JWT_EXPIRY` defaulting to **30 days** (`auth.ts:6`) and `POST /auth/logout` a no-op
    (`routes/auth.ts:47-48`), a user who deletes their account keeps a valid token for up
    to 30 days and can continue posting clips and sending ciphertext. This is the same
    non-revocability the admin plane explicitly rejected for itself (`admin.ts:9-12`).

12. **Deleted users stay reachable and keep receiving ciphertext.** Neither
    `GET /devices/:user_id` (`routes/devices.ts:86-97`) nor `GET /prekeys/:user_id`
    (`routes/prekeys.ts:59-68`) joins `users` or filters `deleted_at` — grep for
    `deleted_at` in `devices.ts`, `prekeys.ts` and `messages.ts` returns **0 hits in all
    three**. Devices are revoked at deletion (`users.ts:205`) and both queries do filter
    `revoked_at is null`, so today the bundle list comes back *empty* rather than stale —
    the harm is a confusing failure ("peer has no available prekeys") rather than a leak.
    But the safety depends entirely on that one `update devices` statement succeeding; it
    is not written as an erasure invariant anywhere, and Fix 10's resurrection path can
    re-register a device onto a `deleted_at`-set row. Deletion should be enforced at the
    identity layer, not inferred from device revocation.

13. **`DELETE /devices/:device_id` has no ownership check.** The handler updates
    `devices set revoked_at = now() where id = $1` and deletes that device's one-time
    prekeys using **only the path parameter** (`routes/devices.ts:101-105`) — `user_id`
    from `req.auth` is never read, and there is no `and user_id = $1` clause. Any
    authenticated user who learns another user's `device_id` can revoke that device and
    destroy its prekeys, denying the victim inbound sessions. Device ids are not secret:
    `GET /devices/:user_id` returns them for **any** user id to any authenticated caller
    (`devices.ts:86-93`), so the attack is two unprivileged requests. The correct pattern
    is already used one function above, in `/voip-token`, which scopes its update with
    `where id = $1 and user_id = $2` and explains exactly why (`devices.ts:70-77`). This
    is a security bug found while auditing the device data model for the admin session
    viewer; it is not DPDP-specific but it is in the blast radius of "admin can revoke
    devices" (Fix 7) and should be fixed first.

---

## 3. How WhatsApp + Signal do it

**Signal (from source at `/Users/devacc/Signal stack`):** the server-side device record
stores exactly `lastSeen` and `userAgent` — no IP address on the account/device model
(`Signal-Server/service/src/main/java/org/whispersystems/textsecuregcm/storage/Device.java:77,83`).
`X-Forwarded-For` appears only in request-scoped plumbing (e.g.
`.../grpc/RequestAttributesInterceptor.java`), used transiently for rate limiting and
abuse defense, not persisted per account. This is the model Voiid's `devices` table
already resembles (`002_devices.sql`), and it is the posture to keep: **device metadata
lives on the device row; IP lives only in short-retention security telemetry.** Signal's
public subpoena responses ("we can produce account creation date and last connection
date, nothing else") are the operational proof of this design.

**WhatsApp (from public policy knowledge, no source):** collects far more — device model,
OS, battery, signal strength, IP, and derived coarse location — under a broad privacy
policy. That is lawful for them because their notice says so; it is not a design to copy
for a product whose pitch is E2EE-with-minimal-metadata. The useful WhatsApp import is
*process*, not data: an in-app grievance/report flow per message-or-content item, a
published India grievance officer with an address, and monthly IT Rules transparency
reports — all things Voiid has no surface for yet.

**Design conclusion:** collect device *type* (platform, model name, OS version, app
version — client-declared, on the `devices` row, visible to the user themselves) for
support and security; collect IP only into `security_events`/session rows with a fixed
short retention; never join IP to message metadata; never collect content-adjacent
telemetry. This keeps the DPDP purpose statement honest and one sentence long.

---

## 4. DPDP Act 2023 compliance checklist for Voiid

Act as passed August 2023; DPDP Rules notified November 2025 with phased commencement —
**exact in-force dates and final rule text must come from counsel [COUNSEL]**. Mapping to
Voiid state:

| # | Obligation (section) | Voiid today | Gap |
|---|---|---|---|
| 1 | **Notice** before/at consent: itemized personal data + purposes, how to exercise rights and complain to the Data Protection Board; available in English + the 22 Eighth-Schedule languages (s.5) | No reachable privacy policy at all (§2.6) | Write notice; host it; link from onboarding + About; [COUNSEL] for translation obligation scope |
| 2 | **Consent**: free, specific, informed, unconditional, unambiguous, by clear affirmative action (s.6); withdrawal as easy as giving (s.6(4)) | Endpoint exists, never called; timestamp-only (§2.1) | Versioned consent record (notice version, language, timestamp, per-purpose flags) + in-app withdrawal |
| 3 | **Purpose limitation / data minimisation** (s.6, s.8) | Collection is genuinely minimal (§1.3) — the strongest part | Document purposes per column; keep IP out of long-lived tables |
| 4 | **Security safeguards** + breach intimation to the **Board and each affected Data Principal** (s.8(5)-(6)); Rules prescribe timelines (72-hour detailed report to the Board under the notified Rules — [COUNSEL] confirm) | `security_events` exists; no breach runbook, no notification tooling | Breach runbook doc + admin console affordance to export affected-user lists |
| 5 | **Erasure** when purpose served or consent withdrawn (s.8(7)); rights of access, correction, erasure (ss.11-12) | Soft delete leaks phone/username forever; no erasure job; no access-request export (§2.2) | Erasure worker + DPDP request console (§5) |
| 6 | **Grievance redressal** (s.8(10), s.13) + IT Rules 2021 grievance officer (Rule 3(2), already `docs/LEGAL_QUESTIONS.md:72-73`) | Nothing | Named grievance officer + contact in app + notice; response SLAs [COUNSEL] |
| 7 | **Children** (s.9): verifiable parental consent under 18; no tracking/behavioural monitoring/targeted ads directed at children | No age gate anywhere in onboarding | Age self-declaration at minimum; [COUNSEL] — "verifiable" standard for a phone-number-only signup is genuinely unsettled |
| 8 | **Cross-border** (s.16): transfers allowed except to Centrally-blacklisted countries (negative list); sectoral rules may be stricter | DB region + R2 (Cloudflare) location are deployment facts to inventory (`docs/LEGAL_QUESTIONS.md:59`) | Document where users/clips/media bytes physically live; [COUNSEL] on R2/Firebase/LiveKit processor terms |
| 9 | **Significant Data Fiduciary** (s.10): DPO resident in India, independent audits, DPIAs — only if designated | N/A now | Track; likely irrelevant pre-scale |
| 10 | **Right to nominate** (s.14) and **duties of Data Principals** (s.15) | Nothing | Low priority; notice text item |
| 11 | **Penalties**: up to ₹250 crore for failing security safeguards (Schedule) | — | Motivates #3-#5 above |
| 12 | **E2EE tension**: DPDP itself does not require content access; the *traceability* pressure comes from IT Rules 2021 Rule 4(2) for SSMIs (≥50 lakh users) | E2EE architecture is DPDP-*friendly* (can't breach what you don't hold) | Never respond to a DPDP access request with anything but metadata — there is no content to give, and that must be stated in the notice |

**Key framing for the notice [COUNSEL to draft]:** message/call/location/moment *content*
is end-to-end encrypted and never processed by Voiid; what Voiid processes is: phone
number (identity), profile fields (user-provided), device metadata (per
`002_devices.sql`), clips/comments (public by choice), transient IP for security
(`009_security_events.sql`), and payment data later (Phase 8).

---

## 5. Recommended fixes (ordered)

Each is independently actionable.

### Fix 1 — Build the erasure worker; stop retaining phone/username after deletion (backend, **critical**)
Files: `backend/workers/src/erasure.ts` (new), `backend/workers/src/index.ts`,
`backend/api/src/routes/users.ts:200-207`, new migration
`database/migrations/030_erasure.sql`.
Grace period (e.g. 30 days, [COUNSEL] the number), then per user with
`deleted_at < now() - interval`: delete devices, prekeys, otp_sessions by phone,
contact_sync rows, location_shares, stories + R2 objects, clips + comments + R2 objects
(or anonymize author), message_ciphertexts addressed to their devices; finally either
delete the `users` row or overwrite `phone_number` with a random tombstone value (FK
`on delete cascade` already set on most children, `002_devices.sql:7`). Fix the
`users.ts:205` comment/code mismatch by actually deleting prekeys at request time. Risk:
medium — cascade order and R2 cleanup must mirror `admin.ts:279-282`'s "storage first"
rule; make the job idempotent per `workers/src/index.ts:14` contract.

### Fix 2 — Actually capture consent, versioned (both-mobile + backend, **critical**)
Files: `backend/api/src/routes/users.ts:193-198`, new migration
`database/migrations/031_consent.sql` (a `consent_records` table: user_id, notice_version,
language, purposes jsonb, given_at, withdrawn_at — not just a timestamp column),
iOS `apps/ios/Voiid/Voiid/Onboarding/OnboardingFlow.swift` (make the Terms/Privacy line a
real affirmative action wired to the endpoint), Android onboarding equivalent under
`apps/android/app/src/main/java/com/voiid/app/`. Today zero clients call `POST
/users/consent`, so `consent_given_at` is null for every user. Risk: low technically;
sequencing matters (consent before profile completion, and a backfill prompt for existing
users on next launch).

### Fix 3 — Retention sweeps for IP/phone-bearing tables (backend, **high**)
Files: `backend/workers/src/retention.ts` (new), `backend/workers/src/index.ts`.
Delete: `otp_sessions` where `expires_at < now() - 24h` (`004_otp_sessions.sql`);
`security_events` older than 90 days (`009_security_events.sql`);
`admin_sessions` where `expires_at < now()` (`028_admin_users.sql:44-53`). Write the
chosen periods into the privacy notice. Risk: minimal — pure deletes, idempotent.

### Fix 4 — Trustworthy client IP (backend, **high**)
Files: `backend/api/src/index.ts` (add `app.set('trust proxy', <hop count or proxy CIDR>)`
matching the deploy topology in `docs/VULTR_DEPLOY.md`), then replace the manual
`x-forwarded-for` parsing in `backend/api/src/routes/admin.ts:41-45` and
`backend/api/src/security.ts:31` with `req.ip`. Without this every stored IP is
attacker-controllable, which poisons audit and rate-limit keys (an attacker can also
rotate fake IPs to dodge the limiter). Risk: must match the real proxy chain — wrong hop
count makes *everyone* share the proxy IP and the rate limiter throttles all users as one.

### Fix 5 — User report flow + admin report queue (all, **high**)
Files: new migration `database/migrations/032_clip_reports.sql` (clip_reports: id,
clip_id, reporter_user_id, reason enum, note, created_at, resolved_at, resolved_by →
admin_users, resolution; unique (clip_id, reporter_user_id));
`backend/api/src/routes/clips.ts` (POST `/clips/:id/report`, authed + rate-limited);
`backend/api/src/routes/admin.ts` (GET `/admin/reports` queue with counts-per-clip,
POST `/admin/reports/:id/resolve` writing `admin_audit_log`);
`apps/admin-web/app/reports/page.tsx` (new); report button in iOS/Android clips UI
(`apps/ios/Voiid/Voiid` clips player, Android clips screen). Risk: low; reuse the
keyset-pagination and audit patterns already in `admin.ts:173-208, 47-60`.

### Fix 6 — DPDP request console (backend + admin-web, **high**)
Files: new migration `database/migrations/033_dpdp_requests.sql` (dpdp_requests: id,
user_id, kind `access|correction|erasure|grievance`, status
`open|verifying|in_progress|done|rejected`, opened_at, due_at, closed_at, handled_by →
admin_users, notes); `backend/api/src/routes/users.ts` (POST `/users/dpdp-request`, plus
GET `/users/me/export` returning the *metadata-only* JSON: profile row, devices rows,
consent records, clips list — explicitly no message content, which the server cannot read
per `admin.ts:14-17`); `backend/api/src/routes/admin.ts` (queue + status transitions,
each audited); `apps/admin-web/app/dpdp/page.tsx` (new). SLA timers surfaced in the UI;
the erasure kind triggers Fix 1's worker path. Risk: low mechanically; response-content
rules are [COUNSEL].

### Fix 7 — Admin users list + device/session viewer + audit UI + roles (backend + admin-web, **medium**)
Files: `backend/api/src/routes/admin.ts` (GET `/admin/users?search=` — id, masked phone,
username, created_at, deleted_at, clip count; GET `/admin/users/:id` — devices rows from
`002_devices.sql` metadata and recent `security_events` for that user; POST
`/admin/users/:id/revoke-devices`); new migration `database/migrations/034_admin_roles.sql`
(`admin_users.role text not null default 'moderator'` — gate `DELETE /clips/:id` purge,
user actions, and DPDP console to `admin`); `apps/admin-web/app/users/page.tsx`,
`apps/admin-web/app/audit/page.tsx` (endpoint already exists, `admin.ts:291-303`),
`apps/admin-web/app/page.tsx:51-53` (nav). Mask phone numbers by default in the UI —
admins moderating clips don't need them (data minimisation applies to the admin plane
too). Risk: low; audit every new mutation via `admit()` pattern at `admin.ts:47-60`.

### Fix 8 — Minimal lawful device-type collection (both-mobile + backend, **medium**)
Files: `backend/api/src/routes/devices.ts:9-23` (accept `os_version`, `app_version`),
migration `database/migrations/035_device_meta.sql` (two nullable text columns on
`devices`), iOS registration call site in `apps/ios/Voiid/Voiid` networking layer, Android
equivalent. Purpose: support/debugging and the user's own "linked devices" screen —
mirrors Signal's server device model (userAgent + lastSeen only, `Signal-Server .../storage/Device.java:77,83`).
Do **not** add an IP column to `devices`; IP stays in `security_events` under Fix 3's
retention. Risk: minimal; declare the two new fields in the privacy notice (Fix 2's
notice version bump).

### Fix 9 — Log IP on failed logins; server-side user session revocation (backend, **medium**)
Files: `backend/api/src/routes/auth.ts:27` (pass `ip_address` — requires Fix 4's `req.ip`
— to `logSecurityEvent`), and a larger follow-up: replace the no-op `POST /auth/logout`
(`auth.ts:47-48`) with revocable user sessions (short-lived JWT + refresh-token row, or a
Redis denylist checked in `backend/api/src/auth.ts`'s `requireAuth`). Without revocation,
Fix 7's "revoke devices" button doesn't actually end API access until token expiry — the
exact flaw the admin plane called out and solved for itself (`admin.ts:9-12`). Risk:
medium — touches every authed request; roll out with a dual-accept window.
**Sequencing:** Fix 10 adds the first per-request user lookup in `requireAuth`; build the
denylist/refresh mechanism on top of that same lookup rather than as a second, parallel
one. If both are done independently, `requireAuth` ends up with two caches to invalidate.

### Fix 10 — Close the deletion lifecycle: resurrection, live JWTs, reachability (backend, **critical**)
Files: `backend/api/src/routes/auth.ts:32-38`, `backend/api/src/auth.ts:22-33`,
`backend/api/src/routes/users.ts:200-207`.
Three defects share one root cause — `deleted_at` is a flag with no lifecycle (§2.10-2.12):
(a) the login upsert re-issues a token for a soft-deleted row without ever reading
`deleted_at`, so a deleted account is silently resurrected into an unusable state;
(b) `requireAuth` never loads the user, so an existing 30-day JWT (`auth.ts:6`) keeps full
API access after deletion; (c) deletion is enforced only by the `update devices` in
`users.ts:205` rather than at the identity layer. Change the upsert to select `deleted_at`
in its `returning` clause and branch explicitly: either reject the login, or — if counsel
chooses reinstatement-within-grace [COUNSEL] — clear `deleted_at` as a deliberate, audited
un-delete rather than as a side effect. Add a `deleted_at is null` check to `requireAuth`
(cache the lookup in Redis for a few seconds to avoid a DB round-trip per request; this is
the same trade the admin plane already pays at `admin.ts:73-80`). Risk: medium — `requireAuth`
is on every authed request, so the cache and its failure mode (fail *closed* for deleted
users, but do not fail closed on a Redis outage) need care. Do this **before** Fix 1: an
erasure worker that deletes rows while stale JWTs still authenticate against them creates
orphaned writes.

### Fix 11 — Scope `DELETE /devices/:device_id` to the caller (backend, **critical**, small)
Files: `backend/api/src/routes/devices.ts:101-105`.
The handler revokes a device and deletes its one-time prekeys using only the path parameter;
`user_id` from `req.auth` is never read (§2.13). Any authenticated user can revoke any other
user's device — ids are freely readable via `GET /devices/:user_id` (`devices.ts:86-93`).
Add `and user_id = $2` to the update, pass `req.auth.user_id`, return 404 when no row
matches, and scope the prekey delete to the same guard (do not delete prekeys unless the
revoke matched). Copy the pattern and rationale already present in `/voip-token`
(`devices.ts:70-77`). Risk: minimal — a strictly narrowing change; the only callers are the
user's own linked-devices screen. Ship independently of everything else in this doc.

### Fix 12 — Publish the legal surface (all, **medium**, mostly non-code)
Files: `apps/ios/Voiid/Voiid/Main/Settings/AboutView.swift:46-48` (set the three URLs),
`apps/ios/Voiid/Voiid/Onboarding/OnboardingFlow.swift:~106-108` (make Terms/Privacy
tappable), Android settings/onboarding equivalents, plus hosting the documents (the
landing page per `docs/LANDING_PAGE_BRIEF.md`). Content — notice text, grievance-officer
designation, children's-data stance, breach runbook, retention table — is [COUNSEL],
tracked in `docs/LEGAL_QUESTIONS.md` §3/§4. Risk: none technically; blocking for launch.

---

## 6. Explicit [COUNSEL] list (do not guess in code)

1. DPDP Rules 2025 commencement dates and final breach-notification timelines/format.
2. "Verifiable parental consent" standard for phone-number-only signup (s.9).
3. Whether messaging *metadata* retention periods must be stated in the notice, and the
   defensible retention numbers (this doc proposes 90d security events / 30d erasure grace
   as engineering placeholders).
4. IT Rules 2021: SSMI thresholds, traceability (Rule 4(2)) vs E2EE, grievance officer
   formalities — `docs/LEGAL_QUESTIONS.md:69-73`.
5. Cross-border status of Cloudflare R2, Firebase Auth, and LiveKit under s.16 +
   processor contract requirements (s.8(2)).
6. Notice translation obligation (22 languages) scope for an app of this size.
