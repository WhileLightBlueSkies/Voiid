/**
 * Domain hues — section identity.
 *
 * The app defines five (Theme.swift, "Domain hues"); the site adds three aliases so
 * every page in the nav has one. A hue is applied by setting the `--hue` custom
 * property on a subtree; components read `var(--hue)` and never name a colour.
 *
 * A page sets its hue once — normally on <Hero hue="..."> and each <Section hue="...">
 * — and everything inside inherits it.
 */

import type { CSSProperties } from 'react';

export type DomainHue =
  | 'chat'
  | 'stories'
  | 'map'
  | 'calls'
  | 'payments'
  | 'games'
  | 'clips'
  | 'privacy';

/**
 * The style object that binds a subtree to a hue. Two properties: the hue itself and
 * a translucent wash of it (tints, glows, hairlines) that cannot be derived in CSS
 * without `color-mix` on every use site.
 *
 * Usage: `<div style={hueVars('map')}>` — or just pass `hue="map"` to any primitive.
 */
export function hueVars(hue?: DomainHue): CSSProperties | undefined {
  if (!hue) return undefined;
  return {
    ['--hue' as string]: `var(--hue-${hue})`,
    ['--hue-wash' as string]: `color-mix(in srgb, var(--hue-${hue}) 12%, transparent)`,
  } as CSSProperties;
}
