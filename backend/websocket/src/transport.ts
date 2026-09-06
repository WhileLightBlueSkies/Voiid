import { WebSocket } from 'ws';

export const MAX_OUTBOUND_BYTES = 512 * 1024;
/** Disposable hints are coalesced by dropping them under pressure; durable wakes replay via API. */
export function boundedSend(ws: WebSocket, payload: string): boolean {
  if (ws.readyState !== WebSocket.OPEN) return false;
  const bytes = Buffer.byteLength(payload);
  if (ws.bufferedAmount + bytes > MAX_OUTBOUND_BYTES) {
    ws.terminate();
    return false;
  }
  if (ws.bufferedAmount > MAX_OUTBOUND_BYTES / 2) {
    try {
      if (['typing', 'loc_update'].includes(JSON.parse(payload).type)) return false;
    } catch { /* opaque wake */ }
  }
  ws.send(payload, error => { if (error) ws.terminate(); });
  return true;
}

// Redis TIME makes leases independent of relay host clock skew. The legacy online key
// remains compatible with API readers and expires at the last connection's deadline.
export const PRESENCE_SCRIPT = `
local clock = redis.call('TIME')
local now = clock[1] * 1000 + math.floor(clock[2] / 1000)
redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', now)
if ARGV[2] == 'remove' then
  redis.call('ZREM', KEYS[1], ARGV[1])
else
  if not redis.call('ZSCORE', KEYS[1], ARGV[1]) and redis.call('ZCARD', KEYS[1]) >= tonumber(ARGV[4]) then return 0 end
  redis.call('ZADD', KEYS[1], now + tonumber(ARGV[3]), ARGV[1])
end
local last = redis.call('ZREVRANGE', KEYS[1], 0, 0, 'WITHSCORES')
if #last == 0 then
  redis.call('DEL', KEYS[1], KEYS[2])
else
  local ttl = math.max(1, tonumber(last[2]) - now)
  redis.call('PEXPIRE', KEYS[1], ttl)
  redis.call('SET', KEYS[2], '1', 'PX', ttl)
end
redis.call('SET', KEYS[3], tostring(now))
return 1
`;

/** Atomic per-user frame/byte allowance shared by all devices and relay instances. */
export const FRAME_BUDGET_SCRIPT = `
local frames = redis.call('HINCRBY', KEYS[1], 'frames', 1)
local bytes = redis.call('HINCRBY', KEYS[1], 'bytes', ARGV[1])
if frames == 1 then redis.call('PEXPIRE', KEYS[1], ARGV[4]) end
if frames > tonumber(ARGV[2]) or bytes > tonumber(ARGV[3]) then return 0 end
return 1
`;
