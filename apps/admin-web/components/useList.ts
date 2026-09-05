'use client';

//
// One keyset-pagination hook for every list in the console.
//
// It exists because five pages hand-rolling the same cursor/append/error dance is five
// chances to get the error-vs-empty distinction wrong, and that distinction is the one an
// operations console cannot afford to blur.
//
// ── W02: WHAT THE DEBOUNCE WAS NOT DOING ─────────────────────────────────────────
//
// The effect cleared a TIMER on filter change. It did not cancel a request already in flight,
// so a slow response for filter A could land after B's and overwrite B's rows, B's cursor and
// B's error state — the table then showed results for a filter the operator had moved away
// from, and "load more" appended pages of that obsolete query. Two things fix it, and both are
// needed: an AbortController so the obsolete request stops costing anything, and a generation
// check before EVERY state write, because an abort is not instantaneous and a response can
// already be in the microtask queue when the next filter arrives.
//
import { useCallback, useEffect, useRef, useState } from 'react';
import { api } from '../lib/api';
import { LatestRequest, dedupeById } from '../lib/latestOnly';

export function useList<T extends { id?: string }>(
  path: string,
  key: string,
  params: Record<string, string> = {},
) {
  const [rows, setRows] = useState<T[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Serialised so the effect re-runs on VALUE change, not on the new object identity a
  // caller creates inline on every render — which would loop forever.
  const qs = JSON.stringify(params);

  const guard = useRef(new LatestRequest());
  const inFlight = useRef<AbortController | null>(null);
  // Load-more is serialised: two clicks used to fire two appends from the same cursor.
  const appending = useRef(false);

  useEffect(() => {
    const current = guard.current;
    return () => {
      current.retire();
      inFlight.current?.abort();
    };
  }, []);

  const load = useCallback(async (append: string | null = null) => {
    if (append && appending.current) return;
    if (append) appending.current = true;

    inFlight.current?.abort();
    const controller = new AbortController();
    inFlight.current = controller;
    const token = guard.current.begin();

    setLoading(true);
    try {
      const p = new URLSearchParams(JSON.parse(qs) as Record<string, string>);
      if (append) p.set('cursor', append);
      const r = await api<Record<string, unknown>>(`${path}?${p}`, { signal: controller.signal });
      // The check has to be here, after the await, and again in every branch below: the
      // response may have been overtaken while it was being parsed.
      if (!guard.current.isCurrent(token)) return;
      const list = (r[key] as T[]) ?? [];
      setRows((prev) => (append ? dedupeById(prev, list) : list));
      setCursor((r.next_cursor as string | null) ?? null);
      setError(null);
    } catch (e) {
      // An abort is us cancelling, not the server failing. Showing a banner because the
      // operator typed another character teaches people to ignore banners.
      if (LatestRequest.isAbort(e) || !guard.current.isCurrent(token)) return;
      setError(e instanceof Error ? e.message : 'could not load this list');
    } finally {
      if (append) appending.current = false;
      // `finally` runs for the obsolete response too, and clearing `loading` there would hide
      // the spinner while the CURRENT request is still running.
      if (guard.current.isCurrent(token)) setLoading(false);
    }
  }, [path, key, qs]);

  useEffect(() => {
    const t = setTimeout(() => { void load(null); }, 200);
    return () => clearTimeout(t);
  }, [load]);

  return {
    rows, cursor, loading, error,
    reload: () => load(null),
    more: () => load(cursor),
  };
}
