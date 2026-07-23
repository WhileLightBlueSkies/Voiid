// Encrypted-backup routes. The backup blob is E2E-encrypted ON-DEVICE (under the
// master backup secret, see e2e-core src/recovery.rs) BEFORE upload — the server
// only ever sees ciphertext, never plaintext or the backup key. The blob lives in
// R2; this API stores a metadata pointer (r2_object_key + size) in `backups`.
//
// Unlike media (client PUTs straight to R2 via a presigned URL), the backup blob
// is accepted THROUGH the API as raw bytes and written to R2 server-side, then
// served back on GET as a short-lived presigned R2 download URL.
import express, { Router } from 'express';
import { requireAuth } from '../auth';
import { query } from '../db';
import { putObject, presignGet, r2Configured } from '../r2';

const router = Router();

// Max accepted backup size. The blob is message/metadata ciphertext (media lives
// separately in R2), so a few tens of MB is ample. Override with BACKUP_MAX_BYTES.
const MAX_BACKUP_BYTES = Number(process.env.BACKUP_MAX_BYTES) || 50 * 1024 * 1024; // 50 MiB

// Raw-body parser scoped to PUT /backup only (the global express.json parser skips
// non-JSON content types, so the octet-stream body reaches this untouched).
const rawBackup = express.raw({ type: () => true, limit: MAX_BACKUP_BYTES });

// PUT /backup — upload the encrypted backup blob (Content-Type: application/octet-stream).
// Stores the ciphertext in R2 and upserts the caller's backup metadata.
router.put(
  '/',
  requireAuth,
  (req, res, next) => {
    // Cheap up-front guard so an oversized upload gets a clean 413 without being
    // buffered into memory first. rawBackup's own limit is the hard backstop.
    const len = Number(req.headers['content-length'] ?? 0);
    if (len > MAX_BACKUP_BYTES) {
      return res.status(413).json({ error: 'backup too large', max_bytes: MAX_BACKUP_BYTES });
    }
    next();
  },
  rawBackup,
  async (req, res) => {
    if (!r2Configured()) return res.status(503).json({ error: 'backup storage not configured' });
    const { user_id } = (req as any).auth;
    const body = req.body;
    if (!Buffer.isBuffer(body) || body.length === 0) {
      return res.status(400).json({ error: 'backup blob required (send raw bytes as application/octet-stream)' });
    }

    // Stable key per user — a new backup overwrites the previous one (no orphans).
    const key = `backups/${user_id}`;
    try {
      await putObject(key, body, 'application/octet-stream');
    } catch (e) {
      return res.status(500).json({ error: (e as Error).message });
    }
    await query(
      `insert into backups (user_id, r2_object_key, size_bytes)
         values ($1, $2, $3)
         on conflict (user_id) do update set
           r2_object_key = excluded.r2_object_key,
           size_bytes    = excluded.size_bytes`,
      [user_id, key, body.length]
    );
    res.json({ stored: true, size_bytes: body.length });
  }
);

// GET /backup — return a short-lived presigned R2 download URL for the caller's
// encrypted backup blob (+ size/updated_at metadata). 404 if none.
router.get('/', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const rows = await query<{ r2_object_key: string; size_bytes: string; updated_at: Date }>(
    `select r2_object_key, size_bytes, updated_at from backups where user_id = $1`,
    [user_id]
  );
  const row = rows[0];
  if (!row) return res.status(404).json({ error: 'no backup found' });
  if (!r2Configured()) return res.status(503).json({ error: 'backup storage not configured' });

  try {
    const download_url = await presignGet(row.r2_object_key);
    res.json({ download_url, size_bytes: Number(row.size_bytes), updated_at: row.updated_at });
  } catch (e) {
    return res.status(500).json({ error: (e as Error).message });
  }
});

export default router;
