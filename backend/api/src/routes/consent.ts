// Consent — the record that processing had a lawful basis, and the record of its withdrawal.
//
// ── WHY THIS IS A NEW ROUTER AND NOT A LINE IN users.ts ──────────────────────────
//
// `POST /users/consent` exists today and does one thing: `update users set
// consent_given_at = now()`. It has never been called by either app, so the column is
// null for every account in production. Both halves of that are defects, but they are
// different defects: the missing client leg is fixed in the apps, and the inadequate
// RECORD is fixed here. A bare timestamp cannot answer the only questions a consent
// record exists to answer — which notice, in which language, for which purposes, and
// was it later withdrawn. 030_dpdp.sql built the table that can; this is the endpoint
// that writes it.
//
// The legacy column is not orphaned: 030_dpdp.sql installs a trigger that keeps
// `users.consent_given_at` as a derived cache of "has any live consent", so old read
// paths keep working and a withdrawal cannot leave them saying "consented".
//
// ── METADATA ONLY ────────────────────────────────────────────────────────────────
//
// Nothing here reads, or could read, a message, a call, a location share or a moment.
// Those are end-to-end encrypted and the server holds ciphertext and no key. This file
// moves five facts about an ACCOUNT: which notice version, which language, which
// purposes, when, and by what route. That is the whole surface.
//
// ── THIS IMPLEMENTS A CONTROL; IT CERTIFIES NOTHING ──────────────────────────────
//
// [COUNSEL] The v1 notice declares every purpose REQUIRED, so the app presents one
// affirmative action for the bundle. DPDP s.6 requires consent that is "specific" and
// "unconditional", and whether bundling service-necessary purposes behind a single tick
// satisfies that — or whether each purpose needs its own toggle even when refusing one
// means the app cannot function — is an open question for India-qualified counsel. The
// schema and this endpoint already carry per-purpose booleans, so the answer is a data
// change (a new notice version whose purposes are marked optional) and not a rewrite.
// Tracked in docs/research/11_admin_dpdp.md §4 row 2 and docs/LEGAL_QUESTIONS.md §3.
import { Router } from 'express';
import { query } from '../db';
import { requireAuth } from '../auth';
import { asyncHandler } from '../util';

const router = Router();

// ─────────────────────────────────────────────────────────────────────────────────
// The purposes each published notice declares.
//
// WHY THIS LIVES IN CODE AND THE NOTICE ROW LIVES IN THE DATABASE. The row is
// evidence — which document, published when, at which locator — and evidence belongs
// in the database where it can be joined to a consent record years later. The purpose
// LIST is a contract between this endpoint's validation and the text the app renders,
// and a contract that can be edited in a psql session at 2am without a diff is not a
// contract. Same rationale 030_dpdp.sql gives for keeping retention periods as named
// constants in the worker rather than reading them from data_retention_policy.
//
// The consequence, stated so it is not discovered: seeding a NEW notice row without
// deploying a build that knows its purposes does not make that notice current. See
// currentNotice() below — that is deliberate, not a gap.
// ─────────────────────────────────────────────────────────────────────────────────

interface Purpose {
  key: string;
  /** Required = the app cannot deliver the service without it. See the [COUNSEL] note above. */
  required: boolean;
  /** One plain sentence. The apps render their own bundled copy of this; see the drift note in NOTICE_PURPOSES. */
  summary: string;
}

/**
 * Keyed by notice version (the `version` column of consent_notices), NOT by app build.
 *
 * The apps carry their own copy of these strings because the notice text is bundled —
 * a notice that only exists on a server is unreachable to someone being asked to agree
 * to it, which is the failure repair plan 3.31 is about. That duplication is real, so
 * the rule is: this table is the AUTHORITY for what may be stored, the app copy is a
 * DISPLAY copy, and a key the app invents is rejected here rather than written.
 */
const NOTICE_PURPOSES: Record<string, Purpose[]> = {
  '2026-08-01': [
    {
      key: 'identity',
      required: true,
      summary:
        'Your phone number identifies your account, and lets people who already have it find you.',
    },
    {
      key: 'delivery',
      required: true,
      summary:
        'Delivering your messages and calls. Voiid stores the encrypted bytes it cannot read, plus who they are addressed to and when.',
    },
    {
      key: 'security',
      required: true,
      summary:
        'Keeping accounts safe: detecting abuse and blocking automated attacks, using your IP address held for a short period.',
    },
    {
      key: 'support_diagnostics',
      required: true,
      summary:
        'Support and crash triage: the device name, platform, OS version and app version your app reports.',
    },
    // NOTE ON THE LAST ONE. support_diagnostics is marked REQUIRED even though it is the
    // most obviously "optional-looking" purpose here, because the device row is written
    // by device registration regardless of any flag in this table. Marking it optional
    // would put a switch in front of a user that changes nothing — a lie with a nicer
    // shape than the one this work is removing. Making it genuinely optional is a change
    // to the device-registration path FIRST (drop os_version/app_version when the flag is
    // false), and a new notice version SECOND.
  ],
};

/** How the consent arrived. Mirrors the CHECK constraint in 030_dpdp.sql. */
const GIVEN_VIA = ['app_onboarding', 'app_settings', 'backfill_prompt', 'support'] as const;
/** How a withdrawal arrived. Mirrors the CHECK constraint in 030_dpdp.sql. */
const WITHDRAWN_VIA = ['app_settings', 'support', 'account_deletion'] as const;

interface NoticeRow {
  version: string;
  language: string;
  url: string;
  published_at: string;
  content_sha256: Buffer | null;
}

/**
 * The notice a client should currently be shown, or null if there is none.
 *
 * "Current" = the newest published, un-retired notice THAT THIS BUILD ALSO HAS A PURPOSE
 * TABLE FOR. The join to NOTICE_PURPOSES is the whole point: a notice row seeded ahead of
 * a deploy would otherwise become current instantly, and every client would then be asked
 * to consent to a version whose purposes this process cannot validate — turning a
 * paperwork step into a signup outage. That is the same failure mode 030_dpdp.sql avoided
 * by refusing to put a foreign key between consent_records and consent_notices.
 *
 * Language: only 'en' is published. Whether the Eighth-Schedule translation obligation
 * applies at Voiid's size is [COUNSEL] (11_admin_dpdp.md §6.6), so the query filters by
 * requested language and returns nothing rather than silently serving English to someone
 * who asked for Tamil — an unanswered request is visible; a wrong one is not.
 */
async function currentNotice(language: string): Promise<NoticeRow | null> {
  const known = Object.keys(NOTICE_PURPOSES);
  if (known.length === 0) return null;
  const rows = await query<NoticeRow>(
    `select version, language, url, published_at, content_sha256
       from consent_notices
      where retired_at is null
        and language = $1
        and version = any($2::text[])
      order by published_at desc, version desc
      limit 1`,
    [language, known],
  );
  return rows[0] ?? null;
}

/**
 * Normalise a client-supplied purposes object into the full declared set.
 *
 * Three things happen here and each one is a defence:
 *   - an undeclared key is REJECTED, not dropped. Silently discarding it would let a
 *     client believe it recorded a choice that was never stored.
 *   - a required purpose that is present and false is REJECTED. Storing
 *     {"identity": false} on an account whose identity we are about to process would be
 *     an evidence record that contradicts the processing it evidences.
 *   - every declared key is written explicitly, so the stored object is always the
 *     complete set for that version. A missing key later reads as "unknown", and
 *     "unknown" is exactly what a consent record must never say.
 */
function normalisePurposes(
  version: string,
  input: unknown,
): { ok: true; purposes: Record<string, boolean> } | { ok: false; error: string } {
  const declared = NOTICE_PURPOSES[version];
  if (!declared) return { ok: false, error: 'unknown_notice_version' };

  let supplied: Record<string, unknown> = {};
  if (input != null) {
    if (typeof input !== 'object' || Array.isArray(input)) {
      return { ok: false, error: 'purposes must be an object' };
    }
    supplied = input as Record<string, unknown>;
  }

  const declaredKeys = new Set(declared.map((p) => p.key));
  for (const key of Object.keys(supplied)) {
    if (!declaredKeys.has(key)) return { ok: false, error: `unknown purpose: ${key}` };
    if (typeof supplied[key] !== 'boolean') return { ok: false, error: `purpose ${key} must be a boolean` };
  }

  const purposes: Record<string, boolean> = {};
  for (const p of declared) {
    const value = key(supplied, p.key);
    if (p.required) {
      // Absent is fine (the app agreed to the bundle); an explicit false is not.
      if (value === false) return { ok: false, error: `purpose ${p.key} is required by notice ${version}` };
      purposes[p.key] = true;
    } else {
      purposes[p.key] = value === true;
    }
  }
  return { ok: true, purposes };
}

/** Own-property read, so a body of {"__proto__": ...} cannot smuggle a value in. */
function key(obj: Record<string, unknown>, k: string): unknown {
  return Object.prototype.hasOwnProperty.call(obj, k) ? obj[k] : undefined;
}

// ─────────────────────────────────────────────────────────────────────────────────
// GET /consent/notice — which notice should this client present?
//
// UNAUTHENTICATED, deliberately. The affirmative action happens on the very first
// screen of onboarding, before a phone number has been entered and long before a JWT
// exists. Requiring auth here would force the app to ask for consent AFTER it had
// already processed the phone number it is asking for consent to process — the exact
// inversion DPDP s.5 ("notice at or before") is about.
// ─────────────────────────────────────────────────────────────────────────────────
router.get(
  '/notice',
  asyncHandler(async (req, res) => {
    const language = typeof req.query.language === 'string' && req.query.language ? req.query.language : 'en';
    const notice = await currentNotice(language);
    if (!notice) {
      // 404 rather than an empty 200: "there is no notice published in this language"
      // is a real answer the client must handle (fall back to its bundled English copy
      // and say so), not an empty success it can mistake for "no consent needed".
      return res.status(404).json({ error: 'no published notice for this language', code: 'notice_unavailable' });
    }
    res.json({
      version: notice.version,
      language: notice.language,
      url: notice.url,
      published_at: notice.published_at,
      // Null until the notice is served rather than bundled; see 031_consent_notice.sql.
      content_sha256: notice.content_sha256 ? notice.content_sha256.toString('hex') : null,
      purposes: NOTICE_PURPOSES[notice.version].map((p) => ({
        key: p.key,
        required: p.required,
        summary: p.summary,
      })),
    });
  }),
);

// ─────────────────────────────────────────────────────────────────────────────────
// GET /consent/me — does this account have live consent, and to what?
//
// Drives two things in the apps: the settings screen that shows what you agreed to and
// offers to withdraw it, and the backfill prompt for the accounts that were created
// before consent was ever captured.
// ─────────────────────────────────────────────────────────────────────────────────
router.get(
  '/me',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const language = typeof req.query.language === 'string' && req.query.language ? req.query.language : 'en';

    const rows = await query<{
      notice_version: string;
      language: string;
      purposes: Record<string, boolean>;
      given_at: string;
      given_via: string;
    }>(
      `select notice_version, language, purposes, given_at, given_via
         from consent_records
        where user_id = $1 and withdrawn_at is null
        order by given_at asc`,
      [user_id],
    );

    const notice = await currentNotice(language);
    const live = rows.map((r) => r.notice_version);
    res.json({
      // Every live consent, not just the newest: a user may hold consent to an older
      // notice version, and "you agreed to v1, we now publish v2" is a real state the
      // settings screen has to be able to show honestly.
      consents: rows,
      current_notice_version: notice?.version ?? null,
      // The single question the client actually branches on. False when the account
      // already holds live consent to the CURRENT notice; true when it holds none, or
      // only holds consent to a superseded version.
      needs_consent: notice ? !live.includes(notice.version) : false,
    });
  }),
);

// ─────────────────────────────────────────────────────────────────────────────────
// POST /consent — record an affirmative action.
// ─────────────────────────────────────────────────────────────────────────────────
router.post(
  '/',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const body = (req.body ?? {}) as Record<string, unknown>;

    const version = typeof body.notice_version === 'string' ? body.notice_version : '';
    const language = typeof body.language === 'string' && body.language ? body.language : 'en';
    const givenVia = typeof body.given_via === 'string' ? body.given_via : 'app_onboarding';

    if (!version) return res.status(400).json({ error: 'notice_version is required' });
    if (!(GIVEN_VIA as readonly string[]).includes(givenVia)) {
      return res.status(400).json({ error: 'invalid given_via' });
    }

    // The version must be one WE published. Rejecting an unknown version is the check
    // 030_dpdp.sql deliberately left out of the schema: a foreign key here would make
    // signup fail with a 500 whenever the registry is unseeded, whereas this returns a
    // 400 that names the problem.
    const noticeRows = await query<{ version: string }>(
      `select version from consent_notices
        where version = $1 and language = $2 and retired_at is null`,
      [version, language],
    );
    if (noticeRows.length === 0) {
      return res.status(400).json({ error: 'unknown or retired notice version', code: 'notice_unknown' });
    }
    if (!NOTICE_PURPOSES[version]) {
      // Published, but this build does not know its purposes — a deploy skew, not a
      // client error. 409 so the app retries later instead of treating it as "your
      // consent was rejected" and blocking the user forever.
      return res.status(409).json({ error: 'notice not servable by this build', code: 'notice_skew' });
    }

    const normalised = normalisePurposes(version, body.purposes);
    if (!normalised.ok) return res.status(400).json({ error: normalised.error });

    // ON CONFLICT against the PARTIAL unique index idx_consent_active — note the WHERE
    // clause, which is not optional decoration: without it Postgres cannot infer a
    // partial index as the arbiter and this statement fails outright. (The related trap
    // 030_dpdp.sql documents is the opposite one: a nullable column inside a plain unique
    // key makes ON CONFLICT never match, silently turning an upsert into an insert.)
    //
    // given_at is NOT updated on conflict. Re-posting the same consent — an app retry, a
    // second device, a settings screen re-affirming — must not move the moment the user
    // actually acted; "consenting since" is the value the trigger mirrors onto
    // users.consent_given_at, and it would drift forward on every retry otherwise.
    const rows = await query<{
      id: string;
      notice_version: string;
      language: string;
      purposes: Record<string, boolean>;
      given_at: string;
      given_via: string;
    }>(
      `insert into consent_records (user_id, notice_version, language, purposes, given_via)
       values ($1, $2, $3, $4::jsonb, $5)
       on conflict (user_id, notice_version) where withdrawn_at is null
       do update set purposes = excluded.purposes, given_via = excluded.given_via
       returning id, notice_version, language, purposes, given_at, given_via`,
      [user_id, version, language, JSON.stringify(normalised.purposes), givenVia],
    );

    res.json({ consent: rows[0] });
  }),
);

// ─────────────────────────────────────────────────────────────────────────────────
// POST /consent/withdraw — s.6(4): withdrawal must be as easy as giving.
//
// "As easy" is a design constraint on the CLIENT (one tap, from the same screen that
// shows what was agreed, no support ticket, no email), and this endpoint is the part of
// it the server owns: one call, no arguments required, no verification step.
//
// WHAT WITHDRAWAL DOES AND DOES NOT DO, because the honest answer is uncomfortable:
// every purpose in the v1 notice is one the service cannot run without. Withdrawing
// consent therefore does not put the account into a reduced mode — there is no reduced
// mode to put it in — it records that consent ended, and the app tells the user plainly
// that continuing to use Voiid means deleting the account. This endpoint deliberately
// does NOT delete anything: erasure is DELETE /users/me plus the erasure worker (repair
// plan 3.25), and silently destroying an account from a "withdraw consent" tap would be
// a far worse surprise than the extra confirmation.
//
// [COUNSEL] Whether s.6(4)+s.8(7) require withdrawal to AUTOMATICALLY trigger erasure,
// or whether recording the withdrawal and requiring a separate deletion is sufficient,
// is unresolved — as is what lawful basis (if any) covers the interval between the two.
// Do not resolve this by wiring the two calls together without advice.
// ─────────────────────────────────────────────────────────────────────────────────
router.post(
  '/withdraw',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id } = (req as any).auth;
    const body = (req.body ?? {}) as Record<string, unknown>;

    const withdrawnVia = typeof body.withdrawn_via === 'string' ? body.withdrawn_via : 'app_settings';
    if (!(WITHDRAWN_VIA as readonly string[]).includes(withdrawnVia)) {
      return res.status(400).json({ error: 'invalid withdrawn_via' });
    }
    // Optional. Absent = withdraw everything live, which is what the in-app control does:
    // asking a user to pick which notice version to withdraw from is not "as easy as
    // giving", it is a quiz.
    const version = typeof body.notice_version === 'string' && body.notice_version ? body.notice_version : null;
    const note = typeof body.note === 'string' ? body.note.slice(0, 2000) : null;

    // One conditional UPDATE ... RETURNING, not select-then-update: two concurrent
    // withdrawals (the user tapping twice, or a support action racing the app) would
    // otherwise both read "live" and both write, and the second would move withdrawn_at
    // forward — overwriting the moment consent actually ended.
    //
    // `withdrawn_at is null` in the predicate is what makes this idempotent: a repeat
    // call matches nothing and returns an empty set, which the response reports honestly
    // as zero rather than dressing up as a fresh withdrawal.
    const rows = await query<{ notice_version: string; withdrawn_at: string }>(
      `update consent_records
          set withdrawn_at = now(), withdrawn_via = $2, withdrawal_note = $3
        where user_id = $1
          and withdrawn_at is null
          and ($4::text is null or notice_version = $4)
        returning notice_version, withdrawn_at`,
      [user_id, withdrawnVia, note, version],
    );

    // The trigger in 030_dpdp.sql has already recomputed users.consent_given_at from the
    // remaining live rows, so no second write is needed here — and must not be added,
    // because a hand-maintained copy is exactly what that trigger exists to prevent.
    res.json({ withdrawn: rows });
  }),
);

export default router;
