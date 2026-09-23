import * as React from 'react';
import { cva, type VariantProps } from 'class-variance-authority';
import { cn } from '../../lib/utils';

//
// Status badges. Every variant is a TINT plus a readable ink, not a solid fill: a row of
// saturated pills in a dense table fights the data for attention, which is backwards —
// the number is the content, the status is the label on it.
//
const badgeVariants = cva(
  'inline-flex items-center rounded-full border px-2.5 py-0.5 text-tiny font-semibold transition-colors',
  {
    variants: {
      variant: {
        default: 'border-transparent bg-[var(--lime-soft)] text-[var(--accent-ink)]',
        secondary: 'border-border bg-secondary text-[var(--text-dim)]',
        destructive: 'border-transparent bg-[rgba(217,58,58,0.09)] text-[var(--danger)]',
        ok: 'border-transparent bg-[rgba(30,158,79,0.1)] text-[var(--ok)]',
        warning: 'border-transparent bg-[rgba(185,132,7,0.1)] text-[var(--warning)]',
        attention: 'border-transparent bg-[rgba(226,112,27,0.1)] text-[var(--attention)]',
        outline: 'border-border text-[var(--text-dim)]',
      },
    },
    defaultVariants: { variant: 'default' },
  },
);

export interface BadgeProps
  extends React.HTMLAttributes<HTMLDivElement>, VariantProps<typeof badgeVariants> {}

function Badge({ className, variant, ...props }: BadgeProps) {
  return <div className={cn(badgeVariants({ variant }), className)} {...props} />;
}

export { Badge, badgeVariants };
