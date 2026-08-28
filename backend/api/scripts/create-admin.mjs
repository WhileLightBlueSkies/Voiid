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
// The password is GENERATED and printed once. Passing one on the command line would write
// it into shell history and the process list, where it outlives the session.
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
const password = randomBytes(18).toString('base64url');
const hash = await bcrypt.hash(password, 12);

const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });

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
  // `on conflict (email)` needs a unique index on that column. The login path does a
  // case-insensitive lookup and takes limit 1, which does NOT prove one exists — so check
  // first and fall back to an explicit update rather than crashing on a missing constraint.
  const uniq = await pool.query(
    `select 1 from pg_indexes
      where tablename = 'admin_users' and indexdef ilike '%unique%' and indexdef ilike '%(email)%'
      limit 1`,
  );

  if (uniq.rowCount === 0) {
    const existing = await pool.query(
      `select id from admin_users where lower(email) = $1 limit 1`, [email],
    );
    if (existing.rowCount > 0) {
      const u = await pool.query(
        `update admin_users
            set password_hash = $2, role = $3, disabled_at = null,
                name = coalesce(nullif($4, ''), name)
          where id = $1
          returning id, email, name, role, false as created`,
        [existing.rows[0].id, hash, role, name],
      );
      report(u.rows[0]);
      await pool.end();
      process.exit(0);
    }
  }

  const r = await pool.query(
    `insert into admin_users (email, name, role, password_hash)
     values ($1, $2, $3, $4)
     on conflict (email) do update
       set password_hash = excluded.password_hash,
           name = coalesce(nullif(excluded.name, ''), admin_users.name),
           role = excluded.role,
           disabled_at = null
     returning id, email, name, role,
               (xmax = 0) as created`,
    [email, name || email.split('@')[0], role, hash],
  );

  report(r.rows[0]);
} catch (err) {
  console.error('failed:', err.message);
  process.exitCode = 1;
} finally {
  await pool.end();
}
