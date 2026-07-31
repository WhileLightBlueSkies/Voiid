// Reachability routes — WHO IS ALLOWED TO MESSAGE YOU (see 020_reachability.sql).
//
// Address-book discovery used to be the gate: the only way to learn someone's user id was to
// have their number. Username search removes that, so it is replaced with two explicit gates:
//
//   mutual contacts     -> chat opens directly
//   one-way contact     -> arrives as a request (Accept / Decline)
//   found by @username  -> must present the target's 6-digit PIN, THEN a request
//
// NOTHING HERE TOUCHES THE ENCRYPTION. This is server-side authorisation for creating a
// conversation row; key exchange and the ratchet are unchanged. A pending request holds
// ordinary ciphertext the server cannot read — it is simply not surfaced as a normal chat yet.
import { Router } from 'express';
import bcrypt from 'bcryptjs';
import { randomInt, timingSafeEqual } from 'crypto';
import { pool, query } from '../db';
import { requireAuth } from '../auth';
import { logSecurityEvent } from '../security';
import { open, seal, secretboxAvailable } from '../secretbox';

const router = Router();

/**
 * Constant-time string compare.
 *
 * `bcrypt.compare` was already constant-time; plain `===` is not, and swapping one for the
 * other on a secret would quietly reintroduce a timing side channel. The rate limiter makes
 * the channel hard to exploit here, but "hard to exploit" is not a reason to leave it.
 *
 * Length is compared first and separately — `timingSafeEqual` THROWS on unequal lengths
 * rather than returning false, so it cannot be the only check. Leaking whether the guess had
 * six digits is not a meaningful disclosure; the PIN's length is fixed and public.
 */
function timingSafeEqualStr(a: string, b: string): boolean {
  const ba = Buffer.from(a, 'utf8');
  const bb = Buffer.from(b, 'utf8');
  return ba.length === bb.length && timingSafeEqual(ba, bb);
}

// ─────────────────────────────────────────────────────────────────────────────────
// Brute-force policy.
//
// Six digits is 1,000,000 combinations, which an unthrottled attacker exhausts in minutes —
// these limits ARE the security of the PIN, not a refinement of it. Counted per (sender →
// target) so one abusive sender cannot lock a victim out of legitimate requests from others.
// ─────────────────────────────────────────────────────────────────────────────────
const PIN_MAX_PER_HOUR = 5;
const PIN_MAX_PER_DAY = 20;

/**
 * Whether this user has a PIN at all, under EITHER storage scheme.
 *
 * Checking only one column is the easy bug here: it would make everyone who set a PIN
 * before 026 look unreachable by username, or everyone who set one after look the same,
 * depending which column you picked.
 */
function hasPin(u: { contact_pin_hash: string | null; contact_pin_enc: string | null }): boolean {
  return !!(u.contact_pin_hash || u.contact_pin_enc);
}

function clientIp(req: any): string | null {
  return (req.headers['x-forwarded-for'] as string)?.split(',')[0]?.trim()
    || req.socket?.remoteAddress
    || null;
}

/** A fresh 6-digit PIN. `randomInt` is CSPRNG-backed — never Math.random for a credential. */
function generatePin(): string {
  return String(randomInt(0, 1_000_000)).padStart(6, '0');
}

/** True when BOTH users have saved each other (contact_sync holds resolved links only). */
async function isMutualContact(a: string, b: string): Promise<boolean> {
  const rows = await query<{ n: string }>(
    `select count(*)::text as n from contact_sync
      where (owner_user_id = $1 and contact_user_id = $2)
         or (owner_user_id = $2 and contact_user_id = $1)`,
    [a, b]
  );
  return Number(rows[0]?.n ?? 0) >= 2;
}

/** True when `owner` has saved `other` (one direction only). */
async function hasSavedContact(owner: string, other: string): Promise<boolean> {
  const rows = await query(
    `select 1 from contact_sync where owner_user_id = $1 and contact_user_id = $2 limit 1`,
    [owner, other]
  );
  return rows.length > 0;
}

// ─────────────────────────────────────────────────────────────────────────────────
// GET /reachability/by-username?username=nehal
//
// Resolve a public handle to the PUBLIC profile only. This endpoint is the boundary between
// Voiid's two identity planes, and it must never leak across it: a stranger who knows
// @nehal must not be able to reach a phone number. Returning the phone here — or any field
// that could be joined back to it — recreates the enumeration attack that has repeatedly hit
// other platforms.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/by-username', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const u = String(req.query.username ?? '').trim().toLowerCase();
  if (!u) return res.status(400).json({ error: 'username required' });

  const rows = await query<{
    id: string; full_name: string | null; photo_url: string | null;
    username: string | null; bio: string | null;
    contact_pin_hash: string | null; contact_pin_enc: string | null;
  }>(
    `select id, full_name, photo_url, username, bio, contact_pin_hash, contact_pin_enc
       from users
      where lower(username) = $1 and deleted_at is null
      limit 1`,
    [u]
  );
  const target = rows[0];
  if (!target) return res.status(404).json({ error: 'no such username' });

  // Whether a PIN is even required is public: the sender has to know whether to prompt for
  // one. WHAT the pin is, of course, is not.
  const mutual = target.id === user_id ? true : await isMutualContact(user_id, target.id);

  res.json({
    user_id: target.id,
    username: target.username,
    full_name: target.full_name,
    photo_url: target.photo_url,
    bio: target.bio,
    // The client uses these to decide which flow to run.
    is_mutual_contact: mutual,
    requires_pin: !mutual && hasPin(target),
    // A target who has never set a PIN cannot be reached by username at all — see the
    // request route. Told plainly so the UI can say so rather than failing at send time.
    reachable_by_username: mutual || hasPin(target),
  });
});

// ─────────────────────────────────────────────────────────────────────────────────
// POST /reachability/request  { username, pin? }
//
// Open a 1:1 by handle. Returns the conversation id on success; the recipient's membership is
// left 'pending' unless the two are mutual contacts.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/request', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const username = String(req.body?.username ?? '').trim().toLowerCase();
  const pin = req.body?.pin == null ? null : String(req.body.pin).trim();
  if (!username) return res.status(400).json({ error: 'username required' });

  const rows = await query<{ id: string; contact_pin_hash: string | null; contact_pin_enc: string | null }>(
    `select id, contact_pin_hash, contact_pin_enc from users
      where lower(username) = $1 and deleted_at is null limit 1`,
    [username]
  );
  const target = rows[0];
  if (!target) return res.status(404).json({ error: 'no such username' });
  if (target.id === user_id) return res.status(400).json({ error: 'cannot message yourself' });

  const mutual = await isMutualContact(user_id, target.id);

  // ── PIN gate. Skipped entirely for mutual contacts — they already proved acquaintance by
  //    both having saved each other, and demanding a PIN there would be pure friction.
  if (!mutual) {
    if (!target.contact_pin_hash && !target.contact_pin_enc) {
      // No PIN set = not reachable by handle. Deliberately NOT an invitation to try again.
      return res.status(403).json({ error: 'This person can’t be reached by username.' });
    }
    if (!pin) return res.status(400).json({ error: 'pin required' });

    // Throttle BEFORE verifying, so a wrong guess still costs an attempt.
    const counts = await query<{ hour: string; day: string }>(
      `select
         count(*) filter (where attempted_at > now() - interval '1 hour')::text as hour,
         count(*) filter (where attempted_at > now() - interval '1 day')::text  as day
       from contact_pin_attempts
      where target_user_id = $1 and sender_user_id = $2 and succeeded = false`,
      [target.id, user_id]
    );
    const perHour = Number(counts[0]?.hour ?? 0);
    const perDay = Number(counts[0]?.day ?? 0);
    if (perHour >= PIN_MAX_PER_HOUR || perDay >= PIN_MAX_PER_DAY) {
      await logSecurityEvent('api_abuse', {
        ip_address: clientIp(req) ?? undefined,
        metadata: { bucket: 'contact_pin', target: target.id, sender: user_id, perHour, perDay },
      });
      return res.status(429).json({ error: 'Too many attempts. Try again later.' });
    }

    // Encrypted first, hash as the fallback. Both paths exist because 026 does not — and
    // cannot — migrate old PINs: a bcrypt hash is one-way, so a user who set a PIN before
    // that migration keeps verifying against the hash until they next rotate.
    const stored = open(target.contact_pin_enc);
    const ok = stored !== null
      ? timingSafeEqualStr(pin, stored)
      : target.contact_pin_hash
        ? await bcrypt.compare(pin, target.contact_pin_hash)
        : false;
    await query(
      `insert into contact_pin_attempts (target_user_id, sender_user_id, sender_ip, succeeded)
       values ($1, $2, $3, $4)`,
      [target.id, user_id, clientIp(req), ok]
    );
    if (!ok) return res.status(403).json({ error: 'That PIN is not correct.' });
  }

  // ── Idempotent: reuse an existing 1:1 rather than creating a second one.
  const existing = await query<{ id: string }>(
    `select c.id from conversations c
       join conversation_members m1 on m1.conversation_id = c.id and m1.user_id = $1 and m1.left_at is null
       join conversation_members m2 on m2.conversation_id = c.id and m2.user_id = $2 and m2.left_at is null
      where c.type = 'direct'
        and (select count(*) from conversation_members m where m.conversation_id = c.id and m.left_at is null) = 2
      limit 1`,
    [user_id, target.id]
  );
  if (existing[0]) return res.json({ conversation_id: existing[0].id, existed: true, pending: false });

  // The recipient is 'pending' unless mutual. The SENDER is always 'accepted' — they have
  // implicitly accepted by initiating, which is exactly why this state is per-member.
  const recipientState = mutual ? 'accepted' : 'pending';
  const openedVia = mutual ? 'contact' : 'username';

  const client = await pool.connect();
  try {
    await client.query('begin');
    const conv = (await client.query(
      `insert into conversations (type, created_by) values ('direct', $1) returning id`,
      [user_id]
    )).rows[0];
    await client.query(
      `insert into conversation_members (conversation_id, user_id, request_state, opened_via)
       values ($1, $2, 'accepted', $4), ($1, $3, $5, $4)`,
      [conv.id, user_id, target.id, openedVia, recipientState]
    );
    await client.query('commit');
    return res.json({ conversation_id: conv.id, existed: false, pending: !mutual });
  } catch (e) {
    await client.query('rollback');
    throw e;
  } finally {
    client.release();
  }
});

// ─────────────────────────────────────────────────────────────────────────────────
// POST /reachability/:id/accept  — recipient accepts a pending request.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/:id/accept', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const updated = await query(
    `update conversation_members set request_state = 'accepted'
      where conversation_id = $1 and user_id = $2 and request_state = 'pending'
      returning id`,
    [req.params.id, user_id]
  );
  if (!updated[0]) return res.status(404).json({ error: 'no pending request here' });
  res.json({ ok: true });
});

// ─────────────────────────────────────────────────────────────────────────────────
// POST /reachability/:id/decline — recipient declines.
//
// The sender is NEVER told. If "declined" were distinguishable from "not opened yet", a
// request would become a presence oracle: send one, learn whether the account is live and
// attended. From the sender's side both states look identical — message shows Sent, forever.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/:id/decline', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const updated = await query(
    `update conversation_members set request_state = 'declined'
      where conversation_id = $1 and user_id = $2 and request_state in ('pending', 'accepted')
      returning id`,
    [req.params.id, user_id]
  );
  if (!updated[0]) return res.status(404).json({ error: 'not a member of this conversation' });
  res.json({ ok: true });
});

// ─────────────────────────────────────────────────────────────────────────────────
// GET /reachability/pending — the caller's inbound requests, for a Requests inbox.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/pending', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const rows = await query(
    `select c.id as conversation_id,
            cm.opened_via,
            cm.joined_at,
            u.id as sender_id, u.username, u.full_name, u.photo_url
       from conversation_members cm
       join conversations c on c.id = cm.conversation_id
       join conversation_members other
            on other.conversation_id = c.id and other.user_id <> $1 and other.left_at is null
       join users u on u.id = other.user_id
      where cm.user_id = $1 and cm.request_state = 'pending' and cm.left_at is null
      order by cm.joined_at desc
      limit 200`,
    [user_id]
  );
  res.json({ requests: rows });
});

// ─────────────────────────────────────────────────────────────────────────────────
// GET /reachability/contact-pin — the caller's OWN pin, in the clear.
//
// Returning the plaintext here is the point of 026. The PIN is a token you hand out, not a
// credential you prove knowledge of, so being unable to look it up made forgetting it cost a
// rotation that locked out everyone already holding it.
//
// OWNER ONLY, and structurally so: `requireAuth` supplies the user id and the query is keyed
// on it, so there is no parameter an attacker could vary to read someone else's. Nothing
// anywhere else in the API returns this column.
//
// `pin` is null — with has_pin true — for a PIN minted before 026 and therefore stored only
// as an unreversible hash. The client reads that combination as "set, but not viewable" and
// offers a rotation to gain a readable one. Same shape when the server has no secretbox key.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/contact-pin', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const rows = await query<{
    contact_pin_hash: string | null;
    contact_pin_enc: string | null;
    contact_pin_set_at: string | null;
  }>(
    `select contact_pin_hash, contact_pin_enc, contact_pin_set_at from users where id = $1`,
    [user_id]
  );
  const row = rows[0];
  res.json({
    has_pin: !!(row?.contact_pin_hash || row?.contact_pin_enc),
    pin: open(row?.contact_pin_enc),
    set_at: row?.contact_pin_set_at ?? null,
  });
});

// ─────────────────────────────────────────────────────────────────────────────────
// POST /reachability/contact-pin/rotate — mint a new PIN, replacing any existing one.
//
// Rotation exists for the case the PIN is no longer secret — posted publicly, or given to
// someone who abused it. It invalidates everyone holding the old one immediately, and the
// attempt ledger is cleared with it so a sender previously locked out by throttling gets a
// fresh start against the NEW secret.
//
// Since 026 the new PIN is also readable afterwards via GET /contact-pin, so this is no
// longer the user's only chance to see it. That makes rotation a genuine revocation tool
// rather than the only way to recover a forgotten PIN.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/contact-pin/rotate', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const pin = generatePin();

  // No key configured = no reversible storage. Fall back to hash-only rather than storing a
  // PIN in the clear: a deployment that forgot the env var gets the OLD show-once behaviour,
  // never a silent downgrade to plaintext in the database.
  const enc = secretboxAvailable() ? seal(pin) : null;
  // The hash is kept in step so a key that is later removed, rotated, or misconfigured
  // degrades to "cannot be viewed" instead of "cannot be verified" — losing the key must
  // never lock legitimate senders out of an existing PIN.
  const hash = await bcrypt.hash(pin, 10);

  const client = await pool.connect();
  try {
    await client.query('begin');
    await client.query(
      `update users
          set contact_pin_hash = $2, contact_pin_enc = $3, contact_pin_set_at = now()
        where id = $1`,
      [user_id, hash, enc]
    );
    await client.query(`delete from contact_pin_attempts where target_user_id = $1`, [user_id]);
    await client.query('commit');
  } catch (e) {
    await client.query('rollback');
    throw e;
  } finally {
    client.release();
  }

  // `viewable` tells the client whether GET /contact-pin will return this again, so the UI
  // can stop promising a permanent PIN on a deployment that cannot actually store one.
  res.json({ pin, viewable: enc !== null });
});

export default router;
