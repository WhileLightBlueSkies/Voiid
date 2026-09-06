'use client';

import { useCallback, useLayoutEffect, useRef, useState } from 'react';
import { api } from '../lib/api';
import { LatestRequest, dedupeById } from '../lib/latestOnly';

export function useList<T extends { id?: string }>(path: string, key: string, params: Record<string, string> = {}) {
  const [rows, setRows] = useState<T[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const qs = JSON.stringify(params);
  const identity = JSON.stringify([path, key, qs]);
  const active = useRef<{ identity: string; controller: AbortController; append: boolean } | null>(null);
  const mountedQuery = useRef<string | null>(null);

  const load = useCallback(async (append: string | null = null) => {
    if (mountedQuery.current !== identity || (append && active.current?.append)) return;
    active.current?.controller.abort();
    const request = { identity, controller: new AbortController(), append: append !== null };
    active.current = request;
    const current = () => active.current === request && mountedQuery.current === identity;
    setLoading(true);
    try {
      const p = new URLSearchParams(JSON.parse(qs) as Record<string, string>);
      if (append) p.set('cursor', append);
      const result = await api<Record<string, unknown>>(`${path}?${p}`, { signal: request.controller.signal });
      if (!current()) return;
      const page = (result[key] as T[]) ?? [];
      setRows(previous => append ? dedupeById(previous, page) : page);
      setCursor((result.next_cursor as string | null) ?? null);
      setError(null);
    } catch (e) {
      if (current() && !LatestRequest.isAbort(e)) setError(e instanceof Error ? e.message : 'could not load this list');
    } finally {
      if (current()) { active.current = null; setLoading(false); }
    }
  }, [identity, path, key, qs]);

  // Invalidate at the filter commit, before debounce or an obsolete response can run.
  // Setup is reversible so React StrictMode's cleanup/setup cycle remains functional.
  useLayoutEffect(() => {
    mountedQuery.current = identity;
    active.current?.controller.abort();
    active.current = null;
    setRows([]); setCursor(null); setError(null); setLoading(true);
    const timer = setTimeout(() => { void load(); }, 200);
    return () => {
      clearTimeout(timer);
      mountedQuery.current = null;
      active.current?.controller.abort();
      active.current = null;
    };
  }, [identity, load]);

  return { rows, cursor, loading, error, reload: () => load(), more: () => cursor ? load(cursor) : Promise.resolve() };
}
