// Redis behind a thin module so Redis -> NATS/Centrifugo is swappable at scale (Section 2.2).
import Redis from 'ioredis';

export const redisOptions = {
  connectTimeout: 1500, commandTimeout: 1500, enableOfflineQueue: false,
  maxRetriesPerRequest: 1, retryStrategy: (attempt: number) => Math.min(attempt * 250, 2000),
};
export const redis = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6379', redisOptions);

// Dedicated publisher connection for pub/sub routing of relayed ciphertext.
export const publisher = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6379', redisOptions);
