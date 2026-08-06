// Content reports — the user-facing half (plan item 3.29).
//
// There was no way for anyone to report anything. The schema (035_reports.sql) shipped and
// nothing wrote to it; this is the endpoint that does, plus the queue the admin panel reads.
//
// ── WHAT A REPORT MAY CARRY, AND WHAT IT MAY NOT ─────────────────────────────────
// Reporting a CLIP or a CREATOR is unremarkable: that content is already public and the
// server can read it (022_clips.sql).
//
// Reporting a MESSAGE SENDER is the delicate one, and the schema names it carefully — the
// target is the PERSON, never a message. There is no 'message' target type and no
// message_id column, precisely so nobody can later build "fetch the reported message",
// which is unbuildable and must stay unbuildable: the server has no key.
//
// If a reporter wants a moderator to see what was said, they must ATTACH it themselves.
// That is the `reporter_attached` disclosure, and it means the reporter deliberately
// decrypted something on their device and chose to hand it over. Anything else is
// metadata_only, which is the default, and which is all the server could produce anyway.
import { Router } from 'express';
import { query } from '../db';
import { requireAuth } from '../auth';
import { asyncHandler } from '../util';

const router = Router();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const TARGET_TYPES = ['clip', 'creator', 'message_sender'] as const;
const REASONS = [
  'spam', 'harassment', 'hate', 'violence', 'nudity',
  'self_harm', 'child_safety', 'impersonation', 'illegal', 'other',
] as const;

const MAX_NOTE = 1000;
/**
 * Attached evidence is bounded hard. A reporter choosing to hand over a conversation
 * excerpt is legitimate; a client shipping a whole thread through this endpoint is not —
 * that would turn a report into a backdoor for bulk plaintext upload, which is exactly the
 * shape this feature must not have.
 */
const MAX_EVIDENCE_BYTES = 16 * 1024;

// ─────────────────────────────────────────────────────────────────────────────────
// POST /reports  { target_type, target_id, reason, note?, disclosure?, evidence?,
//                  context_conversation_id? }
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const {
    target_type, target_id, reason, note,
    disclosure, evidence, context_conversation_id,
  } = req.body ?? {};

  if (!TARGET_TYPES.includes(target_type)) {
    return res.status(400).json({ error: `target_type must be one of ${TARGET_TYPES.join(', ')}` });
  }
  if (typeof target_id !== 'string' || !UUID_RE.test(target_id)) {
    return res.status(400).json({ error: 'target_id must be a uuid' });
  }
  if (!REASONS.includes(reason)) {
    return res.status(400).json({ error: 'unknown reason' });
  }
  if (note != null && (typeof note !== 'string' || note.length > MAX_NOTE)) {
    return res.status(400).json({ error: `note must be under ${MAX_NOTE} characters` });
  }
  if (target_id === user_id) {
    return res.status(400).json({ error: 'you cannot report yourself' });
  }

  // Evidence is only meaningful for a message_sender report — the schema enforces the same
  // constraint, but rejecting it here gives the client a readable error instead of a 500
  // from a check violation.
  const wantsAttachment = disclosure === 'reporter_attached';
  if (wantsAttachment && target_type !== 'message_sender') {
    return res.status(400).json({ error: 'attachments only apply to reporting a person' });
  }
  if (evidence != null) {
    if (target_type !== 'message_sender') {
      return res.status(400).json({ error: 'evidence only applies to reporting a person' });
    }
    const size = Buffer.byteLength(JSON.stringify(evidence), 'utf8');
    if (size > MAX_EVIDENCE_BYTES) {
      return res.status(413).json({ error: 'attached excerpt is too large' });
    }
  }

  // The target must exist — but the response NEVER says whether it did. A report endpoint
  // that distinguishes "no such clip" from "reported" is an existence oracle for content
  // the caller may not be able to see, and for user ids generally.
  const exists = target_type === 'clip'
    ? (await query(`select 1 from clips where id = $1 limit 1`, [target_id])).length > 0
    : (await query(`select 1 from users where id = $1 and deleted_at is null limit 1`, [target_id])).length > 0;

  if (exists) {
    // ON CONFLICT DO NOTHING against the anti-report-bombing key in 035: one open report per
    // (reporter, target). A second report of the same thing is not new information, and
    // letting it through would let one person inflate a queue.
    await query(
      `insert into content_reports
         (target_type, target_id, reporter_user_id, reason, note, disclosure, evidence,
          context_conversation_id)
       values ($1, $2, $3, $4, $5, $6, $7::jsonb, $8)
       -- The index is PARTIAL (where status = 'open'), so the conflict target must repeat
       -- its predicate — a bare ON CONFLICT DO NOTHING does not match a partial index and
       -- would raise "no unique or exclusion constraint matching" at runtime.
       on conflict (target_type, target_id, reporter_user_id) where status = 'open'
       do nothing`,
      [
        target_type, target_id, user_id, reason,
        typeof note === 'string' && note.trim() ? note.trim() : null,
        wantsAttachment ? 'reporter_attached' : 'metadata_only',
        evidence != null ? JSON.stringify(evidence) : null,
        typeof context_conversation_id === 'string' && UUID_RE.test(context_conversation_id)
          ? context_conversation_id : null,
      ]
    );
  }

  // The SAME answer either way, and deliberately so: it is also the honest one. A report is
  // received, not adjudicated, and telling the reporter "thanks, we'll look" is true
  // regardless of whether the target existed.
  return res.status(202).json({ received: true });
}));

export default router;
