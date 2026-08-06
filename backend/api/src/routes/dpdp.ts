// Data-principal rights — the endpoints a user reaches to exercise DPDP ss.11-13, and the
// metadata-only export that answers an access request (repair plan 3.27).
//
// ── WHY THIS IS A NEW ROUTER AND NOT LINES IN users.ts ───────────────────────────
//
// The repair plan names `POST /users/dpdp-request` and `GET /users/me/export`. This is the
// same functionality on its own router, for the reason routes/consent.ts already gives for
// the same move: users.ts is the profile CRUD surface, and the rights machinery is a
// different concern with a different lifetime — it has an admin counterpart (admin.ts),
// its own ledger (034_dpdp_requests.sql), and an export whose whole design is a list of
// things it must never touch. Bolting that onto the profile router would put the export's
// content-exclusion rules in a file where nobody editing a display-name validator would
// think to look for them.
//
// ── METADATA ONLY, AND STRUCTURALLY SO ───────────────────────────────────────────
//
// The export cannot contain a message, a call, a location share or a moment. That is not a
// promise made in a comment: the document is assembled from a hand-written allow-list of
// sections (EXPORT_SECTIONS below), and assertExportIsMetadataOnly() re-reads every one of
// those SQL strings at module load and THROWS if any of them names a table that holds
// end-to-end-encrypted material or key material, or uses `select *`. A future edit that
// adds `message_ciphertexts` to the export does not ship a leak — it fails to boot.
//
// Both halves of that matter. The table check is the obvious one. `select *` is the
// non-obvious one: an allow-list of tables plus a wildcard is not an allow-list at all,
// because a column added to `users` next year would silently join the export without
// anyone deciding that it should.
//
// The absence is also stated IN the document, as its first field, rather than left to be
// noticed. An access response that quietly omits the thing the principal most expects to
// see reads as an incomplete answer; the honest framing is that there is nothing to
// return, because the server holds ciphertext and no key, and that is a property of the
// product rather than a refusal.
//
// ── NOT MOUNTED YET ──────────────────────────────────────────────────────────────
//
// backend/api/src/index.ts is owned by another workstream, so this router is not reachable
// until one line is added there (see the mount snippet at the bottom of this file). Until
// then these handlers are dead code, deliberately — shipping the router separately from
// its mount is safer than two workstreams editing the same file.
//
// ── THIS IMPLEMENTS A CONTROL; IT CERTIFIES NOTHING ──────────────────────────────
//
// [COUNSEL] Every response period in SLA_DAYS is an engineering placeholder. The DPDP
// Rules 2025 commencement and the prescribed periods are open question
// docs/research/11_admin_dpdp.md §6.1; the IT Rules 2021 grievance-officer formalities and
// timelines are §6.4. Nothing here asserts that any of these numbers is the required one,
// and nothing here asserts that Voiid complies with anything.
import { Router } from 'express';
import { query } from '../db';
import { requireAuth } from '../auth';
import { asyncHandler } from '../util';

const router = Router();

// ─────────────────────────────────────────────────────────────────────────────────
// The four rights, and how long we give ourselves to answer each.
//
// NAMED CONSTANTS IN CODE, not a column default and not a config row — the same rule
// 030_dpdp.sql applies to retention periods and backend/workers/src/index.ts applies to
// the sweep. A response deadline is exactly the number somebody wants to quietly extend
// when the queue is full, and it should take a diff to do it.
//
// The deadline is written onto the row at creation (034_dpdp_requests.sql `due_at`) rather
// than derived at read time, so changing a constant here never moves the deadline of a
// request that was already open under the old one.
// ─────────────────────────────────────────────────────────────────────────────────

const REQUEST_KINDS = ['access', 'correction', 'erasure', 'grievance'] as const;
type RequestKind = (typeof REQUEST_KINDS)[number];

/** [COUNSEL] placeholders — see the header. Not legal advice, not a compliance claim. */
const SLA_DAYS: Record<RequestKind, number> = {
  access: 30,
  correction: 30,
  erasure: 30,
  // Shorter than the rest on purpose: a grievance is a complaint about how we handled
  // something, and the one thing a complaints channel must not do is take as long as the
  // process being complained about.
  grievance: 15,
};

/** Free text from a stranger is unbounded by default; 4 KB is a paragraph, not a payload. */
const MAX_NOTE_CHARS = 4000;

// ═════════════════════════════════════════════════════════════════════════════════
// THE EXPORT
// ═════════════════════════════════════════════════════════════════════════════════

/**
 * Tables that hold end-to-end-encrypted material, key material, or another person's data.
 *
 * NAMING ONE OF THESE IN AN EXPORT SECTION IS A BOOT FAILURE. The list is deliberately
 * wider than "content": it also covers key and prekey tables (exporting key material to
 * whoever holds a session token is a compromise, not an access response) and the social
 * graph (conversations, calls, contacts and follows are records about OTHER people as much
 * as about the requester, and answering one principal's access request by handing them a
 * list of everyone they have spoken to is a disclosure about those third parties).
 *
 * Anything not on the allow-list is already excluded; this list exists so that adding a
 * forbidden table is loud rather than merely wrong.
 */
const FORBIDDEN_TABLES = [
  // Content and its envelopes — the server holds ciphertext and no key.
  'messages', 'message_ciphertexts', 'message_read_receipts',
  'stories', 'story_keys', 'story_receipts',
  'location_shares', 'location_share_targets',
  // Key material.
  'mls_key_packages', 'mls_group_events',
  'one_time_prekeys', 'signed_prekeys', 'profile_keys',
  'recovery_keys', 'backups',
  // Records that are as much about someone else as about the requester.
  'conversations', 'conversation_members',
  'calls', 'call_participants',
  'contact_sync', 'creator_follows',
  'community_members', 'community_host_threads',
  // The admin plane. A principal's own data does not include who reviewed them.
  'admin_users', 'admin_sessions', 'admin_audit_log',
];

interface ExportSection {
  /** Key in the exported document. */
  key: string;
  /** One sentence, included in the document so the principal knows what they are reading. */
  description: string;
  /** SELECT with an explicit column list. $1 is always the subject's user id. */
  sql: string;
}

/**
 * The whole export, as data.
 *
 * Every column is listed by hand. That is tedious and it is the point: a reviewer can read
 * this array and know exactly what leaves the building, which is not true of any
 * abstraction that generates it.
 */
const EXPORT_SECTIONS: ExportSection[] = [
  {
    key: 'account',
    description:
      'Your account row. The phone number is your identity in Voiid — it is what an account IS, not a field on one.',
    sql: `select id, phone_number, username, full_name, email, photo_url, bio, status_text,
                 photo_privacy, about_privacy, last_seen_privacy,
                 consent_given_at, created_at, updated_at, deleted_at
            from users where id = $1`,
  },
  {
    key: 'devices',
    description:
      'Devices registered to your account. Voiid stores each device\'s PUBLIC key only; the private keys never leave the device and are not held here, so they cannot appear in this export.',
    // NO last_seen_at, and no push_token.
    //
    // last_seen_at is omitted because the column is never written — grepping the backend
    // finds three reads and zero writes. Printing a permanently empty field in a legal
    // access response is worse than omitting it: it invites the reading that we track
    // something we do not.
    //
    // The push token is omitted because it is a routing credential for waking this device,
    // not a fact about the person; whoever holds it can send that handset notifications.
    // `push_provider` and the boolean below say everything an access request needs — that
    // a token exists and which network it belongs to — without handing out the token.
    sql: `select id, device_name, platform, registration_id, os_version, app_version,
                 push_provider, (push_token is not null) as push_configured,
                 created_at, revoked_at
            from devices where user_id = $1 order by created_at`,
  },
  {
    key: 'consent_records',
    description:
      'Every consent you gave and every consent you withdrew, with the notice version and language it applied to.',
    sql: `select notice_version, language, purposes, given_at, given_via,
                 withdrawn_at, withdrawn_via
            from consent_records where user_id = $1 order by given_at`,
  },
  {
    key: 'clips',
    description:
      'Clips you posted. Clips are public, non-encrypted content by design — this is metadata about them, not the video files, which you can still see in the app.',
    sql: `select id, caption, duration_ms, width, height, byte_size, status,
                 view_count, like_count, comment_count,
                 created_at, deleted_at, removed_at, removed_reason
            from clips where author_id = $1 order by created_at`,
  },
  {
    key: 'security_events',
    description:
      'Security telemetry recorded against your account — failed logins, rate-limit trips and device linking. Kept for a limited period and then deleted.',
    // The `metadata` jsonb is deliberately not exported: it holds internal rate-limit
    // bucket names and, for some event types, identifiers belonging to the OTHER party in
    // an incident. Exporting it would answer one principal's request with another
    // principal's data.
    sql: `select event_type, ip_address, created_at
            from security_events where user_id = $1 order by created_at desc limit 500`,
  },
  {
    key: 'rights_requests',
    description: 'Requests you have made under the DPDP Act, and how each was handled.',
    sql: `select id, kind, status, subject_note, opened_at, due_at, closed_at, resolution
            from dpdp_requests where user_id = $1 order by opened_at desc`,
  },
];

/**
 * The guard that makes the header's claim true.
 *
 * Runs once, at module load, so a violating edit fails the process at startup rather than
 * on the first export request — the difference between a failed deploy and a disclosure.
 *
 * Word-boundary matching rather than `includes`, so that a legitimate table whose name
 * contains a forbidden one as a substring is not falsely rejected. Comments are stripped
 * first: a forbidden name mentioned in an explanatory comment inside a SQL string is not a
 * table reference, and a guard that cannot be explained around is a guard people work
 * around.
 */
function assertExportIsMetadataOnly(sections: ExportSection[]): void {
  for (const section of sections) {
    const sql = section.sql.replace(/--[^\n]*/g, '').toLowerCase();

    if (sql.includes('*')) {
      throw new Error(
        `dpdp export section "${section.key}" uses a wildcard column list. Every exported ` +
        `column must be named explicitly, so that a column added to the table later cannot ` +
        `join the export without a decision.`,
      );
    }
    for (const table of FORBIDDEN_TABLES) {
      if (new RegExp(`\\b${table}\\b`).test(sql)) {
        throw new Error(
          `dpdp export section "${section.key}" references "${table}", which holds ` +
          `end-to-end-encrypted material, key material, or another person's data. The ` +
          `export is metadata only; see the header of routes/dpdp.ts.`,
        );
      }
    }
  }
}

assertExportIsMetadataOnly(EXPORT_SECTIONS);

/**
 * The statement that belongs at the top of the document.
 *
 * Written out in full rather than summarised, because this is the part a principal (or a
 * regulator reading over their shoulder) will actually weigh, and because the sentence
 * "there is nothing to return" is only credible with the reason attached.
 */
const E2EE_DISCLOSURE = {
  headline: 'This export contains no message, call, location or moment content.',
  why:
    'Those are end-to-end encrypted. They are encrypted on your device with keys that never ' +
    'leave your devices, and Voiid\'s servers hold only ciphertext. There is no key on the ' +
    'server, and no endpoint anywhere in Voiid that can decrypt them — not this one, and not ' +
    'the admin panel.',
  consequence:
    'So this document cannot include your messages, your call audio or video, the locations ' +
    'you shared, or your moments — not because we decline to include them, but because we do ' +
    'not have them in a readable form. Those messages are on your devices, where you can read ' +
    'them in the app.',
  what_is_here:
    'What follows is the metadata Voiid does hold: your account row, your registered devices, ' +
    'your consent history, the clips you posted (which are public and not encrypted, by ' +
    'design), recent security events on your account, and your rights requests.',
  // Named so that a reader who wants to check the claim can, and so that the exclusions
  // below are not the only place the boundary is written down.
  see_also: 'database/migrations/030_dpdp.sql, database/migrations/022_clips.sql',
};

/**
 * What is deliberately absent, and why — because an unexplained absence looks like an
 * incomplete answer, and every one of these has a different reason.
 */
const DELIBERATE_EXCLUSIONS = [
  {
    what: 'Messages, calls, location shares, moments and their attachments',
    why: 'End-to-end encrypted. The server holds ciphertext and no key. See the notice above.',
  },
  {
    what: 'Cryptographic key material (prekeys, identity keys, MLS state, backup and recovery keys)',
    why:
      'Your private keys are not here to export — they are on your devices. What the server ' +
      'holds is public keys and opaque encrypted blobs, and handing those to whoever holds a ' +
      'session token would weaken your account rather than inform you about it.',
  },
  {
    what: 'Your conversation list, call history, synced contacts and follow graph',
    why:
      'These are records about other people as much as about you. Answering your access ' +
      'request with a list of everyone you have spoken to would disclose those people\'s data ' +
      'to whoever is reading this file.',
  },
  {
    what: 'Push notification tokens',
    why:
      'A push token is a credential for waking your device, not a fact about you. Whether a ' +
      'token exists, and which network it uses, is included above.',
  },
  {
    what: 'The internal detail attached to security events',
    why:
      'It contains internal rate-limit identifiers and, for some events, identifiers ' +
      'belonging to the other party in the incident.',
  },
];

// ─────────────────────────────────────────────────────────────────────────────────
// GET /dpdp/export — the metadata-only access response, served to the principal
// themselves.
//
// SELF-SERVICE ON PURPOSE. The fastest correct answer to "what do you hold about me" is
// the one that does not queue behind an operator, and the caller is already authenticated
// as the subject, so there is no identity-verification step to add value. An `access`
// REQUEST (below) is therefore for the case where this document did not answer them.
//
// No pagination and no streaming: every section is bounded by construction (one account
// row, a handful of devices, a capped security-events window, and a clips list that is
// already small enough for the app's own profile grid). If any of those stops being true,
// the fix is a bound on that section, not a wildcard.
// ─────────────────────────────────────────────────────────────────────────────────
router.get(
  '/export',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;

    const data: Record<string, unknown> = {};
    const sections: Array<{ key: string; description: string; row_count: number }> = [];

    // Sequential rather than Promise.all: this is a rare, non-latency-critical request,
    // and six concurrent queries from a single user's export is a pointless spike on a
    // pool that every other request shares.
    for (const section of EXPORT_SECTIONS) {
      const rows = await query(section.sql, [user_id]);
      data[section.key] = rows;
      sections.push({ key: section.key, description: section.description, row_count: rows.length });
    }

    res.json({
      // FIRST FIELD, not a footnote. See the header.
      e2ee_notice: E2EE_DISCLOSURE,
      deliberate_exclusions: DELIBERATE_EXCLUSIONS,
      // Bumped when the SHAPE changes, so a principal comparing two exports a year apart
      // can tell "this field disappeared" from "this file is laid out differently".
      format_version: 1,
      generated_at: new Date().toISOString(),
      subject_user_id: user_id,
      sections,
      data,
      // Not a compliance claim — a pointer, so a principal who is unsatisfied by this
      // document knows the next step exists.
      if_this_is_not_enough:
        'Open an access request (POST /dpdp/requests with kind "access") and a human will respond.',
    });
  }),
);

// ─────────────────────────────────────────────────────────────────────────────────
// POST /dpdp/requests  { kind, note? }
//
// Opening a request. The caller is authenticated, so the subject is known and there is
// nothing to verify — which is why an app-opened request may skip the console's
// `verifying` state. (Requests that arrive by email cannot, and the console keeps that
// state for them.)
// ─────────────────────────────────────────────────────────────────────────────────
router.post(
  '/requests',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const kind = String(req.body?.kind ?? '') as RequestKind;
    if (!(REQUEST_KINDS as readonly string[]).includes(kind)) {
      return res.status(400).json({ error: 'kind must be one of: ' + REQUEST_KINDS.join(', ') });
    }

    const raw = typeof req.body?.note === 'string' ? req.body.note.trim() : '';
    const note = raw ? raw.slice(0, MAX_NOTE_CHARS) : null;

    try {
      const rows = await query<{ id: string; kind: string; status: string; opened_at: string; due_at: string }>(
        `insert into dpdp_requests (user_id, kind, subject_note, due_at)
         values ($1, $2, $3, now() + make_interval(days => $4))
         returning id, kind, status, opened_at, due_at`,
        [user_id, kind, note, SLA_DAYS[kind]],
      );

      res.status(201).json({
        request: rows[0],
        // Said explicitly because it is the one place a user could reasonably assume
        // otherwise: opening an erasure REQUEST is not the same act as deleting the
        // account, and pretending it were would mean an endpoint that deletes an account
        // as a side effect of a form submission.
        note:
          kind === 'erasure'
            ? 'Recorded. This is a request to be actioned by a person — it has not deleted your ' +
              'account. You can delete it yourself at any time from Settings, which starts the ' +
              'same erasure immediately.'
            : 'Recorded. You can see its status at GET /dpdp/requests.',
      });
    } catch (err: any) {
      // 23505 = unique_violation on idx_dpdp_open_per_kind: one open request per kind.
      // Reported as a 409 with the existing row rather than as a failure, because from the
      // user's side "I already asked" is a success state, and a client retrying a request
      // it is not sure landed should get the same answer twice.
      if (err?.code === '23505') {
        const existing = await query(
          `select id, kind, status, opened_at, due_at from dpdp_requests
            where user_id = $1 and kind = $2 and closed_at is null limit 1`,
          [user_id, kind],
        );
        return res.status(409).json({
          error: 'a request of this kind is already open',
          request: existing[0] ?? null,
        });
      }
      throw err;
    }
  }),
);

/**
 * GET /dpdp/requests — the principal's own requests.
 *
 * `notes` (the operator's working notes) is not selected. The resolution is the answer and
 * belongs to the principal; the workings are internal and can name other people.
 */
router.get(
  '/requests',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const rows = await query(
      `select id, kind, status, subject_note, opened_at, due_at, closed_at, resolution
         from dpdp_requests where user_id = $1 order by opened_at desc limit 50`,
      [user_id],
    );
    res.json({ requests: rows });
  }),
);

export default router;

// ─────────────────────────────────────────────────────────────────────────────────
// MOUNT (for whoever owns backend/api/src/index.ts):
//
//   import dpdpRoutes from './routes/dpdp';
//   ...
//   // Data-principal rights (DPDP ss.11-13). The export is METADATA ONLY and is
//   // structurally prevented from naming any table that holds ciphertext or key material
//   // — see the guard at the top of routes/dpdp.ts. A low ceiling: opening a rights
//   // request is a once-in-an-account-lifetime action, and the export is expensive
//   // relative to how often anyone needs it.
//   api.use('/dpdp', rateLimit({ max: 20, windowSeconds: 60, bucket: 'dpdp' }), dpdpRoutes);
// ─────────────────────────────────────────────────────────────────────────────────
