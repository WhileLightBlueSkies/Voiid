'use client';

//
// The console's one choice control, replacing native <select>.
//
// A native select opens the OPERATING SYSTEM's menu: grey, square, in the system font, and
// different on every browser — the one surface on a page the theme cannot reach. This draws
// the menu itself, so a filter or a sort reads like the rest of the console.
//
// It keeps what the native control gave for free, because an operator who drives the panel
// from the keyboard must not lose it:
//   * ArrowDown / Enter / Space open it; arrows, Home and End move; Enter or Space picks;
//     Escape closes and returns focus to the trigger; Tab closes and moves on.
//   * Typing a letter jumps to the next option starting with it.
//   * listbox / option roles, aria-expanded and aria-activedescendant for screen readers.
//
// The menu is PORTALLED and fixed-positioned. Several selects live inside tables whose card
// clips overflow, and an absolutely positioned menu there would be cut off at the card edge.
// It flips upward when there is no room below.
//

import { useCallback, useEffect, useId, useLayoutEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Check, ChevronDown } from 'lucide-react';
import { cn } from '../../lib/utils';

export type DropdownOption<V extends string | number> = {
  value: V;
  label: string;
  /** A second line under the label, for options whose name alone is ambiguous. */
  hint?: string;
  tone?: 'danger';
};

export function Dropdown<V extends string | number>({
  value, onChange, options, placeholder = 'Select…', ariaLabel, disabled, variant = 'pill',
  className, menuMinWidth = 200, id,
}: {
  value: V | '' | null | undefined;
  onChange: (v: V) => void;
  options: DropdownOption<V>[];
  placeholder?: string;
  ariaLabel?: string;
  disabled?: boolean;
  /** `pill` for toolbars and filters; `field` for a full-width form input. */
  variant?: 'pill' | 'field';
  className?: string;
  menuMinWidth?: number;
  id?: string;
}) {
  const [open, setOpen] = useState(false);
  const [hi, setHi] = useState(0);
  const [pos, setPos] = useState<{ left: number; top?: number; bottom?: number; width: number; maxH: number } | null>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const list = useRef<HTMLUListElement>(null);
  const typed = useRef({ text: '', at: 0 });
  const uid = useId();
  const listId = `${uid}-list`;

  const selectedIndex = options.findIndex((o) => o.value === value);
  const selected = selectedIndex >= 0 ? options[selectedIndex] : null;

  const place = useCallback(() => {
    const r = trigger.current?.getBoundingClientRect();
    if (!r) return;
    const gap = 8;
    const below = window.innerHeight - r.bottom - gap - 12;
    const above = r.top - gap - 12;
    const want = Math.min(320, options.length * 44 + 12);
    const up = below < want && above > below;
    const width = Math.max(r.width, menuMinWidth);
    // Keep the menu on screen horizontally: right-align it to the trigger if it would overflow.
    const left = r.left + width > window.innerWidth - 12 ? Math.max(12, r.right - width) : r.left;
    setPos(up
      ? { left, bottom: window.innerHeight - r.top + gap, width, maxH: Math.min(320, above) }
      : { left, top: r.bottom + gap, width, maxH: Math.min(320, below) });
  }, [options.length, menuMinWidth]);

  const openMenu = () => {
    if (disabled) return;
    setHi(selectedIndex >= 0 ? selectedIndex : 0);
    place();
    setOpen(true);
  };
  const close = (refocus = true) => {
    setOpen(false);
    if (refocus) trigger.current?.focus();
  };
  const pick = (i: number) => {
    const o = options[i];
    if (!o) return;
    close();
    if (o.value !== value) onChange(o.value);
  };

  // Follow the trigger while open: a page scroll or resize must not leave the menu floating
  // over the wrong row.
  useLayoutEffect(() => {
    if (!open) return;
    place();
    const onMove = () => place();
    window.addEventListener('scroll', onMove, true);
    window.addEventListener('resize', onMove);
    return () => {
      window.removeEventListener('scroll', onMove, true);
      window.removeEventListener('resize', onMove);
    };
  }, [open, place]);

  useEffect(() => {
    if (!open) return;
    list.current?.focus({ preventScroll: true });
    const onDown = (e: MouseEvent) => {
      const t = e.target as Node;
      if (!trigger.current?.contains(t) && !list.current?.contains(t)) close(false);
    };
    document.addEventListener('mousedown', onDown);
    return () => document.removeEventListener('mousedown', onDown);
  }, [open]);

  // Keep the highlighted option in view as the arrows move through a long list.
  useEffect(() => {
    if (!open) return;
    list.current?.querySelector<HTMLElement>(`[data-i="${hi}"]`)?.scrollIntoView({ block: 'nearest' });
  }, [hi, open]);

  const typeAhead = (key: string) => {
    const now = Date.now();
    const t = typed.current;
    t.text = now - t.at > 600 ? key : t.text + key;
    t.at = now;
    const from = t.text.length === 1 ? hi + 1 : hi;
    for (let k = 0; k < options.length; k++) {
      const i = (from + k) % options.length;
      if (options[i].label.toLowerCase().startsWith(t.text.toLowerCase())) return i;
    }
    return -1;
  };

  const onListKey = (e: React.KeyboardEvent) => {
    switch (e.key) {
      case 'ArrowDown': e.preventDefault(); setHi((h) => Math.min(h + 1, options.length - 1)); break;
      case 'ArrowUp': e.preventDefault(); setHi((h) => Math.max(h - 1, 0)); break;
      case 'Home': e.preventDefault(); setHi(0); break;
      case 'End': e.preventDefault(); setHi(options.length - 1); break;
      case 'Enter': case ' ': e.preventDefault(); pick(hi); break;
      case 'Escape': e.preventDefault(); close(); break;
      case 'Tab': close(false); break;
      default:
        if (e.key.length === 1 && !e.metaKey && !e.ctrlKey) {
          const i = typeAhead(e.key);
          if (i >= 0) setHi(i);
        }
    }
  };

  return (
    <>
      <button
        ref={trigger}
        id={id}
        type="button"
        disabled={disabled}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={open ? listId : undefined}
        aria-label={ariaLabel ? `${ariaLabel}: ${selected?.label ?? placeholder}` : undefined}
        onClick={() => (open ? close() : openMenu())}
        onKeyDown={(e) => {
          if (['ArrowDown', 'ArrowUp', 'Enter', ' '].includes(e.key)) { e.preventDefault(); openMenu(); }
        }}
        className={cn(
          'group inline-flex items-center gap-2 text-left text-sm font-medium text-[color:var(--text)]',
          'bg-card shadow-[var(--shadow-1)] ring-1 ring-[var(--border)] transition-[box-shadow,background] duration-150',
          'hover:bg-card hover:ring-[var(--border-strong)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--lime-strong)]',
          'disabled:cursor-not-allowed disabled:opacity-50',
          open && 'ring-2 ring-[var(--lime-strong)] hover:ring-[var(--lime-strong)]',
          variant === 'pill' ? 'h-10 rounded-full pl-4 pr-3' : 'h-11 w-full rounded-[12px] pl-3.5 pr-3',
          className,
        )}
      >
        <span className={cn('min-w-0 flex-1 truncate', !selected && 'text-[color:var(--text-dim)]')}>
          {selected?.label ?? placeholder}
        </span>
        <span className={cn(
          'grid h-6 w-6 shrink-0 place-items-center rounded-full transition-[transform,background] duration-200',
          open ? 'rotate-180 bg-[var(--accent)] text-white' : 'bg-[var(--surface-2)] text-[color:var(--text-dim)]',
        )}>
          <ChevronDown size={14} strokeWidth={2.4} />
        </span>
      </button>

      {open && pos && createPortal(
        <ul
          ref={list}
          id={listId}
          role="listbox"
          tabIndex={-1}
          aria-label={ariaLabel}
          aria-activedescendant={`${uid}-o${hi}`}
          onKeyDown={onListKey}
          style={{ position: 'fixed', left: pos.left, top: pos.top, bottom: pos.bottom, minWidth: pos.width, maxHeight: pos.maxH }}
          className={cn(
            'z-[60] m-0 list-none overflow-y-auto rounded-[18px] bg-card p-1.5 outline-none',
            'shadow-[var(--shadow-2)] ring-1 ring-black/[0.05]',
            'animate-in fade-in-0 zoom-in-95 duration-150',
            pos.top !== undefined ? 'slide-in-from-top-1 origin-top' : 'slide-in-from-bottom-1 origin-bottom',
          )}
        >
          {options.map((o, i) => {
            const isSel = o.value === value;
            return (
              <li
                key={String(o.value)}
                id={`${uid}-o${i}`}
                data-i={i}
                role="option"
                aria-selected={isSel}
                onMouseEnter={() => setHi(i)}
                onMouseDown={(e) => e.preventDefault()}
                onClick={() => pick(i)}
                className={cn(
                  'flex cursor-pointer items-center gap-3 rounded-[12px] px-3 py-2.5 text-sm transition-colors duration-100',
                  i === hi && 'bg-[var(--surface-2)]',
                  isSel ? 'font-semibold' : 'font-medium',
                  o.tone === 'danger' ? 'text-[color:var(--danger)]' : 'text-[color:var(--text)]',
                )}
              >
                <span className="min-w-0 flex-1">
                  <span className="block truncate">{o.label}</span>
                  {o.hint && <span className="block truncate text-micro font-normal text-[color:var(--text-mute)]">{o.hint}</span>}
                </span>
                <span className={cn(
                  'grid h-5 w-5 shrink-0 place-items-center rounded-full transition-opacity',
                  isSel ? 'bg-[var(--lime)] text-[color:var(--text)] opacity-100' : 'opacity-0',
                )}>
                  <Check size={12} strokeWidth={3} />
                </span>
              </li>
            );
          })}
        </ul>,
        document.body,
      )}
    </>
  );
}
