# VOIID Stories — protocol & privacy model

Stories are 24-hour ephemeral media. This document is the contract between the
clients and `backend/api/src/routes/stories.ts`, and — more importantly — the
honest statement of what the server does and does not learn.

Companion docs: `docs/FANOUT_PROTOCOL.md` (the per-device envelope pattern this
reuses), `docs/DEPLOYMENT.md` (`voiid-workers` + the R2 lifecycle rule).

---

## 1. One paragraph

A story is the existing media-message flow with the recipient set widened from
"one peer's devices" to "the chosen audience's devices". The blob is encrypted
**once** on-device with a fresh random AES-256-GCM key (`encryptMedia`), the
ciphertext is PUT **once** straight to R2 via a presigned URL, and a ~400-byte
JSON envelope carrying that key is encrypted **once per target device** over that
device's existing Double Ratchet session and stored in `story_keys` —
structurally identical to `message_ciphertexts`. **Zero changes to
`packages/e2e-core`.**

---

## 2. What the server sees, precisely

| Endpoint | Server learns | Server does NOT learn |
|---|---|---|
| `POST /v1/stories/presign-upload` | that this user wants to upload something | what it is |
| *(client PUTs to R2 directly)* | opaque bytes at an opaque key | the key, nonce, real mime, dimensions — the bytes never enter the API process |
| `POST /v1/stories` | author user + device, the R2 key, the **wrapper** mime, a ciphertext byte count, a timestamp, and **the set of device ids that received key material** | the media key, the real mime, the caption, the dimensions, the bytes |
| `GET /v1/stories/feed` | which device fetched which envelope, when | the envelope contents |
| `POST /v1/stories/presign-download` | that an entitled user wants the object | the plaintext |
| `POST /v1/stories/:id/receipt` | that the authenticated caller submitted a receipt for a story (see §5) | it does not *store* the viewer id — that lives inside the ciphertext |
| `DELETE /v1/stories/:id` | that the author deleted it | — |

There is **no field on any of these endpoints through which a media key can
arrive**, and the server never fetches the R2 object.

### 2.1 The audience is metadata we do NOT hide

`story_keys` holds one row per recipient **device**, and `devices.user_id` maps
each to a user. **The server can therefore enumerate exactly who you sent a story
to, and when.**

This cannot be hidden with the primitives available: there is no sealed sender in
Voiid, and one cannot be added (the `e2e-core` FFI surface is frozen — the
bindings cannot be regenerated). The fan-out must be addressed to real device ids
for the relay to work at all.

The clients state this in the audience picker, verbatim:

> *"Voiid can't read your story, but it does see who you send it to."*

Do not omit it. Do not soften it.

---

## 3. The protocol, step by step

**Author device, posting to audience `A = {u1..uN}`:**

1. **Mint the id** — `story_id = UUIDv4`, client-supplied (precedent: `calls.id`).
   Required because the envelope must *bind* `story_id`, and the envelope is
   encrypted **before** the POST that creates the row.
2. **Encrypt the media** — `enc = encryptMedia(bytes)`. `enc.mediaKey.{key,nonce}`
   NEVER leave E2E.
3. **`POST /v1/stories/presign-upload {mime?}`** → `{ key, upload_url }`. `key` is
   `media/stories/<user_id>/<uuid>`. The `mime` handed to the presigner is the
   **wrapper** type (`application/octet-stream`); the real media type rides
   encrypted inside the envelope.
4. **PUT the ciphertext directly to R2.** Bytes never transit the API process.
5. **Build the envelope** (§4).
6. **Resolve targets** — `GET /v1/devices/:user_id` per audience member, plus the
   author's own other devices (so linked devices show "My story" and can collect
   view receipts), excluding the posting device.
7. **Fan out** — reuse the stable session, or establish one from
   `GET /v1/prekeys/:user_id` (fetch **once per user**, never per device — each
   fetch consumes a one-time key). Then `ciphertext_d = Session.encrypt(envelope)`.
   Devices with no bundle / no available one-time prekey are **skipped and
   logged**, not fatal — the composer reports "Sent to 46 of 48" and
   `POST /v1/stories/:id/keys` retries the rest.
8. **`POST /v1/stories`** with `{story_id, r2_key, media_mime, byte_size,
   sender_device_id, keys[]}`.
9. **Relay** — the API publishes one routing-only signal per user to
   `channel:user:<uid>`:
   `{"type":"story","story_id":"…","author_id":"…","recipient_device_ids":[…]}`.
   A device's ciphertext is **never** placed on the shared user channel. Each woken
   device calls `GET /v1/stories/feed` and pulls its own blob. Plus a content-free
   wake push.

**Recipient device:** `GET /v1/stories/feed?device_id=` → its own `ciphertext` →
`Session.decrypt` → envelope → **validate (§4.1)** → persist locally → on open,
`POST /v1/stories/presign-download {story_id}` → GET from R2 →
`decryptMedia(mediaKey, ciphertext)` → render.

---

## 4. The envelope

This is the **authenticated plaintext** of the per-device ratchet message. There
is **no AAD parameter on any AEAD in `e2e-core`**, so `story_id`/author/expiry
cannot be bound at the AEAD layer — they go *inside* the plaintext, where GCM
authenticates them.

```jsonc
{
  "v": 1,
  "t": "story",
  "story_id":       "<uuid>",
  "author_id":      "<uuid>",
  "created_at":     1750000000000,   // epoch ms
  "expires_at":     1750086400000,   // created_at + 24h — the AUTHOR's claim
  "media": {                         // == the EXISTING MediaRef shape, verbatim
    "mediaUrl": "media/stories/<uid>/<uuid>",
    "mime":     "image/jpeg",        // the REAL type
    "key":      "<base64 32B>",
    "nonce":    "<base64 12B>",
    "sha256":   "<base64 ciphertext hash>"
  },
  "caption":        "",
  "durationMs":     null,            // video only; drives the segment timer
  "width":          1080,
  "height":         1920,
  "allowsReplies":  true
}
```

### 4.1 Receiver-side validation — MANDATORY

**Any authenticated user can POST a story targeting your device id.** The server
does not and cannot validate the envelope (it cannot read it). The receiving
client MUST, before showing anything:

1. Envelope `story_id` **==** the feed row's `story_id`. Else drop.
2. Envelope `author_id` **==** the feed row's `author_id`. Else drop. *(Without
   this the server could reattribute a story; authorship on this path is
   server-asserted metadata **plus** this in-plaintext binding.)*
3. Envelope `media.mediaUrl` **==** the feed row's `r2_key`. Else drop.
4. `expires_at <= created_at + 24h + 60s` skew. Else clamp to `created_at + 24h`.
5. Author is a **known contact** and **not blocked**. Else drop silently. *(Without
   this, strangers push media into your story feed.)*
6. Duplicate `story_id` already stored → ignore.
7. `decryptMedia` verifies the ciphertext SHA-256 before decrypting — surface a
   failure as "This story couldn't be loaded", never as a blank frame.

---

## 5. View receipts — OFF by default

Sending a view receipt tells the **Voiid server** that user A opened user B's
story at time T. The server has no other way to learn that — it delivered a key,
which does not mean the story was opened. There is no sealed sender and one
cannot be added, so there is no way to send a receipt without the server
authenticating and therefore identifying the viewer.

Given "the server learns a new behavioural fact about every user by default" vs
"the viewer list starts empty until people opt in", the privacy-preserving
default is the second. **`Settings → Privacy → Story view receipts` defaults to
OFF**, and the opt-out is **reciprocal**: with it off you send no receipts, your
own viewer list is hidden, and incoming receipts are discarded on decrypt.

`story_receipts` deliberately has **no `viewer_user_id` column** — the viewer
identity lives inside the encrypted payload, openable only by the author's
devices. **The missing column is not a defence.** The API authenticates whoever
POSTs the receipt, so the server *can* observe it; the schema is a statement that
we do not **store** it. Never describe it as anything stronger.

With receipts off, your own stories still show a **delivered-device count** from
`GET /v1/stories/mine`. That is routing metadata the server already has (it wrote
the rows) and it is **not a view** — a delivered envelope means a device fetched
it, not that a human opened it. Label it accordingly.

---

## 6. Expiry

`stories.expires_at = created_at + interval '24 hours'`, **computed server-side at
insert**. The envelope's `expires_at` is the author's claim, used only as an
offline fallback for an already-cached story.

**Visibility is independent of cleanup.** Every server read path filters
`and s.expires_at > now()`; every client read path filters `expires_at > now()`.
Expiry is therefore correct even if the reaper has been dead for a week. **Never
rely on the reaper for visibility.** This is non-negotiable.

| Artifact | Deleted by | When |
|---|---|---|
| `stories` row | `voiid-workers` | `expires_at + 1h` grace |
| `story_keys` / `story_receipts` | `on delete cascade` | with the row |
| R2 object | worker calls `deleteObject(key)` **before** deleting the row | `expires_at + 1h` grace |
| R2 orphans | bucket lifecycle rule on prefix `media/stories/` | 48h |
| Local rows + cached plaintext | client sweep | on app foreground and on viewer open |

The **1h grace** exists so a client that started a download at T+23:59 does not
404 mid-fetch. The **48h lifecycle rule** is the orphan net, deliberately wider
than the reaper so the reaper — code in this repo — stays the primary mechanism.

Because rows and objects expire independently, both clients must tolerate:

- object gone, row present → **"This story is no longer available"**
- row gone, object present → harmless ciphertext garbage, swept by the lifecycle rule

### 6.1 The 48-hour-offline device

- Every story posted more than 24h ago is excluded by `expires_at > now()`,
  regardless of whether the reaper has run.
- Its `story_keys` rows are deleted by cascade when the reaper takes the row.
  **There is no "you missed these" backfill and none will be built.**
- Stories posted within the last 24h **are** delivered, with their remaining
  lifetime. A story posted 23h ago shows for 1h.
- There is **no Double-Ratchet backlog hazard**: story keys are ordinary ratchet
  messages at ≤20/author/day — nowhere near `MAX_MESSAGE_KEYS=40` skipped keys or
  `MAX_MESSAGE_GAP=2000`.

A client that loses its local DB (reinstall) can re-pull live envelopes with
`GET /v1/stories/feed?device_id=&include_delivered=1`, which returns
already-delivered live rows without touching `delivered_at`. There is no other way
back to its own key blobs — the sender's ratchet message is long gone.

---

## 7. Authorization

Everything below is enforced in code in `routes/stories.ts`, not by comment:

| Operation | Rule |
|---|---|
| `POST /v1/stories` | `r2_key` must be exactly `media/stories/<caller>/<uuid>` — you cannot claim another user's object key. A body-supplied `sender_device_id` must be one of the caller's own devices. |
| `GET /v1/stories/feed` | the `device_id` must belong to the caller (403 otherwise), and the SQL returns only envelopes addressed to that device. |
| `GET /v1/stories/receipts` | same device-ownership check. |
| `POST /v1/stories/presign-download` | caller must be the author **or** own a device holding a `story_keys` row for the story, and the story must be live. 404 for expired *and* nonexistent — distinguishing them would confirm a story id was real. |
| `POST /v1/stories/:id/keys` | author-only, live story only. |
| `POST /v1/stories/:id/receipt` | caller must hold a `story_keys` row for the story (you cannot claim to have viewed a story you were not sent), **and** every receipt target must be a live device of that story's author. |
| `DELETE /v1/stories/:id` | author-only. |

Fan-out inserts resolve device ids against `devices` first and skip unknown or
**revoked** devices — a revoked device must never be handed key material, and one
stale id in a bundle must not fail the whole story.

### 7.1 Why stories get their own download endpoint

`POST /v1/media/presign-download` authorizes on *"authenticated AND key starts
with `media/`"* only. A leaked `(mediaKey, objectKey)` pair therefore lets **any
logged-in Voiid user** fetch and decrypt. `POST /v1/stories/presign-download`
checks actual entitlement instead.

**This is defence in depth, NOT a guarantee.** The object still sits under the
`media/` prefix, so the generic endpoint would still serve it to anyone who
learned the key. Access control is ultimately the E2E media key. Do not describe
it otherwise in UI or docs.

---

## 8. Honest limits — state these, do not ship UI that contradicts them

- **Every viewer gets the same key for the same blob.** One leaking viewer leaks
  the story to whoever they give the key to. Inherent to any story feature; not a
  bug.
- **Revocation after delivery is impossible.** No primitive expires, rotates, or
  zeroizes a delivered key. Deleting a story deletes the R2 object and the rows;
  anyone who already downloaded keeps it forever. **Never ship UI promising
  "remove viewer" as a security property.** The delete confirm dialog must say so.
- **"24 hours" is policy, not cryptography.** Enforced by client-side filtering +
  server-side deletion.
- **View-once and screenshot prevention cannot be enforced.** Out of scope, and
  shipping either would be a lie.
- **The audience is metadata the server learns.** See §2.1.
- **No sender-key / sealed-sender multi-recipient envelope.** Signal's bandwidth
  optimisation does not exist in Voiid and cannot be added here. Our fan-out is N
  small ciphertexts. Do not imply parity.
- **No chunked/streaming media encryption.** `encrypt_media` takes and returns a
  whole `Vec<u8>`, so the blob is held in memory twice and crosses the FFI twice.
  This is why the client size caps (images ≤10 MB, video ≤30 s / ≤50 MB) are hard
  requirements, not suggestions.

---

## 9. Rejected designs (do not revisit)

- **An MLS group per story audience.** There is no `leave_group`/`delete_group` on
  the FFI, so every ephemeral story group would be welded permanently into the
  single whole-state Keychain blob that all *real* group chats depend on. Each add
  also burns one published KeyPackage from a batch of only 10.
- **Keying a story from a group's exporter secret.** `GroupSession.callKeys()`
  yields `SrtpKeys{16B key, 14B salt}` = 30 bytes; `to_key32` hard-rejects
  anything ≠ 32 bytes.
- **A forward-secret key chain per story.** No KDF is exported. Every key is
  freshly random and individually shipped.
- **Opportunistic expiry sweeps inside request handlers.** If the route is cold
  nothing runs, so R2 orphans live forever, and a user's request pays an unbounded
  latency cost for someone else's cleanup.
- **pg_cron + a lifecycle rule alone.** Retention would become a console setting
  outside the repo, and the DB half and object half would drift silently apart.
