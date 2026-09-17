/**
 * The admin panel is a CLIENT-SIDE SPA. Every page is `'use client'`, there are no route
 * handlers, no server actions and no middleware — it talks to the API from the browser with
 * a bearer token. `output: 'export'` makes that mechanical: the build fails the moment
 * someone reaches for a server feature, rather than quietly requiring a Node runtime that
 * the static host does not have.
 *
 * That constraint is also what lets Cloudflare Access sit in FRONT of the whole thing. A
 * static origin has no server-side session to bypass, so the identity gate is the outermost
 * layer rather than something the app has to re-implement.
 */
export default {
  reactStrictMode: true,
  output: 'export',
  images: { unoptimized: true },
  // Emits `/users/index.html` rather than `/users.html`, so the export drops onto any static
  // host without rewrite rules. Same reason the marketing site does it.
  trailingSlash: true,
};
