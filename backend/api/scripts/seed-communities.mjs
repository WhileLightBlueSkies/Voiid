#!/usr/bin/env node
//
// seed-communities.mjs — demo communities, so the Communities UI can be judged with
// something in it.
//
// A design reads differently at one row than at six. The community card carries a HOST
// badge, a join policy, an avatar fallback and a member count, and with a single community
// on the account none of that is visible — the screen looks empty and the layout cannot be
// assessed. This seeds a spread that exercises every state the card and the community page
// can render:
//
//   open / approval / invite_only     the globe-vs-lock and the join button's three verbs
//   hosted by you / by someone else   the HOST badge and the accent border
//   discoverable / not               whether search finds it
//   member counts from 64 to 1284    the count's formatting at each width
//
// DEMO DATA, NOT FIXTURES. These rows are indistinguishable from real ones to the rest of
// the app: the API does not know they are seeded and nothing filters them out. That is the
// point — the UI has to look right against real rows — but it also means this must never
// run against production. Every handle is prefixed in `HANDLES` below so `--remove` can
// find them again, and removal is by handle rather than by "everything", so a real
// community created alongside them survives.
//
// DRY RUN BY DEFAULT, like wipe-clips.mjs. It prints what it would write and exits.
//
//   node scripts/seed-communities.mjs              # prints the plan, writes nothing
//   node scripts/seed-communities.mjs --confirm    # writes the rows
//   node scripts/seed-communities.mjs --remove     # deletes them again (also needs --confirm)
//
// The owner is whoever the --owner flag names, or the first user in the table. Two of the
// six are owned by ANOTHER user where one exists, because a list where you host everything
// never shows the non-host card state.
//
import pg from 'pg';
import { randomUUID } from 'node:crypto';

const CONFIRM = process.argv.includes('--confirm');
const REMOVE = process.argv.includes('--remove');
const ownerFlag = process.argv.find((a) => a.startsWith('--owner='))?.split('=')[1];

// Every seeded handle, so --remove can find exactly these and nothing else.
const HANDLES = ['designdaily', 'swiftindia', 'nightowls', 'foundersroom', 'filmclub'];

const DEMO = [
  { handle: 'designdaily', name: 'Design Daily', mine: true,
    description: 'Daily critique, type nerdery and the occasional shipping war story. Post work, get honest feedback.',
    join_policy: 'open', discoverable: true, member_count: 1284 },
  { handle: 'swiftindia', name: 'Swift India', mine: false,
    description: 'iOS and Swift developers across India. Meetups, job posts, and help with whatever is on fire today.',
    join_policy: 'approval', discoverable: true, member_count: 842 },
  { handle: 'nightowls', name: 'Night Owls', mine: true,
    description: 'For people who ship at 2am. No standups, no roadmaps, just what you built last night.',
    join_policy: 'open', discoverable: true, member_count: 317 },
  { handle: 'foundersroom', name: 'Founders Room', mine: false,
    description: 'Private room for early-stage founders. Revenue numbers, hard calls, and the things you cannot post publicly.',
    join_policy: 'invite_only', discoverable: false, member_count: 64 },
  { handle: 'filmclub', name: 'The Film Club', mine: false,
    description: 'One film a week, one long argument about it. Currently working through 70s thrillers.',
    join_policy: 'open', discoverable: true, member_count: 456 },
];

const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });

async function main() {
  if (!process.env.DATABASE_URL) {
    console.error('DATABASE_URL is not set. Run with --env-file=.env from /opt/voiid.');
    process.exit(1);
  }

  if (REMOVE) {
    const { rows } = await pool.query(
      `select handle, name from communities where handle = any($1::text[])`, [HANDLES]);
    if (!rows.length) { console.log('Nothing to remove.'); return; }
    console.log(`${CONFIRM ? 'Removing' : 'Would remove'} ${rows.length}:`);
    rows.forEach((r) => console.log(`  - @${r.handle}  ${r.name}`));
    if (!CONFIRM) { console.log('\nDry run. Pass --confirm to delete.'); return; }
    // Members and host threads cascade from the community row (030).
    await pool.query(`delete from communities where handle = any($1::text[])`, [HANDLES]);
    console.log('Removed.');
    return;
  }

  const owner = ownerFlag
    ?? (await pool.query(`select id from users order by created_at limit 1`)).rows[0]?.id;
  if (!owner) { console.error('No users in the database — nothing can own a community.'); process.exit(1); }

  // A second owner so the list is not all HOST badges. Falls back to the first if the
  // database only has one account, which is honest: a solo database cannot show that state.
  const other = (await pool.query(
    `select id from users where id <> $1 order by created_at limit 1`, [owner])).rows[0]?.id ?? owner;

  console.log(`Owner (you):   ${owner}`);
  console.log(`Second owner:  ${other}${other === owner ? '  (same — only one user exists)' : ''}\n`);

  for (const c of DEMO) {
    const ownerId = c.mine ? owner : other;
    const tag = c.mine ? 'you host' : 'someone else hosts';
    console.log(`${CONFIRM ? 'writing' : 'would write'}  @${c.handle.padEnd(13)} ${String(c.member_count).padStart(5)} members  ${c.join_policy.padEnd(11)} ${tag}`);
    if (!CONFIRM) continue;

    // The unique index is on lower(handle) — an EXPRESSION index, which `on conflict
    // (handle)` cannot use as an arbiter. And `id` is client-supplied (no default), like
    // clips. So: look it up, then insert or update explicitly.
    const existing = await pool.query(
      `select id from communities where lower(handle) = lower($1)`, [c.handle]);

    let id;
    if (existing.rows.length) {
      id = existing.rows[0].id;
      await pool.query(
        `update communities
            set owner_id = $2, name = $3, description = $4, join_policy = $5,
                discoverable = $6, member_count = $7, updated_at = now()
          where id = $1`,
        [id, ownerId, c.name, c.description, c.join_policy, c.discoverable, c.member_count]);
    } else {
      id = randomUUID();
      await pool.query(
        `insert into communities (id, owner_id, handle, name, description,
                                  join_policy, discoverable, member_count)
              values ($1, $2, $3, $4, $5, $6, $7, $8)`,
        [id, ownerId, c.handle, c.name, c.description,
         c.join_policy, c.discoverable, c.member_count]);
    }
    const rows = [{ id }];

    // The owner has to be on the roster: resolveHostTarget checks community_members, so a
    // community whose owner is not a member cannot be messaged even by its own host.
    await pool.query(
      `insert into community_members (community_id, user_id, role, state)
            values ($1, $2, 'owner', 'active')
       on conflict (community_id, user_id) do nothing`,
      [rows[0].id, ownerId]);

    // Join the OTHER user's communities as a member, so the "Joined" pill and the
    // member-facing "Message host" bar both have something to render.
    if (!c.mine && owner !== other) {
      await pool.query(
        `insert into community_members (community_id, user_id, role, state)
              values ($1, $2, 'member', 'active')
         on conflict (community_id, user_id) do nothing`,
        [rows[0].id, owner]);
    }
  }

  if (!CONFIRM) console.log('\nDry run. Pass --confirm to write these rows.');
  else console.log('\nSeeded. Pull to refresh in the app.');
}

main().then(() => process.exit(0)).catch((e) => { console.error(e.message); process.exit(1); });
