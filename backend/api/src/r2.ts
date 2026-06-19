// Cloudflare R2 (S3-compatible) client for media blobs. Media is E2E-encrypted
// ON-DEVICE before upload — the server only ever sees ciphertext, and never the
// bytes themselves: clients PUT/GET directly to R2 via short-lived presigned
// URLs that this module signs.
//
// Config (env, set on the box .env):
//   R2_ENDPOINT           https://<account>.r2.cloudflarestorage.com
//   R2_ACCESS_KEY_ID      S3 access key id (R2 API token)
//   R2_SECRET_ACCESS_KEY  S3 secret access key
//   R2_BUCKET             bucket name (e.g. voiid-media-dev)
import { S3Client, PutObjectCommand, GetObjectCommand, HeadObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

const endpoint = process.env.R2_ENDPOINT;
const accessKeyId = process.env.R2_ACCESS_KEY_ID;
const secretAccessKey = process.env.R2_SECRET_ACCESS_KEY;
export const R2_BUCKET = process.env.R2_BUCKET ?? '';

/** Whether R2 is configured (all required env present). Surfaced in /health. */
export function r2Configured(): boolean {
  return !!(endpoint && accessKeyId && secretAccessKey && R2_BUCKET);
}

let client: S3Client | null = null;
function s3(): S3Client {
  if (!r2Configured()) throw new Error('R2 not configured (set R2_ENDPOINT/_ACCESS_KEY_ID/_SECRET_ACCESS_KEY/_BUCKET)');
  if (!client) {
    client = new S3Client({
      region: 'auto', // R2 ignores region but the SDK requires one
      endpoint,
      credentials: { accessKeyId: accessKeyId!, secretAccessKey: secretAccessKey! },
    });
  }
  return client;
}

const PUT_TTL = 300; // 5 min — enough to upload, short enough to limit replay
const GET_TTL = 3600; // 1 hour — download window for a fetched message

/** Presigned PUT URL the client uses to upload encrypted bytes to `key`. */
export function presignPut(key: string, contentType = 'application/octet-stream'): Promise<string> {
  return getSignedUrl(s3(), new PutObjectCommand({ Bucket: R2_BUCKET, Key: key, ContentType: contentType }), {
    expiresIn: PUT_TTL,
  });
}

/** Presigned GET URL the client uses to download encrypted bytes at `key`. */
export function presignGet(key: string): Promise<string> {
  return getSignedUrl(s3(), new GetObjectCommand({ Bucket: R2_BUCKET, Key: key }), { expiresIn: GET_TTL });
}

/** True if an object exists at `key` (used to confirm an upload completed). */
export async function objectExists(key: string): Promise<boolean> {
  try {
    await s3().send(new HeadObjectCommand({ Bucket: R2_BUCKET, Key: key }));
    return true;
  } catch {
    return false;
  }
}
