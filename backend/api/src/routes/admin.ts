// Admin routes — the moderation plane (see 028_admin_users.sql).
//
// A SEPARATE AUTH SYSTEM, ON PURPOSE. Every other router here authenticates a Voiid USER via
// `requireAuth`, which resolves a JWT minted from an SMS OTP. This one does not, and must
// not: a phone number is a credential someone else's carrier controls, and a SIM swap should
// never also grant the ability to read every clip on the platform. Admins have their own
// table, their own email+password credential, and no path from a user session to this plane.
//
// SESSIONS ARE SERVER-SIDE. A stateless JWT cannot be revoked before it expires — a lost
// admin laptop would mean waiting it out or rotating the signing secret for everyone. A row
// can be deleted. For a plane that can take content down, instant revocation is worth the
// lookup on every request.
//
// NOTHING HERE TOUCHES E2EE CONTENT. Admins can read clips because clips are public
// plaintext by design (022_clips.sql). Messages, calls, locations and moments remain
// end-to-end encrypted and are not readable from this router or any other — there is no
// endpoint, and no key, that would let one. The people-facing surfaces added below (the
// users list, the device viewer, the data-principal console) do not change that: they show
// ACCOUNT metadata and acts of administration, and there is nothing else for them to show.
//
// TWO ROLES (033_admin_roles.sql). `moderator` works the clip queue, all of whose actions
// are reversible. `admin` additionally holds every power that touches a PERSON or destroys
// data: the irreversible clip purge, the per-user device and security view, device
// revocation, and the whole DPDP console. The gate is `requireRole('admin')` applied per
// route rather than an `if` inside each handler, because the failure mode of a role system
// is a new privileged endpoint nobody remembered to gate, and a missing middleware in a
// route definition is visible in review in a way a missing branch is not.
import { Router } from 'express';
import type { Request, Response, NextFunction } from 'express';
import bcrypt from 'bcryptjs';
import { createHash, randomBytes, timingSafeEqual } from 'crypto';
import { pool, query } from '../db';
import { presignGet, deleteObject, r2Configured } from '../r2';
import { clientIp } from '../security';
import { invalidateAccountState } from '../auth';
import { CAPABILITIES, isCapability } from '../communityEntitlements';

const router = Router();

/** 12 hours. Long enough for a working session, short enough that a forgotten laptop lapses. */
const SESSION_TTL_SECONDS = 12 * 60 * 60;

/**
 * Tokens are stored HASHED, never raw.
 *
 * SHA-256 rather than bcrypt, deliberately: this is a 256-bit random value, not a
 * user-chosen password, so there is no dictionary to slow down — and it is checked on every
 * request, where bcrypt's cost would be paid on every page load for no security gain.
 */
function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

/** Record an admin action. Best-effort: a failed audit write must not fail the action. */
async function audit(adminId: string | null, action: string,
                     targetType?: string, targetId?: string, detail?: unknown) {
  try {
    await query(
      `insert into admin_audit_log (admin_id, action, target_type, target_id, detail)
       values ($1, $2, $3, $4, $5)`,
      [adminId, action, targetType ?? null, targetId ?? null,
       detail == null ? null : JSON.stringify(detail)]
    );
  } catch {
    // Swallow. An audit failure is worth neither a 500 nor blocking a takedown.
  }
}

// ─────────────────────────────────────────────────────────────────────────────────
// Auth middleware
// ─────────────────────────────────────────────────────────────────────────────────

type AdminRole = 'moderator' | 'admin';

interface AdminAuth { adminId: string; email: string; name: string | null; role: AdminRole }

async function requireAdmin(req: Request, res: Response, next: NextFunction) {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'admin auth required' });
  }
  const rows = await query<{ admin_id: string; email: string; name: string | null; role: string; disabled_at: string | null }>(
    `select s.admin_id, a.email, a.name, a.role, a.disabled_at
       from admin_sessions s
       join admin_users a on a.id = s.admin_id
      where s.token_hash = $1 and s.expires_at > now()
      limit 1`,
    [hashToken(header.slice(7))]
  );
  const row = rows[0];
  // A disabled admin's sessions die immediately rather than lingering until expiry — that
  // is most of the point of revocable sessions.
  if (!row || row.disabled_at) {
    return res.status(401).json({ error: 'invalid or expired session' });
  }
  // The role is read from the ROW on every request, not baked into the session at login.
  // A demotion has to take effect on the next request for the same reason a disable does:
  // the alternative is telling an operator "we removed their access" while a live tab keeps
  // the power they just took away.
  //
  // Anything other than 'admin' falls back to the least privilege rather than throwing, so
  // an unrecognised value in the column can only ever cost access, never grant it.
  const role: AdminRole = row.role === 'admin' ? 'admin' : 'moderator';
  (req as any).admin = { adminId: row.admin_id, email: row.email, name: row.name, role } as AdminAuth;
  next();
}

/**
 * Gate a route on a role. Always used AFTER requireAdmin, which is what populates req.admin.
 *
 * The denial is audited. An attempt to reach a privileged endpoint from a moderator session
 * is either a UI bug or the interesting half of an incident, and neither is discoverable if
 * the 403 is silent.
 */
function requireRole(required: AdminRole) {
  return async (req: Request, res: Response, next: NextFunction) => {
    const a = (req as any).admin as AdminAuth | undefined;
    if (!a) return res.status(401).json({ error: 'admin auth required' });
    if (required === 'admin' && a.role !== 'admin') {
      await audit(a.adminId, 'admin.forbidden', 'route', `${req.method} ${req.baseUrl}${req.path}`,
                  { role: a.role, required });
      return res.status(403).json({ error: 'this action requires the admin role' });
    }
    next();
  };
}

/**
 * Phone numbers are masked EVERYWHERE this router returns one, with no unmask endpoint.
 *
 * The admin plane's jobs are moderating public content and answering rights requests, and
 * neither needs to read a full phone number: a support case starts from a number somebody
 * already has, which the users search can confirm by lookup. So the panel can verify a
 * number you hold and cannot harvest one you do not — which is the whole of what the job
 * requires, and data minimisation applies to the admin plane too.
 *
 * Keeps the dialling prefix and the last two digits: enough to tell two accounts apart in a
 * list, not enough to dial or to re-identify.
 */
function maskPhone(phone: string | null): string | null {
  if (!phone) return null;
  if (phone.length <= 5) return '•'.repeat(phone.length);
  return `${phone.slice(0, 3)}${'•'.repeat(phone.length - 5)}${phone.slice(-2)}`;
}

// ─────────────────────────────────────────────────────────────────────────────────
// POST /admin/login  { email, password }
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/login', async (req, res) => {
  const email = String(req.body?.email ?? '').trim().toLowerCase();
  const password = String(req.body?.password ?? '');
  if (!email || !password) return res.status(400).json({ error: 'email and password required' });

  const rows = await query<{ id: string; password_hash: string; name: string | null; disabled_at: string | null }>(
    `select id, password_hash, name, disabled_at from admin_users where lower(email) = $1 limit 1`,
    [email]
  );
  const admin = rows[0];

  // ONE indistinguishable failure for "no such admin", "wrong password" and "disabled".
  // Anything else turns this endpoint into an oracle for which emails are admins — the
  // single most useful thing an attacker could learn from it.
  //
  // bcrypt.compare runs even with no matching row, against a dummy hash, so the response
  // time does not reveal whether the email exists.
  const hash = admin?.password_hash
    ?? '$2a$10$invalidinvalidinvalidinvalidinvalidinvalidinvalidinvalidinv';
  const ok = await bcrypt.compare(password, hash);
  if (!admin || !ok || admin.disabled_at) {
    await audit(admin?.id ?? null, 'admin.login_failed', 'admin', email,
                { ip: clientIp(req) });
    return res.status(401).json({ error: 'invalid credentials' });
  }

  const token = randomBytes(32).toString('base64url');
  await query(
    `insert into admin_sessions (token_hash, admin_id, expires_at, user_agent, ip)
     values ($1, $2, now() + ($3 || ' seconds')::interval, $4, $5)`,
    [hashToken(token), admin.id, String(SESSION_TTL_SECONDS),
     req.headers['user-agent'] ?? null, clientIp(req)]
  );
  await query(`update admin_users set last_login_at = now() where id = $1`, [admin.id]);
  await audit(admin.id, 'admin.login', 'admin', admin.id, { ip: clientIp(req) });

  res.json({ token, expires_in: SESSION_TTL_SECONDS, name: admin.name, email });
});

// POST /admin/logout — delete THIS session (not every session for the admin).
router.post('/logout', requireAdmin, async (req, res) => {
  const header = req.headers.authorization!;
  await query(`delete from admin_sessions where token_hash = $1`, [hashToken(header.slice(7))]);
  res.json({ ok: true });
});

/**
 * GET /admin/me — who am I, for the panel's header. Also the session-validity probe.
 *
 * `role` is returned so the panel can hide what this session cannot do. That is a courtesy
 * to the operator, NOT the control: every privileged route carries requireRole on the
 * server, and a hand-crafted request from a moderator session is refused there.
 */
router.get('/me', requireAdmin, (req, res) => {
  const a = (req as any).admin as AdminAuth;
  res.json({ email: a.email, name: a.name, role: a.role });
});

// ─────────────────────────────────────────────────────────────────────────────────
// GET /admin/stats — the dashboard's top row.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/stats', requireAdmin, async (_req, res) => {
  const rows = await query<Record<string, number>>(`
    select
      (select count(*) from users where deleted_at is null)::int          as users,
      (select count(*) from clips where removed_at is null)::int          as clips,
      (select count(*) from clips where removed_at is not null)::int      as clips_removed,
      (select count(*) from clip_comments)::int                           as comments,
      (select count(*) from clips
        where created_at > now() - interval '24 hours'
          and removed_at is null)::int                                    as clips_24h,
      (select count(*) from users
        where created_at > now() - interval '24 hours'
          and deleted_at is null)::int                                    as users_24h,
      -- The two numbers that make a rights queue visible on the screen people actually
      -- open. A DPDP request breaches its period by being forgotten, not by being refused,
      -- so the overdue count belongs where somebody will see it without navigating to it.
      (select count(*) from dpdp_requests where closed_at is null)::int    as dpdp_open,
      (select count(*) from dpdp_requests
        where closed_at is null and due_at < now())::int                  as dpdp_overdue,
      -- Communities, split the way an operator reads them: how many exist, and how many are
      -- currently taken down. A single total would hide the second number entirely.
      (select count(*) from communities where suspended_at is null)::int     as communities,
      (select count(*) from communities where suspended_at is not null)::int as communities_suspended,
      (select count(*) from communities
        where created_at > now() - interval '24 hours'
          and suspended_at is null)::int                                     as communities_24h,

      -- The rest of the platform. Every module Voiid ships gets a number here, because a
      -- console that only counts what it can moderate leaves an operator unable to answer
      -- "is games working" without a psql prompt.
      --
      -- These are VOLUMES AND CONTAINERS, never content: conversations counts threads, not
      -- messages, and calls counts sessions, not audio. Both are E2EE and the server holds
      -- no key, so the encryption stays a fact rather than a claim.
      (select count(*) from stories)::int                                    as stories,
      (select count(*) from creator_profiles)::int                           as creators,
      (select count(*) from creator_highlights)::int                         as highlights,
      (select count(*) from game_lobbies)::int                               as game_lobbies,
      (select count(*) from game_lobbies
        where created_at > now() - interval '24 hours')::int                 as game_lobbies_24h,
      (select count(*) from tournaments)::int                                as tournaments,
      (select count(*) from community_events)::int                           as events,
      (select count(*) from event_tickets)::int                              as event_tickets,
      (select count(*) from event_orders)::int                               as event_orders,
      (select count(*) from conversations)::int                              as conversations,
      (select count(*) from calls)::int                                      as calls,
      (select count(*) from calls where ended_at is null)::int               as calls_active,
      (select count(*) from devices)::int                                    as devices,
      (select count(*) from user_blocks)::int                                as blocks
  `);
  res.json(rows[0] ?? {});
});

// ─────────────────────────────────────────────────────────────────────────────────
// GET /admin/geo — where accounts registered, by phone dialling prefix.
//
// WHAT THIS IS NOT: a map of where people are. Voiid stores no user geolocation at all —
// live location shares are encrypted on-device and never persisted (routes/location.ts),
// and there is no country column on `users`. The only geographic signal the server holds is
// the country code inside an E.164 phone number, which says where the SIM was issued.
//
// That distinction is stated on the page too, because a world map is read as "our users are
// here" by default, and someone will make a decision on it.
//
// Longest-prefix wins: +1 must not swallow +1242, and +7 must not swallow +7xx. Three
// prefixes are genuinely ambiguous (+1 covers 13 NANP countries, +7 two, +39 two) and are
// labelled by region rather than assigned to a country we cannot distinguish — guessing
// "US" for every +1 would invent a fact.
// ─────────────────────────────────────────────────────────────────────────────────
const DIAL_PREFIXES: [string, string][] = [
  ['211', 'SS'],
  ['212', 'MA'],
  ['213', 'DZ'],
  ['216', 'TN'],
  ['218', 'LY'],
  ['220', 'GM'],
  ['221', 'SN'],
  ['222', 'MR'],
  ['223', 'ML'],
  ['224', 'GN'],
  ['225', 'CI'],
  ['226', 'BF'],
  ['227', 'NE'],
  ['228', 'TG'],
  ['229', 'BJ'],
  ['230', 'MU'],
  ['231', 'LR'],
  ['232', 'SL'],
  ['233', 'GH'],
  ['234', 'NG'],
  ['235', 'TD'],
  ['236', 'CF'],
  ['237', 'CM'],
  ['238', 'CV'],
  ['239', 'ST'],
  ['240', 'GQ'],
  ['241', 'GA'],
  ['242', 'CG'],
  ['243', 'CD'],
  ['244', 'AO'],
  ['245', 'GW'],
  ['248', 'SC'],
  ['249', 'SD'],
  ['250', 'RW'],
  ['251', 'ET'],
  ['252', 'SO'],
  ['253', 'DJ'],
  ['254', 'KE'],
  ['255', 'TZ'],
  ['256', 'UG'],
  ['257', 'BI'],
  ['258', 'MZ'],
  ['260', 'ZM'],
  ['261', 'MG'],
  ['263', 'ZW'],
  ['264', 'NA'],
  ['265', 'MW'],
  ['266', 'LS'],
  ['267', 'BW'],
  ['268', 'SZ'],
  ['269', 'KM'],
  ['291', 'ER'],
  ['351', 'PT'],
  ['352', 'LU'],
  ['353', 'IE'],
  ['354', 'IS'],
  ['355', 'AL'],
  ['356', 'MT'],
  ['357', 'CY'],
  ['358', 'FI'],
  ['359', 'BG'],
  ['370', 'LT'],
  ['371', 'LV'],
  ['372', 'EE'],
  ['373', 'MD'],
  ['374', 'AM'],
  ['375', 'BY'],
  ['376', 'AD'],
  ['377', 'MC'],
  ['378', 'SM'],
  ['380', 'UA'],
  ['381', 'RS'],
  ['382', 'ME'],
  ['385', 'HR'],
  ['386', 'SI'],
  ['387', 'BA'],
  ['389', 'MK'],
  ['420', 'CZ'],
  ['421', 'SK'],
  ['423', 'LI'],
  ['501', 'BZ'],
  ['502', 'GT'],
  ['503', 'SV'],
  ['504', 'HN'],
  ['505', 'NI'],
  ['506', 'CR'],
  ['507', 'PA'],
  ['509', 'HT'],
  ['591', 'BO'],
  ['592', 'GY'],
  ['593', 'EC'],
  ['595', 'PY'],
  ['597', 'SR'],
  ['598', 'UY'],
  ['670', 'TL'],
  ['673', 'BN'],
  ['674', 'NR'],
  ['675', 'PG'],
  ['676', 'TO'],
  ['677', 'SB'],
  ['678', 'VU'],
  ['679', 'FJ'],
  ['680', 'PW'],
  ['685', 'WS'],
  ['686', 'KI'],
  ['688', 'TV'],
  ['691', 'FM'],
  ['692', 'MH'],
  ['850', 'KP'],
  ['852', 'HK'],
  ['853', 'MO'],
  ['855', 'KH'],
  ['856', 'LA'],
  ['880', 'BD'],
  ['886', 'TW'],
  ['960', 'MV'],
  ['961', 'LB'],
  ['962', 'JO'],
  ['963', 'SY'],
  ['964', 'IQ'],
  ['965', 'KW'],
  ['966', 'SA'],
  ['967', 'YE'],
  ['968', 'OM'],
  ['971', 'AE'],
  ['972', 'IL'],
  ['973', 'BH'],
  ['974', 'QA'],
  ['975', 'BT'],
  ['976', 'MN'],
  ['977', 'NP'],
  ['992', 'TJ'],
  ['993', 'TM'],
  ['994', 'AZ'],
  ['995', 'GE'],
  ['996', 'KG'],
  ['998', 'UZ'],
  ['20', 'EG'],
  ['27', 'ZA'],
  ['30', 'GR'],
  ['31', 'NL'],
  ['32', 'BE'],
  ['33', 'FR'],
  ['34', 'ES'],
  ['36', 'HU'],
  ['39', 'IT'],
  ['40', 'RO'],
  ['41', 'CH'],
  ['43', 'AT'],
  ['44', 'GB'],
  ['45', 'DK'],
  ['46', 'SE'],
  ['47', 'NO'],
  ['48', 'PL'],
  ['49', 'DE'],
  ['51', 'PE'],
  ['52', 'MX'],
  ['53', 'CU'],
  ['54', 'AR'],
  ['55', 'BR'],
  ['56', 'CL'],
  ['57', 'CO'],
  ['58', 'VE'],
  ['60', 'MY'],
  ['61', 'AU'],
  ['62', 'ID'],
  ['63', 'PH'],
  ['64', 'NZ'],
  ['65', 'SG'],
  ['66', 'TH'],
  ['81', 'JP'],
  ['82', 'KR'],
  ['84', 'VN'],
  ['86', 'CN'],
  ['90', 'TR'],
  ['91', 'IN'],
  ['92', 'PK'],
  ['93', 'AF'],
  ['94', 'LK'],
  ['95', 'MM'],
  ['98', 'IR'],
  ['1', 'NANP'],
  ['7', 'RU']
];

router.get('/geo', requireAdmin, async (_req, res) => {
  // Grouped in SQL by the longest matching prefix. The values are a fixed, code-side
  // table — not user input — so they are inlined as a VALUES list rather than parameterised
  // into 183 placeholders, and every entry is asserted to be digits-only below.
  for (const [dial] of DIAL_PREFIXES) {
    if (!/^[0-9]{1,4}$/.test(dial)) throw new Error(`bad dial prefix: ${dial}`);
  }
  const values = DIAL_PREFIXES.map(([d, c]) => `('${d}','${c}')`).join(',');

  const rows = await query<{ code: string; dial: string; users: number }>(
    `with p(dial, code) as (values ${values}),
     matched as (
       select u.id,
              (select p.code from p
                where u.phone_number like '+' || p.dial || '%'
                -- Longest prefix wins: +1242 (Bahamas) must not be counted as +1.
                order by length(p.dial) desc
                limit 1) as code
         from users u
        where u.deleted_at is null and u.phone_number is not null
     )
     select coalesce(code, 'UNKNOWN') as code,
            ''::text as dial,
            count(*)::int as users
       from matched
      group by 1
      order by users desc`,
  );

  // Named per COUNTRY. Names come from Node's own ICU data rather than a table checked in
  // here: a hardcoded list of 200 names is one more thing to drift, and this one is
  // already correct and already installed.
  const display = new Intl.DisplayNames(['en'], { type: 'region' });
  const nameOf = (code: string): string => {
    if (code === 'UNKNOWN') return 'Unknown';
    // The three ambiguous dialling prefixes cannot name a single country, so they are
    // labelled by what they actually are. Calling +1 "United States" would invent a fact.
    if (code === 'NANP') return 'US & Canada';
    try {
      // DisplayNames returns the input unchanged for a code it does not know, which would
      // surface a bare "XX" — better than throwing, and rare enough to leave visible.
      return display.of(code) ?? code;
    } catch {
      return code;
    }
  };

  const total = rows.reduce((n, r) => n + r.users, 0);
  const countries = rows.map((r) => ({
    code: r.code,
    name: nameOf(r.code),
    users: r.users,
    // One decimal: whole percents make a four-account database read as 25/25/25/25 and
    // hide everything smaller.
    share: total > 0 ? Math.round((r.users / total) * 1000) / 10 : 0,
  }));

  res.json({
    countries,
    total,
    // Said explicitly so a caller cannot mistake this for presence data.
    basis: 'phone_country_code',
    note: 'Where accounts registered, by phone dialling prefix. Not current location.',
  });
});

// ─────────────────────────────────────────────────────────────────────────────────
// GET /admin/series?days=30   — the last N days, or
// GET /admin/series?from=YYYY-MM-DD&to=YYYY-MM-DD — an explicit range.
//
// Both spellings exist because they answer different questions: "how are we doing lately"
// wants a rolling window that stays current, while "what happened during the incident on
// the 14th" wants fixed edges that do not move as the clock does.
//
// generate_series LEFT JOINed against each table, so a day with no signups comes back as a
// zero rather than as a missing point. A chart built from present rows only silently
// redraws its x-axis and turns a quiet week into a straight line between two busy days —
// which reads as steady activity when the truth is none.
//
// One query, not six: six round trips to draw one screen is how a dashboard becomes the
// slowest page in a tool people are supposed to keep open.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/series', requireAdmin, async (req, res) => {
  // A strict shape check, not a Date parse. `new Date('2026-02-31')` and
  // `new Date('banana')` both produce something, and neither belongs in a SQL cast — the
  // value is parameterised either way, but a malformed date should be a 400 with a reason
  // rather than a 500 from Postgres.
  const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
  const rawFrom = typeof req.query.from === 'string' ? req.query.from : null;
  const rawTo = typeof req.query.to === 'string' ? req.query.to : null;
  const custom = Boolean(rawFrom && rawTo);

  if ((rawFrom || rawTo) && !custom) {
    return res.status(400).json({ error: 'from and to must be given together' });
  }
  if (custom && (!DATE_RE.test(rawFrom!) || !DATE_RE.test(rawTo!))) {
    return res.status(400).json({ error: 'dates must be YYYY-MM-DD' });
  }
  if (custom && rawFrom! > rawTo!) {
    // String comparison is sound on zero-padded ISO dates, and says the useful thing rather
    // than silently returning an empty series for a backwards range.
    return res.status(400).json({ error: 'from must not be after to' });
  }

  // Capped at a year for an explicit range, a quarter for the rolling window. This scans
  // created_at across several tables with no index guarantee, and an operator typing
  // days=100000 should not be able to table-scan the production database from a query
  // string. The cap is enforced in SQL below rather than trusted from the client.
  const MAX_DAYS = 366;
  const days = Math.min(Math.max(Number(req.query.days) || 30, 1), 90);

  // The day-spine differs between the two modes; everything measured against it does not.
  // Built as one string so the shared body is written once — a ternary spanning two template
  // literals leaves the select clause dangling outside both.
  const spine = custom
    ? `with bounds as (
         select $1::date as lo,
                -- least() clamps the far edge instead of rejecting a wide range: an operator
                -- who asks for five years gets the most recent year, which is more useful
                -- than an error telling them to ask again.
                least($2::date, ($1::date + ($3::int - 1) * interval '1 day')::date) as hi
       ),
       d as (select generate_series(lo, hi, interval '1 day')::date as day from bounds)`
    : `with d as (
         select generate_series(
           (current_date - ($1::int - 1) * interval '1 day')::date,
           current_date,
           interval '1 day'
         )::date as day
       )`;

  const rows = await query<any>(
    `${spine}
     select to_char(d.day, 'YYYY-MM-DD') as day,
       (select count(*) from users u
         where u.created_at::date = d.day and u.deleted_at is null)::int      as users,
       (select count(*) from clips c
         where c.created_at::date = d.day and c.removed_at is null)::int      as clips,
       (select count(*) from communities m
         where m.created_at::date = d.day)::int                               as communities,
       (select count(*) from community_posts p
         where p.created_at::date = d.day)::int                               as posts,
       (select count(*) from conversations v
         where v.created_at::date = d.day)::int                               as conversations
     from d order by d.day asc`,
    custom ? [rawFrom, rawTo, MAX_DAYS] : [days],
  );

  res.json({
    // Echoes the range actually used, not the one asked for — the far edge may have been
    // clamped, and a chart that labelled itself with the request would then be lying.
    from: rows[0]?.day ?? null,
    to: rows[rows.length - 1]?.day ?? null,
    days: rows.length,
    series: rows,
  });
});

// ─────────────────────────────────────────────────────────────────────────────────
// GET /admin/clips?cursor=&limit=&removed=
//
// The moderation queue. Newest first, keyset-paginated on created_at rather than OFFSET:
// offset pagination re-scans and, worse, SKIPS rows when something is removed mid-scroll —
// which on a moderation queue means missing the clip you were looking for.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/clips', requireAdmin, async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 30, 100);
  const cursor = typeof req.query.cursor === 'string' ? req.query.cursor : null;
  const removed = req.query.removed === 'true';

  const rows = await query<any>(
    `select c.id, c.author_id, c.caption, c.thumb_r2_key, c.r2_key,
            c.duration_ms, c.width, c.height, c.byte_size, c.created_at,
            c.removed_at, c.removed_reason,
            c.like_count, c.view_count, c.comment_count,
            u.full_name as author_name, u.username as author_username
       from clips c
       left join users u on u.id = c.author_id
      where ${removed ? 'c.removed_at is not null' : 'c.removed_at is null'}
        ${cursor ? 'and c.created_at < $2' : ''}
      order by c.created_at desc
      limit $1`,
    cursor ? [limit, cursor] : [limit]
  );

  // Thumbnails are signed here rather than returned as raw keys: the panel cannot reach R2
  // directly, and a moderation list without pictures is unusable for its one job.
  const clips = await Promise.all(rows.map(async (c) => ({
    ...c,
    thumb_url: r2Configured() && c.thumb_r2_key
      ? await presignGet(c.thumb_r2_key).catch(() => null)
      : null,
  })));

  res.json({
    clips,
    // Null when the page was not full — the client uses that to stop, rather than issuing
    // one more request that returns nothing.
    next_cursor: rows.length === limit ? rows[rows.length - 1].created_at : null,
  });
});

/** GET /admin/clips/:id/playback — a signed URL for the actual video, to review it. */
router.get('/clips/:id/playback', requireAdmin, async (req, res) => {
  const rows = await query<{ r2_key: string; r2_key_sd: string | null }>(
    `select r2_key, r2_key_sd from clips where id = $1 limit 1`, [req.params.id]);
  const clip = rows[0];
  if (!clip) return res.status(404).json({ error: 'not found' });
  if (!r2Configured()) return res.status(503).json({ error: 'media storage not configured' });
  // SD when available — a moderator is judging content, not picture quality, and the
  // smaller rendition loads faster on a queue you are scrolling through.
  const key = clip.r2_key_sd ?? clip.r2_key;
  res.json({ url: await presignGet(key) });
});

// ─────────────────────────────────────────────────────────────────────────────────
// POST /admin/clips/:id/remove  { reason }
//
// SOFT delete. The row and the media stay; only visibility changes. A mistaken takedown is
// recoverable, and a disputed one has a record — a hard DELETE destroys the evidence of why
// something was removed, which is exactly what you need when the author asks.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/clips/:id/remove', requireAdmin, async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  const reason = String(req.body?.reason ?? '').trim() || null;

  const rows = await query<{ id: string; author_id: string }>(
    `update clips
        set removed_at = now(), removed_by = $2, removed_reason = $3
      where id = $1 and removed_at is null
      returning id, author_id`,
    [req.params.id, a.adminId, reason]
  );
  if (!rows[0]) return res.status(404).json({ error: 'not found or already removed' });

  await audit(a.adminId, 'clip.remove', 'clip', req.params.id,
              { reason, author_id: rows[0].author_id });
  res.json({ ok: true });
});

/** POST /admin/clips/:id/restore — undo a takedown. */
router.post('/clips/:id/restore', requireAdmin, async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  const rows = await query<{ id: string }>(
    `update clips set removed_at = null, removed_by = null, removed_reason = null
      where id = $1 and removed_at is not null
      returning id`,
    [req.params.id]
  );
  if (!rows[0]) return res.status(404).json({ error: 'not found or not removed' });
  await audit(a.adminId, 'clip.restore', 'clip', req.params.id);
  res.json({ ok: true });
});

// ─────────────────────────────────────────────────────────────────────────────────
// DELETE /admin/clips/:id — PERMANENT: the row and every R2 object.
//
// Separate from remove/ for a reason: this one cannot be undone, and the two must never be
// one endpoint with a flag. Reserved for content that genuinely must not persist anywhere.
//
// ADMIN ROLE ONLY (033_admin_roles.sql). Every other action on the clip queue is
// reversible, and a moderator's whole job is performed with those. Handing the one
// irreversible action to everyone who can log in was the pre-role default, not a decision.
// ─────────────────────────────────────────────────────────────────────────────────
router.delete('/clips/:id', requireAdmin, requireRole('admin'), async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  const rows = await query<{ r2_key: string; thumb_r2_key: string; r2_key_sd: string | null; r2_key_hd: string | null; author_id: string }>(
    `select r2_key, thumb_r2_key, r2_key_sd, r2_key_hd, author_id from clips where id = $1 limit 1`,
    [req.params.id]
  );
  const clip = rows[0];
  if (!clip) return res.status(404).json({ error: 'not found' });

  // R2 FIRST. The keys only exist in the row, so deleting the row first would orphan the
  // objects with nothing left to enumerate them by — storage paid for forever.
  for (const key of [clip.r2_key, clip.thumb_r2_key, clip.r2_key_sd, clip.r2_key_hd]) {
    if (key) await deleteObject(key).catch(() => { /* already gone is success */ });
  }
  await query(`delete from clips where id = $1`, [req.params.id]);

  await audit(a.adminId, 'clip.purge', 'clip', req.params.id, { author_id: clip.author_id });
  res.json({ ok: true });
});

// ─────────────────────────────────────────────────────────────────────────────────
// GET /admin/reports?status=open|resolved&cursor=&limit=
//
// The moderation queue for user reports (plan item 3.29). Newest-first and keyset
// paginated, never OFFSET: rows are being resolved underneath the reader, and offset
// pagination on a queue that shrinks SKIPS rows — on a moderation queue that means
// silently never seeing a report.
//
// The target is LEFT JOINed and may be null. 035_reports.sql deliberately puts no foreign
// key on target_id (every FK action destroys the record of why something was removed), so
// a dangling target renders as "deleted" rather than dropping the report.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/reports', requireAdmin, async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 30, 100);
  const cursor = typeof req.query.cursor === 'string' && req.query.cursor ? req.query.cursor : null;
  const resolved = req.query.status === 'resolved';

  const rows = await query<any>(
    `select r.id, r.target_type, r.target_id, r.reason, r.note, r.disclosure,
            r.evidence is not null as has_evidence,
            r.status, r.created_at, r.resolved_at, r.resolution, r.resolution_note,
            reporter.username as reporter_username,
            tu.username        as target_username,
            tu.deleted_at      as target_deleted_at,
            c.caption          as clip_caption,
            c.removed_at       as clip_removed_at,
            a.email            as resolved_by_email,
            (select count(*)::int from content_reports o
              where o.target_type = r.target_type and o.target_id = r.target_id
                and o.status = 'open') as open_against_target
       from content_reports r
       left join users reporter on reporter.id = r.reporter_user_id
       left join users tu       on tu.id = r.target_id and r.target_type <> 'clip'
       left join clips c        on c.id  = r.target_id and r.target_type = 'clip'
       left join admin_users a  on a.id  = r.resolved_by
      where r.status = ${resolved ? "'resolved'" : "'open'"}
        ${cursor ? 'and r.created_at < $2::timestamptz' : ''}
      order by r.created_at desc
      limit $1`,
    cursor ? [limit, cursor] : [limit]
  );

  res.json({
    reports: rows,
    next_cursor: rows.length === limit ? rows[rows.length - 1].created_at : null,
  });
});

// POST /admin/reports/:id/resolve  { resolution, note? }
//
// ONE conditional UPDATE, not select-then-update: two moderators working the queue at once
// would otherwise both "resolve" the same row and the second would overwrite the first's
// verdict. `where status = 'open'` makes the loser's update affect zero rows and say so.
router.post('/reports/:id/resolve', requireAdmin, async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  const resolution = String(req.body?.resolution ?? '');
  const note = String(req.body?.note ?? '').trim() || null;

  if (!['removed', 'no_action', 'duplicate', 'escalated'].includes(resolution)) {
    return res.status(400).json({ error: 'unknown resolution' });
  }

  const rows = await query<{ id: string; target_type: string; target_id: string }>(
    `update content_reports
        set status = 'resolved', resolved_at = now(), resolved_by = $2,
            resolution = $3, resolution_note = $4
      where id = $1 and status = 'open'
      returning id, target_type, target_id`,
    [req.params.id, a.adminId, resolution, note]
  );
  if (!rows[0]) return res.status(409).json({ error: 'already resolved by someone else' });

  await audit(a.adminId, 'report.resolve', 'report', req.params.id, {
    resolution, target_type: rows[0].target_type, target_id: rows[0].target_id,
  });
  res.json({ resolved: true });
});

// ─────────────────────────────────────────────────────────────────────────────────
// GET /admin/audit?action=&target_type=&target_id=&admin_id=&cursor=&limit=
//
// Who did what. The endpoint existed and worked; until now nothing rendered it, so the
// accountability record the panel writes on every action was write-only.
//
// KEYSET ON `id`, NOT OFFSET, for the reason the clips queue already documents: offset
// pagination re-scans and skips rows when the underlying set shifts mid-scroll. Here the
// set only grows at the head, but `id` is a bigserial issued in insertion order, so
// ordering by it is identical to ordering by created_at and gives a cursor that cannot
// tie — two entries written in the same millisecond would make a created_at cursor either
// repeat or skip one of them.
//
// Every filter is optional and every one of them is an equality on an indexed or
// low-cardinality column; there is deliberately no free-text search over `detail`, which
// would be a full scan over jsonb on a table that only grows.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/audit', requireAdmin, async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 50, 200);
  const str = (v: unknown) => (typeof v === 'string' && v.trim() ? v.trim() : null);

  const action = str(req.query.action);
  const targetType = str(req.query.target_type);
  const targetId = str(req.query.target_id);
  const adminId = str(req.query.admin_id);
  const cursor = str(req.query.cursor);

  // Built positionally so an absent filter contributes no parameter at all — simpler to
  // read than a chain of `$n is null or col = $n`, and it keeps the planner honest.
  const where: string[] = [];
  const params: unknown[] = [limit];
  const add = (sql: string, value: unknown) => { params.push(value); where.push(sql.replace('$?', `$${params.length}`)); };

  if (action)     add('l.action = $?', action);
  if (targetType) add('l.target_type = $?', targetType);
  if (targetId)   add('l.target_id = $?', targetId);
  if (adminId)    add('l.admin_id = $?::uuid', adminId);
  if (cursor)     add('l.id < $?::bigint', cursor);

  const rows = await query<{ id: string }>(
    `select l.id, l.admin_id, l.action, l.target_type, l.target_id, l.detail, l.created_at,
            a.email as admin_email, a.name as admin_name
       from admin_audit_log l
       left join admin_users a on a.id = l.admin_id
      ${where.length ? `where ${where.join(' and ')}` : ''}
      order by l.id desc
      limit $1`,
    params
  );

  res.json({
    entries: rows,
    // Null when the page was not full, so the client stops rather than issuing one more
    // request that returns nothing.
    next_cursor: rows.length === limit ? rows[rows.length - 1].id : null,
  });
});

// ═════════════════════════════════════════════════════════════════════════════════
// PEOPLE
//
// Everything below this line concerns a PERSON rather than a piece of public content, and
// is gated accordingly. The line drawn between the two roles is:
//
//   * the users LIST is readable by a moderator, because the author of a reported clip has
//     to be identifiable to be moderated — and every phone number in it is masked, with no
//     endpoint anywhere that unmasks one;
//   * one named person's DEVICES and SECURITY HISTORY, and any action against their
//     account, require the admin role. That is a different kind of access from "who posted
//     this", and a moderation contractor has no reason to hold it.
//
// Nothing here reads content. It cannot: there is no key on this server.
// ═════════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────────
// GET /admin/users?search=&cursor=&limit=&deleted=
//
// SEARCH IS EXACT-ISH BY DESIGN. A phone term must be at least 6 digits and matches by
// suffix; a username matches by prefix; a uuid matches exactly. What it deliberately does
// NOT support is the query that returns everyone whose number starts with a given operator
// prefix, because that is enumeration rather than lookup, and this list is the one place in
// the product where enumeration would be cheap.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/users', requireAdmin, async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 30, 100);
  const cursor = typeof req.query.cursor === 'string' && req.query.cursor ? req.query.cursor : null;
  const deleted = req.query.deleted === 'true';
  const search = typeof req.query.search === 'string' ? req.query.search.trim() : '';

  const where: string[] = [deleted ? 'u.deleted_at is not null' : 'u.deleted_at is null'];
  const params: unknown[] = [limit];
  const add = (sql: string, value: unknown) => { params.push(value); where.push(sql.replace('$?', `$${params.length}`)); };

  if (search) {
    const digits = search.replace(/[^0-9]/g, '');
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(search)) {
      add('u.id = $?::uuid', search);
    } else if ((search.startsWith('+') || /^[0-9\s-]+$/.test(search)) && digits.length >= 6) {
      // Suffix match: numbers are stored E.164 with a country code the person searching
      // may not have typed. Anchored at the END so a partial prefix cannot sweep a range.
      add(`u.phone_number like '%' || $?`, digits);
    } else if (/^[0-9\s+-]+$/.test(search)) {
      // A short numeric term is rejected rather than silently treated as a name search,
      // which would look like "no such user" for a number that exists.
      return res.status(400).json({ error: 'phone search needs at least 6 digits' });
    } else {
      // Prefix, not substring: `%term%` on a name column is a full scan and, worse, lets
      // one query surface everyone whose name contains a common syllable.
      add(`(u.username ilike $? || '%' or u.full_name ilike $? || '%')`, search);
      // The `add` helper substitutes one placeholder; the second reference reuses it.
      where[where.length - 1] = where[where.length - 1].replace(
        /\$\d+ \|\| '%'\)$/, `$${params.length} || '%')`);
    }
  }
  if (cursor) add('u.created_at < $?', cursor);

  const rows = await query<any>(
    `select u.id, u.phone_number, u.username, u.full_name, u.created_at, u.deleted_at,
            u.consent_given_at,
            (select count(*) from clips c where c.author_id = u.id and c.deleted_at is null)::int as clip_count,
            (select count(*) from devices d where d.user_id = u.id and d.revoked_at is null)::int as device_count
       from users u
      where ${where.join(' and ')}
      order by u.created_at desc
      limit $1`,
    params
  );

  res.json({
    // The raw column never leaves this function. Masking in the SELECT would have been
    // tidier, but doing it here means one place to read and no way for a future `select
    // u.*` to route around it.
    users: rows.map(({ phone_number, ...u }) => ({ ...u, phone_masked: maskPhone(phone_number) })),
    next_cursor: rows.length === limit ? rows[rows.length - 1].created_at : null,
  });
});

// ─────────────────────────────────────────────────────────────────────────────────
// GET /admin/users/:id — one person: devices, recent security events, consent, requests.
//
// ADMIN ROLE ONLY, and AUDITED AS A READ. Almost everything else in this router audits
// mutations only, which is the usual rule; this is the deliberate exception. Reading one
// named individual's device list and security history is the kind of access that gets
// misused quietly, and "nobody can tell who looked" is the property that makes it possible.
// One row per view is cheap.
//
// NO last_seen_at. The column exists on `devices` and is never written — grepping the
// backend finds three reads and zero writes — so surfacing it would render a permanently
// empty field that reads as "this device has never been used". Displaying a value we do not
// maintain is worse than omitting it. Writing it on every authenticated request is the fix,
// and it belongs in the auth path, not here.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/users/:id', requireAdmin, requireRole('admin'), async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  const id = req.params.id;

  const users = await query<any>(
    `select id, phone_number, username, full_name, email, bio, status_text,
            consent_given_at, created_at, updated_at, deleted_at
       from users where id = $1 limit 1`,
    [id]
  );
  const user = users[0];
  if (!user) return res.status(404).json({ error: 'not found' });

  const [devices, events, consents, requests] = await Promise.all([
    query(
      `select id, device_name, platform, registration_id, push_provider,
              os_version, app_version, created_at, revoked_at
         from devices where user_id = $1 order by created_at desc`,
      [id]
    ),
    // Bounded window AND bounded count: security_events is swept at 90 days
    // (030_dpdp.sql), so an unbounded query here would still be small — but "still small"
    // is a property of the retention worker running, and this endpoint should not depend
    // on that. `metadata` is included: unlike the user-facing export, an operator
    // investigating an incident is exactly who it is for.
    query(
      `select id, event_type, ip_address, metadata, created_at
         from security_events
        where user_id = $1 and created_at > now() - interval '90 days'
        order by created_at desc limit 100`,
      [id]
    ),
    query(
      `select notice_version, language, purposes, given_at, given_via, withdrawn_at, withdrawn_via
         from consent_records where user_id = $1 order by given_at desc`,
      [id]
    ),
    query(
      `select id, kind, status, opened_at, due_at, closed_at, resolution
         from dpdp_requests where user_id = $1 order by opened_at desc`,
      [id]
    ),
  ]);

  await audit(a.adminId, 'user.view', 'user', id);

  const { phone_number, ...rest } = user;
  res.json({
    user: { ...rest, phone_masked: maskPhone(phone_number) },
    devices,
    security_events: events,
    consent_records: consents,
    dpdp_requests: requests,
  });
});

// ─────────────────────────────────────────────────────────────────────────────────
// POST /admin/users/:id/revoke-devices  { reason }
//
// Revokes every device on the account: no device can be sent to, and no prekey bundle is
// returned for one, so inbound sessions stop.
//
// WHAT THIS DOES NOT DO, stated here and repeated in the panel because an operator who
// believes otherwise will make a bad call in an incident: it does NOT end the user's API
// access. A Voiid user session is a stateless JWT valid for up to 30 days, and
// `POST /auth/logout` is a no-op — the same non-revocability the ADMIN plane explicitly
// rejected for itself (see the header of this file). Until user sessions are revocable
// server-side (repair plan Fix 9 / docs/research/11_admin_dpdp.md §2.7), this button
// removes the account's ability to RECEIVE, not its ability to act.
//
// A reason is required. "Why was this account cut off" is the question that arrives later,
// and an audit entry that cannot answer it is decoration.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/users/:id/revoke-devices', requireAdmin, requireRole('admin'), async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  const reason = String(req.body?.reason ?? '').trim();
  if (!reason) return res.status(400).json({ error: 'a reason is required' });

  const exists = await query<{ id: string }>(`select id from users where id = $1 limit 1`, [req.params.id]);
  if (!exists[0]) return res.status(404).json({ error: 'not found' });

  // `revoked_at is null` in the predicate keeps this idempotent and keeps the original
  // revocation timestamp: re-running it must not move the moment a device was cut off.
  const revoked = await query<{ id: string }>(
    `update devices set revoked_at = now()
      where user_id = $1 and revoked_at is null
      returning id`,
    [req.params.id]
  );

  await audit(a.adminId, 'user.revoke_devices', 'user', req.params.id,
              { reason, devices_revoked: revoked.length });
  res.json({
    ok: true,
    devices_revoked: revoked.length,
    note: 'Inbound sessions stopped. The user\'s existing API token remains valid until it expires — user sessions are not yet revocable server-side.',
  });
});

// ═════════════════════════════════════════════════════════════════════════════════
// THE DATA-PRINCIPAL REQUEST CONSOLE (repair plan 3.27; 034_dpdp_requests.sql)
//
// ADMIN ROLE ONLY, all of it. Working this queue means reading what somebody asked us
// about their own data and, for an erasure, starting something irreversible.
//
// The console holds no content and cannot produce any. What a rights request against an
// end-to-end-encrypted product can be answered with is metadata, and the export that
// answers it is assembled in routes/dpdp.ts from an allow-list that is checked at boot.
//
// [COUNSEL] The response periods on these rows are engineering placeholders written by
// routes/dpdp.ts from a named constant, and nothing in this console asserts that any of
// them is the legally required one. See docs/research/11_admin_dpdp.md §6.
// ═════════════════════════════════════════════════════════════════════════════════

/**
 * Which statuses a request may move to from which.
 *
 * A TABLE, not a chain of ifs, because the interesting property is what is ABSENT: there is
 * no transition out of `done` or `rejected`. A closed request stays closed — reopening one
 * would silently restart an SLA clock that has already been reported as met, and the honest
 * way to revisit a decision is a new request that says so.
 */
const DPDP_TRANSITIONS: Record<string, string[]> = {
  verifying:   ['open'],
  in_progress: ['open', 'verifying'],
  done:        ['open', 'verifying', 'in_progress'],
  rejected:    ['open', 'verifying', 'in_progress'],
};

const DPDP_TERMINAL = new Set(['done', 'rejected']);

// ─────────────────────────────────────────────────────────────────────────────────
// GET /admin/dpdp?status=open|closed|all&kind=&cursor=&limit=
//
// The queue. Open requests are ordered by DUE DATE ascending — the oldest deadline first,
// not the newest request — because the only way this queue fails is by something reaching
// its period while sitting behind newer work. Closed requests order by closure, newest
// first, which is how anyone reads a history.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/dpdp', requireAdmin, requireRole('admin'), async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 50, 200);
  const status = req.query.status === 'closed' ? 'closed' : req.query.status === 'all' ? 'all' : 'open';
  const kind = typeof req.query.kind === 'string' && req.query.kind ? req.query.kind : null;
  const cursor = typeof req.query.cursor === 'string' && req.query.cursor ? req.query.cursor : null;

  const where: string[] = [];
  const params: unknown[] = [limit];
  const add = (sql: string, value: unknown) => { params.push(value); where.push(sql.replace('$?', `$${params.length}`)); };

  if (status === 'open')   where.push('r.closed_at is null');
  if (status === 'closed') where.push('r.closed_at is not null');
  if (kind) add('r.kind = $?', kind);
  if (cursor) add(status === 'open' ? 'r.due_at > $?' : 'r.closed_at < $?', cursor);

  const rows = await query<any>(
    `select r.id, r.user_id, r.kind, r.status, r.subject_note, r.opened_at, r.due_at,
            r.closed_at, r.resolution, r.notes, r.redacted_at,
            (r.closed_at is null and r.due_at < now()) as overdue,
            u.username, u.phone_number, u.deleted_at as subject_deleted_at,
            h.email as handled_by_email
       from dpdp_requests r
       left join users u on u.id = r.user_id
       left join admin_users h on h.id = r.handled_by
      ${where.length ? `where ${where.join(' and ')}` : ''}
      order by ${status === 'open' ? 'r.due_at asc' : 'r.closed_at desc nulls last'}
      limit $1`,
    params
  );

  res.json({
    requests: rows.map(({ phone_number, ...r }) => ({ ...r, phone_masked: maskPhone(phone_number) })),
    next_cursor: rows.length === limit
      ? (status === 'open' ? rows[rows.length - 1].due_at : rows[rows.length - 1].closed_at)
      : null,
  });
});

// ─────────────────────────────────────────────────────────────────────────────────
// POST /admin/dpdp/:id/status  { status, resolution?, notes? }
//
// ONE CONDITIONAL UPDATE, not select-then-update. Two operators working the queue at once
// would otherwise both read `in_progress` and both write a closure, and the second would
// overwrite the first's resolution and move `closed_at` forward — falsifying the one
// timestamp the row exists to record. The allowed source statuses go into the predicate, so
// a losing writer matches no row and is told so.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/dpdp/:id/status', requireAdmin, requireRole('admin'), async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  const status = String(req.body?.status ?? '');
  const from = DPDP_TRANSITIONS[status];
  if (!from) {
    return res.status(400).json({
      error: `status must be one of: ${Object.keys(DPDP_TRANSITIONS).join(', ')} ` +
             `(a closed request cannot be reopened — open a new one)`,
    });
  }

  const terminal = DPDP_TERMINAL.has(status);
  const resolution = String(req.body?.resolution ?? '').trim() || null;
  const notes = typeof req.body?.notes === 'string' ? req.body.notes.trim().slice(0, 4000) || null : null;

  // Enforced here as well as by dpdp_closed_needs_resolution, so the operator gets "say
  // what you did" rather than a constraint-violation 500.
  if (terminal && !resolution) {
    return res.status(400).json({ error: 'closing a request requires a resolution' });
  }

  const rows = await query<any>(
    `update dpdp_requests
        set status      = $2,
            handled_by  = $3,
            closed_at   = case when $4::boolean then now() else null end,
            resolution  = coalesce($5, resolution),
            notes       = coalesce($6, notes)
      where id = $1
        and status = any($7::text[])
      returning id, kind, status, opened_at, due_at, closed_at, resolution`,
    [req.params.id, status, a.adminId, terminal, resolution, notes, from]
  );
  if (!rows[0]) {
    return res.status(409).json({
      error: 'request not found, already closed, or not in a status this transition allows',
    });
  }

  await audit(a.adminId, 'dpdp.status', 'dpdp_request', req.params.id,
              { to: status, from_allowed: from, kind: rows[0].kind });
  res.json({ request: rows[0] });
});

// ─────────────────────────────────────────────────────────────────────────────────
// POST /admin/dpdp/:id/start-erasure  { confirm: true }
//
// The one irreversible thing in the console. It does exactly what `DELETE /users/me` does
// — soft-delete the row, null the profile text, revoke every device, drop the cached
// account-state verdict — after which backend/workers/src/erasure.ts owns the actual purge
// once the grace period elapses.
//
// SCOPED THROUGH THE REQUEST ROW, DELIBERATELY. There is no "delete this account" endpoint
// keyed on a user id. The only way to reach this code is a dpdp_requests row of kind
// `erasure` that is open and belongs to an identified principal — so an admin cannot erase
// an account without a recorded request to point at, and widening it later would mean
// visibly removing that constraint rather than adding a parameter.
//
// [COUNSEL] docs/research/11_admin_dpdp.md §2.10 asks whether a re-login inside the grace
// window CANCELS an erasure request or whether the account is already gone. This endpoint
// does not answer it: it sets the same flag the self-service path sets, and the worker
// implements "already gone" by re-checking deleted_at inside its transaction. If counsel
// chooses reinstatement, the change is a deliberate audited un-delete elsewhere, not a
// behaviour change here.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/dpdp/:id/start-erasure', requireAdmin, requireRole('admin'), async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  // A typed confirmation, because a misclick here is not recoverable.
  if (req.body?.confirm !== true) {
    return res.status(400).json({ error: 'confirm must be true' });
  }

  const client = await pool.connect();
  try {
    await client.query('begin');

    // FOR UPDATE on the request row: two admins hitting this at once must not both run the
    // deletion, and the row lock is what serialises them. The kind/status predicate is what
    // makes the endpoint unable to erase anything that is not a live erasure request.
    const reqRows = await client.query<{ id: string; user_id: string | null; status: string }>(
      `select id, user_id, status from dpdp_requests
        where id = $1 and kind = 'erasure' and closed_at is null
        for update`,
      [req.params.id]
    );
    const request = reqRows.rows[0];
    if (!request) {
      await client.query('rollback');
      return res.status(404).json({ error: 'no open erasure request with that id' });
    }
    if (!request.user_id) {
      await client.query('rollback');
      // The subject is already erased — the FK nulled the link (034_dpdp_requests.sql).
      return res.status(409).json({ error: 'this request no longer has a subject; it was already erased' });
    }

    // The same statements as DELETE /users/me, in the same order, because divergence
    // between two paths that both mean "delete this account" is how one of them ends up
    // leaving something behind.
    const deleted = await client.query<{ id: string }>(
      `update users
          set deleted_at = now(), full_name = null, email = null,
              photo_url = null, bio = null, status_text = null
        where id = $1 and deleted_at is null
        returning id`,
      [request.user_id]
    );
    await client.query(
      `update devices set revoked_at = now() where user_id = $1 and revoked_at is null`,
      [request.user_id]
    );
    await client.query(
      `update dpdp_requests set status = 'in_progress', handled_by = $2 where id = $1`,
      [request.id, a.adminId]
    );

    await client.query('commit');

    // AFTER the commit. Dropping the cached "is this account live" verdict before the
    // transaction lands would let a request in the gap re-populate the cache with the old
    // answer, which is the one thing the invalidation exists to prevent.
    await invalidateAccountState(request.user_id);

    await audit(a.adminId, 'dpdp.start_erasure', 'user', request.user_id,
                { request_id: request.id, already_deleted: deleted.rowCount === 0 });

    res.json({
      ok: true,
      // Honest about the case where the user had already deleted themselves: the request is
      // still progressed, but nothing new happened to the account.
      already_deleted: deleted.rowCount === 0,
      note: 'Account soft-deleted. The erasure worker purges it after the grace period; close ' +
            'this request with a resolution once it has.',
    });
  } catch (err) {
    await client.query('rollback').catch(() => { /* the connection is going back to the pool either way */ });
    throw err;
  } finally {
    client.release();
  }
});

// ─────────────────────────────────────────────────────────────────────────────────
// POST /admin/users/:id/reveal-phone   { reason }
//
// The ONE way to read a full phone number, and it is deliberately shaped so that reading
// one is an ACT rather than a side effect of looking at a list.
//
// Every list on this router stays masked. That is the whole control: a stolen or careless
// admin session can still confirm a number somebody already holds (via the users search),
// but harvesting numbers it does not have costs one attributable, logged request each. Bulk
// export stops being a scroll and becomes a thousand audit rows with a name on them.
//
// POST, not GET, for the same reason: a GET is prefetched, cached, logged in proxies, and
// sits in browser history. Reading personal data should not be something a browser can do
// on its own initiative.
//
// admin-role only, and a reason is required — "why did you look at this person's number"
// is the question a DPDP audit asks, and an entry that cannot answer it is decoration.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/users/:id/reveal-phone', requireAdmin, requireRole('admin'), async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  const reason = String(req.body?.reason ?? '').trim();
  if (!reason) return res.status(400).json({ error: 'a reason is required' });

  const rows = await query<{ phone_number: string | null; username: string | null }>(
    `select phone_number, username from users where id = $1 limit 1`,
    [req.params.id],
  );
  if (!rows[0]) return res.status(404).json({ error: 'not found' });

  // Audited BEFORE the number is returned. If the write fails the read still proceeds —
  // audit() swallows its own errors by design — but the ordering means there is no path
  // where a number reaches a screen earlier than the record of it being asked for.
  await audit(a.adminId, 'user.phone_revealed', 'user', req.params.id,
              { reason, username: rows[0].username });

  res.json({ phone: rows[0].phone_number });
});

// ═════════════════════════════════════════════════════════════════════════════════
// COMMUNITIES
//
// The platform-wide view. Every existing /communities route is scoped to a caller's own
// membership — correct for the app, useless for an operator, who needs to see the
// communities they are NOT in, which is where the problems are.
//
// `communities.suspended_at` has existed since the table did and nothing has ever written
// to it. The container-level takedown below is the first thing that can.
//
// WHAT THIS DELIBERATELY CANNOT DO: read messages. Community chat is E2EE and the server
// holds no key; the counts here come from `community_posts`, the non-E2EE feed. An admin
// plane that could read conversations would make the encryption a claim rather than a fact.
// ═════════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────────
// GET /admin/communities?cursor=&limit=&q=&state=
//
// Keyset-paginated on created_at for the same reason the clips queue is: OFFSET skips rows
// when the set shifts under a scroll, and a moderation list that silently omits an entry is
// worse than one that pages slowly.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/communities', requireAdmin, async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 30, 100);
  const cursor = typeof req.query.cursor === 'string' ? req.query.cursor : null;
  const q = typeof req.query.q === 'string' ? req.query.q.trim() : '';
  const state = req.query.state === 'suspended' ? 'suspended'
              : req.query.state === 'active' ? 'active' : 'all';

  const where: string[] = [];
  const params: unknown[] = [];

  if (cursor) { params.push(cursor); where.push(`c.created_at < $${params.length}`); }
  if (state === 'suspended') where.push('c.suspended_at is not null');
  if (state === 'active') where.push('c.suspended_at is null');
  if (q) {
    // Name OR handle: an operator chasing a report has one or the other, rarely both.
    params.push(`%${q.toLowerCase()}%`);
    where.push(`(lower(c.name) like $${params.length} or lower(c.handle) like $${params.length})`);
  }
  params.push(limit);

  const rows = await query<any>(
    `select c.id, c.handle, c.name, c.description, c.category,
            c.discoverable, c.join_policy, c.member_count, c.max_members,
            c.suspended_at, c.created_at, c.owner_id,
            u.full_name as owner_name, u.username as owner_username,
            (select count(*) from community_posts p where p.community_id = c.id)::int as post_count
       from communities c
       left join users u on u.id = c.owner_id
       ${where.length ? `where ${where.join(' and ')}` : ''}
      order by c.created_at desc
      limit $${params.length}`,
    params
  );

  res.json({
    communities: rows,
    // Null rather than a repeated cursor when the page is short: a client that keys "more"
    // on presence cannot then loop forever on the last page.
    next_cursor: rows.length === limit ? rows[rows.length - 1].created_at : null,
  });
});

// ─────────────────────────────────────────────────────────────────────────────────
// GET /admin/communities/:id — one community, with its roster split by state.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/communities/:id', requireAdmin, async (req, res) => {
  const id = String(req.params.id);
  if (!/^[0-9a-f-]{36}$/i.test(id)) {
    return res.status(400).json({ error: 'community id must be a uuid' });
  }

  const rows = await query<any>(
    `select c.id, c.handle, c.name, c.description, c.category,
            c.discoverable, c.join_policy, c.member_count, c.max_members,
            c.suspended_at, c.created_at, c.owner_id, c.members_can_invite,
            u.full_name as owner_name, u.username as owner_username
       from communities c
       left join users u on u.id = c.owner_id
      where c.id = $1`,
    [id]
  );
  const community = rows[0];
  if (!community) return res.status(404).json({ error: 'not found' });

  // Counts by state in ONE pass rather than four queries, and the post total alongside, so
  // the detail header cannot show numbers that disagree with each other.
  const counts = await query<Record<string, number>>(
    `select
       count(*) filter (where state = 'active')::int  as active,
       count(*) filter (where state = 'pending')::int as pending,
       count(*) filter (where state = 'banned')::int  as banned,
       count(*) filter (where state = 'left')::int    as left_,
       count(*) filter (where role in ('owner','admin') and state = 'active')::int as managers
     from community_members where community_id = $1`,
    [id]
  );

  const members = await query<any>(
    `select m.user_id, m.role, m.state, m.joined_at,
            u.full_name, u.username
       from community_members m
       left join users u on u.id = m.user_id
      where m.community_id = $1 and m.state <> 'left'
      order by case m.role when 'owner' then 0 when 'admin' then 1 else 2 end,
               m.joined_at asc
      limit 200`,
    [id]
  );

  const posts = await query<any>(
    `select count(*)::int as total,
            count(*) filter (where created_at > now() - interval '7 days')::int as last_7d
       from community_posts where community_id = $1`,
    [id]
  );

  res.json({
    community,
    counts: counts[0] ?? {},
    posts: posts[0] ?? { total: 0, last_7d: 0 },
    members,
    // Said plainly so nobody reads the roster cap as the roster.
    members_truncated: members.length === 200,
  });
});

// ─────────────────────────────────────────────────────────────────────────────────
// POST /admin/communities/:id/suspend   { reason }
//
// Container-level takedown, admin-role only — the same bar as deleting a clip, because it
// takes down everyone's content at once rather than one person's.
//
// Suspend is REVERSIBLE and destroys nothing. It is deliberately not a delete: an operator
// acting on a report needs to stop the harm now and be able to be wrong later.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/communities/:id/suspend', requireAdmin, requireRole('admin'), async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  const id = String(req.params.id);
  const reason = String(req.body?.reason ?? '').trim();
  if (!/^[0-9a-f-]{36}$/i.test(id)) {
    return res.status(400).json({ error: 'community id must be a uuid' });
  }
  // A takedown with no stated reason is one nobody can review later, and the audit row is
  // the only account of why this happened.
  if (!reason) return res.status(400).json({ error: 'a reason is required' });

  const r = await query<any>(
    `update communities set suspended_at = now()
      where id = $1 and suspended_at is null
      returning id, name, handle`,
    [id]
  );
  if (!r[0]) {
    // Distinguishes "no such community" from "already suspended" only in the message: both
    // leave the operator with the same next step, and neither is a failure worth a 500.
    return res.status(409).json({ error: 'not found, or already suspended' });
  }

  await audit(a.adminId, 'community.suspend', 'community', id,
              { reason, name: r[0].name, handle: r[0].handle });
  res.json({ ok: true, community: r[0] });
});

// ─────────────────────────────────────────────────────────────────────────────────
// POST /admin/communities/:id/restore   { reason }
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/communities/:id/restore', requireAdmin, requireRole('admin'), async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  const id = String(req.params.id);
  const reason = String(req.body?.reason ?? '').trim();
  if (!/^[0-9a-f-]{36}$/i.test(id)) {
    return res.status(400).json({ error: 'community id must be a uuid' });
  }

  const r = await query<any>(
    `update communities set suspended_at = null
      where id = $1 and suspended_at is not null
      returning id, name, handle`,
    [id]
  );
  if (!r[0]) return res.status(409).json({ error: 'not found, or not suspended' });

  // Reinstatement is audited as loudly as the takedown. A reversal nobody can see is how a
  // moderation log stops being a record of what actually happened.
  await audit(a.adminId, 'community.restore', 'community', id,
              { reason: reason || null, name: r[0].name, handle: r[0].handle });
  res.json({ ok: true, community: r[0] });
});

// ─────────────────────────────────────────────────────────────────────────────────
// GET  /admin/communities/:id/entitlements
// POST /admin/communities/:id/entitlements          { capability, note, expires_at? }
// POST /admin/communities/:id/entitlements/:cap/revoke  { note }
//
// Paid capabilities, switched on per community on request. Creating and running a community
// is free; this is only for what we sell separately, e-commerce first.
//
// admin-role only, and a note is REQUIRED on both grant and revoke — "why does this community
// have e-commerce" is the question a dispute asks, and a grant nobody can explain later is a
// grant nobody can defend.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/communities/:id/entitlements', requireAdmin, async (req, res) => {
  const id = String(req.params.id);
  if (!/^[0-9a-f-]{36}$/i.test(id)) {
    return res.status(400).json({ error: 'community id must be a uuid' });
  }

  // History included, not just live rows: the revoked and expired grants ARE the record this
  // table exists to keep, and an operator answering "did they ever have this" needs them.
  const rows = await query<any>(
    `select e.id, e.capability, e.granted_at, e.expires_at, e.revoked_at, e.note,
            (e.revoked_at is null and (e.expires_at is null or e.expires_at > now())) as live,
            a.email as granted_by_email
       from community_entitlements e
       left join admin_users a on a.id = e.granted_by
      where e.community_id = $1
      order by e.granted_at desc`,
    [id],
  );

  res.json({ entitlements: rows, available: CAPABILITIES });
});

router.post('/communities/:id/entitlements', requireAdmin, requireRole('admin'), async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  const id = String(req.params.id);
  const capability = String(req.body?.capability ?? '');
  const note = String(req.body?.note ?? '').trim();
  const expiresAt = req.body?.expires_at ? String(req.body.expires_at) : null;

  if (!/^[0-9a-f-]{36}$/i.test(id)) {
    return res.status(400).json({ error: 'community id must be a uuid' });
  }
  // Checked against the server's own list rather than trusted from the body: the column is
  // free text, so an unrecognised name would otherwise be stored and then grant nothing —
  // an entitlement that looks live in the panel and fails at the call site.
  if (!isCapability(capability)) {
    return res.status(400).json({ error: 'unknown capability', available: CAPABILITIES });
  }
  if (!note) return res.status(400).json({ error: 'a note is required' });

  const exists = await query<{ id: string }>(
    `select id from communities where id = $1`, [id]);
  if (!exists[0]) return res.status(404).json({ error: 'no such community' });

  try {
    const r = await query<any>(
      `insert into community_entitlements
         (community_id, capability, note, granted_by, expires_at)
       values ($1, $2, $3, $4, $5)
       returning id, capability, granted_at, expires_at, note`,
      [id, capability, note, a.adminId, expiresAt],
    );
    await audit(a.adminId, 'community.entitlement_granted', 'community', id,
                { capability, note, expires_at: expiresAt });
    res.json({ ok: true, entitlement: r[0] });
  } catch (err: any) {
    // The partial unique index means one LIVE grant per capability. A duplicate is not an
    // error worth a 500 — it means the thing the caller wanted is already true.
    if (err?.code === '23505') {
      return res.status(409).json({ error: 'this community already has that capability' });
    }
    throw err;
  }
});

router.post('/communities/:id/entitlements/:cap/revoke',
            requireAdmin, requireRole('admin'), async (req, res) => {
  const a = (req as any).admin as AdminAuth;
  const id = String(req.params.id);
  const capability = String(req.params.cap);
  const note = String(req.body?.note ?? '').trim();

  if (!/^[0-9a-f-]{36}$/i.test(id)) {
    return res.status(400).json({ error: 'community id must be a uuid' });
  }
  if (!note) return res.status(400).json({ error: 'a reason is required' });

  // The row is kept and stamped, never deleted — see the migration header. Appending the
  // revocation reason to the original note keeps both halves of the story on one row.
  const r = await query<any>(
    `update community_entitlements
        set revoked_at = now(),
            note = note || E'\n\nRevoked: ' || $3
      where community_id = $1 and capability = $2 and revoked_at is null
      returning id, capability`,
    [id, capability, note],
  );
  if (!r[0]) return res.status(409).json({ error: 'not granted, or already revoked' });

  await audit(a.adminId, 'community.entitlement_revoked', 'community', id,
              { capability, note });
  res.json({ ok: true });
});

// ─────────────────────────────────────────────────────────────────────────────────
// GET /admin/communities/:id/posts?cursor=&limit=
//
// The feed as an operator sees it. Non-E2EE by design — this is the public wall, not chat.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/communities/:id/posts', requireAdmin, async (req, res) => {
  const id = String(req.params.id);
  const limit = Math.min(Number(req.query.limit) || 30, 100);
  const cursor = typeof req.query.cursor === 'string' ? req.query.cursor : null;
  if (!/^[0-9a-f-]{36}$/i.test(id)) {
    return res.status(400).json({ error: 'community id must be a uuid' });
  }

  const params: unknown[] = [id];
  let cursorClause = '';
  if (cursor) { params.push(cursor); cursorClause = `and p.created_at < $${params.length}`; }
  params.push(limit);

  const rows = await query<any>(
    `select p.id, p.author_id, p.body, p.media_url, p.like_count, p.comment_count,
            p.created_at, p.edited_at,
            u.full_name as author_name, u.username as author_username
       from community_posts p
       left join users u on u.id = p.author_id
      where p.community_id = $1 ${cursorClause}
      order by p.created_at desc
      limit $${params.length}`,
    params
  );

  res.json({
    posts: rows,
    next_cursor: rows.length === limit ? rows[rows.length - 1].created_at : null,
  });
});

export default router;
export { requireAdmin, requireRole };
