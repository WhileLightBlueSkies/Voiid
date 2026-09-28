'use client';

import { useRef, useState, type ComponentType } from 'react';
import { Glyph } from '../Glyph';

type SandboxComponent = ComponentType<{ onClose: () => void }>;

export function AppSandboxLauncher({ className }: { className?: string }) {
  const [Sandbox, setSandbox] = useState<SandboxComponent | null>(null);
  const [loading, setLoading] = useState(false);
  const [failed, setFailed] = useState(false);
  const launchRef = useRef<HTMLButtonElement>(null);

  const open = async () => {
    setLoading(true);
    setFailed(false);
    try {
      const module = await import('./AppSandbox');
      setSandbox(() => module.AppSandbox);
    } catch {
      setFailed(true);
    } finally {
      setLoading(false);
    }
  };

  const close = () => {
    setSandbox(null);
    requestAnimationFrame(() => launchRef.current?.focus());
  };

  return (
    <>
      <button
        ref={launchRef}
        type="button"
        className={className}
        onClick={open}
        disabled={loading}
      >
        {loading ? 'Opening the app…' : 'Go through the app'}
        <Glyph name="arrow-right" size={18} />
      </button>
      {failed ? (
        <span role="status">
          The tour did not load. <a href="#features">Explore the features instead.</a>
        </span>
      ) : null}
      {Sandbox ? <Sandbox onClose={close} /> : null}
    </>
  );
}
