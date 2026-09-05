#!/usr/bin/env node
// Runs every named tsx suite and reports ALL of their results, then exits non-zero if any
// failed.
//
// This replaces an `&&` chain. The chain was not merely untidy: when one early suite failed
// (the stale snake tick assertion in engine/registry.test.ts), the five suites after it never
// ran, so an audit reading CI could not tell whether they passed, failed, or were simply
// never reached. Short-circuiting is the right behaviour for a build pipeline and the wrong
// behaviour for a test report — a test run's job is to tell you everything that is broken,
// not just the first thing.
//
// Suites are still run SEQUENTIALLY: they are independent, but serial output stays readable
// and keeps any shared-resource assumptions intact.
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Resolve tsx from the repo's own node_modules rather than trusting PATH. `npm run` puts
// .bin on PATH, but a bare spawnSync does not inherit that the way a shell does, and an
// unresolvable binary is an ENOENT that is far too easy to mistake for a passing suite.
const here = path.dirname(fileURLToPath(import.meta.url));
const tsx = [
  path.join(here, '..', 'node_modules', '.bin', 'tsx'),
  path.join(process.cwd(), 'node_modules', '.bin', 'tsx'),
].find((c) => existsSync(c));
if (!tsx) {
  console.error('run-suites: could not resolve the tsx binary in node_modules/.bin');
  process.exit(2);
}

const suites = process.argv.slice(2);
if (suites.length === 0) {
  console.error('run-suites: no suite files given');
  process.exit(2);
}

const failed = [];
for (const suite of suites) {
  console.log(`\n──── ${suite} ────`);
  const r = spawnSync(tsx, [suite], { stdio: 'inherit', shell: false });
  // A suite killed by a signal, or one that could not be spawned at all, is a failure too.
  // Note the order: on a spawn error `status` is null, so checking `r.error` FIRST is what
  // stops an unrunnable suite from being reported as a passing one.
  if (r.error) failed.push(`${suite} (could not run: ${r.error.message})`);
  else if (r.signal) failed.push(`${suite} (killed by signal ${r.signal})`);
  else if (r.status !== 0) failed.push(`${suite} (exit ${r.status})`);
}

console.log(`\n──── ${suites.length - failed.length}/${suites.length} suites passed ────`);
if (failed.length > 0) {
  for (const f of failed) console.log(`FAILED  ${f}`);
  process.exit(1);
}
