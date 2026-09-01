'use client';

//
// The primitives every page composes from. They exist so that "loading", "this failed", and
// "there is genuinely nothing here" look the same everywhere — three states that a console
// must never blur, because an operator who reads a failed fetch as an empty queue concludes
// there is no work waiting.
//

import type { ReactNode } from 'react';

export function PageHeader({ title, subtitle, right }: {
  title: string; subtitle?: string; right?: ReactNode;
}) {
  return (
    <header style={{ display: 'flex', alignItems: 'flex-start', gap: 16, marginBottom: 22 }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <h1>{title}</h1>
        {subtitle && <p className="muted" style={{ margin: '5px 0 0', fontSize: 14 }}>{subtitle}</p>}
      </div>
      {right}
    </header>
  );
}

export function Stat({ label, value, tone, sub }: {
  label: string; value: number | string; tone?: 'ok' | 'warning' | 'danger';
  /// What the number is OF. A bare figure invites the wrong reading — "12" beside Tickets
  /// means nothing until it says whether capacity is 12 or 1200.
  sub?: string;
}) {
  return (
    <div className="card" style={{ padding: 16 }}>
      <div className="mute" style={{ fontSize: 13 }}>{label}</div>
      <div
        className="mono"
        style={{
          fontSize: 28, fontWeight: 650, marginTop: 4, letterSpacing: '-0.02em',
          // Colour appears only when the number MEANS something. A count of zero overdue
          // requests must not wear the same red as a count of nine.
          color: tone ? `var(--${tone})` : 'var(--text)',
        }}
      >
        {value}
      </div>
      {sub && <div className="mute" style={{ fontSize: 12, marginTop: 2 }}>{sub}</div>}
    </div>
  );
}

/** The three states, in one place, in a fixed order of precedence. */
export function Async<T>({ loading, error, empty, emptyText, children }: {
  loading: boolean; error: string | null; empty: boolean; emptyText: string; children: ReactNode;
}) {
  // Error BEFORE empty, always. A list that failed to load and drew as "nothing here" is
  // the one lie an operations console cannot tell.
  if (error) return <div className="notice error">{error}</div>;
  if (loading) return <div className="empty">Loading…</div>;
  if (empty) return <div className="empty">{emptyText}</div>;
  return <>{children}</>;
}

export function Pill({ tone, children }: {
  tone?: 'ok' | 'danger' | 'warning' | 'accent'; children: ReactNode;
}) {
  return <span className={`pill${tone ? ` ${tone}` : ''}`}>{children}</span>;
}

/** Dates render in the operator's locale; a raw ISO string is not a reading experience. */
export function when(iso: string | null | undefined): string {
  if (!iso) return '—';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '—';
  return d.toLocaleString(undefined, {
    year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit',
  });
}

export function name(full?: string | null, username?: string | null, fallback = 'Unknown'): string {
  if (full && full.trim()) return full;
  if (username && username.trim()) return `@${username}`;
  return fallback;
}

/// Minor units in, decimal string out. The server never divides — a float rupee is a
/// rounding bug waiting for a reconciliation — so the decimal point is placed here, once.
export function money(minor: number | string | null | undefined, currency = 'INR') {
  const n = typeof minor === 'string' ? Number(minor) : minor;
  if (n == null || Number.isNaN(n)) return '—';
  try {
    return new Intl.NumberFormat('en-IN', {
      style: 'currency', currency, minimumFractionDigits: 2,
    }).format(n / 100);
  } catch {
    // An unknown currency code should degrade to a readable number, not blank the cell.
    return `${currency} ${(n / 100).toFixed(2)}`;
  }
}
