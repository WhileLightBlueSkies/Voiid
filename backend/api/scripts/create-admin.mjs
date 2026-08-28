#!/usr/bin/env node
//
// Create (or re-password) an admin account.
//
// There is deliberately NO signup route on the admin plane: an endpoint that mints
// moderator accounts is a permanent hole in a surface whose whole job is taking content
// down. Accounts are made here, by someone who already holds the database.
//
// Usage, on the box where DATABASE_URL is set:
//   node scripts/create-admin.mjs --email=you@voiid.app --name="Your Name" --role=admin
//
// The password is GENERATED and printed once by default. Passing one on the command line
// writes it into shell history and the process list, where it outlives the session — so
// --password= exists for a deliberate choice (a known first login), not as the normal path.
//
// Re-running for an existing email RESETS that account's password rather than failing —
// which is the recovery path, and the reason it does not silently create a second row.

import pg from 'pg';
import bcrypt from 'bcryptjs';
import { randomBytes } from 'node:crypto';

const arg = (k) => process.argv.find((a) => a.startsWith(`--${k}=`))?.split('=').slice(1).join('=');

const email = (arg('email') ?? '').trim().toLowerCase();
const name = (arg('name') ?? '').trim();
// Anything other than an explicit 'admin' falls back to the LEAST privilege, matching how
// requireAdmin reads the column: an unrecognised value can only ever cost access.
const role = arg('role') === 'admin' ? 'admin' : 'moderator';

if (!email || !email.includes('@')) {
  console.error('usage: node scripts/create-admin.mjs --email=you@voiid.app --name="Your Name" --role=admin');
  process.exit(1);
}
if (!process.env.DATABASE_URL) {
  console.error('DATABASE_URL is not set. Run this on the API box, or export it first.');
  process.exit(1);
}

// 18 bytes of base64url ≈ 144 bits. Long enough that the account is not the weak link, and
// short enough to retype once into a password manager.
const password = arg('password') || randomBytes(18).toString('base64url');
const hash = await bcrypt.hash(password, 12);

// Matches src/db.ts: Supabase's pooler presents a chain node does not have a root for, so a
// remote connection disables chain verification exactly as the API does. Local Postgres gets
// no ssl block at all rather than a weakened one.
const isLocal = /localhost|127\.0\.0\.1/.test(process.env.DATABASE_URL);
// `?sslmode=require` in the URL is read by current pg as verify-full, which then IGNORES the
// ssl object below and fails on Supabase's chain. Stripping the parameter lets the explicit
// setting win — same connection security as the API, which does not carry the flag.
const connectionString = process.env.DATABASE_URL.replace(/[?&]sslmode=[^&]*/, '');
const pool = new pg.Pool({
  connectionString,
  ssl: isLocal ? undefined : { rejectUnauthorized: false },
});

function report(a) {
  console.log('');
  console.log(a.created ? '  Admin created.' : '  Admin already existed — password reset.');
  console.log('');
  console.log(`  Email     ${a.email}`);
  console.log(`  Password  ${password}`);
  console.log(`  Role      ${a.role}`);
  console.log('');
  console.log('  This password is shown ONCE and is not stored anywhere in plaintext.');
  console.log('');
}

try {
  // NO `on conflict`. The upsert form needs a unique index on email, and admin_users does
  // not necessarily have one — probing pg_indexes first was not enough, because that only
  // covered the case where a row ALREADY existed. A brand-new account with no constraint
  // fell straight through to an insert that cannot work.
  //
  // Look-then-write is correct here regardless: this script is run by hand, by one person,
  // on a table with a handful of rows. The race an upsert protects against does not exist.
  const existing = await pool.query(
    `select id from admin_users where lower(email) = $1 limit 1`, [email],
  );

  const r = existing.rowCount > 0
    ? await pool.query(
        `update admin_users
            set password_hash = $2, role = $3, disabled_at = null,
                name = coalesce(nullif($4, ''), name)
          where id = $1
          returning id, email, name, role, false as created`,
        [existing.rows[0].id, hash, role, name],
      )
    : await pool.query(
        `insert into admin_users (email, name, role, password_hash)
         values ($1, $2, $3, $4)
         returning id, email, name, role, true as created`,
        [email, name || email.split('@')[0], role, hash],
      );

  report(r.rows[0]);
} catch (err) {
  console.error('failed:', err.message);
  process.exitCode = 1;
} finally {
  await pool.end();
}
