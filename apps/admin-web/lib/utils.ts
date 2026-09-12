import { type ClassValue, clsx } from 'clsx';
import { twMerge } from 'tailwind-merge';

/**
 * The class merger every shadcn component composes with.
 *
 * twMerge on top of clsx so a caller's `className` can OVERRIDE a component's default
 * rather than fighting it: `<Button className="bg-destructive">` wins, instead of both
 * background classes landing in the DOM and the cascade deciding by source order.
 */
export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}
