import { rateLimit } from '../security';
// GIF search — a thin proxy in front of GIPHY.
//
// WHY PROXY instead of calling the provider from the app:
//   1. The API key never ships inside the binary, where anyone can extract it from an IPA/APK
//      and burn our quota.
//   2. Users' GIF searches do not go straight to the provider carrying their IP. GIPHY sees
//      our server, not "someone in Pune searched for X at 14:02".
//
// ONE KEY, NOT ONE PER PLATFORM. GIPHY issues keys per app, so there is an iOS key and an
// Android key — but neither client ever talks to GIPHY. Both call this route, so this route
// holds a single key and the per-platform split does not apply. Putting a key in each app
// would be the exact leak the proxy exists to prevent.
//
// WAS TENOR. Switched on request. The costs that had argued for Tenor are real and now ours:
// GIPHY's free tier is rate-limited (~1k/day, 42/hour on a dev key) where Tenor had no hard
// public cap, and GIPHY's terms require a visible "Powered By GIPHY" attribution mark. The
// dev keys in use now must be swapped for production keys before launch or search will fail
// under real traffic — see docs and the GIPHY dashboard.
//
// WHAT THIS ROUTE RETURNS is a list of GIF URLs. The CLIENT then downloads the chosen GIF,
// ENCRYPTS it, and uploads the ciphertext to R2 as an ordinary media message — so recipients
// never touch GIPHY at all. Their IPs stay private, and the GIF keeps working even if GIPHY
// removes it. That download-and-encrypt step is the whole reason this returns URLs rather
// than proxying the bytes.
import { Router } from 'express';
import { requireAuth } from '../auth';
import { asyncHandler } from '../util';

const router = Router();

// GIPHY_API_KEY is the name going forward. TENOR_API_KEY is NOT read as a fallback: the two
// are different providers' credentials, and silently sending a Tenor key to GIPHY would fail
// as an opaque 401 rather than as "GIFs are not configured".
const GIPHY_KEY = process.env.GIPHY_API_KEY;

/** One GIF, flattened to what a client actually needs to render and send. */
interface Gif {
  id: string;
  /** Full-size GIF — what gets downloaded, encrypted and sent. */
  url: string;
  /** Small looping preview for the picker grid. Never sent to anyone. */
  preview: string;
  width: number;
  height: number;
  /** Alt text, used as the accessibility label. */
  description: string;
}

/**
 * GIPHY nests every rendition under `images`. We flatten to the two we use — `original` for
 * sending, `fixed_width_small` for the grid — so the client never has to know GIPHY's shape
 * and swapping providers again touches only this file. This is the same contract the Tenor
 * version returned, which is why no client code changes.
 */
function flatten(results: any[]): Gif[] {
  const out: Gif[] = [];
  for (const r of results ?? []) {
    const img = r?.images ?? {};
    const full = img.original ?? img.downsized;
    const tiny = img.fixed_width_small ?? img.preview_gif ?? full;
    if (!full?.url || !tiny?.url) continue;
    out.push({
      id: String(r.id ?? full.url),
      url: full.url,
      preview: tiny.url,
      width: Number(full.width ?? 0),
      height: Number(full.height ?? 0),
      // alt_text is the real description; title is a headline like "Tom Hanks Hello GIF" and
      // is the better-than-nothing fallback for a screen reader.
      description: String(r.alt_text || r.title || ''),
    });
  }
  return out;
}

async function giphy(path: string, params: Record<string, string>): Promise<Gif[]> {
  const qs = new URLSearchParams({
    api_key: GIPHY_KEY as string,
    // GIPHY's content ratings run g < pg < pg-13 < r. This is a messaging app used by
    // people's families, so anything above pg-13 is not an acceptable default. (The Tenor
    // equivalent was contentfilter=high.)
    rating: 'pg-13',
    limit: '30',
    bundle: 'messaging_non_clips',
    ...params,
  });
  const res = await fetch(`https://api.giphy.com/v1/gifs/${path}?${qs}`);
  if (!res.ok) throw new Error(`giphy ${res.status}`);
  const body: any = await res.json();
  return flatten(body?.data);
}

// ─────────────────────────────────────────────────────────────────────────────────
// GET /gifs/search?q=…   → { gifs: [...] }
// GET /gifs/trending     → { gifs: [...] }   (an empty q falls through to trending)
//
// Auth-gated: this costs us quota, so it is not an open endpoint.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/search', requireAuth, rateLimit({ max: 180, windowSeconds: 60, bucket: 'gifs' }), asyncHandler(async (req, res) => {
  if (!GIPHY_KEY) {
    // Degrade HONESTLY. A build with no key returns empty plus a flag, so the client can say
    // "GIFs aren't set up" instead of showing an endless spinner.
    return res.json({ gifs: [], configured: false });
  }
  const q = String(req.query.q ?? '').trim();
  try {
    const gifs = q
      ? await giphy('search', { q })
      : await giphy('trending', {});
    res.json({ gifs, configured: true });
  } catch (e) {
    console.warn('[gifs] giphy request failed:', (e as Error).message);
    // Never 500 for a GIF search — the composer must stay usable.
    res.json({ gifs: [], configured: true });
  }
}));

router.get('/trending', requireAuth, rateLimit({ max: 180, windowSeconds: 60, bucket: 'gifs' }), asyncHandler(async (_req, res) => {
  if (!GIPHY_KEY) return res.json({ gifs: [], configured: false });
  try {
    res.json({ gifs: await giphy('trending', {}), configured: true });
  } catch (e) {
    console.warn('[gifs] giphy trending failed:', (e as Error).message);
    res.json({ gifs: [], configured: true });
  }
}));

export default router;
