'use client';

//
// The console's front door.
//
// A login screen is the one page in an admin panel with no data on it, which makes it the
// page most often left as a bare form on a grey field. It is also the first thing anyone
// sees of the product, including the person deciding whether the rest looks trustworthy —
// so it gets the same care as a surface that does carry data.
//
// WHAT IT DELIBERATELY DOES NOT DO
//   * No "forgot password" link. Admin accounts are provisioned, not self-served; a link to
//     a flow that does not exist is worse than no link.
//   * No sign-up. Same reason.
//   * No branding claims about security. A padlock illustration on a login form is
//     decoration pretending to be assurance.
//

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { api, setToken, ApiError } from '../../lib/api';
import { Button } from '../../components/ui/button';
import { Input, Label } from '../../components/ui/input';
import { BrandMark } from '../../components/Brand';

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
    <div className="relative grid min-h-screen place-items-center overflow-hidden p-6">
      {/*
        AMBIENT LIGHT, not a picture. Two wide, very low-opacity accent washes behind the
        card give the page a light source, so the form reads as sitting in a room rather
        than floating on a flat fill. They are pure CSS — no image request on the one page
        that must load before a session exists, and nothing to go stale.
      */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0"
        style={{
          background:
            'radial-gradient(760px circle at 18% 8%, rgba(19,130,140,0.18), transparent 62%),' +
            'radial-gradient(680px circle at 84% 92%, rgba(104,184,189,0.18), transparent 60%)',
        }}
      />
      {/* A faint grid. It gives the empty field a sense of scale — the difference between
          "dark background" and "a surface that extends past the card". Masked to fade out
          before the edges so it never reads as a texture swatch. */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 opacity-[0.35]"
        style={{
          backgroundImage:
            'linear-gradient(rgba(16,22,23,0.05) 1px, transparent 1px),' +
            'linear-gradient(90deg, rgba(16,22,23,0.05) 1px, transparent 1px)',
          backgroundSize: '52px 52px',
          maskImage: 'radial-gradient(ellipse 70% 60% at 50% 45%, #000 30%, transparent 78%)',
          WebkitMaskImage: 'radial-gradient(ellipse 70% 60% at 50% 45%, #000 30%, transparent 78%)',
        }}
      />

      <div className="relative w-full max-w-[400px]">
        {/* The mark sits ABOVE the card rather than inside it. The card is the task; the
            identity is context, and stacking them lets the form start at its own first
            line instead of a third of the way down. */}
        <div className="mb-7 flex items-center gap-2.5">
          <BrandMark size={32} />
          <div className="leading-tight">
            <div className="text-[15px] font-semibold tracking-[-0.01em]">Voiid</div>
            <div className="text-tiny text-[var(--text-mute)]">Operations console</div>
          </div>
        </div>

        <form
          onSubmit={submit}
          className="rounded-[28px] border border-black/[0.04] bg-card p-7"
          style={{
            boxShadow: 'var(--shadow-2)',
          }}
        >
          <h1 className="mb-1 text-[17px] font-semibold tracking-[-0.015em]">Sign in</h1>
          <p className="mb-6 text-sm text-[var(--text-mute)]">
            Internal access only. Sessions end when this tab closes.
          </p>

          <div className="mb-4 space-y-1.5">
            <Label htmlFor="email" className="text-[var(--text-dim)]">Email</Label>
            <Input
              id="email" type="email" value={email} autoComplete="username" required
              autoFocus placeholder="you@voiid.app"
              onChange={(e) => setEmail(e.target.value)}
            />
          </div>

          <div className="mb-5 space-y-1.5">
            <Label htmlFor="password" className="text-[var(--text-dim)]">Password</Label>
            <Input
              id="password" type="password" value={password} autoComplete="current-password"
              required placeholder="••••••••••••"
              onChange={(e) => setPassword(e.target.value)}
            />
          </div>

          {/* role="alert" so the failure is ANNOUNCED, not merely drawn. A sighted user sees
              the red; a screen-reader user would otherwise submit into silence. */}
          {error && (
            <div
              role="alert"
              className="mb-5 rounded-md border px-3 py-2.5 text-sm"
              style={{
                borderColor: 'rgba(248,113,113,0.28)',
                background: 'rgba(248,113,113,0.09)',
                color: 'var(--danger)',
              }}
            >
              {error}
            </div>
          )}

          <Button type="submit" disabled={busy} className="w-full" size="lg">
            {busy ? 'Signing in…' : 'Sign in'}
          </Button>
        </form>

        {/* The session rule, stated where it is relevant rather than discovered later. It is
            also the honest reason this console feels different from a consumer app: closing
            the tab really does end the session. */}
        <p className="mt-5 text-center text-tiny text-[var(--text-mute)]">
          Access is provisioned by an administrator.
        </p>
      </div>
    </div>
  );
}
