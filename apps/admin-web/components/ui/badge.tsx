import * as React from 'react';
import { cva, type VariantProps } from 'class-variance-authority';
import { cn } from '../../lib/utils';

//
// Status badges. Every variant is a TINT plus a readable ink, not a solid fill: a row of
// saturated pills in a dense table fights the data for attention, which is backwards —
// the number is the content, the status is the label on it.
//
const badgeVariants = cva(
  'inline-flex items-center rounded-sm border px-2 py-0.5 text-tiny font-medium transition-colors',
  {
    variants: {
      variant: {
        default: 'border-transparent bg-[var(--accent-quiet)] text-[var(--accent-ink)]',
        secondary: 'border-border bg-secondary text-[var(--text-dim)]',
        destructive: 'border-transparent bg-[rgba(229,72,77,0.14)] text-[#ff8a8d]',
        ok: 'border-transparent bg-[rgba(47,163,107,0.14)] text-[#5cc98f]',
        warning: 'border-transparent bg-[rgba(250,204,21,0.14)] text-[#e3c13f]',
        attention: 'border-transparent bg-[rgba(246,130,31,0.14)] text-[#f6a45f]',
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
