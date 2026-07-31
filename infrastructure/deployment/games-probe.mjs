// TEMPORARY DIAGNOSTIC — why do the games endpoints 500?
//
// POST /games/matches, GET /games/invites and GET /games/leaderboard all return 500, and every
// indirect attempt to see the cause came back useless: the API's global error handler flattens
// every 5xx to {"error":"internal error"}, the box is not SSH-reachable from the machine doing the
// debugging, and an inline `node -e` in the deploy script had its quotes eaten by the shell — which
// produced fake errors ("column \"waiting\" does not exist") that looked exactly like real ones and
// cost several deploy cycles.
//
// Hence a FILE. Quotes in a file are not touched by any shell, so what Postgres sees is what is
// written here. Run from deploy-dev.sh with the box's .env; delete once the games 500 is fixed.
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { Client } = require('pg');

const url = process.env.DATABASE_URL ?? '';
if (!url) {
  console.log('[probe] DATABASE_URL is not set');
  process.exit(0);
}

const isLocal = /@(localhost|127\.0\.0\.1)/.test(url);
const client = new Client({
  connectionString: url,
  ssl: isLocal ? undefined : { rejectUnauthorized: false },
});

async function show(label, sql, params) {
  try {
    const r = await client.query(sql, params);
    console.log(`[probe] ${label} OK rows=${r.rows.length}`,
      JSON.stringify(r.rows[0] ?? null).slice(0, 300));
  } catch (e) {
    console.log(`[probe] ${label} FAILED code=${e.code} msg=${e.message}`);
  }
}

try {
  await client.connect();

  await show('game_matches columns:',
    `select string_agg(column_name, ', ' order by ordinal_position) as cols
       from information_schema.columns where table_name = 'game_matches'`);

  await show('games columns:',
    `select string_agg(column_name, ', ' order by ordinal_position) as cols
       from information_schema.columns where table_name = 'games'`);

  await show('users has username:',
    `select count(*)::int as n from information_schema.columns
       where table_name = 'users' and column_name = 'username'`);

  const users = await client.query('select id from users limit 1');
  const uid = users.rows[0]?.id;
  console.log('[probe] sample user:', uid ?? '(none)');

  // The exact statement POST /games/matches runs. If this fails, that 500 is explained.
  await show('insert match (the failing one):',
    `insert into game_matches (game_id, player_ids, created_by, status, options)
     values ((select id from games where enabled = true limit 1), $1::jsonb, $2, 'waiting', $3::jsonb)
     returning id`,
    [JSON.stringify([uid]), uid, '{}']);

  // The invites query.
  await show('invites query:',
    `select m.id, g.slug, m.options, u.full_name, u.username
       from game_matches m
       join games g on g.id = m.game_id
       left join users u on u.id = m.created_by
      where m.status = 'waiting' and m.player_ids @> $1::jsonb
      limit 1`,
    [JSON.stringify([uid])]);
} catch (e) {
  console.log('[probe] fatal:', e.message);
} finally {
  await client.end().catch(() => {});
}
