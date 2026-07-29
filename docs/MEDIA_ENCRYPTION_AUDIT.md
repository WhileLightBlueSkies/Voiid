# Chat & group media on R2 — what is actually protected, and what leaks

Status: **findings only, nothing fixed yet.** Written 2026-07-29 in response to the question
"we want images and video shared in chat and groups to be encrypted, but we're using an R2 bucket
and a preview is showing — what are the drawbacks?"

Short answer: **the bytes are genuinely safe. Three pieces of metadata are not.** None of them
expose message content, but two of them make it possible to tell *what kind* of media a person
sent, to whom, and when — which is exactly the class of thing a private messenger should not hand
over.

---

## 1. What the system does correctly

The media path is sound in its core design:

1. `encryptMedia` (e2e-core) encrypts the blob **on-device** with a fresh AES-256-GCM key.
2. The client PUTs the **ciphertext** straight to R2 via a presigned URL. Bytes never transit the
   API process.
3. The media key travels **inside** the Double-Ratchet message plaintext (`MediaRef` in
   [ChatEngine.swift](../apps/ios/Voiid/Voiid/Networking/ChatEngine.swift)), so it is E2E and the
   server never holds it.
4. Object keys are `media/<uid>/<uuid>` — random, revealing nothing about content.

**So: Cloudflare cannot view the image. Voiid's server cannot view the image. That part of the
claim holds.** There is also **no thumbnail or preview generation anywhere in the chat path** — I
searched for it specifically. No thumb, no blurhash, no separate unencrypted preview file exists.

### About the preview you saw in the R2 dashboard

That is almost certainly leak #1 below. Cloudflare's object browser renders a preview **because the
object is tagged `Content-Type: image/jpeg`**, not because a plaintext copy exists. The preview
itself will be garbage — it is trying to render ciphertext. Worth confirming that is what you saw,
because "the dashboard shows a broken/noise image" and "the dashboard shows my actual photo" are
very different findings and only the second would mean encryption is failing.

---

## 2. Leak 1 — the real MIME type is sent to R2 as `Content-Type`

**Severity: medium. Fix first — it is the cheapest and it is what makes the dashboard preview.**

[ChatEngine.swift:393](../apps/ios/Voiid/Voiid/Networking/ChatEngine.swift#L393) passes the **real**
mime into `MediaService.upload`, which sets it as the `Content-Type` header on the PUT
([MediaService.swift:38](../apps/ios/Voiid/Voiid/Networking/MediaService.swift#L38)). Android does
the same at [ChatEngine.kt:269](../apps/android/app/src/main/java/com/voiid/app/net/ChatEngine.kt#L269)
→ [MediaService.kt:44](../apps/android/app/src/main/java/com/voiid/app/net/MediaService.kt#L44).

Every object in the bucket is therefore labelled `image/jpeg`, `video/mp4`, `audio/m4a`. Anyone with
bucket access — Cloudflare staff, anyone with a leaked R2 token, anyone reading a backup — can
classify every blob without decrypting anything.

**Stories already do this correctly** and the reason is written down in
[017_stories.sql](../database/migrations/017_stories.sql#L27): *"The REAL media type travels
encrypted inside the per-device envelope; NEVER store the real one here."* Chat media predates that
decision and never got it.

**Fix:** send `application/octet-stream` on the PUT; carry the real mime inside `MediaEnvelope`,
which is already E2E. Two lines per platform. Needs a rollout window — see §6.

---

## 3. Leak 2 — the real MIME is stored in Postgres in plaintext

**Severity: medium-high. This is the one with lasting consequences.**

`media_mime` is a column on `messages` ([006_messages.sql:16](../database/migrations/006_messages.sql#L16))
and is written on every media send ([messages.ts:85](../backend/api/src/routes/messages.ts#L85)).

So the database holds a permanent, queryable record of **who sent what kind of media to whom, and
when**. That is a social-graph-plus-behaviour dataset: "this person sent 40 voice notes to that
person last Tuesday night" is answerable with one SQL query, forever, without touching a single
encrypted byte. Unlike the R2 header, this survives in every database backup.

Compare stories again: `media_mime` there is `not null default 'application/octet-stream'` — the
column exists purely as a wrapper type.

**Fix:** stop writing the real mime; default the column to `application/octet-stream`. Then a
one-off `update messages set media_mime = 'application/octet-stream'` to purge the history. This is
the change that needs the most care because old clients read this field (§6).

---

## 4. Leak 3 — `presign-download` authorizes on almost nothing

**Severity: low-medium (defence in depth, not a break).**

[media.ts:44](../backend/api/src/routes/media.ts#L44) checks only *"is the caller authenticated AND
does the key start with `media/`"*. Any logged-in Voiid user who learns an object key can obtain a
presigned URL for that ciphertext.

This is **not** a content break — the bytes are useless without the media key, which only
conversation members can decrypt. But it means R2 access control is doing zero work, and it is
strictly weaker than the equivalent stories endpoint, which checks real entitlement (author, or
holds a `story_keys` row) and explains why in its own comment block.

**Fix:** verify the caller is a member of the conversation that references the key. Requires a
lookup from `media_url` → `messages.conversation_id` → membership.

---

## 5. Smaller items, listed for honesty rather than urgency

- **File size is visible.** Ciphertext length ≈ plaintext length. A 4 KB blob is a sticker; a 40 MB
  blob is a video. Hiding this needs padding buckets, which costs real bandwidth. Recommendation:
  **do not fix, but do not claim it is hidden either.**
- **Upload/download timing is visible** to the server and in R2 access logs (which IP fetched which
  object, when). Inherent to the architecture.
- **No lifecycle rule on `media/`.** Stories get reaped; chat media appears to accumulate forever,
  including orphans from uploads that never became messages. This is a cost and data-retention
  issue as much as a privacy one.
- **The sender's own `media_url` is in the plaintext message row**, so the server knows which
  message points at which object — unavoidable, since it must serve the reference.

---

## 6. Why these fixes need a rollout plan, not a single commit

`media_mime` is on the **wire and in the database**, and old clients read it. If the server stops
populating it before clients stop depending on it, media messages on un-updated devices may render
as the wrong type or fail to open.

Suggested order:

1. **Ship clients that read the real mime from inside the encrypted envelope**, falling back to the
   server's `media_mime` when the envelope field is absent. Harmless on its own.
2. **Stop sending the real mime to R2** (leak 1). No compatibility concern at all — nothing reads
   the `Content-Type` back. This can ship immediately, even before step 1.
3. Once step-1 clients are the floor (the app already has a `minSupportedVersion` force-update gate
   — use it), **stop writing the real `media_mime`** and backfill the column to
   `application/octet-stream` (leak 2).
4. **Tighten `presign-download`** (leak 3) — independent of the above, can land any time.
5. **Add the R2 lifecycle rule** on `media/`.

Steps 2 and 4 are safe to do now. Step 3 is the one that must wait for client rollout.

---

## 7. What this does *not* affect

Clips are **deliberately not encrypted** — they are public broadcast content, and that decision is
documented in [CLIPS.md](./CLIPS.md) §0 and the header of
[020_clips.sql](../database/migrations/020_clips.sql). Nothing in this audit changes that, and the
clips composer tells users so in plain language. Messages, calls, locations and moments are
unaffected by the clips work and remain E2EE.
