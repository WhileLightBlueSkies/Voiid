// GET /config — server-driven version negotiation + feature flags + force-update.
// The client calls this on launch (UNVERSIONED, before it knows which version to
// use). It returns the API version to use, the min supported app version, whether
// THIS client must update, feature flags (toggle features without an app update),
// and the SDUI seam for clips/video.
//
// Feature flags / SDUI here are server-driven so we can flip them without shipping
// a build. SDUI is scoped to clips ONLY — calls, groups, auth, navigation and all
// crypto/message handling stay native and are never server-driven.
import { Router } from 'express';
import {
  CURRENT_API_VERSION, SUPPORTED_API_VERSIONS, minSupportedApp,
  readClient, isUpdateRequired, APP_STORE_URL, PLAY_STORE_URL,
} from '../version';

const router = Router();

router.get('/', (req, res) => {
  const client = readClient(req);
  res.json({
    api_version: CURRENT_API_VERSION,
    supported_api_versions: SUPPORTED_API_VERSIONS,
    min_supported_app: minSupportedApp(),
    force_update: isUpdateRequired(client),
    store_url: { ios: APP_STORE_URL, android: PLAY_STORE_URL },
    // Server-toggled features — gate UI on these so we can dark-launch / kill-switch.
    feature_flags: {
      direct_messaging: true,
      media: true,
      voice_notes: true,
      receipts: true,
      presence: true,
      contacts: true,
      groups: false,        // MLS not shipped yet
      calls: false,
      clips: false,
    },
    // SDUI seam — CLIPS/VIDEO ONLY. Until Clips is built this is disabled and the
    // app falls back to native. When enabled, `screens` carries server UI defs.
    sdui: {
      clips_enabled: false,
      version: 0,
      screens: {},
    },
  });
});

export default router;
