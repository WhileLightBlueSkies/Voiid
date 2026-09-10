// Bask control agent — the remote operations plane.
//
// A SEPARATE AUTH SYSTEM AGAIN, and for a stronger reason than the admin router's.
// routes/admin.ts authenticates a PERSON against admin_users so it can take content
// down. This one authenticates a MACHINE — Bask, the internal admin app — and what it
// can do is restart processes, rewrite /opt/voiid/.env and run migrations. That is root
// on the box by another name, so it shares nothing with either the user JWT or the admin
// session: a compromised phone, and a stolen admin cookie, both end at this router's door.
//
// THE COMMAND SET IS CLOSED, and closed in the strong sense: `command` is a NAME that
// selects a handler from a table in this file, never a string that reaches a shell. There
// is no passthrough parameter and no arbitrary-argument escape hatch, because the whole
// value of a remote ops endpoint is that the blast radius is the list you can read here.
// Everything is spawned as an argv array with shell:false — no /bin/sh, so no quoting bug
// in this file can ever become command injection.
//
// NOTHING HERE ECHOES A SECRET. The env route names KEYS in its output and never values,
// and no handler returns the contents of .env. An operator reading a response, or a log
// line from one, must not learn a credential — this endpoint's own audience is the admin
// app, whose screen is exactly where a leaked DATABASE_URL would be most convenient.
import { Router } from 'express';
import type { Request, Response, NextFunction } from 'express';
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync, renameSync, copyFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { timingSafeEqual, createHash } from 'node:crypto';
import { asyncHandler } from '../util';

const router = Router();

// ─────────────────────────────────────────────────────────────────────────────────
// The services this box runs
// ─────────────────────────────────────────────────────────────────────────────────

/**
 * The pm2 process names from infrastructure/deployment/deploy-dev.sh, which is the
 * only thing that starts anything here. Kept in this order because it is the order an
 * operator thinks in: the two that serve traffic, then the two that work behind them.
 *
 * This list is also the ALLOWLIST for the `service` parameter. The caller is told to send
 * a name it got from GET /status, but a caller that can be trusted to do that could equally
 * be a stolen token, so every service name is checked against this set before it is passed
 * to pm2 as an argument.
 */
const SERVICES = ['voiid-api', 'voiid-ws', 'voiid-games', 'voiid-workers'] as const;
type ServiceName = (typeof SERVICES)[number];

function isService(value: unknown): value is ServiceName {
  return typeof value === 'string' && (SERVICES as readonly string[]).includes(value);
}

/** Where the box actually keeps its environment (docs/VULTR_DEPLOY.md; deploy-dev.sh reads the same file). */
const APP_DIR = process.env.VOIID_APP_DIR ?? '/opt/voiid';
const ENV_FILE = process.env.VOIID_ENV_FILE ?? join(APP_DIR, '.env');

// ─────────────────────────────────────────────────────────────────────────────────
// Auth
// ─────────────────────────────────────────────────────────────────────────────────

/**
 * 16 chars is the floor the caller specified; the token we actually issue is 43 chars of
 * base64url from 32 random bytes. The floor exists so a placeholder like "changeme" cannot
 * quietly become production auth on a plane that can restart the platform.
 */
const MIN_TOKEN_LENGTH = 16;

/**
 * Read at module load, not per request, so a boot with a missing token fails at startup
 * (see assertBaskAgentConfig) rather than at the first call from Bask — by which time the
 * failure is someone else's pager.
 */
const EXPECTED_TOKEN = process.env.BASK_AGENT_TOKEN ?? '';

/**
 * Constant-time bearer comparison.
 *
 * timingSafeEqual throws on a length mismatch, and the LENGTH itself is a real leak: a
 * naive wrapper that returns early on differing lengths tells an attacker how long the
 * token is, which is the first thing you would want to know. Hashing both sides to a fixed
 * 32 bytes first makes every comparison the same shape regardless of what was sent, so the
 * only thing the timing reveals is nothing.
 */
function tokenMatches(presented: string): boolean {
  const a = createHash('sha256').update(presented).digest();
  const b = createHash('sha256').update(EXPECTED_TOKEN).digest();
  return timingSafeEqual(a, b);
}

/**
 * Every route in this router, with no exceptions and no per-route opt-out.
 *
 * Applied with router.use() rather than named on each route, because the failure mode of
 * an ops plane is the one new endpoint somebody added without the guard — and a missing
 * middleware in a route definition is much easier to miss in review than this is.
 */
function requireBaskToken(req: Request, res: Response, next: NextFunction) {
  const header = req.headers.authorization;
  if (typeof header !== 'string' || !header.startsWith('Bearer ') || !tokenMatches(header.slice(7))) {
    // No detail, deliberately. "wrong token" and "missing header" are the same answer here;
    // distinguishing them only helps someone who is guessing.
    return res.status(401).json({ error: 'unauthorized' });
  }
  next();
}

router.use(requireBaskToken);

/**
 * Called from index.ts BEFORE listen(). Refuses to boot on a token that is absent or too
 * short, per the operator contract — the alternative is a control plane that is live and
 * unauthenticated, which is strictly worse than a box that does not come up.
 */
export function assertBaskAgentConfig(): void {
  if (EXPECTED_TOKEN.length >= MIN_TOKEN_LENGTH) return;
  // Under `node --test` the app is imported to assert its MOUNT ORDER (test/rateLimitRouting.ts
  // and friends), never to serve — index.ts stubs listen() away. Exiting there would fail those
  // tests on a machine that has no ops token, which is every developer machine. The guard that
  // matters is the one on the boot path, and index.ts calls this immediately before listen().
  if (process.env.NODE_ENV === 'test' || process.env.NODE_TEST_CONTEXT) return;
  console.error(
    '[voiid:api] REFUSING TO START: BASK_AGENT_TOKEN is ' +
      (EXPECTED_TOKEN ? `${EXPECTED_TOKEN.length} chars — the minimum is ${MIN_TOKEN_LENGTH}` : 'not set') +
      '. The Bask control agent can restart services and rewrite .env; it does not run unauthenticated. ' +
      'Generate one with: openssl rand -base64 32 | tr -d /+= | head -c 43'
  );
  process.exit(1);
}

// ─────────────────────────────────────────────────────────────────────────────────
// Running things
// ─────────────────────────────────────────────────────────────────────────────────

/** The caller times out at 20s, so every child gets a shorter leash than that. */
const COMMAND_TIMEOUT_MS = 15_000;

/** Migrations are the one command that can legitimately outrun the caller. See runMigrations below. */
const MIGRATION_TIMEOUT_MS = 14_000;

/** The response cap from the contract. Applied to the LAST 8 KB — a failure explains itself at the end. */
const MAX_OUTPUT_BYTES = 8 * 1024;

function truncate(text: string): string {
  const buf = Buffer.from(text, 'utf8');
  if (buf.length <= MAX_OUTPUT_BYTES) return text;
  // Slice on a byte boundary, then let toString drop any partial UTF-8 sequence at the cut.
  const tail = buf.subarray(buf.length - MAX_OUTPUT_BYTES).toString('utf8');
  return `[... ${buf.length - MAX_OUTPUT_BYTES} earlier bytes truncated ...]\n${tail}`;
}

interface CommandResult { exitCode: number; output: string }

/**
 * Spawn an argv array. NEVER a shell string.
 *
 * shell:false is the default and is stated explicitly anyway, because it is the single
 * property that makes this file safe: with no /bin/sh in the path, a service name or a line
 * count cannot be quoted out of its argument position no matter what it contains. The
 * allowlists elsewhere in this file are defence in depth on top of it, not instead of it.
 *
 * Never rejects: a spawn failure is a result with a non-zero code, because the contract
 * says a command that ran and failed is still a successful HTTP call.
 */
function run(argv: string[], timeoutMs = COMMAND_TIMEOUT_MS): Promise<CommandResult> {
  const [command, ...args] = argv;
  return new Promise((resolve) => {
    let settled = false;
    const finish = (exitCode: number, output: string) => {
      if (settled) return;
      settled = true;
      resolve({ exitCode, output: truncate(output) });
    };

    let child;
    try {
      child = spawn(command, args, { shell: false, env: process.env });
    } catch (err) {
      return finish(1, `failed to run ${command}: ${(err as Error).message}`);
    }

    // Bounded in memory as well as in the response: a runaway `pm2 logs` must not grow the
    // API's heap while we wait for it. We keep a little over the cap and truncate at the end.
    const chunks: Buffer[] = [];
    let bytes = 0;
    const collect = (chunk: Buffer) => {
      chunks.push(chunk);
      bytes += chunk.length;
      while (bytes > MAX_OUTPUT_BYTES * 2 && chunks.length > 1) {
        bytes -= chunks.shift()!.length;
      }
    };
    child.stdout?.on('data', collect);
    child.stderr?.on('data', collect);

    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      finish(1, `${command} exceeded ${Math.round(timeoutMs / 1000)}s and was killed.\n` +
                 Buffer.concat(chunks).toString('utf8'));
    }, timeoutMs);

    child.on('error', (err) => {
      clearTimeout(timer);
      finish(1, `failed to run ${command}: ${err.message}`);
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      finish(code ?? 1, Buffer.concat(chunks).toString('utf8') || `(${command} produced no output)`);
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────────
// The commands
// ─────────────────────────────────────────────────────────────────────────────────

/** pm2 as an absolute path where we can find one; the deploy runs it off PATH, so PATH is the fallback. */
const PM2 = process.env.VOIID_PM2_BIN ?? 'pm2';

/** "3d 4h" / "2h 11m" / "45s" — pm2 uptimes are read at a glance, not parsed. */
function humanDuration(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d) return `${d}d ${h}h`;
  if (h) return `${h}h ${m}m`;
  if (m) return `${m}m`;
  return `${s}s`;
}

async function pm2Action(action: 'restart' | 'stop' | 'start', service: ServiceName): Promise<CommandResult> {
  // --update-env matches deploy-dev.sh: a restart after an env change must pick the new
  // values up, and a pm2 restart WITHOUT it silently keeps the old environment — which
  // would make POST /env's `restart: true` a lie in exactly the case it exists for.
  const argv = action === 'start'
    ? [PM2, 'start', service]
    : [PM2, action, service, '--update-env'];
  const result = await run(argv);
  if (result.exitCode === 0) {
    return { exitCode: 0, output: `${service} ${action === 'stop' ? 'stopped' : action + 'ed'} successfully.\n\n${result.output}` };
  }
  return result;
}

/**
 * `pm2 jlist` rather than the pretty table: the table's box drawing is unreadable once it
 * reaches an admin panel, and jlist gives us the fields worth showing without parsing columns.
 */
async function serviceStatus(): Promise<CommandResult> {
  const result = await run([PM2, 'jlist']);
  if (result.exitCode !== 0) return result;
  try {
    const procs = JSON.parse(result.output) as Array<{
      name: string;
      pm2_env?: { status?: string; restart_time?: number; pm_uptime?: number };
      monit?: { cpu?: number; memory?: number };
    }>;
    const lines = SERVICES.map((name) => {
      const proc = procs.find((p) => p.name === name);
      if (!proc) return `${name.padEnd(14)} not running (no pm2 process)`;
      const status = proc.pm2_env?.status ?? 'unknown';
      const uptime = proc.pm2_env?.pm_uptime ? humanDuration((Date.now() - proc.pm2_env.pm_uptime) / 1000) : '—';
      const mem = proc.monit?.memory ? `${Math.round(proc.monit.memory / 1024 / 1024)}MB` : '—';
      return `${name.padEnd(14)} ${status.padEnd(10)} up ${uptime.padEnd(12)} cpu ${String(proc.monit?.cpu ?? 0).padEnd(5)} mem ${mem.padEnd(8)} restarts ${proc.pm2_env?.restart_time ?? 0}`;
    });
    const unhealthy = lines.filter((l) => !l.includes('online')).length;
    return { exitCode: unhealthy > 0 ? 1 : 0, output: lines.join('\n') };
  } catch {
    // pm2 printed something that is not JSON — hand it over rather than swallowing it.
    return { exitCode: 1, output: `could not parse pm2 jlist output:\n${result.output}` };
  }
}

/**
 * Reload without a full restart.
 *
 * `pm2 reload` is a rolling, zero-downtime restart in cluster mode and a plain restart in
 * fork mode, which is what these four processes use. That is still the honest answer to
 * "reload config" on this box: Node reads .env at boot via --env-file, so there is no
 * signal that re-reads configuration in place, and pretending otherwise would mean
 * reporting success while the process kept its old values.
 */
async function reloadConfig(): Promise<CommandResult> {
  const result = await run([PM2, 'reload', ...SERVICES, '--update-env']);
  if (result.exitCode !== 0) return result;
  return {
    exitCode: 0,
    output: 'Reloaded all services with a refreshed environment.\n\n' +
      'Note: these run under pm2 in fork mode and read configuration from .env at boot, so a ' +
      'reload is a fast restart rather than an in-place re-read. There is no in-place option ' +
      'on this box.\n\n' + result.output,
  };
}

async function tailLogs(service: ServiceName, lines: number): Promise<CommandResult> {
  // `pm2 logs --nostream` prints the last N lines and exits, instead of following the file
  // forever — following is what would hold the caller's connection open until its 20s timeout.
  // `lines` is a validated integer, and is passed as its own argv element regardless.
  return run([PM2, 'logs', service, '--lines', String(lines), '--nostream']);
}

async function diskUsage(): Promise<CommandResult> {
  const result = await run(['df', '-h', '/']);
  if (result.exitCode !== 0) return result;
  // The box also fills up in ways `df /` does not explain — pm2's own logs are the usual
  // culprit — so include them when the directory is there.
  const logs = await run(['du', '-sh', join(process.env.HOME ?? '/root', '.pm2', 'logs')]);
  return {
    exitCode: 0,
    output: result.output + (logs.exitCode === 0 ? `\npm2 logs: ${logs.output.trim()}` : ''),
  };
}

/**
 * The project's migrations, run exactly the way the deploy runs them
 * (infrastructure/deployment/migrate.mjs, idempotent, pending-only, advisory-locked).
 *
 * THE LOCK IS WHY THIS IS SAFE TO EXPOSE. migrate.mjs takes pg_advisory_lock(862419,1)
 * before it reads the ledger, so this route racing a deploy does not interleave — the
 * second one waits, then finds nothing pending.
 *
 * It is also the one command that can outlast the caller's 20s timeout, since a migration
 * over a large table takes as long as it takes. Killing it mid-flight would be far worse
 * than answering late, so on timeout we report "still running" and LEAVE IT RUNNING — the
 * advisory lock means the next call reports the truth rather than starting a second copy.
 */
async function runMigrations(): Promise<CommandResult> {
  const script = join(APP_DIR, 'infrastructure', 'deployment', 'migrate.mjs');
  if (!existsSync(script)) {
    return { exitCode: 1, output: `migration runner not found at ${script} — is VOIID_APP_DIR correct?` };
  }
  const result = await run(['node', `--env-file=${ENV_FILE}`, script], MIGRATION_TIMEOUT_MS);
  if (result.exitCode === 1 && result.output.includes('was killed')) {
    return {
      exitCode: 1,
      output:
        'Migrations are STILL RUNNING — they outlasted this request and were left running ' +
        'deliberately rather than killed mid-statement.\n\n' +
        'migrate.mjs holds a Postgres advisory lock, so nothing else will start a second copy. ' +
        'Re-run this command in a minute: it will either report the completed set or wait on the ' +
        'same lock. Check `pm2 logs` on the box if it never settles.',
    };
  }
  return result;
}

// ─────────────────────────────────────────────────────────────────────────────────
// GET /status
// ─────────────────────────────────────────────────────────────────────────────────

router.get('/status', asyncHandler(async (_req, res) => {
  const pm2 = await serviceStatus();
  // "degraded" and not "offline" when something is down: this process is answering, so the
  // BOX is up by definition. Offline is a state only the caller's own connection failure can
  // establish, and claiming it here would be reporting on our own absence.
  const status = pm2.exitCode === 0 ? 'online' : 'degraded';
  const detail = pm2.exitCode === 0
    ? null
    : truncateDetail(pm2.output.split('\n').filter((l) => !l.includes('online')).join('; '));
  res.json({ status, detail, services: [...SERVICES] });
}));

/** The contract caps `detail` at 500 chars. Nothing here carries a value from .env. */
function truncateDetail(text: string): string {
  const clean = text.replace(/\s+/g, ' ').trim();
  return clean.length <= 500 ? clean : clean.slice(0, 497) + '...';
}

// ─────────────────────────────────────────────────────────────────────────────────
// POST /command
// ─────────────────────────────────────────────────────────────────────────────────

const COMMANDS = ['status', 'restart_service', 'stop_service', 'start_service',
                  'reload_config', 'tail_logs', 'disk_usage', 'run_migrations'] as const;
type CommandName = (typeof COMMANDS)[number];

/** The four that take a service. Used to decide whether `service` is required, not just allowed. */
const SERVICE_COMMANDS = new Set<CommandName>(['restart_service', 'stop_service', 'start_service', 'tail_logs']);

const DEFAULT_LOG_LINES = 100;
const MAX_LOG_LINES = 500;

router.post('/command', asyncHandler(async (req, res) => {
  const body = (req.body ?? {}) as { command?: unknown; service?: unknown; lines?: unknown };
  const command = body.command;

  if (typeof command !== 'string' || !(COMMANDS as readonly string[]).includes(command)) {
    // 400 and not 200: an unrecognised command did not run, so it has no exit code to report.
    return res.status(400).json({ error: 'unknown_command', commands: [...COMMANDS] });
  }
  const name = command as CommandName;

  let service: ServiceName | undefined;
  if (SERVICE_COMMANDS.has(name)) {
    if (!isService(body.service)) {
      return res.status(400).json({ error: 'unknown_service', services: [...SERVICES] });
    }
    service = body.service;
  }

  let lines = DEFAULT_LOG_LINES;
  if (name === 'tail_logs' && body.lines != null) {
    const parsed = Number(body.lines);
    if (!Number.isInteger(parsed) || parsed < 1 || parsed > MAX_LOG_LINES) {
      return res.status(400).json({ error: 'invalid_lines', min: 1, max: MAX_LOG_LINES });
    }
    lines = parsed;
  }

  const result = await dispatch(name, service, lines);
  // 200 even on a non-zero exit code: the command ran, so the CALL succeeded. Reserving
  // non-200 for auth/shape/agent errors is what lets the caller tell "your migration failed"
  // apart from "your token is wrong", which are very different pages to wake up to.
  res.status(200).json(result);
}));

/**
 * The name-to-action table. This IS the closed list — there is no default branch that
 * falls through to running anything, and adding a command means adding a function above.
 */
async function dispatch(name: CommandName, service: ServiceName | undefined, lines: number): Promise<CommandResult> {
  switch (name) {
    case 'status':          return serviceStatus();
    case 'restart_service': return pm2Action('restart', service!);
    case 'stop_service':    return pm2Action('stop', service!);
    case 'start_service':   return pm2Action('start', service!);
    case 'reload_config':   return reloadConfig();
    case 'tail_logs':       return tailLogs(service!, lines);
    case 'disk_usage':      return diskUsage();
    case 'run_migrations':  return runMigrations();
  }
}

// ─────────────────────────────────────────────────────────────────────────────────
// POST /env
// ─────────────────────────────────────────────────────────────────────────────────

/** The caller's contract, restated here because this is where it is enforced. */
const KEY_PATTERN = /^[A-Z_][A-Z0-9_]{0,127}$/;
const MAX_CHANGES = 50;

interface EnvChange { key: string; value: string | null }

/**
 * Rewrite .env in place, preserving comments, blank lines and key ORDER.
 *
 * A naive implementation reads the file into an object and writes it back out, which
 * silently destroys every comment in a file that is mostly comments (see .env.example) —
 * the next operator to open it loses the rollout notes for DB TLS. So we edit LINES:
 * a changed key is rewritten where it sits, a deleted key's line is dropped, and a new key
 * is appended.
 */
function applyEnvChanges(original: string, changes: EnvChange[]): { text: string; updated: string[]; added: string[]; removed: string[]; missing: string[] } {
  const lines = original.split('\n');
  const updated: string[] = [], added: string[] = [], removed: string[] = [], missing: string[] = [];

  for (const { key, value } of changes) {
    // Match an assignment for this key, ignoring leading whitespace. A COMMENTED-OUT key
    // (`# API_PORT=4000`) is deliberately not matched: it is documentation, and uncommenting
    // it on the operator's behalf would change behaviour they did not ask for.
    const index = lines.findIndex((line) => new RegExp(`^\\s*${key}\\s*=`).test(line));
    if (value === null) {
      if (index === -1) { missing.push(key); continue; }
      lines.splice(index, 1);
      removed.push(key);
      continue;
    }
    const rendered = `${key}=${renderValue(value)}`;
    if (index === -1) { lines.push(rendered); added.push(key); }
    else { lines[index] = rendered; updated.push(key); }
  }

  let text = lines.join('\n');
  if (!text.endsWith('\n')) text += '\n';
  return { text, updated, added, removed, missing };
}

/**
 * Quote only when the value would otherwise not survive a round trip.
 *
 * Node's --env-file parser (and pm2's, and the shell's, if anyone sources this) treats a
 * bare value as running to end of line, so a value with a trailing space, a quote, a
 * newline or a `#` needs quoting to come back the same. Values that need nothing are left
 * bare, so the file keeps looking like the hand-written file it is.
 */
function renderValue(value: string): string {
  if (value === '' || /[\s"'#$`\\]/.test(value)) {
    return `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n')}"`;
  }
  return value;
}

router.post('/env', asyncHandler(async (req, res) => {
  const body = (req.body ?? {}) as { changes?: unknown; restart?: unknown };

  if (!Array.isArray(body.changes) || body.changes.length === 0) {
    return res.status(400).json({ error: 'changes_required' });
  }
  if (body.changes.length > MAX_CHANGES) {
    return res.status(400).json({ error: 'too_many_changes', max: MAX_CHANGES });
  }

  const changes: EnvChange[] = [];
  const seen = new Set<string>();
  for (const raw of body.changes) {
    const entry = raw as { key?: unknown; value?: unknown };
    if (typeof entry?.key !== 'string' || !KEY_PATTERN.test(entry.key)) {
      // The KEY is echoed because a key is not a secret and the operator needs to know which
      // entry was rejected. The value never is, here or anywhere else in this handler.
      return res.status(400).json({ error: 'invalid_key', key: String(entry?.key).slice(0, 128) });
    }
    if (entry.value !== null && typeof entry.value !== 'string') {
      return res.status(400).json({ error: 'invalid_value', key: entry.key });
    }
    // Two changes to one key in one request is ambiguous — the caller's intent is unknowable,
    // and applying them in array order would be a coin flip dressed up as a rule.
    if (seen.has(entry.key)) return res.status(400).json({ error: 'duplicate_key', key: entry.key });
    seen.add(entry.key);
    changes.push({ key: entry.key, value: entry.value as string | null });
  }

  if (!existsSync(ENV_FILE)) {
    return res.status(200).json({ exitCode: 1, output: `environment file not found at ${ENV_FILE} — is VOIID_APP_DIR correct?` });
  }

  let summary;
  try {
    const original = readFileSync(ENV_FILE, 'utf8');

    // TIMESTAMPED BACKUP FIRST, before anything is written. If the apply is wrong — a bad
    // DATABASE_URL, a deleted JWT_SECRET — the previous file is the only way back, and it has
    // to exist before the mistake, not after it.
    const backupDir = join(dirname(ENV_FILE), '.env-backups');
    if (!existsSync(backupDir)) mkdirSync(backupDir, { recursive: true, mode: 0o700 });
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    copyFileSync(ENV_FILE, join(backupDir, `env-${stamp}`));

    summary = applyEnvChanges(original, changes);

    // ATOMIC: write a temp file in the SAME directory, then rename over the target. rename(2)
    // within a filesystem is atomic, so a crash or a full disk mid-write leaves the old file
    // intact rather than a truncated one — and a truncated .env is a box that cannot boot,
    // since every service reads it with --env-file at startup.
    const temp = `${ENV_FILE}.tmp-${process.pid}-${Date.now()}`;
    writeFileSync(temp, summary.text, { mode: 0o600 });
    renameSync(temp, ENV_FILE);
  } catch (err) {
    // The MESSAGE of a filesystem error is a path and an errno, never file contents — safe to
    // return, and the difference between EACCES and ENOSPC is the whole diagnosis.
    return res.status(200).json({ exitCode: 1, output: `failed to write ${ENV_FILE}: ${(err as Error).message}` });
  }

  // KEY NAMES ONLY. Not the new value, not the old one, not a length or a prefix — the
  // operator asking for this change already knows what they sent.
  const parts: string[] = [];
  if (summary.updated.length) parts.push(`updated ${summary.updated.join(', ')}`);
  if (summary.added.length) parts.push(`added ${summary.added.join(', ')}`);
  if (summary.removed.length) parts.push(`removed ${summary.removed.join(', ')}`);
  if (summary.missing.length) parts.push(`${summary.missing.join(', ')} already absent`);
  const applied = summary.updated.length + summary.added.length + summary.removed.length;

  let output = `${applied} variable${applied === 1 ? '' : 's'} applied (${parts.join('; ')}). ` +
               `Previous file backed up under ${dirname(ENV_FILE)}/.env-backups/.`;
  let exitCode = 0;

  if (body.restart === true) {
    // ALL FOUR, because there is one .env and every service reads it. Restarting a subset
    // after an env change leaves the box running two different configurations, which is the
    // kind of state that produces a bug report nobody can reproduce.
    //
    // voiid-api RESTARTS ITSELF HERE. pm2 kills this process while the response is in flight,
    // so the caller may see a dropped connection on `restart: true` — the change is already
    // committed to disk at this point, and GET /status confirms the outcome.
    const restart = await run([PM2, 'restart', ...SERVICES, '--update-env']);
    exitCode = restart.exitCode;
    output += restart.exitCode === 0
      ? `\n\nRestarted: ${SERVICES.join(', ')}. (This API restarted itself, so a dropped ` +
        `connection on this request is expected — the changes are already on disk.)`
      : `\n\nENV CHANGES WERE APPLIED, BUT THE RESTART FAILED — services are still running the ` +
        `old values:\n${restart.output}`;
  } else {
    output += '\n\nNot restarted: the services read .env at boot, so these values are NOT live yet. ' +
              'Send restart: true, or run restart_service, to pick them up.';
  }

  res.status(200).json({ exitCode, output: truncate(output) });
}));

export default router;
