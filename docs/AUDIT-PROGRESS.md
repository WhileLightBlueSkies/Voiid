# Audit progress — what is fixed, and what it means

A running record of the [2026-09-05 app audit](../plans/app-audit-2026-09-05/00-MASTER.md) as it
is worked through. **Updated with every fix.**

This is the plain-language view. The
[issue register](../plans/app-audit-2026-09-05/01-ISSUE-REGISTER.md) remains the status
authority and holds the full completion record for each item — files changed, how the failure was
reproduced, what was verified and what was not.

**Status: 10 fixed · 3 implemented but unverified · 38 open**
Baseline `a2e24e5` · 50 findings · last updated 2026-09-06

**Every P0 is now closed except S04**, which its own spec calls a release gate needing a
cryptographic reviewer rather than an implementation.

---

## Fixed

Newest first.

### S05 — The database connection checks who it is talking to
`pending` · P1 · every service

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
