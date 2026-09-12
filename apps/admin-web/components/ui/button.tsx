'use client';

import * as React from 'react';
import { cva, type VariantProps } from 'class-variance-authority';
import { cn } from '../../lib/utils';

//
// Variants named for the JOB, not the colour.
//
// `destructive` rather than `red`: the day the danger hue changes, every call site should
// follow without being edited, and a reviewer reading `variant="destructive"` on a takedown
// button can tell it is correct without opening the palette.
//
const buttonVariants = cva(
  'inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-md text-sm font-medium ' +
  'transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring ' +
  'focus-visible:ring-offset-2 focus-visible:ring-offset-background ' +
  'disabled:pointer-events-none disabled:opacity-50 [&_svg]:size-4 [&_svg]:shrink-0',
  {
    variants: {
      variant: {
        default: 'bg-primary text-white hover:bg-[var(--accent-hover)]',
        destructive: 'bg-destructive text-white hover:brightness-110',
        outline: 'border border-border bg-transparent hover:bg-accent hover:text-accent-foreground',
        secondary: 'bg-secondary text-secondary-foreground hover:bg-accent',
        ghost: 'hover:bg-accent hover:text-accent-foreground text-[var(--text-dim)]',
        link: 'text-[var(--accent-ink)] underline-offset-4 hover:underline',
      },
      size: {
        default: 'h-9 px-4 py-2',
        sm: 'h-8 rounded-md px-3 text-tiny',
        lg: 'h-10 rounded-md px-6',
        icon: 'h-9 w-9',
      },
    },
    defaultVariants: { variant: 'default', size: 'default' },
  },
);

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant, size, ...props }, ref) => (
    <button ref={ref} className={cn(buttonVariants({ variant, size }), className)} {...props} />
  ),
);
Button.displayName = 'Button';

export { Button, buttonVariants };
