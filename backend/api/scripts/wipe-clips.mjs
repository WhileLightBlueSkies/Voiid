#!/usr/bin/env node
//
// wipe-clips.mjs — delete every clip, from Postgres AND R2.
//
// A CLEAN SLATE BEFORE CREATOR PROFILES LAND. Clips currently have no creator profile
// behind them, and the profile becomes mandatory at post time; rather than backfill
// profiles for a handful of test uploads, the feed starts empty.
//
// THIS IS IRREVERSIBLE. There is no undo, no soft-delete, and no backup taken here — the
// videos are gone from R2 and the rows are gone from the database.
//
// So it is DRY RUN BY DEFAULT. It prints exactly what it would remove and exits. Deleting
// only happens when you pass --confirm, which is deliberately awkward to type by accident.
//
//   node scripts/wipe-clips.mjs                             # counts only, deletes nothing
//   node scripts/wipe-clips.mjs --confirm                   # deletes clips + media
//   node scripts/wipe-clips.mjs --confirm --reset-profiles  # ALSO wipes creator identity
//
// --reset-profiles additionally clears creator_profiles, creator_follows and
// creator_handle_history. Without it, a wipe leaves every user still holding their old
// handle — so the "create a profile before you post" gate never fires for them, and the
// first-post flow cannot actually be tested on a supposedly fresh database. WITH it, every
// handle returns to the pool and every user goes through the picker again.
//
// ORDER MATTERS. R2 objects go FIRST, rows second. The keys only exist in the rows, so
// deleting rows first would orphan every video in the bucket with no way left to find it —
// storage you pay for forever and cannot enumerate. If this script dies halfway, a re-run
// picks up where it left off precisely because the rows are still there.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import pg from 'pg';
import { S3Client, DeleteObjectCommand } from '@aws-sdk/client-s3';

const __dirname = dirname(fileURLToPath(import.meta.url));
const CONFIRM = process.argv.includes('--confirm');
// SEPARATE FLAG, deliberately. Wiping clips is about content; wiping creator profiles
// destroys IDENTITY — handles, follower graphs, avatars. Someone clearing out test videos
// almost never means "and release every @handle on the platform", so it must be asked for
// explicitly rather than riding along with --confirm.
const RESET_PROFILES = process.argv.includes('--reset-profiles');

// ---- config -----------------------------------------------------------------

function env(name, required = true) {
  const v = process.env[name];
  if (!v && required) {
    console.error(`Missing ${name}. Run with the API's environment loaded, e.g.\n` +
                  `  node --env-file=.env scripts/wipe-clips.mjs`);
    process.exit(1);
  }
  return v;
}

// TLS settings copied from src/db.ts so this script reaches the SAME database the API
// does. Managed Postgres (Supabase, RDS) terminates TLS with a chain Node does not trust
// out of the box; local development has no TLS at all.
// `?sslmode=require` in the URL takes precedence over the `ssl` option below and makes
// node-postgres verify the chain, which managed Postgres fails. Strip it so the explicit
// setting wins — the connection is still TLS, just without chain verification, exactly as
// the API does it.
const dbUrl = env('DATABASE_URL').replace(/[?&]sslmode=[a-z-]+/i, '');
const isLocalDb = /@(localhost|127\.0\.0\.1)/.test(dbUrl);
const pool = new pg.Pool({
  connectionString: dbUrl,
  ssl: isLocalDb ? undefined : { rejectUnauthorized: false },
});

// Matches src/r2.ts exactly — R2_ENDPOINT is the full URL, not an account id. Building the
// URL here from a different variable would mean this script works against a different
// bucket than the API writes to, which for a delete script is the worst possible bug.
const s3 = new S3Client({
  region: 'auto',
  endpoint: env('R2_ENDPOINT'),
  credentials: {
    accessKeyId: env('R2_ACCESS_KEY_ID'),
    secretAccessKey: env('R2_SECRET_ACCESS_KEY'),
  },
});
const BUCKET = env('R2_BUCKET');

// ---- run --------------------------------------------------------------------

const { rows } = await pool.query(`
  select id, author_id, r2_key, thumb_r2_key, r2_key_sd, r2_key_hd, byte_size, created_at
    from clips
   order by created_at
`);

// creator_profiles may not exist on a database that has not run 029 yet — to_regclass
// returns null instead of throwing, so this script still works mid-migration.
const hasProfiles = (await pool.query(
  `select to_regclass('public.creator_profiles') is not null as ok`)).rows[0].ok;

const counts = await pool.query(`
  select
    (select count(*) from clips)          ::int as clips,
    (select count(*) from clip_likes)     ::int as likes,
    (select count(*) from clip_views)     ::int as views,
    (select count(*) from clip_comments)  ::int as comments,
    ${hasProfiles ? "(select count(*) from creator_profiles)::int" : '0'} as profiles,
    ${hasProfiles ? "(select count(*) from creator_follows)::int" : '0'}  as follows
`);
const c = counts.rows[0];

// Four keys per clip, not one: the original, both renditions (023) and the thumbnail.
// Missing any of them leaves orphaned objects that nothing can ever enumerate again.
const keys = rows.flatMap(r =>
  [r.r2_key, r.thumb_r2_key, r.r2_key_sd, r.r2_key_hd].filter(Boolean));

const bytes = rows.reduce((n, r) => n + Number(r.byte_size ?? 0), 0);
const authors = new Set(rows.map(r => r.author_id));

console.log('');
console.log('  WIPE CLIPS');
console.log('  ----------');
console.log(`  clips        ${c.clips}`);
console.log(`  authors      ${authors.size}`);
console.log(`  likes        ${c.likes}`);
console.log(`  views        ${c.views}`);
console.log(`  comments     ${c.comments}`);
console.log(`  profiles     ${c.profiles}${RESET_PROFILES ? '' : '   (kept — pass --reset-profiles)'}`);
console.log(`  follows      ${c.follows}${RESET_PROFILES ? '' : '   (kept — pass --reset-profiles)'}`);
console.log(`  R2 objects   ${keys.length}`);
console.log(`  video bytes  ${(bytes / 1e6).toFixed(1)} MB`);
console.log('');

if (!CONFIRM) {
  console.log('  DRY RUN — nothing deleted.');
  console.log('  Re-run with --confirm to actually delete.');
  console.log('');
  await pool.end();
  process.exit(0);
}

// R2 FIRST — see the header. A failure here is survivable; the rows still name the keys.
let deleted = 0, failed = 0;
for (const key of keys) {
  try {
    await s3.send(new DeleteObjectCommand({ Bucket: BUCKET, Key: key }));
    deleted++;
  } catch (e) {
    // Keep going. One unreachable object must not strand the other 200 — and a key that
    // is already gone (a retry, a half-finished upload) is a success, not an error.
    failed++;
    console.warn(`  ! could not delete ${key}: ${e.message}`);
  }
}
console.log(`  R2: ${deleted} deleted, ${failed} failed`);

// Rows second, in one transaction. clip_likes / clip_views / clip_comments cascade from
// clips, but they are truncated explicitly so the intent is visible rather than implied by
// a foreign key someone might later alter.
const client = await pool.connect();
try {
  await client.query('begin');
  await client.query('delete from clip_comments');
  await client.query('delete from clip_views');
  await client.query('delete from clip_likes');
  await client.query('delete from clips');
  if (RESET_PROFILES) {
    // Order matters: follows reference profiles' users, and handle history references the
    // user too. Deleting profiles first would work by cascade, but doing it explicitly keeps
    // the intent readable and does not depend on a foreign key someone may later alter.
    await client.query('delete from creator_follows');
    await client.query('delete from creator_handle_history');
    await client.query('delete from creator_profiles');
  }
  await client.query('commit');
  console.log(`  DB: all clip rows deleted`);
  if (RESET_PROFILES) console.log('  DB: creator profiles, follows and handle history reset');
} catch (e) {
  await client.query('rollback');
  console.error('  DB delete FAILED, rolled back:', e.message);
  process.exitCode = 1;
} finally {
  client.release();
}

console.log('');
await pool.end();
