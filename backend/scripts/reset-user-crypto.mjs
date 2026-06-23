#!/usr/bin/env node
// Wipe a user's accumulated E2EE state so they re-register clean — clears the
// stale device generations + orphaned one-time prekeys that build up across many
// reinstalls and cause acceptSession DecryptionFailed (the sender lands on a dead
// one-time key whose private the recipient no longer has).
//
// It does NOT touch messages/conversations. After running, fully reinstall the
// app for that user → it registers a fresh device + publishes a fresh prekey pool.
//
// Usage (on the box, where DATABASE_URL is in /opt/voiid/.env):
//   cd /opt/voiid && node backend/scripts/reset-user-crypto.mjs <phone-or-user_id> [more...]
// Accepts a phone number (E.164 or last-10) OR a user_id (uuid).

import { readFileSync } from 'node:fs';
import pg from 'pg';

const args = process.argv.slice(2);
if (!args.length) { console.error('pass a phone number or user_id'); process.exit(2); }

const env = readFileSync('/opt/voiid/.env', 'utf8');
const url = (env.match(/^DATABASE_URL=(.*)$/m) || [])[1]?.trim();
if (!url) { console.error('DATABASE_URL not found in /opt/voiid/.env'); process.exit(2); }
const pool = new pg.Pool({ connectionString: url });

const isUuid = (s) => /^[0-9a-f-]{36}$/i.test(s);

for (const arg of args) {
  let userId = arg;
  if (!isUuid(arg)) {
    const digits = arg.replace(/\D/g, '');
    const r = await pool.query(
      `select id, phone_number from users where phone_number = $1 or phone_number like $2 limit 1`,
      [arg.startsWith('+') ? arg : `+${digits}`, `%${digits.slice(-10)}`]
    );
    if (!r.rows[0]) { console.log(`⚠️  no user for "${arg}"`); continue; }
    userId = r.rows[0].id;
    console.log(`• ${arg} → user ${userId} (${r.rows[0].phone_number})`);
  }
  const otk = await pool.query(
    `delete from one_time_prekeys where device_id in
       (select id from devices where user_id = $1) returning id`, [userId]);
  const sp = await pool.query(
    `delete from signed_prekeys where device_id in
       (select id from devices where user_id = $1) returning id`, [userId]).catch(() => ({ rowCount: 0 }));
  const dev = await pool.query(`delete from devices where user_id = $1 returning id`, [userId]);

  // Also wipe the DEAD messages in this user's conversations. After many reinstalls
  // the conversation is full of ciphertext encrypted to identities that no longer
  // exist — it can never decrypt and re-fails on every sync. Clearing it lets a
  // fresh exchange start from an empty, decryptable history.
  let msgs = { rowCount: 0 };
  if (process.env.WIPE_MESSAGES === '1') {
    msgs = await pool.query(
      `delete from messages where conversation_id in
         (select conversation_id from conversation_members where user_id = $1) returning id`,
      [userId]
    );
  }
  console.log(`  ✅ removed ${dev.rowCount} device(s), ${otk.rowCount} one-time prekey(s), ${sp.rowCount} signed prekey(s)` +
    (process.env.WIPE_MESSAGES === '1' ? `, ${msgs.rowCount} message(s)` : ' (messages kept; set WIPE_MESSAGES=1 to also clear the poisoned history)'));
}

await pool.end();
console.log('\nDone. Fully REINSTALL the app(s) for these users so they re-register clean.');
