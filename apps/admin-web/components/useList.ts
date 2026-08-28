'use client';

//
// One keyset-pagination hook for every list in the console.
//
// It exists because five pages hand-rolling the same cursor/append/error dance is five
// chances to get the error-vs-empty distinction wrong, and that distinction is the one an
// operations console cannot afford to blur.
//

import { useCallback, useEffect, useState } from 'react';
import { api } from '../lib/api';

export function useList<T>(
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

  const load = useCallback(async (append: string | null = null) => {
    setLoading(true);
    try {
      const p = new URLSearchParams(JSON.parse(qs) as Record<string, string>);
      if (append) p.set('cursor', append);
      const r = await api<Record<string, unknown>>(`${path}?${p}`);
      const list = (r[key] as T[]) ?? [];
      setRows((prev) => (append ? [...prev, ...list] : list));
      setCursor((r.next_cursor as string | null) ?? null);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'could not load this list');
    } finally {
      setLoading(false);
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
