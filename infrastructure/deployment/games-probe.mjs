// TEMPORARY — runs GET /games/invites' exact query against the real database and prints the
// Postgres error. Delete once that endpoint returns 200.
//
// Why a file and not `node -e`: an inline script's quotes are eaten by the enclosing shell, which
// produced fake errors indistinguishable from real ones and cost several deploy cycles. Quotes in
// a file reach Postgres exactly as written.
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { Client } = require('pg');

const url = process.env.DATABASE_URL ?? '';
if (!url) { console.log('[probe] no DATABASE_URL'); process.exit(0); }

const client = new Client({
  connectionString: url,
  ssl: /@(localhost|127\.0\.0\.1)/.test(url) ? undefined : { rejectUnauthorized: false },
});

async function show(label, sql, params) {
  try {
    const r = await client.query(sql, params);
    console.log(`[probe] ${label} OK rows=${r.rows.length}`,
      JSON.stringify(r.rows[0] ?? null).slice(0, 260));
  } catch (e) {
    console.log(`[probe] ${label} FAILED code=${e.code} msg=${e.message} pos=${e.position ?? '-'}`);
  }
}

try {
  await client.connect();

  const uid = (await client.query('select id from users limit 1')).rows[0]?.id;
  console.log('[probe] user:', uid ?? '(none)');

  await show('columns of game_matches:',
    `select string_agg(column_name || ':' || data_type, ' | ' order by ordinal_position) as cols
       from information_schema.columns where table_name = 'game_matches'`);

  // The EXACT invites query from routes/games.ts.
  await show('invites (exact query):',
    `select m.id, g.slug, g.name, g.icon_key, m.options, m.created_by, m.created_at,
            u.full_name as inviter_name, u.username as inviter_username
       from game_matches m
       join games g on g.id = m.game_id
       left join users u on u.id = m.created_by
      where m.status = 'waiting'
        and m.created_by <> $1::uuid
        and m.player_ids @> $2::jsonb
      order by m.created_at desc
      limit 20`,
    [uid, JSON.stringify([uid])]);
} catch (e) {
  console.log('[probe] fatal:', e.message);
} finally {
  await client.end().catch(() => {});
}
