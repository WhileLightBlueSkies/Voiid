// GIF search — a thin proxy in front of Tenor.
//
// WHY PROXY instead of calling Tenor from the app:
//   1. The API key never ships inside the binary, where anyone can extract it from an IPA/APK
//      and burn our quota.
//   2. Users' GIF searches do not go straight to Google carrying their IP. Tenor sees our
//      server, not "someone in Pune searched for X at 14:02".
//
// TENOR, NOT GIPHY. Tenor is free with no hard public cap and needs no attribution badge;
// GIPHY's free tier rate-limits at ~1k/day and mandates a "Powered By GIPHY" mark on screen.
//
// WHAT THIS ROUTE RETURNS is a list of GIF URLs. The CLIENT then downloads the chosen GIF,
// ENCRYPTS it, and uploads the ciphertext to R2 as an ordinary media message — so recipients
// never touch Tenor at all. Their IPs stay private, and the GIF keeps working even if Tenor
// removes it. That download-and-encrypt step is the whole reason this returns URLs rather
// than proxying the bytes.
import { Router } from 'express';
import { requireAuth } from '../auth';
import { asyncHandler } from '../util';

const router = Router();

const TENOR_KEY = process.env.TENOR_API_KEY;
// Tenor asks for a stable client key per integration so it can separate our traffic.
const CLIENT_KEY = process.env.TENOR_CLIENT_KEY ?? 'voiid';

/** One GIF, flattened to what a client actually needs to render and send. */
interface Gif {
  id: string;
  /** Full-size MP4-quality GIF — what gets downloaded, encrypted and sent. */
  url: string;
  /** Small looping preview for the picker grid. Never sent to anyone. */
  preview: string;
  width: number;
  height: number;
  /** Alt text from Tenor, used as the accessibility label. */
  description: string;
}

/**
 * Tenor's response nests every rendition under `media_formats`. We flatten to the two we use
 * — `gif` for sending, `tinygif` for the grid — so the client never has to know Tenor's shape
 * and swapping providers later touches only this file.
 */
function flatten(results: any[]): Gif[] {
  const out: Gif[] = [];
  for (const r of results ?? []) {
    const full = r?.media_formats?.gif ?? r?.media_formats?.mediumgif;
    const tiny = r?.media_formats?.tinygif ?? full;
    if (!full?.url || !tiny?.url) continue;
    out.push({
      id: String(r.id ?? full.url),
      url: full.url,
      preview: tiny.url,
      width: Number(full.dims?.[0] ?? 0),
      height: Number(full.dims?.[1] ?? 0),
      description: String(r.content_description ?? ''),
    });
  }
  return out;
}

async function tenor(path: string, params: Record<string, string>): Promise<Gif[]> {
  const qs = new URLSearchParams({
    key: TENOR_KEY as string,
    client_key: CLIENT_KEY,
    // Tenor's "high" filter excludes explicit content. This is a messaging app used by
    // people's families; the default (off) is not an acceptable posture.
    contentfilter: 'high',
    media_filter: 'gif,tinygif',
    limit: '30',
    ...params,
  });
  const res = await fetch(`https://tenor.googleapis.com/v2/${path}?${qs}`);
  if (!res.ok) throw new Error(`tenor ${res.status}`);
  const body: any = await res.json();
  return flatten(body?.results);
}

// ─────────────────────────────────────────────────────────────────────────────────
// GET /gifs/search?q=…   → { gifs: [...] }
// GET /gifs/trending     → { gifs: [...] }   (an empty q falls through to trending)
//
// Auth-gated: this costs us quota, so it is not an open endpoint.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/search', requireAuth, asyncHandler(async (req, res) => {
  if (!TENOR_KEY) {
    // Degrade HONESTLY. A build with no key returns empty plus a flag, so the client can say
    // "GIFs aren't set up" instead of showing an endless spinner.
    return res.json({ gifs: [], configured: false });
  }
  const q = String(req.query.q ?? '').trim();
  try {
    const gifs = q
      ? await tenor('search', { q })
      : await tenor('featured', {});
    res.json({ gifs, configured: true });
  } catch (e) {
    console.warn('[gifs] tenor request failed:', (e as Error).message);
    // Never 500 for a GIF search — the composer must stay usable.
    res.json({ gifs: [], configured: true });
  }
}));

router.get('/trending', requireAuth, asyncHandler(async (_req, res) => {
  if (!TENOR_KEY) return res.json({ gifs: [], configured: false });
  try {
    res.json({ gifs: await tenor('featured', {}), configured: true });
  } catch (e) {
    console.warn('[gifs] tenor trending failed:', (e as Error).message);
    res.json({ gifs: [], configured: true });
  }
}));

export default router;
