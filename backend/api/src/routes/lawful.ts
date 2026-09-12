//
// GOVERNMENT / LAWFUL REQUESTS — the console for answering a compelled disclosure.
//
// WHY THERE IS NO LOOKUP ENDPOINT
// ===============================
// The obvious API for "give the government what they ask for" is
// GET /lawful/subject?phone=… returning everything we hold. That endpoint does not exist
// here and must not be added. It is a mass-surveillance interface with a legal
// justification bolted on afterwards: an insider looking up an ex, a stolen admin session,
// or a staff member facing someone with a badge and no warrant all reach the same data
// with no record of why.
//
// Instead: the ORDER comes first. POST /lawful/requests records the authority, the statute,
// the reference and the served document. Only then can a preview or a disclosure name that
// request — and every one of them writes a row to lawful_access_log. There is no path to
// subject data that is not attributable to a specific order and a specific person.
//
// WHAT THIS CANNOT PRODUCE
// Message content. Voiid's servers hold ciphertext whose keys never leave user devices
// (packages/e2e-core). The 'ciphertext' category returns what we have — undecryptable
// bytes — and says so. There is no decrypt path to expose, which is why none is gated.
//

import { Router } from 'express';
import type { Request, Response, NextFunction } from 'express';
import { asyncHandler } from '../util';
import { query } from '../db';
import { presignPut, presignGet, r2Configured } from '../r2';

const router = Router();

/** Populated by the admin router's requireAdmin, which runs before this is mounted. */
interface AdminAuth { adminId: string; email: string; name: string | null; role: 'moderator' | 'admin' }

/**
 * EVERY route here is admin-only. Not moderator.
 *
 * Moderation is about public content; this is about a named private individual and a
 * government demand. The two jobs have different blast radii and should not share a role —
 * a moderator hired to review clip reports has no business near a disclosure file.
 */
function requireLawfulRole(req: Request, res: Response, next: NextFunction) {
  const a = (req as any).admin as AdminAuth | undefined;
  if (!a) return res.status(401).json({ error: 'admin auth required' });
  if (a.role !== 'admin') {
    void query(
      `insert into admin_audit_log (admin_id, action, target_type, target_id, detail)
       values ($1, 'lawful.forbidden', 'route', $2, $3)`,
      [a.adminId, `${req.method} ${req.path}`, JSON.stringify({ role: a.role })]
    ).catch(() => {});
    return res.status(403).json({ error: 'lawful requests require the admin role' });
  }
  next();
}
router.use(requireLawfulRole);

const admin = (req: Request) => (req as any).admin as AdminAuth;

/**
 * Same masking rule as the rest of the admin plane, and it applies HERE TOO.
 *
 * The operator handling a request already holds the number — the authority served it. What
 * the console must not become is a place to read numbers you did not arrive with.
 */
function maskPhone(phone: string | null): string | null {
  if (!phone) return null;
  if (phone.length <= 5) return '•'.repeat(phone.length);
  return `${phone.slice(0, 3)}${'•'.repeat(phone.length - 5)}${phone.slice(-2)}`;
}

async function auditLawful(adminId: string, action: string, requestId: string, detail?: unknown) {
  try {
    await query(
      `insert into admin_audit_log (admin_id, action, target_type, target_id, detail)
       values ($1, $2, 'lawful_request', $3, $4)`,
      [adminId, action, requestId, detail == null ? null : JSON.stringify(detail)]
    );
  } catch { /* an audit failure must not block the legal workflow */ }
}

// ── The categories this system can produce ─────────────────────────────────────────────
//
// A CLOSED LIST, mirrored by the CHECK on lawful_disclosures.category. Closed because it
// doubles as the statement of what Voiid is capable of disclosing: adding a category is a
// deliberate act with a schema change attached, not something a route can quietly start
// returning. Each entry says what a subject would be told was handed over.
const CATEGORIES = {
  subscriber_info: 'Phone number, account creation date, display name, username.',
  device_list: 'Devices on the account: platform, registration date, last seen.',
  contact_graph: 'Which accounts this user has in contacts, and which have them.',
  conversation_members: 'Which conversations this user belongs to. NOT message content.',
  community_members: 'Communities and spaces this user belongs to.',
  call_records: 'Call metadata: who, when, duration. No audio, no video.',
  location_shares: 'Who this user shared location with and when. Coordinates stay E2EE.',
  blocked_list: 'Accounts this user has blocked.',
  push_tokens: 'APNs/FCM tokens registered to this account.',
  security_events: 'Authentication events and the IP addresses recorded with them.',
  ciphertext: 'Stored message ciphertext. UNDECRYPTABLE — keys never leave user devices.',
  account_status: 'Whether the account is active or erased, with creation and update times.',
} as const;
type Category = keyof typeof CATEGORIES;

/**
 * The one place a category becomes SQL.
 *
 * Every query is scoped to a single subject user id — there is no shape here that can
 * return rows about anyone else, which is what keeps a disclosure inside the order that
 * authorised it.
 */
const QUERIES: Record<Category, { sql: string }> = {
  subscriber_info: { sql:
    `select id, phone_number, full_name, username, created_at from users where id = $1` },
  device_list: { sql:
    `select id, platform, device_name, created_at, last_seen_at, revoked_at
       from devices where user_id = $1 order by created_at` },
  contact_graph: { sql:
    `select owner_user_id, contact_user_id, created_at from contact_sync
      where owner_user_id = $1 or contact_user_id = $1` },
  conversation_members: { sql:
    `select conversation_id, joined_at from conversation_members where user_id = $1` },
  community_members: { sql:
    `select community_id, role, joined_at from community_members where user_id = $1` },
  call_records: { sql:
    `select distinct c.id, c.started_at, c.answered_at, c.ended_at,
            c.call_kind, c.status, c.end_reason
       from calls c left join call_participants p on p.call_id = c.id
      where c.caller_user_id = $1 or p.user_id = $1
      order by c.started_at desc limit 1000` },
  location_shares: { sql:
    `select s.id, s.kind, s.started_at, s.expires_at, s.ended_at, t.target_user_id
       from location_shares s left join location_share_targets t on t.share_id = s.id
      where s.owner_user_id = $1
      order by s.started_at desc limit 1000` },
  blocked_list: { sql:
    `select blocked_user_id, created_at from user_blocks where blocker_user_id = $1` },
  push_tokens: { sql:
    `select id, platform, push_provider, (push_token is not null) as has_token
       from devices where user_id = $1` },
  security_events: { sql:
    `select event_type, ip_address, created_at from security_events
      where user_id = $1 order by created_at desc limit 500` },
  ciphertext: { sql:
    `select count(*)::int as ciphertext_rows from message_ciphertexts mc
       join devices d on d.id = mc.recipient_device_id where d.user_id = $1` },
  // No suspended_at on users — suspension is not a column on this table, so the honest
  // answer is creation, update and erasure timestamps and nothing invented beside them.
  account_status: { sql:
    `select id, created_at, updated_at, deleted_at,
            (deleted_at is not null) as erased
       from users where id = $1` },
};

// ═══════════════════════════════════════════════════════════════════════════════════════
// GET /lawful/categories — what this system can produce, and in what words.
// ═══════════════════════════════════════════════════════════════════════════════════════
router.get('/categories', asyncHandler(async (_req, res) => {
  res.json({
    categories: Object.entries(CATEGORIES).map(([id, description]) => ({ id, description })),
    // Stated in the API, not only in the UI, so an integrator cannot miss it.
    cannot_produce: [
      'Message, call or location CONTENT. End-to-end encrypted; keys never leave user devices.',
      'Full phone numbers of anyone other than the named subject.',
      'Any data about a person the served order does not name.',
    ],
  });
}));

// ═══════════════════════════════════════════════════════════════════════════════════════
// GET /lawful/requests — the case list.
// ═══════════════════════════════════════════════════════════════════════════════════════
router.get('/requests', asyncHandler(async (req, res) => {
  const status = typeof req.query.status === 'string' ? req.query.status : null;
  const rows = await query<any>(
    `select r.id, r.authority, r.legal_basis, r.reference, r.scope_requested,
            r.received_channel, r.received_at, r.status, r.emergency,
            r.subject_phone, r.subject_user_id, r.subject_notified,
            r.order_document_key, r.order_document_kind,
            r.decision_note, r.approved_at, r.closed_at,
            o.email as opened_by_email, ap.email as approved_by_email,
            (select count(*)::int from lawful_disclosures d where d.request_id = r.id) as disclosure_count
       from lawful_requests r
       left join admin_users o  on o.id  = r.opened_by
       left join admin_users ap on ap.id = r.approved_by
      ${status ? 'where r.status = $1' : ''}
      order by r.received_at desc limit 200`,
    status ? [status] : []
  );
  res.json({
    requests: rows.map(r => ({ ...r, subject_phone: maskPhone(r.subject_phone) })),
  });
}));

// ═══════════════════════════════════════════════════════════════════════════════════════
// POST /lawful/requests — log an order. THE FIRST STEP; nothing else works without it.
// ═══════════════════════════════════════════════════════════════════════════════════════
router.post('/requests', asyncHandler(async (req, res) => {
  const a = admin(req);
  const b = req.body ?? {};
  const required = ['authority', 'legal_basis', 'reference', 'scope_requested', 'received_channel', 'subject_phone'];
  const missing = required.filter(k => !String(b[k] ?? '').trim());
  if (missing.length) return res.status(400).json({ error: `missing: ${missing.join(', ')}` });

  // Resolve the subject WITHOUT disclosing anything. Whether an account exists is itself
  // information about a person, so it is recorded on the case file rather than returned
  // as a bare answer to an unrecorded question.
  const phone = String(b.subject_phone).trim();
  const found = await query<{ id: string }>(
    `select id from users where phone_number = $1 limit 1`, [phone]);

  const rows = await query<{ id: string }>(
    `insert into lawful_requests
       (authority, legal_basis, reference, scope_requested, received_channel,
        subject_phone, subject_user_id, emergency, opened_by, order_document_key,
        order_document_sha256, order_document_kind)
     values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) returning id`,
    [String(b.authority).trim(), String(b.legal_basis).trim(), String(b.reference).trim(),
     String(b.scope_requested).trim(), String(b.received_channel),
     phone, found[0]?.id ?? null, b.emergency === true, a.adminId,
     b.order_document_key ?? null, b.order_document_sha256 ?? null, b.order_document_kind ?? null]
  );
  await auditLawful(a.adminId, 'lawful.request.opened', rows[0].id,
    { authority: b.authority, legal_basis: b.legal_basis, reference: b.reference,
      subject_resolved: !!found[0] });
  res.status(201).json({ id: rows[0].id, subject_resolved: !!found[0] });
}));

// ═══════════════════════════════════════════════════════════════════════════════════════
// POST /lawful/requests/:id/document — presigned PUT for the FIR / warrant / notice.
//
// The order must be ATTACHED before anything can be disclosed (enforced by
// lawful_document_required in migration 073). This is how it gets there.
// ═══════════════════════════════════════════════════════════════════════════════════════
router.post('/requests/:id/document', asyncHandler(async (req, res) => {
  const a = admin(req);
  if (!r2Configured()) return res.status(503).json({ error: 'document storage is not configured' });
  const kind = String(req.body?.kind ?? 'other');
  const contentType = String(req.body?.content_type ?? 'application/pdf');
  // Evidence lives under its own prefix so it can carry a different lifecycle policy from
  // user media — it must NOT be swept by anything that cleans up attachments.
  const key = `lawful/${req.params.id}/order-${Date.now()}`;
  const url = await presignPut(key, contentType);
  await auditLawful(a.adminId, 'lawful.document.presigned', req.params.id, { key, kind });
  res.json({ upload_url: url, key });
}));

/**
 * Confirm the upload landed and record its digest.
 *
 * The digest is taken from the bytes the CLIENT uploaded and stored beside the key, so the
 * document we were served can later be proven to be the document we still hold — an
 * authority producing a different order, or a staff member swapping the file, both become
 * visible instead of silent.
 */
router.post('/requests/:id/document/confirm', asyncHandler(async (req, res) => {
  const a = admin(req);
  const key = String(req.body?.key ?? '').trim();
  const sha = String(req.body?.sha256 ?? '').trim().toLowerCase();
  const kind = String(req.body?.kind ?? 'other');
  if (!key || !/^[0-9a-f]{64}$/.test(sha)) {
    return res.status(400).json({ error: 'key and a 64-hex sha256 are required' });
  }
  await query(
    `update lawful_requests
        set order_document_key = $1, order_document_sha256 = $2,
            order_document_kind = $3, updated_at = now()
      where id = $4`,
    [key, sha, kind, req.params.id]
  );
  await auditLawful(a.adminId, 'lawful.document.attached', req.params.id, { key, sha256: sha, kind });
  res.json({ ok: true });
}));

/** Read the served order back. Logged: viewing the evidence is itself an access. */
router.get('/requests/:id/document', asyncHandler(async (req, res) => {
  const a = admin(req);
  const rows = await query<{ order_document_key: string | null }>(
    `select order_document_key from lawful_requests where id = $1`, [req.params.id]);
  const key = rows[0]?.order_document_key;
  if (!key) return res.status(404).json({ error: 'no document attached' });
  await auditLawful(a.adminId, 'lawful.document.viewed', req.params.id, { key });
  res.json({ url: await presignGet(key) });
}));

// ═══════════════════════════════════════════════════════════════════════════════════════
// POST /lawful/requests/:id/approve — the SECOND pair of eyes.
//
// The database refuses approved_by = opened_by (lawful_two_person). This route surfaces
// that as a readable error rather than a constraint violation, and refuses approval before
// the order is attached.
// ═══════════════════════════════════════════════════════════════════════════════════════
router.post('/requests/:id/approve', asyncHandler(async (req, res) => {
  const a = admin(req);
  const rows = await query<{ opened_by: string | null; order_document_key: string | null }>(
    `select opened_by, order_document_key from lawful_requests where id = $1`, [req.params.id]);
  const r = rows[0];
  if (!r) return res.status(404).json({ error: 'no such request' });
  if (r.opened_by === a.adminId) {
    return res.status(403).json({
      error: 'a request must be approved by someone other than the person who opened it',
    });
  }
  if (!r.order_document_key) {
    return res.status(400).json({ error: 'attach the served order before approving' });
  }
  await query(
    `update lawful_requests set approved_by = $1, approved_at = now(),
            status = 'under_review', updated_at = now() where id = $2`,
    [a.adminId, req.params.id]
  );
  await auditLawful(a.adminId, 'lawful.request.approved', req.params.id);
  res.json({ ok: true });
}));

// ═══════════════════════════════════════════════════════════════════════════════════════
// POST /lawful/requests/:id/preview — look at what we hold, for ONE category.
//
// Logged to lawful_access_log whether or not anything is ultimately disclosed. Assessing an
// order means looking before deciding, and that look is exactly the access an insider would
// want unattributable — so it is recorded with the same weight as a disclosure.
// ═══════════════════════════════════════════════════════════════════════════════════════
router.post('/requests/:id/preview', asyncHandler(async (req, res) => {
  const a = admin(req);
  const category = String(req.body?.category ?? '') as Category;
  if (!(category in QUERIES)) return res.status(400).json({ error: 'unknown category' });

  const rows = await query<{ subject_user_id: string | null; status: string; approved_by: string | null }>(
    `select subject_user_id, status, approved_by from lawful_requests where id = $1`, [req.params.id]);
  const r = rows[0];
  if (!r) return res.status(404).json({ error: 'no such request' });
  if (!r.approved_by) return res.status(403).json({ error: 'this request has not been approved' });
  if (r.status === 'refused' || r.status === 'withdrawn') {
    return res.status(403).json({ error: `this request is ${r.status}` });
  }
  if (!r.subject_user_id) {
    await query(
      `insert into lawful_access_log (request_id, admin_id, category, record_count)
       values ($1,$2,$3,0)`, [req.params.id, a.adminId, category]);
    return res.json({ category, rows: [], count: 0, note: 'no account matches the subject' });
  }

  const data = await query<any>(QUERIES[category].sql, [r.subject_user_id]);
  await query(
    `insert into lawful_access_log (request_id, admin_id, category, record_count)
     values ($1,$2,$3,$4)`, [req.params.id, a.adminId, category, data.length]);
  await auditLawful(a.adminId, 'lawful.preview', req.params.id, { category, count: data.length });

  res.json({
    category,
    description: CATEGORIES[category],
    count: data.length,
    rows: data.map(row => 'phone_number' in row
      ? { ...row, phone_number: maskPhone(row.phone_number) } : row),
  });
}));

// ═══════════════════════════════════════════════════════════════════════════════════════
// POST /lawful/requests/:id/disclose — record that a category was handed over.
//
// This does NOT transmit anything. Producing the artefact and delivering it to the
// authority happens outside this system; what belongs here is the RECORD that it happened,
// at category granularity, so "what did you give them" has an answer.
// ═══════════════════════════════════════════════════════════════════════════════════════
router.post('/requests/:id/disclose', asyncHandler(async (req, res) => {
  const a = admin(req);
  const category = String(req.body?.category ?? '') as Category;
  if (!(category in CATEGORIES)) return res.status(400).json({ error: 'unknown category' });

  const rows = await query<{ approved_by: string | null; order_document_key: string | null }>(
    `select approved_by, order_document_key from lawful_requests where id = $1`, [req.params.id]);
  const r = rows[0];
  if (!r) return res.status(404).json({ error: 'no such request' });
  if (!r.approved_by) return res.status(403).json({ error: 'this request has not been approved' });
  if (!r.order_document_key) return res.status(400).json({ error: 'no served order is attached' });

  await query(
    `insert into lawful_disclosures
       (request_id, category, record_count, artifact_key, artifact_sha256, disclosed_by)
     values ($1,$2,$3,$4,$5,$6)
     on conflict (request_id, category) do update
       set record_count = excluded.record_count, artifact_key = excluded.artifact_key,
           artifact_sha256 = excluded.artifact_sha256, disclosed_at = now()`,
    [req.params.id, category, Number(req.body?.record_count ?? 0),
     req.body?.artifact_key ?? null, req.body?.artifact_sha256 ?? null, a.adminId]
  );
  await auditLawful(a.adminId, 'lawful.disclosed', req.params.id,
    { category, record_count: req.body?.record_count ?? 0 });
  res.json({ ok: true });
}));

// ═══════════════════════════════════════════════════════════════════════════════════════
// POST /lawful/requests/:id/close — the outcome, with a reason.
// ═══════════════════════════════════════════════════════════════════════════════════════
router.post('/requests/:id/close', asyncHandler(async (req, res) => {
  const a = admin(req);
  const status = String(req.body?.status ?? '');
  const note = String(req.body?.decision_note ?? '').trim();
  const notified = String(req.body?.subject_notified ?? 'pending');
  if (!['refused', 'narrowed', 'complied', 'no_data', 'withdrawn'].includes(status)) {
    return res.status(400).json({ error: 'invalid closing status' });
  }
  // A decision with no stated reason is indefensible later, whichever way it went.
  if (!note) return res.status(400).json({ error: 'a decision note is required' });

  try {
    await query(
      `update lawful_requests
          set status = $1, decision_note = $2, subject_notified = $3,
              closed_at = now(), updated_at = now()
        where id = $4`,
      [status, note, notified, req.params.id]
    );
  } catch (e) {
    // The document constraint is the likely failure: closing as complied/no_data without
    // the served order attached. Say so plainly rather than leaking a constraint name.
    if (String((e as Error).message).includes('lawful_document_required')) {
      return res.status(400).json({
        error: 'the served order must be attached before closing as complied, narrowed or no_data',
      });
    }
    throw e;
  }
  await auditLawful(a.adminId, 'lawful.request.closed', req.params.id, { status, subject_notified: notified });
  res.json({ ok: true });
}));

// ═══════════════════════════════════════════════════════════════════════════════════════
// GET /lawful/requests/:id — the full case file, access history included.
// ═══════════════════════════════════════════════════════════════════════════════════════
router.get('/requests/:id', asyncHandler(async (req, res) => {
  const rows = await query<any>(
    `select r.*, o.email as opened_by_email, ap.email as approved_by_email
       from lawful_requests r
       left join admin_users o  on o.id  = r.opened_by
       left join admin_users ap on ap.id = r.approved_by
      where r.id = $1`, [req.params.id]);
  const r = rows[0];
  if (!r) return res.status(404).json({ error: 'no such request' });

  const disclosures = await query<any>(
    `select d.*, u.email as disclosed_by_email from lawful_disclosures d
       left join admin_users u on u.id = d.disclosed_by
      where d.request_id = $1 order by d.disclosed_at`, [req.params.id]);
  const access = await query<any>(
    `select l.category, l.record_count, l.created_at, u.email as admin_email
       from lawful_access_log l left join admin_users u on u.id = l.admin_id
      where l.request_id = $1 order by l.created_at desc limit 200`, [req.params.id]);

  res.json({
    request: { ...r, subject_phone: maskPhone(r.subject_phone) },
    disclosures,
    access_log: access,
  });
}));

export default router;
