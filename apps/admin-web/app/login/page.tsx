'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { api, setToken, ApiError } from '../../lib/api';

export default function Login() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const router = useRouter();

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const r = await api<{ token: string }>('/login', { json: { email, password } });
      setToken(r.token);
      router.replace('/');
    } catch (err) {
      // ONE message for every CREDENTIAL outcome — distinguishing "no such admin" from
      // "wrong password" tells an attacker which half they got right.
      //
      // But a transport failure is not a credential outcome, and folding the two together
      // is how a 404 from a wrong HTTP method spent an afternoon looking like a bad
      // password. Anything that is not a 401 says so, without saying anything about the
      // account.
      const status = err instanceof ApiError ? err.status : 0;
      setError(
        status === 401 || status === 403
          ? 'Those details did not work.'
          : status === 429
            ? 'Too many attempts. Wait a minute and try again.'
            : `Could not reach the server (${status || 'network error'}).`,
      );
    } finally {
      setBusy(false);
    }
  }

  return (
    <div style={{ minHeight: '100vh', display: 'grid', placeItems: 'center', padding: 24 }}>
      <form onSubmit={submit} className="card" style={{ width: '100%', maxWidth: 380, padding: 26 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 9, marginBottom: 6 }}>
          <span style={{ width: 10, height: 10, borderRadius: 3, background: 'var(--accent)' }} />
          <strong>Voiid</strong>
          <span className="mute" style={{ fontSize: 13 }}>Admin</span>
        </div>
        <p className="muted" style={{ margin: '0 0 20px', fontSize: 14 }}>
          Internal operations console.
        </p>

        <label className="mute" style={{ fontSize: 13 }}>Email</label>
        <input
          type="email" value={email} autoComplete="username" required
          onChange={(e) => setEmail(e.target.value)} style={{ margin: '6px 0 14px' }}
        />

        <label className="mute" style={{ fontSize: 13 }}>Password</label>
        <input
          type="password" value={password} autoComplete="current-password" required
          onChange={(e) => setPassword(e.target.value)} style={{ margin: '6px 0 18px' }}
        />

        {error && <div className="notice error" style={{ marginBottom: 14 }}>{error}</div>}

        <button type="submit" disabled={busy} style={{ width: '100%' }}>
          {busy ? 'Signing in…' : 'Sign in'}
        </button>
      </form>
    </div>
  );
}
