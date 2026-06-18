// Firebase Admin — verifies the Firebase ID token the CLIENT obtains after it
// completes Phone Auth. Firebase owns OTP send+verify on the client; our server
// only validates the resulting token and then issues OUR JWT (identity is ours).
//
// Config (env): FIREBASE_SERVICE_ACCOUNT = the service-account JSON (stringified)
// or FIREBASE_SERVICE_ACCOUNT_PATH = path to the JSON file.
//
// Dev bypass: if AUTH_DEV_BYPASS=1 (development only), a token of the form
// "dev:<phone>" is accepted without Firebase, so the full login + chat flow is
// testable before Firebase is wired. NEVER enable this in production.

import { readFileSync } from 'fs';

let adminApp: import('firebase-admin/app').App | null = null;
let initTried = false;

function getAdmin() {
  if (initTried) return adminApp;
  initTried = true;
  try {
    // Lazy require so the API still boots if firebase-admin isn't needed in dev.
    const { initializeApp, cert, getApps } =
      require('firebase-admin/app') as typeof import('firebase-admin/app');

    if (getApps().length) {
      adminApp = getApps()[0];
      return adminApp;
    }

    const json = process.env.FIREBASE_SERVICE_ACCOUNT;
    const path = process.env.FIREBASE_SERVICE_ACCOUNT_PATH;
    const raw = json ?? (path ? readFileSync(path, 'utf8') : null);
    if (!raw) {
      console.warn('[firebase] no service account configured; only dev bypass will work');
      return null;
    }
    adminApp = initializeApp({ credential: cert(JSON.parse(raw)) });
    return adminApp;
  } catch (e) {
    console.warn('[firebase] admin init failed:', (e as Error).message);
    return null;
  }
}

/**
 * Diagnostic for /health: reports whether the Firebase Admin SDK is configured
 * and initializes successfully (i.e. the server CAN verify real tokens). No
 * secrets are returned — just status + the project_id it loaded (handy to catch
 * a service-account-from-wrong-project mismatch).
 */
export function firebaseStatus(): { configured: boolean; project_id: string | null; error?: string } {
  const hasEnv = !!(process.env.FIREBASE_SERVICE_ACCOUNT || process.env.FIREBASE_SERVICE_ACCOUNT_PATH);
  if (!hasEnv) return { configured: false, project_id: null, error: 'no FIREBASE_SERVICE_ACCOUNT(_PATH) set' };
  try {
    const app = getAdmin();
    if (!app) return { configured: false, project_id: null, error: 'admin init failed (see logs)' };
    const projectId = (app.options.credential as any)?.projectId
      ?? (app.options as any)?.projectId ?? null;
    return { configured: true, project_id: projectId };
  } catch (e) {
    return { configured: false, project_id: null, error: (e as Error).message };
  }
}

export interface VerifiedPhone {
  phone_number: string;
  firebase_uid?: string;
}

/**
 * Verify a Firebase ID token and return the user's phone number. Throws on an
 * invalid/expired token or a token without a phone number.
 */
export async function verifyFirebaseToken(idToken: string): Promise<VerifiedPhone> {
  // Dev bypass (development only): accept "dev:<phone>".
  if (
    process.env.AUTH_DEV_BYPASS === '1' &&
    process.env.NODE_ENV !== 'production' &&
    idToken.startsWith('dev:')
  ) {
    const phone = idToken.slice(4).trim();
    if (!phone) throw new Error('dev token missing phone');
    return { phone_number: phone, firebase_uid: `dev:${phone}` };
  }

  const app = getAdmin();
  if (!app) throw new Error('firebase not configured');

  const { getAuth } = require('firebase-admin/auth') as typeof import('firebase-admin/auth');
  const decoded = await getAuth(app).verifyIdToken(idToken);
  const phone = decoded.phone_number;
  if (!phone) throw new Error('token has no phone_number');
  return { phone_number: phone, firebase_uid: decoded.uid };
}
