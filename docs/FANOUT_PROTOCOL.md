# Multi-device fan-out protocol (per-device envelope)

**Status:** DESIGN — for alignment between backend (me) + client (Priyanshu) before either side codes it. Date 2026-07-18.

## The problem
Today `POST /messages/send` takes **one** `ciphertext` and relays **per-user**. But E2EE gives each *device* its own session (vodozemac), so a recipient's *second* device receives a blob it can't decrypt → the well-known "recipient multi-device" gap (Nehal's PR #26 fixed *sender*-multi-device; this fixes *recipient*-multi-device — the last 1:1 gap).

## The crypto is already done ✅
`packages/e2e-core` exposes `DeviceFanout`:
```
DeviceFanout::new()
  .add_device(device_id, session)   // one session per target device
  .encrypt(plaintext) -> Vec<DeviceMessage>   // encrypts ONCE per device
```
So the client can produce one ciphertext per target device in a single call. This spec only defines how those travel.

## Envelope — the change to `POST /messages/send`
**Additive + back-compatible.** Keep the legacy single-`ciphertext` body working; add an optional `messages[]` bundle. If `messages[]` is present, use per-device; else fall back to legacy (single-device path).

```jsonc
POST /v1/messages/send
{
  "conversation_id": "…",
  "sender_device_id": "…",
  "content_type": "text",            // metadata, same for all recipients
  "media_url": null, "media_mime": null,
  "messages": [                      // one entry per TARGET device
    { "recipient_device_id": "devA", "ciphertext": "<b64>" },
    { "recipient_device_id": "devB", "ciphertext": "<b64>" },
    …                               // every recipient device + sender's OTHER devices
  ]
}
```
Response: `{ "message_id": "…", "delivered_devices": N }`.

## Client responsibilities (Priyanshu)
1. Resolve target devices: for each conversation member, `GET /v1/devices/:user_id` → their active device ids; **plus the sender's own other devices** (so your linked devices see your sent messages).
2. Ensure a session per target device (existing prekey flow, per device).
3. Build `DeviceFanout`, `add_device` each, `encrypt(plaintext)` once → `Vec<DeviceMessage>`.
4. POST the `messages[]` bundle.
5. On receive: `GET /v1/messages/pending` returns **only this device's** ciphertext; decrypt with that peer-device session.

## Backend responsibilities (me)
1. **Schema:** add `message_ciphertexts (message_id FK, recipient_device_id FK devices, ciphertext bytea, delivered_at, PRIMARY KEY(message_id, recipient_device_id))`. Keep one canonical `messages` row for metadata (sender, ts, conversation) — the per-device ciphertext lives in the new table. (No plaintext, ever.)
2. **Send:** insert the `messages` row + one `message_ciphertexts` row per `messages[]` entry.
3. **Relay:** publish per-device (`channel:device:{recipient_device_id}`) so a live socket for that specific device gets its own ciphertext. (WS layer subscribes per connected device.)
4. **Pending fetch:** `GET /messages/pending` filters `message_ciphertexts` by the caller's `device_id`, returns only its ciphertext; mark `delivered_at` when fetched.
5. **Back-compat:** if legacy single `ciphertext` arrives, keep today's behaviour (store on the `messages` row, per-user relay).

## Open questions to agree
1. **Sender fan-out to own devices** — confirm the client includes the sender's other devices in `messages[]` (needed for linked-device sync of sent messages).
2. **Missing-session handling** — if the client can't build a session for a target device (no prekeys), does it skip that device (and retry later) or fail the send? Propose: skip + flag, deliver to the rest, retry on next prekey availability.
3. **Relay granularity** — per-device channel (`channel:device:{id}`) vs per-user with a device filter. Propose per-device channel; needs the WS layer to subscribe per connected device (small change).
4. **Cutover** — ship additive (both paths live), clients migrate to `messages[]`, then retire the legacy single-ciphertext path once all clients send bundles.

## Split of work
- **Backend (me):** the `message_ciphertexts` table, the send/pending/relay changes, back-compat, WS per-device subscribe. All verifiable server-side.
- **Client (Priyanshu):** device enumeration, `DeviceFanout` wiring, sending the bundle, per-device receive. Native, his domain.

**Both must land together** (the contract changes on both sides) — hence this doc, so we agree the shape first. Once agreed, I build the backend half on a branch; Priyanshu builds the client half; we integrate.
