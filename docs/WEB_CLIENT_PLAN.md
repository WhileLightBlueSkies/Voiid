# Voiid Web — design and delivery plan

> A WhatsApp-Web-style companion: link a browser to an existing account by QR, then read and
> send end-to-end encrypted messages from it.
>
> Status: **not started**. This is the plan, written 2026-09-09 against the code as it stands.

## What already exists, and what does not

The expensive half is done. This is not a greenfield project.

| Piece | State |
|---|---|
| Linking protocol (`backend/api/src/routes/linking.ts`) | **Built and hardened** — S06 |
| `device_link_requests` table (migration 061) | **Built** |
| Conversations / messages / receipts / media APIs | **Built**, used by both native apps |
| WebSocket relay (presence, typing, delivery) | **Built** |
| Rust E2E core (`packages/e2e-core`) | **Built** — 81 exported functions across `ffi.rs` + `api.rs` |
| Swift + Kotlin bindings | **Built** |
| **WASM binding** | **Missing** — this is the project |
| **A web client** | **Missing** — `apps/web` is a marketing site |
| Node binding (`bindings/node/`) | A README. Deliberately deferred, and **not** what a browser needs |

`apps/web/app/messaging/page.tsx` is 170 lines of marketing copy with a phone mockup. There is
no client code to extend; the web app is a brochure.

## The one hard problem

`linking.ts` states the constraint that shapes everything:

> *"The new device's private keys are generated on-device and never sent here."*

So the browser must perform **real Olm cryptography** — generate an identity, publish prekeys,
establish per-device sessions, and advance a double ratchet — with private keys that never
leave it. There is no server-side shortcut that preserves the E2E property.

That means compiling `e2e-core` to **WebAssembly**. The existing `node` binding target cannot
be reused: napi-rs produces a native `.node` addon for a Node process, not something a browser
can load.

Everything else in this project is a React app talking to APIs that already work.

## Why this is not simply "port the iOS client"

Three properties the native apps rely on do not hold in a browser.

**Storage is evictable.** iOS and Android hold Olm sessions in the Keychain / Keystore, which
persist until the app is uninstalled. IndexedDB can be cleared by the browser under storage
pressure, by the user clearing site data, or by ITP after a period of inactivity. A wiped
session store is not a logout — it is a device that still exists server-side but can no longer
decrypt anything addressed to it. The client must detect this and re-link rather than silently
show empty chats.

**Multiple tabs are multiple writers.** Two tabs of the same origin share one IndexedDB. Two
copies of a ratchet advancing independently corrupt each other, and a corrupted Olm session
cannot be repaired — it can only be torn down and re-established, losing in-flight messages.
One tab must own the crypto; the rest proxy to it.

**There is no background execution.** A closed tab receives nothing. Missed messages must be
fetched on reconnect, which the existing sync endpoint already supports, but the UI has to be
honest that a browser is not a phone: it catches up, it does not stay caught up.

## Architecture

```
   Browser tab (leader)                     Other tabs
   ┌────────────────────────┐               ┌───────────┐
   │ React UI               │               │ React UI  │
   │ ├─ WASM e2e-core       │◄── BroadcastChannel ──────┤
   │ ├─ IndexedDB (sessions)│               │ (proxy)   │
   │ └─ WebSocket           │               └───────────┘
   └──────────┬─────────────┘
              │ HTTPS + WSS
        ┌─────▼──────┐
        │ Voiid API  │  (unchanged)
        └────────────┘
```

**Leader election** via Web Locks: the tab holding the lock owns the WASM instance, the
IndexedDB writes and the socket. Others render from a shared read model and post intents to
the leader. This is the single most important structural decision — get it wrong and sessions
corrupt in ways that are invisible until a message fails to decrypt days later.

## Phases

Each phase ends in something demonstrable. No phase depends on a later one being designed.

### Phase 1 — WASM crypto (the risk lives here)

- `wasm-bindgen` target in `packages/e2e-core`, alongside the existing UniFFI exports
- `build-web.sh`, mirroring `build-apple.sh` / `build-android.sh`
- Prove: generate an identity, encrypt to a native device, decrypt its reply

**Exit test:** a browser and the iOS app exchange a message both can read.

**Risks:** vodozemac's dependency tree must compile to `wasm32-unknown-unknown`; anything
pulling `getrandom` needs the `js` feature. Bundle size wants measuring early — a multi-MB
WASM blob on a login page is a product problem, not just a technical one.

### Phase 2 — Linking

- QR rendering from `POST /linking/request`
- Poll `GET /linking/poll/:link_token`, store the returned session
- IndexedDB schema for identity, sessions, device id
- Wipe-and-relink path for evicted storage

**Exit test:** scan from the phone, browser lands authenticated, survives a reload.

**No backend work.** The endpoints exist and are hardened.

### Phase 3 — Messaging

- Conversation list, thread view, send, receive, history paging
- Receipts (delivered / read), matching the semantics the native clients use
- Sync-on-open, since a browser misses everything while closed

**Exit test:** a full conversation with an Android device, ticks correct on both sides.

### Phase 4 — Live

- WebSocket: inbound messages, presence, typing
- Reconnect with backlog drain
- Leader election, so multiple tabs stop being a correctness hazard

**Exit test:** two tabs open, no duplicate decrypts, no session corruption.

### Phase 5 — Media and hardening

- Encrypted media download and decrypt; upload
- Logout wipes IndexedDB completely
- Session-eviction detection and recovery
- Storage-pressure handling

## Explicitly out of scope

**Calls.** `linking.ts` says it: *"messaging only; no calls."* LiveKit in a browser with
frame-cryptor keys is its own project, and a linked companion has no CallKit equivalent to
integrate with.

**Also out:** Clips, Games, Map, Communities, Stories. The web client is a messaging companion.

## Sequencing against everything else

Do not start Phase 1 while these are open:

- Three chat fixes (duplicates, iOS push token, in-app banners) — **unverified on devices**
- CI red on 2 of 6 jobs
- S04 — the P0 recovery-PIN gate, needs a cryptographic reviewer
- TestFlight round not yet run

A web client adds a third platform to keep in parity. Adding it while the first two have
unverified message-delivery bugs means debugging three clients against one moving backend.

## Estimate

3–6 weeks for one developer to Phase 4. Phase 1 carries most of the uncertainty: if vodozemac
compiles to WASM cleanly it is days, and if it does not, that is the whole schedule.

Nothing here needs backend changes. That is the good news, and it is because the linking
protocol was designed for this case before the client existed.
