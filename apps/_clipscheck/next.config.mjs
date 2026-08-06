/**
 * The marketing site is a BROCHURE. `output: 'export'` is not a deployment
 * preference, it is a guard rail: it makes the constraint mechanical, so the build
 * fails the moment someone reaches for a server action, a route handler, or ISR.
 * There is no auth here, no form that collects anything, and nothing to leak.
 *
 * `images.unoptimized` follows from that — the optimiser is a server. Every graphic
 * on this site is CSS or inline SVG we author, so there is nothing to optimise and
 * no external asset host to depend on (offline builds must work).
 */

/** @type {import('next').NextConfig} */
export default {
  reactStrictMode: true,
  output: 'export',
  images: { unoptimized: true },
  // Emits `/messaging/index.html` rather than `/messaging.html`, so the export drops
  // onto any static host (S3, R2, Pages, nginx) without a rewrite rule.
  trailingSlash: true,
};
