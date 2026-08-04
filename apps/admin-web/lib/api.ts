//
// The admin panel's API client.
//
// SESSION IN sessionStorage, NOT localStorage. A moderation session that survives closing
// the tab is a session left open on a shared or unattended machine — and this token can take
// content down. sessionStorage dies with the tab, which is the behaviour an admin plane
// should have. The server-side 12-hour expiry is the backstop, not the primary control.
//
// No cookie, and therefore no CSRF surface: the token is attached explicitly as a header, so
// a malicious page cannot make the browser send it on the panel's behalf.
//

const BASE = process.env.NEXT_PUBLIC_API_BASE ?? 'https://api-dev.voiid.app';
const TOKEN_KEY = 'voiid.admin.token';

export function getToken(): string | null {
  if (typeof window === 'undefined') return null;
  return sessionStorage.getItem(TOKEN_KEY);
}

export function setToken(token: string) {
  sessionStorage.setItem(TOKEN_KEY, token);
}

export function clearToken() {
  sessionStorage.removeItem(TOKEN_KEY);
}

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

export async function api<T>(
  path: string,
  init: RequestInit & { json?: unknown } = {},
): Promise<T> {
  const token = getToken();
  const headers: Record<string, string> = {
    ...(init.headers as Record<string, string> | undefined),
  };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (init.json !== undefined) headers['Content-Type'] = 'application/json';

  const res = await fetch(`${BASE}/admin${path}`, {
    ...init,
    headers,
    body: init.json !== undefined ? JSON.stringify(init.json) : init.body,
  });

  // A 401 means the session is gone — expired, revoked, or the admin was disabled. Clear it
  // and bounce to login rather than letting every subsequent call fail the same way.
  if (res.status === 401) {
    clearToken();
    if (typeof window !== 'undefined' && !window.location.pathname.startsWith('/login')) {
      window.location.href = '/login';
    }
    throw new ApiError(401, 'session expired');
  }

  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new ApiError(res.status, body.error ?? `request failed (${res.status})`);
  }
  return res.json() as Promise<T>;
}
