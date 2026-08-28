'use client';

//
// The range control: presets plus a custom picker, in the Cloudflare shape — a single
// button showing the ACTIVE range, opening a popover rather than sitting permanently
// expanded. A dashboard's date control is touched rarely and read constantly, so it should
// cost one line of chrome, not a row of inputs.
//
// Native <input type="date"> rather than a hand-built calendar grid: it is keyboard
// accessible, localised, and understands the user's locale conventions for free. A custom
// calendar here would be several hundred lines re-earning what the platform already does.
//

import { useEffect, useRef, useState } from 'react';

export type Range =
  | { kind: 'days'; days: number }
  | { kind: 'custom'; from: string; to: string };

export function rangeQuery(r: Range): string {
  return r.kind === 'days' ? `days=${r.days}` : `from=${r.from}&to=${r.to}`;
}

export function rangeLabel(r: Range): string {
  if (r.kind === 'days') {
    return r.days === 1 ? 'Today' : `Last ${r.days} days`;
  }
  return r.from === r.to ? r.from : `${r.from} → ${r.to}`;
}

const PRESETS = [7, 30, 90];

/** Local-time YYYY-MM-DD. toISOString() would shift the day for anyone behind UTC. */
function iso(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

export function DateRange({ value, onChange }: {
  value: Range; onChange: (r: Range) => void;
}) {
  const [open, setOpen] = useState(false);
  const [from, setFrom] = useState(value.kind === 'custom' ? value.from : '');
  const [to, setTo] = useState(value.kind === 'custom' ? value.to : '');
  const [error, setError] = useState<string | null>(null);
  const box = useRef<HTMLDivElement>(null);

  // Dismiss on outside click and on Escape. A popover that can only be closed by the
  // control that opened it is a trap for anyone who reached it by keyboard.
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (box.current && !box.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false); };
    document.addEventListener('mousedown', onDown);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDown);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);

  const today = iso(new Date());

  function apply() {
    if (!from || !to) { setError('Pick both dates.'); return; }
    // Checked here as well as server-side. The server is the authority; this exists so the
    // answer is instant and does not cost a round trip to say something obvious.
    if (from > to) { setError('The start date is after the end date.'); return; }
    setError(null);
    onChange({ kind: 'custom', from, to });
    setOpen(false);
  }

  return (
    <div ref={box} style={{ position: 'relative' }}>
      <div className="row" style={{ gap: 6 }}>
        {PRESETS.map((d) => (
          <button
            key={d}
            className={value.kind === 'days' && value.days === d ? '' : 'ghost'}
            onClick={() => onChange({ kind: 'days', days: d })}
            style={{ padding: '5px 11px' }}
          >
            {d}d
          </button>
        ))}
        <button
          className={value.kind === 'custom' ? '' : 'ghost'}
          onClick={() => setOpen((o) => !o)}
          style={{ padding: '5px 11px' }}
          aria-expanded={open}
        >
          {value.kind === 'custom' ? rangeLabel(value) : 'Custom'}
        </button>
      </div>

      {open && (
        <div
          className="card"
          style={{
            position: 'absolute', right: 0, top: 'calc(100% + 6px)', zIndex: 20,
            width: 268, boxShadow: 'var(--shadow-2)',
          }}
        >
          <div className="mute" style={{ fontSize: 11, fontWeight: 600, letterSpacing: '0.06em', textTransform: 'uppercase', marginBottom: 10 }}>
            Custom range
          </div>

          <label className="mute" style={{ fontSize: 12 }}>From</label>
          <input
            type="date" value={from} max={to || today}
            onChange={(e) => { setFrom(e.target.value); setError(null); }}
            style={{ margin: '5px 0 12px', padding: '7px 10px', fontSize: 13 }}
          />

          <label className="mute" style={{ fontSize: 12 }}>To</label>
          <input
            type="date" value={to} min={from || undefined} max={today}
            onChange={(e) => { setTo(e.target.value); setError(null); }}
            style={{ margin: '5px 0 12px', padding: '7px 10px', fontSize: 13 }}
          />

          {error && (
            <div className="notice error" style={{ marginBottom: 10, padding: '7px 10px', fontSize: 12 }}>
              {error}
            </div>
          )}

          {/* Ranges over a year are clamped by the server to the most recent 366 days, so
              say that here rather than letting a chart quietly disagree with the request. */}
          <p className="mute" style={{ fontSize: 11, margin: '0 0 12px' }}>
            Ranges longer than a year show the most recent 366 days.
          </p>

          <div className="row" style={{ gap: 8 }}>
            <button onClick={apply} style={{ flex: 1 }}>Apply</button>
            <button className="ghost" onClick={() => setOpen(false)}>Cancel</button>
          </div>
        </div>
      )}
    </div>
  );
}
