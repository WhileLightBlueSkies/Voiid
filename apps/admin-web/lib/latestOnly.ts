//
// The two small rules that stop the console showing an operator something untrue.
//
// Kept out of the React components so they can be tested directly: both bugs they fix are
// ORDERING bugs, and ordering is exactly what is hard to see by reading a hook.
//

/**
 * Only the newest request may write state (W02).
 *
 * The list debounce cleared a TIMER, not a request. A fetch already in flight when the filter
 * changed still completed, and because it finished last its `setRows` won — so the table
 * showed rows for a filter the operator had already moved away from, with a cursor belonging
 * to that obsolete query. "Load more" then appended pages of the wrong list.
 *
 * A generation counter rather than "compare the query string": two requests for the SAME query
 * (a reload, or a filter toggled away and back) are still distinct requests, and the older one
 * still must not win.
 */
export class LatestRequest {
  private generation = 0;
  private retired = false;

  /** Start a request and take a token for it. Anything older is now obsolete. */
  begin(): number {
    return ++this.generation;
  }

  /** May the response holding this token write? */
  isCurrent(token: number): boolean {
    return !this.retired && token === this.generation;
  }

  /** The component unmounted: nothing may write again. */
  retire(): void {
    this.retired = true;
  }

  /**
   * An abort is US cancelling, not the server failing.
   *
   * Showing "could not load this list" because the operator typed another character is a
   * failure banner for a success, and it trains people to ignore the banner.
   */
  static isAbort(error: unknown): boolean {
    return (error as { name?: string } | null)?.name === 'AbortError';
  }
}

/**
 * Append a page without showing a row twice (W02).
 *
 * Keyset pagination can legitimately return an overlapping row — a boundary row, or one
 * updated between pages — and the old code pushed it in again. Later values win, because a
 * stale row is worse than one that did not move, and position is kept so the table does not
 * reshuffle under the cursor.
 */
export function dedupeById<T extends { id?: string }>(existing: T[], page: T[]): T[] {
  const merged = [...existing];
  const index = new Map<string, number>();
  existing.forEach((row, i) => { if (row?.id) index.set(row.id, i); });
  for (const row of page) {
    const at = row?.id !== undefined ? index.get(row.id) : undefined;
    if (at === undefined) {
      if (row?.id) index.set(row.id, merged.length);
      merged.push(row);
    } else {
      merged[at] = row;
    }
  }
  return merged;
}

/**
 * What the operator actually said in the note dialog (W01).
 *
 * `window.prompt(...)?.trim() ?? ''` collapsed Cancel and an empty note into the same empty
 * string, and the caller then resolved the report anyway — an irreversible action taken after
 * the operator declined to take it. `null` means they said no; `''` means they said yes with
 * nothing to add.
 */
export function promptNote(raw: string | null): string | null {
  return raw === null ? null : raw.trim();
}
