> Current status: [single audit report](AUDIT-FINAL-REPORT.md). Earlier entries below are historical; the 6 September review supersedes their totals and A02/M01/C02/C04 completion claims.

# Audit progress — what is fixed, and what it means

A running record of the [2026-09-05 app audit](../plans/app-audit-2026-09-05/00-MASTER.md) as it
is worked through. **Updated with every fix.**

This is the plain-language view. The
[issue register](../plans/app-audit-2026-09-05/01-ISSUE-REGISTER.md) remains the status
authority and holds the full completion record for each item — files changed, how the failure was
reproduced, what was verified and what was not.

**Status: 21 fixed · 16 awaiting verification · 13 open**
Baseline `a2e24e5` · 50 findings · last updated 2026-09-06

**Every P0 is now closed except S04**, which its own spec calls a release gate needing a
cryptographic reviewer rather than an implementation.

---

## Fixed

Newest first.

### M04 — Scrolling back through history could skip messages permanently
`pending` · P2 · API

History paged by timestamp alone. Messages sent in the same instant — which is what a group
fan-out produces — share a timestamp, so when a page boundary fell inside such a group the next
page started *past* them. With 300 messages sent together, **295 of 320 were unreachable**, and
permanently: the client had scrolled past them and would never ask again.

Measuring the query found a second problem. The read-receipt aggregation ran over the *entire*
conversation before taking the fifty rows being displayed: on a 50-member group with 50,000
messages that was **51ms and spilling to disk**. Selecting the page first takes it to **3.5ms**
with no spill. No index was added — the existing ones already cover it, which was checked rather
than assumed.

Also decided: someone joining a group no longer "un-reads" every older message for everyone. A
person who wasn't sent a message can't read it, so read status is judged against the roster at
send time.

**Not verified:** there is no agreed performance budget to hold those numbers against, and they
come from one fixture on a laptop. The apps also still page the old way until they're updated.

### Q03 — A release build can no longer ship pointing at the dev server
`f1072b2` · P1 · Android + iOS · **implemented, not verified**

Both apps hardcoded the development backend, and nothing anywhere set anything else. There was
no separation between a debug build and a release one — a signed release would have talked to
the dev server, and the only thing preventing that was someone remembering to edit a line first.
Android also permitted plaintext connections app-wide, which is a local-development convenience
that had no business shipping.

Endpoints now come from build configuration. Debug keeps working exactly as before; **a release
build with no endpoint configured refuses to build**, as does one pointing at a dev host or using
plaintext. All three refusals were executed, not just asserted.

**Not verified:** no release artifact was built or inspected — that needs the real production
hostname, which this work deliberately does not guess. iOS also needs its build settings adding
in Xcode; until then a misconfigured release would fail at launch rather than at build.

### A04 — A forgotten migration can no longer wipe local history
`2e493ce` · P1 · Android

The database was configured to **drop and recreate every table** on any version bump that lacked
a migration. The comment above that setting already described the danger accurately — it takes
`call_history` and the address-book names with it, which live on the device and nowhere else. The
failure it produces isn't a crash: it's an upgrade that *succeeds* while the user's call history
quietly disappears.

Nothing is broken today — versions 1 to 4 all have migrations. It becomes broken the first time
someone bumps the version and forgets, which is precisely the mistake that setting exists to
hide. It's removed, schemas are now exported and committed, and the build fails if a version is
ever left without a migration.

**Not verified:** no upgrade was run against a real old database. What's proven is that the
destructive path is gone and every version is covered — not that each migration is correct.

### R05 — Two people adding to a full call can no longer both succeed
`c17feb8` · P1 · API

A conference holds eight. The cap was enforced inside the insert statement itself, on the
reasoning that the database evaluates the count and the write together. It does — but two
requests that *start* before either finishes both count seven, both pass, and both add someone.
Two connections racing the last seat produced a **nine-person call**.

The audit predicted this and said only a test against a real database could settle it. That test
now exists, and it reproduced the fault before the fix. Admission takes a lock on the call
itself, so the second request counts a roster that already includes the first.

**Still open:** join and leave don't take the same lock — they move existing people rather than
adding seats, so they can't breach the cap, but they aren't serialized against admission either.

### C02 / C04 — Workers that report what they actually did
`0a70755` · P1 · workers

**C04:** when the story reaper could not delete a file — no storage configured, or after
repeated failures — it deleted the database row anyway. That row was the only thing that knew
the file's key, so the media stayed in the bucket with **nothing left able to name it**. The
code justified this by pointing at a storage lifecycle rule that the audit could not verify.
Keys are now written to the existing retry queue before the row goes.

**C02:** every job catches its own errors and *returns* counts. Health only looked at whether a
job threw — so retention could fail every pass, or the reaper abandon rows every pass, and the
health check stayed green. It now reads what the jobs actually reported, plus how long since
each last succeeded and whether one is hung.

**Still open:** two workers can still claim the same rows (C03, P2) — duplicate work rather than
damage. The bucket lifecycle rule remains unverified; this removes the *dependence* on it rather
than confirming it.

### S06 — Linking a companion device happens once
`4eafc6d` · P1 · API

The QR linking handshake lived in a cache, and every step was read-then-write across three
separate round trips. Two people approving the same QR at once could both register a device —
one account kept a device nobody would ever use, and which account the waiting browser got came
down to whichever write finished last. Two polls could both collect the same session credential.
A crash mid-way left a registered device and a QR stuck on "pending" forever. And a Redis
restart lost every link in progress.

It is a database row and one transaction now: the device, its session and the state change
commit together, so there is no half-way to be stuck in, and the credential can be collected
exactly once.

### W01 / W02 / W03 — Console and site-header correctness
`2803a92` · P1 · admin console + marketing site

**W01:** cancelling the "add a note" dialog when resolving a report still **resolved the
report**. Cancel and an empty note were the same empty string to the code. There is no undo on
that screen.

**W02:** typing in a console filter cleared a timer but not the request already in flight. A
slow response for the old filter could land last and win — showing rows for a filter the
operator had moved away from, with that query's cursor, so "load more" appended the wrong list.

**W03:** the closed mobile menu was hidden from *sight* and from nothing else. Its links stayed
in the keyboard order, so tabbing across the header dropped you into a menu you could not see;
and the checkbox driving it could not announce "expanded" to a screen reader. It is a real
button now, and the closed menu is properly inert — at the mobile breakpoint only, since the
same element is the desktop navigation.

**W03 not verified:** nothing was checked in a browser. Keyboard traversal, screen-reader
announcement and focus behaviour across resize all need inspection that does not exist here.

### M03 — A long-offline device gets its backlog in pages
`4d02fd9` · P1 · API

Fetching undelivered messages had no page limit at all: a phone returning after two weeks asked
the server to load, sort and serialise its entire backlog in memory. **My own M02 change made
this worse** — once fetching stopped marking messages delivered, that whole backlog came back on
every poll until the device acknowledged it.

It now arrives in pages with a cursor, capped by both row count and total size. The page boundary
is keyed on time *and* id, so a burst of messages sharing a timestamp cannot be split in a way
that drops or repeats them.

**Not measured:** the bound is structural rather than observed — no memory or latency figure was
recorded, and the 310-message test backlog is not a large one.

### A03 — Dates on Android 7 were silently all "now"
`f18d8f9` · P1 · Android

The app supports Android 7 (API 24) and uses `java.time`, which arrived in API 26, without the
build setting that makes it work there. On those devices every date parse threw — and because
each call site wrapped it in `runCatching`, the error was **swallowed and the timestamp became
the current time**. No crash, no log: messages silently out of order, story and location expiry
silently wrong, for every user on Android 7. The same substitution turned any malformed server
date into a plausible one on every Android version.

Desugaring is enabled now, and an unreadable date returns nothing rather than "now" — callers
fall back to 1970, which is wrong somewhere a person will notice, and for an expiry means
"already expired", which is the safe direction. A third copy of the bug turned up in group
messaging that the audit had not spotted.

Lint errors dropped from 116 to 90.

**Not verified:** nothing was run on an API 24 device or emulator. The unit tests run on a JVM
that has `java.time` regardless, so they prove the parsing rules and not the desugaring.

### P03 — A failing request now answers instead of hanging
`bd03787` · P1 · API

Express 4 does not catch a rejected promise from a route handler, so a handler that threw sent
**no response at all** — the client waited until it timed out and the socket stayed open. The
audit named four such handlers; a full inventory found **67 across 12 files**.

The error handler also guessed the status from the error's text. A body that was too large came
back as 500 instead of 413, telling clients to retry something that could never work; and any
internal failure whose message happened to contain "invalid input" — which is what Postgres says
for a bad id — was reported to the caller as their mistake.

Every handler is wrapped now, errors carry a stable code and a request id, and nothing is
inferred from prose.

### S05 — The database connection checks who it is talking to
`3f5416a` · P1 · every service

Every service connected to the database with certificate verification **off**. The traffic was
encrypted, and nothing checked who it was encrypted *to* — anyone able to sit between the server
and Supabase could present any certificate and read or rewrite the whole database.

The local-development exemption made it worse: it searched the entire connection string for the
word "localhost", so a password containing it, a database named it, or a host called
`localhost.attacker.example` silently turned verification off for a remote database.

One shared, tested policy now. The hostname is parsed, remote connections are verified, and a
connection string that would quietly weaken the policy is refused rather than honoured.

**Action needed on the server.** Verification is the default, so a machine whose trust store
lacks the database's CA will now fail to connect. The rollout is: set `VOIID_DB_TLS_INSECURE=1`
(today's behaviour, made explicit), provision the CA, then remove the flag. **Until that last
step, the hole is still open** — loudly now, and logged at every boot, rather than silently.

### I03 — Persistence that reports whether it persisted
`d39a9e9` · P0 · both clients · **implemented, not verified**

Writing a conversation to disk cleared the "needs writing" marker *before* writing, and
swallowed every failure into a log line. A full disk or a permission error meant the
conversation was never written and never retried — the app carried an in-memory copy that
vanished when it exited. Since M02 that also made the client tell the server it had stored
messages it had not, so the server stopped offering them.

Two more found while fixing it. The Android write fell back to overwriting the live file when
the atomic replace failed — the opposite of atomic, since an interruption there destroys the good
copy. And an unreadable shard was skipped on load, so the conversation came back **empty** and the
next write saved that emptiness over it: one bad file silently replaced a whole conversation's
history.

Writes now report success, markers survive failure, there is no in-place fallback, unreadable
files are moved aside rather than skipped, and neither client acknowledges anything it did not
actually store.

**Not verified:** the iOS project has no test target, so the iOS half is verified by compilation
and by being the same design as the tested Android half. The acceptance scenarios were produced
through injected failures, not on a device with a genuinely full disk.

### A02 — SecurePrefs no longer destroys what it cannot read
`537dcf5` · P0 · Android

Any failure opening an encrypted store deleted the file, and if the rebuild also failed it deleted
the Keystore master key **shared by every store in the app**. One unreadable file could take the
E2E identity, the session token, the message history and the account-backup master secret with it,
on launch, from a transient error.

Failures are now classified and answered from a tested decision table. A locked device is retried
then reported. An invalidated key is reported — regenerating an identity is the user's decision.
Corruption moves that one file aside (a rename, never a delete). Nothing reaches a destructive path
automatically.

### A01 — Private stores stop leaving the device
`537dcf5` · P0 · Android · **implemented, not verified**

The backup rules named 3 stores. The app had 20. Sixteen were being copied to Google's cloud and
onto any transferred device, including the master secret for the encrypted account backup and the
Olm identity. Device transfer was never allowlisted at all.

Both rule files are allowlists now — four cosmetic preferences may leave, everything else is
excluded by construction. A build-failing test scans the sources so a new store cannot be added
without classifying it.

**Not verified:** no backup archive was inspected and no restore was performed on a device. The
issue explicitly says not to infer safety from the presence of backup XML, and this has not been
proven on hardware.

### M02 — Delivery is what the device reports, not what the server sent
`9f02a7d` · P0 · API + both clients

Fetching a message marked it delivered, and committed before the response left the server. A
dropped socket, a killed app or a failed disk write lost the message permanently — the next fetch
skipped it and nothing raised an error. Scrolling through history marked messages delivered too.

Fetch is a read now. A device acknowledges only what it has actually stored. Legacy messages also
gained per-recipient tracking: their delivery state was one shared bit, so one device fetching a
message emptied every other device's queue.

### M01 — A retry is the same message, and the wake survives Redis
`deacbd8` · P0 · API + workers + both clients

A client cannot tell "not delivered" from "delivered, reply lost", so it retried — and every retry
was a second message and a second bubble for the recipient. Sends now carry a stable client id.

Separately, the wake notification was fire-and-forget: if Redis was unreachable the message existed
and **nobody was ever told**. Notifications are now written in the same transaction as the message,
with a sweep that delivers whatever the inline publish could not.

### R02 — The relay derives who a frame may reach
`2c27dd9` · P0 · WebSocket relay

Typing, session-reset and location frames carried a recipient list and the relay published to
whatever it named — so anyone could push a typing indicator into any conversation id they guessed,
or relay location frames at arbitrary users. The relay had no database when that was written; S03
gave it one.

Recipients are derived from conversation membership and share ownership now. A client's list can
only narrow that audience, never widen it. Also added the socket-wide frame budget that was missing
and bounded the limiter maps a client could grow without limit.

### C01 — A failed payment webhook is retried, not marked done
`e568dfc` · P0 · API + payments

A delivery was claimed before settlement. If settlement failed, the retry hit the duplicate check
and was answered 200 — so the buyer's money had moved, no ticket existed, and the ledger said the
delivery was handled. Nothing would ever try again.

The effect and the record of the effect now commit together. Also closed: webhooks arriving before
their order row existed were discarded, and a refund arriving before its payment was lost entirely
(then the payment landed and minted live tickets for money already returned).

### S03 — Sessions are bound to devices, so revocation revokes
`a99cc2f` · P0 · API + relay + both clients

Logging out did nothing: the JWT stayed valid for its full 30 days. There was no server-side object
a revocation could be written to, and prekey upload could un-revoke a device the user had explicitly
signed out.

Sessions are rows now, carried in the token and checked on every request. The relay verifies them
against the database at connect rather than a cache that fails open. Existing installs keep working
until a configured cutoff date.

### S02 — Message paths validate sender and recipient devices
`fb058cf` · P0 · API

A conversation member could fetch another device's ciphertext and affect its queue, and a modified
client could route messages outside the intended roster.

### S01 — Receipt reads and writes are authorized
`8629003` · P0 · API + both clients

Any authenticated caller could forge receipts against arbitrary message ids, read metadata for
conversations they were not in, and interfere with another conversation's pending state.

### Q01 — The test baseline was repaired without hiding regressions
`a90e089` · P1 · Tests

Four API tests failed against a fake that refused every invite, and a shell `&&` chain meant one
early failure stopped five later suites from running at all.

---

## Implemented but not verified

### I03 — see above

### Q02 — Quality gates before deployment
`f0e116a` · P1

Deploys opened an SSH session with no test, typecheck or native check anywhere in the path. CI now
gates both deploy workflows and pins the deployed commit.

**Not verified:** no job has executed on a GitHub runner. Every step was checked locally, but runner
images differ and a first-run shakeout should be expected.

### A01 — see above

---

## What is still open

Everything else in the [register](../plans/app-audit-2026-09-05/01-ISSUE-REGISTER.md). The P0s
remaining are:

| ID | Issue | Note |
|---|---|---|
| S04 | Replace the false recovery lockout security boundary | **Needs a cryptographic reviewer.** Its own spec calls this a release gate, not a task to be closed by an implementation alone |

Everything else is P1 or below: API performance, the remaining realtime and worker items, Android
API-24 compatibility, Liquid Glass, motion and accessibility, web admin, and the crypto assurance
review.

---

## How to read the completion records

Every fix in the register carries the same sections, and two of them matter most:

- **Regression evidence** — the fix was reverted and the tests were watched to fail. A test that
  passes both with and without the fix proves nothing, so this is stated explicitly each time.
- **Remaining limitations** — what was *not* proven. Device runs, load tests and production
  measurements are called out as missing rather than implied. Where an item says
  IMPLEMENTED_UNVERIFIED, this section is the reason.

### P01/P02 — Independent request limits and atomic windows

Ordinary community browsing no longer spends host-thread creation allowance. Authenticated route limits follow the account; anonymous traffic retains an IP guard. Redis counts and expiry update atomically, rejection responses include retry timing, and floods no longer produce one SQL write per rejection. Real route-order and Redis concurrency checks passed. See [evidence](audit-evidence/api-throttles.md). Earlier 18 + 4 + 30 totals were incorrect; the register has 50 entries.

## 6 September continuation

Integrated and checked recovered work after agent usage limits. API throttles, message retry race, cleanup queue durability, Android cancellation, admin request races and navigation focus received fixes. Detailed tests and remaining acceptance are in the [continuation evidence](audit-evidence/continuation-2026-09-06.md). The [single report](AUDIT-FINAL-REPORT.md) is the current overview.
