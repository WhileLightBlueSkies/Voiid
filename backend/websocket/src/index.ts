// VOIID WebSocket relay (Phase 0 realtime flow, Section 10).
// Connect with JWT -> SUBSCRIBE channel:user:{id} -> in-memory socket_map.
// On Redis message for a user, push the wake/ciphertext-ref down their live socket.
// Unauthenticated sockets are rejected (Section 4.6).
import { WebSocketServer, WebSocket } from 'ws';
import jwt from 'jsonwebtoken';
import Redis from 'ioredis';

const JWT_SECRET = process.env.JWT_SECRET ?? 'dev-only-change-me';
const port = Number(process.env.WS_PORT) || 4001;

// socket_map: user_id -> set of live sockets on THIS instance.
const socketMap = new Map<string, Set<WebSocket>>();

// Subscriber connection: one shared sub, pattern-subscribe to user channels routed here.
const sub = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6379');
const presence = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6379');

sub.psubscribe('channel:user:*');
sub.on('pmessage', (_pattern, channel, payload) => {
  const userId = channel.replace('channel:user:', '');
  const sockets = socketMap.get(userId);
  if (!sockets) return; // socket lives on another instance; that instance delivers it
  for (const ws of sockets) {
    if (ws.readyState === WebSocket.OPEN) ws.send(payload);
  }
});

const wss = new WebSocketServer({ port });

wss.on('connection', (ws, req) => {
  // JWT via ?token= or Sec-WebSocket-Protocol; reject if absent/invalid.
  const url = new URL(req.url ?? '', 'http://localhost');
  const token = url.searchParams.get('token');
  let userId: string;
  try {
    userId = (jwt.verify(token ?? '', JWT_SECRET) as { user_id: string }).user_id;
  } catch {
    ws.close(4401, 'unauthorized');
    return;
  }

  if (!socketMap.has(userId)) socketMap.set(userId, new Set());
  socketMap.get(userId)!.add(ws);

  // presence: user online with heartbeat TTL
  presence.set(`user:${userId}:online`, '1', 'EX', 60);

  ws.on('message', (raw) => {
    // typing indicators / heartbeats / read receipts arrive here (handled in Phase 2 layer 2)
    try {
      const msg = JSON.parse(raw.toString());
      if (msg.type === 'heartbeat') {
        presence.set(`user:${userId}:online`, '1', 'EX', 60);
      }
    } catch { /* ignore malformed frames */ }
  });

  ws.on('close', () => {
    const set = socketMap.get(userId);
    set?.delete(ws);
    if (set && set.size === 0) {
      socketMap.delete(userId);
      presence.set(`user:${userId}:last_seen`, Date.now().toString());
      presence.del(`user:${userId}:online`);
    }
  });

  ws.send(JSON.stringify({ type: 'connected', user_id: userId }));
});

console.log(`[voiid:ws] listening on :${port}`);
