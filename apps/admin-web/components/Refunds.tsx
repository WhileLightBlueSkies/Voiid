'use client';

//
// Refund pieces shared by the event page and the Refunds queue.
//
// A refund always carries a reason — it is recorded, shown to the buyer, and in the audit log —
// so the dialog asks for one, with the common ones a click away and room for your own words.
//

import { useState } from 'react';

export type RefundState = 'pending' | 'failed' | 'refunded';

export const REFUND_TONE: Record<RefundState, 'ok' | 'danger' | 'warning' | 'accent'> = {
  pending: 'warning', failed: 'danger', refunded: 'accent',
};
export const REFUND_LABEL: Record<RefundState, string> = {
  pending: 'Refund on the way', failed: 'Refund failed', refunded: 'Refunded',
};

/** Where an order's refund stands, or null when there is no refund in play. */
export function refundState(o: { status: string; refund_requested_at: string | null; refund_error: string | null }): RefundState | null {
  if (o.status === 'refunded') return 'refunded';
  if (o.status !== 'paid') return null;
  if (o.refund_error) return 'failed';
  if (o.refund_requested_at) return 'pending';
  return null;
}

const REASONS: { code: string; label: string }[] = [
  { code: 'event_cancelled', label: 'Event cancelled' },
  { code: 'attendee_request', label: 'Requested by the attendee' },
  { code: 'duplicate_payment', label: 'Duplicate payment' },
  { code: 'event_changed', label: 'Event changed' },
];

export function RefundDialog({ title, detail, defaultReason, onCancel, onConfirm }: {
  title: string;
  detail: string;
  defaultReason: string;
  onCancel: () => void;
  onConfirm: (reason: string) => void;
}) {
  const [reason, setReason] = useState(defaultReason);
  const [custom, setCustom] = useState('');
  const other = reason === 'other';
  const ready = !other || custom.trim().length >= 3;

  return (
    <div role="dialog" aria-modal="true" aria-labelledby="refund-title"
         onClick={onCancel}
         style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.45)', display: 'flex',
                  alignItems: 'center', justifyContent: 'center', zIndex: 50, padding: 16 }}>
      <div className="card" onClick={(e) => e.stopPropagation()}
           style={{ maxWidth: 460, width: '100%', padding: 22 }}>
        <h2 id="refund-title" style={{ margin: '0 0 8px', fontSize: 18 }}>{title}</h2>
        <p className="mute" style={{ margin: '0 0 16px', fontSize: 14, lineHeight: 1.45 }}>{detail}</p>

        <div className="mute" style={{ fontSize: 12, marginBottom: 6 }}>Reason (shown to the buyer)</div>
        <div style={{ display: 'grid', gap: 6, marginBottom: 12 }}>
          {[...REASONS, { code: 'other', label: 'Something else…' }].map((r) => (
            <label key={r.code} style={{ display: 'flex', gap: 8, alignItems: 'center', fontSize: 14, cursor: 'pointer' }}>
              <input type="radio" name="refund-reason" checked={reason === r.code}
                     onChange={() => setReason(r.code)} />
              {r.label}
            </label>
          ))}
        </div>
        {other && (
          <input autoFocus value={custom} onChange={(e) => setCustom(e.target.value)} maxLength={200}
                 placeholder="In a few words" style={{ width: '100%', marginBottom: 12 }} />
        )}

        <div className="row" style={{ gap: 8, justifyContent: 'flex-end' }}>
          <button className="ghost" onClick={onCancel}>Cancel</button>
          <button className="danger" disabled={!ready}
                  onClick={() => onConfirm(other ? custom.trim() : reason)}>
            Refund
          </button>
        </div>
      </div>
    </div>
  );
}
