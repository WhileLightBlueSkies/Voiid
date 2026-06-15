// Contact sync routes (Section 2.3 / 4.8). Matching is LOCAL on-device; the raw contact book is NEVER uploaded.
// The client resolves phone numbers to VOIID users on-device and submits ONLY the resolved user_id links here.
import { Router } from 'express';
import { query } from '../db';
import { requireAuth } from '../auth';

const router = Router();

// POST /contacts/sync — { contacts: [{ contact_user_id, saved_name? }] }
// Body must contain resolved VOIID user_ids only — never raw phone numbers from the address book.
router.post('/sync', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const { contacts } = req.body ?? {};
  if (!Array.isArray(contacts)) return res.status(400).json({ error: 'contacts array required' });

  // Guard the privacy invariant: reject anything that smells like a raw phone book upload.
  for (const c of contacts) {
    if (!c?.contact_user_id) return res.status(400).json({ error: 'each contact needs a resolved contact_user_id' });
    if ('phone_number' in (c ?? {})) {
      return res.status(400).json({ error: 'raw phone numbers must NOT be uploaded; resolve to user_id on-device' });
    }
  }

  let upserted = 0;
  for (const c of contacts) {
    if (c.contact_user_id === user_id) continue; // skip self
    await query(
      `insert into contact_sync (owner_user_id, contact_user_id, saved_name)
         values ($1, $2, $3)
         on conflict (owner_user_id, contact_user_id)
         do update set saved_name = excluded.saved_name`,
      [user_id, c.contact_user_id, c.saved_name ?? null]
    );
    upserted++;
  }
  res.json({ synced: upserted });
});

// GET /contacts — the caller's matched VOIID contacts (saved_name overrides full_name, Section 2.3).
router.get('/', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const rows = await query(
    `select cs.contact_user_id as user_id,
            coalesce(cs.saved_name, u.full_name) as display_name,
            cs.saved_name, u.full_name, u.photo_url
       from contact_sync cs
       join users u on u.id = cs.contact_user_id and u.deleted_at is null
      where cs.owner_user_id = $1
      order by display_name nulls last`,
    [user_id]
  );
  res.json({ contacts: rows });
});

export default router;
