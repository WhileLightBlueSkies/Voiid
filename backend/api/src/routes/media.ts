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
import { randomUUID } from 'crypto';
import { requireAuth } from '../auth';
import { presignPut, presignGet, objectExists, r2Configured } from '../r2';

const router = Router();

// POST /media/presign-upload  { mime? }  -> { key, upload_url }
// `key` is an opaque object id the client then puts into the E2EE message's
// media_url field. The actual bytes are ciphertext.
router.post('/presign-upload', requireAuth, async (req, res) => {
  if (!r2Configured()) return res.status(503).json({ error: 'media storage not configured' });
  const { user_id } = (req as any).auth;
  const mime = typeof req.body?.mime === 'string' ? req.body.mime : 'application/octet-stream';

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
});

// POST /media/presign-download  { key }  -> { download_url }
// Caller must be authenticated; the bytes are useless without the per-message
// media key (which only conversation members can decrypt), so access control is
// the E2E key itself. We still require a valid session to sign a URL.
router.post('/presign-download', requireAuth, async (req, res) => {
  if (!r2Configured()) return res.status(503).json({ error: 'media storage not configured' });
  const key = req.body?.key;
  if (typeof key !== 'string' || !key.startsWith('media/')) {
    return res.status(400).json({ error: 'valid media key required' });
  }
  try {
    const download_url = await presignGet(key);
    res.json({ download_url });
  } catch (e) {
    return res.status(500).json({ error: (e as Error).message });
  }
});

// POST /media/confirm  { key }  -> { exists }
// Optional: the sender can confirm the upload landed before sending the message.
router.post('/confirm', requireAuth, async (req, res) => {
  if (!r2Configured()) return res.status(503).json({ error: 'media storage not configured' });
  const key = req.body?.key;
  if (typeof key !== 'string' || !key.startsWith('media/')) {
    return res.status(400).json({ error: 'valid media key required' });
  }
  res.json({ exists: await objectExists(key) });
});

export default router;
