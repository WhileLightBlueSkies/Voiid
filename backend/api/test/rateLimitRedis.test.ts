import test from 'node:test';
import assert from 'node:assert/strict';
import Redis from 'ioredis';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { RATE_LIMIT_SCRIPT } from '../src/security';
import { redis, publisher } from '../src/redis';
redis.disconnect(); publisher.disconnect();
const binary = process.env.REDIS_TEST_SERVER;
test('atomic fixed window across connections repairs missing TTL and starts a new window', { skip: !binary }, async () => {
  const dir = await mkdtemp(join(tmpdir(), 'voiid-redis-test-'));
  const socket = join(dir, 'redis.sock');
  const server = spawn(binary!, ['--port', '0', '--unixsocket', socket, '--save', '', '--appendonly', 'no']);
  const clients: Redis[] = [];
  try {
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Redis startup timed out')), 5000);
      server.on('error', reject);
      server.stdout.on('data', chunk => { if (chunk.toString().includes('ready to accept connections') || chunk.toString().includes('Ready to accept connections')) { clearTimeout(timer); resolve(); } });
    });
    const a = new Redis(socket), b = new Redis(socket); clients.push(a, b);
    const counts = await Promise.all(Array.from({ length: 60 }, (_, i) => (i % 2 ? a : b).eval(RATE_LIMIT_SCRIPT, 1, 'limit', 30000) as Promise<number[]>));
    assert.deepEqual(counts.map(x => x[0]).sort((a,b) => a-b), Array.from({ length: 60 }, (_, i) => i+1));
    assert.ok(await a.pttl('limit') > 0);
    await a.set('immortal', '8');
    assert.equal(await a.pttl('immortal'), -1);
    assert.deepEqual(await b.eval(RATE_LIMIT_SCRIPT, 1, 'immortal', 5000), [9, 5000]);
    await a.pexpire('limit', 1);
    // Wait for the observed expiry, not a guessed wall-clock boundary.
    while (await b.exists('limit')) await new Promise(resolve => setTimeout(resolve, 2));
    assert.deepEqual(await a.eval(RATE_LIMIT_SCRIPT, 1, 'limit', 30000), [1, 30000]);
  } finally {
    clients.forEach(c => c.disconnect());
    server.kill('SIGTERM');
    await new Promise(resolve => server.once('exit', resolve));
    await rm(dir, { recursive: true, force: true });
  }
});
