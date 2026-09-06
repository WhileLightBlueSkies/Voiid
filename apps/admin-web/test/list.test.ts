// W01/W02 — the two ways the console lies to an operator.
//
// W02: the list debounce cleared a TIMER, not a request. A fetch already in flight when the
// filter changed still completed, and its `setRows` ran last — so the table showed results for
// a filter the operator had already moved away from, with a cursor from that same obsolete
// query. "Load more" then appended pages of the wrong list.
//
// W01: `window.prompt(...)?.trim() ?? ''` turned Cancel into an empty string, so cancelling
// the note dialog still resolved the report. There is no undo on that screen.
import test from 'node:test';
import assert from 'node:assert/strict';
import { LatestRequest, dedupeById, promptNote } from '../lib/latestOnly';

// ── W02: only the newest request may write ─────────────────────────────────────

test('the newest request wins, whatever order the responses arrive in', () => {
  const guard = new LatestRequest();
  const first = guard.begin();
  const second = guard.begin();

  assert.equal(guard.isCurrent(second), true);
  assert.equal(
    guard.isCurrent(first), false,
    'the slow first response must not overwrite what the second already showed'
  );
});

test('a response that started and finished alone may write', () => {
  const guard = new LatestRequest();
  const token = guard.begin();
  assert.equal(guard.isCurrent(token), true);
});

test('an unmounted list accepts nothing further', () => {
  const guard = new LatestRequest();
  const token = guard.begin();
  guard.retire();
  assert.equal(guard.isCurrent(token), false, 'React would warn, and the state is gone anyway');
});

test('an aborted request is not a failure to show the operator', () => {
  assert.equal(LatestRequest.isAbort(Object.assign(new Error('x'), { name: 'AbortError' })), true);
  assert.equal(LatestRequest.isAbort(new DOMException('aborted', 'AbortError')), true);
  assert.equal(
    LatestRequest.isAbort(new Error('the server said no')), false,
    'a real error must still reach the banner'
  );
});

// ── W02: appended pages ────────────────────────────────────────────────────────

test('load-more cannot show the same row twice', () => {
  const existing = [{ id: 'a' }, { id: 'b' }];
  const page = [{ id: 'b' }, { id: 'c' }];
  assert.deepEqual(dedupeById(existing, page).map((r) => r.id), ['a', 'b', 'c']);
});

test('a re-fetched row keeps its position but takes the newer values', () => {
  const existing = [{ id: 'a', status: 'open' }, { id: 'b', status: 'open' }];
  const page = [{ id: 'a', status: 'resolved' }];
  const merged = dedupeById(existing, page);
  assert.deepEqual(merged.map((r) => r.id), ['a', 'b']);
  assert.equal(merged[0].status, 'resolved', 'a stale row is worse than a reordered one');
});

test('rows without an id are kept rather than silently dropped', () => {
  const merged = dedupeById([{ id: 'a' }], [{} as { id: string }]);
  assert.equal(merged.length, 2);
});

// ── W01: Cancel is not an empty note ───────────────────────────────────────────

test('cancelling the note dialog performs no action at all', () => {
  assert.equal(promptNote(null), null, 'Cancel and Escape both give null');
});

test('an intentionally empty note is still a submission', () => {
  assert.equal(promptNote(''), '');
  assert.equal(promptNote('   '), '', 'trimmed, but present');
});

test('a note is trimmed, not altered', () => {
  assert.equal(promptNote('  spam and abuse '), 'spam and abuse');
});
