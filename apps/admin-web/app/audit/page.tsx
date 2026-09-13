'use client';

//
// The audit log. GET /admin/audit has existed with no UI at all — so every moderation action
// and, more importantly, every DENIED privileged attempt has been recorded where nobody
// could read it. A log nobody looks at is a log that is not doing its job.
//

import { useCallback, useEffect, useState } from 'react';
import Shell from '../../components/Shell';
import { PageHeader, Async, Pill, when } from '../../components/ui';
import { api } from '../../lib/api';
import { Card } from '../../components/ui/card';
import { Badge } from '../../components/ui/badge';
import { Button } from '../../components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '../../components/ui/table';

type Entry = {
  id: string; admin_id: string | null; action: string;
  target_type: string | null; target_id: string | null;
  detail: unknown; created_at: string;
  admin_email?: string | null; admin_name?: string | null;
};

export default function Audit() {
  return <Shell>{() => <Body />}</Shell>;
}

function Body() {
  const [rows, setRows] = useState<Entry[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async (append: string | null = null) => {
    setLoading(true);
    try {
      const p = new URLSearchParams();
      if (append) p.set('cursor', append);
      const r = await api<{ entries?: Entry[]; audit?: Entry[]; next_cursor: string | null }>(
        `/audit?${p}`,
      );
      // The route's envelope key is read defensively: this list is the record of what
      // happened, and rendering it as empty because a key was named differently would be
      // the most misleading possible failure.
      const list = r.entries ?? r.audit ?? [];
      setRows((prev) => (append ? [...prev, ...list] : list));
      setCursor(r.next_cursor);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'could not load the audit log');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void load(null); }, [load]);

  return (
    <>
      <PageHeader
        title="Audit log"
        subtitle="Every action taken from this console, and every privileged attempt that was refused."
      />

      <Async
        loading={loading && rows.length === 0}
        error={error}
        empty={rows.length === 0}
        emptyText="Nothing recorded yet."
      >
        <Card className="overflow-hidden p-0">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>When</TableHead>
                <TableHead>Who</TableHead>
                <TableHead>Action</TableHead>
                <TableHead>Target</TableHead>
                <TableHead>Detail</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((e) => (
                <TableRow key={e.id}>
                  <TableCell className="whitespace-nowrap text-tiny text-[var(--text-mute)]">
                    {when(e.created_at)}
                  </TableCell>
                  <TableCell className="text-tiny text-[var(--text-dim)]">
                    {e.admin_name || e.admin_email || '—'}
                  </TableCell>
                  <TableCell>
                    {/* A refusal is the interesting half of an incident, so it is the one
                        action that gets a colour of its own. */}
                    {e.action.endsWith('forbidden')
                      ? <Badge variant="destructive">{e.action}</Badge>
                      : <Badge variant="secondary">{e.action}</Badge>}
                  </TableCell>
                  <TableCell className="text-tiny text-[var(--text-dim)]">
                    {e.target_type ?? '—'}
                    {e.target_id && (
                      <div className="mono text-micro text-[var(--text-mute)]">
                        {e.target_id.slice(0, 8)}…
                      </div>
                    )}
                  </TableCell>
                  {/* The detail is raw JSON and can be long. Truncated with the full value
                      on hover: a log row must stay one line tall or the table stops being
                      scannable, but the detail is often the reason someone opened it. */}
                  <TableCell className="mono max-w-[280px] truncate text-micro text-[var(--text-mute)]"
                             title={e.detail ? JSON.stringify(e.detail, null, 2) : undefined}>
                    {e.detail ? JSON.stringify(e.detail) : '—'}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </Card>

        {cursor && (
          <div className="mt-4 text-center">
            <Button variant="outline" size="sm" disabled={loading} onClick={() => void load(cursor)}>
              {loading ? 'Loading…' : 'Load more'}
            </Button>
          </div>
        )}
      </Async>
    </>
  );
}
