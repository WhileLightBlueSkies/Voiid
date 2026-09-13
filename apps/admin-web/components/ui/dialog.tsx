'use client';

//
// A modal that replaces window.prompt / window.confirm for consequential actions.
//
// WHY THE BROWSER PRIMITIVES HAD TO GO
// ====================================
// window.prompt is the wrong control for the most consequential moment on a page. It cannot
// be styled, so the one dialog an operator should read carefully looks like a phishing
// artefact from 1998. It blocks the entire tab, including the rows the operator is trying to
// check while deciding. It cannot validate — a reason that is only whitespace returns as a
// truthy string, and the server rejects it after the round trip. And it cannot explain WHY
// the field is required, which is precisely what a moderator hesitating over a takedown
// needs to read.
//
// APPLE'S RULES THIS FOLLOWS (see the apple-design skill)
//   * Dim to focus. A modal task pairs its surface with a scrim and pushes the page back;
//     this is a blocking decision, so it earns one.
//   * Materialize, don't fade. The panel scales from 0.97 with its blur, so it reads as a
//     surface arriving rather than an opacity ramp.
//   * Respond on press, and never trap the user: Escape and the scrim both dismiss, and the
//     destructive path is never the default focus.
//   * Reduced motion gets a cross-fade, not a slide — gentler, not absent.
//

import { useEffect, useRef, useState } from 'react';
import { Button } from './button';
import { Textarea } from './input';

export function PromptDialog({
  open, title, body, label, placeholder, confirmLabel, destructive, busy,
  requireReason = true, onConfirm, onCancel,
}: {
  open: boolean;
  title: string;
  body?: string;
  label: string;
  placeholder?: string;
  confirmLabel: string;
  destructive?: boolean;
  busy?: boolean;
  /** False where a note is genuinely optional — a reinstatement, say. */
  requireReason?: boolean;
  onConfirm: (reason: string) => void;
  onCancel: () => void;
}) {
  const [value, setValue] = useState('');
  const ref = useRef<HTMLTextAreaElement>(null);

  // Clear on each open. A reason left over from the previous action is the worst possible
  // default: it is plausible text, attached to the wrong decision, already typed.
  useEffect(() => {
    if (open) {
      setValue('');
      // Focus the FIELD, not the confirm button — the destructive action must never be one
      // keystroke from a reflexive Return.
      const t = setTimeout(() => ref.current?.focus(), 40);
      return () => clearTimeout(t);
    }
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onCancel();
      // Cmd/Ctrl+Return commits, because the field is a textarea and plain Return must stay
      // a newline. Discoverable from the hint under the buttons.
      if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && (!requireReason || value.trim())) {
        onConfirm(value.trim());
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open, value, requireReason, onConfirm, onCancel]);

  if (!open) return null;
  const ready = !busy && (!requireReason || value.trim().length > 0);

  return (
    <div
      className="fixed inset-0 z-50 grid place-items-center p-5"
      role="dialog"
      aria-modal="true"
      aria-label={title}
    >
      {/* The scrim carries the blur, so the page behind recedes as a MATERIAL rather than
          merely darkening — and clicking it is the same as cancelling, which is the
          behaviour every modal on every platform has taught. */}
      <div
        className="absolute inset-0 animate-in fade-in duration-150"
        style={{ background: 'rgba(4,8,12,0.62)', backdropFilter: 'blur(3px)' }}
        onClick={busy ? undefined : onCancel}
      />
      <div
        className="relative w-full max-w-[440px] rounded-lg border border-border bg-card p-5
                   animate-in fade-in zoom-in-95 duration-150"
        style={{
          backgroundImage: 'linear-gradient(180deg, rgba(255,255,255,0.05), rgba(255,255,255,0) 120px)',
          boxShadow: '0 24px 60px -20px rgba(0,0,0,0.85)',
        }}
      >
        <h2 className="m-0 text-[15px] font-semibold tracking-[-0.01em]">{title}</h2>
        {body && (
          <p className="m-0 mt-1.5 text-sm leading-relaxed text-[var(--text-dim)]">{body}</p>
        )}

        <label className="mt-4 block">
          <span className="mb-1.5 block text-tiny font-medium text-[var(--text-dim)]">
            {label}
            {requireReason && <span className="ml-1 text-[var(--attention)]">required</span>}
          </span>
          <Textarea
            ref={ref}
            rows={3}
            value={value}
            placeholder={placeholder}
            disabled={busy}
            onChange={(e) => setValue(e.target.value)}
          />
        </label>

        <div className="mt-4 flex items-center gap-2">
          <Button variant="ghost" size="sm" disabled={busy} onClick={onCancel}>Cancel</Button>
          <span className="flex-1" />
          <span className="mono text-micro text-[var(--text-mute)]">⌘↵</span>
          <Button
            size="sm"
            variant={destructive ? 'destructive' : 'default'}
            disabled={!ready}
            onClick={() => onConfirm(value.trim())}
          >
            {busy ? 'Working…' : confirmLabel}
          </Button>
        </div>
      </div>
    </div>
  );
}

/**
 * A confirmation with no free-text field, for an action whose only question is "are you
 * sure" — signing every device out, starting an erasure.
 *
 * Kept SEPARATE from PromptDialog rather than making its reason optional. A dialog with a
 * field the operator may leave blank teaches that the field does not matter, and the next
 * dialog they meet — where it does — inherits that lesson.
 */
export function ConfirmDialog({
  open, title, body, confirmLabel, destructive, busy, onConfirm, onCancel,
}: {
  open: boolean; title: string; body?: string; confirmLabel: string;
  destructive?: boolean; busy?: boolean; onConfirm: () => void; onCancel: () => void;
}) {
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onCancel(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open, onCancel]);

  if (!open) return null;
  return (
    <div className="fixed inset-0 z-50 grid place-items-center p-5"
         role="alertdialog" aria-modal="true" aria-label={title}>
      <div
        className="absolute inset-0 animate-in fade-in duration-150"
        style={{ background: 'rgba(4,8,12,0.62)', backdropFilter: 'blur(3px)' }}
        onClick={busy ? undefined : onCancel}
      />
      <div
        className="relative w-full max-w-[400px] rounded-lg border border-border bg-card p-5
                   animate-in fade-in zoom-in-95 duration-150"
        style={{
          backgroundImage: 'linear-gradient(180deg, rgba(255,255,255,0.05), rgba(255,255,255,0) 110px)',
          boxShadow: '0 24px 60px -20px rgba(0,0,0,0.85)',
        }}
      >
        <h2 className="m-0 text-[15px] font-semibold tracking-[-0.01em]">{title}</h2>
        {body && <p className="m-0 mt-1.5 text-sm leading-relaxed text-[var(--text-dim)]">{body}</p>}
        <div className="mt-5 flex items-center gap-2">
          <Button variant="ghost" size="sm" disabled={busy} onClick={onCancel}>Cancel</Button>
          <span className="flex-1" />
          <Button size="sm" variant={destructive ? 'destructive' : 'default'}
                  disabled={busy} onClick={onConfirm}>
            {busy ? 'Working…' : confirmLabel}
          </Button>
        </div>
      </div>
    </div>
  );
}
