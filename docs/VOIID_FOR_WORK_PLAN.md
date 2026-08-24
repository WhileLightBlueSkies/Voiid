# Voiid for Work — architecture plan

> **Status: PROPOSAL. Nothing here is built.** Decisions below were taken in the planning
> session of 2026-08-11 and are recorded so the reasoning survives the conversation.
> Written against the codebase at `b7a3e2b`.

Voiid for Work is a **separate app and a separate identity system** on the existing Voiid
backend. An organisation buys a workspace, creates work identities for its staff, and those
identities message, call and hold group channels — end-to-end encrypted, on the same MLS
plumbing the consumer app already uses.

It is **Slack/Teams-shaped, not WhatsApp-Business-shaped**. That distinction is the most
important sentence in this document; see "What this is not".

---

## The four decisions

| Question | Decision |
|---|---|
| Who does an org message? | **Its own members only.** The org adds them. |
| Employee identity | **Separate work identity.** Not the phone-based personal account. |
| Login | **Admin invites by email + org password.** |
| Personal vs work on one phone | **Separate app build.** No profile switcher. |
| Offboarding | **Device wipe on revoke.** |
| Compliance archival | **No. E2EE is the product.** |
| Bot / API keys | **Hybrid, split by surface** (below). |

---

## What this is not

**There is no business→customer messaging.** An org cannot message a stranger, ever.

This is what makes the whole design tractable. `020_reachability.sql` exists to stop bulk
senders reaching people who never asked to be reached — *"treating 'I have your number' as
sufficient is what turns a leaked number list into spam on other platforms."* A business
blasting order updates at customers is precisely that thing.

Because an org only ever talks to **members it has itself added**, that rule is never
strained. Org membership is a fourth authorisation path alongside the three in
`020_reachability.sql`, and it is narrower than any of them: both parties are inside the same
workspace, and an admin put them there.

If business→customer messaging is ever wanted, it is **a separate product with a separate
threat model**, and it must not be smuggled in by widening anything described here.

---

## Identity: the one foundational change

`001_users.sql` makes phone number the identity: `phone_number text not null unique`. Work
identity breaks that assumption, and it is the largest single piece of work in this plan.

**Why it has to break.** Offboarding. When Alice leaves Acme, Acme must revoke her work
access without touching her personal Voiid account — which it does not own and must never be
able to delete. A work identity that *is* a personal account cannot be revoked; it can only
be removed from groups, leaving her keys, devices and cached history untouched. So work
identity must be a distinct principal that the org controls completely.

### Shape

A **work identity is its own row in `users`**, with `phone_number` nullable and a new
`work_email` unique within the org. It reuses `devices`, `prekeys`, `mls_key_packages`,
`messages` and every crypto path unchanged — a work identity is just a user that logged in
differently.

```sql
-- 0NN_org_identity.sql (sketch)
alter table users
    alter column phone_number drop not null,
    add column org_id     uuid references organizations(id) on delete cascade,
    add column work_email text,
    add column revoked_at timestamptz;          -- offboarding; distinct from deleted_at

-- Exactly one of phone (personal) or work_email+org (work). No hybrids.
alter table users add constraint users_identity_kind check (
    (phone_number is not null and org_id is null and work_email is null) or
    (phone_number is null and org_id is not null and work_email is not null)
);
create unique index on users (org_id, lower(work_email)) where work_email is not null;
```

The CHECK constraint is doing real work: it makes "a personal account that is also a work
account" **unrepresentable**, rather than merely discouraged.

> **Audit required before writing this migration.** 31 references to `phone_number` across 7
> files (`auth.ts`, `users.ts`, `security.ts`, `admin.ts`, `dpdp.ts`, `contacts.ts`,
> `firebase.ts`). Every one must be checked for a null phone. `contacts.ts` matters most —
> contact sync is phone-hash based and **must never match work identities**, or work accounts
> leak into personal address books.

### Login: password, done like `012_recovery.sql`

Consumer auth is OTP-only, so password auth is new. But the *hard* part — deriving key
material from a secret the server never sees — already exists and should be copied, not
reinvented.

`012_recovery.sql` stores a `PinWrappedSecret`: an **Argon2id + AES-256-GCM** wrap of a
master secret, opaque to the server, with `failed_attempts` / `locked_until` throttling
online guessing. Work login is the same pattern with a password instead of a PIN.

Two secrets, and keeping them separate is the point:

1. **An authentication verifier** — server-side hash (`bcryptjs`, already a dependency)
   proving Alice may call the API. Server-visible by necessity.
2. **A password-wrapped key blob** — Argon2id-derived, unwrapping Alice's private keys on a
   new device. **Opaque to the server**, exactly like `recovery_keys.wrapped_key`.

If the server only held (1), it could not hand Alice her keys on a new device without holding
her private keys — which would end E2EE. (2) is what preserves the golden rule under
password login.

**Password reset therefore cannot recover history.** The wrap is Argon2id over the password;
no password, no unwrap. An admin reset restores *access* and issues *new* keys — it cannot
decrypt old messages. This must be stated in the admin UI at the moment of reset, or it will
be discovered as a bug during an incident.

**Invite flow:** admin creates the identity → single-use, expiring, hashed invite token
emailed → Alice sets password in-app → device registers, uploads `identity_public_key` and
prekeys exactly like a consumer device. Invite tokens hashed at rest and single-use, per the
existing `contact_pin_hash` stance.

---

## Tenancy

```sql
create table organizations (
    id            uuid primary key,         -- CLIENT-supplied, like communities (030)
    name          text not null,
    slug          text not null unique,
    plan          text not null default 'trial',
    created_at    timestamptz not null default now(),
    suspended_at  timestamptz,              -- non-payment: read-only, not destructive
    deleted_at    timestamptz
);

create table org_members (
    org_id     uuid not null references organizations(id) on delete cascade,
    user_id    uuid not null references users(id) on delete cascade,
    role       text not null default 'member',   -- owner | admin | member | guest
    joined_at  timestamptz not null default now(),
    revoked_at timestamptz,
    primary key (org_id, user_id)
);
```

Client-supplied `id` follows the idempotency reasoning in `030_communities.sql`: creation is a
multi-step transaction, so a retried POST must land on the same row rather than build a second
half-wired org.

**Isolation is enforced in one place, not per route.** A `requireOrgMember` middleware
alongside `requireAuth` resolves the caller's org and every query filters on it. Per-route
checks are how cross-tenant leaks happen; there must be a single choke point, and it should be
tested adversarially (member of org A requesting every org B resource).

**Channels are MLS groups.** An org channel is a `conversations` row of type `group` with an
`org_id`, using `mls_key_packages` / `mls_group_events` / `mls_event_deliveries` unchanged.
Calls and video reuse the existing signaling. **No new cryptography is invented for this
product** — that is the main reason it is buildable.

---

## The server-key question

An org's API server needs a key to send messages, but it is not a human with a phone. Three
options, and the chosen answer is the third.

**Option 1 — the bot is a real device, org holds the key.** True E2EE, golden rule intact.
Cost: the org must run a stateful key-holding service.

> **The `max_past_epochs = 0` trap.** Per `037_mls_device_delivery.sql`: *"a member who misses
> one commit cannot decrypt anything from that epoch onward and cannot catch up... the only
> repair is being removed and re-added."* A bot offline during a deploy while staff churn
> happens comes back **permanently deaf** in that channel. Any bot implementation **must**
> detect epoch loss and self-heal by requesting removal and re-add. This is not optional and
> is easy to discover far too late.

**Option 2 — Voiid holds the org's key.** Trivial for customers, but the server reads every
message that bot touches.

**Option 3 — hybrid, split by surface. CHOSEN.**

- **Human staff chat, calls, channels → truly E2EE.** Keys on real devices. No exceptions,
  no asterisk. This is the product promise.
- **Bot / API integrations → Voiid-hosted key, explicitly disclosed.**

**Why this is honest rather than a fudge:** MLS makes a bot a *visible member of the group*.
It holds a member seat, so clients can render it. "This channel includes a Voiid-hosted bot;
messages here are readable by Voiid" becomes a **visible property of the room enforced by the
cryptography**, not a footnote in a privacy policy. A channel with no bot is end-to-end
encrypted, full stop.

Orgs wanting zero Voiid-readable surface can run Option 1 and get no hosted key at all.

This mirrors `030_communities.sql`: name the exception, scope it structurally, refuse to let
it spread. When the bot migration is written, it should carry the same
`NOT END-TO-END ENCRYPTED` header block, surface by surface.

---

## Offboarding: device wipe on revoke

Revoking a work identity sets `org_members.revoked_at` and `users.revoked_at`, then:

1. Reuses `revokeAccountSessions()` from `auth.ts` — Redis tombstone plus a `force_signout`
   publish. This already handles the stateless WebSocket relay, which holds no DB connection
   and cannot check revocation itself.
2. Revokes the identity's `devices` rows, invalidating sessions.
3. Publishes a **`wipe_work_data`** command; the work app destroys local keys and cached
   messages on receipt.
4. Removes the member from every org MLS group (Commit), so the group re-keys and the
   departed device cannot read anything sent afterwards. **This part is cryptographic and
   cannot be circumvented** — it holds even if the device never comes back online.

**State the limit plainly:** steps 1, 2 and 4 are enforced server-side and by MLS. Step 3 is
best-effort — it needs the device online and the app honest. A rooted device with a
filesystem copy keeps what it already decrypted. Forward secrecy after removal is guaranteed;
retroactive erasure of already-delivered plaintext is not, by anyone, and the admin UI should
not imply otherwise.

---

## Compliance: no archival

No server-side archival, no eDiscovery export, no compliance backdoor. This costs regulated
customers (finance, healthcare) and that is accepted.

If it is ever revisited, the **only** form that preserves the promise is an org-run archive
endpoint joined as a visible group member holding an **org-held** key — Voiid still cannot
read it, and the roster shows it. A Voiid-held archival key is the one thing that would make
the E2EE claim false, and it should stay off the table.

---

## Separate app build

`apps/work-ios` / `apps/work-android`, sharing packages with the consumer apps. No profile
switcher, no shared key store — strongest separation, simplest crypto, at the cost of
shipping and maintaining another app. Backend is shared; work routes live under `/org/*`.

---

## Build order

Each phase is independently useful and leaves the system working.

1. **Tenancy** — `organizations`, `org_members`, `requireOrgMember`, isolation tests.
   No identity changes yet; seed with existing accounts to exercise the middleware.
2. **Work identity** — the `phone_number`-nullable migration, the 31-reference audit,
   password auth (verifier + Argon2id wrap), invite flow. **Largest and riskiest phase.**
3. **Work app shell** — new builds, enrolment, device registration and prekey upload.
4. **Channels** — org-scoped MLS groups, DMs, calls. Mostly wiring existing plumbing.
5. **Offboarding** — revoke, wipe command, MLS removal. Before any paying customer.
6. **Bots / API** — hosted-key surface, roster visibility, epoch-loss self-heal.
   Last, because it is the only part carrying a crypto exception.

---

## Open questions

- **Guest access** — external collaborators in one channel. Deferred; `org_members.role`
  reserves `guest` so it does not need a migration later.
- **Ownership transfer** — `030_communities.sql` already flags this as unsolved for
  communities (deleting an owner deletes the container). An org cannot ship with that
  behaviour; it needs a real transfer flow before GA.
- **Billing** — `plan` and `suspended_at` are placeholders. Suspension must be **read-only,
  never destructive**: non-payment must not delete keys or history.
- **Rate limits** — per-org quotas on invites, channel creation and bot posts.
