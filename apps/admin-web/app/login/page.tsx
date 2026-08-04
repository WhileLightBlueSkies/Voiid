'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { api, setToken } from '@/lib/api';

export default function LoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const res = await api<{ token: string }>('/login', {
        method: 'POST',
        json: { email, password },
      });
      setToken(res.token);
      router.push('/');
    } catch {
      // ONE message for every failure, matching the server. Distinguishing "no such admin"
      // from "wrong password" would turn this form into a way to discover which emails are
      // admins.
      setError('Invalid email or password.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <main style={{ display: 'grid', placeItems: 'center', minHeight: '100vh', padding: 24 }}>
      <form onSubmit={submit} className="card" style={{ width: 360, padding: 28 }}>
        <h1 style={{ margin: '0 0 4px', fontSize: 22 }}>Voiid Admin</h1>
        <p style={{ margin: '0 0 22px', color: 'var(--text-dim)', fontSize: 13 }}>
          Moderation and monitoring.
        </p>

        <label style={{ fontSize: 13, color: 'var(--text-dim)' }}>Email</label>
        <input
          type="email" value={email} onChange={(e) => setEmail(e.target.value)}
          autoComplete="username" required style={{ margin: '6px 0 14px' }}
        />

        <label style={{ fontSize: 13, color: 'var(--text-dim)' }}>Password</label>
        <input
          type="password" value={password} onChange={(e) => setPassword(e.target.value)}
          autoComplete="current-password" required style={{ margin: '6px 0 18px' }}
        />

        {error && (
          <p style={{ color: 'var(--danger)', fontSize: 13, margin: '0 0 14px' }}>{error}</p>
        )}

        <button type="submit" disabled={busy} style={{ width: '100%' }}>
          {busy ? 'Signing in…' : 'Sign in'}
        </button>
      </form>
    </main>
  );
}
