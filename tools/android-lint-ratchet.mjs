#!/usr/bin/env node
// Compares the Android lint error count against a recorded baseline.
//
// WHY A RATCHET AND NOT `-D warnings`: lintDebug currently reports 116 errors, and they are
// real (36 of them are the java.time NewApi calls that A03 tracks as an API 24/25 crash
// risk). Two options were available and both are worse than this one:
//
//   - Gate on zero. CI is red from the first run, every author learns the Android job is
//     "always broken", and the gate stops being read at all.
//   - Don't gate. The count keeps climbing, exactly as it has been.
//
// So: the existing debt is recorded and visible, and the build fails if the count GROWS.
// Fixing errors below the baseline is rewarded with a message asking you to lower it, which
// is how the number gets to zero without a flag day.
//
// This is a stopgap that A03 and Q06 are expected to burn down. It is not a licence to leave
// 116 errors in place.
import { readFileSync, existsSync } from 'node:fs';

const [reportPath, baselinePath] = process.argv.slice(2);
if (!reportPath || !baselinePath) {
  console.error('usage: android-lint-ratchet.mjs <lint-results.txt> <baseline.json>');
  process.exit(2);
}

// A missing report means lint did not run, which must never read as "no errors".
if (!existsSync(reportPath)) {
  console.error(`lint-ratchet: no lint report at ${reportPath} — did lintDebug run?`);
  process.exit(2);
}

const report = readFileSync(reportPath, 'utf8');
// Trust lint's own summary line ("116 errors, 276 warnings, 23 hints") over counting matches
// ourselves: a multi-line error entry would otherwise be counted more than once.
const summary = report.match(/^(\d+) errors?, (\d+) warnings?/m);
if (!summary) {
  console.error('lint-ratchet: could not find the "N errors, M warnings" summary in the report');
  process.exit(2);
}
const errors = Number(summary[1]);

const baseline = JSON.parse(readFileSync(baselinePath, 'utf8'));
const allowed = Number(baseline.maxErrors);
if (!Number.isInteger(allowed)) {
  console.error(`lint-ratchet: ${baselinePath} has no integer maxErrors`);
  process.exit(2);
}

console.log(`lint-ratchet: ${errors} error(s); baseline allows ${allowed}`);

if (errors > allowed) {
  console.error(
    `\nAndroid lint errors went UP: ${errors} > ${allowed}.\n` +
      `Fix the new error(s). Do not raise maxErrors in ${baselinePath} to make this pass —\n` +
      `the baseline only ever moves down.\n`
  );
  process.exit(1);
}

if (errors < allowed) {
  console.log(
    `\nLint errors went DOWN (${errors} < ${allowed}). Please lower "maxErrors" to ${errors}\n` +
      `in ${baselinePath} so the improvement is locked in.\n`
  );
}
