// Cloudflare R2 (S3-compatible) delete client for the reaper.
//
// WHY this duplicates ~30 lines of backend/api/src/r2.ts: see src/db.ts — the worker
// stays independent of @voiid/api so it can be restarted, deployed and crashed on its
// own. It reads the SAME R2_* env as the API.
//
// This module can ONLY delete. It has no Put/Get/presign surface, because a background
// job has no business minting URLs or touching bytes. And it never READS an object:
// story ciphertext is meaningless to the server, and downloading it would be the one
// way this process could ever hold user media.
import { S3Client, DeleteObjectCommand } from '@aws-sdk/client-s3';

const endpoint = process.env.R2_ENDPOINT;
const accessKeyId = process.env.R2_ACCESS_KEY_ID;
const secretAccessKey = process.env.R2_SECRET_ACCESS_KEY;
const R2_BUCKET = process.env.R2_BUCKET ?? '';

/** Whether R2 is configured (all required env present). Surfaced on /health. */
export function r2Configured(): boolean {
  return !!(endpoint && accessKeyId && secretAccessKey && R2_BUCKET);
}

let client: S3Client | null = null;
function s3(): S3Client {
  if (!r2Configured()) {
    throw new Error('R2 not configured (set R2_ENDPOINT/_ACCESS_KEY_ID/_SECRET_ACCESS_KEY/_BUCKET)');
  }
  if (!client) {
    client = new S3Client({
      region: 'auto', // R2 ignores region but the SDK requires one
      endpoint,
      credentials: { accessKeyId: accessKeyId!, secretAccessKey: secretAccessKey! },
    });
  }
  return client;
}

/**
 * Delete the object at `key`. Idempotent — S3/R2 DeleteObject succeeds for a key that
 * is already gone, so a retry (or two worker instances racing on the same row) is safe.
 */
export async function deleteObject(key: string): Promise<void> {
  await s3().send(new DeleteObjectCommand({ Bucket: R2_BUCKET, Key: key }));
}
