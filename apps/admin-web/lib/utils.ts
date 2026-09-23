import { type ClassValue, clsx } from 'clsx';
import { extendTailwindMerge } from 'tailwind-merge';

/**
 * tailwind-merge, taught this console's custom font sizes.
 *
 * It only knows Tailwind's stock scale, and it classifies an unknown `text-*` as a COLOUR.
 * So `text-tiny` (one of the sizes in tailwind.config.ts) was read as a colour and silently
 * deleted whatever colour class came before it: a ghost <Button size="sm"> lost its ink and
 * rendered white-on-white. Registering the sizes puts them in the font-size group, where
 * they belong, and colours survive.
 */
const twMerge = extendTailwindMerge({
  extend: {
    classGroups: {
      'font-size': [{ text: ['micro', 'tiny'] }],
    },
  },
});

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
