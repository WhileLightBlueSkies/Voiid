'use client';

import type { ReactNode } from 'react';
import { Async } from './ui';

/** The table frame + load-more control every list page shares. */
export function ListTable({ head, loading, error, empty, emptyText, cursor, onMore, children }: {
  head: string[]; loading: boolean; error: string | null; empty: boolean;
  emptyText: string; cursor: string | null; onMore: () => void; children: ReactNode;
}) {
  return (
    <Async loading={loading && empty} error={error} empty={empty} emptyText={emptyText}>
      <div className="card" style={{ padding: 0, overflow: 'auto' }}>
        <table>
          <thead><tr>{head.map((h) => <th key={h}>{h}</th>)}</tr></thead>
          <tbody>{children}</tbody>
        </table>
      </div>
      {cursor && (
        <div style={{ marginTop: 14, textAlign: 'center' }}>
          <button className="ghost" disabled={loading} onClick={onMore}>
            {loading ? 'Loading…' : 'Load more'}
          </button>
        </div>
      )}
    </Async>
  );
}
