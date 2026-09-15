const events = new Set(['call_offer', 'call_answer', 'call_hangup', 'call_decline', 'call_busy']);
const reasons = new Set(['no-answer', 'ice-failed', 'ice-closed', 'setup-failed', 'local-hangup',
  'remote-hangup', 'conference-migrated', 'swapped', 'declined', 'busy', 'answer', 'decline', 'ended', 'offer']);

/** Explicitly allowlisted lifecycle fields only. Never serialize the signaling frame. */
export function callDiagnostic(type: unknown, reason: unknown, decision: 'received' | 'allowed' | 'blocked',
  until: number, now = Date.now()) {
  if (!Number.isFinite(until) || now >= until || typeof type !== 'string' || !events.has(type)) return null;
  return { at: new Date(now).toISOString(), event: type, decision,
    reason: typeof reason === 'string' && reasons.has(reason) ? reason : 'unspecified' };
}
