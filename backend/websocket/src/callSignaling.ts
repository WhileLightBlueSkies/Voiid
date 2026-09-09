/** Normalize the two shipped clients' opaque, device-addressed call-key formats. */
export function callKeyCopies(message: Record<string, any>): Array<{ device_id: string; body: string }> | null {
  const raw = message.ciphertexts;
  const entries: unknown[] = Array.isArray(raw) ? raw
    : raw && typeof raw === 'object' ? Object.entries(raw).map(([device_id, body]) => ({ device_id, body }))
    : [{ device_id: message.device_id, body: message.ciphertext }];
  if (!entries.length || entries.length > 32) return null;
  const copies: Array<{ device_id: string; body: string }> = [];
  const seen = new Set<string>();
  for (const entry of entries) {
    const e = entry as Record<string, unknown> | null;
    if (!e || typeof e.device_id !== 'string' || !e.device_id || e.device_id.length > 128 ||
        typeof e.body !== 'string' || !e.body || e.body.length > 65536 || seen.has(e.device_id)) return null;
    seen.add(e.device_id);
    copies.push({ device_id: e.device_id, body: e.body });
  }
  return copies;
}

/**
 * One device wins a 1:1 answer/decline. Redis serializes the claim across relay instances.
 * Existing winners may renegotiate; losing devices cannot hang up the winning call.
 * Conference keys/invites use their separate roster authorization and never claim a seat here.
 * Result: [allowed, winningDevice, verdict]. No SDP or key material is stored.
 */
export const CALL_DEVICE_CLAIM_SCRIPT = `
local peerVerdict = redis.call('HGET', KEYS[2], 'verdict')
if peerVerdict == 'decline' or peerVerdict == 'ended' then return {0, '', peerVerdict} end
local owner = redis.call('HGET', KEYS[1], 'device')
local verdict = redis.call('HGET', KEYS[1], 'verdict')
if owner and owner ~= ARGV[1] then return {0, owner, verdict or ''} end
if verdict == 'decline' or verdict == 'ended' then return {0, owner or '', verdict} end
local kind = ARGV[2]
if kind == 'call_answer' or kind == 'call_decline' or kind == 'call_offer' then
  local next = kind == 'call_decline' and 'decline' or ((kind == 'call_answer' or verdict == 'answer') and 'answer' or 'offer')
  redis.call('HSET', KEYS[1], 'device', ARGV[1], 'verdict', next)
  redis.call('EXPIRE', KEYS[1], ARGV[3])
  return {1, ARGV[1], next}
end
if kind == 'call_hangup' and ARGV[4] ~= 'conference-migrated' then
  redis.call('HSET', KEYS[1], 'device', ARGV[1], 'verdict', 'ended')
  redis.call('EXPIRE', KEYS[1], ARGV[3])
end
return {1, owner or '', verdict or ''}
`;

/** Both shipped decoders can read each device copy; neither needs a coordinated upgrade. */
export function callKeyDeliveryFrames(callId: string, fromUserId: string, senderDeviceId: string,
  copies: Array<{ device_id: string; body: string }>): string[] {
  return copies.map(copy => JSON.stringify({
    type: 'call_key', call_id: callId, from_user_id: fromUserId, sender_device_id: senderDeviceId,
    device_id: copy.device_id, ciphertext: copy.body, ciphertexts: [copy],
  }));
}
