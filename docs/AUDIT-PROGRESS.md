# Audit progress — what is fixed, and what it means

A running record of the [2026-09-05 app audit](../plans/app-audit-2026-09-05/00-MASTER.md) as it
is worked through. **Updated with every fix.**

This is the plain-language view. The
[issue register](../plans/app-audit-2026-09-05/01-ISSUE-REGISTER.md) remains the status
authority and holds the full completion record for each item — files changed, how the failure was
reproduced, what was verified and what was not.

**Status: 9 fixed · 2 implemented but unverified · 40 open**
Baseline `a2e24e5` · 50 findings · last updated 2026-09-06

---

## Fixed

Newest first.

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
| I03 | iOS keeps dirty state when local persistence fails | The iOS half of the durability work |
| S04 | Replace the false recovery lockout security boundary | **Needs a cryptographic reviewer.** Its own spec calls this a release gate, not a task to be closed by an implementation alone |

---

## How to read the completion records

Every fix in the register carries the same sections, and two of them matter most:

- **Regression evidence** — the fix was reverted and the tests were watched to fail. A test that
  passes both with and without the fix proves nothing, so this is stated explicitly each time.
- **Remaining limitations** — what was *not* proven. Device runs, load tests and production
  measurements are called out as missing rather than implied. Where an item says
  IMPLEMENTED_UNVERIFIED, this section is the reason.
