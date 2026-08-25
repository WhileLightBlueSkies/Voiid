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

// 053 adds the last two. 'community_post' targets the POST, never its author — reporting a
// person is what 'creator' and 'message_sender' are for, and those accumulate against an
// account, which is a different fact from "this one post is bad".
const TARGET_TYPES = ['clip', 'creator', 'message_sender', 'community_post', 'community'] as const;

/**
 * Which target kinds name a USER rather than a piece of content.
 *
 * Used only by the anti-self-report guard below. Extracted because that guard compares
 * `target_id` to the caller's user id, and doing so for a kind whose target_id is a POST id
 * would be comparing two different namespaces — harmless today, but it is the sort of thing
 * that silently becomes wrong when a fifth kind arrives.
 */
const USER_TARGET_TYPES: readonly string[] = ['creator', 'message_sender'];
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
  // The anti-self-report guard, now scoped to the kinds whose target_id IS a user id. For a
  // 'community_post' or 'community' the id names content, not a person, so this comparison
  // would be against the wrong namespace — and the real "do not report your own thing" check
  // for a post is the authorship test below, which is a different question with a different
  // answer.
  if (USER_TARGET_TYPES.includes(target_type) && target_id === user_id) {
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
  //
  // The two 053 kinds probe their own tables. `community_post` deliberately does NOT filter on
  // `removed_at is null`: a post removed between the reader seeing it and the report arriving
  // is still a report worth recording — it is evidence about the AUTHOR's behaviour that a
  // moderator reviewing an appeal needs, and dropping it would silently discard exactly the
  // reports filed about the worst content, which tends to be removed fastest.
  let exists: boolean;
  switch (target_type) {
    case 'clip':
      exists = (await query(`select 1 from clips where id = $1 limit 1`, [target_id])).length > 0;
      break;
    case 'community_post':
      exists = (await query(
        `select 1 from community_posts where id = $1 limit 1`, [target_id])).length > 0;
      break;
    case 'community':
      exists = (await query(
        `select 1 from communities where id = $1 limit 1`, [target_id])).length > 0;
      break;
    default:
      // 'creator' and 'message_sender' — both name a user.
      exists = (await query(
        `select 1 from users where id = $1 and deleted_at is null limit 1`,
        [target_id])).length > 0;
  }

  // Reporting your OWN post is refused, and this is the post-shaped half of the self-report
  // guard above. Not a privacy matter — it is that the author already has Delete on their own
  // post, so a self-report can only ever be noise in a moderator's queue.
  //
  // Checked ONLY when the post exists, and answered with the same 202 as everything else, so
  // this cannot be used to probe who wrote a post the caller cannot see.
  if (exists && target_type === 'community_post') {
    const own = await query(
      `select 1 from community_posts where id = $1 and author_id = $2 limit 1`,
      [target_id, user_id]
    );
    if (own.length > 0) return res.status(202).json({ received: true });
  }

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
