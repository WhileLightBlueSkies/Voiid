// Host KYC — the gate in front of paid events (087_moderator_badges_institutions_host_kyc.sql).
//
//   GET  /kyc/me                          where this host stands, and their documents
//   POST /kyc/verify                      PAN + bank → Cashfree Secure ID → Easy Split vendor
//   POST /kyc/documents                   presign an upload into the private `kyc/` prefix
//   POST /kyc/documents/:id/confirm       the upload landed; show it to reviewers
//   DELETE /kyc/documents/:id             withdraw a document before review
//
// ── WHAT HAPPENS TO THE NUMBERS ──────────────────────────────────────────────────
//
// The PAN and the account number arrive in ONE request, go to Secure ID and to Easy Split in
// that same request, and are dropped. Only their last four characters are written anywhere.
// They are never logged: cashfree.ts logs HTTP status and Cashfree's error code only.
//
// ── WHO DECIDES ─────────────────────────────────────────────────────────────────
//
// Secure ID's answer is evidence, not the verdict. A passing check moves the host to
// `pending_review`; a Voiid admin approves or rejects from the admin panel (routes/admin.ts),
// with the documents in front of them. Only `verified` can price an event.
import { Router } from 'express';
import { randomUUID } from 'crypto';
import { query } from '../db';
import { requireAuth } from '../auth';
import { asyncHandler } from '../util';
import { rateLimit } from '../security';
import { presignPut, objectExists, r2Configured } from '../r2';
import {
  AUTO_ACCEPT_NAME_MATCH, CashfreeError, cashfreeFromEnv, cashfreeVerificationFromEnv,
} from '../payments/cashfree';

const router = Router();

const PAN_RE = /^[A-Z]{5}[0-9]{4}[A-Z]$/;
const IFSC_RE = /^[A-Z]{4}0[A-Z0-9]{6}$/;
const ACCOUNT_RE = /^[0-9A-Za-z]{6,40}$/;
const EMAIL_RE = /^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const DOC_KINDS = ['pan_card', 'bank_proof', 'address_proof', 'institution_letter', 'other'];
const DOC_MIMES: Record<string, string> = {
  'image/jpeg': 'jpg', 'image/png': 'png', 'application/pdf': 'pdf',
};

export type HostVerificationRow = {
  status: string;
  legal_name: string | null;
  email: string | null;
  pan_last4: string | null;
  pan_registered_name: string | null;
  pan_valid: boolean | null;
  pan_name_match: boolean | null;
  bank_last4: string | null;
  ifsc: string | null;
  bank_name: string | null;
  name_at_bank: string | null;
  bank_name_match: string | null;
  cashfree_vendor_id: string | null;
  vendor_status: string | null;
  submitted_at: string | null;
  reviewed_at: string | null;
  rejection_reason: string | null;
};

/** The shape both apps read. Every key always present — Swift's Codable rule. */
function shape(row: HostVerificationRow | undefined, docs: any[], configured: boolean) {
  return {
    // `not_started` is not a stored state: it is the absence of a row.
    status: row?.status ?? 'not_started',
    legal_name: row?.legal_name ?? null,
    email: row?.email ?? null,
    pan_last4: row?.pan_last4 ?? null,
    pan_registered_name: row?.pan_registered_name ?? null,
    bank_last4: row?.bank_last4 ?? null,
    ifsc: row?.ifsc ?? null,
    bank_name: row?.bank_name ?? null,
    submitted_at: row?.submitted_at ?? null,
    reviewed_at: row?.reviewed_at ?? null,
    rejection_reason: row?.rejection_reason ?? null,
    documents: docs,
    // False when Secure ID is not configured on this server. The app then says so instead of
    // offering a form whose submit can only fail.
    available: configured,
  };
}

async function load(userId: string) {
  const row = (await query<HostVerificationRow>(
    `select * from host_verifications where user_id = $1`, [userId]))[0];
  const docs = await query<any>(
    `select id, kind, mime, uploaded_at from kyc_documents
      where user_id = $1 and confirmed_at is not null and deleted_at is null
      order by uploaded_at`, [userId]);
  return { row, docs };
}

/** Whether this user may price an event — used by routes/events.ts. */
export async function hostIsVerified(userId: string): Promise<boolean> {
  const rows = await query<{ ok: boolean }>(
    `select true as ok from host_verifications where user_id = $1 and status = 'verified'`, [userId]);
  return rows.length > 0;
}

/** The payout account an order's host share settles to, when there is one. */
export async function hostVendorId(userId: string): Promise<string | null> {
  const rows = await query<{ cashfree_vendor_id: string | null }>(
    `select cashfree_vendor_id from host_verifications where user_id = $1 and status = 'verified'`, [userId]);
  return rows[0]?.cashfree_vendor_id ?? null;
}

router.get('/kyc/me', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const { row, docs } = await load(user_id);
  res.json({ verification: shape(row, docs, cashfreeVerificationFromEnv() !== null) });
}));

router.post(
  '/kyc/verify',
  requireAuth,
  // Each call costs a Secure ID check and a penny drop. Tight on purpose: a person verifies
  // once or twice, and a loop here is somebody probing other people's PANs.
  rateLimit({ max: 5, windowSeconds: 3600, bucket: 'kyc-verify' }),
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const verification = cashfreeVerificationFromEnv();
    const gateway = cashfreeFromEnv();
    if (!verification || !gateway) {
      return res.status(503).json({ error: 'identity verification is not available yet', code: 'kyc_unavailable' });
    }

    const b = req.body ?? {};
    const legalName = typeof b.legal_name === 'string' ? b.legal_name.trim().replace(/\s+/g, ' ') : '';
    const email = typeof b.email === 'string' ? b.email.trim().toLowerCase() : '';
    const pan = typeof b.pan === 'string' ? b.pan.trim().toUpperCase() : '';
    const account = typeof b.bank_account === 'string' ? b.bank_account.replace(/\s/g, '') : '';
    const ifsc = typeof b.ifsc === 'string' ? b.ifsc.trim().toUpperCase() : '';

    if (legalName.length < 2 || legalName.length > 100) {
      return res.status(400).json({ error: 'Enter your full name as it appears on your PAN.' });
    }
    if (!EMAIL_RE.test(email)) return res.status(400).json({ error: 'Enter a valid email address.' });
    if (!PAN_RE.test(pan)) return res.status(400).json({ error: 'That doesn’t look like a PAN (e.g. ABCDE1234F).' });
    if (!ACCOUNT_RE.test(account)) return res.status(400).json({ error: 'Enter a valid bank account number.' });
    if (!IFSC_RE.test(ifsc)) return res.status(400).json({ error: 'That doesn’t look like an IFSC (e.g. HDFC0001234).' });

    const existing = (await query<HostVerificationRow>(
      `select * from host_verifications where user_id = $1`, [user_id]))[0];
    if (existing?.status === 'verified') {
      return res.status(409).json({ error: 'You’re already verified.' });
    }

    try {
      const panResult = await verification.verifyPan(`pan_${user_id.replace(/-/g, '')}_${Date.now()}`, pan, legalName);
      if (!panResult.valid) {
        return res.status(422).json({ error: 'That PAN couldn’t be verified. Check it and try again.', code: 'pan_invalid' });
      }
      const bank = await verification.verifyBankAccount(account, ifsc, legalName);
      if (!bank.valid) {
        return res.status(422).json({ error: 'That bank account couldn’t be verified. Check the number and IFSC.', code: 'bank_invalid' });
      }

      const phone = (await query<{ phone_number: string | null }>(
        `select phone_number from users where id = $1`, [user_id]))[0]?.phone_number ?? '';
      const vendorArgs = {
        vendorId: existing?.cashfree_vendor_id ?? `vh_${user_id.replace(/-/g, '')}`,
        name: legalName, email, phone,
        accountNumber: account, accountHolder: bank.nameAtBank || legalName, ifsc, pan,
      };
      const vendor = existing?.cashfree_vendor_id
        ? await gateway.updateVendor(vendorArgs)
        : await gateway.createVendor(vendorArgs);

      await query(
        `insert into host_verifications
           (user_id, status, legal_name, email,
            pan_last4, pan_registered_name, pan_valid, pan_name_match, pan_reference,
            bank_last4, ifsc, bank_name, name_at_bank, bank_name_match, bank_reference,
            cashfree_vendor_id, vendor_status, submitted_at, reviewed_at, reviewed_by,
            rejection_reason, updated_at)
         values ($1, 'pending_review', $2, $3, $4, $5, true, $6, $7, $8, $9, $10, $11, $12, $13,
                 $14, $15, now(), null, null, null, now())
         on conflict (user_id) do update set
            status = 'pending_review', legal_name = excluded.legal_name, email = excluded.email,
            pan_last4 = excluded.pan_last4, pan_registered_name = excluded.pan_registered_name,
            pan_valid = true, pan_name_match = excluded.pan_name_match,
            pan_reference = excluded.pan_reference, bank_last4 = excluded.bank_last4,
            ifsc = excluded.ifsc, bank_name = excluded.bank_name,
            name_at_bank = excluded.name_at_bank, bank_name_match = excluded.bank_name_match,
            bank_reference = excluded.bank_reference,
            cashfree_vendor_id = excluded.cashfree_vendor_id,
            vendor_status = excluded.vendor_status, submitted_at = now(), reviewed_at = null,
            reviewed_by = null, rejection_reason = null, updated_at = now()`,
        [user_id, legalName, email, pan.slice(-4), panResult.registeredName ?? null,
         panResult.nameMatch ?? null, panResult.referenceId ?? null,
         account.slice(-4), ifsc, bank.bankName ?? null, bank.nameAtBank ?? null,
         bank.nameMatchResult ?? null, bank.referenceId ?? null,
         vendor.vendorId, vendor.status]
      );
    } catch (e) {
      if (e instanceof CashfreeError) {
        return res.status(502).json({ error: 'Verification is having trouble right now. Try again in a few minutes.', code: 'kyc_provider_error' });
      }
      throw e;
    }

    const { row, docs } = await load(user_id);
    res.json({
      verification: shape(row, docs, true),
      // A hint for the app's copy, not a decision: a strong name match usually clears review
      // quickly, a weak one usually needs a document.
      strong_match: row?.pan_name_match === true && AUTO_ACCEPT_NAME_MATCH.has(row?.bank_name_match ?? ''),
    });
  })
);

router.post(
  '/kyc/documents',
  requireAuth,
  rateLimit({ max: 20, windowSeconds: 3600, bucket: 'kyc-docs' }),
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    if (!r2Configured()) return res.status(503).json({ error: 'uploads are not available right now' });
    const kind = String(req.body?.kind ?? '');
    const mime = String(req.body?.mime ?? '');
    if (!DOC_KINDS.includes(kind)) return res.status(400).json({ error: 'unknown document kind' });
    if (!DOC_MIMES[mime]) return res.status(400).json({ error: 'upload a JPEG, PNG or PDF' });

    const live = (await query<{ n: number }>(
      `select count(*)::int as n from kyc_documents where user_id = $1 and deleted_at is null`, [user_id]))[0].n;
    if (live >= 10) return res.status(409).json({ error: 'Remove a document before adding another.' });

    const id = randomUUID();
    const key = `kyc/${user_id}/${id}.${DOC_MIMES[mime]}`;
    await query(
      `insert into kyc_documents (id, user_id, kind, r2_key, mime) values ($1, $2, $3, $4, $5)`,
      [id, user_id, kind, key, mime]);
    const upload_url = await presignPut(key, mime);
    res.status(201).json({ document: { id, kind, mime }, upload_url });
  })
);

router.post('/kyc/documents/:id/confirm', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const id = String(req.params.id);
  if (!UUID_RE.test(id)) return res.status(400).json({ error: 'id must be a uuid' });
  const doc = (await query<{ r2_key: string }>(
    `select r2_key from kyc_documents where id = $1 and user_id = $2 and deleted_at is null`, [id, user_id]))[0];
  if (!doc) return res.status(404).json({ error: 'document not found' });
  if (!(await objectExists(doc.r2_key))) return res.status(409).json({ error: 'the upload did not arrive' });
  await query(`update kyc_documents set confirmed_at = coalesce(confirmed_at, now()) where id = $1`, [id]);
  res.json({ ok: true });
}));

router.delete('/kyc/documents/:id', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const id = String(req.params.id);
  if (!UUID_RE.test(id)) return res.status(400).json({ error: 'id must be a uuid' });
  // Soft delete: a document a reviewer already saw stays on record until retention removes it.
  const rows = await query(
    `update kyc_documents set deleted_at = now()
      where id = $1 and user_id = $2 and deleted_at is null returning id`, [id, user_id]);
  if (!rows[0]) return res.status(404).json({ error: 'document not found' });
  res.json({ ok: true });
}));

export default router;
