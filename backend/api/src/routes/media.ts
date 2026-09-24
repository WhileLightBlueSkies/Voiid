// Media routes. The blob is encrypted ON-DEVICE (e2e-core encryptMedia) BEFORE
// upload; the server only signs short-lived R2 URLs and never sees the bytes or
// the media key. Flow:
//   1. client: encryptMedia(blob) -> ciphertext + media key (the key is wrapped
//      inside the E2EE message, never sent here)
//   2. POST /media/presign-upload -> { key, upload_url }
//   3. client PUTs ciphertext to upload_url (direct to R2)
//   4. client sends the E2EE message carrying media_url=key (+ media_mime)
//   5. recipient: POST /media/presign-download { key } -> { download_url }; GET; decrypt
import { Router } from 'express';
import { asyncHandler } from '../util';
import { randomUUID } from 'crypto';
import { requireAuth } from '../auth';
import { presignPut, presignGet, objectExists, r2Configured } from '../r2';

const router = Router();

// The chat limit: 25 MB of plaintext, as the apps show it (decimal megabytes). Encryption adds
// a tag and nonce, so the ciphertext is allowed a little over. The apps compress anything
// bigger on the phone before it gets here (ChatMediaCompressor.swift).
export const CHAT_MEDIA_MAX_PLAINTEXT = 25_000_000;
const CHAT_MEDIA_MAX_CIPHERTEXT = CHAT_MEDIA_MAX_PLAINTEXT + 4096;

// POST /media/presign-upload  { mime? }  -> { key, upload_url }
// `key` is an opaque object id the client then puts into the E2EE message's
// media_url field. The actual bytes are ciphertext.
router.post('/presign-upload', requireAuth, asyncHandler(async (req, res) => {
  if (!r2Configured()) return res.status(503).json({ error: 'media storage not configured' });
  const { user_id } = (req as any).auth;
  const mime = typeof req.body?.mime === 'string' ? req.body.mime : 'application/octet-stream';

  // `size` is the ciphertext length the client is about to PUT. Clients that predate the
  // limit do not send it, and are let through rather than broken mid-rollout.
  const size = req.body?.size;
  if (size !== undefined) {
    if (typeof size !== 'number' || !Number.isInteger(size) || size <= 0) {
      return res.status(400).json({ error: 'size must be a positive integer' });
    }
    if (size > CHAT_MEDIA_MAX_CIPHERTEXT) {
      return res.status(413).json({ error: 'Files can be up to 25 MB.', code: 'media_too_large',
                                     max_bytes: CHAT_MEDIA_MAX_PLAINTEXT });
    }
  }

  // Namespace by uploader + random id. Content is ciphertext, so the key reveals
  // nothing about the media; the mime is the WRAPPER type (octet-stream), the
  // real media type travels encrypted in the message.
  const key = `media/${user_id}/${randomUUID()}`;
  try {
    const upload_url = await presignPut(key, mime);
    res.json({ key, upload_url });
  } catch (e) {
    return res.status(500).json({ error: (e as Error).message });
  }
}));

// POST /media/presign-download  { key }  -> { download_url }
// Caller must be authenticated; the bytes are useless without the per-message
// media key (which only conversation members can decrypt), so access control is
// the E2E key itself. We still require a valid session to sign a URL.
router.post('/presign-download', requireAuth, asyncHandler(async (req, res) => {
  if (!r2Configured()) return res.status(503).json({ error: 'media storage not configured' });
  const key = req.body?.key;
  if (typeof key !== 'string' || !key.startsWith('media/')) {
    return res.status(400).json({ error: 'valid media key required' });
  }
  // Story expiry and audience authorization belong to the story-specific endpoint.
  if (key.startsWith('media/stories/')) {
    return res.status(403).json({ error: 'use the story download endpoint' });
  }
  try {
    const download_url = await presignGet(key);
    res.json({ download_url });
  } catch (e) {
    return res.status(500).json({ error: (e as Error).message });
  }
}));

// POST /media/confirm  { key }  -> { exists }
// Optional: the sender can confirm the upload landed before sending the message.
router.post('/confirm', requireAuth, asyncHandler(async (req, res) => {
  if (!r2Configured()) return res.status(503).json({ error: 'media storage not configured' });
  const key = req.body?.key;
  if (typeof key !== 'string' || !key.startsWith('media/')) {
    return res.status(400).json({ error: 'valid media key required' });
  }
  res.json({ exists: await objectExists(key) });
}));

export default router;
