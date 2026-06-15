// Redis behind a thin module so Redis -> NATS/Centrifugo is swappable at scale (Section 2.2).
import Redis from 'ioredis';

export const redis = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6379');

// Dedicated publisher connection for pub/sub routing of relayed ciphertext.
export const publisher = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6379');
